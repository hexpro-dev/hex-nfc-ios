import CommonCrypto
import Foundation

/// AES-128 ECB / CBC primitives and AES-CMAC, sized to what the NTAG424
/// DNA simulator and SUN message generator need. CommonCrypto ships with
/// iOS / macOS as a system library — using it here does not add a third-
/// party dependency.
///
/// References:
///   - NXP NT4H2421Gx (NTAG 424 DNA) datasheet rev 3.2, §11.
///   - NXP Application Note AN12196 — "NTAG 424 DNA features and hints",
///     §3 (Cryptographic Operations) for SV1/SV2 session-key derivation.
///   - RFC 4493 — "The AES-CMAC Algorithm". The CMAC implementation here
///     is verified bit-for-bit against the four vectors in §4.
public enum NTAG424Crypto {
    // MARK: - AES-128 ECB block (single 16-byte block)

    /// One-shot AES-128 ECB encrypt of a single 16-byte block. Returns 16
    /// bytes. Used as the primitive underneath CBC, CMAC, and SV derivation.
    public static func aesECBEncrypt(key: Data, block: Data) -> Data {
        precondition(key.count == 16, "AES-128 key must be 16 bytes")
        precondition(block.count == 16, "ECB block must be 16 bytes")
        var output = Data(count: 16)
        var moved = 0
        _ = output.withUnsafeMutableBytes { outBuf in
            block.withUnsafeBytes { inBuf in
                key.withUnsafeBytes { keyBuf in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode), // no PKCS7 padding
                        keyBuf.baseAddress, 16,
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

    public static func aesECBDecrypt(key: Data, block: Data) -> Data {
        precondition(key.count == 16)
        precondition(block.count == 16)
        var output = Data(count: 16)
        var moved = 0
        _ = output.withUnsafeMutableBytes { outBuf in
            block.withUnsafeBytes { inBuf in
                key.withUnsafeBytes { keyBuf in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyBuf.baseAddress, 16,
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

    // MARK: - AES-128 CBC

    /// AES-128 CBC encrypt with no padding. `data.count` must be a
    /// multiple of 16.
    public static func aesCBCEncrypt(key: Data, iv: Data, data: Data) -> Data {
        precondition(key.count == 16)
        precondition(iv.count == 16)
        precondition(data.count % 16 == 0)
        var output = Data()
        var prev = iv
        var cursor = data.startIndex
        while cursor < data.endIndex {
            let block = data.subdata(in: cursor ..< (cursor + 16))
            let xored = xor(block, prev)
            let ct = aesECBEncrypt(key: key, block: xored)
            output.append(ct)
            prev = ct
            cursor += 16
        }
        return output
    }

    public static func aesCBCDecrypt(key: Data, iv: Data, data: Data) -> Data {
        precondition(key.count == 16)
        precondition(iv.count == 16)
        precondition(data.count % 16 == 0)
        var output = Data()
        var prev = iv
        var cursor = data.startIndex
        while cursor < data.endIndex {
            let block = data.subdata(in: cursor ..< (cursor + 16))
            let pt = xor(aesECBDecrypt(key: key, block: block), prev)
            output.append(pt)
            prev = block
            cursor += 16
        }
        return output
    }

    // MARK: - AES-CMAC (RFC 4493)

    /// Compute the AES-CMAC of `data` under `key`. Returns a 16-byte tag.
    /// Verified against the four RFC 4493 §4 test vectors.
    public static func aesCMAC(key: Data, data: Data) -> Data {
        precondition(key.count == 16)

        // Subkey generation (RFC 4493 §2.3).
        let zero = Data(repeating: 0x00, count: 16)
        let l = aesECBEncrypt(key: key, block: zero)
        let k1 = subkey(from: l)
        let k2 = subkey(from: k1)

        let blockCount = max(1, (data.count + 15) / 16)
        let lastBlockIsComplete = !data.isEmpty && (data.count % 16 == 0)

        var x = Data(repeating: 0x00, count: 16)

        for i in 0 ..< (blockCount - 1) {
            let start = data.startIndex + i * 16
            let block = data.subdata(in: start ..< (start + 16))
            x = aesECBEncrypt(key: key, block: xor(x, block))
        }

        let lastStart = data.startIndex + (blockCount - 1) * 16
        let lastChunk: Data
        if lastBlockIsComplete {
            lastChunk = xor(data.subdata(in: lastStart ..< data.endIndex), k1)
        } else {
            // Pad with 0x80 followed by 0x00s up to 16 bytes, then XOR K2.
            let remaining = data.count - (blockCount - 1) * 16
            var padded = Data()
            if remaining > 0 {
                padded.append(data.subdata(in: lastStart ..< data.endIndex))
            }
            padded.append(0x80)
            while padded.count < 16 {
                padded.append(0x00)
            }
            lastChunk = xor(padded, k2)
        }
        return aesECBEncrypt(key: key, block: xor(x, lastChunk))
    }

    /// Truncated CMAC used by NTAG424 short-MAC: take the 8 even-indexed
    /// bytes (offsets 1, 3, 5, 7, 9, 11, 13, 15) of the 16-byte CMAC, per
    /// AN12196 §3.2 ("MAC truncation"). The result is 8 bytes long.
    public static func truncateCMAC(_ mac: Data) -> Data {
        precondition(mac.count == 16)
        var out = Data()
        for i in stride(from: 1, to: 16, by: 2) {
            out.append(mac[mac.startIndex + i])
        }
        return out
    }

    // MARK: - Session-key derivation (AN12196 §3.4)

    /// Compute SV1 and SV2 from RandA / RandB so the same routine drives
    /// SesAuthENCKey (via SV1) and SesAuthMACKey (via SV2).
    ///
    /// SV1 = `A5 5A 00 01 00 80 || RandA[15..14] || (RandA[13..8] XOR RandB[15..10]) || RandB[9..0] || RandA[7..0]`
    /// SV2 same shape but starts `5A A5 ...`.
    public static func sessionVector(prefix: UInt8, alt: UInt8, randA: Data, randB: Data) -> Data {
        precondition(randA.count == 16)
        precondition(randB.count == 16)
        var sv = Data()
        sv.append(prefix)
        sv.append(alt)
        sv.append(contentsOf: [0x00, 0x01, 0x00, 0x80])
        // RandA[15..14] — high two bytes
        sv.append(randA.subdata(in: 0 ..< 2))
        // RandA[13..8] XOR RandB[15..10] — next six bytes
        let aMid = randA.subdata(in: 2 ..< 8)
        let bHigh = randB.subdata(in: 0 ..< 6)
        sv.append(xor(aMid, bHigh))
        // RandB[9..0] — next ten bytes
        sv.append(randB.subdata(in: 6 ..< 16))
        // RandA[7..0] — final eight bytes
        sv.append(randA.subdata(in: 8 ..< 16))
        return sv
    }

    /// SesAuthENCKey = CMAC(KAppMaster, SV1).
    public static func deriveENCKey(appKey: Data, randA: Data, randB: Data) -> Data {
        let sv1 = sessionVector(prefix: 0xA5, alt: 0x5A, randA: randA, randB: randB)
        return aesCMAC(key: appKey, data: sv1)
    }

    /// SesAuthMACKey = CMAC(KAppMaster, SV2).
    public static func deriveMACKey(appKey: Data, randA: Data, randB: Data) -> Data {
        let sv2 = sessionVector(prefix: 0x5A, alt: 0xA5, randA: randA, randB: randB)
        return aesCMAC(key: appKey, data: sv2)
    }

    // MARK: - Helpers

    /// Bytewise XOR of two equal-length Datas.
    public static func xor(_ a: Data, _ b: Data) -> Data {
        precondition(a.count == b.count, "xor: length mismatch \(a.count) vs \(b.count)")
        var out = Data(count: a.count)
        for i in 0 ..< a.count {
            out[out.startIndex + i] = a[a.startIndex + i] ^ b[b.startIndex + i]
        }
        return out
    }

    /// RFC 4493 §2.3 subkey generation: left-shift the 16-byte input by 1
    /// and conditionally XOR `Rb = 0x87` based on the MSB.
    static func subkey(from input: Data) -> Data {
        precondition(input.count == 16)
        var out = Data(count: 16)
        let msb = input[input.startIndex] & 0x80
        var carry: UInt8 = 0
        // Iterate from LSB (last byte) to MSB so carry propagates correctly.
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

    /// Rotate `data` left by one byte. Used for RndA' / RndB' in the
    /// EV2 First protocol.
    public static func rotateLeftByOne(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        var out = Data(data.dropFirst())
        out.append(data[data.startIndex])
        return out
    }

    // MARK: - AN12196 secure-messaging primitives

    /// JAMCRC variant of CRC-32 — reflected polynomial `0xEDB88320`, init
    /// `0xFFFFFFFF`, **no final XOR**. NXP uses this in the NTAG424 DNA
    /// ChangeKey cryptogram to checksum the new key value. Returned as 4
    /// bytes in little-endian wire order (AN12196 §6.16, Table 26: NewKey
    /// `F384...B966` → CRC32 `789DFADC`).
    public static func crc32Jam(_ data: Data) -> Data {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0 ..< 8 {
                if (crc & 1) != 0 {
                    crc = (crc >> 1) ^ 0xEDB8_8320
                } else {
                    crc >>= 1
                }
            }
        }
        // No final XOR — that's what makes this JAMCRC rather than IEEE.
        return Data([
            UInt8(crc & 0xFF),
            UInt8((crc >> 8) & 0xFF),
            UInt8((crc >> 16) & 0xFF),
            UInt8((crc >> 24) & 0xFF),
        ])
    }

    /// Build the **command IV** for AN12196 secure messaging:
    ///
    ///   IVc = E(SesAuthENCKey, 0xA5 0x5A || TI || CmdCtr_LE || 0x00 × 8)
    ///
    /// Used as the CBC IV for encrypting CmdData in Full mode and for
    /// encrypting the ChangeKey cryptogram. AN12196 §5.4 Table 18.
    public static func commandIV(sesAuthENCKey: Data, ti: Data, cmdCtr: UInt16) -> Data {
        precondition(ti.count == 4, "TI is 4 bytes")
        var input = Data([0xA5, 0x5A])
        input.append(ti)
        input.append(UInt8(cmdCtr & 0xFF))
        input.append(UInt8((cmdCtr >> 8) & 0xFF))
        input.append(Data(repeating: 0x00, count: 8))
        return aesECBEncrypt(key: sesAuthENCKey, block: input)
    }

    /// Build the **response IV**:
    ///
    ///   IVr = E(SesAuthENCKey, 0x5A 0xA5 || TI || (CmdCtr+1)_LE || 0x00 × 8)
    ///
    /// The `5A A5` swap and the `CmdCtr + 1` are both prescribed by AN12196
    /// §5.4. Used as the CBC IV for decrypting EncResponseData in Full mode.
    public static func responseIV(sesAuthENCKey: Data, ti: Data, cmdCtr: UInt16) -> Data {
        precondition(ti.count == 4)
        let next = cmdCtr &+ 1
        var input = Data([0x5A, 0xA5])
        input.append(ti)
        input.append(UInt8(next & 0xFF))
        input.append(UInt8((next >> 8) & 0xFF))
        input.append(Data(repeating: 0x00, count: 8))
        return aesECBEncrypt(key: sesAuthENCKey, block: input)
    }

    /// ISO/IEC 9797-1 method 2 padding: append `0x80` then `0x00`s up to
    /// the next 16-byte boundary. **Always pads** — if `data.count` is
    /// already a multiple of 16 a full extra `0x80 0x00×15` block is
    /// appended. AN12196 §5.3 "Padding".
    public static func iso9797Pad(_ data: Data) -> Data {
        var padded = data
        padded.append(0x80)
        while padded.count % 16 != 0 {
            padded.append(0x00)
        }
        return padded
    }

    /// Strip ISO/IEC 9797-1 method 2 padding by truncating to the
    /// requested plaintext length. AN12196 senders always know the
    /// plaintext length from the command header, so this is unambiguous.
    public static func stripIso9797(_ padded: Data, plaintextLength: Int) -> Data? {
        guard plaintextLength <= padded.count else { return nil }
        return padded.prefix(plaintextLength)
    }

    /// AN12196 **command MAC** input layout:
    ///
    ///   MAC = MACt(SesAuthMACKey,
    ///              cmdINS || CmdCtr_LE || TI || CmdHeader || EncCmdData)
    ///
    /// Returns the 8-byte truncated MAC (odd-indexed bytes of the
    /// 16-byte CMAC output).
    public static func commandMAC(
        sesAuthMACKey: Data,
        cmdINS: UInt8,
        cmdCtr: UInt16,
        ti: Data,
        cmdHeader: Data,
        encCmdData: Data
    ) -> Data {
        precondition(ti.count == 4)
        var input = Data([cmdINS])
        input.append(UInt8(cmdCtr & 0xFF))
        input.append(UInt8((cmdCtr >> 8) & 0xFF))
        input.append(ti)
        input.append(cmdHeader)
        input.append(encCmdData)
        return truncateCMAC(aesCMAC(key: sesAuthMACKey, data: input))
    }

    /// AN12196 **response MAC** input layout:
    ///
    ///   MAC = MACt(SesAuthMACKey,
    ///              RC || (CmdCtr+1)_LE || TI || EncResponseData)
    ///
    /// `RC` is the response code (0x00 for success). Returns 8 bytes.
    public static func responseMAC(
        sesAuthMACKey: Data,
        responseCode: UInt8 = 0x00,
        cmdCtr: UInt16,
        ti: Data,
        encResponseData: Data = Data()
    ) -> Data {
        precondition(ti.count == 4)
        let next = cmdCtr &+ 1
        var input = Data([responseCode])
        input.append(UInt8(next & 0xFF))
        input.append(UInt8((next >> 8) & 0xFF))
        input.append(ti)
        input.append(encResponseData)
        return truncateCMAC(aesCMAC(key: sesAuthMACKey, data: input))
    }
}
