import Foundation
import HexNFCKit
import HexNFCRecords
import Observation

/// State for the TagEditor screen. Holds the in-flight records (mutable,
/// SwiftUI binds to this) plus the original snapshot for dirty tracking.
///
/// Saving as a preset and writing to a tag both live elsewhere — this model
/// only manages the list and its dirty bit.
@Observable
@MainActor
public final class EditFlowModel {
    public var records: [NDEFRecord]
    /// What the tag is known to hold: the snapshot captured at construction,
    /// then whatever the last successful write (`noteWritten`) or data-area
    /// reading (`apply`) established.
    public private(set) var original: [NDEFRecord]

    /// True if `records` differs from `original`.
    public var isDirty: Bool {
        records != original
    }

    /// Metadata about the physical tag this edit session came from (chip, UID,
    /// capabilities). `nil` for a blank build or a preset/history entry — those
    /// have no scanned tag behind them.
    public private(set) var tag: ScannedTagInfo?

    /// Password-protection *settings* configured in the editor. Applied by the
    /// write flow and persisted (settings only) when saved as a preset.
    public var protection: TagProtection = .none
    /// In-memory secret for `protection` — never stored on this model beyond the
    /// session; stashed into the Keychain only when saved as a preset, and
    /// handed to the write flow via `pendingProtection()`. Family-tagged: the
    /// 4-byte PWD+PACK (Type-2), 16-byte AES key (Type-4) or 4-byte password
    /// (Type-5) all ride in here.
    public var protectionCredential: TagCredential?

    /// The protection state the tag had when this editor opened (detected at
    /// scan, or a preset's settings). Lets the write flow tell "remove the
    /// existing protection" (the user toggled it off) apart from "was never
    /// protected" — the toggle alone can't carry that intent.
    public private(set) var originalProtection: TagProtection

    /// `true` when the scan could not read the tag's protection state, so
    /// `originalProtection` is a default rather than a fact.
    ///
    /// The editor must not present it as "Off". A failed read tells us nothing,
    /// and saying "Off" turns nothing into a claim. Only the display is
    /// affected: the write flow reads protection again in its own session, so a
    /// tag that really is protected still stops for the password.
    public private(set) var protectionIsUnknown: Bool

    /// Where this editor's content came from, which decides what "nothing to
    /// write" means. See `isWriteOffered`.
    public enum Origin: Equatable, Sendable {
        /// A live scan. `original` is what the tag in hand was read to hold, so
        /// an unedited editor would write the tag's own state back onto it.
        case liveScan
        /// A history row. Stored content whose job is to be put onto a tag,
        /// and the one-tap write puts it onto whichever tag is held.
        case history
        /// A blank build, with nothing behind it until it writes.
        case build
    }

    /// Passed at construction and never inferred. A history row and a live scan
    /// whose lock read was lost carry the same `tag` shape, and `apply` moves the
    /// fields that differ, so any inference would sooner or later call a scan a
    /// history row and offer its own content back to it.
    public let origin: Origin

    /// The arm this editor's own write last proved on a tag, in wire terms.
    ///
    /// Set only together with that write's own read-back, and dropped whenever
    /// it could have gone stale: any other protection reading, the start of any
    /// write that changes protection, and the Operations sheet opening, which
    /// can arm, re-key or remove without publishing anything when its own
    /// read-back fails. A stale proof here is the dangerous direction: it would
    /// withdraw an arm the tag does not hold.
    public private(set) var provenArm: ProvenArm?

    /// `origin` goes last and has no default, like `WriteFlowModel`'s
    /// `dataArea`: a default is a claim about which editor a caller meant, and
    /// the wrong one either hides Write or offers a tag its own state back.
    public init(
        records: [NDEFRecord] = [],
        tag: ScannedTagInfo? = nil,
        protection: TagProtection = .none,
        protectionCredential: TagCredential? = nil,
        protectionIsUnknown: Bool = false,
        origin: Origin
    ) {
        self.records = records
        original = records
        self.tag = tag
        self.protection = protection
        originalProtection = protection
        self.protectionCredential = protectionCredential
        self.protectionIsUnknown = protectionIsUnknown
        self.origin = origin
    }

    /// Bumped every time a reading changes what this editor knows about the
    /// tag's lock bits, so a view can fire its moment exactly once per change.
    public private(set) var lockMomentCount = 0
    /// The same, for protection.
    public private(set) var protectionMomentCount = 0

    /// The whole-tag lock verdict, or `.unknown` when nothing was read.
    public var lockState: TagLockState {
        tag?.lock.state ?? .unknown
    }

    /// `true` when a read established that this tag refuses every write.
    ///
    /// Deliberately narrow. `.partlyLocked` does not block, because the unburned
    /// half may still take a write and withdrawing the affordance over an
    /// unproven region strands the user with a tag they could have used.
    /// `.writtenNotWitnessed` does not block either, because it is an absence of
    /// proof, and acting on it would be making the claim we declined to make.
    public var isWriteBlocked: Bool {
        lockState == .locked
    }

    /// Take a reading from a tag, but only when it is a reading about *this*
    /// editor's tag.
    ///
    /// The identity guard is the whole point. `OperationsSheet` is handed only
    /// the app model, every operation opens its own session against whatever tag
    /// the user then presents, and `OperationsFlowModel`'s typed-UID gate
    /// compares tap 2 against the UID *it* read on tap 1, never against this
    /// editor's tag. A stack of blanks is easy to mix up, so a reading from any
    /// other tag is discarded rather than guessed at. An editor with no tag
    /// behind it (a blank build, a preset, a history row with no UID) has no
    /// identity to match and takes nothing.
    ///
    /// `arm` is what this editor's own write proved, and it travels with that
    /// write's reading: it is accepted only when the reading says the same tag
    /// is armed. A reading that carries none, which is every Operations
    /// reading, clears the one held.
    ///
    /// - Returns: `true` when something changed.
    @discardableResult
    public func apply(_ observation: TagObservation, provenArm arm: ProvenArm? = nil) -> Bool {
        guard let mine = tag?.uidHex, !mine.isEmpty else {
            // No identity, so no reading is taken. The one thing such an editor
            // can still learn is that its own write proved an arm, and it may
            // only act on it through `isWriteOffered`: `protectionToSend` keeps
            // the arm in the next write, because that write may be to a
            // different tag.
            if let arm, arm.uid == observation.uid, observation.protection?.passwordProtect == true {
                provenArm = arm
            }
            return false
        }
        guard Self.normalisedUID(mine) == Self.normalisedUID(observation.uid.hexString) else { return false }

        var changed = false

        if let reading = observation.lock, reading.state != .unknown, tag?.lock != reading {
            // Only on an actual change. The moment counters drive a haptic, and
            // re-delivering the same reading (a retry that reads the same tag,
            // or a latch drained twice) would fire it at a card that did not
            // move.
            tag?.lock = reading
            lockMomentCount += 1
            changed = true
        }

        if let read = observation.protection {
            // `protection` is the user's *intent* and `originalProtection` is
            // the baseline the write flow computes a removal against. They are
            // not the same thing. Rebasing the baseline is what stops
            // `wantsProtectionRemoved` lying about the next write; overwriting
            // the intent as well would silently cancel a change the user had
            // already configured in the Protection card.
            //
            // Two questions, and the guard needs both. Whole-value inequality
            // answers the first, "is there an intent at all", and nothing else
            // can: a card nobody has touched holds a copy of the baseline.
            //
            // What it cannot answer is the second, "has the tag arrived at it",
            // because the same armed tag is described differently at each end.
            // The card stages `protectFromPage: nil`, meaning "derive it at
            // write time", and `hasStoredCredential: true`; a Type-2 read-back
            // reports the resolved page and can never report a credential at
            // all, since a PWD is not readable. So after an arm the two stayed
            // unequal for the rest of the editor session, the intent looked
            // pending for ever, and a removal run from the Operations sheet
            // could not reach the card that had armed the tag. Found on an
            // NTAG213 on 2026-09-22: the card kept saying "Password, write-only"
            // about an open tag, and since `pendingProtection()` is built from
            // the same value, the next write would have put the password back.
            //
            // `intentReached` therefore asks only about fields a reading can
            // speak about, and about the gate's knobs only when the gate is on.
            // Per family, through `effectiveStyle`: an NTAG424 keeps its read
            // gate, a SLIX2 its kind and an Ultralight C its start page inside
            // `style`, with the flat fields left at their defaults on both
            // sides, so a flat comparison called any staged change to them
            // "reached" and the next same-tag reading discarded it.
            let intentReached = protection.passwordProtect == read.passwordProtect
                && (!read.passwordProtect
                    || Self.gateMatches(staged: protection.effectiveStyle, read: read.effectiveStyle))
            let hadStagedChange = protection != originalProtection && !intentReached
            let rebased = Self.merged(read, into: originalProtection)
            let moved = rebased != originalProtection || protectionIsUnknown
            originalProtection = rebased
            protectionIsUnknown = false
            if !hadStagedChange {
                protection = originalProtection
            }
            if moved {
                protectionMomentCount += 1
                changed = true
            }
            // Every protection reading re-decides the proof, and only this
            // editor's own write can carry one. An Operations re-key or removal
            // that did report back lands here with none, and clears it.
            provenArm = (arm?.uid == observation.uid && read.passwordProtect) ? arm : nil
        }

        // A Capability Container read back as correct refutes exactly one
        // verdict, and it is not a licence to declare the tag readable. Page 3
        // says nothing about the data area, which is the half that was wrong on
        // the tag this branch was written for. So a format clears the "no
        // Capability Container" notice and leaves `.unreadableDataArea` alone;
        // the state it moves to is `.unknown`, because what the data area holds
        // is now genuinely unestablished.
        if observation.formatted == true, tag?.formatState == .noCapabilityContainer {
            tag?.formatState = .unknown
            changed = true
        }

        // An NDEF message read back off the tag is the stronger fact, and the
        // only one that clears a damaged data area: it proves the whole
        // structure walks. This is what an erase or a verified write publishes.
        if observation.ndefReadable == true, tag?.formatState != .readable {
            tag?.formatState = .readable
            changed = true
        }

        // The data area, under the same rule the protection branch follows: a
        // reading rebases the baseline, and it overwrites what the user is
        // editing only when they are not editing anything. `isDirty` is the
        // whole test, and it is exact here in a way the protection branch could
        // not be, because records are compared against the same list in the same
        // vocabulary rather than against a read-back that loses fields.
        //
        // An erase run from the Operations sheet publishes an empty list, and
        // before this branch existed the editor went on showing the records it
        // had cleared. `dataAreaChange` is built from the same list, so the next
        // write put them back (2026-09-22, NTAG213).
        if let observed = observation.records {
            if !isDirty {
                records = observed
            }
            original = observed
            changed = true
        }

        // `protectionCredential` is deliberately never touched here.
        // `ProtectionConfigSheet`'s rule is "only ever set a credential, never
        // clear one": discarding the secret because a read-back says the tag is
        // open destroys the thing a removal still needs, which is the shape that
        // stranded a real tag on 2026-09-04.
        return changed
    }

    /// Whether an armed reading describes the gate the user staged, in the
    /// knobs a reading of that family can report.
    ///
    /// A staged `nil` start page means "the chip's first data page, resolved at
    /// write time", which a reading cannot distinguish from an explicit one, so
    /// it matches whatever page the tag reports. The Type-2 arm is exactly the
    /// comparison this replaced. A family mismatch is never "reached": a staged
    /// NTAG424 key is not something a Type-2 reading can have arrived at.
    private static func gateMatches(staged: ProtectionStyle, read: ProtectionStyle) -> Bool {
        switch (staged, read) {
        case (.type2(let wanted), .type2(let found)):
            wanted.readProtect == found.readProtect
                && (wanted.protectFromPage ?? found.protectFromPage) == found.protectFromPage

        case (.type4(let wanted), .type4(let found)):
            wanted.readProtect == found.readProtect

        case (.type5(let wanted), .type5(let found)):
            wanted.kind == found.kind

        case (.ultralightC(let wanted), .ultralightC(let found)):
            wanted.readProtect == found.readProtect
                && (wanted.protectFromPage ?? found.protectFromPage) == found.protectFromPage

        default:
            false
        }
    }

    /// A read-back is a projection and it loses fields. A Type-2 configuration
    /// read always reports `hasStoredCredential: false`, and the read-gated
    /// projection reports `protectFromPage: nil`. Merge rather than replace, so
    /// a reading never erases something the editor already knew.
    private static func merged(_ read: TagProtection, into existing: TagProtection) -> TagProtection {
        var result = read
        result.hasStoredCredential = existing.hasStoredCredential
        if result.protectFromPage == nil, read.passwordProtect, existing.passwordProtect {
            result.protectFromPage = existing.protectFromPage
        }
        return result
    }

    /// Colons out, upper-cased. The editor's side is `Data.hexString` for a live
    /// scan and `HistoryEntry.displayUID` for a rebuilt row. The two are
    /// documented to agree; normalising means the guard does not depend on that
    /// holding.
    private static func normalisedUID(_ value: String) -> String {
        value.replacingOccurrences(of: ":", with: "").uppercased()
    }

    /// The bytes of the tag this editor is about, for a write that has to
    /// confirm which tag it is changing. `nil` for an editor with no tag behind
    /// it: a blank build, a preset, a history row with no UID.
    ///
    /// Parsed here rather than in the sheet that builds the write flow, because
    /// that sheet is `#if os(iOS)` and never compiles on the test host. Both
    /// producers of `uidHex` are colon-delimited (`Data.hexString` and
    /// `HistoryEntry.displayUID`), and anything that is not an even-length run
    /// of hex is no identity at all.
    public var targetUID: Data? {
        guard let uidHex = tag?.uidHex else { return nil }
        let digits = Self.normalisedUID(uidHex)
        guard !digits.isEmpty, digits.count.isMultiple(of: 2),
              digits.allSatisfy(\.isHexDigit)
        else { return nil }
        return Data.parseHex(digits)
    }

    /// `true` when the tag started out protected and the user has switched
    /// protection off — the write must authenticate and clear the lock, not just
    /// skip applying one.
    public var wantsProtectionRemoved: Bool {
        originalProtection.passwordProtect && !protection.passwordProtect
    }

    /// `true` when there is a protection change the tag does not already hold:
    /// a configured arm (a credential is in hand) that this editor has not
    /// already proved there, or the removal of the tag's existing protection.
    /// `isDirty` tracks only the record list, so without this a protection-only
    /// change on an unedited tag (e.g. enabling a password on a scanned blank
    /// tag) would leave nothing to write.
    public var hasProtectionChange: Bool {
        (pendingProtection() != nil && !armIsSettled) || wantsProtectionRemoved
    }

    /// What the next write should do to the tag's data area.
    ///
    /// `isDirty` alone is the wrong test, and the `!hasProtectionChange` half is
    /// why. A history row is not dirty until edited, and pressing Write on one
    /// with nothing else staged still has to put its records down. A change
    /// that is *purely* about protection leaves the data area alone, on every
    /// origin, including a history row whose records have not been edited.
    public var dataAreaChange: DataAreaChange {
        isDirty || !hasProtectionChange ? .replace(records) : .untouched
    }

    /// Bundle of settings + resolved secret to hand the write flow, or `nil`
    /// when protection isn't requested or no credential has been entered yet.
    ///
    /// Says what is *staged*, not what is left to send. The write takes
    /// `protectionToSend()`; this stays as it was because the Protection card,
    /// a preset save and a removal all need the staged credential whether or not
    /// the tag already holds it.
    public func pendingProtection() -> PendingProtection? {
        guard protection.passwordProtect, let credential = protectionCredential else { return nil }
        return PendingProtection(settings: protection, credential: credential)
    }

    /// `true` when the arm staged now would put exactly the frames on the air
    /// that this editor's own write already proved on the tag.
    ///
    /// Compared as `ProtectionSpec`, resolved against the same first data page
    /// the proven write used, so that "no custom start page" means the page it
    /// meant then. Wire terms are the only safe vocabulary here. A comparison
    /// against a reading could never see a new password or PACK, because no
    /// family's read-back reports one, and treating a new password as already on
    /// the tag is a credential desync: the tag keeps the old one while the app
    /// believes the new.
    ///
    /// An editor with a tag behind it also needs that tag to still read armed.
    /// A build has none, and takes no readings, so the proof alone decides.
    var armIsSettled: Bool {
        guard let arm = provenArm, let staged = pendingProtection(),
              let spec = ProtectionSpec.make(
                  settings: staged.settings,
                  credential: staged.credential,
                  defaultFirstDataPage: arm.firstDataPage
              ),
              spec == arm.spec
        else { return false }
        guard targetUID != nil else { return true }
        return originalProtection.passwordProtect && !protectionIsUnknown
    }

    /// The arm the next write should carry, or `nil`.
    ///
    /// A settled arm is not sent again to an editor's own tag. An editor with no
    /// `targetUID` still sends it: its write is not pinned to one tag, so the
    /// next tag may well not be the one already armed, and dropping the arm
    /// there would put records on it with no password while the card says
    /// "Password".
    public func protectionToSend() -> PendingProtection? {
        guard let pending = pendingProtection() else { return nil }
        return armIsSettled && targetUID != nil ? nil : pending
    }

    /// Whether Write has anything to do.
    ///
    /// A live scan and a build are offered only a change: an unedited scan
    /// would put the tag's own state back on it, and a build that has written
    /// its content holds nothing new until it is edited. A history row is
    /// offered whenever it holds something, because its job is to put stored
    /// content onto a tag and the one-tap write goes to whichever tag is held.
    /// A tag read back as permanently locked is offered nothing.
    public var isWriteOffered: Bool {
        guard !isWriteBlocked else { return false }
        switch origin {
        case .liveScan, .build:
            return isDirty || hasProtectionChange

        case .history:
            return !records.isEmpty || isDirty || hasProtectionChange
        }
    }

    /// Record what a successful write put down, from what that write carried.
    ///
    /// Not from `records`. The hand-back arrives up to a few seconds after
    /// `.done`, from a task that outlives a swipe dismissal, and an edit made in
    /// that window was never written: taking the list on screen would call it
    /// written and withdraw Write from content the tag does not hold.
    ///
    /// And only when the write landed on this editor's tag. A plain record
    /// write is not pinned and goes to whichever tag is held, so a stack of
    /// blanks makes it easy to write an edit to the wrong one. Recording that as
    /// this tag's content would withdraw Write from a tag that never received
    /// it. An editor with no tag of its own (a build) records every write.
    public func noteWritten(_ dataArea: DataAreaChange, to uid: Data?) {
        guard targetUID == nil || uid == targetUID else { return }
        if case .replace(let written) = dataArea {
            original = written
        }
    }

    /// Whether a reading is about this editor's tag, for the sheet deciding
    /// what to hold until its covering sheet has gone.
    ///
    /// `apply` would discard a reading about another tag anyway. Asking first
    /// matters because the sheet holds one pending reading, and merging
    /// readings of two different tags keeps only the later: an Operations run
    /// on this tag followed by one on another tag used to lose this tag's
    /// reading, leaving the card claiming a password the tag no longer had.
    /// An editor with no tag of its own takes every reading, as before.
    public func isAboutThisTag(_ uid: Data) -> Bool {
        guard let target = targetUID else { return true }
        return uid == target
    }

    /// Everything one press of Write sends.
    public struct WriteRequest: Equatable, Sendable {
        public let dataArea: DataAreaChange
        public let protection: PendingProtection?
        public let removeProtection: Bool
        /// The only tag this write may land on, or `nil` when any tag will do.
        public let pinnedUID: Data?
    }

    /// Decide what a press of Write sends, and drop any proof it could
    /// invalidate. One place, so the sheet and the tests cannot drift apart
    /// about it.
    ///
    /// The pin is what makes withholding a settled arm safe. The write's only
    /// check of `targetUID` is on its identify tap, and that tap exists only
    /// for a write that arms or removes protection, so a write with the arm
    /// held back would otherwise go in one tap to whatever tag is presented,
    /// and put the records on it with no password while the card says
    /// "Password". Before the arm could be held back, re-sending it is what
    /// raised that tap and refused the wrong tag.
    ///
    /// The proof goes when this write changes protection at all. Until its own
    /// proof comes back, which credential the tag answers to is not known, and a
    /// proof kept across a write that tore after the PWD page would let the old
    /// credential read as settled again. Read before it goes: dropping it flips
    /// a settled arm back to pending, and a data area read after that would turn
    /// a build's `.replace(records)` into `.untouched`.
    public func prepareWrite() -> WriteRequest {
        let dataArea = dataAreaChange
        let arming = protectionToSend()
        let removing = wantsProtectionRemoved
        let withheld = pendingProtection() != nil && arming == nil
        if arming != nil || removing {
            provenArm = nil
        }
        return WriteRequest(
            dataArea: dataArea,
            protection: arming,
            removeProtection: removing,
            pinnedUID: withheld ? targetUID : nil
        )
    }

    /// The Operations sheet is opening. It can arm, re-key or remove on this
    /// tag and publish nothing when its read-back fails, so nothing this editor
    /// proved before it opened can be relied on after.
    public func forgetProvenArm() {
        provenArm = nil
    }

    public func append(_ record: NDEFRecord) {
        records.append(record)
    }

    public func remove(at index: Int) {
        guard records.indices.contains(index) else { return }
        records.remove(at: index)
    }

    public func remove(id: UUID) {
        records.removeAll { $0.id == id }
    }

    public func move(from source: IndexSet, to destination: Int) {
        // SwiftUI's `move(fromOffsets:toOffset:)` only exists when SwiftUI is
        // in scope; we re-implement it here so the flow model stays a pure
        // Foundation type and is testable from macOS test bundles.
        let extracted = source.compactMap { records.indices.contains($0) ? records[$0] : nil }
        for index in source.sorted(by: >) {
            records.remove(at: index)
        }
        let adjusted = destination - source.filter { $0 < destination }.count
        records.insert(contentsOf: extracted, at: max(0, min(adjusted, records.count)))
    }

    public func replace(_ record: NDEFRecord) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[index] = record
    }

    public func markClean() {
        original = records
    }

    public func revert() {
        records = original
    }
}

/// Display-ready snapshot of a scanned tag's identity, built from a
/// `ConnectedTag` by `ScanFlowModel` (live scans) or rebuilt from a
/// `HistoryEntry` (history rows). Stores only primitives and pre-localized
/// strings; the `capabilitySummary(fromRaw:)` helper bridges the raw
/// `TagCapability` bitmask both producers carry.
public struct ScannedTagInfo: Equatable, Sendable {
    public var chipName: String?
    public var familyName: String?
    public var manufacturer: String?
    public var uidHex: String?
    /// Total addressable memory (`memoryLayout.byteCount`).
    public var totalBytes: Int?
    /// Usable NDEF capacity, when it differs from `totalBytes` — lets the card
    /// show "256 Bytes (416B Total)". `nil` for chips with no distinct
    /// blind-readable NDEF area (DESFire, FeliCa).
    public var ndefBytes: Int?
    /// Comma-joined, already-localized list of supported operations, or `nil`.
    public var capabilitySummary: String?
    /// Comma-joined, already-localized list of the chip's *extra* silicon
    /// features: originality signature, tap counter, tamper loop, SUN. Split
    /// from `capabilitySummary` so the "Supports" line stays the short list of
    /// things the user can do, and the hardware facts get their own row instead
    /// of being invisible. `nil` when the chip has none of them.
    public var featureSummary: String?
    /// Whether this chip can take password protection — `true` when it advertises
    /// `.passwordAuth` *and* a backend exists for its family (`protectionStyle`
    /// non-nil). Gates the editor's Protection affordance; not derivable from
    /// `capabilitySummary` alone (ICODE SLIX advertises `.passwordAuth` but only
    /// works once its Type-5 backend is wired).
    public var supportsPasswordProtection: Bool

    /// Which family's protection model the editor should configure for this chip
    /// (Type-2 PWD/PACK, Type-4 AES key, Type-5 password), or `nil` when none.
    /// Drives `ProtectionConfigSheet`'s per-family fields. Defaults to `.type2`
    /// for a blank build (the common writable tag); the write validates against
    /// the real chip.
    public var protectionStyle: ProtectionStyle?

    /// What the scan established about the tag's NDEF structure. Drives the
    /// notice on the scan result and the nudge in the editor, both of which used
    /// to render an unreadable tag as an ordinary empty one and then fail at
    /// write time.
    ///
    /// Never set from a history row: this is a fact about the tag right now, not
    /// something worth replaying from a snapshot. `.unknown` claims nothing and
    /// renders nothing, which is what a history row deserves.
    public var formatState: TagFormatState

    /// Read-only silicon facts collected at the end of the scan: originality
    /// signature, tap counter, tamper loop. Empty by default, and empty for
    /// history rows: a counter reading is a measurement taken at a moment, and
    /// replaying a stale one as though it were current would be worse than
    /// showing nothing.
    public var diagnostics: TagDiagnostics

    /// What this tag's lock bytes said during the scan.
    ///
    /// Never set from a history row, on the same rule as `formatState` and
    /// `diagnostics`: a lock is a fact about the tag in the field right now. A
    /// lock bit latches, so a stored `true` could not go stale, but a history
    /// row stores no lock data at all, and a stored `false` goes stale the
    /// moment the tag is locked somewhere else. `.notRead` claims nothing.
    public var lock: TagLockReading = .notRead

    /// What the chip reported about itself when we couldn't name it. Set only
    /// when `chipName` is `nil`; drives the "Chip not recognised" rows so an
    /// unknown tag is still diagnosable from the scan card alone.
    public var unidentifiedSummary: String?
    /// Raw `GET_VERSION` bytes behind `unidentifiedSummary`, for bug reports.
    public var unidentifiedVersionHex: String?

    public init(
        chipName: String? = nil,
        familyName: String? = nil,
        manufacturer: String? = nil,
        uidHex: String? = nil,
        totalBytes: Int? = nil,
        ndefBytes: Int? = nil,
        capabilitySummary: String? = nil,
        supportsPasswordProtection: Bool = false,
        protectionStyle: ProtectionStyle? = nil,
        unidentifiedSummary: String? = nil,
        unidentifiedVersionHex: String? = nil,
        featureSummary: String? = nil,
        formatState: TagFormatState = .unknown,
        diagnostics: TagDiagnostics = TagDiagnostics(),
        lock: TagLockReading = .notRead
    ) {
        self.unidentifiedSummary = unidentifiedSummary
        self.unidentifiedVersionHex = unidentifiedVersionHex
        self.featureSummary = featureSummary
        self.formatState = formatState
        self.diagnostics = diagnostics
        self.lock = lock
        self.chipName = chipName
        self.familyName = familyName
        self.manufacturer = manufacturer
        self.uidHex = uidHex
        self.totalBytes = totalBytes
        self.ndefBytes = ndefBytes
        self.capabilitySummary = capabilitySummary
        self.supportsPasswordProtection = supportsPasswordProtection
        self.protectionStyle = protectionStyle
    }

    /// Whether there's anything worth showing a "Tag" section for.
    public var hasContent: Bool {
        chipName != nil || familyName != nil || uidHex != nil || unidentifiedSummary != nil
    }

    /// Localised, comma-joined "Supports" summary for a raw `TagCapability`
    /// bitmask (e.g. `"Read, Write, Lock"`), or `nil` if it carries none of the
    /// user-facing operations. Single source of truth for both the live scan and
    /// the rebuilt-from-history path.
    public static func capabilitySummary(fromRaw raw: UInt32) -> String? {
        let caps = TagCapability(rawValue: raw)
        var labels: [String] = []
        if caps.contains(.ndefRead) {
            labels.append(String(localized: "Read"))
        }
        if caps.contains(.ndefWrite) {
            labels.append(String(localized: "Write"))
        }
        if caps.contains(.passwordAuth) {
            labels.append(String(localized: "Password"))
        }
        // Named for the cipher, not folded into "Password". An Ultralight C takes
        // a 16-byte 3DES key and cannot be unlocked with a 4-byte password, so a
        // shared label would tell the user the wrong thing to go and find. This
        // line was previously absent entirely, which meant the card said nothing
        // at all about how the chip authenticates.
        if caps.contains(.tripleDESAuth) {
            labels.append(String(localized: "3DES key"))
        }
        if caps.contains(.permanentLock) {
            labels.append(String(localized: "Lock"))
        }
        if caps.contains(.rawTransceive) {
            labels.append(String(localized: "Raw commands"))
        }
        return labels.isEmpty ? nil : labels.joined(separator: ", ")
    }

    /// Re-resolve the protection backend for a tag we are rebuilding from a
    /// stored row rather than a live `ConnectedTag` (a history entry).
    ///
    /// A history row persists the chip's *display name* and its capability
    /// bitmask but not its family, and `backendStyle` needs the family, so the
    /// name is looked back up in the catalog. `nil` for a chip we can't name,
    /// which correctly hides the affordance rather than guessing Type-2 at it.
    ///
    /// Lives here, next to the live-scan path, rather than inside the iOS-only
    /// view that calls it: this is the same gate `supportsPasswordProtection`
    /// applies, and a gate that decides whether protection UI appears should not
    /// be somewhere `swift test` can't reach.
    public static func protectionStyle(forChipNamed name: String?, capabilitiesRaw raw: UInt32) -> ProtectionStyle? {
        guard let name, let profile = ChipCatalog.all.first(where: { $0.displayName == name }) else { return nil }
        return ProtectionStyle.backendStyle(
            for: profile.family,
            capabilities: TagCapability(rawValue: raw)
        )
    }

    /// Localised, comma-joined summary of the chip's extra silicon features, or
    /// `nil` when it has none.
    ///
    /// These are all things identification already establishes and the card never
    /// showed: whether the chip carries an NXP originality signature, a read-only
    /// tap counter, a tamper loop, or SUN mirroring. They're the facts that
    /// distinguish otherwise-similar chips (an NTAG213 TT from an NTAG213, an
    /// Ultralight EV1 from an Ultralight C), so leaving them out made the card
    /// look identical for chips that aren't.
    public static func featureSummary(fromRaw raw: UInt32) -> String? {
        let caps = TagCapability(rawValue: raw)
        var labels: [String] = []
        if caps.contains(.signatureRead) {
            labels.append(String(localized: "Originality signature"))
        }
        if caps.contains(.counterRead) {
            labels.append(String(localized: "Tap counter"))
        }
        if caps.contains(.tamperStatus) {
            labels.append(String(localized: "Tamper loop"))
        }
        if caps.contains(.sunMessages) {
            labels.append(String(localized: "SUN mirroring"))
        }
        if caps.contains(.fastRead) {
            labels.append(String(localized: "Fast read"))
        }
        return labels.isEmpty ? nil : labels.joined(separator: ", ")
    }
}
