import Foundation
import HexNFCKit
import HexNFCRecords
import SwiftUI

/// The unlock prompt's family-dependent vocabulary, in one place.
///
/// `ScanSheet` and `WriteSheet` both ask the user for a tag's secret and both
/// have to know how many bytes to expect and how to package them. That logic
/// was duplicated in the two files as `unlockIsKey ? 16 : 4`, a two-way
/// conditional that silently produced the wrong answer the moment a third
/// credential shape existed: MIFARE Ultralight C's key is 16 bytes like the
/// NTAG424's, but it is a 3DES key, not AES, and it builds a different
/// `TagCredential`. A `Bool` cannot carry that.
///
/// The user-facing copy stays in each sheet, because the two genuinely differ
/// ("this tag is protected" when we know, "this tag looks protected" when we
/// are inferring). What lives here is everything a wrong answer would break,
/// including the one rule for when a refusal's own copy replaces the sheet's
/// (`TagError.unlockPromptCopy`).
extension ProtectionStyle {
    /// How many bytes the secret is. The field enables only at this exact
    /// length, so it is also the input validation.
    var unlockSecretByteCount: Int {
        switch self {
        case .type2: 4 // PWD
        case .type4: 16 // AES-128 key
        case .type5: 4 // SLIX password
        case .ultralightC: 16 // 2-key 3DES key
        }
    }

    /// Whether the secret reads as a "key" rather than a "password". Drives
    /// which noun the prompt uses.
    var unlockSecretIsKey: Bool {
        switch self {
        case .type2, .type5: false
        case .type4, .ultralightC: true
        }
    }

    /// The specific cipher named in the prompt. Naming it matters: a user with
    /// both an NTAG424 and an Ultralight C has two different 16-byte keys, and
    /// "16-byte key" alone does not tell them which one to paste.
    var unlockSecretDescription: LocalizedStringKey {
        switch self {
        case .type2: "Tag password (4 bytes)"
        case .type4: "Tag key (16-byte AES)"
        case .type5: "Tag password (4 bytes)"
        case .ultralightC: "Tag key (16-byte 3DES)"
        }
    }

    /// Package entered bytes into the family's credential, or `nil` if they are
    /// the wrong length or otherwise unusable.
    func unlockCredential(from bytes: Data) -> TagCredential? {
        guard bytes.count == unlockSecretByteCount else { return nil }
        switch self {
        case .type2:
            // PACK is unknown at unlock time; the Type-2 path only needs PWD.
            return .type2(password: bytes, pack: Data())

        case .type4:
            return .type4(aesKey: bytes, keySlot: 0)

        case .type5(let settings):
            return .type5(password: bytes, kind: settings.kind)

        case .ultralightC:
            // Entered hex is the **cipher-order** key, which is the form the
            // datasheet, Proxmark3 and every other reference quote. The memory
            // order is an implementation detail of the write path and users
            // should never have to think about it.
            guard let key = try? UltralightCKey(cipherOrder: bytes) else { return nil }
            return .ultralightC(key: key)
        }
    }
}

extension TagError {
    /// What an unlock prompt says in place of its own copy after this refusal, or
    /// `nil` to keep its own.
    ///
    /// Only a refusal on a tag that reported an attempt limit replaces it. The
    /// prompts' failure copy, "That password didn't unlock the tag. Check it and
    /// try again.", is right for a tag that can be tried again and wrong for one
    /// whose `AUTH_LIM` is spent: that chip refuses the correct password too
    /// (bench 2026-09-10, finding 17), and the advice sends its owner to doubt a
    /// password that is right and to spend another attempt. The driver's
    /// qualified copy says the limit is set and does not guess which it was.
    ///
    /// Both forms qualify. On 2026-09-14 the form followed the lock: a locked
    /// NTAG213 answered every password with the one-byte payload, and an unlocked
    /// one answered a wrong password in the transport form. So on a limited tag
    /// the transport form is the ordinary wrong password, and it is the form the
    /// owner of a still-open tag meets first, which is the one place a warning
    /// can still save the tag. Its copy used to open "Couldn't check the
    /// password: the tag stopped answering", which would have told that user the
    /// password was never checked and invited the same one again, so the prompts
    /// kept their own words for it. It now says a wrong try counts and to check
    /// the password first, which is the better advice.
    ///
    /// The kind no longer chooses between the two forms; the limit does. The
    /// kind guard is not redundant: `.protectionIncomplete` carries a limit too
    /// (`Type2PasswordDriver.presentCredential`), and `WriteFlowModel` files any
    /// limit-bearing refusal as `unlockRefusal` without looking at its kind, so
    /// this is what confines the swap to the two authentication outcomes. Both
    /// messages already exist in the catalogue, so this adds no string.
    /// A third state joined the two on 2026-09-20: a refusal from a tag that
    /// **hides** its limit. A read-protected Type-2 tag keeps `AUTH_LIM` behind
    /// the gate the password is trying to open, so the driver reads no number
    /// and, said as `nil`, that was indistinguishable here from a tag that
    /// reported none. The prompt then came back in its neutral first-run copy
    /// after a refusal, telling the owner nothing, and the same button spent the
    /// next try. `limitReading` separates the two, and both readings that say
    /// something about a counter now replace the prompt's own words.
    var unlockPromptCopy: LocalizedStringResource? {
        guard limitReading != .notRead, kind == .authFailed || kind == .authInconclusive else { return nil }
        return userMessage
    }
}
