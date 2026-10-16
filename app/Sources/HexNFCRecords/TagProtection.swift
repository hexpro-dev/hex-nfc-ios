import Foundation

/// Which chip-family protection model a `TagProtection` configures, plus that
/// family's *non-secret* knobs. The secret (PWD/PACK, AES key, SLIX password)
/// never lives here — it stays in the device Keychain. This is the discriminator
/// that lets one settings type describe Type-2, Type-4 and Type-5 protection
/// without the persisted shape pinning to one command model.
///
/// Migration note: `TagProtection.style` is *optional*. A legacy row (written
/// before families existed) has no `style` and is interpreted as Type-2 from the
/// flat fields — see `TagProtection.effectiveStyle`. New Type-2 rows keep
/// `style == nil` too, so their JSON stays byte-identical to the legacy form
/// (cross-app interop + history dedup fingerprints are unaffected). `style` is
/// written non-nil only for Type-4 / Type-5.
public enum ProtectionStyle: Hashable, Sendable, Codable {
    /// NTAG21x / Ultralight EV1. PWD + PACK are the secret; these are the knobs.
    case type2(Type2Settings)
    /// NTAG424 DNA. A 16-byte AES-128 key is the secret; this is the gating config.
    case type4(Type4Settings)
    /// ICODE SLIX. The 4-byte password(s) are the secret; this is the kind.
    case type5(Type5Settings)
    /// MIFARE Ultralight C. A 16-byte 2-key 3DES key is the secret; these are
    /// the two configuration bytes.
    ///
    /// Deliberately **not** folded into `.type2` even though the chip is
    /// page-addressed and shares READ/WRITE with the NTAG21x line. Every seam in
    /// this codebase is keyed on credential *shape*, and a 16-byte key with a
    /// mutual handshake is not a 4-byte password with a PACK reply: the
    /// Keychain blob, `TagCredential`, `ProtectionSpec` and the config sheet all
    /// branch differently. Reusing `.type2` would also hand the chip to the
    /// PWD/PACK backend through `ProtectionStyle.backendStyle`.
    case ultralightC(UltralightCSettings)

    /// Which family a style configures, with the settings dropped.
    ///
    /// It exists because the two producers of a `ProtectionStyle` are not
    /// comparable with `==`. A chip's `protectionStyle` answers with the
    /// backend's *default* settings, describing what that chip can drive, while
    /// a staged `TagProtection.effectiveStyle` carries the user's AUTH0 and PROT
    /// (and a legacy row's AUTH_LIM). Comparing whole values would call every
    /// configured arm a mismatch.
    public enum Family: String, Hashable, Sendable, CaseIterable {
        case type2
        case type4
        case type5
        case ultralightC
    }

    public var family: Family {
        switch self {
        case .type2: .type2
        case .type4: .type4
        case .type5: .type5
        case .ultralightC: .ultralightC
        }
    }

    public struct Type2Settings: Hashable, Sendable, Codable {
        /// AUTH0 — first protected page. `nil` ⇒ derive the chip's first data
        /// page at apply time, so a preset isn't pinned to one layout.
        public var protectFromPage: Int?
        /// PROT bit: reads also require the password.
        public var readProtect: Bool
        /// AUTH_LIM (0…7). `0` = unlimited; non-zero permanently bricks after N
        /// wrong attempts, so the UI must warn loudly before setting it.
        public var authLimit: Int
        public init(protectFromPage: Int? = nil, readProtect: Bool = false, authLimit: Int = 0) {
            self.protectFromPage = protectFromPage
            self.readProtect = readProtect
            self.authLimit = authLimit
        }
    }

    public struct Type4Settings: Hashable, Sendable, Codable {
        /// Key slot the NDEF file is gated behind (0 by default). Settings, not secret.
        public var keySlot: Int
        /// Gate reads too (enabling always implies write-protect).
        public var readProtect: Bool
        public init(keySlot: Int = 0, readProtect: Bool = false) {
            self.keySlot = keySlot
            self.readProtect = readProtect
        }
    }

    public struct Type5Settings: Hashable, Sendable, Codable {
        /// Which SLIX password kind(s) this configures.
        public enum Kind: String, Hashable, Sendable, Codable {
            case write
            case read
            case readWrite
        }

        public var kind: Kind
        public init(kind: Kind = .write) {
            self.kind = kind
        }
    }

    /// MIFARE Ultralight C (MF0ICU2) knobs: the two authentication
    /// configuration bytes, AUTH0 (page 2Ah) and AUTH1 (page 2Bh).
    public struct UltralightCSettings: Hashable, Sendable, Codable {
        /// AUTH0 — first page (≥) that authentication covers. Valid `0x03`…`0x30`
        /// on this chip, where `0x30` means "protection off". `nil` ⇒ derive the
        /// chip's first data page at apply time, so a preset isn't pinned to one
        /// layout (same contract as `Type2Settings.protectFromPage`).
        public var protectFromPage: Int?
        /// Reads also require authentication.
        ///
        /// Stored as the human-meaningful sense, **not** as the raw AUTH1 byte,
        /// because AUTH1's polarity is inverted relative to the NTAG21x `PROT`
        /// bit it superficially resembles: AUTH1 bit 0 = `0` means read+write
        /// restricted and `1` means write-only (MF0ICU2 rev 3.3 Table 12). The
        /// conversion lives in one place, `UltralightCConfiguration`.
        public var readProtect: Bool
        public init(protectFromPage: Int? = nil, readProtect: Bool = false) {
            self.protectFromPage = protectFromPage
            self.readProtect = readProtect
        }
    }

    /// Whether this style's settings call for reads to be gated, too.
    public var readProtect: Bool {
        switch self {
        case .type2(let s): s.readProtect
        case .type4(let s): s.readProtect
        case .type5(let s): s.kind == .read || s.kind == .readWrite
        case .ultralightC(let s): s.readProtect
        }
    }
}

/// Persisted *settings* for tag password protection — what the user configured,
/// never the secret. The password/PACK/AES-key/SLIX-password are deliberately NOT
/// fields here: they live in the device Keychain (see `ProtectionCredentialStore`)
/// keyed by the owning preset's id, so the secret never syncs to iCloud and never
/// rides inside a `.hexnfc` export. Only these non-secret settings travel with a
/// preset, a history row, or an export.
///
/// Permanent lock is intentionally absent — it is an irreversible, per-tag
/// action (a "Dangerous Action"), never a batchable preset attribute that could
/// brick a stack of tags from one careless write.
public struct TagProtection: Hashable, Codable, Sendable {
    /// Apply password protection when this preset/tag is written.
    public var passwordProtect: Bool

    /// Family discriminator + per-family settings. OPTIONAL for migration: a
    /// `nil` here means "legacy / Type-2 row" — `effectiveStyle` synthesizes a
    /// `.type2` from the flat fields below. Set non-nil only for Type-4/Type-5;
    /// Type-2 deliberately keeps this nil so its encoded JSON is byte-identical
    /// to the pre-families form.
    public var style: ProtectionStyle?

    // --- Legacy Type-2 flat fields. KEPT at top level for wire compatibility. ---
    // For `.type2`, these remain the canonical storage (and `style` stays nil),
    // so existing JSON round-trips unchanged. For `.type4`/`.type5` they are
    // unused (left at default) and everything lives in `style`.

    /// First page (≥) that protection covers — AUTH0. `nil` means "derive a
    /// sensible default at apply time" (the chip's first NDEF/data page), so a
    /// preset isn't pinned to one chip's page layout.
    public var protectFromPage: Int?

    /// PROT bit. `true` ⇒ reads *also* require the password; `false` ⇒ the tag
    /// stays readable but is write-protected (the common case).
    public var readProtect: Bool

    /// AUTH_LIM — failed-authentication attempt limit. `0` means unlimited and
    /// never auto-bricks; a non-zero value permanently locks the tag after that
    /// many wrong passwords, so the UI must warn loudly before setting it.
    public var authLimit: Int

    /// `true` once a credential has been stashed in the Keychain for the owning
    /// preset. Lets the UI show "password set" without holding the secret, and
    /// tells the write flow whether it can apply protection without re-prompting
    /// (e.g. after a cross-device sync, where the secret is absent).
    public var hasStoredCredential: Bool

    public init(
        passwordProtect: Bool = false,
        style: ProtectionStyle? = nil,
        protectFromPage: Int? = nil,
        readProtect: Bool = false,
        authLimit: Int = 0,
        hasStoredCredential: Bool = false
    ) {
        self.passwordProtect = passwordProtect
        self.style = style
        self.protectFromPage = protectFromPage
        self.readProtect = readProtect
        self.authLimit = authLimit
        self.hasStoredCredential = hasStoredCredential
    }

    /// No protection — the default for a fresh build or an unprotected scan.
    public static let none = TagProtection()

    /// `true` when this config asks for any protection to be applied on write.
    public var isActive: Bool {
        passwordProtect
    }

    /// The family-resolved style. Legacy / Type-2 rows (`style == nil`) synthesize
    /// a `.type2` from the flat fields; Type-4/Type-5 rows use the explicit `style`.
    /// This is the single accessor callers should read — never branch on `style`
    /// being nil directly.
    public var effectiveStyle: ProtectionStyle {
        if let style {
            return style
        }
        return .type2(.init(protectFromPage: protectFromPage, readProtect: readProtect, authLimit: authLimit))
    }

    /// Whether reads (not just writes) are gated, resolved across families.
    public var effectiveReadProtect: Bool {
        style?.readProtect ?? readProtect
    }
}
