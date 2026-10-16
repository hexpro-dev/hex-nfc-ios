import CommonCrypto
import Foundation

/// Derives a MIFARE Ultralight C key from a human passphrase.
///
/// **These parameters are a permanent compatibility contract.** A tag
/// personalised with v1 parameters can only ever be opened by re-deriving with
/// v1 parameters: the key is not recoverable from the tag (the key pages are
/// write-only) and there is no factory reset that preserves data. Changing the
/// salt, the iteration count, the PRF or the output length silently makes every
/// previously protected tag unopenable, with no error to notice at the time.
///
/// So: the scheme is **versioned from the first release**, the parameters are
/// pinned as constants rather than tuned, and `UltralightCKeyDerivationTests`
/// asserts fixed vectors. If a future version is ever needed, add a case, keep
/// v1 derivable forever, and record which version a tag was personalised with.
public enum UltralightCKeyDerivation {
    /// Versioned parameter sets. Never remove or alter an existing case.
    public enum Scheme: String, Hashable, Sendable, CaseIterable {
        /// PBKDF2-HMAC-SHA256, 210 000 iterations, fixed application salt,
        /// 16-byte output. Iteration count follows OWASP's 2023 guidance for
        /// PBKDF2-HMAC-SHA256; the derivation runs once per personalisation, so
        /// the cost is invisible to the user and worth paying against a
        /// passphrase that may be short.
        case v1

        var iterations: UInt32 {
            switch self {
            case .v1: 210_000
            }
        }

        /// A fixed application salt, not a per-tag random one.
        ///
        /// Deliberate: the point of passphrase derivation here is that the user
        /// can re-derive the same key for a *stack* of tags from memory alone,
        /// having stored nothing. A random salt would have to be recorded
        /// somewhere to be useful, which defeats the feature, and there is
        /// nowhere on the tag to put it (the key pages are write-only and the
        /// user area is the thing being protected).
        ///
        /// The trade-off is honest and must stay in the UI copy: a fixed salt
        /// means identical passphrases across users derive identical keys, so
        /// the passphrase carries the whole strength. Generate is the default
        /// key-entry method for exactly this reason.
        var salt: Data {
            switch self {
            case .v1: Data("pro.hex.nfc.ultralightc.kdf.v1".utf8)
            }
        }
    }

    /// Derive a key from `passphrase`. Throws on an empty passphrase; every
    /// other input is valid, since the KDF fixes the output length.
    public static func key(
        from passphrase: String,
        scheme: Scheme = .v1
    ) throws -> UltralightCKey {
        let normalised = passphrase.precomposedStringWithCanonicalMapping
        guard !normalised.isEmpty else {
            throw TagError.protocolError(
                "Enter a passphrase to derive a key from",
                diagnostics: "empty passphrase"
            )
        }
        let passwordBytes = Array(normalised.utf8)
        let salt = [UInt8](scheme.salt)
        var derived = [UInt8](repeating: 0, count: UltralightCKey.byteCount)

        let status = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            normalised, passwordBytes.count,
            salt, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            scheme.iterations,
            &derived, derived.count
        )
        guard status == kCCSuccess else {
            throw TagError.unexpected("key derivation failed (CommonCrypto status \(status))")
        }
        // The derived bytes are the **cipher-order** key. Nothing about the
        // derivation knows or cares about the tag's memory byte order, which is
        // `UltralightCKey`'s job.
        return try UltralightCKey(cipherOrder: Data(derived))
    }
}
