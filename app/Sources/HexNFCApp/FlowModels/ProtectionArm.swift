import Foundation
import HexNFCKit
import HexNFCRecords
import Security

/// What the standalone "Protect with password" operation is going to arm, built
/// from the family the tag reported on tap 1 and the fields the screen collected
/// after it.
///
/// It lives here rather than in `OperationsSheet.swift` for the reason
/// `ProtectionCardSeed` and `TagAccessIntent` give: every file under `Screens/`
/// is `#if os(iOS)` and `swift test` on macOS never compiles a line of one, so a
/// rule kept in the view can only ever be reviewed. The rules here decide which
/// secret reaches a tag and whether its reads end up gated, which is not a class
/// of rule this repo leaves to review.
struct ProtectionArm: Equatable {
    /// Type-2 password, or the Type-5 write password.
    var passwordHex: String = ""
    /// Type-2 PACK.
    var packHex: String = ""
    /// Type-4 AES key or Ultralight C 3DES key, in cipher order.
    var keyHex: String = ""
    /// Whether reads should be gated too. Only ever settable on the two
    /// families that offer it; see `offersReadGate`.
    var readProtect: Bool = false

    /// What an arm carries before the screen has been told anything.
    ///
    /// `passwordProtect: false` is the load-bearing half, and it is read in two
    /// places. `OperationsFlowModel.armingStyle` reads it, so the identify tap
    /// stages no family against a tag nothing has read yet: a screen that
    /// assumed Type-2 before the tap is exactly what made an NTAG424, an
    /// Ultralight C and a SLIX2 dead-end on `capabilityUnsupported`. And
    /// `OperationsFlowModel.requiresProtectionSettings` reads it to keep the
    /// typed-UID gate shut until the real settings have been supplied, so a run
    /// can never reach a tag still carrying this placeholder.
    static let unstaged = PendingProtection(
        settings: TagProtection(passwordProtect: false),
        credential: .type2(password: Data(), pack: Data())
    )

    /// Whether this family is offered a read gate at all.
    ///
    /// Type-2 and Type-4 only, which is the same answer `ProtectionConfigSheet`
    /// gives, and neither exclusion is a matter of taste:
    ///
    /// - A SLIX2 read gate **is** privacy mode, and a tag in privacy mode
    ///   answers no inventory (SL2S2602 §9.5.3.9). CoreNFC only ever vends
    ///   inventoried tags, so the tag stops being discoverable and no frame this
    ///   app can send will undo it.
    /// - A read-gated Ultralight C hides pages 28h-2Bh, which are the pages
    ///   `ChipCatalog` identifies the chip from, so the app stops recognising
    ///   the tag and can never offer to unlock it, even holding the right key.
    ///
    /// Both drivers already refuse a read gate without an explicit opt-in this
    /// app never passes. Left to the driver alone, the refusal arrives as
    /// `capabilityUnsupported` after the user has typed fourteen characters of
    /// UID, which is the dead end the adaptive screen exists to remove.
    static func offersReadGate(_ family: ProtectionStyle.Family) -> Bool {
        switch family {
        case .type2, .type4: true
        case .type5, .ultralightC: false
        }
    }

    /// The fields a family's card opens with, from `ProtectionCardSeed`.
    ///
    /// The same rule the editor's Protection card runs, and it is reused rather
    /// than restated because it has twice been able to reprogram a live
    /// credential: a default in a field that reads as valid turns the only
    /// affirmative button on the screen into a re-key nobody chose. `credential:
    /// nil` is the honest argument here, because this screen holds no credential
    /// for the tag: `TagCredentialStore` has never been read by anything, and
    /// making Operations its first reader would put a stored secret into a
    /// plain-text hex field.
    ///
    /// - Parameters:
    ///   - family: the family the identify tap reported.
    ///   - tagReportsProtection: the tag said it is protected, or its state
    ///     could not be established. An unread gate counts as "may hold a
    ///     credential", for the same reason the editor's card counts it.
    ///   - randomKey: the generated Ultralight C key, injected so the seeding
    ///     rule is testable without asserting on entropy.
    static func seeded(
        family: ProtectionStyle.Family,
        tagReportsProtection: Bool,
        randomKey: () -> String = { randomHex(16) }
    ) -> ProtectionArm {
        let seed = ProtectionCardSeed.seed(
            family: family,
            credential: nil,
            tagReportsProtection: tagReportsProtection
        )
        return ProtectionArm(
            passwordHex: seed.passwordHex,
            packHex: seed.packHex,
            keyHex: seed.generatesUltralightCKey ? randomKey() : seed.keyHex,
            readProtect: false
        )
    }

    /// The arm these fields describe for `family`, or `nil` while they are not
    /// yet a usable secret.
    ///
    /// Mirrors `ProtectionConfigSheet.commit()` family for family, because the
    /// two routes are meant to be the same operation reached two ways. What it
    /// deliberately does not mirror is the card's Advanced disclosure: there is
    /// no custom start page here, so `protectFromPage` stays nil and
    /// `ProtectionSpec.make` resolves it against the tag the run connects to.
    func pending(for family: ProtectionStyle.Family) -> PendingProtection? {
        var settings = TagProtection(passwordProtect: true)
        switch family {
        case .type2:
            // Flat fields stay canonical for Type-2, with `style` nil, so the
            // settings this produces encode exactly as every other Type-2 row.
            guard let password = Data.parseHex(passwordHex), password.count == 4,
                  let pack = Data.parseHex(packHex), pack.count == 2
            else { return nil }
            settings.readProtect = readProtect
            settings.hasStoredCredential = true
            return PendingProtection(settings: settings, credential: .type2(password: password, pack: pack))

        case .type4:
            guard let key = Data.parseHex(keyHex), key.count == 16 else { return nil }
            settings.style = .type4(.init(keySlot: 0, readProtect: readProtect))
            settings.hasStoredCredential = true
            return PendingProtection(settings: settings, credential: .type4(aesKey: key, keySlot: 0))

        case .type5:
            guard let password = Data.parseHex(passwordHex), password.count == 4 else { return nil }
            // Always `.write`. See `offersReadGate`.
            settings.style = .type5(.init(kind: .write))
            settings.hasStoredCredential = true
            return PendingProtection(settings: settings, credential: .type5(password: password, kind: .write))

        case .ultralightC:
            guard let bytes = Data.parseHex(keyHex), bytes.count == 16,
                  let key = try? UltralightCKey(cipherOrder: bytes)
            else { return nil }
            // Always write-only, and no custom start page. See `offersReadGate`.
            settings.style = .ultralightC(.init(protectFromPage: nil, readProtect: false))
            settings.hasStoredCredential = true
            return PendingProtection(settings: settings, credential: .ultralightC(key: key))
        }
    }

    static func randomHex(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).hexString
    }
}
