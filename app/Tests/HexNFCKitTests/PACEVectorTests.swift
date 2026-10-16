@testable import HexNFCKit
import XCTest

/// PACE crypto verified against the **ICAO Doc 9303 Part 11 worked examples**
/// (Appendix G = Generic Mapping, Appendix H = Integrated Mapping; both use
/// BrainpoolP256r1 + AES-128). These are the published, non-secret test vectors,
/// and they pin down the pieces a simulator round-trip cannot catch (both sides
/// would share any mistake): the K_π / KDF derivation, the Integrated-Mapping
/// pseudo-random function and point encoding, the session-key derivation, and —
/// crucially — that the CMAC is truncated to its **first 8 bytes**.
final class PACEVectorTests: XCTestCase {
    private func h(_ s: String) -> Data {
        let clean = s.replacingOccurrences(of: " ", with: "")
        var data = Data()
        var i = clean.startIndex
        while i < clean.endIndex {
            let j = clean.index(i, offsetBy: 2)
            // Fatal on purpose: the only inputs are the ICAO Doc 9303 test-vector
            // literals in this file. A nil here is a typo in one of them.
            // swiftlint:disable:next force_unwrapping
            data.append(UInt8(clean[i ..< j], radix: 16)!)
            i = j
        }
        return data
    }

    // OID value bytes for the two protocols (App G / App H).
    private let gmOID = "04 00 7F 00 07 02 02 04 02 02"
    private let imOID = "04 00 7F 00 07 02 02 04 04 02"

    // MARK: - Password key K_π (shared by both examples)

    func test_passwordKey_matchesDoc9303() {
        let mrzInformation = "T22000129364081251010318"
        // K = SHA-1(MRZ_information).
        XCTAssertEqual(
            EMRTDCrypto.sha1(Data(mrzInformation.utf8)),
            h("7E2D2A41 C74EA0B3 8CD36F86 3939BFA8 E9032AAD")
        )
        // K_π = KDF(K, 3) truncated to 16 bytes (AES-128 → SHA-1 KDF).
        XCTAssertEqual(
            PACE.passwordKey(mrzInformation: mrzInformation, keyBytes: 16),
            h("89DED1B2 6624EC1E 634C1989 302849DD")
        )
    }

    // MARK: - Integrated Mapping (App H.1)

    func test_integratedMapping_matchesAppH1() throws {
        let curve = ECCurve.brainpoolP256r1
        let s = h("2923BE84 E16CD6AE 529049F1 F1BBE9EB")
        let t = h("5DD4CBFC 96F5453B 130D890A 1CDBAE32")

        // R(s,t) — 48 bytes.
        XCTAssertEqual(
            PACE.pseudoRandomR(curve: curve, nonce: s, key: t),
            h(
                "E4447E2D FB3586BA C05DDB00 156B57FB B2179A39 49294C97 25418980 0C517BAA 8DA0FF39 7ED8C445 D3E421E4 FEB57322"
            )
        )
        // Rp(s,t) = int(R) mod p.
        XCTAssertEqual(
            PACE.pseudoRandomFieldElement(curve: curve, nonce: s, key: t).serialize(byteCount: 32),
            h("A2F8FF2D F50E52C6 599F386A DCB595D2 29F6A167 ADE2BE5F 2C3296AD D5B7430E")
        )

        // Mapped generator Ĝ.
        let g = try PACE.integratedMappedGenerator(curve: curve, nonce: s, terminalNonce: t)
        XCTAssertTrue(curve.isOnCurve(g))
        XCTAssertEqual(
            g.x.serialize(byteCount: 32),
            h("8E82D315 59ED0FDE 92A4D049 8ADD3C23 BABA94FB 77691E31 E90AEA77 FB17D427")
        )
        XCTAssertEqual(
            g.y.serialize(byteCount: 32),
            h("4C1AE14B D0C3DBAC 0C871B7F 36081693 64437CA3 0AC243A0 89D3F266 C1E60FAD")
        )
    }

    // MARK: - Session-key derivation

    func test_sessionKeys_genericMapping_appG() {
        let sharedX = h("28768D20 701247DA E81804C9 E780EDE5 82A9996D B4A31502 0B273319 7DB84925")
        let keys = PACE.sessionKeys(sharedSecretX: sharedX, keyBytes: 16)
        XCTAssertEqual(keys.enc, h("F5F0E35C 0D7161EE 6724EE51 3A0D9A7F"))
        XCTAssertEqual(keys.mac, h("FE251C78 58B356B2 4514B3BD 5F4297D1"))
    }

    func test_sessionKeys_integratedMapping_appH() {
        let sharedX = h("4F150FDE 1D4F0E38 E95017B8 91BAE171 33A0DF45 B0D3E18B 60BA7BEA FDC2C713")
        let keys = PACE.sessionKeys(sharedSecretX: sharedX, keyBytes: 16)
        XCTAssertEqual(keys.enc, h("0D3FEB33 251A6370 893D62AE 8DAAF51B"))
        XCTAssertEqual(keys.mac, h("B01E89E3 D9E8719E 586B50B4 A7506E0B"))
    }

    // MARK: - Authentication tokens (proves first-8-byte CMAC truncation)

    func test_authToken_genericMapping_appG() {
        let ksMac = h("FE251C78 58B356B2 4514B3BD 5F4297D1")
        // T_IFD MACs the chip's key-agreement public key.
        let chipPK = h("04 9E880F84 2905B8B3 181F7AF7 CAA9F0EF B743847F 44A306D2 D28C1D9E C65DF6DB "
            + "7764B222 77A2EDDC 3C265A9F 018F9CB8 52E111B7 68B32690 4B59A019 3776F094")
        XCTAssertEqual(
            PACE.authToken(macKey: ksMac, oid: h(gmOID), encodedPublicPoint: chipPK),
            h("C2B0BD78 D94BA866")
        )
        // T_IC MACs the terminal's key-agreement public key.
        let terminalPK = h("04 2DB7A64C 0355044E C9DF1905 14C625CB A2CEA487 54887122 F3A5EF0D 5EDD301C "
            + "3556F3B3 B186DF10 B857B58F 6A7EB80F 20BA5DC7 BE1D43D9 BF850149 FBB36462")
        XCTAssertEqual(
            PACE.authToken(macKey: ksMac, oid: h(gmOID), encodedPublicPoint: terminalPK),
            h("3ABB9674 BCE93C08")
        )
    }

    func test_authToken_integratedMapping_appH() {
        let kMac = h("B01E89E3 D9E8719E 586B50B4 A7506E0B")
        // T_IC MACs the terminal's public key PK_IFD.
        let pkIFD = h("04 89CBA23F FE96AA18 D824627C 3E934E54 A9FD0B87 A95D1471 DC1C0ABF DCD640D4 "
            + "6755DE9B 7B778280 B6BEBD57 439ADFEB 0E21FD4E D6DF4257 8C13418A 59B34C37")
        XCTAssertEqual(
            PACE.authToken(macKey: kMac, oid: h(imOID), encodedPublicPoint: pkIFD),
            h("75D4D96E 8D5B0308")
        )
        // T_IFD MACs the chip's public key PK_IC.
        let pkIC = h("04 67F78E5F 7F768608 2B293E8D 087E0569 16D0F74B C01A5F89 57D0DE45 691E51E8 "
            + "932B69A9 62B52A09 85AD2C0A 271EE6A1 3A8ADDDC D1A3A994 B9DED257 F4D22753")
        XCTAssertEqual(
            PACE.authToken(macKey: kMac, oid: h(imOID), encodedPublicPoint: pkIC),
            h("450F02B8 6F6A0909")
        )
    }
}
