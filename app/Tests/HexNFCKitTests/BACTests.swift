@testable import HexNFCKit
import XCTest

/// End-to-end BAC handshake against the ICAO Doc 9303 Part 11 Appendix D worked
/// example: build EXTERNAL AUTHENTICATE from fixed randoms, then process the
/// card's fixed reply and confirm the derived session keys and SSC match D.4.
final class BACTests: XCTestCase {
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

    private let mrz = "L898902C<369080619406236"
    private let rndIC = "4608F91988702212"
    private let rndIFD = "781723860C06C226"
    private let kIFD = "0B795240CB7049B01C19B33E32804F0B"

    func test_buildExternalAuthenticate_matchesDoc9303() throws {
        let (cmd, kEnc, kMac) = try BAC.buildExternalAuthenticate(
            mrzInformation: mrz, rndIC: hex(rndIC), rndIFD: hex(rndIFD), kIFD: hex(kIFD)
        )
        XCTAssertEqual(kEnc, hex("AB94FDECF2674FDFB9B391F85D7F76F2"))
        XCTAssertEqual(kMac, hex("7962D9ECE03D1ACD4C76089DCE131543"))
        XCTAssertEqual(
            cmd,
            hex("72C29C2371CC9BDB65B779B8E8D37B29ECC154AA56A8799FAE2F498F76ED92F2"
                + "5F1448EEA8AD90A7")
        )
    }

    func test_completeMutualAuthentication_derivesSession() throws {
        // The card's EXTERNAL AUTHENTICATE reply from Appendix D.3 (E.IC ‖ M.IC).
        let responseData = hex(
            "46B9342A41396CD7386BF5803104D7CEDC122B9132139BAF2EEDC94EE178534F"
                + "2F2D235D074D7449"
        )
        let (_, kEnc, kMac) = try BAC.buildExternalAuthenticate(
            mrzInformation: mrz, rndIC: hex(rndIC), rndIFD: hex(rndIFD), kIFD: hex(kIFD)
        )
        let session = try BAC.completeMutualAuthentication(
            responseData: responseData,
            rndIC: hex(rndIC), rndIFD: hex(rndIFD), kIFD: hex(kIFD),
            kEnc: kEnc, kMac: kMac
        )
        XCTAssertEqual(session.ksEnc, hex("979EC13B1CBFE9DCD01AB0FED307EAE5"))
        XCTAssertEqual(session.ksMac, hex("F1CB1F1FB5ADF208806B89DC579DC1F8"))
        XCTAssertEqual(session.ssc, hex("887022120C06C226"))
    }

    func test_completeMutualAuthentication_rejectsBadMAC() throws {
        let bad = hex(
            "46B9342A41396CD7386BF5803104D7CEDC122B9132139BAF2EEDC94EE178534F"
                + "0000000000000000"
        )
        let (_, kEnc, kMac) = try BAC.buildExternalAuthenticate(
            mrzInformation: mrz, rndIC: hex(rndIC), rndIFD: hex(rndIFD), kIFD: hex(kIFD)
        )
        XCTAssertThrowsError(try BAC.completeMutualAuthentication(
            responseData: bad, rndIC: hex(rndIC), rndIFD: hex(rndIFD), kIFD: hex(kIFD),
            kEnc: kEnc, kMac: kMac
        ))
    }
}
