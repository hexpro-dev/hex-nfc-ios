import Foundation

/// PACE Integrated Mapping (ECDH) — ICAO Doc 9303 Part 11 §4.4.3.3.2 + Appendix B.2.
///
/// Unlike Generic Mapping (which runs a fresh ephemeral ECDH to derive the mapped
/// generator), Integrated Mapping derives it *directly* from the decrypted nonce
/// `s` and the terminal-chosen nonce `t`, with no key exchange: a pseudo-random
/// function `R` expands `(s, t)` to a field element `Rp`, and a point-encoding
/// `f_G` (a square-root SWU map, valid for `p ≡ 3 mod 4`) maps it onto the curve.
///
/// Both `R`/`Rp` and `f_G` are transcribed from ICAO Doc 9303 Part 11 and checked
/// byte-for-byte against the Part 11 Appendix H.1 worked example
/// (BrainpoolP256r1 / AES-128) in `PACEIntegratedMappingTests`. The `c0`/`c1`
/// PRF constants are the ICAO values (identical in JMRTD).
extension PACE {
    // PRF constants for the two block-output sizes l ∈ {128, 256} bits.
    private static let imC0_128 = hexData("A668892A7C41E3CA739F40B057D85904")
    private static let imC1_128 = hexData("A4E136AC725F738B01C1F60217C188AD")
    private static let imC0_256 = hexData("D463D65234124EF7897054986DCA0A174E28DF758CBAA03F240616414D5A1676")
    private static let imC1_256 = hexData("54BD7255F0AAF831BEC3423FCF39D69B6CBF066677D0FAAE5AADD99DF8E53517")

    /// The Integrated-Mapping mapped generator `Ĝ = f_G(Rp(s, t))`.
    static func integratedMapping(curve: ECCurve, nonce s: Data, terminalNonce t: Data) throws -> ECPoint {
        // The square-root point encoding requires p ≡ 3 (mod 4) — true for every
        // eMRTD PACE curve (NIST P-224, id 10, is the sole exception and is not
        // one we support).
        guard curve.p.mod(BigUInt(4)) == BigUInt(3) else { throw Failure.unsupportedMapping }
        let tt = pseudoRandomFieldElement(curve: curve, nonce: s, key: t)
        return map2Point(curve: curve, fieldElement: tt)
    }

    // MARK: - Pseudo-random function R / Rp

    /// `R(s, t)`: an AES-based expansion to at least `bitlen(p) + 64` bits (ICAO
    /// §4.4.3.3.2). `t` is the AES key (k/8 bytes); `s` is one block-output (l/8
    /// bytes). The block-output size `l` is 128 bits for AES-128 and 256 bits for
    /// AES-192/256, so those run a two-block CBC. Only the key material is
    /// truncated to `k` bits between rounds; the output blocks never are.
    static func pseudoRandomR(curve: ECCurve, nonce s: Data, key t: Data) -> Data {
        let keyBytes = t.count // k / 8
        let lBytes = keyBytes <= 16 ? 16 : 32 // l / 8
        let (c0, c1) = lBytes == 16 ? (imC0_128, imC1_128) : (imC0_256, imC1_256)
        let iv = Data(repeating: 0, count: 16) // CBC IV is one 128-bit block

        let lBits = lBytes * 8
        let blocks = (curve.p.bitWidth + 64 + lBits - 1) / lBits

        func truncKey(_ x: Data) -> Data {
            Data(x.prefix(keyBytes))
        }

        var key = truncKey(EMRTDCrypto.aesCBCEncrypt(key: t, iv: iv, data: s))
        var out = Data()
        for _ in 0 ..< blocks {
            out.append(EMRTDCrypto.aesCBCEncrypt(key: key, iv: iv, data: c1)) // output block x_i
            key = truncKey(EMRTDCrypto.aesCBCEncrypt(key: key, iv: iv, data: c0)) // advance key
        }
        return out
    }

    /// `Rp(s, t) = int(R(s, t)) mod p`.
    static func pseudoRandomFieldElement(curve: ECCurve, nonce s: Data, key t: Data) -> BigUInt {
        BigUInt(bytes: pseudoRandomR(curve: curve, nonce: s, key: t)).mod(curve.p)
    }

    // MARK: - Point encoding f_G (ICAO Appendix B.2, affine)

    /// Map a field element `tt` to a curve point (short-Weierstrass, `p ≡ 3 mod 4`,
    /// cofactor 1). This is the square-root SWU encoding of ICAO Appendix B.2.
    static func map2Point(curve: ECCurve, fieldElement tt: BigUInt) -> ECPoint {
        let p = curve.p, a = curve.a, b = curve.b
        let one = BigUInt(1)
        func neg(_ v: BigUInt) -> BigUInt {
            v.isZero ? v : p - v
        }

        let ttp = tt.mod(p)
        let alpha = neg(curve.fieldMul(ttp, ttp)) // α = -tt²
        let alphaSum = BigUInt.addMod(alpha, curve.fieldMul(alpha, alpha), p) // α + α²
        let onePlus = BigUInt.addMod(one, alphaSum, p) // 1 + α + α²
        let denomInv = BigUInt.inverseMod(curve.fieldMul(a, alphaSum), p) // (a(α+α²))⁻¹
        let x2 = neg(curve.fieldMul(b, curve.fieldMul(onePlus, denomInv))) // X2
        let x3 = curve.fieldMul(alpha, x2) // X3 = α·X2

        // h2 = X2³ + a·X2 + b.
        let h2 = BigUInt.addMod(
            BigUInt.addMod(curve.fieldMul(curve.fieldMul(x2, x2), x2), curve.fieldMul(a, x2), p),
            b, p
        )
        let tt3 = curve.fieldMul(curve.fieldMul(ttp, ttp), ttp) // tt³
        let u = curve.fieldMul(tt3, h2) // U = tt³·h2

        // A = h2^(p − 1 − (p+1)/4); if A²·h2 == 1, h2 is a QR → take X2, else X3.
        let exponent = (p - one) - (p + one).divMod(BigUInt(4)).quotient
        let capitalA = curve.fieldPow(h2, exponent)
        if curve.fieldMul(curve.fieldMul(capitalA, capitalA), h2) == one {
            return ECPoint(x: x2, y: curve.fieldMul(capitalA, h2))
        } else {
            return ECPoint(x: x3, y: curve.fieldMul(capitalA, u))
        }
        // Cofactor is 1 for every supported curve → no cofactor multiplication.
    }

    private static func hexData(_ s: String) -> Data {
        var data = Data()
        var index = s.startIndex
        while index < s.endIndex {
            let next = s.index(index, offsetBy: 2)
            // Fatal on purpose; see the same helper in `ECCurve.swift`. Inputs
            // are the ICAO Doc 9303 Part 11 test-vector literals only.
            // swiftlint:disable:next force_unwrapping
            data.append(UInt8(s[index ..< next], radix: 16)!)
            index = next
        }
        return data
    }
}
