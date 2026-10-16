@testable import HexNFCKit
import XCTest

/// Verifies the eMRTD crypto against the ICAO Doc 9303 Part 11 Appendix D worked
/// example (document `L898902C<`, DOB `690806`, expiry `940623`). Matching these
/// published vectors is the guarantee the BAC key derivation, two-key 3DES-CBC,
/// and Retail MAC are correct — not "trust the math".
final class EMRTDCryptoTests: XCTestCase {
    private func hex(_ s: String) -> Data {
        var data = Data()
        var index = s.startIndex
        while index < s.endIndex {
            let next = s.index(index, offsetBy: 2)
            // Fatal on purpose: the only inputs are the ICAO Doc 9303 test-vector
            // literals in this file. A nil here is a typo in one of them.
            // swiftlint:disable:next force_unwrapping
            data.append(UInt8(s[index ..< next], radix: 16)!)
            index = next
        }
        return data
    }

    // MARK: - Hashes

    func test_sha1_emptyVector() {
        XCTAssertEqual(EMRTDCrypto.sha1(Data()), hex("da39a3ee5e6b4b0d3255bfef95601890afd80709"))
    }

    func test_sha256_emptyVector() {
        XCTAssertEqual(
            EMRTDCrypto.sha256(Data()),
            hex("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        )
    }

    // MARK: - BAC key derivation (Doc 9303 Part 11 Appendix D.1)

    func test_bacKeySeed_matchesDoc9303() {
        let seed = EMRTDCrypto.bacKeySeed(mrzInformation: "L898902C<369080619406236")
        XCTAssertEqual(seed, hex("239AB9CB282DAF66231DC5A4DF6BFBAE"))
    }

    func test_bacKeys_matchDoc9303() {
        let keys = EMRTDCrypto.bacKeys(mrzInformation: "L898902C<369080619406236")
        XCTAssertEqual(keys.enc, hex("AB94FDECF2674FDFB9B391F85D7F76F2"), "K.enc")
        XCTAssertEqual(keys.mac, hex("7962D9ECE03D1ACD4C76089DCE131543"), "K.mac")
    }

    // MARK: - BAC mutual authentication (Doc 9303 Part 11 Appendix D.3)

    private let kEnc = "AB94FDECF2674FDFB9B391F85D7F76F2"
    private let kMac = "7962D9ECE03D1ACD4C76089DCE131543"

    func test_tripleDESCBC_encryptsSMessage() throws {
        let rndIC = "4608F91988702212"
        let rndIFD = "781723860C06C226"
        let kIFD = "0B795240CB7049B01C19B33E32804F0B"
        let s = hex(rndIFD + rndIC + kIFD)

        let eIFD = try EMRTDCrypto.tripleDESCBCEncrypt(
            key: hex(kEnc), iv: Data(repeating: 0, count: 8), data: s
        )
        XCTAssertEqual(
            eIFD,
            hex("72C29C2371CC9BDB65B779B8E8D37B29ECC154AA56A8799FAE2F498F76ED92F2")
        )

        // Round-trip: decrypting E.IFD recovers S.
        let back = try EMRTDCrypto.tripleDESCBCDecrypt(
            key: hex(kEnc), iv: Data(repeating: 0, count: 8), data: eIFD
        )
        XCTAssertEqual(back, s)
    }

    func test_retailMAC_matchesMIFD() throws {
        let eIFD = hex("72C29C2371CC9BDB65B779B8E8D37B29ECC154AA56A8799FAE2F498F76ED92F2")
        let mIFD = try EMRTDCrypto.retailMAC(key: hex(kMac), data: eIFD)
        XCTAssertEqual(mIFD, hex("5F1448EEA8AD90A7"))
    }

    // MARK: - Padding

    func test_iso9797Method2Pad_addsBlockWhenAligned() {
        let padded = EMRTDCrypto.iso9797Method2Pad(Data(repeating: 0xAA, count: 8), blockSize: 8)
        XCTAssertEqual(padded.count, 16)
        XCTAssertEqual(padded[8], 0x80)
    }
}
