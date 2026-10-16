import Foundation
import HexNFCKit
import HexNFCRecords

/// What a tap is going to touch on the tag, stated rather than inferred.
///
/// The editor spelled its own answer inline: `(existing.protectFromPage ?? 0)
/// <= ndefUpper`, then `if writeBlocked || removeProtection`. That is two of
/// the six intents this app actually has, written where only one flow can read
/// them. The Operations sheet has the other four and nowhere to put them, which
/// is why every one of its operations either authenticates by accident or not
/// at all: erase writes the data area and takes no credential, the memory dump
/// reads gated pages and takes no credential, and format works on a protected
/// tag only because its one write lands on page 3, below every AUTH0 this app
/// writes.
///
/// Making the question explicit is what lets one preamble serve both routes. It
/// also turns that last sentence from an accident into an invariant recorded at
/// the single call site that depends on it.
///
/// This lives in `FlowModels` and not in `Screens` on purpose: every file under
/// `Screens/` is `#if os(iOS)` and `swift test` on macOS skips it whole, so a
/// rule that has to be tested cannot live there. `ProtectionCardSeed` states
/// the same placement rule and is the precedent.
struct TagAccessIntent: OptionSet, Sendable, Hashable {
    let rawValue: Int

    /// Reads pages that a read gate would cover.
    static let readsGatedPages = TagAccessIntent(rawValue: 1 << 0)
    /// Writes inside the NDEF data area.
    static let writesDataArea = TagAccessIntent(rawValue: 1 << 1)
    /// Writes a configuration page: AUTH0, ACCESS, PWD, PACK, a lock byte.
    static let writesConfigPages = TagAccessIntent(rawValue: 1 << 2)

    /// Whether this tap needs the tag's credential before it can do its work.
    ///
    /// An option set rather than an enum because one editor run both writes the
    /// data area and writes config pages, and "the most gated wins" is exactly
    /// an OR over the members.
    ///
    /// `protectFromPage ?? 0` has to read as "everything is gated", and the nil
    /// is not a missing value. `Type2PasswordDriver.readState()` projects a
    /// read-gated tag with `protectFromPage: nil`, because the page number is
    /// behind the very gate it is describing. Defaulting that to the first data
    /// page, or to anything above `ndefUpperBound`, would answer "no credential
    /// needed" about the one tag that certainly needs one.
    func needsCredential(given state: TagProtection, ndefUpperBound: Int) -> Bool {
        guard state.passwordProtect else { return false }
        if contains(.writesConfigPages) {
            return true
        }
        if contains(.writesDataArea), (state.protectFromPage ?? 0) <= ndefUpperBound {
            return true
        }
        if contains(.readsGatedPages), state.effectiveReadProtect {
            return true
        }
        return false
    }
}
