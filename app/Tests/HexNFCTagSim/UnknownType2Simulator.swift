import Foundation
@testable import HexNFCKit
@testable import HexNFCRecords

/// Fallback Type-2 simulator for chips the kit's `ChipCatalog` doesn't
/// recognise. Lets advanced-console tests exercise the "unknown chip"
/// code path — `GET_VERSION` returns all-zeros, no PWD/PACK pages, no
/// permanent lock, no signature.
///
/// Real-world callers would typically downgrade to plain READ/WRITE and
/// surface a warning in the UI; this simulator gives that downgrade path
/// something to drive against.
public final class UnknownType2Simulator: ChipSimulator, @unchecked Sendable {
    public let uid: Data
    public let profile: ChipProfile? = nil

    public private(set) var pages: [Data]
    public private(set) var isLockedPermanent = false

    public init(
        uid: Data = UnknownType2Simulator.defaultUID,
        pageCount: Int = 16,
        ndefMessage: Data? = nil
    ) {
        precondition(uid.count == 7, "UID is 7 bytes")
        precondition(pageCount >= 4, "need at least UID + CC + 2 user pages")
        self.uid = uid
        var seed = Array(repeating: Data(repeating: 0x00, count: 4), count: pageCount)
        // Pages 0–2 mirror the standard NTAG layout so the kit's
        // identification probe finds *something* — it just doesn't match
        // any known profile, which is the point.
        seed[0] = Data([uid[uid.startIndex + 0],
                        uid[uid.startIndex + 1],
                        uid[uid.startIndex + 2],
                        0x88])
        seed[1] = Data([uid[uid.startIndex + 3],
                        uid[uid.startIndex + 4],
                        uid[uid.startIndex + 5],
                        uid[uid.startIndex + 6]])
        seed[2] = Data([0x00, 0x48, 0x00, 0x00])
        seed[3] = Data([0xE1, 0x10, 0x06, 0x00])
        pages = seed
        if let message = ndefMessage {
            let envelope = NDEFEnvelope.wrap(message: message)
            var pad = envelope
            while pad.count % 4 != 0 {
                pad.append(0x00)
            }
            for i in 0 ..< (pad.count / 4) {
                let page = 4 + i
                guard page < pages.count else { break }
                pages[page] = pad.subdata(in: (i * 4) ..< (i * 4 + 4))
            }
        }
    }

    // MARK: - ChipSimulator surface

    public func handle(command: Data) -> Data {
        guard let opcode = command.first else { return Data([0x00]) }
        switch opcode {
        case 0x30: // READ — 16 bytes from <page>
            guard command.count >= 2 else { return nak() }
            let start = Int(command[command.startIndex + 1])
            return readPages(start: start, count: 4)

        case 0xA2: // WRITE — 4 bytes at <page>
            guard command.count >= 6 else { return nak() }
            let page = Int(command[command.startIndex + 1])
            guard page < pages.count, !isLockedPermanent else { return nak() }
            pages[page] = command.subdata(in: (command.startIndex + 2) ..< (command.startIndex + 6))
            return Data([0x0A])

        case 0x60: // GET_VERSION — unknown chip returns zeros so the kit's
            // `identify(getVersion:)` returns nil and callers fall
            // back to the unknown-chip path.
            return Data(repeating: 0x00, count: 8)

        default:
            return nak()
        }
    }

    public func readMemory(range: Range<Int>) throws -> Data {
        guard range.lowerBound >= 0, range.upperBound <= pages.count * 4 else {
            throw TagError.protocolError("read out of range \(range)")
        }
        let all = pages.reduce(Data(), +)
        return all.subdata(in: (all.startIndex + range.lowerBound) ..< (all.startIndex + range.upperBound))
    }

    public func writeMemory(at offset: Int, bytes: Data) throws {
        if isLockedPermanent {
            throw TagError.lockedPermanent()
        }
        guard offset % 4 == 0, bytes.count % 4 == 0 else {
            throw TagError.protocolError("page-aligned writes only")
        }
        var page = offset / 4
        var cursor = bytes.startIndex
        while cursor < bytes.endIndex {
            guard page < pages.count
            else { throw TagError.writeOverflow(needed: cursor + 4, available: pages.count * 4) }
            pages[page] = bytes.subdata(in: cursor ..< (cursor + 4))
            page += 1
            cursor += 4
        }
    }

    public func readNDEF() throws -> Data {
        let all = pages.dropFirst(4).reduce(Data(), +)
        do { return try NDEFEnvelope.unwrap(all) } catch NDEFEnvelope.ParseError.noNDEFTLV { return Data() }
    }

    public func writeNDEF(_ envelope: Data) throws {
        var padded = envelope
        while padded.count % 4 != 0 {
            padded.append(0x00)
        }
        let capacity = (pages.count - 4) * 4
        guard padded.count <= capacity else {
            throw TagError.writeOverflow(needed: padded.count, available: capacity)
        }
        try writeMemory(at: 4 * 4, bytes: padded)
    }

    public func authenticate(password: Data) throws -> Data {
        throw TagError.capabilityUnsupported(.passwordAuth, diagnostics: "unknown chip")
    }

    public func setPassword(_ password: Data, pack: Data) throws {
        throw TagError.capabilityUnsupported(.passwordAuth, diagnostics: "unknown chip")
    }

    public func permanentLock() throws {
        throw TagError.capabilityUnsupported(.permanentLock, diagnostics: "unknown chip")
    }

    // MARK: - Helpers

    private func nak() -> Data {
        Data([0x00])
    }

    private func readPages(start: Int, count: Int) -> Data {
        guard start >= 0, start < pages.count else { return nak() }
        var out = Data()
        for i in 0 ..< count {
            let p = start + i
            if p >= pages.count {
                return nak()
            }
            out.append(pages[p])
        }
        return out
    }

    public static let defaultUID: Data = .init([0x04, 0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE])
}
