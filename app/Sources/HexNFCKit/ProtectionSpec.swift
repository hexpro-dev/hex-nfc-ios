import Foundation
import HexNFCRecords

/// The raw secret used to authenticate past, or remove, a tag's protection —
/// family-tagged, carrying only bytes. Deliberately a `HexNFCKit`-local type
/// (not `HexNFCStorage.ProtectionCredential`): `HexNFCKit` must not depend on the
/// storage layer, so the App resolves the Keychain credential and maps it to a
/// `TagCredential` before handing it to a `ConnectedTag`.
public enum TagCredential: Hashable, Sendable {
    case type2(password: Data, pack: Data)
    case type4(aesKey: Data, keySlot: Int)
    case type5(password: Data, kind: ProtectionStyle.Type5Settings.Kind)
    /// MIFARE Ultralight C. The 16-byte 2-key 3DES key, in **cipher order**
    /// (`UltralightCKey` owns the conversion to the memory order the tag's key
    /// pages take).
    case ultralightC(key: UltralightCKey)
}

/// What opening a tag's gate actually did.
///
/// `alreadyOpen` is the answer that did not exist before, and it is the whole
/// point: a tag the app did not need to authenticate against used to be
/// indistinguishable from one it authenticated successfully, and both were
/// indistinguishable from a tag it halted trying. Consulting the tag's own
/// configuration first, and saying so in the result, is what stops a stale
/// credential from being fired at a chip that no longer wants one.
public struct GateOpening: Hashable, Sendable {
    /// Two answers, and deliberately only two.
    ///
    /// There is no `authenticatedWithFactoryDefault`. On a Type-2 chip a refused
    /// `PWD_AUTH` NAKs and the NAK returns the chip to HALT for the rest of the
    /// activation, so no driver can present a second credential and report which
    /// one worked: a fallback is always a second *tap*, and the only layer that
    /// knows one was chosen is the flow that chose it
    /// (`OperationsFlowModel.retryWithFactoryDefault`). The case used to exist
    /// with no producer anywhere and two readers comparing against it, both
    /// permanently false, which read as though Type-2 had an in-session fallback
    /// it does not have.
    ///
    /// The families that genuinely can try candidates inside one session
    /// (NTAG424, SLIX2) report it on `ProtectionResidue.authenticatedWithFactoryDefault`,
    /// which is a separate field and is unaffected.
    public enum Route: Hashable, Sendable {
        /// The tag's own configuration says nothing is gated, so no
        /// authentication frame was sent at all.
        case alreadyOpen
        case authenticated
    }

    public let route: Route
    /// Whatever the tag answered the handshake with, and empty for every route
    /// that sent no handshake.
    ///
    /// Two families fill it: Type-2 puts the 2-byte PACK here, and Ultralight C
    /// puts the 8-byte RndA the card returned. It is not a value to compare a
    /// credential against, and nothing does: `Type2PasswordDriver.enable` proves
    /// its own PACK round trip, and the Ultralight C driver has already verified
    /// the card's half of the handshake before returning. The one reader is the
    /// live harness (`UltralightCPlan`, the `ulc.auth` step), which checks the
    /// length as evidence the mutual authentication really completed on silicon.
    /// It reads `Data`, never a key.
    public let response: Data

    public init(route: Route, response: Data = Data()) {
        self.route = route
        self.response = response
    }
}

/// Everything a backend needs to *enable* protection in one operation: the
/// non-secret settings plus the resolved secret. Never persisted (it carries the
/// secret). Built by `ProtectionSpec.make` from a `TagProtection` (settings) plus
/// a resolved `TagCredential`, so App-layer callers never assemble a
/// family-specific argument list or know a chip's page layout.
public enum ProtectionSpec: Hashable, Sendable {
    /// Type-2 (NTAG21x / UL-EV1). `protectFromPage` is resolved (no longer nil).
    case type2(password: Data, pack: Data, protectFromPage: Int, readProtect: Bool, authLimit: Int)
    /// Type-4 (NTAG424 DNA). Gate the NDEF file behind `aesKey` in `keySlot`.
    case type4(aesKey: Data, keySlot: Int, readProtect: Bool)
    /// Type-5 (ICODE SLIX). Set the write password and optionally a read password.
    case type5(write: Data?, read: Data?, kind: ProtectionStyle.Type5Settings.Kind)
    /// MIFARE Ultralight C. Write `key`, then gate pages from `protectFromPage`.
    ///
    /// What opens the tag *now* is deliberately not part of the spec. It arrives
    /// through `enableProtection(_:replacing:)`, the same channel the other three
    /// families already use, so there is one answer to "what opens this tag" and
    /// not two that can disagree. This case used to carry a `currentKey`
    /// alongside, and the arm in `TagSession` preferred it over `replacing:`,
    /// which is how a caller's resolved credential got dropped on the floor.
    case ultralightC(key: UltralightCKey, protectFromPage: Int, readProtect: Bool)

    /// The non-secret style this spec applies, with the secret dropped. Used to
    /// record `TagProtection.style`/the on-tag summary after a successful write.
    public var style: ProtectionStyle {
        switch self {
        case .type2(_, _, let page, let readProtect, let authLimit):
            .type2(.init(protectFromPage: page, readProtect: readProtect, authLimit: authLimit))

        case .type4(_, let keySlot, let readProtect):
            .type4(.init(keySlot: keySlot, readProtect: readProtect))

        case .type5(_, _, let kind):
            .type5(.init(kind: kind))

        case .ultralightC(_, let page, let readProtect):
            .ultralightC(.init(protectFromPage: page, readProtect: readProtect))
        }
    }

    /// Build a family-appropriate spec from settings + secret. Returns `nil` when
    /// the credential's family doesn't match the settings' style (a programming
    /// error the caller should surface as `.capabilityUnsupported`).
    /// `defaultFirstDataPage` lets Type-2 resolve a `nil` AUTH0 without the caller
    /// knowing the chip's page layout — preserving "a preset isn't pinned to one
    /// chip".
    public static func make(
        settings: TagProtection,
        credential: TagCredential,
        defaultFirstDataPage: Int
    ) -> ProtectionSpec? {
        switch (settings.effectiveStyle, credential) {
        case (.type2(let s), .type2(let password, let pack)):
            // AUTH_LIM is forced to 0 here, and `s.authLimit` is deliberately
            // ignored. This is the choke point every batchable write funnels
            // through, so it is the only place the rule can be made structural
            // rather than remembered.
            //
            // A non-zero attempt limit destroys a tag after that many wrong
            // passwords, with no recovery, which puts it in the same class as a
            // permanent lock: "standalone only, a per-tag, UID-confirmed
            // Dangerous Action. Never a batchable preset/write-time setting."
            // A `TagProtection` is a preset. It is explicitly not pinned to one
            // chip, it replays across a whole stack of tags from the Library,
            // and it travels in `.hexnfc` exports and iCloud sync, so a
            // confirmation typed against the first tag would stand in for every
            // tag after it.
            //
            // Removing the editor's stepper was not enough on its own. A row can
            // still arrive carrying a limit without anyone choosing one here:
            // scanning a tag whose owner set AUTH_LIM=3 reads it back into
            // `detectedProtection`, "Save as preset" stores it verbatim without
            // the Protection card ever being opened, and an imported `.hexnfc`
            // carries `TagProtection` whole. Every one of those reaches the
            // silicon through this line.
            //
            // Setting a limit is `Operation.setAttemptLimit`, which takes two
            // taps and the tag's typed UID between them.
            //
            // A read gate is pinned to the first data page for a different
            // reason, and it is the one that strands tags. `Type2PasswordDriver`
            // recognises a read-gated tag by the roll-over in a single `30 03`:
            // a gated chip serves pages 0 and 1 again instead of the pages above
            // the Capability Container. That signature only appears inside the
            // sixteen bytes the driver compares when AUTH0 is the first data
            // page. One or two pages higher the wrap lands later in the frame,
            // unseen; higher still there is no wrap at all. So on any other
            // start page `readState` reads a NAK instead of a reading, throws
            // before a password is ever presented, and every unlock, rewrite,
            // re-key and removal reports that the user's correct password did
            // not open the tag. The tag is not damaged and another app that
            // authenticates first can still reach it, but this one cannot,
            // which is as good as lost to the person holding it.
            //
            // Pinned rather than refused because this is the batch path: a
            // preset replays across a stack of tags and an imported `.hexnfc`
            // arrives whole, so there is no screen here to carry a refusal. The
            // stricter boundary is also the safe direction, since it gates more
            // of the tag than was asked rather than less. The editor does not
            // offer the combination at all (`ProtectionConfigSheet`), and this
            // is what makes the rule hold for the rows that never passed
            // through it.
            //
            // A *write* gate's start page is honoured, and that is deliberate:
            // the Protection card offers it and the tag it was chosen against is
            // in the user's hand. What is not deliberate is the same number
            // reaching a stack of other tags, which is the batch hazard the read
            // gate's pin already answers. That one is settled a layer up, at the
            // only boundary that can tell the two apart: `Preset` drops a pinned
            // AUTH0 (`Preset.unpinningStartPage`), so a preset, a `.hexnfc`
            // import and an iCloud row all arrive here with `nil` and resolve
            // against the chip actually on the reader.
            return .type2(
                password: password,
                pack: pack,
                protectFromPage: s.readProtect ? defaultFirstDataPage : (s.protectFromPage ?? defaultFirstDataPage),
                readProtect: s.readProtect,
                authLimit: 0
            )

        case (.type4(let s), .type4(let aesKey, let keySlot)):
            return .type4(aesKey: aesKey, keySlot: keySlot, readProtect: s.readProtect)

        case (.type5(let s), .type5(let password, _)):
            let write: Data? = (s.kind == .write || s.kind == .readWrite) ? password : nil
            let read: Data? = (s.kind == .read || s.kind == .readWrite) ? password : nil
            return .type5(write: write, read: read, kind: s.kind)

        case (.ultralightC(let s), .ultralightC(let key)):
            return .ultralightC(
                key: key,
                protectFromPage: s.protectFromPage ?? defaultFirstDataPage,
                readProtect: s.readProtect
            )

        default:
            return nil
        }
    }
}

public extension ProtectionStyle {
    /// The protection model a *backend* (production `CoreNFCConnectedTag` and the
    /// matching simulator) can actually drive for a given chip, or `nil` if none
    /// exists yet. This is the single definition of "a backend exists for this
    /// chip" — the capability-driven UI offers protection iff this is non-nil
    /// (and `.passwordAuth` is present, which this already checks).
    ///
    /// It deliberately gates on the specific *variant*, not just the family: a
    /// Type-2 chip needs a `Type2ConfigLayout`; only the NTAG424 DNA among Type-4;
    /// only ICODE SLIX among Type-5. As each backend lands, its variant is added
    /// here — that one edit flips the affordance on across the whole app.
    static func backendStyle(
        for family: TagFamily?,
        capabilities: TagCapability
    ) -> ProtectionStyle? {
        // MIFARE Ultralight C is matched **before** the generic Type-2 arm and
        // on a different capability. It is a Type-2 chip by transport, so the
        // arm below would claim it for the PWD/PACK backend the moment it had a
        // `Type2ConfigLayout` — which is exactly why `Type2ConfigLayout.for`
        // returns `nil` for it. Gating on `.tripleDESAuth` rather than
        // `.passwordAuth` makes the two mutually exclusive by construction.
        if case .type2(.mifareUltralightC) = family, capabilities.contains(.tripleDESAuth) {
            return .ultralightC(.init())
        }
        guard capabilities.contains(.passwordAuth) else { return nil }
        switch family {
        case .type2(let variant) where Type2ConfigLayout.for(variant) != nil:
            return .type2(.init())

        case .type4(.ntag424DNA):
            return .type4(.init())

        // **SLIX2 only.** `.icodeSlix` used to be listed here too, on the
        // reasoning that the two share a command set. The identification data
        // does not support that: 28 blocks is SLI, SLIX, SLIX-S or SLIX-L
        // indistinguishably, and only the 80-block SLIX2 is both identifiable
        // and known to carry the read/write password machinery. Offering the
        // affordance to the whole 28-block group meant offering password
        // protection to silicon that has none, and the refusal a plain SLI gives
        // is silence rather than an error (SL2S2602 section 9.5.3.2), which
        // reads as a lost tag.
        //
        // `ChipCatalog.icodeSlix` no longer advertises `.passwordAuth`, so this
        // is the second half of one decision. The two definitions must agree.
        case .type5(.icodeSlix2):
            return .type5(.init())

        default:
            return nil
        }
    }
}
