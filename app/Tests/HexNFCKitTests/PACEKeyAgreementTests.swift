@testable import HexNFCKit
import XCTest

/// Validates the PACE ECDH Generic Mapping key agreement by playing both sides
/// (reader + card) and confirming they derive identical session keys and
/// cross-verifying authentication tokens. This exercises the whole PACE crypto
/// core — password KDF, the mapped generator `s·G + H`, the second ECDH, session
/// key derivation, and the CMAC tokens — without needing a full APDU simulator.
/// (The exact derivation constants still need Doc 9303 vector / live
/// confirmation before PACE is trusted on real documents.)
final class PACEKeyAgreementTests: XCTestCase {
    private func bu(_ bytes: [UInt8]) -> BigUInt {
        BigUInt(bytes: Data(bytes))
    }

    func test_paceGM_bothSidesAgree() {
        let curve = ECCurve.brainpoolP256r1
        let oid = Data([0x04, 0x00, 0x7F, 0x00, 0x07, 0x02, 0x02, 0x04, 0x02, 0x02])

        // Password key is deterministic from the MRZ.
        let kpi = PACE.passwordKey(mrzInformation: "L898902C<369080619406236")
        XCTAssertEqual(kpi.count, 16)

        // The decrypted nonce (card picks it; reader recovers it via K_π).
        let s = Data([UInt8](0x01 ... 0x10))

        // --- First ECDH (mapping): reader x1·G, card y1·G ---
        let x1 = bu([0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99])
        let y1 = bu([0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6, 0x07, 0x18])
        let bigX1 = curve.scalarMul(x1, curve.g)
        let bigY1 = curve.scalarMul(y1, curve.g)
        let hReader = curve.scalarMul(x1, bigY1)
        let hCard = curve.scalarMul(y1, bigX1)
        XCTAssertEqual(hReader, hCard, "first ECDH shared point mismatch")

        let gReader = PACE.mappedGenerator(curve: curve, nonce: s, sharedH: hReader)
        let gCard = PACE.mappedGenerator(curve: curve, nonce: s, sharedH: hCard)
        XCTAssertEqual(gReader, gCard, "mapped generator mismatch")
        XCTAssertTrue(curve.isOnCurve(gReader))

        // --- Second ECDH (on the mapped generator) ---
        let x2 = bu([0x0F, 0x1E, 0x2D, 0x3C, 0x4B, 0x5A, 0x69, 0x78])
        let y2 = bu([0x87, 0x96, 0xA5, 0xB4, 0xC3, 0xD2, 0xE1, 0xF0])
        let bigX2 = curve.scalarMul(x2, gReader)
        let bigY2 = curve.scalarMul(y2, gCard)
        let kReader = curve.scalarMul(x2, bigY2)
        let kCard = curve.scalarMul(y2, bigX2)
        XCTAssertEqual(kReader, kCard, "second ECDH shared secret mismatch")

        // --- Session keys from the shared secret's x-coordinate ---
        let (encR, macR) = PACE.sessionKeys(sharedSecretX: kReader.x.serialize(byteCount: 32))
        let (encC, macC) = PACE.sessionKeys(sharedSecretX: kCard.x.serialize(byteCount: 32))
        XCTAssertEqual(encR, encC, "KSenc mismatch")
        XCTAssertEqual(macR, macC, "KSmac mismatch")

        // --- Tokens: each side MACs the other's mapped public key ---
        let tIFD = PACE.authToken(macKey: macR, oid: oid, encodedPublicPoint: curve.encode(bigY2))
        let tIFDCardCheck = PACE.authToken(macKey: macC, oid: oid, encodedPublicPoint: curve.encode(bigY2))
        XCTAssertEqual(tIFD, tIFDCardCheck, "reader token not verifiable by card")
        XCTAssertEqual(tIFD.count, 8)
    }

    func test_parseInfo_extractsBrainpoolPACE() {
        // A minimal EF.CardAccess: SET { SEQUENCE { OID(id-PACE-ECDH-GM-AES128),
        // INTEGER version=2, INTEGER parameterId=13 } }.
        let oid = Data([0x06, 0x0A, 0x04, 0x00, 0x7F, 0x00, 0x07, 0x02, 0x02, 0x04, 0x02, 0x02])
        let version = Data([0x02, 0x01, 0x02])
        let parameterId = Data([0x02, 0x01, 0x0D]) // 13 = Brainpool P256r1
        let seqBody = oid + version + parameterId
        let seq = Data([0x30, UInt8(seqBody.count)]) + seqBody
        let set = Data([0x31, UInt8(seq.count)]) + seq

        let info = PACE.parseInfo(set)
        XCTAssertEqual(info?.parameterId, 13)
        XCTAssertNotNil(info?.curve)
    }
}
