@testable import HexNFCKit
import XCTest

/// Verifies BAC 3DES secure messaging against the ICAO Doc 9303 Part 11
/// Appendix D.4 worked example: the exact protected SELECT EF.COM and READ
/// BINARY commands, and the exact protected responses, driven by one session so
/// the send-sequence-counter progression is exercised end to end.
final class SecureMessagingTests: XCTestCase {
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

    private func makeSession() -> TDESSecureMessaging {
        TDESSecureMessaging(
            ksEnc: hex("979EC13B1CBFE9DCD01AB0FED307EAE5"),
            ksMac: hex("F1CB1F1FB5ADF208806B89DC579DC1F8"),
            ssc: hex("887022120C06C226")
        )
    }

    func test_bacSecureMessaging_fullSequence() throws {
        let sm = makeSession()

        // 1. Protect SELECT EF.COM (00 A4 02 0C 02 01 1E).
        let protectedSelect = try sm.protect(hex("00A4020C02011E"))
        XCTAssertEqual(
            protectedSelect,
            hex("0CA4020C158709016375432908C044F68E08BF8B92D635FF24F800")
        )

        // 2. Unprotect its response — empty data, status 90 00.
        let selectResponse = try sm.unprotect(hex("990290008E08FA855A5D4C50A8ED9000"))
        XCTAssertEqual(selectResponse, hex("9000"))

        // 3. Protect READ BINARY of the first 4 bytes (00 B0 00 00 04).
        let protectedRead = try sm.protect(hex("00B0000004"))
        XCTAssertEqual(protectedRead, hex("0CB000000D9701048E08ED6705417E96BA5500"))

        // 4. Unprotect its response — decrypts to the first 4 EF.COM bytes.
        let readResponse = try sm.unprotect(hex("8709019FF0EC34F9922651990290008E08AD55CC17140B2DED9000"))
        XCTAssertEqual(readResponse, hex("60145F019000"))
    }

    func test_unprotect_detectsTamperedMAC() throws {
        let sm = makeSession()
        _ = try sm.protect(hex("00A4020C02011E"))
        // Flip a byte in the MAC — verification must fail.
        XCTAssertThrowsError(try sm.unprotect(hex("990290008E08FA855A5D4C50A8EE9000"))) { error in
            XCTAssertEqual(error as? SecureMessagingError, .macMismatch)
        }
    }
}
