import Foundation
import HexNFCRecords

/// AES secure messaging as established by PACE (ICAO Doc 9303 Part 11 §9.8, AES
/// variant): AES-CBC encryption with a per-message IV `E(KSenc, SSC)`, and an
/// AES-CMAC truncated to its **8 most significant bytes** checksum. The send-
/// sequence counter is a 16-byte block, starts at zero, and increments before
/// every command and every response. Keys are AES-128/192/256 (16/24/32 bytes),
/// so it uses the key-size-agnostic AES in `EMRTDCrypto` (not the AES-128-only
/// `NTAG424Crypto`, whose MAC truncation is a different, NXP-specific scheme).
final class AESSecureMessaging: SecureMessaging {
    private let ksEnc: Data
    private let ksMac: Data
    private var ssc: Data // 16 bytes

    init(ksEnc: Data, ksMac: Data) {
        precondition([16, 24, 32].contains(ksEnc.count) && ksEnc.count == ksMac.count)
        self.ksEnc = ksEnc
        self.ksMac = ksMac
        ssc = Data(repeating: 0, count: 16)
    }

    private var iv: Data {
        EMRTDCrypto.aesEncryptBlock(key: ksEnc, ssc)
    }

    func protect(_ apdu: Data) throws -> Data {
        incrementSSC()
        let command = APDU.parse(apdu)
        let maskedHeader = Data([command.cla | 0x0C, command.ins, command.p1, command.p2])
        let paddedHeader = EMRTDCrypto.iso9797Method2Pad(maskedHeader, blockSize: 16)

        var do87 = Data()
        if let data = command.data, !data.isEmpty {
            let padded = EMRTDCrypto.iso9797Method2Pad(data, blockSize: 16)
            let enc = EMRTDCrypto.aesCBCEncrypt(key: ksEnc, iv: iv, data: padded)
            do87.append(0x87)
            do87.append(berLength(enc.count + 1))
            do87.append(0x01)
            do87.append(enc)
        }

        var do97 = Data()
        if let le = command.le {
            do97 = Data([0x97, 0x01, le])
        }

        // ICAO Doc 9303 Part 11 §9.8.6: the MAC input is padded (ISO 9797-1
        // method 2) to the cipher block size *before* the CMAC, exactly as the
        // 3DES Retail MAC pads internally. Feeding the raw, block-unaligned
        // concatenation to AES-CMAC lets RFC 4493 pad it itself and XOR the
        // final block with subkey K2 — but the chip pads first, making the
        // input block-aligned so CMAC uses K1. Same bytes, different subkey →
        // the card rejects the command with SW 0x6988.
        let macInput = EMRTDCrypto.iso9797Method2Pad(ssc + paddedHeader + do87 + do97, blockSize: 16)
        let cc = EMRTDCrypto.macTruncate8(EMRTDCrypto.aesCMAC(key: ksMac, data: macInput))
        let do8e = Data([0x8E, 0x08]) + cc

        let body = do87 + do97 + do8e
        var out = maskedHeader
        out.append(UInt8(body.count))
        out.append(body)
        out.append(0x00)
        return out
    }

    func unprotect(_ response: Data) throws -> Data {
        incrementSSC()
        guard response.count >= 2 else { throw SecureMessagingError.malformedResponse }
        let body = Data(response.dropLast(2))
        let objects = (try? BERTLV.parse(body)) ?? []

        guard let do8e = objects.first(where: { $0.tag == 0x8E }) else {
            throw SecureMessagingError.missingMAC
        }
        guard let do99 = objects.first(where: { $0.tag == 0x99 }) else {
            throw SecureMessagingError.missingStatus
        }
        let do87 = objects.first(where: { $0.tag == 0x87 })

        let do8eLen = do8e.tagBytes.count + berLength(do8e.value.count).count + do8e.value.count
        guard body.count >= do8eLen else { throw SecureMessagingError.malformedResponse }
        let macCovered = body.prefix(body.count - do8eLen)
        let expected = EMRTDCrypto.macTruncate8(
            EMRTDCrypto.aesCMAC(key: ksMac, data: EMRTDCrypto.iso9797Method2Pad(ssc + macCovered, blockSize: 16))
        )
        guard constantTimeEqual(expected, do8e.value) else { throw SecureMessagingError.macMismatch }

        var plaintext = Data()
        if let do87, do87.value.count > 1 {
            let enc = Data(do87.value.dropFirst())
            let dec = EMRTDCrypto.aesCBCDecrypt(key: ksEnc, iv: iv, data: enc)
            plaintext = stripISO9797Method2(dec)
        }
        return plaintext + do99.value
    }

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
