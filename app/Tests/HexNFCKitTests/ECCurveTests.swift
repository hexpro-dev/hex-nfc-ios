@testable import HexNFCKit
import XCTest

/// Validates the from-scratch big-integer + elliptic-curve arithmetic against the
/// published domain parameters, without needing external `k·G` vectors: the base
/// point is on the curve, `n·G` is the identity (the strongest single check —
/// it exercises add/double/scalar-mul/field-inverse against the real group
/// order), `(n−1)·G = −G`, and ECDH is commutative. If any field or point
/// operation were wrong, `n·G` would not vanish.
final class ECCurveTests: XCTestCase {
    private func check(_ curve: ECCurve, _ name: String) {
        // Base point is on the curve.
        XCTAssertTrue(curve.isOnCurve(curve.g), "\(name): G not on curve")

        // 2G via double equals G + G.
        XCTAssertEqual(curve.double(curve.g), curve.add(curve.g, curve.g), "\(name): 2G mismatch")

        // n·G = point at infinity.
        let nG = curve.scalarMul(curve.n, curve.g)
        XCTAssertTrue(nG.isInfinity, "\(name): n·G is not the identity")

        // (n−1)·G = −G.
        let nMinus1 = curve.n - BigUInt(1)
        XCTAssertEqual(curve.scalarMul(nMinus1, curve.g), curve.negate(curve.g), "\(name): (n-1)G ≠ -G")

        // Encode/decode round-trip of 5·G.
        let fiveG = curve.scalarMul(BigUInt(5), curve.g)
        XCTAssertTrue(curve.isOnCurve(fiveG))
        XCTAssertEqual(curve.decode(curve.encode(fiveG)), fiveG, "\(name): encode/decode round-trip")

        // ECDH commutativity: a·(b·G) == b·(a·G).
        let a = BigUInt(0x1234_5678), b = BigUInt(0x9ABC_DEF0)
        let ab = curve.scalarMul(a, curve.scalarMul(b, curve.g))
        let ba = curve.scalarMul(b, curve.scalarMul(a, curve.g))
        XCTAssertEqual(ab, ba, "\(name): ECDH not commutative")
    }

    func test_brainpoolP256r1() {
        check(.brainpoolP256r1, "BrainpoolP256r1")
    }

    func test_nistP256() {
        check(.nistP256, "NIST P-256")
    }

    func test_brainpoolP384r1() {
        check(.brainpoolP384r1, "BrainpoolP384r1")
    }

    func test_brainpoolP512r1() {
        check(.brainpoolP512r1, "BrainpoolP512r1")
    }

    func test_nistP384() {
        check(.nistP384, "NIST P-384")
    }

    func test_nistP521() {
        check(.nistP521, "NIST P-521")
    }

    /// The modular square root (`p ≡ 3 mod 4`) round-trips a known residue for
    /// every curve: `sqrt(y_G²)² == y_G²`. A wrong `p` would break this.
    func test_fieldSqrt_roundTrips() {
        let curves: [(ECCurve, String)] = [
            (.brainpoolP256r1, "bp256"), (.brainpoolP384r1, "bp384"), (.brainpoolP512r1, "bp512"),
            (.nistP256, "p256"), (.nistP384, "p384"), (.nistP521, "p521"),
        ]
        for (curve, name) in curves {
            let ySquared = curve.fieldMul(curve.g.y, curve.g.y)
            let root = curve.fieldSqrt(ySquared)
            XCTAssertNotNil(root, "\(name): y² should be a quadratic residue")
            if let root {
                XCTAssertEqual(curve.fieldMul(root, root), ySquared, "\(name): sqrt round-trip")
            }
        }
    }

    func test_bigUInt_bytesRoundTrip() {
        let bytes = Data([0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF])
        let value = BigUInt(bytes: bytes)
        XCTAssertEqual(value.serialize(byteCount: 9), bytes)
    }

    func test_bigUInt_inverse() {
        let m = ECCurve.brainpoolP256r1.p
        let a = BigUInt(bytes: Data([0x02, 0x9A, 0x7F, 0x31, 0xCC]))
        let inv = BigUInt.inverseMod(a, m)
        XCTAssertEqual(BigUInt.mulMod(a, inv, m), BigUInt(1), "a · a⁻¹ ≠ 1 mod p")
    }
}
