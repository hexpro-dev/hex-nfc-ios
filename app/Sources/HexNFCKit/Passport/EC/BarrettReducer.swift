import Foundation

/// Barrett modular reduction for a fixed modulus. Replaces the bit-by-bit long
/// division in `BigUInt.mod` (which dominates EC scalar multiplication) with two
/// multiplications and a couple of subtractions, making a PACE handshake fast
/// enough to finish inside the NFC session window.
///
/// Reference: Handbook of Applied Cryptography, Algorithm 14.42.
struct BarrettReducer: Sendable {
    let m: BigUInt
    private let k: Int // limb count of the modulus
    private let mu: BigUInt // ⌊ 2^(64·2k) / m ⌋
    private let bkp1: BigUInt // 2^(64·(k+1))

    init(modulus: BigUInt) {
        m = modulus
        k = modulus.limbCount
        mu = BigUInt(1).shiftedLeft(byBits: 64 * 2 * k).divMod(modulus).quotient
        bkp1 = BigUInt(1).shiftedLeft(byBits: 64 * (k + 1))
    }

    /// Reduce `x` (which must be < m²) modulo m.
    func reduce(_ x: BigUInt) -> BigUInt {
        if x < m {
            return x
        }
        let q1 = x.dropLow(k - 1)
        let q3 = (q1 * mu).dropLow(k + 1)
        let r1 = x.low(k + 1)
        let r2 = (q3 * m).low(k + 1)
        var r = r1 >= r2 ? (r1 - r2) : (bkp1 - (r2 - r1))
        // Barrett guarantees at most two correction subtractions.
        while r >= m {
            r -= m
        }
        return r
    }

    func mulMod(_ a: BigUInt, _ b: BigUInt) -> BigUInt {
        reduce(a * b)
    }
}
