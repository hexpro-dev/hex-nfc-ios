import Foundation
@testable import HexNFCKit
@testable import HexNFCRecords

/// A chip simulator that also answers FeliCa "Read Without Encryption" requests.
/// Implemented by transit-card sims so `SimulatedConnectedTag` can bridge to the
/// production `FeliCaReadable` seam without CoreNFC.
public protocol FeliCaChipSimulator: ChipSimulator {
    var systemCode: UInt16 { get }
    var idm: Data { get }
    func readWithoutEncryption(serviceCode: UInt16, blocks: Range<Int>) throws -> [Data]
}

/// Bridges a simulated tag to `FeliCaReadable` when its simulator is a
/// `FeliCaChipSimulator`. Mirrors the production `CoreNFCConnectedTag`
/// conformance, so `TransitReader` runs identically over the simulator.
extension SimulatedConnectedTag: FeliCaReadable {
    public var systemCode: UInt16 {
        (simulator as? FeliCaChipSimulator)?.systemCode ?? 0
    }

    public var idm: Data {
        (simulator as? FeliCaChipSimulator)?.idm ?? simulator.uid
    }

    public func readWithoutEncryption(
        serviceCode: UInt16,
        blocks: Range<Int>
    ) async throws -> [Data] {
        guard let felica = simulator as? FeliCaChipSimulator else {
            throw TagError.capabilityUnsupported(.transitRead)
        }
        return try felica.readWithoutEncryption(serviceCode: serviceCode, blocks: blocks)
    }
}

/// Simulates a Suica-family (FeliCa system `0x0003`) transit IC card, exposing a
/// canned but realistic 20-block transaction history on service `0x090F`.
///
/// The fixture covers all four block namespaces a real card mixes together: rail
/// rides, a top-up, a bus fare and a shop purchase. The non-rail blocks carry
/// non-zero bytes 6-9 because real silicon always does; the *values* are stand-ins
/// chosen to collide with seeded rail codes, not decoded field layouts.
///
/// The history blocks are built with `SuicaHistoryDecoder`'s exact byte layout,
/// so this simulator is a faithful source of truth for the decoder and the
/// end-to-end `TransitReader` path. FeliCa is block-addressed and non-NDEF, so
/// the page/NDEF/auth members throw `.capabilityUnsupported`, matching the
/// production session.
public final class SuicaSimulator: FeliCaChipSimulator, @unchecked Sendable {
    public let uid: Data
    public let profile: ChipProfile?
    public let systemCode: UInt16
    /// History blocks, newest first (index 0 = most recent), 16 bytes each.
    public private(set) var historyBlocks: [Data]

    public var idm: Data {
        uid
    }

    /// Default IDm (8 bytes) for the simulated card.
    public static let defaultIDm = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])

    public init(
        idm: Data = SuicaSimulator.defaultIDm,
        history: [Data] = SuicaSimulator.sampleHistory()
    ) {
        uid = idm
        systemCode = 0x0003
        // The transit card declares the generic FeliCa profile plus transitRead.
        if let base = ChipCatalog.profile(for: .genericFeliCa) {
            profile = ChipProfile(
                id: base.id,
                family: base.family,
                capabilities: base.capabilities.union(.transitRead),
                displayName: base.displayName,
                manufacturer: base.manufacturer,
                memoryLayout: base.memoryLayout
            )
        } else {
            profile = nil
        }
        // Pad/trim to exactly 20 blocks of 16 bytes.
        var blocks = history
        while blocks.count < 20 {
            blocks.append(Data(repeating: 0, count: 16))
        }
        historyBlocks = Array(blocks.prefix(20))
    }

    // MARK: - FeliCaChipSimulator

    public func readWithoutEncryption(serviceCode: UInt16, blocks: Range<Int>) throws -> [Data] {
        guard serviceCode == 0x090F else {
            // Unknown service → FeliCa would return a non-zero status flag.
            throw TagError.protocolError(
                "no such service",
                diagnostics: "service=\(String(format: "%04X", serviceCode))"
            )
        }
        return blocks.compactMap { index in
            historyBlocks.indices.contains(index) ? historyBlocks[index] : nil
        }
    }

    // MARK: - ChipSimulator (non-applicable surfaces)

    public func handle(command: Data) -> Data {
        Data()
    }

    public func readMemory(range: Range<Int>) throws -> Data {
        throw TagError.capabilityUnsupported(.memoryRead)
    }

    public func writeMemory(at offset: Int, bytes: Data) throws {
        throw TagError.capabilityUnsupported(.memoryWrite)
    }

    public func readNDEF() throws -> Data {
        // Transit cards carry no NDEF — this is the "identified, zero records"
        // path the scan flow treats as a successful read.
        throw TagError.capabilityUnsupported(.ndefRead)
    }

    public func writeNDEF(_ message: Data) throws {
        throw TagError.capabilityUnsupported(.ndefWrite)
    }

    public func authenticate(password: Data) throws -> Data {
        throw TagError.capabilityUnsupported(.passwordAuth)
    }

    public func setPassword(_ password: Data, pack: Data) throws {
        throw TagError.capabilityUnsupported(.passwordAuth)
    }

    public func permanentLock() throws {
        throw TagError.capabilityUnsupported(.permanentLock)
    }

    // MARK: - Block construction

    /// Build a 16-byte Suica history block from decoded fields, matching
    /// `SuicaHistoryDecoder`'s layout exactly.
    ///
    /// The `entry*`/`exit*` parameters are byte setters for bytes 6-9. They only
    /// *mean* "station" on a rail ride; use `makeNonRailBlock` when building a
    /// bus, charge or purchase block so the call site says what those bytes
    /// actually hold.
    public static func makeBlock(
        terminal: UInt8,
        process: UInt8,
        year: Int,
        month: Int,
        day: Int,
        entryLine: UInt8 = 0,
        entryStation: UInt8 = 0,
        exitLine: UInt8 = 0,
        exitStation: UInt8 = 0,
        balanceYen: Int,
        sequence: Int
    ) -> Data {
        var b = [UInt8](repeating: 0, count: 16)
        b[0] = terminal
        b[1] = process
        let packedDate = UInt16(((year - 2000) & 0x7F) << 9 | (month & 0x0F) << 5 | (day & 0x1F))
        b[4] = UInt8(packedDate >> 8)
        b[5] = UInt8(packedDate & 0xFF)
        b[6] = entryLine
        b[7] = entryStation
        b[8] = exitLine
        b[9] = exitStation
        b[10] = UInt8(balanceYen & 0xFF) // little-endian
        b[11] = UInt8((balanceYen >> 8) & 0xFF)
        b[12] = UInt8((sequence >> 16) & 0xFF)
        b[13] = UInt8((sequence >> 8) & 0xFF)
        b[14] = UInt8(sequence & 0xFF)
        return Data(b)
    }

    /// Build a block whose bytes 6-9 are **not** rail station codes: a bus
    /// fare's line/stop codes, or the terminal/shop identifiers a charge or a
    /// shop purchase writes into the same four bytes.
    ///
    /// Real silicon fills these bytes on every kind of block. Modelling them as
    /// zero (as this simulator did until 2026-08-19) is the divergence that let
    /// the app resolve them against the rail station directory and offer a
    /// "Name this station" input under top-ups and purchases.
    public static func makeNonRailBlock(
        terminal: UInt8,
        process: UInt8,
        year: Int,
        month: Int,
        day: Int,
        aux6: UInt8,
        aux7: UInt8,
        aux8: UInt8 = 0,
        aux9: UInt8 = 0,
        balanceYen: Int,
        sequence: Int
    ) -> Data {
        makeBlock(
            terminal: terminal, process: process,
            year: year, month: month, day: day,
            entryLine: aux6, entryStation: aux7,
            exitLine: aux8, exitStation: aux9,
            balanceYen: balanceYen, sequence: sequence
        )
    }

    /// A realistic five-entry history (newest first), the rest blank: two rail
    /// rides, a top-up, a bus fare and a shop purchase.
    ///
    /// Rail codes line up with the seeded StationPack entries (line 1: Tokyo=1,
    /// Shinjuku=8, Shibuya=12, Shinagawa=22). The three non-rail blocks
    /// deliberately carry bytes 6-9 that **collide with those seeded rail
    /// codes**, so any regression that resolves them against the station
    /// directory shows up as a wrong station name rather than a blank.
    public static func sampleHistory() -> [Data] {
        [
            makeBlock(terminal: 0x16, process: 0x01, year: 2024, month: 5, day: 20,
                      entryLine: 1, entryStation: 8, exitLine: 1, exitStation: 12,
                      balanceYen: 1230, sequence: 100),
            // Top-up at a station machine: bytes 6-7 hold that machine's own
            // station code and 8-9 are zero, matching the live cards. 01:08
            // collides with the seeded Shinjuku entry, so a regression that
            // resolves a charge leg shows up as a wrong name rather than a blank.
            makeNonRailBlock(terminal: 0x16, process: 0x02, year: 2024, month: 5, day: 18,
                             aux6: 0x01, aux7: 0x08,
                             balanceYen: 1450, sequence: 99),
            // Bus fare: bytes 6-7 are a 16-bit bus line code and 8-9 a 16-bit
            // stop code, in the bus namespace. 01:0C collides with Shibuya.
            makeNonRailBlock(terminal: 0x05, process: 0x0D, year: 2024, month: 5, day: 17,
                             aux6: 0x01, aux7: 0x0C, aux8: 0x00, aux9: 0x05,
                             balanceYen: 450, sequence: 98),
            makeBlock(terminal: 0x16, process: 0x01, year: 2024, month: 5, day: 15,
                      entryLine: 1, entryStation: 1, exitLine: 1, exitStation: 22,
                      balanceYen: 660, sequence: 97),
            // Shop purchase: bytes 6-7 carry a packed time of day and 8-9 a shop
            // code. The exact bit layout of the time is NOT modelled here (no
            // trace to derive it from), so these are opaque non-zero bytes that
            // stand in for "not a station code" and nothing more. Do not read a
            // clock out of them.
            makeNonRailBlock(terminal: 0xC7, process: 0x46, year: 2024, month: 5, day: 10,
                             aux6: 0x11, aux7: 0x2E, aux8: 0x03, aux9: 0x9F,
                             balanceYen: 1180, sequence: 96),
        ]
    }
}
