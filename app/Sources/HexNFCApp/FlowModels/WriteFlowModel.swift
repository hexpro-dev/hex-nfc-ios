import Foundation
import HexNFCKit
import HexNFCRecords
import HexNFCStorage
import Observation

/// Everything the write flow needs to apply password protection in the same
/// tap that writes the records: the non-secret settings plus the resolved
/// secret. Lives only in memory — the secret comes from the editor's live input
/// or the Keychain (for a saved preset), never from a persisted model object.
/// `Hashable` because `OperationsFlowModel.Operation` carries one and is
/// itself `Hashable`. Both stored properties already are, so this costs
/// nothing and keeps the two routes on one type rather than on two that can
/// drift.
public struct PendingProtection: Hashable, Sendable {
    public var settings: TagProtection
    /// Family-tagged secret to apply (Type-2 PWD+PACK / Type-4 AES key /
    /// Type-5 password).
    public var credential: TagCredential

    public init(settings: TagProtection, credential: TagCredential) {
        self.settings = settings
        self.credential = credential
    }
}

/// What a write does to the tag's data area.
///
/// `.untouched` is not "write nothing": it is a write whose subject is the
/// tag's configuration, and it says so rather than leaving the data area to be
/// rewritten with whatever the caller happened to be holding. An editor
/// protection-only change used to read the message off the tag and put the same
/// bytes straight back (2026-09-21: `READ p3` at 13:34:32.288 returned it, and
/// the write landed 22 ms later).
/// An arm a write put on a tag and the driver proved there.
///
/// Kept in wire terms, as the `ProtectionSpec` that went on the air and the
/// page a `nil` start page was resolved against, because that is the only
/// vocabulary in which "the next arm would change nothing" can be asked
/// without losing a field. The editor and a read-back describe the same armed
/// tag differently (`protectFromPage: nil` against the resolved page, a
/// credential against none at all, since no family's read-back can see one),
/// and a comparison in either of those vocabularies either never matches or
/// matches a new password it cannot see. A new password, PACK, key, start page,
/// read gate or style each produce a different spec.
public struct ProvenArm: Hashable, Sendable {
    public let uid: Data
    public let spec: ProtectionSpec
    public let firstDataPage: Int

    public init(uid: Data, spec: ProtectionSpec, firstDataPage: Int) {
        self.uid = uid
        self.spec = spec
        self.firstDataPage = firstDataPage
    }
}

public enum DataAreaChange: Equatable, Sendable {
    case replace([NDEFRecord])
    case untouched

    /// What a Library preset write does to the tag's data area.
    ///
    /// The editor's Save menu offers a preset with no records at all and calls
    /// it "a preset that just locks tags". The Library route used to write that
    /// preset's empty message anyway, so arming a tag from the Library cleared
    /// whatever it was carrying, which nobody asked for and nothing on the way
    /// through said.
    ///
    /// Both halves of the condition matter. Answering `.untouched` for any
    /// records-free preset would turn a deliberate clear into a no-op, and
    /// clearing a tag is an ordinary thing to keep a preset for. It is the
    /// combination that is unambiguous: no records **and** protection to arm
    /// means the records were never the point.
    ///
    /// Lives here rather than beside its one call site because that call site
    /// is in `RootView`, which is `#if os(iOS)` and invisible to `swift test`.
    /// A rule about what reaches a tag has to be testable.
    public static func forPreset(records: [NDEFRecord], arming: Bool) -> DataAreaChange {
        records.isEmpty && arming ? .untouched : .replace(records)
    }
}

/// State machine for "open a fresh NFC session and write these records back
/// to a tag, then verify by re-reading and diffing". When `protection` is set
/// and the chip supports it, password protection is applied *after* a clean
/// verify (never before — a read-protected tag can't be verified afterwards).
@Observable
@MainActor
public final class WriteFlowModel {
    public enum Phase: Equatable, Sendable {
        case ready
        /// Tap 1 of a confirmed write: read the tag's UID and its state, write
        /// nothing. Only reached when `requiresUIDConfirmation` is true.
        case identifying
        /// Tap 1 is over and its session is torn down. The user is typing the UID
        /// the tag reported, with no NFC session open, exactly as Operations
        /// asks for it.
        case awaitingConfirmation(uidHex: String)
        case polling
        case writing
        case verifying
        case applyingProtection
        case removingProtection
        /// The target tag is already password-protected over the area we need to
        /// write, and we don't hold (a correct) password for it. The UI collects
        /// one and calls `unlock(with:)`. We can't prompt mid-session — the NFC
        /// sheet owns the screen — so this ends the session and re-taps.
        case needsUnlock
        case done
        /// The user closed the system sheet before any tag was in play, on a
        /// write that has never had one. Nothing was read or written, so there
        /// is nothing to report: the sheet closes, back to the editor, or to Home
        /// for a preset written from the Library. See `TagContact` for why a
        /// write that ever had a tag, on either tap, never lands here.
        case cancelled
        /// The session reached its time limit with nothing in the field, on a
        /// write that has never had a tag. Not a failure: no error and no
        /// diagnostics, and `retry()` runs it again.
        case noTagFound
        case error(message: String, diagnostics: String)
    }

    public private(set) var phase: Phase = .ready
    public private(set) var transitionCount: Int = 0

    /// What this write does to the tag's data area.
    ///
    /// **Deliberately not defaulted**, like `credentials` and `uidConfirmation`.
    /// A default would be a claim about which of the two a caller meant, and
    /// the wrong one rewrites bytes the tag already holds. The same argument
    /// rules out `[NDEFRecord]?` with `nil` for "leave it alone": optional
    /// promotion would let every existing call site keep compiling, which is
    /// the whole hazard.
    public let dataArea: DataAreaChange

    public var protection: PendingProtection?

    /// Credential used to authenticate *past* the tag's existing protection
    /// before writing — distinct from `protection`, which is the (new) protection
    /// to apply afterwards. Seeded from the editor/preset when known; otherwise
    /// filled in by `unlock(with:)` after the `.needsUnlock` prompt.
    public var unlockCredential: TagCredential?
    /// `true` when the last unlock attempt authenticated with the wrong
    /// credential, so the prompt can say so rather than repeating its first-run
    /// copy.
    public private(set) var unlockFailed = false

    /// The refusal behind the last failed unlock, kept only when the prompt has
    /// to say something its own copy cannot: that the tag has an attempt limit.
    ///
    /// On an exhausted `AUTH_LIM` the chip refuses the **correct** password
    /// (bench 2026-09-10, tags A and B), and "That password didn't unlock the tag.
    /// Check it and try again." tells that user to doubt a password that is right
    /// and to spend another try. The driver already qualifies the refusal when it
    /// read the limit (`TagError.attemptLimit`); this is how it reaches the prompt.
    /// See `TagError.unlockPromptCopy`.
    public private(set) var unlockRefusal: TagError?

    /// The protection family of the tag that triggered `.needsUnlock`. Lets the
    /// unlock prompt show the right field (4-byte password for Type-2/SLIX, a
    /// 16-byte AES key for an NTAG424) and build the matching `TagCredential`,
    /// instead of always assuming Type-2. Set when existing protection is detected.
    public private(set) var unlockStyle: ProtectionStyle?

    /// Remove the tag's existing password protection after writing (the user
    /// toggled protection off). Requires authenticating first — the unlock
    /// credential doubles as the secret `disableProtection` needs.
    public var removeProtection: Bool

    /// What the last protection change actually left on the tag. `nil` until one
    /// has run. A removal that proved the gate open and then failed to tidy the
    /// credential away reports here rather than as an error.
    public private(set) var protectionResidue: ProtectionResidue?

    /// The arm this write proved, or `nil`. What lets the editor stop offering
    /// the same arm again, so it is set on the driver's proof and never on
    /// `.done`: a write reaches `.done` on any residue the driver returns,
    /// including one whose gate read back open or whose PACK round trip failed.
    ///
    /// Cleared when a run starts, never in `reset()`. A swipe dismissal resets
    /// the model before its success hand-back reads this.
    public private(set) var provenArm: ProvenArm?

    /// The UID of the tag this write's write tap connected to, or `nil` before
    /// one did. A plain record write goes to whichever tag is presented, so the
    /// editor needs this to tell "my tag now holds these records" from "some
    /// other tag does". Kept across `reset()` for the same reason as
    /// `provenArm`: the hand-back reads it after a swipe dismissal.
    public private(set) var writtenUID: Data?

    /// What this write established about the tag it wrote to, from a read-back.
    ///
    /// Handed to the editor so a Protection card that was showing the state the
    /// tag had *before* the write stops showing it. `nil` when the write carried
    /// no protection change, or when the read-back could not be taken: a write
    /// that succeeded is never failed by this, and an unread state is never
    /// published as a finding.
    public private(set) var observation: TagObservation?

    /// Whether this caller's writes confirm the tag's UID before changing its
    /// protection. **Deliberately not defaulted**, like `credentials`: the one
    /// exempt route in the app is the Library preset write, and an exemption
    /// that arrives by forgetting an argument is the shape this whole change
    /// exists to remove.
    public enum UIDConfirmation: Hashable, Sendable {
        case required
        case notRequired
    }

    /// The tag this write is *about*, when the caller knows: the editor's
    /// scanned tag. `nil` for a build with no tag behind it and for the preset
    /// route, which is about whichever tag is presented.
    ///
    /// Checked on the identify tap, not on the write tap. It is what makes the
    /// typed UID mean something: without it the gate asks the user to confirm
    /// the identity of whatever they happen to be holding, which a user who
    /// picked up the wrong tag will confirm accurately.
    public let targetUID: Data?

    /// The only tag this write may land on, checked on the write tap itself.
    ///
    /// Separate from `targetUID`, which is checked only on the identify tap and
    /// is deliberately not a constraint on a plain record write: that write goes
    /// to whichever tag is presented. The editor sets this when it holds back
    /// an arm the tag already carries (`EditFlowModel.prepareWrite`), because
    /// holding it back also takes away the identify tap that used to refuse a
    /// different tag, and the records would otherwise go onto that tag with no
    /// password while the card says "Password".
    public let pinnedUID: Data?

    private let uidConfirmation: UIDConfirmation

    /// The UID the identify tap read. Survives a `.needsUnlock` round trip, so a
    /// tag whose password is typed between the taps is not re-identified.
    private var identifiedUID: Data?
    /// Whether the user has typed that UID back. Separate from `identifiedUID`
    /// because they answer different questions: what the tag is, and what the
    /// user consented to. Folding them made a mistyped password re-open the gate.
    private var uidConfirmed = false
    private var confirmationContinuation: CheckedContinuation<Bool, Never>?
    /// An answer that arrived before anything was waiting for it. See
    /// `waitForConfirmation()`.
    private var pendingConfirmation: Bool?

    /// Bumped by every cancel-shaped entry point, so a run already inside
    /// `begin()` can tell that the intent behind it is gone. `reset()` alone
    /// cannot stop one: `currentSession?.invalidate()` is a no-op until
    /// `CoreNFCSession` has actually created its reader session, which it does
    /// only after `NFCSessionClock.awaitCooldown()`, up to 2.5 s after the
    /// previous teardown. That window is exactly when the sheet's Cancel button
    /// is the only thing the user can reach.
    private var runToken = 0

    /// Whether the finished write's system NFC sheet has gone, and who is
    /// waiting for it to. See `systemSheetDismissal()`.
    private var systemSheetGone = false
    private var systemSheetWaiters: [CheckedContinuation<Void, Never>] = []

    private let factory: TagSessionFactory
    private var currentSession: TagSession?
    /// Whether any session of this write has had a tag. Nothing clears it, not
    /// `reset()`, `retry()` or `unlock(with:)`: once the identify tap or a write
    /// tap has had a tag, a cancel on a later tap is reported as it always was,
    /// because the tap before it may already have changed the tag.
    private var contact = TagContact()
    /// UID-keyed credential storage, through the ledger that owns the ordering
    /// rules.
    ///
    /// The store behind it is **deliberately not defaulted** on the init below.
    /// A defaulted in-memory store is exactly how the AES key silently failed to
    /// persist: this flow had no reference to any store at all, so a key it
    /// programmed onto an NTAG424 lived only on the edit model and was gone the
    /// moment the sheet was dismissed. The tag was then gated behind a key nobody
    /// held, and an NTAG424 has no factory reset. Making every caller name a
    /// store is what stops that reappearing.
    private let credentials: TagCredentialLedger

    public init(
        factory: TagSessionFactory,
        dataArea: DataAreaChange,
        credentials: TagCredentialStoring,
        protection: PendingProtection? = nil,
        unlockCredential: TagCredential? = nil,
        removeProtection: Bool = false,
        uidConfirmation: UIDConfirmation,
        targetUID: Data? = nil,
        pinnedUID: Data? = nil
    ) {
        self.factory = factory
        self.dataArea = dataArea
        self.credentials = TagCredentialLedger(credentials)
        self.protection = protection
        self.unlockCredential = unlockCredential
        self.removeProtection = removeProtection
        self.uidConfirmation = uidConfirmation
        self.targetUID = targetUID
        self.pinnedUID = pinnedUID
    }

    /// Whether this write asks the user to type the tag's UID before it changes
    /// the tag's protection, mirroring `Operation.requiresUIDConfirmation`,
    /// which is true for arming and for removal alike.
    ///
    /// Both halves are load-bearing. The intrinsic half keeps a plain record
    /// write, and a write to a protected tag whose password the app holds, at
    /// one tap. The policy half is the whole of the Library preset exemption:
    /// `uidConfirmation` is read here and nowhere else, so the trigger and the
    /// exemption cannot drift apart.
    public var requiresUIDConfirmation: Bool {
        guard uidConfirmation == .required else { return false }
        return protection?.settings.passwordProtect == true || removeProtection
    }

    /// Whether the *next* run raises the card, as opposed to whether this
    /// caller's writes are gated at all.
    ///
    /// `requiresUIDConfirmation` is policy plus staged intent, and it stays true
    /// after `confirm()`. The sheet needs the live question instead: the unlock
    /// prompt is reachable on both sides of the gate, and once the UID has been
    /// typed, "Unlock & continue" and a note about two holds are both stale.
    public var awaitsUIDConfirmation: Bool {
        requiresUIDConfirmation && !uidConfirmed
    }

    /// Whether the hold the sheet is waiting on is the second of a confirmed
    /// run, so it can say which tap this is and that the tag must be the same
    /// one. `.ready` renders the same view as `.polling`, and only a confirmed
    /// run has an identity to compare against.
    public var isSecondTap: Bool {
        requiresUIDConfirmation && uidConfirmed && identifiedUID != nil
    }

    private func isStale(_ token: Int) -> Bool {
        token != runToken
    }

    /// A diagnostics line naming each location record in `dataArea` that has
    /// no coordinates or map URL to write, or `nil` when there is none.
    ///
    /// Such a record encodes as a real place on the equator or the prime
    /// meridian, most often `geo:0,0`, because the URI builder fills whatever
    /// is missing with 0. `begin()` refuses the write rather than put that on
    /// a tag. Static so the rule is testable without a session.
    static func locationsWithNowhereToPoint(in dataArea: DataAreaChange) -> String? {
        guard case .replace(let records) = dataArea else { return nil }
        let unplaced = records.enumerated().compactMap { index, record -> String? in
            guard case .map(let map) = record, !map.hasLocation else { return nil }
            return "record \(index + 1) of \(records.count) (source \(map.source.rawValue))"
        }
        guard !unplaced.isEmpty else { return nil }
        return "refused before a session opened: location without coordinates or map URL at "
            + unplaced.joined(separator: ", ")
    }

    /// Whether this write arms protection, as opposed to removing it or leaving
    /// it alone. Read by the shared preamble and by the apply step.
    private var willProtect: Bool {
        protection?.settings.passwordProtect == true
    }

    /// This write's answer to "what is this tap going to touch".
    ///
    /// Both halves are what the preamble needs to decide whether a gated tag's
    /// credential is in the way. `.writesConfigPages` covers arming as well as
    /// removal: AUTH0, ACCESS, PWD and PACK all sit above AUTH0 itself, so a tag
    /// gated anywhere refuses them wherever its gate starts.
    private var intent: TagAccessIntent {
        var intent: TagAccessIntent = .writesDataArea
        if willProtect || removeProtection {
            intent.insert(.writesConfigPages)
        }
        return intent
    }

    /// Run the shared preamble for this write and translate its two outcomes
    /// into this flow's own state.
    ///
    /// Everything about the *tag* lives in `TagPreamble`, so the identify tap,
    /// the write tap and Operations cannot diverge. What stays here is
    /// everything about the *flow*: the three fields the unlock prompt reads,
    /// the session this model owns, and the transition to `.needsUnlock`.
    ///
    /// `writesAllowed` is false on the identify tap: on a SLIX2 the protection
    /// read is a write probe, and a tap that told the user it is reading the tag
    /// must not put a write on the air.
    private func establish(
        on tag: ConnectedTag,
        session: TagSession,
        writesAllowed: Bool
    ) async throws -> TagPreamble.Outcome {
        let outcome = try await TagPreamble.establish(on: tag, TagPreamble.Request(
            intent: intent,
            heldCredential: unlockCredential,
            // Non-nil is exactly `willProtect`, which is the gate both chip
            // guards in the preamble turn on.
            stagedStyle: willProtect ? protection?.settings.effectiveStyle : nil,
            writesAllowed: writesAllowed
        ))
        switch outcome {
        case .established(let established):
            // Only when the reading found a gate. An established run does not
            // reach the unlock prompt, but a later one may, and clearing what
            // this tap learned about the tag's family would make it ask for the
            // wrong kind of credential.
            if let style = established.style {
                unlockStyle = style
            }

        case .needsCredential(let request):
            unlockStyle = request.style
            unlockFailed = request.offeredCredentialFailed
            unlockRefusal = request.refusal
            await stopForUnlock(session)
        }
        return outcome
    }

    /// End `session`, and forget it only if it is still the one this flow holds.
    ///
    /// `invalidate` suspends until the teardown is reported or its 2 s safety
    /// net fires, and a cancel and a newer run can both land inside that wait:
    /// on 2026-09-19 a finished write's teardown had still not been reported
    /// when a second run began 218 ms later. Clearing `currentSession`
    /// unconditionally afterwards dropped the newer run's session, so the
    /// `reset()` that closed the sheet had nothing to invalidate, and the
    /// session stayed queued until iOS refused it with error 202.
    private func endSession(_ session: TagSession, error: String?) async {
        await session.invalidate(error: error)
        if currentSession === session {
            currentSession = nil
        }
    }

    /// End the activation and put the flow on the unlock prompt. The caller has
    /// already set whichever of `unlockStyle` / `unlockFailed` / `unlockRefusal`
    /// the preamble could establish.
    private func stopForUnlock(_ session: TagSession) async {
        await endSession(session, error: nil)
        transition(to: .needsUnlock)
    }

    /// End a tap that never had a tag, with nothing to report.
    ///
    /// The session tore down before its `start` threw, so `endSession` returns
    /// at once, and it goes without a message because there is no failure to
    /// put in one.
    private func endQuietly(_ session: TagSession, _ ending: NoTagEnd) async {
        await endSession(session, error: nil)
        switch ending {
        case .cancelled:
            transition(to: .cancelled)

        case .timedOut:
            transition(to: .noTagFound)
        }
    }

    /// Tap 1 of a confirmed write. Reads the tag's identity and its state, puts
    /// no write on the air, and tears the session down before the card that asks
    /// the user to type the UID goes up.
    ///
    /// Returns false when the run is over: the flow is on `.needsUnlock`, on
    /// `.error`, or was cancelled. `identifiedUID` survives all three, so a
    /// password typed between the taps does not cost a second identify.
    private func identify(token: Int) async -> Bool {
        let session = factory.makeSession()
        currentSession = session
        transition(to: .identifying)
        do {
            let tag = try await session.start(alert: String(localized: "Hold the tag to identify it."))
            contact.tagArrived()
            guard !isStale(token) else {
                await endSession(session, error: nil)
                return false
            }
            let uid = tag.uid
            // The gate is satisfied by typing this UID, and `DestructiveConfirmation`
            // refuses an empty target by design, so a tag with no UID would put a
            // card on screen whose button can never enable.
            guard !uid.isEmpty else {
                throw TagError.protocolError(
                    "identify: tag reported no UID, so the confirmation gate cannot be raised",
                    diagnostics: "chip=\(tag.chip?.family.shortName ?? "unidentified")"
                )
            }
            // The tag the editor is about, when it knows one. Without this the
            // gate would ask the user to confirm the identity of whatever they
            // are holding, which someone who picked up the wrong tag will
            // confirm accurately.
            if let targetUID, uid != targetUID {
                throw TagError.differentTag(
                    expected: targetUID, presented: uid, diagnostics: "on the identify tap, against the edited tag"
                )
            }
            identifiedUID = uid
            guard case .established = try await establish(on: tag, session: session, writesAllowed: false) else {
                return false
            }
            await endSession(session, error: nil)
            return true
        } catch let error as TagError {
            // Classified before the stale check so a cancelled run still records
            // whether it had a tag. The sheet can rebuild and begin this same
            // model again (`WriteSessionLifecycleTests`).
            let ending = contact.quietEnding(for: error)
            guard !isStale(token) else {
                await endSession(session, error: nil)
                return false
            }
            if let ending {
                await endQuietly(session, ending)
                return false
            }
            await endSession(session, error: String(localized: error.userMessage))
            transition(to: .error(
                message: String(localized: error.userMessage),
                diagnostics: error.diagnostics
            ))
            return false
        } catch {
            _ = contact.quietEnding(for: error)
            await endSession(session, error: nil)
            guard !isStale(token) else { return false }
            transition(to: .error(
                message: "Something unexpected went wrong.",
                diagnostics: "\(error)"
            ))
            return false
        }
    }

    /// Suspend until `confirm()` or a cancel.
    ///
    /// The answer can arrive before the wait does. `identify()` puts the card on
    /// screen and returns, and there is a suspension point between that and this
    /// call, so a user who types fast, or a test that polls for the phase, can
    /// confirm into a continuation that does not exist yet. That answer is
    /// parked in `pendingConfirmation` and collected here; without it the run
    /// suspended forever, which is a hang rather than a failure.
    private func waitForConfirmation() async -> Bool {
        if let pending = pendingConfirmation {
            pendingConfirmation = nil
            return pending
        }
        return await withCheckedContinuation { continuation in
            if let pending = pendingConfirmation {
                pendingConfirmation = nil
                continuation.resume(returning: pending)
            } else {
                confirmationContinuation = continuation
            }
        }
    }

    /// Answer the gate, whether or not anything is waiting yet.
    private func resolveConfirmation(_ value: Bool) {
        if let continuation = confirmationContinuation {
            confirmationContinuation = nil
            continuation.resume(returning: value)
        } else {
            pendingConfirmation = value
        }
    }

    /// The user typed the UID back. Public because the sheet's confirmation card
    /// calls it.
    public func confirm() {
        guard case .awaitingConfirmation = phase else { return }
        uidConfirmed = true
        resolveConfirmation(true)
    }

    public func begin(alert: String = NFCPrompt.holdTag) async {
        guard case .ready = phase else { return }
        let token = runToken
        // A cancel that landed before the previous run reached its wait must not
        // answer this one.
        pendingConfirmation = nil
        provenArm = nil
        writtenUID = nil

        // Refused before anything opens, so no tap is spent and the tag is not
        // touched. The editor marks such a record ("No location" on its row, a
        // note in its form), but a Library preset and a record list reopened
        // from history reach this point without passing through the form, and
        // an Add record sheet dismissed with Cancel leaves the empty record in
        // the list. `MapRecord.hasLocation` has the reason.
        if let unplaced = Self.locationsWithNowhereToPoint(in: dataArea) {
            transition(to: .error(
                message: String(
                    localized: "A location record is missing its coordinates or map URL. Nothing was written to the tag."
                ),
                diagnostics: unplaced
            ))
            return
        }

        // A write that changes protection state confirms the tag first: tap 1
        // identifies it, the card asks for its UID with no session open, and the
        // write tap below refuses anything else. `identifiedUID` and
        // `uidConfirmed` are separate so that a password typed in between costs
        // neither a second identify nor a second typed UID.
        if requiresUIDConfirmation, !uidConfirmed {
            if identifiedUID == nil {
                guard await identify(token: token) else { return }
            }
            // Raised here rather than inside `identify()`, because a run that
            // reaches the gate without identifying (the password was typed
            // between the taps, so the identity is already in hand) needs the
            // card just as much. Leaving the transition in the tap left the flow
            // showing the unlock prompt while it waited on the continuation.
            guard let identifiedUID else { return }
            transition(to: .awaitingConfirmation(uidHex: identifiedUID.hexString))
            guard await waitForConfirmation(), !isStale(token) else { return }
        }

        let session = factory.makeSession()
        currentSession = session
        transition(to: .polling)

        do {
            let tag = try await session.start(alert: alert)
            contact.tagArrived()
            guard !isStale(token) else {
                await endSession(session, error: nil)
                return
            }
            // The gate was satisfied against a specific tag. A stack of blanks
            // is easy to mix up, so presenting a different one now must not
            // inherit that confirmation.
            if let identifiedUID, tag.uid != identifiedUID {
                throw TagError.differentTag(
                    expected: identifiedUID, presented: tag.uid,
                    diagnostics: "on the write tap, against the confirmed tag"
                )
            }
            if let pinnedUID, tag.uid != pinnedUID {
                throw TagError.differentTag(
                    expected: pinnedUID, presented: tag.uid,
                    diagnostics: "on the write tap, against the tag whose arm this write held back"
                )
            }
            writtenUID = tag.uid

            guard case .established(let established) = try await establish(
                on: tag, session: session, writesAllowed: true
            ) else {
                return
            }

            // A protection-only change skips all of this. It also gives up what
            // this block incidentally did: the write and the read-back are
            // today what discovers a permanently locked tag, before the
            // protection change runs. That discovery moves into the driver's
            // own PWD write, so the error surfaces one step later rather than
            // not at all, and the editor already withdraws Write on
            // `isWriteBlocked`.
            if case .replace(let records) = dataArea {
                transition(to: .writing)
                try await tag.writeNDEF(records)

                transition(to: .verifying)
                let echoed = try await tag.readNDEF()
                // Compare by re-encoding both sides: the read-back records have
                // fresh UUIDs (the NDEF wire format carries no identity), so a
                // direct `==` would fail even on a faithful write. The bytes
                // are what's on the chip — that's the meaningful comparison.
                let expected = try NDEFCodec.encode(records)
                // An empty write (the user deleted every record) clears the tag,
                // exactly like the Erase operation. `encode([])` is zero bytes, but
                // real hardware echoes a cleared tag back as a single Empty record
                // (`D0 00 00`) — so compare by meaning, not bytes, for that case.
                let verified = records.isEmpty
                    ? NDEFCodec.isEmptyMessage(echoed)
                    : echoed == expected
                guard verified else {
                    let error = TagError.verificationFailed(
                        diff: echoed,
                        diagnostics: "expectedBytes=\(expected.hexString) gotBytes=\(echoed.hexString)"
                    )
                    transition(to: .error(
                        message: String(localized: error.userMessage),
                        diagnostics: error.diagnostics
                    ))
                    await endSession(session, error: String(localized: error.userMessage))
                    return
                }
            }

            // Whatever the data area was going to take has been written and
            // verified by now. Protection changes LAST (after the read-back, so
            // a read-protected tag is never re-read). Apply and remove are mutually
            // exclusive: the editor only sets `removeProtection` when the toggle
            // is off, and `protection` is non-nil only when it's on.
            if willProtect, let protection {
                transition(to: .applyingProtection)
                let firstDataPage = tag.chip?.memoryLayout.ndefRange?.lowerBound ?? 4
                guard let spec = ProtectionSpec.make(
                    settings: protection.settings,
                    credential: protection.credential,
                    defaultFirstDataPage: firstDataPage
                ) else {
                    throw TagError.capabilityUnsupported(
                        .passwordAuth,
                        diagnostics: "protection credential doesn't match \(protection.settings.effectiveStyle)"
                    )
                }
                // Filed BEFORE the frame that could apply it, which is what
                // taking a ticket does: there is no way to ask for one without
                // the record going down first. The asymmetry behind that rule is
                // on `TagCredentialLedger`.
                let ticket = credentials.arming(protection.credential, forUID: tag.uid)
                // `replacing:` is "the credential this tag is answering to right
                // now", and on a tag the reading found open that is not the one
                // being written. The SLIX2 arm presents it as the current
                // password (`Iso15693ProtectionClient.enable`), so passing the
                // new one refused the arm and stopped the chip; the Type-4 arm
                // puts it first among the candidates, spending a refused
                // handshake before the factory key it was always going to need.
                let heldByTheTag = established.tagWasProtected ? unlockCredential : nil
                let residue = try await tag.enableProtection(spec, replacing: heldByTheTag)
                protectionResidue = residue
                // Settled against what the driver established, never against the
                // fact that it returned. A ticket left unsettled by a throw is
                // the interrupted state and is already recorded as one.
                ticket.settle(residue)
                // Authentication, not an ACK. `metItsGoal` accepts an
                // acknowledged key write for Ultralight C, which is right for
                // the ledger's stage and wrong here: withdrawing Write on an ACK
                // would take away the one tap that proves that family's key.
                if case .provenArmed = residue.gate,
                   residue.completed.contains(.credentialProven),
                   residue.credential == .callerSupplied
                {
                    provenArm = ProvenArm(uid: tag.uid, spec: spec, firstDataPage: firstDataPage)
                }
            } else if removeProtection, let unlockCredential {
                // The tag was protected and the user switched it off — clear the
                // lock with the credential they just authenticated with.
                //
                // An open tag never reaches here, and that is a decision rather
                // than the nil binding it looks like. `EditFlowModel` can only
                // stage a removal against a tag it *read* as protected
                // (`wantsProtectionRemoved`), and a tag that reads open is never
                // asked for a credential, so the binding cannot succeed. The
                // Operations sheet refuses the same tag outright with
                // `nothingToRemove`, and the two are right to differ: there the
                // removal is the verb the user chose against the reading on
                // screen, here it is a rider on a write that still has records
                // to put down. Failing the whole write over a moot rider would
                // be the wrong answer. See `RouteParity.exclusions`, which
                // records this as a decision and pins both sides.
                transition(to: .removingProtection)
                let ticket = credentials.removing(unlockCredential, forUID: tag.uid)
                let residue = try await tag.disableProtection(using: unlockCredential)
                protectionResidue = residue
                // Whether the record survives is the ledger's rule, and it turns
                // on a read-back proving the gate down *and* the credential back
                // at the factory value. The 2026-09-04 incident is what that rule
                // is written from; the argument is on `TagCredentialLedger`.
                ticket.settle(residue)
            }

            // Read the protection back, rather than reporting the spec that was
            // written. The card this reaches distinguishes "write-only" from
            // "read + write", and that bit is PROT: the spec asked for it and
            // only the ACCESS byte can confirm it.
            //
            // `try?`, and only when a protection change was actually attempted.
            // The write has already succeeded by this point, so nothing here may
            // fail it, and a read that does not come back is missing knowledge
            // rather than a finding. Same rule as `OperationsFlowModel.verify`.
            if protectionResidue != nil, let state = try? await tag.readProtectionState() {
                observation = TagObservation(uid: tag.uid, protection: state)
            }
            // The verify read above walked the tag's whole NDEF structure, so
            // this write is also proof that a reader can find a message on it.
            // Worth publishing on its own: a write is the other way out of a
            // damaged data area, and the editor's notice should not keep
            // standing behind a tag that has just read back clean.
            //
            // Only where a completed read proves that, which is the Type-2 page
            // transport. Elsewhere an unformatted tag reads back as zero records
            // rather than refusing, so the same successful read would say nothing
            // at all. See `TagFormatState.readProvesStructure`.
            //
            // And only where there was a verify read to stand on. A
            // protection-only change never touched the data area, so it has
            // established nothing about it: taking a `try?` read here purely to
            // publish an optimistic flag would be "an ACK is not proof"
            // inverted, and it would let an unformatted data area fail a change
            // that never promised to repair it.
            if case .replace = dataArea, TagFormatState.readProvesStructure(tag.chip?.family) {
                let readable = TagObservation(uid: tag.uid, ndefReadable: true)
                observation = observation?.merging(readable) ?? readable
            }

            systemSheetGone = false
            transition(to: .done)
            await endSession(session, error: nil)
            // The sheet holds "Locked in" until iOS has taken its own card
            // away, so it waits for the teardown report, not for `invalidate`,
            // which its safety net can end first.
            await session.awaitTeardown(timeout: .seconds(3))
            markSystemSheetGone()
        } catch let error as TagError {
            let ending = contact.quietEnding(for: error)
            // A run the user has already cancelled ends quietly. Its session was
            // invalidated under it, so the error is the cancel itself, and a
            // card on a dismissed sheet would describe nothing they did.
            guard !isStale(token) else {
                await endSession(session, error: nil)
                return
            }
            // A write tap with nothing in the field, on a write that has never
            // had a tag. On a confirmed write this cannot be tap 2, because tap
            // 1 read the tag, so the only tap that can end here quietly is one
            // that nothing came before.
            if let ending {
                await endQuietly(session, ending)
                return
            }
            await endSession(session, error: String(localized: error.userMessage))
            transition(to: .error(
                message: String(localized: error.userMessage),
                diagnostics: error.diagnostics
            ))
        } catch {
            _ = contact.quietEnding(for: error)
            await endSession(session, error: nil)
            guard !isStale(token) else { return }
            transition(to: .error(
                message: "Something unexpected went wrong.",
                diagnostics: "\(error)"
            ))
        }
    }

    /// Returns once the system NFC sheet of the write that just finished has
    /// left the screen, or at once if it already has.
    ///
    /// `WriteSheet` closes on this rather than on a timer. The sheet used to
    /// close 1.7 s after `.done` while iOS kept its card up for about 2.7 s, so
    /// "Locked in" played behind the card's scrim and was gone before the card
    /// was (operator, 2026-09-19). Not tied to the run token: a sheet swiped
    /// away early still hands its reading back, and that needs this to return.
    public func systemSheetDismissal() async {
        guard !systemSheetGone else { return }
        await withCheckedContinuation { systemSheetWaiters.append($0) }
    }

    private func markSystemSheetGone() {
        systemSheetGone = true
        let waiters = systemSheetWaiters
        systemSheetWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// Supply the credential for an already-protected tag (from the `.needsUnlock`
    /// prompt) and retry the write — the new session authenticates before
    /// writing.
    ///
    /// On a write that changes protection, this call now spans the confirmation
    /// gate: it awaits `begin()`, which suspends until `confirm()` or a cancel.
    /// Callers must therefore drive it from a task other than the one that will
    /// confirm, which both sheets already do.
    ///
    /// Neither `identifiedUID` nor `uidConfirmed` is cleared. The tag has not
    /// changed, only the credential offered to it, and re-asking for fourteen
    /// characters because a password was mistyped is a tax on the recovery flow
    /// rather than a safety property.
    public func unlock(with credential: TagCredential) async {
        guard case .needsUnlock = phase else { return }
        unlockCredential = credential
        unlockFailed = false
        unlockRefusal = nil
        phase = .ready
        transitionCount &+= 1
        await begin()
    }

    /// "Try again" after a failure: re-run the same write, keeping what the user
    /// supplied and re-asking only for consent.
    ///
    /// Split from `reset()` for the reason `OperationsFlowModel` splits `retry()`
    /// from `cancel()`. `reset()` is the dismiss path and wipes the credential,
    /// so pointing "Try again" at it made a tag that slipped during the write
    /// cost a second password round trip, and with the gate in front of the
    /// write, a second typed UID as well.
    ///
    /// Consent is still not carried across a failure whose cause is unknown: the
    /// identity and the confirmation both go, and the retry re-identifies. Only
    /// the credential survives, and it is one the tag has not refused, because
    /// both refusal routes end at `.needsUnlock` rather than at `.error`.
    ///
    /// Also the way on from `.noTagFound`, where nothing was identified or
    /// confirmed in the first place, so there is nothing for it to drop.
    public func retry() async {
        switch phase {
        case .error, .noTagFound:
            break

        default:
            return
        }
        identifiedUID = nil
        uidConfirmed = false
        phase = .ready
        transitionCount &+= 1
        await begin()
    }

    /// Cancel or dismiss: revoke consent, drop the credential, stop the run.
    ///
    /// `runToken` is what actually stops a run already inside `begin()`.
    /// Invalidating the session is a no-op until CoreNFC has created it, which
    /// it does only after the inter-session cooldown, and that window is exactly
    /// when the sheet's Cancel button is the only thing on screen.
    public func reset() {
        runToken &+= 1
        resolveConfirmation(false)
        let session = currentSession
        Task { await session?.invalidate(error: nil) }
        currentSession = nil
        identifiedUID = nil
        uidConfirmed = false
        unlockCredential = nil
        unlockFailed = false
        unlockRefusal = nil
        transition(to: .ready)
    }

    private func transition(to newPhase: Phase) {
        phase = newPhase
        transitionCount &+= 1
    }
}
