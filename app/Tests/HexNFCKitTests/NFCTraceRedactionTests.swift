import Foundation
import HexNFCKit
import XCTest

/// What may and may not reach the trace.
///
/// The trace goes two places a user can see and copy: `os_log` lines on subsystem
/// `pro.hex.nfc`, and the in-app "All NFC traffic" tab, which exists to be pasted
/// into a bug report. CLAUDE.md is unconditional about it: never unmask a frame
/// that carries a key or password.
///
/// This file exists because the rule had no test. It lived inside
/// `CoreNFCSession.swift`, which is `#if os(iOS)` from its first line, and
/// `swift test` on the macOS host skips such files whole, so CI compiled the rule
/// and never once evaluated it. That is how the WRITE that puts a Type-2 password
/// on a tag stayed unmasked while the `PWD_AUTH` that presents it was masked from
/// the start: the presenting frame was easy to notice and the storing frame was
/// not, and nothing was watching.
final class NFCTraceRedactionTests: XCTestCase {
    private let ntag213 = ChipCatalog.profile(for: .ntag213)
    private let ntag216 = ChipCatalog.profile(for: .ntag216)
    private let ultralightC = ChipCatalog.profile(for: .mifareUltralightC)

    private func isSecret(_ bytes: [UInt8], _ chip: ChipProfile?) -> Bool {
        NFCTraceRedaction.isSecretFrame(Data(bytes), chip: chip)
    }

    // MARK: - Type-2 credentials

    /// Presenting the password. Masked since the beginning, and the reason the
    /// storing frame's exposure went unnoticed for so long.
    func test_passwordAuth_isMasked() {
        XCTAssertTrue(isSecret([0x1B, 0xA1, 0xB2, 0xC3, 0xD4], ntag213))
    }

    /// Storing it. `A2 <pwdPage> <4 password bytes>` puts the user's password on
    /// the tag in the clear, because a Type-2 chip has no secure channel for it.
    /// Unmasked, the whole password appeared in a log line the app invites people
    /// to paste into a bug report.
    func test_theWriteThatStoresThePassword_isMasked() throws {
        let layout = try XCTUnwrap(Type2ConfigLayout.for(.ntag213))
        XCTAssertTrue(
            isSecret([0xA2, UInt8(layout.pwdPage), 0xA1, 0xB2, 0xC3, 0xD4], ntag213),
            "the PWD page write carries the password itself"
        )
        XCTAssertTrue(
            isSecret([0xA2, UInt8(layout.packPage), 0x1E, 0x2F, 0x00, 0x00], ntag213),
            "the PACK is what the tag answers a successful authentication with, so it is half the pair"
        )
    }

    /// The page numbers are per chip, so the rule has to be too. An NTAG213's PWD
    /// page is ordinary user memory on an NTAG216, and masking it there would
    /// blind the traffic view for nothing.
    func test_theSamePageOnAnotherChip_isNotMasked() throws {
        let small = try XCTUnwrap(Type2ConfigLayout.for(.ntag213))
        let large = try XCTUnwrap(Type2ConfigLayout.for(.ntag216))
        XCTAssertNotEqual(small.pwdPage, large.pwdPage, "the premise of this test")
        XCTAssertFalse(
            isSecret([0xA2, UInt8(small.pwdPage), 0xDE, 0xAD, 0xBE, 0xEF], ntag216),
            "on an NTAG216 that page is user memory"
        )
    }

    /// An ordinary data write must stay readable, or the trace stops being useful
    /// for the thing it is for.
    func test_anOrdinaryPageWrite_isNotMasked() {
        XCTAssertFalse(isSecret([0xA2, 0x04, 0x03, 0x00, 0xFE, 0x00], ntag213))
        XCTAssertFalse(isSecret([0x30, 0x04], ntag213), "a READ carries nothing")
    }

    // MARK: - Ultralight C

    /// The 3DES handshake legs are cryptograms computed under the key. Not the
    /// key, but the input to any offline attack on it.
    func test_ultralightCHandshake_isMasked() {
        XCTAssertTrue(isSecret([0x1A, 0x00], ultralightC))
        XCTAssertTrue(isSecret([0xAF] + Array(repeating: 0x5A, count: 16), ultralightC))
    }

    /// The key pages go out in plaintext, and mean something else entirely on a
    /// larger NTAG die.
    func test_ultralightCKeyPages_areMaskedOnlyOnThatChip() {
        for page in UltralightCLayout.keyPages {
            XCTAssertTrue(
                isSecret([0xA2, UInt8(page), 0x01, 0x02, 0x03, 0x04], ultralightC),
                "page \(page) carries a quarter of the 3DES key"
            )
            XCTAssertFalse(
                isSecret([0xA2, UInt8(page), 0x01, 0x02, 0x03, 0x04], ntag216),
                "the same page is user memory on an NTAG216"
            )
        }
    }

    // MARK: - Type-4 and Type-5

    func test_ntag424AuthAndChangeKey_areMasked() {
        XCTAssertTrue(isSecret([0x90, 0x71, 0x00, 0x00], ntag213), "AuthenticateEV2First")
        XCTAssertTrue(isSecret([0x90, 0xAF, 0x00, 0x00], ntag213), "the second leg")
        XCTAssertTrue(isSecret([0x90, 0xC4, 0x00, 0x00], ntag213), "ChangeKey carries the encrypted new key")
    }

    /// Deliberately readable. Its CmdData is access rights, not key material, and
    /// seeing the whole frame is what diagnoses a real-silicon PARAMETER_ERROR.
    func test_changeFileSettings_isDeliberatelyNotMasked() {
        XCTAssertFalse(isSecret([0x90, 0x5F, 0x00, 0x00], ntag213))
    }

    func test_slixPasswordCommands_areMasked() {
        for opcode in [0xB3, 0xB4, 0xB9, 0xBA] {
            XCTAssertTrue(isSecret([0x02, UInt8(opcode), 0x04], nil), "SLIX \(String(opcode, radix: 16))")
        }
    }

    func test_epassportAccessControl_isMasked() {
        XCTAssertTrue(isSecret([0x00, 0x82, 0x00, 0x00], nil), "EXTERNAL AUTHENTICATE (BAC)")
        XCTAssertTrue(isSecret([0x00, 0x86, 0x00, 0x00], nil), "GENERAL AUTHENTICATE (PACE)")
        XCTAssertTrue(isSecret([0x0C, 0x22, 0x41, 0xA4], nil), "MSE:Set AT")
    }

    /// PACE is a chain, and only its last frame carries CLA `00`.
    ///
    /// `EPassportReader.generalAuthenticate` sends every step but the last with
    /// the chaining bit set, so a rule that matched `00` and `0C` alone masked
    /// one frame of four. The first step is the costly one: the tag answers it
    /// with the nonce encrypted under the MRZ-derived key, and a document
    /// number, date of birth and expiry date are guessable offline once that
    /// ciphertext is in a bug report.
    func test_chainedPACEFrames_areMaskedToo() {
        XCTAssertTrue(isSecret([0x10, 0x86, 0x00, 0x00, 0x02], nil), "GENERAL AUTHENTICATE, chained")
        XCTAssertTrue(isSecret([0x1C, 0x86, 0x00, 0x00, 0x02], nil), "chained inside secure messaging")
        XCTAssertTrue(isSecret([0x10, 0x82, 0x00, 0x00], nil), "EXTERNAL AUTHENTICATE, chained")
    }

    /// The chaining bit widens the class byte and nothing else.
    func test_theChainingRuleDoesNotSwallowOrdinaryFrames() {
        XCTAssertFalse(isSecret([0x10, 0x84, 0x00, 0x00], nil), "GET CHALLENGE carries no key material")
        XCTAssertFalse(isSecret([0x10, 0xA4, 0x04, 0x0C], nil), "a chained SELECT is not a secret")
        XCTAssertFalse(isSecret([0x30, 0x86], ntag213), "a Type-2 READ of page 0x86")
        XCTAssertFalse(isSecret([0x90, 0x86, 0x00, 0x00], ntag213), "a wrapped 424 command that is not auth")
    }

    // MARK: - Degenerate input

    func test_shortFrames_areNotMistakenForSecrets() {
        XCTAssertFalse(isSecret([], ntag213))
        XCTAssertFalse(isSecret([0xA2], ntag213), "a truncated write addresses no page")
        XCTAssertFalse(isSecret([0x30], nil))
    }

    /// A chip the app could not identify still gets the family-independent rules,
    /// and cannot get the page-based ones, because there is no layout to consult.
    func test_anUnidentifiedChip_keepsTheRulesThatNeedNoLayout() {
        XCTAssertTrue(isSecret([0x1B, 0xA1, 0xB2, 0xC3, 0xD4], nil))
        XCTAssertFalse(isSecret([0xA2, 0x2B, 0xA1, 0xB2, 0xC3, 0xD4], nil))
    }
}
