import Foundation
import HexNFCKit // NTAG424Crypto now lives in the production module

/// SUN (Secure Unique NFC) message generator for NTAG424 DNA.
///
/// SUN URLs embed an encrypted **PICCData** blob (UID + SDM read counter)
/// and a short CMAC tag, both authenticated by the application's master
/// AES-128 key. A verifier holding the master key can decrypt the PICCData
/// and re-derive the CMAC to prove the URL was emitted by a real
/// NTAG424 DNA — not copied off a sticker.
///
/// Reference: NXP AN12196 §3.7 (PICCData format) + §3.8 (SDMMACInput).
public enum NTAG424SUNMessage {
    /// Where to splice the encrypted PICCData and the truncated CMAC into
    /// the URL. Hex is uppercase per NXP convention.
    public struct Template: Hashable, Sendable {
        public let prefix: String
        public let between: String
        public let suffix: String
        public init(prefix: String, between: String, suffix: String = "") {
            self.prefix = prefix
            self.between = between
            self.suffix = suffix
        }

        public static let hexpro = Template(
            prefix: "https://hex.pro/v?p=",
            between: "&c=",
            suffix: ""
        )
    }

    /// Build a SUN URL.
    ///
    /// - Parameters:
    ///   - uid: 7-byte tag UID.
    ///   - readCounter: 24-bit SDM read counter (lower 3 bytes used).
    ///   - encKey: SesAuthENCKey (16 bytes) — for the PICCData encryption.
    ///   - macKey: SesAuthMACKey (16 bytes) — for the CMAC.
    ///   - template: URL prefix / between / suffix strings.
    public static func makeURL(
        uid: Data,
        readCounter: UInt32,
        encKey: Data,
        macKey: Data,
        template: Template = .hexpro
    ) -> String {
        let encryptedPicc = encryptedPICCData(
            uid: uid,
            readCounter: readCounter,
            encKey: encKey
        )
        let macInput = Data(encryptedPicc.uppercaseHex.utf8)
        let cmac = NTAG424Crypto.truncateCMAC(NTAG424Crypto.aesCMAC(key: macKey, data: macInput))
        return template.prefix
            + encryptedPicc.uppercaseHex
            + template.between
            + cmac.uppercaseHex
            + template.suffix
    }

    /// Encrypt `PICCData = TagByte || UID || ReadCounter`, padded with
    /// `0x80` and zeros to a single AES block, with AES-CBC under
    /// `SesAuthENCKey`, IV all zero. Returns the 16-byte ciphertext.
    public static func encryptedPICCData(
        uid: Data,
        readCounter: UInt32,
        encKey: Data
    ) -> Data {
        precondition(uid.count == 7, "NTAG424 UID is 7 bytes")
        precondition(encKey.count == 16, "SesAuthENCKey must be 16 bytes")

        var picc = Data()
        // Tag byte: bit 7 = UIDPresent, bit 6 = ReadCtrPresent, low nibble
        // = encrypted-FileData length (zero here — we don't encrypt file
        // data alongside).
        picc.append(0xC7)
        picc.append(uid)
        // SDM read counter, little-endian, 3 bytes.
        picc.append(UInt8(readCounter & 0xFF))
        picc.append(UInt8((readCounter >> 8) & 0xFF))
        picc.append(UInt8((readCounter >> 16) & 0xFF))
        // ISO 9797-1 method 2 padding: 0x80 followed by zeros.
        picc.append(0x80)
        while picc.count < 16 {
            picc.append(0x00)
        }

        return NTAG424Crypto.aesCBCEncrypt(
            key: encKey,
            iv: Data(repeating: 0x00, count: 16),
            data: picc
        )
    }

    /// Parse a SUN URL back into its PICCData fields. Returns `nil` if the
    /// URL doesn't match the template, the hex doesn't decode, or the
    /// CMAC doesn't verify.
    public static func decodeAndVerify(
        url: String,
        encKey: Data,
        macKey: Data,
        template: Template = .hexpro
    ) -> Decoded? {
        guard url.hasPrefix(template.prefix) else { return nil }
        let afterPrefix = String(url.dropFirst(template.prefix.count))
        guard let betweenRange = afterPrefix.range(of: template.between) else { return nil }
        let piccHex = String(afterPrefix[afterPrefix.startIndex ..< betweenRange.lowerBound])
        var afterBetween = String(afterPrefix[betweenRange.upperBound...])
        if !template.suffix.isEmpty {
            guard afterBetween.hasSuffix(template.suffix) else { return nil }
            afterBetween = String(afterBetween.dropLast(template.suffix.count))
        }
        let cmacHex = afterBetween
        guard let encryptedPicc = Data(uppercaseHex: piccHex), encryptedPicc.count == 16,
              let cmac = Data(uppercaseHex: cmacHex), cmac.count == 8 else { return nil }

        // Re-derive expected CMAC and compare.
        let macInput = Data(piccHex.utf8)
        let expectedCMAC = NTAG424Crypto.truncateCMAC(NTAG424Crypto.aesCMAC(key: macKey, data: macInput))
        guard expectedCMAC == cmac else { return nil }

        // Decrypt PICCData.
        let plain = NTAG424Crypto.aesCBCDecrypt(
            key: encKey,
            iv: Data(repeating: 0x00, count: 16),
            data: encryptedPicc
        )
        let tag = plain[plain.startIndex]
        let uid = plain.subdata(in: (plain.startIndex + 1) ..< (plain.startIndex + 8))
        let ctrLE = plain.subdata(in: (plain.startIndex + 8) ..< (plain.startIndex + 11))
        let b0 = UInt32(ctrLE[ctrLE.startIndex])
        let b1 = UInt32(ctrLE[ctrLE.startIndex + 1]) << 8
        let b2 = UInt32(ctrLE[ctrLE.startIndex + 2]) << 16
        let readCounter = b0 | b1 | b2
        return Decoded(tagByte: tag, uid: uid, readCounter: readCounter)
    }

    public struct Decoded: Hashable, Sendable {
        public let tagByte: UInt8
        public let uid: Data
        public let readCounter: UInt32
    }
}

// MARK: - Hex helpers

extension Data {
    /// Uppercase, unseparated hex (per NXP SDM URL convention).
    var uppercaseHex: String {
        map { String(format: "%02X", $0) }.joined()
    }

    /// Decode a string of uppercase or lowercase hex (no separators) back
    /// to bytes. Returns nil on odd length or invalid character.
    init?(uppercaseHex: String) {
        guard uppercaseHex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(uppercaseHex.count / 2)
        var index = uppercaseHex.startIndex
        while index < uppercaseHex.endIndex {
            let next = uppercaseHex.index(index, offsetBy: 2)
            guard let byte = UInt8(uppercaseHex[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }
}
