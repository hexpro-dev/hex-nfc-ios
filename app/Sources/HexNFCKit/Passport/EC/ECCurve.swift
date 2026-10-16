import Foundation

/// A point on a short-Weierstrass curve `y² = x³ + ax + b (mod p)`, or the point
/// at infinity (the group identity).
struct ECPoint: Equatable, Sendable {
    var isInfinity: Bool
    var x: BigUInt
    var y: BigUInt

    static let infinity = ECPoint(isInfinity: true, x: BigUInt(), y: BigUInt())

    init(isInfinity: Bool, x: BigUInt, y: BigUInt) {
        self.isInfinity = isInfinity
        self.x = x
        self.y = y
    }

    init(x: BigUInt, y: BigUInt) {
        self.init(isInfinity: false, x: x, y: y)
    }
}

/// A prime-field short-Weierstrass curve with the group operations PACE Generic
/// Mapping needs (point add/double/scalar-mul, plus SEC1 uncompressed
/// encoding). Affine coordinates with a binary modular inverse — simple and
/// correct; fast enough for a one-shot handshake.
struct ECCurve: Sendable {
    let p: BigUInt // field prime
    let a: BigUInt
    let b: BigUInt
    let g: ECPoint // base point
    let n: BigUInt // group order
    let byteLength: Int // encoded coordinate size
    let reducer: BarrettReducer

    init(p: BigUInt, a: BigUInt, b: BigUInt, g: ECPoint, n: BigUInt, byteLength: Int) {
        self.p = p
        self.a = a
        self.b = b
        self.g = g
        self.n = n
        self.byteLength = byteLength
        reducer = BarrettReducer(modulus: p)
    }

    /// Fast modular multiply for this field (Barrett).
    private func mul(_ x: BigUInt, _ y: BigUInt) -> BigUInt {
        reducer.mulMod(x, y)
    }

    /// Field multiply, exposed for the PACE Integrated-Mapping point encoding.
    func fieldMul(_ x: BigUInt, _ y: BigUInt) -> BigUInt {
        mul(x, y)
    }

    /// Modular exponentiation `base^exponent mod p` (square-and-multiply).
    func fieldPow(_ base: BigUInt, _ exponent: BigUInt) -> BigUInt {
        if exponent.isZero {
            return BigUInt(1)
        }
        var result = BigUInt(1)
        var b = base.mod(p)
        let width = exponent.bitWidth
        var i = 0
        while i < width {
            if exponent.bit(i) {
                result = mul(result, b)
            }
            b = mul(b, b)
            i += 1
        }
        return result
    }

    /// A modular square root of `n` mod p, valid only for `p ≡ 3 (mod 4)` (true
    /// for every curve here): `r = n^((p+1)/4)`. Returns `nil` if `n` is not a
    /// quadratic residue (i.e. `r² ≠ n`), so callers can pick the residue branch.
    func fieldSqrt(_ n: BigUInt) -> BigUInt? {
        let exponent = (p + BigUInt(1)).divMod(BigUInt(4)).quotient
        let r = fieldPow(n, exponent)
        return mul(r, r) == n.mod(p) ? r : nil
    }

    // MARK: - Group operations

    func negate(_ point: ECPoint) -> ECPoint {
        if point.isInfinity {
            return point
        }
        return ECPoint(x: point.x, y: p - point.y)
    }

    func double(_ point: ECPoint) -> ECPoint {
        if point.isInfinity || point.y.isZero {
            return .infinity
        }
        // λ = (3x² + a) / (2y)
        let x2 = mul(point.x, point.x)
        let three = BigUInt.addMod(BigUInt.addMod(x2, x2, p), x2, p)
        let numerator = BigUInt.addMod(three, a, p)
        let denom = BigUInt.addMod(point.y, point.y, p)
        let lambda = mul(numerator, BigUInt.inverseMod(denom, p))
        return affineFromLambda(lambda, point, point)
    }

    func add(_ p1: ECPoint, _ p2: ECPoint) -> ECPoint {
        if p1.isInfinity {
            return p2
        }
        if p2.isInfinity {
            return p1
        }
        if p1.x == p2.x {
            // Same x: either a doubling or mutually inverse (→ infinity).
            if p1.y == p2.y {
                return double(p1)
            }
            return .infinity
        }
        // λ = (y2 - y1) / (x2 - x1)
        let numerator = BigUInt.subMod(p2.y, p1.y, p)
        let denom = BigUInt.subMod(p2.x, p1.x, p)
        let lambda = mul(numerator, BigUInt.inverseMod(denom, p))
        return affineFromLambda(lambda, p1, p2)
    }

    /// x3 = λ² − x1 − x2 ; y3 = λ(x1 − x3) − y1.
    private func affineFromLambda(_ lambda: BigUInt, _ p1: ECPoint, _ p2: ECPoint) -> ECPoint {
        let l2 = mul(lambda, lambda)
        let x3 = BigUInt.subMod(BigUInt.subMod(l2, p1.x, p), p2.x, p)
        let y3 = BigUInt.subMod(
            mul(lambda, BigUInt.subMod(p1.x, x3, p)),
            p1.y, p
        )
        return ECPoint(x: x3, y: y3)
    }

    /// `k·point`, computed in **Jacobian** coordinates so the expensive modular
    /// inverse runs once (the final affine conversion) instead of once per point
    /// operation — the difference between a sub-second and a multi-second PACE
    /// handshake on the 384/512-bit curves. Result is affine (matching `add`/
    /// `double`), so this is a transparent speed-up.
    func scalarMul(_ k: BigUInt, _ point: ECPoint) -> ECPoint {
        guard k.bitWidth > 0, !point.isInfinity else { return .infinity }
        // Jacobian accumulator (X, Y, Z); Z == 0 is the point at infinity.
        var x = BigUInt(), y = BigUInt(1), z = BigUInt()
        var i = k.bitWidth - 1
        while i >= 0 {
            (x, y, z) = jacobianDouble(x, y, z)
            if k.bit(i) {
                (x, y, z) = jacobianAddAffine(x, y, z, point.x, point.y)
            }
            i -= 1
        }
        return jacobianToAffine(x, y, z)
    }

    // MARK: - Jacobian coordinates (internal to scalar multiplication)

    /// Point doubling in Jacobian coordinates for a general `a`
    /// (`S = 4XY²`, `M = 3X² + aZ⁴`).
    private func jacobianDouble(_ x: BigUInt, _ y: BigUInt, _ z: BigUInt) -> (BigUInt, BigUInt, BigUInt) {
        if z.isZero || y.isZero {
            return (BigUInt(), BigUInt(1), BigUInt())
        }
        let xx = mul(x, x)
        let yy = mul(y, y)
        let yyyy = mul(yy, yy)
        let zz = mul(z, z)
        // S = 4·X·YY = 2·((X+YY)² − XX − YYYY).
        let xPlusYY = BigUInt.addMod(x, yy, p)
        let twoXYY = BigUInt.subMod(BigUInt.subMod(mul(xPlusYY, xPlusYY), xx, p), yyyy, p)
        let s = BigUInt.addMod(twoXYY, twoXYY, p)
        // M = 3·XX + a·Z⁴.
        let threeXX = BigUInt.addMod(BigUInt.addMod(xx, xx, p), xx, p)
        let m = BigUInt.addMod(threeXX, mul(a, mul(zz, zz)), p)
        // X' = M² − 2S.
        let twoS = BigUInt.addMod(s, s, p)
        let x3 = BigUInt.subMod(mul(m, m), twoS, p)
        // Y' = M·(S − X') − 8·YYYY.
        let twoYYYY = BigUInt.addMod(yyyy, yyyy, p)
        let fourYYYY = BigUInt.addMod(twoYYYY, twoYYYY, p)
        let eightYYYY = BigUInt.addMod(fourYYYY, fourYYYY, p)
        let y3 = BigUInt.subMod(mul(m, BigUInt.subMod(s, x3, p)), eightYYYY, p)
        // Z' = 2·Y·Z = (Y+Z)² − YY − ZZ.
        let yPlusZ = BigUInt.addMod(y, z, p)
        let z3 = BigUInt.subMod(BigUInt.subMod(mul(yPlusZ, yPlusZ), yy, p), zz, p)
        return (x3, y3, z3)
    }

    /// Mixed addition: Jacobian `(x1,y1,z1)` + affine `(x2,y2)` (madd-2007-bl).
    private func jacobianAddAffine(_ x1: BigUInt, _ y1: BigUInt, _ z1: BigUInt, _ x2: BigUInt,
                                   _ y2: BigUInt) -> (BigUInt, BigUInt, BigUInt)
    {
        if z1.isZero {
            return (x2, y2, BigUInt(1))
        }
        let z1z1 = mul(z1, z1)
        let u2 = mul(x2, z1z1)
        let s2 = mul(mul(y2, z1), z1z1)
        let h = BigUInt.subMod(u2, x1, p)
        let r0 = BigUInt.subMod(s2, y1, p)
        if h.isZero {
            if r0.isZero {
                return jacobianDouble(x1, y1, z1)
            } // P == Q
            return (BigUInt(), BigUInt(1), BigUInt()) // P == −Q → ∞
        }
        let hh = mul(h, h)
        let twoHH = BigUInt.addMod(hh, hh, p)
        let i = BigUInt.addMod(twoHH, twoHH, p) // 4·HH
        let j = mul(h, i)
        let r = BigUInt.addMod(r0, r0, p) // 2·(S2 − Y1)
        let v = mul(x1, i)
        let twoV = BigUInt.addMod(v, v, p)
        let x3 = BigUInt.subMod(BigUInt.subMod(mul(r, r), j, p), twoV, p)
        let twoY1J = { let t = mul(y1, j)
            return BigUInt.addMod(t, t, p)
        }()
        let y3 = BigUInt.subMod(mul(r, BigUInt.subMod(v, x3, p)), twoY1J, p)
        // Z3 = 2·Z1·H = (Z1+H)² − Z1Z1 − HH.
        let z1PlusH = BigUInt.addMod(z1, h, p)
        let z3 = BigUInt.subMod(BigUInt.subMod(mul(z1PlusH, z1PlusH), z1z1, p), hh, p)
        return (x3, y3, z3)
    }

    private func jacobianToAffine(_ x: BigUInt, _ y: BigUInt, _ z: BigUInt) -> ECPoint {
        if z.isZero {
            return .infinity
        }
        let zInv = BigUInt.inverseMod(z, p)
        let zInv2 = mul(zInv, zInv)
        return ECPoint(x: mul(x, zInv2), y: mul(y, mul(zInv2, zInv)))
    }

    func isOnCurve(_ point: ECPoint) -> Bool {
        if point.isInfinity {
            return true
        }
        let lhs = mul(point.y, point.y)
        let x3 = mul(mul(point.x, point.x), point.x)
        let ax = mul(a, point.x)
        let rhs = BigUInt.addMod(BigUInt.addMod(x3, ax, p), b, p)
        return lhs == rhs
    }

    // MARK: - SEC1 uncompressed encoding (0x04 ‖ X ‖ Y)

    func encode(_ point: ECPoint) -> Data {
        if point.isInfinity {
            return Data([0x00])
        }
        return Data([0x04]) + point.x.serialize(byteCount: byteLength)
            + point.y.serialize(byteCount: byteLength)
    }

    func decode(_ data: Data) -> ECPoint? {
        guard data.first == 0x04, data.count == 1 + 2 * byteLength else { return nil }
        let xBytes = data.subdata(in: 1 ..< (1 + byteLength))
        let yBytes = data.subdata(in: (1 + byteLength) ..< (1 + 2 * byteLength))
        let point = ECPoint(x: BigUInt(bytes: xBytes), y: BigUInt(bytes: yBytes))
        return isOnCurve(point) ? point : nil
    }
}

// MARK: - Named curves (eMRTD PACE standardised domain parameters)

extension ECCurve {
    private static func hex(_ s: String) -> BigUInt {
        var data = Data()
        var index = s.startIndex
        while index < s.endIndex {
            let next = s.index(index, offsetBy: 2)
            // Deliberately fatal, and deliberately not softened to `?? 0`. The
            // only inputs are the standardised domain-parameter literals below.
            // A typo in one is a programmer error every curve test catches on
            // the first run, whereas a zero byte would silently substitute a
            // different curve point and fail as a wrong PACE answer much later.
            // swiftlint:disable:next force_unwrapping
            data.append(UInt8(s[index ..< next], radix: 16)!)
            index = next
        }
        return BigUInt(bytes: data)
    }

    /// Brainpool P256r1 — the most common curve for eMRTD PACE.
    static let brainpoolP256r1 = ECCurve(
        p: hex("A9FB57DBA1EEA9BC3E660A909D838D726E3BF623D52620282013481D1F6E5377"),
        a: hex("7D5A0975FC2C3057EEF67530417AFFE7FB8055C126DC5C6CE94A4B44F330B5D9"),
        b: hex("26DC5C6CE94A4B44F330B5D9BBD77CBF958416295CF7E1CE6BCCDC18FF8C07B6"),
        g: ECPoint(
            x: hex("8BD2AEB9CB7E57CB2C4B482FFC81B7AFB9DE27E1E3BD23C23A4453BD9ACE3262"),
            y: hex("547EF835C3DAC4FD97F8461A14611DC9C27745132DED8E545C1D54C72F046997")
        ),
        n: hex("A9FB57DBA1EEA9BC3E660A909D838D718C397AA3B561A6F7901E0E82974856A7"),
        byteLength: 32
    )

    /// NIST P-256 (secp256r1).
    static let nistP256 = ECCurve(
        p: hex("FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF"),
        a: hex("FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFC"),
        b: hex("5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B"),
        g: ECPoint(
            x: hex("6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296"),
            y: hex("4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5")
        ),
        n: hex("FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551"),
        byteLength: 32
    )

    /// Brainpool P384r1 (RFC 5639).
    static let brainpoolP384r1 = ECCurve(
        p: hex("8CB91E82A3386D280F5D6F7E50E641DF152F7109ED5456B412B1DA197FB71123ACD3A729901D1A71874700133107EC53"),
        a: hex("7BC382C63D8C150C3C72080ACE05AFA0C2BEA28E4FB22787139165EFBA91F90F8AA5814A503AD4EB04A8C7DD22CE2826"),
        b: hex("04A8C7DD22CE28268B39B55416F0447C2FB77DE107DCD2A62E880EA53EEB62D57CB4390295DBC9943AB78696FA504C11"),
        g: ECPoint(
            x: hex("1D1C64F068CF45FFA2A63A81B7C13F6B8847A3E77EF14FE3DB7FCAFE0CBD10E8E826E03436D646AAEF87B2E247D4AF1E"),
            y: hex("8ABE1D7520F9C2A45CB1EB8E95CFD55262B70B29FEEC5864E19C054FF99129280E4646217791811142820341263C5315")
        ),
        n: hex("8CB91E82A3386D280F5D6F7E50E641DF152F7109ED5456B31F166E6CAC0425A7CF3AB6AF6B7FC3103B883202E9046565"),
        byteLength: 48
    )

    /// Brainpool P512r1 (RFC 5639).
    static let brainpoolP512r1 = ECCurve(
        p: hex(
            "AADD9DB8DBE9C48B3FD4E6AE33C9FC07CB308DB3B3C9D20ED6639CCA703308717D4D9B009BC66842AECDA12AE6A380E62881FF2F2D82C68528AA6056583A48F3"
        ),
        a: hex(
            "7830A3318B603B89E2327145AC234CC594CBDD8D3DF91610A83441CAEA9863BC2DED5D5AA8253AA10A2EF1C98B9AC8B57F1117A72BF2C7B9E7C1AC4D77FC94CA"
        ),
        b: hex(
            "3DF91610A83441CAEA9863BC2DED5D5AA8253AA10A2EF1C98B9AC8B57F1117A72BF2C7B9E7C1AC4D77FC94CADC083E67984050B75EBAE5DD2809BD638016F723"
        ),
        g: ECPoint(
            x: hex(
                "81AEE4BDD82ED9645A21322E9C4C6A9385ED9F70B5D916C1B43B62EEF4D0098EFF3B1F78E2D0D48D50D1687B93B97D5F7C6D5047406A5E688B352209BCB9F822"
            ),
            y: hex(
                "7DDE385D566332ECC0EABFA9CF7822FDF209F70024A57B1AA000C55B881F8111B2DCDE494A5F485E5BCA4BD88A2763AED1CA2B2FA8F0540678CD1E0F3AD80892"
            )
        ),
        n: hex(
            "AADD9DB8DBE9C48B3FD4E6AE33C9FC07CB308DB3B3C9D20ED6639CCA70330870553E5C414CA92619418661197FAC10471DB1D381085DDADDB58796829CA90069"
        ),
        byteLength: 64
    )

    /// NIST P-384 (secp384r1).
    static let nistP384 = ECCurve(
        p: hex("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFFFF0000000000000000FFFFFFFF"),
        a: hex("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFFFF0000000000000000FFFFFFFC"),
        b: hex("B3312FA7E23EE7E4988E056BE3F82D19181D9C6EFE8141120314088F5013875AC656398D8A2ED19D2A85C8EDD3EC2AEF"),
        g: ECPoint(
            x: hex("AA87CA22BE8B05378EB1C71EF320AD746E1D3B628BA79B9859F741E082542A385502F25DBF55296C3A545E3872760AB7"),
            y: hex("3617DE4A96262C6F5D9E98BF9292DC29F8F41DBD289A147CE9DA3113B5F0B8C00A60B1CE1D7E819D7A431D7C90EA0E5F")
        ),
        n: hex("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFC7634D81F4372DDF581A0DB248B0A77AECEC196ACCC52973"),
        byteLength: 48
    )

    /// NIST P-521 (secp521r1). Coordinates are 66 bytes; the top byte carries a
    /// single significant bit.
    static let nistP521 = ECCurve(
        p: hex(
            "01FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"
        ),
        a: hex(
            "01FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFC"
        ),
        b: hex(
            "0051953EB9618E1C9A1F929A21A0B68540EEA2DA725B99B315F3B8B489918EF109E156193951EC7E937B1652C0BD3BB1BF073573DF883D2C34F1EF451FD46B503F00"
        ),
        g: ECPoint(
            x: hex(
                "00C6858E06B70404E9CD9E3ECB662395B4429C648139053FB521F828AF606B4D3DBAA14B5E77EFE75928FE1DC127A2FFA8DE3348B3C1856A429BF97E7E31C2E5BD66"
            ),
            y: hex(
                "011839296A789A3BC0045C8A5FB42C7D1BD998F54449579B446817AFBD17273E662C97EE72995EF42640C550B9013FAD0761353C7086A272C24088BE94769FD16650"
            )
        ),
        n: hex(
            "01FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFA51868783BF2F966B7FCC0148F709A5D03BB5C9B8899C47AEBB6FB71E91386409"
        ),
        byteLength: 66
    )

    /// Resolve a curve from its ICAO PACE standardised-domain-parameter id
    /// (`PACEInfo.parameterId`, BSI TR-03110 Part 3). These are the curves
    /// eMRTDs actually use for PACE.
    static func standardizedDomainParameter(_ id: Int) -> ECCurve? {
        switch id {
        case 12: .nistP256
        case 13: .brainpoolP256r1
        case 15: .nistP384
        case 16: .brainpoolP384r1
        case 17: .brainpoolP512r1
        case 18: .nistP521
        default: nil
        }
    }
}
