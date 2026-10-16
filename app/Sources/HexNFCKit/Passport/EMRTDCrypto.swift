import CommonCrypto
import Foundation

/// eMRTD (ICAO Doc 9303) cryptographic primitives that sit alongside the AES /
/// AES-CMAC in `NTAG424Crypto`. Like that file, everything here is CommonCrypto —
/// a system library, so it adds **no third-party dependency**. This provides the
/// pieces Doc 9303 needs that AES alone doesn't: SHA-1/SHA-256, single-DES and
/// two-key 3DES (Basic Access Control), and the ISO/IEC 9797-1 Retail MAC.
///
/// Key derivation and the BAC key set are verified bit-for-bit against the
/// worked example in ICAO Doc 9303 Part 11 Appendix D (see `EMRTDCryptoTests`).
///
/// References:
///   - ICAO Doc 9303 Part 11, §9.7 (Key Derivation) and Appendix D (BAC example).
///   - ISO/IEC 9797-1 MAC Algorithm 3 (Retail MAC) with padding method 2.
public enum EMRTDCrypto {
    public enum CipherError: Error, Sendable { case failed(CCCryptorStatus) }

    // MARK: - Hashes

    public static func sha1(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &digest) }
        return Data(digest)
    }

    public static func sha256(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        return Data(digest)
    }

    public static func sha224(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA224_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA224($0.baseAddress, CC_LONG(data.count), &digest) }
        return Data(digest)
    }

    public static func sha384(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA384_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA384($0.baseAddress, CC_LONG(data.count), &digest) }
        return Data(digest)
    }

    public static func sha512(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA512($0.baseAddress, CC_LONG(data.count), &digest) }
        return Data(digest)
    }

    // MARK: - AES (key-size-agnostic: AES-128 / AES-192 / AES-256)

    // PACE with the modern curves needs AES-192 and AES-256, which the AES-128-
    // only `NTAG424Crypto` primitives can't do. These mirror that proven
    // structure (manual CBC / RFC 4493 CMAC over a single-block ECB) but accept
    // a 16/24/32-byte key — CommonCrypto selects the AES variant from the key
    // length. Still no third-party dependency. The AES block is always 128 bits,
    // so the CMAC subkey constant (`Rb = 0x87`) and truncation are unchanged.

    /// AES ECB encrypt of one 16-byte block. `key` is 16/24/32 bytes.
    public static func aesEncryptBlock(key: Data, _ block: Data) -> Data {
        aesBlock(operation: kCCEncrypt, key: key, block: block)
    }

    /// AES ECB decrypt of one 16-byte block. `key` is 16/24/32 bytes.
    public static func aesDecryptBlock(key: Data, _ block: Data) -> Data {
        aesBlock(operation: kCCDecrypt, key: key, block: block)
    }

    private static func aesBlock(operation: Int, key: Data, block: Data) -> Data {
        precondition(block.count == 16, "AES block must be 16 bytes")
        precondition(key.count == 16 || key.count == 24 || key.count == 32, "AES key must be 16/24/32 bytes")
        var output = Data(count: 16)
        var moved = 0
        _ = output.withUnsafeMutableBytes { outBuf in
            block.withUnsafeBytes { inBuf in
                key.withUnsafeBytes { keyBuf in
                    CCCrypt(
                        CCOperation(operation),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode), // no padding
                        keyBuf.baseAddress, key.count,
                        nil,
                        inBuf.baseAddress, 16,
                        outBuf.baseAddress, 16,
                        &moved
                    )
                }
            }
        }
        return output
    }

    /// AES-CBC encrypt, no padding. `data.count` must be a multiple of 16.
    public static func aesCBCEncrypt(key: Data, iv: Data, data: Data) -> Data {
        precondition(iv.count == 16 && data.count % 16 == 0)
        var output = Data()
        var prev = iv
        var cursor = data.startIndex
        while cursor < data.endIndex {
            let block = data.subdata(in: cursor ..< (cursor + 16))
            let ct = aesEncryptBlock(key: key, xorData(block, prev))
            output.append(ct)
            prev = ct
            cursor += 16
        }
        return output
    }

    /// AES-CBC decrypt, no padding. `data.count` must be a multiple of 16.
    public static func aesCBCDecrypt(key: Data, iv: Data, data: Data) -> Data {
        precondition(iv.count == 16 && data.count % 16 == 0)
        var output = Data()
        var prev = iv
        var cursor = data.startIndex
        while cursor < data.endIndex {
            let block = data.subdata(in: cursor ..< (cursor + 16))
            let pt = xorData(aesDecryptBlock(key: key, block), prev)
            output.append(pt)
            prev = block
            cursor += 16
        }
        return output
    }

    /// AES-CMAC (RFC 4493), 16-byte tag, for any AES key size.
    public static func aesCMAC(key: Data, data: Data) -> Data {
        let zero = Data(repeating: 0, count: 16)
        let l = aesEncryptBlock(key: key, zero)
        let k1 = cmacSubkey(l)
        let k2 = cmacSubkey(k1)

        let blockCount = max(1, (data.count + 15) / 16)
        let lastComplete = !data.isEmpty && (data.count % 16 == 0)

        var x = Data(repeating: 0, count: 16)
        for i in 0 ..< (blockCount - 1) {
            let start = data.startIndex + i * 16
            x = aesEncryptBlock(key: key, xorData(x, data.subdata(in: start ..< (start + 16))))
        }

        let lastStart = data.startIndex + (blockCount - 1) * 16
        let lastChunk: Data
        if lastComplete {
            lastChunk = xorData(data.subdata(in: lastStart ..< data.endIndex), k1)
        } else {
            var padded = Data()
            if data.count - (blockCount - 1) * 16 > 0 {
                padded.append(data.subdata(in: lastStart ..< data.endIndex))
            }
            padded.append(0x80)
            while padded.count < 16 {
                padded.append(0x00)
            }
            lastChunk = xorData(padded, k2)
        }
        return aesEncryptBlock(key: key, xorData(x, lastChunk))
    }

    /// The ICAO PACE / secure-messaging MAC truncation: the **8 most significant
    /// bytes** (first 8) of the 16-byte CMAC (ICAO Doc 9303 Part 11 §9.8.6). This
    /// is **not** the NXP odd-indexed-byte truncation `NTAG424Crypto.truncateCMAC`
    /// uses — using that against a real passport would fail every MAC.
    public static func macTruncate8(_ mac: Data) -> Data {
        Data(mac.prefix(8))
    }

    /// Bytewise XOR of two equal-length Datas.
    static func xorData(_ a: Data, _ b: Data) -> Data {
        precondition(a.count == b.count, "xor length mismatch")
        var out = Data(count: a.count)
        for i in 0 ..< a.count {
            out[out.startIndex + i] = a[a.startIndex + i] ^ b[b.startIndex + i]
        }
        return out
    }

    /// RFC 4493 §2.3 subkey generation: left-shift a 16-byte block by one bit and
    /// conditionally XOR `Rb = 0x87` (the constant for a 128-bit block, so it is
    /// the same for AES-128/192/256).
    static func cmacSubkey(_ input: Data) -> Data {
        precondition(input.count == 16)
        var out = Data(count: 16)
        let msb = input[input.startIndex] & 0x80
        var carry: UInt8 = 0
        for i in stride(from: 15, through: 0, by: -1) {
            let b = input[input.startIndex + i]
            out[out.startIndex + i] = (b << 1) | carry
            carry = (b & 0x80) != 0 ? 1 : 0
        }
        if msb != 0 {
            out[out.startIndex + 15] ^= 0x87
        }
        return out
    }

    // MARK: - DES / 3DES block ciphers

    /// Low-level one-shot CommonCrypto call. `key`/`iv` sizing is the caller's
    /// responsibility; no padding is ever applied (Doc 9303 pads explicitly).
    private static func crypt(
        operation: Int,
        algorithm: CCAlgorithm,
        options: CCOptions,
        key: Data,
        iv: Data?,
        input: Data
    ) throws -> Data {
        var output = Data(count: input.count + kCCBlockSize3DES)
        let outputCapacity = output.count
        var moved = 0
        /// Nest the IV access so its buffer stays valid for the whole CCCrypt
        /// call (a pointer taken from `withUnsafeBytes` is invalid once the
        /// closure returns).
        func run(ivPointer: UnsafeRawPointer?) -> CCCryptorStatus {
            output.withUnsafeMutableBytes { outBuf in
                input.withUnsafeBytes { inBuf in
                    key.withUnsafeBytes { keyBuf in
                        CCCrypt(
                            CCOperation(operation),
                            algorithm,
                            options,
                            keyBuf.baseAddress, key.count,
                            ivPointer,
                            inBuf.baseAddress, input.count,
                            outBuf.baseAddress, outputCapacity,
                            &moved
                        )
                    }
                }
            }
        }
        let status: CCCryptorStatus = if let iv {
            iv.withUnsafeBytes { run(ivPointer: $0.baseAddress) }
        } else {
            run(ivPointer: nil)
        }
        guard status == kCCSuccess else { throw CipherError.failed(status) }
        return output.prefix(moved)
    }

    /// Single-DES ECB on one 8-byte block (used to build the Retail MAC).
    static func desECBEncrypt(key: Data, block: Data) throws -> Data {
        try crypt(operation: kCCEncrypt, algorithm: CCAlgorithm(kCCAlgorithmDES),
                  options: CCOptions(kCCOptionECBMode), key: key, iv: nil, input: block)
    }

    static func desECBDecrypt(key: Data, block: Data) throws -> Data {
        try crypt(operation: kCCDecrypt, algorithm: CCAlgorithm(kCCAlgorithmDES),
                  options: CCOptions(kCCOptionECBMode), key: key, iv: nil, input: block)
    }

    /// Single-DES CBC, no padding. `data.count` must be a multiple of 8.
    static func desCBCEncrypt(key: Data, iv: Data, data: Data) throws -> Data {
        try crypt(operation: kCCEncrypt, algorithm: CCAlgorithm(kCCAlgorithmDES),
                  options: 0, key: key, iv: iv, input: data)
    }

    /// Two-key 3DES CBC, no padding. `key` is the 16-byte K.enc / K.mac form;
    /// it is expanded to the 24-byte `K1‖K2‖K1` EDE key CommonCrypto expects.
    /// `data.count` must be a multiple of 8. This is BAC secure messaging's
    /// cipher.
    public static func tripleDESCBCEncrypt(key: Data, iv: Data, data: Data) throws -> Data {
        try crypt(operation: kCCEncrypt, algorithm: CCAlgorithm(kCCAlgorithm3DES),
                  options: 0, key: expand16to24(key), iv: iv, input: data)
    }

    public static func tripleDESCBCDecrypt(key: Data, iv: Data, data: Data) throws -> Data {
        try crypt(operation: kCCDecrypt, algorithm: CCAlgorithm(kCCAlgorithm3DES),
                  options: 0, key: expand16to24(key), iv: iv, input: data)
    }

    /// Expand a 16-byte 2-key value `K1‖K2` to the 24-byte `K1‖K2‖K1` EDE form.
    /// A 24-byte key is passed through unchanged.
    static func expand16to24(_ key: Data) -> Data {
        guard key.count == 16 else { return key }
        return key + key.prefix(8)
    }

    // MARK: - Retail MAC (ISO/IEC 9797-1 Algorithm 3)

    /// ISO/IEC 9797-1 MAC Algorithm 3 ("Retail MAC") with padding method 2,
    /// keyed by the 16-byte `Ka‖Kb`. This is BAC's message authentication:
    /// a single-DES CBC chain under `Ka`, finished with `E_Ka(D_Kb(last))`.
    /// Returns 8 bytes.
    public static func retailMAC(key: Data, data: Data) throws -> Data {
        precondition(key.count == 16, "Retail MAC key is 16 bytes (Ka‖Kb)")
        let ka = key.prefix(8)
        let kb = key.suffix(8)
        let padded = iso9797Method2Pad(data, blockSize: 8)

        // CBC-MAC under Ka (IV = 0); take the final ciphertext block.
        let zeroIV = Data(repeating: 0, count: 8)
        let cbc = try desCBCEncrypt(key: Data(ka), iv: zeroIV, data: padded)
        let last = Data(cbc.suffix(8))

        // Retail finish: encrypt-Ka( decrypt-Kb( last ) ).
        let step = try desECBDecrypt(key: Data(kb), block: last)
        return try desECBEncrypt(key: Data(ka), block: step)
    }

    /// ISO/IEC 9797-1 padding method 2: append `0x80`, then `0x00` up to the
    /// next block boundary. Always adds at least the `0x80`.
    public static func iso9797Method2Pad(_ data: Data, blockSize: Int) -> Data {
        var padded = data
        padded.append(0x80)
        while padded.count % blockSize != 0 {
            padded.append(0x00)
        }
        return padded
    }

    // MARK: - BAC key derivation (Doc 9303 Part 11 §9.7.1 / Appendix D.1)

    /// The 16-byte key seed `K.seed = SHA-1(MRZ_information)[0..16]`.
    public static func bacKeySeed(mrzInformation: String) -> Data {
        Data(sha1(Data(mrzInformation.utf8)).prefix(16))
    }

    /// Derive a 16-byte 3DES key from a seed and a 32-bit counter, per Doc 9303
    /// §9.7.1.1: `H = SHA-1(seed ‖ counter)`, take `H[0..16]`, adjust DES parity.
    /// Counter `1` yields K.enc, counter `2` yields K.mac.
    public static func deriveKey(seed: Data, counter: UInt32) -> Data {
        var d = seed
        d.append(contentsOf: [
            UInt8((counter >> 24) & 0xFF),
            UInt8((counter >> 16) & 0xFF),
            UInt8((counter >> 8) & 0xFF),
            UInt8(counter & 0xFF),
        ])
        let h = sha1(d).prefix(16)
        return adjustDESParity(Data(h))
    }

    /// The BAC key pair (K.enc, K.mac) for a given MRZ.
    public static func bacKeys(mrzInformation: String) -> (enc: Data, mac: Data) {
        let seed = bacKeySeed(mrzInformation: mrzInformation)
        return (deriveKey(seed: seed, counter: 1), deriveKey(seed: seed, counter: 2))
    }

    /// Set each byte's least-significant bit so the byte has odd parity, as DES
    /// keys require.
    static func adjustDESParity(_ key: Data) -> Data {
        var out = Data(count: key.count)
        for i in 0 ..< key.count {
            let b = key[key.startIndex + i]
            var ones = 0
            for bit in 0 ..< 8 where (b >> UInt8(bit)) & 1 == 1 {
                ones += 1
            }
            out[out.startIndex + i] = (ones % 2 == 0) ? (b ^ 0x01) : b
        }
        return out
    }
}
