import Foundation

/// Reads the opening of an NFC Forum Type 4 tag's NDEF message with plain
/// ISO 7816 commands, so identification can tell a personal health device from
/// an ordinary tag before anything else is sent to it.
///
/// A `transceive`-closure driver, like the protection drivers, so the frames
/// the simulator answers in CI are the frames production sends. It only ever
/// SELECTs and READs: nothing here can change a tag.
///
/// Sequence (NFC Forum Type 4 Tag, mapping version 2.0), with the NDEF
/// application already selected:
///
///     00 A4 00 0C 02 E1 03      SELECT the Capability Container
///     00 B0 00 00 0F            READ BINARY 15 bytes of it
///     00 A4 00 0C 02 <file>     SELECT the NDEF file the CC names
///     00 B0 00 00 02            READ BINARY NLEN
///     00 B0 00 02 <n>           READ BINARY the head of the message
///
/// and, only when the head is a PHD record, the rest of that message in chunks
/// no larger than the CC's MLe. A published NovoPen 6 trace answers exactly
/// this sequence (`PHDCDeviceSimulator` replays it).
struct Type4NDEFProbe: Sendable {
    /// Sends one command APDU and returns `response data || SW1 || SW2`. The
    /// label names the frame in the trace.
    let transceive: @Sendable (_ command: Data, _ label: String) async throws -> Data

    enum Outcome: Equatable, Sendable {
        /// The message opens with a PHD record. `message` is the whole message
        /// when it was short enough to read in full, else `nil`.
        case personalHealthDevice(message: Data?)
        /// An ordinary NDEF message, of which only the head was read.
        case ndef(head: Data)
        /// The tag did not answer the Type 4 sequence as a readable NDEF tag.
        case unreadable(String)
    }

    /// Bytes of the message read before deciding. Enough for any NDEF record
    /// header and a three-byte type.
    static let headLength = 16

    /// A PHDC association request is about 60 bytes. Anything longer is not
    /// one, and identification has no business reading a long file in full.
    static let fullMessageLimit = 1024

    /// Largest READ BINARY this probe asks for, whatever the CC allows: a short
    /// APDU's Le tops out at 256, and 255 keeps clear of the `00` encoding.
    static let maxReadLength = 255

    func probe() async -> Outcome {
        do {
            guard try await isSuccess(transceive(Self.select(fileID: 0xE103), "SELECT CC")) else {
                return .unreadable("no Capability Container")
            }
            let ccResponse = try await transceive(Self.readBinary(offset: 0, length: 15), "READ CC")
            guard isSuccess(ccResponse), let cc = CapabilityContainer(Data(ccResponse.dropLast(2))) else {
                return .unreadable("Capability Container unreadable: \(ccResponse.hexString)")
            }
            guard cc.readAccessGranted else {
                return .unreadable("NDEF file read access is \(String(format: "%02X", cc.readAccess))")
            }
            guard try await isSuccess(transceive(Self.select(fileID: cc.ndefFileID), "SELECT NDEF file")) else {
                return .unreadable("NDEF file \(String(format: "%04X", cc.ndefFileID)) not selectable")
            }
            let nlenResponse = try await transceive(Self.readBinary(offset: 0, length: 2), "READ NLEN")
            guard isSuccess(nlenResponse), nlenResponse.count == 4 else {
                return .unreadable("NLEN unreadable: \(nlenResponse.hexString)")
            }
            let length = Int(nlenResponse[nlenResponse.startIndex]) << 8 |
                Int(nlenResponse[nlenResponse.startIndex + 1])
            guard length > 0 else { return .ndef(head: Data()) }

            let chunk = min(cc.maxReadLength, Self.maxReadLength)
            let headLength = min(length, Self.headLength, chunk)
            let headResponse = try await transceive(Self.readBinary(offset: 2, length: headLength), "READ NDEF head")
            guard isSuccess(headResponse) else {
                return .unreadable("NDEF head unreadable: \(headResponse.hexString)")
            }
            let head = Data(headResponse.dropLast(2))
            guard PHDAssociation.startsWithPHDRecord(head) else { return .ndef(head: head) }
            guard length <= Self.fullMessageLimit else { return .personalHealthDevice(message: nil) }

            var message = head
            while message.count < length {
                let offset = 2 + message.count
                let response = try await transceive(
                    Self.readBinary(offset: offset, length: min(length - message.count, chunk)),
                    "READ NDEF"
                )
                guard isSuccess(response), response.count > 2 else {
                    return .personalHealthDevice(message: nil)
                }
                message.append(response.dropLast(2))
            }
            return .personalHealthDevice(message: message)
        } catch {
            return .unreadable("\(error)")
        }
    }

    private func isSuccess(_ response: Data) -> Bool {
        response.count >= 2 && Array(response.suffix(2)) == [0x90, 0x00]
    }

    /// `SELECT` by file identifier, first or only occurrence, no response data.
    static func select(fileID: UInt16) -> Data {
        Data([0x00, 0xA4, 0x00, 0x0C, 0x02, UInt8(fileID >> 8), UInt8(fileID & 0xFF)])
    }

    /// `READ BINARY` from the currently selected file.
    static func readBinary(offset: Int, length: Int) -> Data {
        Data([0x00, 0xB0, UInt8((offset >> 8) & 0x7F), UInt8(offset & 0xFF), UInt8(length & 0xFF)])
    }

    /// The fields of a Type 4 Capability Container this probe needs: the
    /// maximum READ BINARY length and the NDEF File Control TLV.
    struct CapabilityContainer: Equatable {
        let maxReadLength: Int
        let ndefFileID: UInt16
        let readAccess: UInt8

        var readAccessGranted: Bool {
            readAccess == 0x00
        }

        /// `CCLEN(2) version(1) MLe(2) MLc(2)`, then the NDEF File Control TLV
        /// `04 06 fileID(2) maxSize(2) read(1) write(1)`. A CC that carries the
        /// mapping 3.0 extended TLV (`06`) instead is not read.
        init?(_ bytes: Data) {
            let cc = [UInt8](bytes)
            guard cc.count >= 15, cc[7] == 0x04, cc[8] >= 0x06 else { return nil }
            maxReadLength = Int(cc[3]) << 8 | Int(cc[4])
            ndefFileID = UInt16(cc[9]) << 8 | UInt16(cc[10])
            readAccess = cc[13]
            guard maxReadLength > 0 else { return nil }
        }
    }
}
