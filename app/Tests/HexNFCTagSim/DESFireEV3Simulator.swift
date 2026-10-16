import Foundation
@testable import HexNFCKit
@testable import HexNFCRecords

/// NXP MIFARE DESFire EV3 4K, modelled as a **factory card**: no applications
/// created, no NDEF application, every data operation key-gated.
///
/// The app's entire DESFire surface is identification plus raw transceive —
/// DESFire keeps its data in key-protected applications, not a blind-readable
/// NDEF area, so `ChipProfile` advertises only `.rawTransceive`. This simulator
/// therefore models exactly that surface, and refuses everything else the way
/// real silicon does rather than pretending to support it.
///
/// **Why it exists:** DESFire was the one chip family in the catalog with no
/// simulator at all, so `desfirePlan` had never executed in CI — the plan and
/// the anti-drift guard couldn't cover it.
///
/// It also closes a real gap in the *NTAG424* coverage: `GET_VERSION` is a
/// 3-frame chained command on genuine silicon, and an undrained chain makes the
/// next command answer `91 CA` (COMMAND_ABORTED). The NTAG424 simulator replies
/// in a single frame, so the drain logic in `MiFareTagIdentifier.getVersion` and
/// `type4GetVersion` had never actually been exercised by a test. This simulator
/// chains for real.
///
/// Wire notes — the **native** (unwrapped) command set, which is what iOS's
/// `sendMiFareCommand` puts on the wire for a DESFire and what
/// `MiFareTagIdentifier` uses:
///   - Status byte comes **first** (`AF …`), unlike the wrapped APDU form whose
///     status word trails (`… 91 AF`).
///   - `0x60` GET_VERSION → 3 frames: `AF`+hw, `AF`+sw, `00`+UID/batch/date.
///   - `0xAF` fetches the next frame of an open chain.
///   - `0x6A` GetApplicationIDs → `00` ‖ 3 bytes per AID (empty on a virgin card).
///   - `0x6E` GetFreeMemory → `00` ‖ 3-byte little-endian free-byte count.
///   - ISO SELECT of the NDEF AID → `6A 82` (file not found) with no NDEF app.
///   - Anything else → `1C` (ILLEGAL_COMMAND_CODE).
public final class DESFireEV3Simulator: ChipSimulator, @unchecked Sendable {
    public let uid: Data
    public let profile: ChipProfile?

    /// How many `GET_VERSION` frames have been handed out. `0` = no chain open.
    /// An open chain is what makes a later native command answer `91 CA` on real
    /// silicon, which is exactly what the identifier's drain logic prevents.
    public private(set) var versionFramesServed = 0

    /// Applications on the card. A factory EV3 has none.
    public var applicationIDs: [Data]

    /// Reported free EEPROM, little-endian 3-byte. Defaults to the **blank-card**
    /// capture; set it alongside `applicationIDs` to model a personalised card.
    ///
    /// Live-verified 2026-08-05 across three DESFire EV3 4K cards:
    ///
    /// | card | applications | free |
    /// |---|---|---|
    /// | blank ×2 | 0 | 5120 B |
    /// | Myki (transit) | 2 | 3200 B |
    ///
    /// The blank figure is deliberately *larger* than the 4096 B the GET_VERSION
    /// storage byte decodes to — that byte is the advertised product tier, not a
    /// bound on the pool. An earlier fabricated value (3808 B) sat below the tier
    /// and let a plan assertion pass in CI that failed on both blank cards.
    ///
    /// No per-application cost is modelled here on purpose: 1920 B for Myki's two
    /// applications is one card's file layout, not a formula worth inventing.
    public var freeMemoryBytes: Int = 5120

    // MARK: - Status bytes (native form — leading byte)

    private enum Status {
        static let ok: UInt8 = 0x00
        static let additionalFrame: UInt8 = 0xAF
        static let illegalCommand: UInt8 = 0x1C
        static let permissionDenied: UInt8 = 0x9D
    }

    /// Real Myki card capture, the same vector `DESFireIdentificationTests` pins:
    /// vendor NXP (`04`), hw type DESFire (`01`), hw major `33` = EV3,
    /// storage `18` → 4096 B.
    public static let versionFrame1 = Data([0x04, 0x01, 0x01, 0x33, 0x00, 0x18, 0x05])
    /// Software info: same shape, software major/minor in place of hardware's.
    public static let versionFrame2 = Data([0x04, 0x01, 0x01, 0x33, 0x00, 0x18, 0x05])

    /// A personalised card modelled on the live Myki capture: two applications
    /// and 3200 B free, i.e. the same pool as a blank card minus its allocations.
    public static func personalised(uid: Data = DESFireEV3Simulator.defaultUID) -> DESFireEV3Simulator {
        let simulator = DESFireEV3Simulator(
            uid: uid,
            applicationIDs: [Data([0x00, 0x11, 0xF2]), Data([0xF0, 0x10, 0xF2])]
        )
        simulator.freeMemoryBytes = 3200
        return simulator
    }

    public init(
        uid: Data = DESFireEV3Simulator.defaultUID,
        applicationIDs: [Data] = []
    ) {
        precondition(uid.count == 7, "DESFire UID is 7 bytes")
        self.uid = uid
        self.applicationIDs = applicationIDs
        // Build the profile through the production decoder, from the very frame
        // this simulator serves — so the simulator can never claim a chip its own
        // GET_VERSION wouldn't identify as.
        profile = ChipCatalog.identify(
            desFireVersion: Data([Status.additionalFrame]) + Self.versionFrame1
        )
    }

    /// NXP manufacturer byte (`0x04`) + an arbitrary but stable serial.
    public static let defaultUID = Data([0x04, 0xDE, 0x5F, 0x13, 0xE3, 0x00, 0x01])

    // MARK: - Command dispatch

    public func handle(command: Data) -> Data {
        guard let opcode = command.first else { return Data([Status.illegalCommand]) }

        // ISO 7816 SELECT (used to probe for an NDEF application).
        if opcode == 0x00, command.count >= 2, command[command.startIndex + 1] == 0xA4 {
            return handleISOSelect(command)
        }

        switch opcode {
        case 0x60: // GET_VERSION — starts a fresh 3-frame chain.
            versionFramesServed = 1
            return Data([Status.additionalFrame]) + Self.versionFrame1

        case 0xAF: // Next frame of the open chain.
            switch versionFramesServed {
            case 1:
                versionFramesServed = 2
                return Data([Status.additionalFrame]) + Self.versionFrame2

            case 2:
                versionFramesServed = 0 // chain complete
                // UID(7) ‖ batch number(5) ‖ production week(1) ‖ year(1).
                return Data([Status.ok]) + uid + Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x24, 0x23])

            default:
                // No chain open — real silicon answers ILLEGAL_COMMAND_CODE.
                return Data([Status.illegalCommand])
            }

        case 0x6A: // GetApplicationIDs
            return Data([Status.ok]) + applicationIDs.reduce(into: Data()) { $0.append($1) }

        case 0x6E: // GetFreeMemory
            let free = UInt32(max(0, freeMemoryBytes))
            return Data([
                Status.ok,
                UInt8(free & 0xFF),
                UInt8((free >> 8) & 0xFF),
                UInt8((free >> 16) & 0xFF),
            ])

        case 0x5A: // SelectApplication — only the master application (000000) exists.
            guard command.count >= 4 else { return Data([Status.illegalCommand]) }
            let aid = command.subdata(in: (command.startIndex + 1) ..< (command.startIndex + 4))
            return aid == Data([0x00, 0x00, 0x00]) || applicationIDs.contains(aid)
                ? Data([Status.ok])
                : Data([0xA0]) // APPLICATION_NOT_FOUND

        case 0x6F, 0xF5, 0xBD, 0xC4:
            // GetFileIDs / GetFileSettings / ReadData / ChangeKey — all key-gated
            // at the PICC level on a factory card, before any authentication.
            return Data([Status.permissionDenied])

        default:
            return Data([Status.illegalCommand])
        }
    }

    /// ISO SELECT. Only the NDEF AID is interesting: a factory EV3 hosts no NDEF
    /// application, so it answers `6A 82` (file/application not found).
    private func handleISOSelect(_ command: Data) -> Data {
        let ndefAID = Data([0xD2, 0x76, 0x00, 0x00, 0x85, 0x01, 0x01])
        if command.count >= 12 {
            let body = command.subdata(in: (command.startIndex + 5) ..< (command.startIndex + 12))
            if body == ndefAID {
                return Data([0x6A, 0x82])
            }
        }
        return Data([0x6A, 0x82])
    }

    // MARK: - Higher-level surface (all refused — DESFire is raw-transceive only)

    private func unsupported(_ capability: TagCapability) -> TagError {
        TagError.capabilityUnsupported(
            capability,
            diagnostics: "DESFire stores data in key-protected applications; only rawTransceive is supported"
        )
    }

    public func readMemory(range: Range<Int>) throws -> Data {
        throw unsupported(.memoryRead)
    }

    public func writeMemory(at offset: Int, bytes: Data) throws {
        throw unsupported(.memoryWrite)
    }

    /// Mirrors production: with no NDEF application, CoreNFC's `queryNDEFStatus`
    /// reports `.notSupported`, which `CoreNFCConnectedTag.readNDEF` surfaces as
    /// `capabilityUnsupported(.ndefRead)` — not a transport failure.
    public func readNDEF() throws -> Data {
        throw unsupported(.ndefRead)
    }

    public func writeNDEF(_ message: Data) throws {
        throw unsupported(.ndefWrite)
    }

    public func authenticate(password: Data) throws -> Data {
        throw unsupported(.passwordAuth)
    }

    public func setPassword(_ password: Data, pack: Data) throws {
        throw unsupported(.passwordAuth)
    }

    public func permanentLock() throws {
        throw unsupported(.permanentLock)
    }
}
