#if DEBUG
import Foundation
import HexNFCKit
import HexNFCRecords
import HexNFCTestKit
import Observation

/// DEBUG-only, live-only flow that verifies a tag ACTUALLY enforces protection on
/// real silicon — the one thing the single-tap batch suite can't prove. The batch
/// writes the config and reads it back (protection *committed*), but genuine silicon
/// only starts *enforcing* the restriction at the next tag activation (an RF
/// power-cycle), and clone/aftermarket tags often never enforce it at all.
///
/// One tap starts a HANDS-OFF sequence of up to three back-to-back sessions (the
/// user just keeps the tag on the phone). Separate sessions are required because a
/// real enforcement refusal tears down the CoreNFC session — the tag stops answering
/// after refusing the write — so cleanup can't share the probe's session:
///
///   Arm:    write protection, confirm via read-back, end the session.
///   Test:   a fresh activation re-latches the gate; do ONE unauthenticated write and
///           classify: accepted = not enforced (clone), refused = enforced (genuine),
///           tag-lost = inconclusive. If the session survives, it disables here.
///   Remove: only when the probe disturbed the session — a fresh session removes
///           protection so the tag never ends protected.
///
/// The chip-specific arm/probe/remove primitives live in an `EnforcementStrategy`
/// (Type-2 AUTH0 latching, or NTAG424 AES EV2 file gating); this model owns the
/// generic coordination, settle timings, retries and the 202-teardown race handling.
///
/// SAFETY: protection is only ever written with the harness's fixed test credential
/// (which the batch cleanup and/or this flow's own disable clear). Every path drives
/// toward a guaranteed disable; a failure reveals Retry / Disable-now.
@MainActor
@Observable
public final class EnforcementCheckFlowModel {
    /// The three visible stages of the sequence.
    public enum Step: Int, CaseIterable, Sendable {
        case arm
        case test
        case remove
        public var title: String {
            switch self {
            case .arm: "Arm protection"
            case .test: "Test enforcement"
            case .remove: "Remove protection"
            }
        }
    }

    public enum Phase {
        case intro
        case running
        case done(String)
        case failed(message: String, diagnostics: String, canRetry: Bool)
    }

    public private(set) var phase: Phase = .intro
    /// The stage currently in flight (nil before the first, or when finished).
    public private(set) var activeStep: Step?
    /// Stages that have completed successfully this run.
    public private(set) var completedSteps: Set<Step> = []
    /// A short "what's happening now" line under the tracker.
    public private(set) var statusDetail: String = ""
    /// Bumped on every stage transition to drive `.hexHero` pulses.
    public private(set) var pulse: Int = 0

    private let strategy: any EnforcementStrategy
    private var task: Task<Void, Never>?

    /// Failable, and deliberately so: there is no safe default strategy.
    ///
    /// This used to fall back to `Type2EnforcementStrategy` for anything that
    /// wasn't Type-4, which meant every unsupported chip silently got the
    /// NTAG21x config-page path. On an ICODE SLIX that is a different transport
    /// entirely; on a MIFARE Ultralight C it would write an NTAG21x AUTH0 and
    /// ACCESS byte to pages that hold a 3DES key, which bricks the tag. The
    /// selection now mirrors `supports(_:)` exactly, so a chip without a
    /// strategy cannot be started at all.
    public init?(
        factory: TagSessionFactory,
        profile: ChipProfile,
        expectedUID: Data,
        credentials: TagTestCredentials = .init()
    ) {
        if Type4EnforcementStrategy.supports(profile) {
            strategy = Type4EnforcementStrategy(
                factory: factory,
                profile: profile,
                expectedUID: expectedUID,
                credentials: credentials
            )
        } else if UltralightCEnforcementStrategy.supports(profile) {
            strategy = UltralightCEnforcementStrategy(
                factory: factory,
                profile: profile,
                expectedUID: expectedUID,
                credentials: credentials
            )
        } else if Type2EnforcementStrategy.supports(profile) {
            strategy = Type2EnforcementStrategy(
                factory: factory,
                profile: profile,
                expectedUID: expectedUID,
                credentials: credentials
            )
        } else {
            return nil
        }
    }

    public var uidTail: String {
        String(strategy.expectedUID.hexString.replacingOccurrences(of: ":", with: "").suffix(4))
    }

    public var introHeadline: String {
        strategy.introHeadline
    }

    public var introBody: String {
        strategy.introBody
    }

    /// Any profile whose family has an enforcement strategy can run this flow.
    public static func supports(_ profile: ChipProfile) -> Bool {
        Type2EnforcementStrategy.supports(profile)
            || Type4EnforcementStrategy.supports(profile)
            || UltralightCEnforcementStrategy.supports(profile)
    }

    // MARK: - Intent

    /// The single entry point: kicks off the whole hands-off sequence.
    public func start() {
        guard case .intro = phase else { return }
        beginRun()
    }

    /// Re-run the whole sequence after a failure.
    public func retry() {
        guard case .failed = phase else { return }
        beginRun()
    }

    /// Escape from a failed state: just remove protection and finish (idempotent —
    /// a no-op if the tag isn't actually protected).
    public func disableNow() {
        guard case .failed = phase else { return }
        phase = .running
        activeStep = .remove
        statusDetail = "Removing protection. Hold the tag flat on the phone…"
        pulse &+= 1
        task = Task {
            switch await self.runDisableWithRetry() {
            case .done(true):
                await self.finishClean(self.strategy.summary(outcome: .skipped, clean: true))

            case .done(false):
                self.fail("Tag still reports protection after removal. Try again.",
                          "readProtectionState still reports protected; uid=\(self.strategy.expectedUID.hexString)")

            case .failed(let message, let diagnostics):
                self.fail(message, diagnostics)
            }
        }
    }

    public func reset() {
        task?.cancel()
        phase = .intro
        activeStep = nil
        completedSteps = []
        statusDetail = ""
    }

    private func beginRun() {
        task?.cancel()
        phase = .running
        activeStep = nil
        completedSteps = []
        statusDetail = ""
        task = Task { await runSequence() }
    }

    // MARK: - Sequence coordinator

    private func setStep(_ step: Step, _ detail: String) {
        activeStep = step
        statusDetail = detail
        pulse &+= 1
    }

    /// Land step 3's (Remove) checkmark and hold a beat so the tracker shows all
    /// three steps completing before the result replaces it — used by every success
    /// path, including the one where the removal ran INSIDE the probe session (so
    /// there was no separate remove tap to watch). The checkmark animates in via the
    /// view's `completedSteps` animation.
    private func finishClean(_ summary: String) async {
        completedSteps.insert(.remove)
        activeStep = nil
        statusDetail = "Protection removed: tag left clean."
        pulse &+= 1
        try? await Task.sleep(for: .seconds(0.7))
        phase = .done(summary)
    }

    private func runSequence() async {
        setStep(.arm, "Arming protection. Hold the tag flat on the phone…")
        do {
            try await strategy.arm()
        } catch let failure as EnforcementFailure {
            fail(failure.message, failure.diagnostics)
            return
        } catch let error as TagError {
            fail(String(localized: error.userMessage), error.diagnostics)
            return
        } catch {
            fail("\(error)", "")
            return
        }
        completedSteps.insert(.arm)
        // `invalidate` above already waited for real teardown — but iOS keeps the
        // NFC sheet animating out and imposes an inter-session cooldown AFTER that
        // callback, with no event that signals "ready for the next session". So a
        // cooldown floor is unavoidable; it's now anchored to actual teardown
        // (reliable) rather than a blind guess timed from the invalidate() call.
        await settle(Self.interSessionCooldown)

        setStep(.test, "Testing enforcement. Keep the same tag on the phone…")
        switch await strategy.probe() {
        case .failedTerminal(let failure):
            fail(failure.message, failure.diagnostics)

        case .doneInSession(let summary):
            // The removal already ran INSIDE the probe session: a clean raw-write
            // refusal (or an accepting clone) leaves the session alive, so the probe
            // authenticates and disables there — no separate remove tap. Land step
            // 3's checkmark for a beat anyway so the tracker reflects all three.
            completedSteps.insert(.test)
            await finishClean(summary)

        case .needsCleanup(let outcome):
            completedSteps.insert(.test)
            // A refused write can tear the probe session down abnormally; its
            // `invalidate` returns once that teardown completes, then the same
            // iOS inter-session cooldown applies before the remove session can open.
            // `runDisableWithRetry` is a further backstop if the cooldown varies.
            setStep(.remove, "Removing protection. Hold the tag flat on the phone…")
            await settle(Self.interSessionCooldown)
            switch await runDisableWithRetry() {
            case .done(true):
                await finishClean(strategy.summary(outcome: outcome, clean: true))

            case .done(false):
                fail("Tag still reports protection after removal. Clear it before finishing.",
                     "readProtectionState still reports protected; uid=\(strategy.expectedUID.hexString)")

            case .failed(let message, let diagnostics):
                fail(message, diagnostics)
            }
        }
    }

    /// iOS inter-session cooldown floor. `invalidate` now waits for *real* teardown
    /// (the `didInvalidateWithError` event), but iOS still needs a beat after that
    /// before it will open a new reader session, and exposes no "ready" event — so
    /// this fixed floor is unavoidable. Anchored to actual teardown, so it's a
    /// reliable floor rather than a race guess. Reused as the retry backoff.
    private static let interSessionCooldown: Double = 2.5

    private func settle(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    // MARK: - Stage: disable (guaranteed cleanup / escape)

    /// Remove protection, retrying on transient session errors. Even with the
    /// teardown wait + cooldown, iOS can occasionally still report a fresh session
    /// as "terminated unexpectedly" (202) right after an abnormal teardown — a
    /// retry is exactly what removing it by hand does. Stops as soon as one clears it.
    private func runDisableWithRetry(attempts: Int = 3) async -> EnforcementDisableResult {
        var last: EnforcementDisableResult = .failed("Protection removal not attempted.", "")
        for attempt in 1 ... attempts {
            if attempt > 1 {
                statusDetail = "Retrying protection removal (\(attempt)/\(attempts))…"
                pulse &+= 1
                await settle(Self.interSessionCooldown)
            }
            let result = await strategy.disableOnce()
            if case .done(true) = result {
                return result
            } // keep retrying on .done(false)
            last = result
        }
        return last
    }

    // MARK: - Helpers

    private func fail(_ message: String, _ diagnostics: String) {
        activeStep = nil
        phase = .failed(message: message, diagnostics: diagnostics, canRetry: true)
    }
}
#endif
