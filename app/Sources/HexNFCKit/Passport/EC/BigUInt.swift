import Foundation

/// A minimal fixed-free arbitrary-precision unsigned integer, just large enough
/// for the elliptic-curve arithmetic PACE needs over prime fields up to ~521
/// bits. Apple's crypto exposes neither the Brainpool curves eMRTDs use nor the
/// raw point operations PACE Generic Mapping requires, so this (and `ECCurve`)
/// are ours. Correctness is favoured over speed — a PACE handshake does only a
/// few thousand field operations, comfortably inside the NFC session window.
///
/// Limbs are 64-bit, little-endian (`limbs[0]` least significant); the value 0
/// is the empty limb array. Not constant-time — acceptable here because the only
/// secret is the MRZ, which is low-entropy and already known to the holder.
struct BigUInt: Equatable, Comparable, Sendable {
    private(set) var limbs: [UInt64]

    // MARK: - Construction

    init() {
        limbs = []
    }

    init(_ value: UInt64) {
        limbs = value == 0 ? [] : [value]
    }

    /// Big-endian bytes → integer.
    init(bytes: Data) {
        var result = BigUInt()
        for byte in bytes {
            result = result.shiftedLeft(byBits: 8)
            result += BigUInt(UInt64(byte))
        }
        self = result
    }

    /// Integer → big-endian bytes, left-padded/truncated to `byteCount`.
    func serialize(byteCount: Int) -> Data {
        var out = [UInt8](repeating: 0, count: byteCount)
        var value = self
        var index = byteCount - 1
        while !value.isZero, index >= 0 {
            out[index] = UInt8((value.limbs.first ?? 0) & 0xFF)
            value = value.shiftedRight(byBits: 8)
            index -= 1
        }
        return Data(out)
    }

    var isZero: Bool {
        limbs.isEmpty
    }

    var limbCount: Int {
        limbs.count
    }

    /// Keep only the low `count` 64-bit limbs (value mod 2^(64·count)).
    func low(_ count: Int) -> BigUInt {
        BigUInt.normalized(Array(limbs.prefix(count)))
    }

    /// Drop the low `count` limbs (value >> 64·count).
    func dropLow(_ count: Int) -> BigUInt {
        if count >= limbs.count {
            return BigUInt()
        }
        return BigUInt.normalized(Array(limbs.suffix(from: count)))
    }

    // MARK: - Normalisation

    private mutating func normalize() {
        while let last = limbs.last, last == 0 {
            limbs.removeLast()
        }
    }

    private static func normalized(_ limbs: [UInt64]) -> BigUInt {
        var result = BigUInt()
        result.limbs = limbs
        result.normalize()
        return result
    }

    // MARK: - Comparison

    static func < (lhs: BigUInt, rhs: BigUInt) -> Bool {
        if lhs.limbs.count != rhs.limbs.count {
            return lhs.limbs.count < rhs.limbs.count
        }
        var i = lhs.limbs.count - 1
        while i >= 0 {
            if lhs.limbs[i] != rhs.limbs[i] {
                return lhs.limbs[i] < rhs.limbs[i]
            }
            i -= 1
        }
        return false
    }

    // MARK: - Add / subtract

    /// BigUInt is Comparable but not AdditiveArithmetic (it has no negatives and
    /// no `zero` in the protocol's sense), so the compound forms do not come for
    /// free. They exist so the accumulate loops below can be written `r -= m`
    /// rather than `r = r - m`.
    static func += (lhs: inout BigUInt, rhs: BigUInt) {
        lhs = lhs + rhs
    }

    /// Requires `lhs >= rhs`, as `-` does.
    static func -= (lhs: inout BigUInt, rhs: BigUInt) {
        lhs = lhs - rhs
    }

    static func + (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        var result = [UInt64]()
        let n = max(lhs.limbs.count, rhs.limbs.count)
        result.reserveCapacity(n + 1)
        var carry: UInt64 = 0
        for i in 0 ..< n {
            let a = i < lhs.limbs.count ? lhs.limbs[i] : 0
            let b = i < rhs.limbs.count ? rhs.limbs[i] : 0
            let (s1, o1) = a.addingReportingOverflow(b)
            let (s2, o2) = s1.addingReportingOverflow(carry)
            result.append(s2)
            carry = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        if carry != 0 {
            result.append(carry)
        }
        return BigUInt.normalized(result)
    }

    /// Requires `lhs >= rhs`.
    static func - (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        var result = [UInt64]()
        result.reserveCapacity(lhs.limbs.count)
        var borrow: UInt64 = 0
        for i in 0 ..< lhs.limbs.count {
            let a = lhs.limbs[i]
            let b = i < rhs.limbs.count ? rhs.limbs[i] : 0
            let (d1, o1) = a.subtractingReportingOverflow(b)
            let (d2, o2) = d1.subtractingReportingOverflow(borrow)
            result.append(d2)
            borrow = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        return BigUInt.normalized(result)
    }

    // MARK: - Multiply

    static func * (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        if lhs.isZero || rhs.isZero {
            return BigUInt()
        }
        var result = [UInt64](repeating: 0, count: lhs.limbs.count + rhs.limbs.count)
        for i in 0 ..< lhs.limbs.count {
            var carry: UInt64 = 0
            let a = lhs.limbs[i]
            for j in 0 ..< rhs.limbs.count {
                let (hi, lo) = a.multipliedFullWidth(by: rhs.limbs[j])
                let (s1, o1) = result[i + j].addingReportingOverflow(lo)
                let (s2, o2) = s1.addingReportingOverflow(carry)
                result[i + j] = s2
                carry = hi &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
            }
            var k = i + rhs.limbs.count
            while carry != 0 {
                let (s, o) = result[k].addingReportingOverflow(carry)
                result[k] = s
                carry = o ? 1 : 0
                k += 1
            }
        }
        return BigUInt.normalized(result)
    }

    // MARK: - Bit operations

    var bitWidth: Int {
        guard let last = limbs.last else { return 0 }
        return (limbs.count - 1) * 64 + (64 - last.leadingZeroBitCount)
    }

    func bit(_ i: Int) -> Bool {
        let limb = i / 64, offset = i % 64
        guard limb < limbs.count else { return false }
        return (limbs[limb] >> UInt64(offset)) & 1 == 1
    }

    func shiftedLeft(byBits bits: Int) -> BigUInt {
        guard !isZero, bits > 0 else { return self }
        let limbShift = bits / 64, bitShift = bits % 64
        var result = [UInt64](repeating: 0, count: limbs.count + limbShift + 1)
        for i in 0 ..< limbs.count {
            let v = limbs[i]
            result[i + limbShift] |= v << UInt64(bitShift)
            if bitShift != 0 {
                result[i + limbShift + 1] |= v >> UInt64(64 - bitShift)
            }
        }
        return BigUInt.normalized(result)
    }

    func shiftedRight(byBits bits: Int) -> BigUInt {
        guard !isZero, bits > 0 else { return self }
        let limbShift = bits / 64, bitShift = bits % 64
        if limbShift >= limbs.count {
            return BigUInt()
        }
        var result = [UInt64](repeating: 0, count: limbs.count - limbShift)
        for i in 0 ..< result.count {
            var v = limbs[i + limbShift] >> UInt64(bitShift)
            if bitShift != 0, i + limbShift + 1 < limbs.count {
                v |= limbs[i + limbShift + 1] << UInt64(64 - bitShift)
            }
            result[i] = v
        }
        return BigUInt.normalized(result)
    }

    var isEven: Bool {
        (limbs.first ?? 0) & 1 == 0
    }

    func halved() -> BigUInt {
        shiftedRight(byBits: 1)
    }

    // MARK: - Division / modulo (bit-by-bit long division)

    func divMod(_ divisor: BigUInt) -> (quotient: BigUInt, remainder: BigUInt) {
        precondition(!divisor.isZero, "division by zero")
        if self < divisor {
            return (BigUInt(), self)
        }
        var quotient = BigUInt()
        var remainder = BigUInt()
        var i = bitWidth - 1
        while i >= 0 {
            remainder = remainder.shiftedLeft(byBits: 1)
            if bit(i) {
                remainder += BigUInt(1)
            }
            if remainder >= divisor {
                remainder -= divisor
                quotient = quotient.settingBit(i)
            }
            i -= 1
        }
        return (quotient, remainder)
    }

    private func settingBit(_ i: Int) -> BigUInt {
        let limb = i / 64, offset = i % 64
        var new = limbs
        while new.count <= limb {
            new.append(0)
        }
        new[limb] |= (UInt64(1) << UInt64(offset))
        return BigUInt.normalized(new)
    }

    func mod(_ m: BigUInt) -> BigUInt {
        divMod(m).remainder
    }

    // MARK: - Modular arithmetic

    static func addMod(_ a: BigUInt, _ b: BigUInt, _ m: BigUInt) -> BigUInt {
        let s = a + b
        return s >= m ? s - m : s
    }

    /// (a - b) mod m, for a, b already reduced mod m.
    static func subMod(_ a: BigUInt, _ b: BigUInt, _ m: BigUInt) -> BigUInt {
        if a >= b {
            return a - b
        }
        return m - (b - a)
    }

    static func mulMod(_ a: BigUInt, _ b: BigUInt, _ m: BigUInt) -> BigUInt {
        (a * b).mod(m)
    }

    /// Modular inverse of `a` mod odd prime `m`, via the binary extended GCD
    /// (no signed arithmetic — differences are kept reduced mod m). Returns 0 if
    /// `a` is not invertible.
    static func inverseMod(_ a: BigUInt, _ m: BigUInt) -> BigUInt {
        let a = a.mod(m)
        if a.isZero {
            return BigUInt()
        }
        var u = a, v = m
        var x1 = BigUInt(1), x2 = BigUInt()
        let one = BigUInt(1)
        while u != one && v != one {
            while u.isEven {
                u = u.halved()
                x1 = x1.isEven ? x1.halved() : (x1 + m).halved()
            }
            while v.isEven {
                v = v.halved()
                x2 = x2.isEven ? x2.halved() : (x2 + m).halved()
            }
            if u >= v {
                u -= v
                x1 = subMod(x1, x2, m)
            } else {
                v -= u
                x2 = subMod(x2, x1, m)
            }
        }
        return u == one ? x1.mod(m) : x2.mod(m)
    }
}
