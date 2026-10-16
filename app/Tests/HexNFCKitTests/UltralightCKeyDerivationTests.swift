@testable import HexNFCKit
import XCTest

/// Fixed vectors for the passphrase-to-key derivation.
///
/// **These assertions are the compatibility contract, not a smoke test.** A tag
/// personalised from a passphrase can only ever be reopened by re-deriving the
/// same bytes: the key pages are write-only, so the key cannot be read back, and
/// Ultralight C has no factory reset that preserves data. If someone retunes the
/// salt, the iteration count, the PRF or the output length, every tag protected
/// with the old parameters becomes permanently unopenable, silently, with no
/// error at the time of the change.
///
/// So these hardcoded expectations exist precisely to make that change loud. If
/// this file fails, the fix is a **new scheme version**, never an updated
/// expectation.
final class UltralightCKeyDerivationTests: XCTestCase {
    /// Locks the v1 output for a fixed passphrase, byte for byte.
    ///
    /// The expectation was derived **independently** of our implementation, so
    /// it checks the derivation rather than merely recording it:
    ///
    ///     python3 -c "import hashlib; print(hashlib.pbkdf2_hmac('sha256',
    ///       'correct horse battery staple'.encode(),
    ///       b'pro.hex.nfc.ultralightc.kdf.v1', 210000, 16).hex())"
    ///     3e1f3dd8eb99497a1b864bb25f8076db
    func test_v1_fixedVector() throws {
        let key = try UltralightCKeyDerivation.key(from: "correct horse battery staple")
        XCTAssertEqual(
            key.cipherOrder.hexString,
            "3E:1F:3D:D8:EB:99:49:7A:1B:86:4B:B2:5F:80:76:DB",
            "v1 parameters changed — add a new Scheme case instead of updating this expectation"
        )
    }

    func test_v1_parametersArePinned() {
        XCTAssertEqual(UltralightCKeyDerivation.Scheme.v1.iterations, 210_000)
        XCTAssertEqual(
            String(data: UltralightCKeyDerivation.Scheme.v1.salt, encoding: .utf8),
            "pro.hex.nfc.ultralightc.kdf.v1"
        )
    }

    /// Deterministic across calls: the whole point is re-deriving the same key
    /// for a stack of tags without storing anything.
    func test_derivationIsDeterministic() throws {
        let a = try UltralightCKeyDerivation.key(from: "hex pro")
        let b = try UltralightCKeyDerivation.key(from: "hex pro")
        XCTAssertEqual(a, b)
    }

    func test_differentPassphrases_giveDifferentKeys() throws {
        let a = try UltralightCKeyDerivation.key(from: "hex pro")
        let b = try UltralightCKeyDerivation.key(from: "hex pro ")
        XCTAssertNotEqual(a, b)
    }

    /// Unicode normalisation, so a passphrase typed with a combining accent on
    /// one device derives the same key as the precomposed form on another.
    /// Without this the user gets an "unopenable" tag with no explanation.
    func test_unicodeNormalisation_isApplied() throws {
        let precomposed = try UltralightCKeyDerivation.key(from: "caf\u{00E9}") // é
        let decomposed = try UltralightCKeyDerivation.key(from: "cafe\u{0301}") // e + ́
        XCTAssertEqual(precomposed, decomposed)
    }

    func test_emptyPassphrase_isRejected() {
        XCTAssertThrowsError(try UltralightCKeyDerivation.key(from: ""))
    }

    /// The derived value is the cipher-order key, and the memory order is
    /// derived from it, never the other way round.
    func test_derivedKey_isCipherOrder() throws {
        let key = try UltralightCKeyDerivation.key(from: "hex pro")
        XCTAssertEqual(key.memoryOrder, UltralightCKey.swappingHalves(key.cipherOrder))
        XCTAssertNotEqual(key.memoryOrder, key.cipherOrder)
    }

    /// A derived key must never be the published factory key.
    func test_derivedKey_isNotTheFactoryDefault() throws {
        XCTAssertFalse(try UltralightCKeyDerivation.key(from: "BREAKMEIFYOUCAN!").isFactoryDefault)
    }
}
