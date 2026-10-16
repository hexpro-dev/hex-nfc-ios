import Foundation
import HexNFCKit
import HexNFCRecords
import HexNFCStorage
import Observation

/// State machine for the tag-operations sheet — the irreversible side of the
/// app. A confirming operation takes **two taps**:
///
///   `.idle → .identifying → .awaitingConfirmation → .polling → .connected
///          → .executing → .verifying? → .done | .error`
///
/// Operations that need no confirmation (`memoryDump`) skip the first two and
/// run in a single tap.
///
/// **The typed-UID gate must sit between the two sessions, not inside one.**
/// This previously opened a session, connected, and *then* asked the user to
/// type the tag's UID — while the system NFC sheet was still on screen. That
/// sheet is modal: the app behind it takes no touches, so the confirmation
/// field could not be typed into, and the session would sit there until iOS
/// timed it out. The DEBUG harness already had this right
/// (`IrreversibleOpsFlowModel`: "the system NFC sheet would block typing") and
/// the shipping path, which is the one users actually reach, did not.
///
/// Splitting it also buys the check the harness has and this flow lacked: tap 2
/// asserts the same UID came back, so a destructive operation confirmed against
/// one tag can't land on a different tag swapped in afterwards.
@Observable
@MainActor
public final class OperationsFlowModel {
    public enum Operation: Hashable, Sendable {
        case erase
        case format
        case permanentLock
        /// Apply protection in one family-agnostic operation. The settings plus
        /// the secret to **write**, which is the same `PendingProtection` the
        /// write route carries. What the tag holds *now* is a different fact
        /// and lives on the model, as `unlockCredential`.
        ///
        /// Deliberately **not** a `ProtectionSpec`. A spec is what
        /// `ProtectionSpec.make` produces, and that function is the choke point
        /// that forces `authLimit: 0` and pins a read gate to the chip's first
        /// data page. The standalone Protect screen used to assemble a spec by
        /// hand, with `protectFromPage: 4` spelled in the screen, and was the
        /// only shipped caller that went round the choke point. Taking the
        /// settings instead means the arm cannot be built any other way.
        case enableProtection(PendingProtection)
        case disableProtection
        /// Arm the chip's failed-authentication limit, ACCESS bits 2-0 on an
        /// NTAG21x or Ultralight EV1. After that many wrong passwords the tag
        /// stops accepting its password, and nothing brings it back.
        ///
        /// **Standalone only**, for the same reason a permanent lock is: it arms
        /// an outcome no later tap can undo, so the consent has to be typed
        /// against one tag's UID. It used to be a Stepper in the editor's
        /// Protection card, riding on a preset that is deliberately not pinned to
        /// one chip, replayed across a stack of tags from the Library and carried
        /// into `.hexnfc` exports. That is the shape CLAUDE.md forbids for a
        /// permanent lock, and this arms the same unrecoverable outcome, just
        /// deferred until somebody mistypes.
        ///
        /// The password the tag holds **now** arrives as `unlockCredential`: the
        /// ACCESS page sits above AUTH0 on an armed tag, so the write is refused
        /// until a `PWD_AUTH` succeeds.
        case setAttemptLimit(limit: Int)
        case memoryDump
    }

    public enum Phase: Equatable, Sendable {
        case idle
        /// Tap 1 of a confirming operation: a read-only scan whose entire purpose
        /// is to learn the tag's UID, after which the session is closed so the
        /// user can actually type it.
        case identifying
        case polling
        case connected(uidHex: String)
        /// The typed-UID gate. **No NFC session is open in this phase** — that is
        /// the point of it.
        case awaitingConfirmation(uidHex: String)
        /// The tag is gated over the region this operation needs and what the
        /// run is holding did not open it. The session is torn down before this
        /// phase is entered, so the prompt can be typed into.
        ///
        /// Reached only from tap 2, and only after the typed-UID gate has been
        /// satisfied: `confirmedUID` survives it, so supplying a credential
        /// resumes at tap 2 rather than starting over. That is the whole design.
        /// The window between the two taps already exists and already has the
        /// user's attention, so a confirming operation collects its credential
        /// there and never gains a tap; this phase is the fallback for a
        /// credential the tag then refused.
        ///
        /// **Abandoning it is safe and needs nothing.** No session is open and
        /// no task is suspended: `begin()` has already returned, so a sheet
        /// dismissed here simply deallocates the model, and there is no session
        /// for iOS to time out. `cancel()` is the deliberate exit and returns
        /// the flow to `.idle`, dropping the credential and the typed UID with
        /// everything else it drops, so the next run starts from the beginning.
        case needsUnlock
        case executing
        case verifying
        case done(summary: Summary)
        /// Backed out before any tag, on a run that never had one: `.idle` again
        /// to `begin()`, and a cue for Memory dump, which opened the sheet, to leave.
        case cancelled
        /// Timed out with nothing in the field, on a run that never had a tag.
        case noTagFound
        case error(message: String, diagnostics: String)
    }

    public enum Summary: Equatable, Sendable {
        case erased
        /// `alreadyFormatted` is `true` when the tag's CC was already the right
        /// bytes and the OTP page was deliberately left untouched — the common
        /// case on factory NTAG21x. Reporting a plain "Tag formatted." there
        /// claimed a write that never happened, on the one page in the app that
        /// only ever gets one write.
        case formatted(alreadyFormatted: Bool)
        /// `verified` is `false` when the lock was written but this tap could not
        /// witness it. That is not a failure and not a doubt about the write: on
        /// MIFARE Ultralight C the lock bytes are "valid upon the next REQA or
        /// WUPA" (MF0ICU2 §7.5.3), so the in-session probe would see a write
        /// accepted on a tag that really is locked. NTAG21x and Ultralight EV1
        /// latch immediately (MF0ULX1 §8.5.2) and come back `true`.
        ///
        /// The distinction reaches the UI on purpose. This is an irreversible
        /// operation, and "we proved it" and "we will know next tap" are
        /// different promises to make about one.
        case permanentlyLocked(verified: Bool)
        case passwordSet
        case passwordRemoved
        /// `verified` is `false` when the ACCESS write was acknowledged but this
        /// tap could not read the byte back, which is the same distinction
        /// `permanentlyLocked(verified:)` draws and for the same reason. It is
        /// never `true` on an ACK alone.
        case attemptLimitSet(limit: Int, verified: Bool)
        case memoryDumped(bytes: Data)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var transitionCount: Int = 0
    public private(set) var connectedTag: ConnectedTag?

    /// What tap 1 established, or `nil` before it has run and after anything
    /// that invalidates it.
    public private(set) var reading: TagReading?

    /// The attempt limit tap 1 read, kept as its own name because
    /// `AttemptLimitReadout` and `AttemptLimitTests` are about that one number
    /// and nothing else.
    public var detectedAttemptLimit: Int? {
        reading?.attemptLimit
    }

    /// What this run established about the tag it actually ran against, from
    /// read-backs only.
    ///
    /// The channel that lets a screen behind this one stop showing a state the
    /// tag no longer has. It deliberately carries the operated UID rather than
    /// assuming the caller's: this sheet is a general tool, every operation runs
    /// against whatever tag the user presents, and that need not be the tag the
    /// caller is showing. The receiver decides whether it is about its own tag.
    ///
    /// Set only from something read off the chip. A summary, an acknowledgement,
    /// and the spec that was written are none of them a reading.
    public private(set) var observation: TagObservation?

    /// The UID of the tag tap 2 actually connected to. Captured at connect,
    /// because `connectedTag` is cleared before the `.done` transition and
    /// `Phase.done` carries no UID.
    private var operatedUID: Data?

    /// The permanent lock's own stage-by-stage outcome, kept from `execute` so
    /// `verify` can map it. `permanentLock()` is `@discardableResult` and this
    /// used to discard it, which left a half-burned tag with nothing to report.
    private var lockOutcome: PermanentLockOutcome?

    /// A next tap the user may choose after a failure, when the failure names one
    /// specific thing worth trying that the app must not try on its own.
    ///
    /// **Never automatic.** A Type-2 chip answers a wrong password with a NAK, the
    /// NAK returns it to HALT for the rest of the activation, and a tag whose
    /// ACCESS byte carries a non-zero AUTH_LIM has a countable number of attempts
    /// before password verification is disabled for good
    /// (`docs/internal/chip-config-pages.md`, ACCESS bits 2-0). Spending one of
    /// those is the user's decision, not this model's.
    public enum Recovery: Equatable, Sendable {
        /// A Type-2 credential was genuinely put on the wire and the operation did
        /// not complete, and this run was not already presenting the delivery
        /// password. The tag may be holding its factory default because an earlier
        /// removal finished on the chip while reporting failure.
        case tryType2FactoryDefault
    }

    /// The offer to show beside the error, or `nil` when the failure names
    /// nothing specific to try.
    public private(set) var recovery: Recovery?

    /// `true` from the moment the user takes `Recovery.tryType2FactoryDefault`
    /// until the substitution is undone by `retry()` or `cancel()`. The idle
    /// screen says which credential the next tap will present, so the app never
    /// sends a credential the user did not choose without saying so.
    public private(set) var presentsFactoryDefault = false

    /// `true` when the run that just finished actually authenticated: a driver
    /// read the tag's configuration, found the gate armed, and a `PWD_AUTH`
    /// succeeded.
    ///
    /// It exists because success is not proof of authentication. A removal on a
    /// tag whose gate is already open sends **no** authentication frame at all
    /// (`Type2PasswordDriver.disable` skips it when `isGateArmed` is false), so a
    /// recovery tap can end in `.done` with nothing having opened anything. Copy
    /// that says "the factory default is what opened this tag" has to be gated on
    /// this, or it is a claim about a tag nothing was presented to.
    public private(set) var didOpenGate = false

    /// The operation this run performs. Nothing may change which operation it
    /// is: a recovery tap moves the *credential* and never the verb.
    public private(set) var operation: Operation

    /// The credential that opens this tag now, and the only channel for one.
    ///
    /// Mirrors `WriteFlowModel.unlockCredential` deliberately, down to the two
    /// fields below it, because the two routes have to behave the same way and
    /// a second shape is a second set of bugs. It is distinct from whatever an
    /// arming operation is about to *write*: that lives in the spec, and the
    /// two used to share one slot on `Operation`, which is how the Ultralight C
    /// arm dropped the caller's resolved key.
    public private(set) var unlockCredential: TagCredential?

    /// `true` when the last credential this run presented did not open the tag,
    /// so a prompt can say so rather than repeating its first-run copy.
    public private(set) var unlockFailed = false

    /// The refusal behind that, kept only when a prompt has to say something
    /// its own copy cannot: that the tag has an attempt limit, on which the chip
    /// refuses the *correct* password. See `TagError.unlockPromptCopy`.
    public private(set) var unlockRefusal: TagError?

    /// The protection family of the tag this run is about, so a prompt asks for
    /// the right kind of credential: a 4-byte password for Type-2 and SLIX, a
    /// 16-byte AES key for an NTAG424, a 16-byte 3DES key for an Ultralight C.
    ///
    /// Deliberately survives a `begin()` that clears everything else this tap
    /// learned, exactly as `WriteFlowModel.unlockStyle` does. What it holds is a
    /// fact about the chip rather than about the run, and clearing it would make
    /// the next prompt ask for the wrong shape of secret.
    public private(set) var unlockStyle: ProtectionStyle?

    private let factory: TagSessionFactory
    /// UID-keyed credential storage, through the ledger that owns the ordering
    /// rules.
    ///
    /// The store behind it is **deliberately not defaulted** on the init below,
    /// for the reason `WriteFlowModel` gives and which this flow is the proof of.
    /// Until now this flow had no reference to any store at all, so a tag
    /// protected from the standalone Operations sheet with a password the user
    /// did not write down was in exactly the state `TagCredentialStore` was made
    /// for, and that type was not on this path. A defaulted in-memory store would
    /// have let it come back silently.
    private let credentials: TagCredentialLedger
    private var currentSession: TagSession?
    /// Resumed with `true` when the typed-UID gate is satisfied and `false` when
    /// the run is cancelled, so the suspended `begin()` learns which happened.
    ///
    /// The outcome rides on the continuation rather than a separate flag on
    /// purpose. Cancelling used to resume and then fall straight through into
    /// `.executing` — the dead session made the command fail, so it *looked*
    /// like a cancel while the intent was never honoured. A boolean flag fixed
    /// the visible half of that and left a narrow one: `begin()` clears any such
    /// flag on entry, so a second run starting between the resume and the
    /// suspended run's check would clear the cancel out from under it and both
    /// would open a session.
    private var confirmationContinuation: CheckedContinuation<Bool, Never>?
    /// The UID captured on tap 1. Tap 2 must present the same tag.
    private var confirmedUID: Data?
    /// Whether any session of this model has had a tag. Never cleared; see `TagContact`.
    private var contact: TagContact

    /// Whether any session of this model has had a tag, or ended in a way that
    /// cannot rule one out. Read by a screen that replaces this model inside one
    /// presentation, so the replacement can be told.
    var mayHaveTouchedATag: Bool {
        contact.mayHaveTouchedATag
    }

    /// - Parameter earlierRunMayHaveTouchedATag: `true` when this model replaces
    ///   one from the same presentation that may have had a tag. Set attempt
    ///   limit's Start over is the one caller: the run it replaces may have
    ///   armed the limit and lost the answer, so a cancel on the tap that
    ///   follows is reported in full, as it would have been on the old model.
    public init(
        factory: TagSessionFactory,
        operation: Operation,
        credentials: TagCredentialStoring,
        earlierRunMayHaveTouchedATag: Bool = false
    ) {
        self.factory = factory
        self.operation = operation
        self.credentials = TagCredentialLedger(credentials)
        contact = TagContact(mayHaveTouchedATag: earlierRunMayHaveTouchedATag)
    }

    /// Hand this run the credential the tag is answering to now.
    ///
    /// The one way in, so "what opens this tag" has a single home.
    ///
    /// Guarded on "no session is open" rather than on "no run is in flight",
    /// and the difference is the whole point of collecting a credential at the
    /// typed-UID gate: `begin()` is suspended on its continuation there, so the
    /// run *is* in flight, and there is no tag in the field to present anything
    /// to. What the guard refuses is a credential swapped under a live session,
    /// which would be presented by a tap the user never chose it for.
    public func supplyUnlockCredential(_ credential: TagCredential?) {
        guard !isHoldingATag else { return }
        unlockCredential = credential
        unlockFailed = false
        unlockRefusal = nil
    }

    /// Restate what this run is going to arm.
    ///
    /// A no-op on any other operation: this changes what an arm writes, and an
    /// erase or a lock has nothing to write.
    ///
    /// Guarded on "no session is open" rather than on "no run is in flight",
    /// for the reason `supplyUnlockCredential` gives one line further up, and
    /// the difference is load-bearing in the same way. The Protect screen's
    /// fields are rendered at the typed-UID gate, where `begin()` is suspended
    /// on its continuation, so the run *is* in flight and there is no tag in the
    /// field for a settings change to reach. Guarded on `isRunning` this was a
    /// silent no-op at the one phase it is called from, and the gate then
    /// refused to open because the arm was still the placeholder. What the guard
    /// refuses is settings swapped under a live session, which would be applied
    /// by a tap the user set up for different ones.
    public func supplyProtection(_ pending: PendingProtection) {
        guard !isHoldingATag, case .enableProtection = operation else { return }
        operation = .enableProtection(Self.armable(pending))
    }

    /// The settings an Operations arm may actually carry, with a read gate
    /// stripped from the two families this app offers none on.
    ///
    /// The reasons are on `ProtectionArm.offersReadGate` and are silicon facts
    /// rather than preferences. What belongs here is why the correction is made
    /// at all rather than left to the driver: `Iso15693ProtectionClient.enable`
    /// and `UltralightCProtectionDriver.enable` both refuse a read gate without
    /// an explicit opt-in this app never passes, and that refusal reaches the
    /// user as `capabilityUnsupported` *after* fourteen characters of UID have
    /// been typed. The adaptive screen exists to remove exactly that dead end,
    /// so the setting is corrected on the way in.
    ///
    /// Both routes into an arm go through here, `supplyProtection` above and
    /// `execute` below, so a model built directly with a read-gated Type-5
    /// arrives at the driver with the gate already gone.
    static func armable(_ pending: PendingProtection) -> PendingProtection {
        var pending = pending
        switch pending.settings.effectiveStyle {
        case .type5(let settings) where settings.kind != .write:
            pending.settings.style = .type5(.init(kind: .write))
            pending.settings.readProtect = false

        case .ultralightC(let settings) where settings.readProtect:
            pending.settings.style = .ultralightC(
                .init(protectFromPage: settings.protectFromPage, readProtect: false)
            )
            pending.settings.readProtect = false

        case .type2, .type4, .type5, .ultralightC:
            break
        }
        return pending
    }

    /// Whether the screen has to collect a credential before tap 2 may run.
    ///
    /// Answered from what this operation touches and what tap 1 read, and from
    /// nothing else. A hand-written list of operation names beside
    /// `accessIntent` is how Format would stop working on a protected tag where
    /// it works today: its intent is empty because its one write lands on page
    /// 3, below every AUTH0 this app can put on a tag, and a list would have to
    /// remember that.
    ///
    /// The rule about the reading is "has **not** positively proven the gate
    /// open", not "says protected". A protected Type-2 tag answers tap 1's
    /// preamble with a credential request rather than with configuration bytes,
    /// and a SLIX2's state cannot be established on an identify tap at all
    /// because the probe is a write. A state-driven rule would hide the field on
    /// exactly the tags that need it.
    public var requiresUnlockCredential: Bool {
        guard let reading else { return false }
        if let state = reading.protection, !state.passwordProtect {
            return false
        }
        // Everything the reading did not rule out is treated as gated. The nil
        // start page is not a missing value: `TagAccessIntent` reads it as "the
        // gate covers everything", which is the only safe reading of a page
        // number that sits behind the gate describing it.
        let assumed = reading.protection ?? TagProtection(
            passwordProtect: true, protectFromPage: nil, readProtect: true
        )
        let ndefUpper = reading.chip
            .flatMap { ChipCatalog.profile(for: $0)?.memoryLayout.ndefRange?.upperBound } ?? Int.max
        return operation.accessIntent.needsCredential(given: assumed, ndefUpperBound: ndefUpper)
    }

    /// Whether this run still has to be told what it is going to arm.
    ///
    /// The Protect screen builds its run before a tag has been tapped, so it has
    /// no chip to choose a credential shape for and stages nothing:
    /// `ProtectionArm.unstaged` is that state, and `passwordProtect: false` is
    /// how it is recognised here and in `armingStyle`. The typed-UID gate stays
    /// shut while this is true, so a placeholder cannot reach a tag.
    ///
    /// False for every other operation, which has nothing to stage.
    public var requiresProtectionSettings: Bool {
        guard case .enableProtection(let pending) = operation else { return false }
        return !pending.settings.passwordProtect
    }

    /// The credential this run will present to open the tag's gate.
    ///
    /// Held credential first, then the arming credential, which is exactly
    /// `Type2PasswordDriver.enable`'s own `currentPassword ?? password`
    /// fallback. It has to mirror the driver: this is the app's record of which
    /// frame goes out, and a record that guesses is worse than none.
    var presentedCredential: TagCredential? {
        if let unlockCredential {
            return unlockCredential
        }
        if case .enableProtection(let pending) = operation, case .type2 = pending.credential {
            return pending.credential
        }
        return nil
    }

    /// The Type-2 password this run will present, or `nil` when it presents
    /// none. Kept as the app's own record of which frame goes out, and read by
    /// the diagnostics and the tests that care about that specifically.
    public var presentedType2Password: Data? {
        if case .type2(let password, _)? = presentedCredential {
            return password
        }
        return nil
    }

    /// The secret this run is holding for the tag, as a hex field renders it, or
    /// `nil` when it holds none.
    ///
    /// The prompt that collects a credential is also the prompt that has to
    /// display one the run acquired some other way. `retryWithFactoryDefault()`
    /// puts the delivery password on the run without anybody typing it, so a
    /// field that comes back empty there is the screen disagreeing with the wire
    /// (bench 2026-09-09, finding 1). Every family, not just Type-2, because
    /// every family's secret now reaches the tag through this one prompt.
    ///
    /// Deliberately only ever what **this run** holds. Nothing here reads a
    /// stored record: `TagCredentialStore` has never been read by anything, and
    /// making a prompt its first reader would put a saved secret into a
    /// plain-text field on a screen anyone holding the phone can open.
    public var heldSecretHex: String? {
        switch unlockCredential {
        case .type2(let password, _): password.hexString
        case .type4(let key, _): key.hexString
        case .type5(let password, _): password.hexString
        case .ultralightC(let key): key.cipherOrder.hexString
        case nil: nil
        }
    }

    /// Whether this operation's credential may ever be swapped for the chip
    /// family's delivery password.
    ///
    /// `.setAttemptLimit` may not, and that exclusion is the whole of why this
    /// exists: the offer costs one counted `PWD_AUTH`, and this is the screen
    /// that arms the counter. A guess there is not a guess the app may propose.
    ///
    /// It used to be structural: the substitution rebuilt the whole operation
    /// and `.setAttemptLimit` had no case to rebuild into. Now that only the
    /// credential moves there is nothing structural left, so the rule is stated
    /// and tested rather than implied.
    var mayPresentTheFactoryDefault: Bool {
        switch operation {
        case .setAttemptLimit:
            false

        case .erase, .format, .permanentLock, .enableProtection, .disableProtection, .memoryDump:
            true
        }
    }

    /// Run the operation through to `.done` or `.error`. For a confirming
    /// operation this spans two taps with the typed-UID gate in between; for the
    /// rest it is a single tap.
    public func begin(alert: String = NFCPrompt.holdTag) async {
        guard phase == .idle || phase == .cancelled else { return }

        // A new run has established nothing yet, so it carries no offer and no
        // verdict about a gate. `presentsFactoryDefault` deliberately survives:
        // it describes the credential this run is about to present, not the last
        // one's outcome.
        recovery = nil
        didOpenGate = false
        // A run that fails before it connects must not re-deliver the previous
        // run's reading to the screen behind it. `reading` goes with it: a tap-1
        // reading describes the tag one activation ago, and a run starting now
        // has established nothing.
        observation = nil
        reading = nil
        operatedUID = nil
        lockOutcome = nil

        // --- Tap 1: identify only, then close the session so the user can type.
        if operation.requiresUIDConfirmation, confirmedUID == nil {
            guard await identify() else { return }
            guard await waitForConfirmation() else { return }
        }

        // --- Tap 2 (or the only tap): do the work.
        let session = factory.makeSession()
        currentSession = session
        transition(to: .polling)

        do {
            let tag = try await session.start(alert: alert)
            contact.tagArrived()
            connectedTag = tag
            let uidHex = tag.uid.hexString
            // The gate was satisfied against a specific tag. Presenting a
            // different one now — a stack of blanks is easy to mix up, and tags
            // from one batch can share their UID tail — must not inherit that
            // confirmation.
            if let confirmedUID, tag.uid != confirmedUID {
                throw TagError.differentTag(
                    expected: confirmedUID, presented: tag.uid, diagnostics: "on tap 2, against the confirmed tag"
                )
            }
            operatedUID = tag.uid
            transition(to: .connected(uidHex: uidHex))

            // The same preamble tap 1 ran, on the activation that writes. It
            // re-establishes state rather than trusting what tap 1 saw, presents
            // the credential at most once, and is the one place that can tell
            // "the tag refused what we are holding" from "the operation failed".
            //
            // `writesAllowed: true` here and false on tap 1: this is the tap the
            // user was told would change the tag.
            let outcome = try await TagPreamble.establish(on: tag, TagPreamble.Request(
                intent: operation.accessIntent,
                heldCredential: unlockCredential,
                stagedStyle: armingStyle,
                writesAllowed: true
            ))
            if case .needsCredential(let request) = outcome {
                unlockFailed = request.offeredCredentialFailed
                unlockRefusal = request.refusal
                if let style = request.style {
                    unlockStyle = style
                }
                // The offer follows the refusal rather than the phase. Before
                // this tap ran a preamble, a Type-2 credential that did not open
                // the tag surfaced as an error and earned the offer there; now
                // it is intercepted one step earlier and lands on the prompt, so
                // the offer has to land with it or the recovery the 2026-09-04
                // incident produced would quietly have no way to be taken.
                recovery = mayPresentTheFactoryDefault
                    ? request.refusal.flatMap { Self.recovery(after: $0, presenting: presentedCredential) }
                    : nil
                await session.invalidate(error: nil)
                currentSession = nil
                connectedTag = nil
                // An assertion rather than a comment. `.needsUnlock` is only
                // ever reached from tap 2, so the typed UID has already been
                // given and has to survive: losing it here would drop a
                // Dangerous Action back to a one-tap flow the next time round,
                // silently, because `begin()` raises the gate only when
                // `confirmedUID` is nil.
                assert(
                    confirmedUID != nil || !operation.requiresUIDConfirmation,
                    "a confirming operation reached .needsUnlock without its confirmed UID"
                )
                transition(to: .needsUnlock)
                return
            }

            transition(to: .executing)
            var summary = try await execute(operation, on: tag)

            if operation.verifies {
                transition(to: .verifying)
                // Verification can *refine* the summary, not just pass or throw —
                // a permanent lock that couldn't be witnessed this tap is neither
                // a success to report plainly nor a failure to raise.
                summary = try await verify(operation, on: tag, summary: summary)
            }

            await session.invalidate(error: nil)
            currentSession = nil
            connectedTag = nil
            transition(to: .done(summary: summary))
        } catch let error as TagError {
            // Tap 2 always follows a tag, so only Memory dump's one tap is quiet.
            if let ending = contact.quietEnding(for: error) {
                await endQuietly(session, ending)
                return
            }
            await session.invalidate(error: String(localized: error.userMessage))
            currentSession = nil
            connectedTag = nil
            recovery = mayPresentTheFactoryDefault
                ? Self.recovery(after: error, presenting: presentedCredential)
                : nil
            // A partial permanent lock arrives here and never as a `Summary`, so
            // a `.done`-only observer would never see the one outcome the user
            // most needs the card behind this sheet to stop lying about. "It
            // failed" is the report CLAUDE.md calls certainly wrong about a tag
            // that has already burned half its lock bits.
            if case .permanentLockIncomplete(let outcome) = error.kind {
                publish(lock: TagLockReading(outcome, staticRegionWitnessed: false))
            } else if let lockOutcome {
                // A lock that committed and *then* lost the tag throws from the
                // verification probe, which opens with an ordinary READ of page
                // 4 and surfaces a slip as `.tagLost`. Without this the outcome
                // is dropped and the card behind goes on saying the tag is
                // unlocked, about a tag whose lock bits are burned for good.
                publish(lock: TagLockReading(lockOutcome, staticRegionWitnessed: false))
            }
            transition(to: .error(
                message: String(localized: error.userMessage),
                diagnostics: error.diagnostics
            ))
        } catch {
            _ = contact.quietEnding(for: error)
            await session.invalidate(error: nil)
            currentSession = nil
            connectedTag = nil
            transition(to: .error(
                message: "Something unexpected went wrong.",
                diagnostics: "\(error)"
            ))
        }
    }

    /// End a run that never had a tag: nothing to show, no offer to make.
    private func endQuietly(_ session: TagSession, _ ending: NoTagEnd) async {
        await session.invalidate(error: nil)
        currentSession = nil
        transition(to: ending == .cancelled ? .cancelled : .noTagFound)
    }

    /// Tap 1: a read-only scan purely to learn which tag the user is holding, so
    /// the UID can be shown next to the confirmation field. The session is closed
    /// before returning — nothing may keep the NFC sheet up while the user types.
    /// Returns `false` if the scan failed (the phase is already `.error`).
    private func identify() async -> Bool {
        let session = factory.makeSession()
        currentSession = session
        transition(to: .identifying)
        do {
            let tag = try await session.start(alert: String(localized: "Hold the tag to identify it."))
            contact.tagArrived()
            // The same preamble the write route runs, so the two cannot diverge
            // about what one activation established.
            //
            // `heldCredential: nil` is this tap's whole contract. Tap 1 says it
            // is identifying the tag, and a credential passed here would put a
            // `PWD_AUTH` on a tap whose own copy says it touches nothing. Tap 1
            // needs a reading, not an open gate.
            //
            // `writesAllowed: false` for the same reason one notch lower down:
            // on a SLIX2 the protection read *is* a write probe.
            let outcome = try await TagPreamble.establish(on: tag, TagPreamble.Request(
                intent: operation.accessIntent,
                heldCredential: nil,
                stagedStyle: armingStyle,
                writesAllowed: false
            ))
            // A tag that wants a credential is not a tap-1 failure. Nothing here
            // holds one by design, so the run goes on to the typed-UID gate and
            // every refusal below is written to proceed on an absent reading
            // rather than to invent one from it. Collecting the credential is a
            // later phase's job.
            //
            // What the outcome does say is that the region this operation needs
            // is gated: the preamble asks only when the tag's own configuration
            // reported a gate over it, or when the tag refused the read that
            // would have described one. That is a statement about the gate being
            // up. It is not a reading of where it starts or what else it covers,
            // so the protection state stays unknown.
            let established: TagPreamble.Established
            var gate = GateReading()
            switch outcome {
            case .established(let reading):
                established = reading
                gate.state = reading.state

            case .needsCredential(let request):
                established = TagPreamble.Established(
                    authenticatedUpFront: false,
                    state: nil,
                    presence: .unknown,
                    provenReadablePage: nil,
                    style: request.style,
                    firstDataPage: tag.chip?.memoryLayout.ndefRange?.lowerBound
                )
                gate.isUpOverThisOperationsRegion = true
            }
            // Before the preflight, because the preflight refuses by throwing
            // and a refusal is a reading. "This tag is not protected, so there
            // is nothing to remove" is the gate read off the chip a moment ago,
            // and it is precisely what the card behind this sheet is wrong
            // about when it sent the user here.
            if let state = gate.state {
                publish(uid: tag.uid, protection: state)
            }
            // An irreversible operation refuses to start against a state it has
            // not established, and "start" is this tap, not the one that writes.
            // Asking the tag now costs nothing and spares the user typing a
            // fourteen-character UID for a change that was never going to happen.
            let findings = try await preflight(operation, on: tag, established, gate)
            if let style = established.style ?? tag.protectionStyle {
                unlockStyle = style
            }
            let uid = tag.uid
            reading = TagReading(
                uid: uid,
                chip: tag.chip?.id,
                chipName: tag.chip?.displayName,
                style: established.style ?? tag.protectionStyle,
                firstDataPage: established.firstDataPage,
                protection: gate.state,
                protectionIsUnknown: gate.state == nil,
                lock: findings.lock,
                attemptLimit: findings.attemptLimit
            )
            await session.invalidate(error: nil)
            currentSession = nil
            confirmedUID = uid
            transition(to: .awaitingConfirmation(uidHex: uid.hexString))
            return true
        } catch let error as TagError {
            if let ending = contact.quietEnding(for: error) {
                await endQuietly(session, ending)
                return false
            }
            await session.invalidate(error: String(localized: error.userMessage))
            currentSession = nil
            transition(to: .error(
                message: String(localized: error.userMessage),
                diagnostics: error.diagnostics
            ))
            return false
        } catch {
            _ = contact.quietEnding(for: error)
            await session.invalidate(error: nil)
            currentSession = nil
            transition(to: .error(
                message: "Something unexpected went wrong.",
                diagnostics: "\(error)"
            ))
            return false
        }
    }

    /// Called by the UI once the typed-UID gate is satisfied.
    ///
    /// A run that needs a credential does not pass the gate without one. The
    /// gate is the window this flow already has with no session open, so it is
    /// where the credential is collected: letting the run through without one
    /// would spend tap 2 discovering what tap 1 already knew.
    public func confirm() {
        guard case .awaitingConfirmation = phase else { return }
        // An arm that has not been told what it is arming does not pass either.
        // The Protect screen's fields are rendered from the reading, which
        // arrives at this gate and not before, so this is the same window the
        // credential is collected in and the same refusal applies to both.
        guard !requiresProtectionSettings else { return }
        guard !requiresUnlockCredential || unlockCredential != nil else { return }
        confirmationContinuation?.resume(returning: true)
        confirmationContinuation = nil
    }

    /// Return to `.idle` so the flow can be run again from the start.
    ///
    /// A two-tap flow has twice as many ways to end up somewhere terminal — the
    /// user cancels the system sheet, the tag slips, iOS times the session out —
    /// and there was no way back from any of them: `.task` only fires `begin()`
    /// once, so an error stranded the screen until the user navigated away and
    /// came back.
    ///
    /// Deliberately clears `confirmedUID` rather than resuming at tap 2. A retry
    /// re-identifies and re-confirms, so consent is never carried across a
    /// failure whose cause we don't know — the tag that comes back may not be the
    /// one that went in.
    public func retry() {
        guard !isRunning else { return }
        confirmedUID = nil
        connectedTag = nil
        reading = nil
        // The credential goes with it. "Try again" on a screen that collected
        // one used to re-present the credential the tag had just refused, so a
        // single mistyped password cost the tag a counted `PWD_AUTH` on each of
        // two taps with nothing on screen saying so. A credential is supplied
        // again through `supplyUnlockCredential`, deliberately by the screen
        // that collects it.
        clearTheCredential()
        presentsFactoryDefault = false
        recovery = nil
        didOpenGate = false
        transition(to: .idle)
    }

    /// Supply the credential the tag asked for, and resume at tap 2.
    ///
    /// Mirrors `WriteFlowModel.unlock(with:)`, including what it does **not**
    /// do: neither `confirmedUID` nor the consent it stands for is cleared. The
    /// tag has not changed, only the credential offered to it, and re-asking for
    /// fourteen typed characters because a password was mistyped is a tax on the
    /// recovery flow rather than a safety property.
    ///
    /// One authentication attempt per activation survives this by construction.
    /// The resumed run is a fresh tap, and inside it the credential is presented
    /// once: there is no retry loop anywhere on this path, so a second attempt
    /// is always a second hold of the tag.
    public func unlock(with credential: TagCredential) async {
        guard phase == .needsUnlock else { return }
        unlockCredential = credential
        unlockFailed = false
        unlockRefusal = nil
        transition(to: .idle)
        await begin()
    }

    /// Run the same operation again, presenting the chip family's published
    /// delivery password instead of the credential the tag refused.
    ///
    /// This is a **second tap**, and it has to be: a refused `PWD_AUTH` NAKs and
    /// the NAK halts a Type-2 chip until it is re-selected, so a second password
    /// in the same activation is answered by silence. See
    /// `Type2PasswordDriver.openGate`.
    ///
    /// It clears `confirmedUID` exactly as `retry()` does, so the run that
    /// follows identifies the tag and passes the typed-UID gate again. The
    /// two-tap guarantee is reused here, never weakened: only the credential
    /// moves, and there is no route by which this could change which operation
    /// runs, because it writes `unlockCredential` and nothing else.
    ///
    /// The values come from `Type2Credential`, which cites NXP NTAG213/215/216
    /// rev 3.2 Table 5 and MF0ULX1 rev 3.3 Table 8, and which is what this app's
    /// own removal writes back. Nothing here invents a byte.
    ///
    /// Nothing calls this on the app's own initiative. It costs one of the tag's
    /// password attempts, and on a tag configured with an attempt limit those run
    /// out for good, so it is a labelled button and never a fallback.
    public func retryWithFactoryDefault() {
        guard !isRunning,
              recovery == .tryType2FactoryDefault,
              mayPresentTheFactoryDefault
        else { return }
        unlockCredential = .type2(
            password: Type2Credential.factoryPassword,
            pack: Type2Credential.factoryPack
        )
        unlockFailed = false
        unlockRefusal = nil
        confirmedUID = nil
        connectedTag = nil
        reading = nil
        recovery = nil
        didOpenGate = false
        presentsFactoryDefault = true
        transition(to: .idle)
    }

    /// Forget whatever this run was holding for the tag.
    private func clearTheCredential() {
        unlockCredential = nil
        unlockFailed = false
        unlockRefusal = nil
    }

    /// `true` exactly while an NFC session is open, which is when nothing may
    /// change what the next frame will carry.
    ///
    /// The two phases this deliberately excludes are the ones this flow exists
    /// to have: the typed-UID gate and the unlock prompt both tear the session
    /// down first, and both are where the user types.
    private var isHoldingATag: Bool {
        switch phase {
        case .identifying, .polling, .connected, .executing, .verifying: true
        case .idle, .awaitingConfirmation, .needsUnlock, .done, .cancelled, .noTagFound, .error: false
        }
    }

    private var isRunning: Bool {
        switch phase {
        // `.needsUnlock` holds no session and no suspended task, so it is not a
        // run in flight: the screen may hand it a credential, retry it, or walk
        // away from it, exactly as it may from `.error`.
        case .idle, .needsUnlock, .done, .cancelled, .noTagFound, .error: false
        default: true
        }
    }

    /// Cancel the operation. Resolves the confirmation gate if waiting, and
    /// invalidates the session.
    public func cancel() {
        confirmedUID = nil
        reading = nil
        clearTheCredential()
        presentsFactoryDefault = false
        recovery = nil
        didOpenGate = false
        confirmationContinuation?.resume(returning: false)
        confirmationContinuation = nil
        Task { [currentSession] in
            await currentSession?.invalidate(error: "Cancelled.")
        }
        currentSession = nil
        connectedTag = nil
        transition(to: .idle)
    }

    // MARK: - Private

    /// Suspends until the gate resolves. `false` means the user cancelled and the
    /// run must stop without opening tap 2's session.
    private func waitForConfirmation() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            confirmationContinuation = continuation
        }
    }

    /// The offer a failure earns, or `nil`.
    ///
    /// ## Why this reads what the app *did* and not which error came back
    ///
    /// The obvious trigger is `TagError.kind == .authFailed`, and it is the wrong
    /// one. `Type2PasswordDriver.authenticate` produces `.authFailed` only when
    /// the transceive returns a short payload; when the transport errors instead
    /// it produces `.authInconclusive`, and a NAK returns a Type-2 chip to HALT,
    /// which `CoreNFCSession` says surfaces "as a 1-byte payload or a transport
    /// error, depending on iOS version". Both live captures show the transport
    /// form: 2026-08-07 on an NTAG216 (`docs/internal/test-harness.md`) and
    /// 2026-09-09 on an NTAG213
    /// (`docs/internal/bench-traces/2026-09-09-t2-3-x-2-ntag213.log`). The
    /// simulator returns the payload form, which has no live capture at all. So
    /// an `.authFailed`-only trigger is green in every test and, on the evidence
    /// this repo actually has, invisible on a phone. That is the failure mode
    /// CLAUDE.md names twice, and the second capture is what turned it from a
    /// risk into an observation.
    ///
    /// The keying below is therefore left exactly as it is. It was written
    /// against the possibility that the kind would be unreliable; silicon has now
    /// twice said it is.
    ///
    /// What the driver can state without guessing is what it did: it read the
    /// tag's configuration, found the gate armed, and put one `PWD_AUTH` on the
    /// wire. That arrives as a failed `ProtectionResidue.Step.gateOpened` inside
    /// `TagError.protectionIncomplete`, whichever kind the transport chose.
    ///
    /// It also excludes, by construction, the failures where nothing was
    /// presented. `TagError.readProtected` carries kind `.authFailed` and is
    /// thrown before any authentication, by both `Type2PasswordDriver.enable` and
    /// `readPages`; it carries no residue, so it earns no offer. A run that
    /// already presented the delivery password earns none either, because the
    /// offer would be to send the identical frame a second time.
    ///
    /// Deliberately consults no credential store. The tags this exists for were
    /// stranded by a build that predates `TagCredentialStore`, so gating on a
    /// local record would withhold the recovery from the population that needs
    /// it, and a stored record is a belief rather than a reading of the tag.
    ///
    /// ## Never on a tag whose attempt limit the driver just read
    ///
    /// The offer costs one more counted `PWD_AUTH`, and on a limited tag that
    /// may be the last one: the chip locks one past `AUTH_LIM`, permanently, and
    /// then refuses the owner's real password for good (bench 2026-09-10, tag A
    /// `04:A9:DB:3A:D6:1F:90`, limit 1, locked at 11:29:06 by taking this exact
    /// offer). A general warning about limits is not enough here, because the
    /// app is the one proposing the tap and it is holding the reading that says
    /// this tag cannot afford it.
    ///
    /// `attemptLimit` is non-nil only when the driver read `AUTH_LIM` armed from
    /// the tag's own configuration before presenting anything
    /// (`Type2PasswordDriver.presentCredential`), so withholding on it withholds
    /// exactly where a try is counted and nowhere else.
    ///
    /// A read-protected tag hides `AUTH_LIM` (`limitReading == .hidden`) and
    /// keeps the offer. That is a judgement rather than a certainty, and it
    /// cuts both ways: the app cannot price the tap, and the tag may have a
    /// limit. It keeps the offer because the alternative withholds the one
    /// recovery this population has on no evidence at all, the screen carries
    /// its own warning about limits above the button, and the refusal that
    /// reaches the banner now says a try may have counted. Revisit it the day a
    /// read-gated tag turns up in the stranded state this offer exists for; the
    /// offer's own premise (a tag left holding the delivery password) is hard to
    /// reach on a read-gated tag, because every removal order this app has
    /// shipped clears ACCESS before it rewrites PWD.
    /// Takes the credential the run presented rather than the operation it
    /// belongs to. Which operation ran decides whether the offer may be *made*,
    /// and that is `mayPresentTheFactoryDefault`, at the one call site; what the
    /// classifier needs is the four bytes that went out.
    static func recovery(after error: TagError, presenting credential: TagCredential?) -> Recovery? {
        guard error.attemptLimit == nil, presentedAndRefused(error) else { return nil }
        guard case .type2(let presented, _)? = credential,
              presented != Type2Credential.factoryPassword
        else { return nil }
        return .tryType2FactoryDefault
    }

    /// Whether a credential frame went out and did not open the tag, in the two
    /// shapes that fact reaches this flow in.
    ///
    /// A driver mid-sequence reports it as a failed `ProtectionResidue` step.
    /// The shared preamble reports it as `TagError.presentedACredential`, which
    /// is set by the code that sent the frame, at the site that sent it, and is
    /// the same statement without a residue to hang it on.
    ///
    /// Neither is the error's *kind*, and that is the whole point. The kind is
    /// unreliable: `Type2PasswordDriver.authenticate` answers a short payload
    /// with `.authFailed` and a transport loss with `.authInconclusive`, both
    /// live captures of a real refusal show the transport form, and the
    /// simulator produces the payload form. A kind-keyed trigger is green in
    /// every test here and invisible on a phone. It also excludes, by
    /// construction, the failures where nothing was presented:
    /// `TagError.readProtected` wears `.authFailed` and is thrown before any
    /// authentication, and it carries neither shape.
    private static func presentedAndRefused(_ error: TagError) -> Bool {
        if case .protectionIncomplete(let residue) = error.kind {
            return residue.family == .type2 && residue.failures.contains { $0.step == .gateOpened }
        }
        return error.presentedACredential
    }

    private func execute(_ operation: Operation, on tag: ConnectedTag) async throws -> Summary {
        switch operation {
        case .erase:
            try await tag.writeNDEF([])
            return .erased

        case .format:
            return try await .formatted(alreadyFormatted: formatCC(on: tag))

        case .permanentLock:
            // Kept rather than discarded: the outcome is the only per-region
            // record of what actually burned, and it is what a half-locked tag
            // has to report. `verify` maps it once the probe below has run.
            lockOutcome = try await tag.permanentLock()
            // Pessimistic until the behavioural probe in `verify` says otherwise.
            return .permanentlyLocked(verified: false)

        case .enableProtection(let requested):
            // Normalised here as well as at `supplyProtection`, so the rule
            // holds for a model built straight from an `Operation` rather than
            // through the screen. See `armable`.
            let pending = Self.armable(requested)
            // The same three lines the write route runs, and for the same
            // reason: `ProtectionSpec.make` forces `authLimit: 0` and pins a
            // read gate to the chip's own first data page, and a caller that
            // assembles a spec itself is a caller that goes round both rules.
            let firstDataPage = tag.chip?.memoryLayout.ndefRange?.lowerBound ?? 4
            guard let spec = ProtectionSpec.make(
                settings: pending.settings,
                credential: pending.credential,
                defaultFirstDataPage: firstDataPage
            ) else {
                throw TagError.capabilityUnsupported(
                    .passwordAuth,
                    diagnostics: "protection credential doesn't match \(pending.settings.effectiveStyle)"
                )
            }
            // Filed before the frame that could apply it, which is what taking a
            // ticket does. This screen used to persist nothing at all, so a tag
            // protected here with a password nobody wrote down was gated behind a
            // credential that existed in no store, which is the state
            // `TagCredentialStore` was made for.
            let ticket = credentials.arming(pending.credential, forUID: tag.uid)
            // `unlockCredential` is the credential the tag holds now. Passing it
            // is what lets an already-armed tag be re-keyed at all, and it is how
            // the factory-default recovery tap opens a tag whose password an
            // earlier torn removal reset. `nil` is legitimate here and only here:
            // a fresh tag holds nothing, and a guess is a spent attempt.
            let residue = try await tag.enableProtection(spec, replacing: unlockCredential)
            ticket.settle(residue)
            didOpenGate = residue.completed.contains(.gateOpened)
            return .passwordSet

        case .disableProtection:
            guard let credential = unlockCredential else {
                throw TagError.capabilityUnsupported(
                    .passwordAuth,
                    diagnostics: "a removal has to present the credential the tag holds now, and this "
                        + "run was given none"
                )
            }
            let ticket = credentials.removing(credential, forUID: tag.uid)
            // The residue is the only report of whether anything was actually
            // authenticated. Discarding it left the screen unable to tell a
            // removal that opened a gate from one that found the gate already
            // open and sent no credential at all.
            let residue = try await tag.disableProtection(using: credential)
            // Whether the record survives turns on a read-back proving the gate
            // down *and* the credential back at the factory value. The argument
            // is on `TagCredentialLedger`, written from the 2026-09-04 incident.
            ticket.settle(residue)
            didOpenGate = residue.completed.contains(.gateOpened)
            return .passwordRemoved

        case .setAttemptLimit(let limit):
            guard case .type2(let password, _)? = unlockCredential else {
                throw TagError.capabilityUnsupported(
                    .passwordAuth,
                    diagnostics: "the attempt limit is a Type-2 ACCESS-byte field and needs a Type-2 "
                        + "credential; this run holds \(unlockCredential == nil ? "none" : "another family's")"
                )
            }
            return try await setAttemptLimit(limit, password: password, on: tag)

        case .memoryDump:
            let bytes = try await dumpMemory(on: tag)
            return .memoryDumped(bytes: bytes)
        }
    }

    /// Write ACCESS bits 2-0, and nothing else.
    ///
    /// Deliberately **not** a second credential sequence. `Type2PasswordDriver`
    /// already owns arming a tag, and a parallel path that writes PWD and PACK
    /// again to change one field is how a shipped sequence ends up with two
    /// implementations that can disagree. So this reads the tag's own CFG1,
    /// changes three bits in it, and puts that one page back, preserving PROT
    /// and every other bit exactly as the tag reported them.
    ///
    /// Order, and why each step is where it is:
    ///  1. **State first.** The gate has to be armed already, or the limit
    ///     guards nothing and is purely a trap set for the tag's future owner.
    ///     Refused here, with nothing written.
    ///  2. **One authentication attempt.** The ACCESS page sits above AUTH0 on an
    ///     armed tag, so the write needs a `PWD_AUTH` first, and a refused one
    ///     NAKs and halts the chip for the rest of the activation. There is no
    ///     retry loop: a second password is always a second tap.
    ///  3. **The write, then a read-back.** ACKs are not proof. `verify` reads
    ///     the byte back, and this returns the pessimistic summary until it does.
    private func setAttemptLimit(
        _ limit: Int,
        password: Data,
        on tag: ConnectedTag
    ) async throws -> Summary {
        guard (1 ... 7).contains(limit) else {
            throw TagError.protocolError(
                "attempt limit must be 1…7",
                diagnostics: "limit=\(limit); 0 means 'no limit' and is what every other control in "
                    + "the app supplies, so it is not something this operation can be asked for"
            )
        }
        let driver = try requireType2PasswordDriver(on: tag)

        let config: Type2ProtectionConfig
        switch try await driver.readState() {
        case .read(let read):
            // Re-established on this tap rather than carried over from tap 1. The
            // UID check proves it is the same tag; it does not prove nothing else
            // has written to it in between.
            guard read.isGateArmed else {
                throw TagError.gateNotArmed(
                    diagnostics: "AUTH0=\(read.auth0) is past page \(read.lastAddressablePage) on tap 2, "
                        + "so the gate this limit was meant to guard is open. Nothing written."
                )
            }
            _ = try await driver.openGate(password: password)
            config = read

        case .gatedByReadProtection:
            // Reads are gated, so CFG1 could not be read up front. Authenticate on
            // the raw primitive and read it afterwards, exactly as `disable` does.
            //
            // The refusal is re-filed on the way out because this is the screen
            // that arms the counter, and it is the one tag shape whose counter
            // the app cannot watch: `AUTH_LIM` lives behind the gate being
            // opened. Unqualified, a wrong password here reads "Couldn't check
            // the password: the tag stopped answering. Hold it steady…", which
            // invites the same password again on a tag that may have one try
            // left.
            _ = try await driver.authenticateThroughAReadGate(password: password)
            guard case .read(let read) = try await driver.readState() else {
                throw TagError.readProtected(
                    diagnostics: "config pages still unreadable after a successful PWD_AUTH; nothing written"
                )
            }
            config = read
        }

        // Read-modify-write, through the driver that owns every other frame in
        // this block. PROT comes back from the tag rather than from the caller:
        // this operation changes the attempt limit and must not quietly move the
        // read gate as a side effect.
        //
        // This went through `ConnectedTag.writeMemory` first, on the reasoning
        // that it is the protocol's own page-write primitive and reaches the wire
        // as the same `A2`. That is true of production and false of the
        // simulator, which answers `writeMemory` out of its page array without
        // ever reaching `handle(command:)`. So the single mutating write of an
        // irreversible operation had no frame in CI to tear, and the lost-ACK
        // branch below could not be reached by any test. The frames an operation
        // ships are the frames it is tested on, or the test is about something
        // else.
        do {
            try await driver.setAttemptLimit(limit, readProtect: config.readProtect, from: config)
        } catch {
            // A refusal may be a lost ACK. Ask the chip what it holds before
            // reporting that the limit is not set, because on a write with no undo
            // "nothing happened" is the one answer that must not be guessed.
            guard case .read(let after)? = try? await driver.readState(),
                  after.authLimit == limit
            else {
                throw error
            }
        }
        // Pessimistic until the read-back in `verify` says otherwise.
        return .attemptLimitSet(limit: limit, verified: false)
    }

    /// Prove the state actually changed, and hand back the summary the UI should
    /// report. Throws on a failed proof; returns a refined summary when the proof
    /// was inconclusive for a reason the datasheet predicts.
    @discardableResult
    private func verify(
        _ operation: Operation,
        on tag: ConnectedTag,
        summary: Summary
    ) async throws -> Summary {
        switch operation {
        case .erase:
            // Two read-backs, and the difference between them is a fact worth
            // keeping rather than a fallback worth hiding.
            //
            // The reader's own path is the stronger proof: it walks the whole
            // structure, Capability Container included, so a tag that answers it
            // is a tag any phone can read. But it refuses a tag with no
            // Capability Container outright, and an erase is a page write that
            // does not care whether one is present. So erasing a factory MIFARE
            // Ultralight C, whose page 3 ships blank (MF0ICU2 rev 3.3 Table 13),
            // wrote a perfectly good empty envelope and then reported the whole
            // operation failed. "It failed" is the wrong report about a tag whose
            // pages this run has already rewritten.
            var readerWalkedIt = true
            let readBack: Data
            do {
                readBack = try await tag.readNDEF()
            } catch let error as TagError where error.kind == .capabilityUnsupported(.ndefRead) {
                readBack = try await readErasedPages(from: tag, refusal: error)
                readerWalkedIt = false
            }
            // An erased tag holds no user records, but real hardware echoes that
            // back either as zero bytes or as a single Empty record (`D0 00 00`)
            // — both are valid empty-message forms. Compare by meaning, not bytes.
            if !NDEFCodec.isEmptyMessage(readBack) {
                throw TagError.verificationFailed(
                    diff: readBack,
                    diagnostics: "erase verify: readBack=\(readBack.hexString) is not an empty NDEF message"
                )
            }
            // Only the reader's path establishes readability, and only it may
            // clear the editor's notice. The page read below proves the bytes we
            // wrote are there and says nothing about whether a reader can find
            // them, which on a tag with no Capability Container it cannot.
            if readerWalkedIt {
                publish(ndefReadable: true)
            }
            // The data area is empty, and that is a reading rather than an
            // inference: the guard above threw unless the read-back decoded as an
            // empty message. Both paths establish it, so this is not gated on
            // `readerWalkedIt` the way readability is.
            //
            // Without it the editor kept listing the records it had just cleared
            // (2026-09-22, NTAG213). `ndefReadable` was the only thing an erase
            // published and it answers a different question, whether the
            // structure walks, not what is in it.
            publish(records: [])

        case .format:
            // The Type-2 OTP page is read back inside `formatCC`, where the CC
            // bytes are in scope and a mismatch can name them. Type-5 keeps its
            // CC in an ordinary rewritable block, so verify it here.
            if case .type5? = tag.chip?.family, let cc = tag.chip?.factoryType5CC {
                let block0 = try await tag.transceive(
                    RawCommand(bytes: Data([0x02, Iso15693Opcode.readSingleBlock, 0x00]), name: "CC read-back")
                )
                guard block0.first == 0x00, block0.dropFirst().prefix(cc.count) == cc else {
                    throw TagError.verificationFailed(
                        diff: Data(block0.dropFirst()),
                        diagnostics: "Type-5 CC read-back: wrote \(cc.hexString), block 0 reads \(block0.hexString)"
                    )
                }
            }
            // Both families have now read their Capability Container back:
            // Type-2 inside `formatCC`, where the bytes are in scope, and Type-5
            // immediately above. So the editor's "this tag isn't formatted"
            // notice can stop saying it.
            publish(formatted: true)

        case .permanentLock:
            // Ask the chip whether it now refuses writes, rather than believing
            // the ACKs. `readProtectionState` reports a Type-5 tag's locked
            // blocks and a Type-2 tag's config, but neither proves a *lock*, so
            // probe behaviourally: rewrite a data unit with the bytes it already
            // holds. An accepted write means the tag is still writable.
            //
            // ⚠️ Type-2 lock timing is **not uniform across the family.** MIFARE
            // Ultralight C lock bytes are "valid upon the next REQA or WUPA
            // command" (MF0ICU2 §7.5.3), so an in-session probe can see the
            // write accepted on a tag that really is locked. NTAG21x and
            // Ultralight EV1 latch immediately (MF0ULX1 §8.5.2: "Setting a lock
            // bit to 1 immediately prevents write access"), so only those two
            // can be judged in this session.
            let witnessed = try await verifyPermanentLock(on: tag)
            // The probe rewrites page 4, which sits inside pages 3 to 15, so it
            // proves the **static** region and says nothing whatever about the
            // dynamic lock page. `TagLockReading` is the type that keeps those
            // apart; a whole-tag verdict drawn from one probe would be the claim
            // this branch exists to avoid making.
            if let lockOutcome, let operatedUID {
                observation = TagObservation(
                    uid: operatedUID,
                    lock: TagLockReading(lockOutcome, staticRegionWitnessed: witnessed)
                )
            }
            return .permanentlyLocked(verified: witnessed)

        case .enableProtection(let pending):
            // Read the configuration back. What can be proven differs by family:
            // AUTH0/ACCESS (Type-2) and the file's access rights (Type-4) are
            // readable, but **no password or key ever is** — NTAG21x PWD/PACK
            // read back as `00`s by design (rev 3.2 §8.8), the Ultralight C key
            // pages NAK, and SLIX2 passwords are write-only. So this proves the
            // gate was armed, never that the credential stored is the one the
            // user chose. That limit is inherent, not an omission.
            // `try?`. The driver has already proven this gate with its own
            // read-back before returning, so this is a second opinion, not the
            // success criterion. A bare `try` let a slip here throw `.tagLost`
            // past a completed operation, and the user was told the tag was lost
            // about a tag that is protected with the password they just chose.
            // Nothing after the criterion may report failure.
            guard let state = try? await tag.readProtectionState() else { return summary }
            publish(protection: state)
            guard state.passwordProtect else {
                throw TagError.verificationFailed(
                    diff: Data(),
                    // The *style*, never the secret. A `PendingProtection`
                    // carries the password or the key, and a diagnostics string
                    // is written to be copied into a bug report.
                    diagnostics: "protection read-back says the tag is NOT protected after "
                        + "\(pending.settings.effectiveStyle): "
                        + "the credential may have been written without the gate being armed"
                )
            }

        case .disableProtection:
            // Same rule as the arm above, and it matters more here: a removal
            // that succeeded and was then lost on this read used to report a
            // failure over a tag that is open and holding the factory password,
            // which is the 2026-09-04 incident in miniature.
            guard let state = try? await tag.readProtectionState() else { return summary }
            publish(protection: state)
            guard !state.passwordProtect else {
                throw TagError.verificationFailed(
                    diff: Data(),
                    diagnostics: "protection read-back says the tag is STILL protected after removal: "
                        + "do not discard the credential"
                )
            }

        case .setAttemptLimit(let limit):
            let driver = try requireType2PasswordDriver(on: tag)
            // The write was acknowledged before this ran. So a read-back that
            // cannot be *performed* is missing knowledge, not a failed write, and
            // saying "it failed" about a tag that is very probably armed is the
            // report that is certainly wrong. Report it as written-not-witnessed
            // and let the copy tell the user to scan again, which is the same
            // distinction a permanent lock draws on Ultralight C.
            guard case .read(let after)? = try? await driver.readState() else {
                return .attemptLimitSet(limit: limit, verified: false)
            }
            // The ACCESS byte was read back, and it carries AUTH0, so this run
            // now knows whether the gate is armed. Published on this branch only:
            // the branch above read nothing.
            publish(protection: after.protection)
            guard after.authLimit == limit else {
                throw TagError.verificationFailed(
                    diff: Data([after.access]),
                    diagnostics: "ACCESS read-back reports AUTH_LIM=\(after.authLimit), asked for \(limit) "
                        + "(access=\(String(format: "%02X", after.access)))"
                )
            }
            guard after.isGateArmed else {
                throw TagError.verificationFailed(
                    diff: Data([after.auth0]),
                    diagnostics: "AUTH_LIM=\(limit) landed but AUTH0=\(after.auth0) now points past "
                        + "page \(after.lastAddressablePage): the limit guards a gate that is open"
                )
            }
            return .attemptLimitSet(limit: limit, verified: true)

        case .memoryDump:
            break
        }
        return summary
    }

    /// Behavioural proof for `.permanentLock`: a locked tag must refuse a write
    /// of the bytes it already holds.
    ///
    /// Returns `true` when the refusal was actually observed, `false` when this
    /// chip's lock bits only take effect at the next activation and so cannot be
    /// judged in this session. Throws only for the case that is genuinely wrong:
    /// a tag that ACKed the lock and still accepts writes.
    private func verifyPermanentLock(on tag: ConnectedTag) async throws -> Bool {
        switch tag.chip?.family {
        case .type2(let variant):
            // See the timing note above: Ultralight C latches at the next
            // REQA/WUPA, so an in-session verdict here would be a false alarm
            // on an irreversible operation. Not judging is the honest option; the
            // tag is locked, we simply cannot witness it this tap — and now the
            // UI says exactly that rather than claiming a proof it doesn't have.
            guard variant != .mifareUltralightC else { return false }
            let pageSize = tag.chip?.memoryLayout.pageSize ?? 4
            let offset = 4 * pageSize
            let original = try await tag.readMemory(range: offset ..< offset + pageSize)
            var accepted = false
            do {
                try await tag.writeMemory(at: offset, bytes: original)
                accepted = true
            } catch {
                // Any refusal is the proof. Deliberately not narrowed to a clean
                // NAK: a refusal returns a Type-2 tag to HALT and iOS surfaces
                // that as either a protocol error or a dropped tag.
            }
            if accepted {
                throw TagError.verificationFailed(
                    diff: original,
                    diagnostics: "page 4 accepted a write after the lock bytes were set: "
                        + "the tag is NOT permanently locked (clone silicon?)"
                )
            }
            return true

        case .type5:
            let probeBlock: UInt8 = 2
            let read = try await tag.transceive(
                RawCommand(bytes: Data([0x02, Iso15693Opcode.readSingleBlock, probeBlock]), name: "lock probe read")
            )
            // A probe we couldn't even read is not a verdict either way.
            guard read.first == 0x00, read.count >= 5 else { return false }
            let original = read.subdata(in: (read.startIndex + 1) ..< (read.startIndex + 5))
            let write = try await tag.transceive(
                RawCommand(
                    bytes: Data([0x02, Iso15693Opcode.writeSingleBlock, probeBlock]) + original,
                    name: "lock probe write"
                )
            )
            if write.first == 0x00 {
                throw TagError.verificationFailed(
                    diff: original,
                    diagnostics: "block \(probeBlock) accepted a write after LOCK_BLOCK: "
                        + "the tag is NOT permanently locked"
                )
            }
            return true

        default:
            return false
        }
    }

    /// Writes the Capability Container. Returns `true` when the tag already
    /// carried the correct CC and nothing was written.
    @discardableResult
    private func formatCC(on tag: ConnectedTag) async throws -> Bool {
        // Each family keeps its Capability Container somewhere different, so
        // dispatch on the family rather than on `.memoryWrite` alone — a SLIX
        // advertises `.memoryWrite` but its CC is a block, not a page, and the
        // page writer would refuse it with a misleading "not a Type-2/MIFARE tag".
        switch tag.chip?.family {
        case .type2:
            // Factory CC bytes are the single source of truth on `ChipProfile`,
            // shared with the console presets and the chip simulators.
            //
            // An unidentified Type-2 chip must **refuse**, never fall back. This
            // previously defaulted to the smallest CC (`E1 10 06 00`, 48 B) on
            // the theory that guessing low is conservative. It is not: page 3 is
            // OTP, so the write ORs bits into whatever is already there and can
            // never clear them. Writing a 48-byte CC to a 144-byte chip either
            // permanently under-declares two thirds of its NDEF area, or, if a
            // CC is already present, ORs into it and produces a size byte that
            // belongs to no chip at all (0x12 | 0x06 = 0x16, declaring 176 bytes
            // of a 144-byte tag). There is exactly one attempt per tag, so a
            // guess here is unrecoverable in a way that an error is not.
            guard let cc = tag.chip?.factoryCC else {
                throw TagError.capabilityUnsupported(
                    .formatCC,
                    diagnostics: "Type-2 CC needs a known chip profile; this tag identified as "
                        + "\(tag.chip?.id.description ?? "unidentified") with no factory CC. "
                        + "Page 3 is OTP, so a guessed size byte cannot be undone."
                )
            }
            try tag.require(.memoryWrite)
            // CC lives at page 3 on Type-2 chips, and page 3 is **OTP**: writes
            // OR bits in and can never clear them. So read it first and refuse
            // outright unless it is still blank.
            //
            // Without this guard, formatting an already-formatted tag ORs the
            // factory CC into whatever is there. Identical bytes make that a
            // no-op, which is why it survives the common case — but a tag
            // carrying a foreign CC, or one whose chip we misidentified, gets a
            // size byte belonging to no chip (`0x12 | 0x06 = 0x16`, declaring
            // 176 B of a 144-byte tag) and there is no second attempt. The
            // DEBUG `formatVirginCC` op has always had this check; the shipping
            // path, which is the one users actually reach, did not.
            let existingCC = try await tag.readMemory(range: 12 ..< 16)
            if Type2CC.isFormatted(existingCC) {
                // Already formatted. Two very different cases hide here, and
                // the old code treated both as "just write it again":
                //
                // • Identical bytes — the overwhelmingly common one, since most
                //   NTAG21x ship pre-formatted. ORing identical bits changes
                //   nothing, so skip the write entirely rather than spend the
                //   tag's one OTP shot re-asserting what is already true.
                // • Different bytes — a foreign CC, or a chip we misidentified.
                //   Here the OR genuinely corrupts: `0x12 | 0x06 = 0x16`
                //   declares 176 B of a 144-byte tag, and page 3 can never be
                //   corrected. Refuse.
                guard existingCC == cc else {
                    throw TagError.protocolError(
                        String(localized: "This tag already has a different Capability Container."),
                        diagnostics: "page 3 = \(existingCC.hexString), would OR \(cc.hexString) into it: "
                            + "OTP bits cannot be cleared, so this would corrupt the CC permanently"
                    )
                }
                return true
            }
            try await tag.writeMemory(at: 12, bytes: cc)
            // Read the OTP page back. This is the one write in the app that can
            // never be retried or corrected, so an ACK alone is not proof.
            let writtenCC = try await tag.readMemory(range: 12 ..< 16)
            guard writtenCC == cc else {
                throw TagError.verificationFailed(
                    diff: writtenCC,
                    diagnostics: "CC read-back mismatch: wrote \(cc.hexString), page 3 now reads \(writtenCC.hexString)"
                )
            }
            return false

        case .type5:
            // Type-5 keeps its CC in block 0 and, unlike Type-2, blocks stay
            // rewritable until explicitly locked — so this is recoverable. This
            // is the path a factory ICODE SLIX2 needs: it ships with no CC, and
            // without one CoreNFC refuses every content NDEF write against it.
            guard let cc = tag.chip?.factoryType5CC else {
                throw TagError.capabilityUnsupported(
                    .formatCC,
                    diagnostics: "Type-5 CC needs known block geometry; profile reports "
                        + "\(tag.chip?.memoryLayout.pageCount ?? 0) × \(tag.chip?.memoryLayout.pageSize ?? 0) B"
                )
            }
            try tag.require(.rawTransceive)
            try await Type5Formatter(transceive: { try await tag.transceive($0) }).format(cc: cc)
            // Type-5 blocks are rewritable, so the formatter always writes.
            return false

        default:
            throw TagError.capabilityUnsupported(
                .formatCC,
                diagnostics: "CC format unsupported on chip family \(tag.chip?.family.shortName ?? "unknown")"
            )
        }
    }

    private func dumpMemory(on tag: ConnectedTag) async throws -> Data {
        try tag.require(.memoryRead)
        // Bounded by what the chip will actually answer, not by how much memory
        // it has. On a MIFARE Ultralight C the last four pages hold the 3DES key
        // and are not decoded for reads at all, so walking to `pageCount` NAKs,
        // and a NAK halts a Type-2 tag for the rest of the activation: the dump
        // would take the whole session down with it rather than just returning
        // four pages short.
        let pageCount: Int = switch tag.chip?.family {
        case .type2: tag.chip?.readablePageCount ?? 0
        default: 0
        }
        guard pageCount > 0 else {
            throw TagError.capabilityUnsupported(
                .memoryRead,
                diagnostics: "memory dump unsupported on chip family \(tag.chip?.family.shortName ?? "unknown")"
            )
        }
        return try await tag.readMemory(range: 0 ..< (pageCount * 4))
    }

    /// Merge a read-back into this run's observation.
    ///
    /// Merging rather than replacing, because one run can establish more than
    /// one fact and the later call must not erase the earlier one. Silently does
    /// nothing without an operated UID: a reading nobody can attribute to a tag
    /// is not one anybody should act on.
    /// - Parameter uid: the tag a tap-1 reading came off, for the window where
    ///   `operatedUID` is deliberately still nil.
    ///
    ///   `operatedUID` is set when tap 2 connects, so for a long time this guard
    ///   read "nothing established during the identify tap may be published",
    ///   which is not a rule anybody chose. Tap 1 reads the gate, and for two
    ///   operations it reads the lock bytes and the whole Type-2 configuration,
    ///   and then throws those readings away on exactly the paths where they are
    ///   most worth having: the refusals, which are themselves readings. Remove
    ///   a password from a tag whose gate tap 1 read as already open and the
    ///   card behind the sheet went on saying "Password, write-only" about it.
    func publish(
        uid: Data? = nil,
        protection: TagProtection? = nil,
        lock: TagLockReading? = nil,
        formatted: Bool? = nil,
        ndefReadable: Bool? = nil,
        records: [NDEFRecord]? = nil
    ) {
        guard let subject = uid ?? operatedUID else { return }
        let latest = TagObservation(
            uid: subject, protection: protection, lock: lock,
            formatted: formatted, ndefReadable: ndefReadable, records: records
        )
        observation = observation?.merging(latest) ?? latest
    }

    /// Read the erased envelope straight off the pages it was written to, for a
    /// tag whose reader path refused the message.
    ///
    /// The refusal is `queryNDEFStatus` answering cleanly rather than a NAK, so
    /// the tag has not halted and this read is safe. Sixteen bytes is one frame
    /// and holds the whole empty envelope (`03 00 FE`) with room to spare.
    ///
    /// Rethrows the original refusal when there is nothing to read: on a chip
    /// with no page-addressed NDEF range there is no second opinion to be had,
    /// and inventing a pass would be worse than the refusal.
    private func readErasedPages(from tag: ConnectedTag, refusal: TagError) async throws -> Data {
        guard let layout = tag.chip?.memoryLayout, let ndef = layout.ndefRange,
              tag.capabilities.contains(.memoryRead)
        else { throw refusal }
        let start = ndef.lowerBound * layout.pageSize
        let end = min(start + 16, (ndef.upperBound + 1) * layout.pageSize)
        let raw = try await tag.readMemory(range: start ..< end)
        return try Type2NDEF.unwrap(raw)
    }

    private func transition(to newPhase: Phase) {
        phase = newPhase
        transitionCount &+= 1
    }
}
