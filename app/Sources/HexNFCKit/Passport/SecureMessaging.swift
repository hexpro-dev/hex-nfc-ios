import Foundation
import HexNFCRecords

/// Wraps and unwraps eMRTD APDUs under a secure-messaging session. BAC produces
/// a `TDESSecureMessaging`; PACE will produce an AES variant (added later). The
/// reader talks to the abstract protocol so the read loop is identical either
/// way.
protocol SecureMessaging: AnyObject {
    /// Protect a plaintext command APDU (increments the send-sequence counter).
    func protect(_ apdu: Data) throws -> Data
    /// Verify and decrypt a protected response, returning `plaintextData ‖ SW1 ‖ SW2`.
    func unprotect(_ response: Data) throws -> Data
}

enum SecureMessagingError: Error, Equatable, Sendable {
    case malformedResponse
    case missingMAC
    case macMismatch
    case missingStatus
}

/// Three-key... no — **two-key** 3DES secure messaging as used after Basic
/// Access Control (ICAO Doc 9303 Part 11 §9.8). Encryption is 3DES-CBC with a
/// zero IV; the checksum is the ISO 9797-1 Retail MAC over `SSC ‖ protected
/// objects`. The send-sequence counter (SSC) is incremented before **every**
/// command and **every** response.
///
/// Verified against the Doc 9303 Part 11 Appendix D.4 worked example
/// (see `SecureMessagingTests`).
final class TDESSecureMessaging: SecureMessaging {
    private let ksEnc: Data
    private let ksMac: Data
    private var ssc: Data
    private let zeroIV = Data(repeating: 0, count: 8)

    init(ksEnc: Data, ksMac: Data, ssc: Data) {
        precondition(ksEnc.count == 16 && ksMac.count == 16 && ssc.count == 8)
        self.ksEnc = ksEnc
        self.ksMac = ksMac
        self.ssc = ssc
    }

    // MARK: - Command protection

    func protect(_ apdu: Data) throws -> Data {
        incrementSSC()
        let command = APDU.parse(apdu)

        let maskedHeader = Data([command.cla | 0x0C, command.ins, command.p1, command.p2])
        let paddedHeader = EMRTDCrypto.iso9797Method2Pad(maskedHeader, blockSize: 8)

        // DO87: encrypted command data (if any).
        var do87 = Data()
        if let data = command.data, !data.isEmpty {
            let padded = EMRTDCrypto.iso9797Method2Pad(data, blockSize: 8)
            let enc = try EMRTDCrypto.tripleDESCBCEncrypt(key: ksEnc, iv: zeroIV, data: padded)
            do87.append(0x87)
            do87.append(berLength(enc.count + 1))
            do87.append(0x01) // padding-content indicator
            do87.append(enc)
        }

        // DO97: expected response length (if any).
        var do97 = Data()
        if let le = command.le {
            do97 = Data([0x97, 0x01, le])
        }

        // DO8E: Retail MAC over SSC ‖ paddedHeader ‖ DO87 ‖ DO97.
        let macInput = ssc + paddedHeader + do87 + do97
        let cc = try EMRTDCrypto.retailMAC(key: ksMac, data: macInput)
        let do8e = Data([0x8E, 0x08]) + cc

        let body = do87 + do97 + do8e
        var out = maskedHeader
        out.append(UInt8(body.count)) // Lc
        out.append(body)
        out.append(0x00) // Le
        return out
    }

    // MARK: - Response verification

    func unprotect(_ response: Data) throws -> Data {
        incrementSSC()
        guard response.count >= 2 else { throw SecureMessagingError.malformedResponse }

        // The trailing two bytes are the transport status word; the real status
        // is carried in DO99 inside the protected body.
        let body = Data(response.dropLast(2))
        let objects = (try? BERTLV.parse(body)) ?? []

        guard let do8e = objects.first(where: { $0.tag == 0x8E }) else {
            throw SecureMessagingError.missingMAC
        }
        guard let do99 = objects.first(where: { $0.tag == 0x99 }) else {
            throw SecureMessagingError.missingStatus
        }
        let do87 = objects.first(where: { $0.tag == 0x87 })

        // MAC covers SSC ‖ (DO87) ‖ DO99 — everything protected, in order,
        // excluding DO8E itself. DO8E is the trailing object, so the MAC input is
        // the body up to where DO8E begins.
        let do8eEncodedLength = do8e.tagBytes.count + berLength(do8e.value.count).count + do8e.value.count
        guard body.count >= do8eEncodedLength else { throw SecureMessagingError.malformedResponse }
        let macCovered = body.prefix(body.count - do8eEncodedLength)
        let expected = try EMRTDCrypto.retailMAC(key: ksMac, data: ssc + macCovered)
        guard constantTimeEqual(expected, do8e.value) else { throw SecureMessagingError.macMismatch }

        // Decrypt DO87 (drop the 0x01 padding-content indicator) if present.
        var plaintext = Data()
        if let do87, do87.value.count > 1 {
            let enc = do87.value.dropFirst()
            let dec = try EMRTDCrypto.tripleDESCBCDecrypt(key: ksEnc, iv: zeroIV, data: Data(enc))
            plaintext = stripISO9797Method2(dec)
        }

        return plaintext + do99.value // do99.value is SW1 ‖ SW2
    }

    // MARK: - Helpers

    private func incrementSSC() {
        var carry: UInt16 = 1
        for i in stride(from: ssc.count - 1, through: 0, by: -1) {
            let sum = UInt16(ssc[ssc.startIndex + i]) + carry
            ssc[ssc.startIndex + i] = UInt8(sum & 0xFF)
            carry = sum >> 8
            if carry == 0 {
                break
            }
        }
    }
}

/// Strip ISO/IEC 9797-1 method 2 padding: drop trailing `0x00`s and the final
/// `0x80`. Returns the input unchanged if no `0x80` marker is found.
func stripISO9797Method2(_ data: Data) -> Data {
    var end = data.endIndex
    while end > data.startIndex {
        let i = data.index(before: end)
        let byte = data[i]
        if byte == 0x00 {
            end = i
            continue
        }
        if byte == 0x80 {
            return Data(data[data.startIndex ..< i])
        }
        break
    }
    return data
}

/// Length-independent byte comparison for MAC checks.
func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for i in 0 ..< a.count {
        diff |= a[a.startIndex + i] ^ b[b.startIndex + i]
    }
    return diff == 0
}
