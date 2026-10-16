import Foundation
import HexNFCKit
import HexNFCRecords

/// What the editor's Protection card shows in its fields the moment it opens.
///
/// It lives here, outside the card, because `ProtectionConfigSheet.swift` is
/// `#if os(iOS)` and `swift test` on macOS never compiles it: a rule kept in the
/// view's `init` can only ever be guarded by reading the source text. This is
/// the one rule in that `init` that has twice been able to reprogram a live
/// credential, so it is the one that belongs where a test can execute it.
///
/// The rule, in one sentence: **a default is only safe where there is nothing to
/// overwrite.**
struct ProtectionCardSeed: Equatable {
    /// Type-2 password / Type-5 write password, as the hex field shows it.
    var passwordHex: String
    /// Type-2 PACK.
    var packHex: String
    /// Type-4 AES key or Ultralight C 3DES key. Empty means the user has to
    /// supply it.
    var keyHex: String
    /// Fill the Ultralight C key field with a fresh random key and open in
    /// Generate mode. False means Paste: either the bytes in `keyHex` are the
    /// tag's own, or the field is empty and waiting for them.
    var generatesUltralightCKey: Bool

    /// The delivery values, which are also what an unprotected tag holds.
    private static let factoryPasswordHex = "FF:FF:FF:FF"
    private static let factoryPackHex = "00:00"

    /// - Parameters:
    ///   - family: the chip family the card is configuring.
    ///   - credential: the credential the app holds for this tag, if any. A tag
    ///     whose protection was merely *detected at scan* arrives with `nil`,
    ///     because nothing seeds a credential from a reading.
    ///   - tagReportsProtection: what the tag said about itself, from
    ///     `TagProtection.passwordProtect`.
    static func seed(
        family: ProtectionStyle.Family,
        credential: TagCredential?,
        tagReportsProtection: Bool
    ) -> ProtectionCardSeed {
        var passwordHex = factoryPasswordHex
        var packHex = factoryPackHex
        var keyHex = ""

        switch credential {
        case .type2(let password, let pack):
            passwordHex = password.hexString
            packHex = pack.hexString

        case .type4(let aesKey, _):
            keyHex = aesKey.hexString

        case .type5(let password, _):
            passwordHex = password.hexString

        case .ultralightC(let key):
            keyHex = key.cipherOrder.hexString

        case nil:
            // No credential in hand.
            //
            // Seeding the field with the factory default here is what let this
            // sheet silently reprogram a live password. A tag whose protection
            // was detected at scan always arrives with no credential, so the
            // sheet opened with the toggle already on and "FF:FF:FF:FF" already
            // in the field, reading as valid; the save button was live without
            // the user typing a character; and Done turned that seed into a real
            // credential that the next write pushed onto the tag. Open the card
            // on a protected tag, press the only affirmative button, write, and
            // the password became the factory default while the app reported
            // success.
            if family == .type5 || tagReportsProtection {
                passwordHex = ""
            }
        }

        // The same rule, for the one family whose field is a key rather than a
        // password. A fresh Ultralight C starts with a generated key, so the
        // card is immediately valid and the safe option is the one already
        // chosen. A tag that already reports protection starts empty instead.
        //
        // Seeding a key there is seeding a credential the user did not choose
        // for a tag that already holds one, and the cost is higher than the
        // password case: the write refuses with the tag's real key, the user
        // supplies that at the unlock prompt, and the write re-keys the tag to
        // the generated value on the way past. Ultralight C has no factory
        // reset and nothing in the app ever shows that key again, so from that
        // moment the protected memory cannot be rewritten by anyone.
        let generatesUltralightCKey = family == .ultralightC && keyHex.isEmpty && !tagReportsProtection

        return ProtectionCardSeed(
            passwordHex: passwordHex,
            packHex: packHex,
            keyHex: keyHex,
            generatesUltralightCKey: generatesUltralightCKey
        )
    }
}
