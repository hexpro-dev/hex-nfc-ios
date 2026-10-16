import Foundation
import HexNFCKit

/// Executes a `TagTestPlan` against *any* `TagSessionFactory`. The same code
/// path drives the live in-app harness (over `CoreNFCSession`) and the
/// anti-drift XCTest (over `SimulatedSession`). Fail-fast on the first failing
/// step, but cleanup always runs, and the tag is verified unprotected
/// afterwards.
///
/// Cleanup obeys `Options.includeSafety` exactly as the suite does, so a
/// read-only run issues no writes from either phase.
///
/// ## Taps
///
/// A step declares which activation it needs (`TagTestStep.tap`). The runner
/// opens one session per tap, in order, over the same tag. That is not a
/// convenience: AUTH0 latches at the next activation, a refused `PWD_AUTH`
/// halts a Type-2 chip for the rest of the current one, and "what credential
/// does this tag hold now?" is therefore a question with exactly one answer per
/// tap. A single-session runner cannot ask it at all, which is why the harness
/// could not have caught the 2026-09-04 credential desync.
///
/// **The wait between taps is anchored to real teardown, not to the call that
/// asked for it.** `TagSession.invalidate` already awaits CoreNFC's
/// `didInvalidateWithError`, and `NFCSessionClock` records the moment that
/// landed; the next `CoreNFCSession.start` then waits out the opaque
/// inter-session cooldown measured from *that* instant. The runner calls
/// `NFCSessionClock.awaitCooldown()` between taps so the guarantee holds
/// whatever session type it was handed. A simulated session records no
/// teardown, so it waits for nothing and CI stays instant.
public final class TagTestRunner: @unchecked Sendable {
    public struct Options: Sendable {
        /// Which safety tiers to run. The batch never includes `.irreversible`
        /// (enforced by the initializer's precondition).
        public var includeSafety: Set<TagTestStep.SafetyLevel>
        /// Stop the suite at the first failing step (remaining steps are marked
        /// skipped). Cleanup still runs.
        public var stopOnFirstFailure: Bool
        /// The initial NFC-sheet alert.
        public var alert: String
        /// Hard ceiling on taps. A step needing a tap past this is **skipped
        /// with a stated reason** rather than dropped, so the console still
        /// shows it exists.
        ///
        /// Cleanup obeys it too, and tidies up inside the last tap it has rather
        /// than declining to run: a run capped at one tap that then refused to
        /// clean up would strand the tag it was capped to protect.
        ///
        /// A read-only identity capture on a one-of-a-kind tag sets this to 1.
        public var maximumTaps: Int
        /// How many times a tap may be asked for again after the wrong tag was
        /// presented.
        public var wrongTagRetries: Int

        public init(
            includeSafety: Set<TagTestStep.SafetyLevel> = [.readOnly, .reversibleWrite],
            stopOnFirstFailure: Bool = true,
            alert: String = "Hold the tag against the top of your iPhone",
            maximumTaps: Int = .max,
            wrongTagRetries: Int = 1
        ) {
            self.includeSafety = includeSafety
            self.stopOnFirstFailure = stopOnFirstFailure
            self.alert = alert
            self.maximumTaps = maximumTaps
            self.wrongTagRetries = wrongTagRetries
        }
    }

    private let plan: TagTestPlan
    private let options: Options

    public init(plan: TagTestPlan, options: Options = .init()) {
        precondition(
            !options.includeSafety.contains(.irreversible),
            "Irreversible steps run only via the gated one-at-a-time flow, never the batch runner."
        )
        self.plan = plan
        self.options = options
    }

    // MARK: - Entry points

    /// Live path: stream progress + per-step results as they happen.
    public func stream(using factory: any TagSessionFactory) -> AsyncStream<TagTestEvent> {
        AsyncStream { continuation in
            let task = Task {
                await self.execute(using: factory) { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// XCTest path: run to completion and return the report.
    @discardableResult
    public func run(using factory: any TagSessionFactory) async -> TagTestReport {
        var captured: TagTestReport?
        await execute(using: factory) { event in
            if case .finished(let report) = event {
                captured = report
            }
        }
        // `execute` always emits `.finished`, so this is never nil.
        return captured ?? TagTestReport(
            profile: plan.profile, uid: Data(), results: [], cleanupResults: [],
            cleanupLeftTagProtected: false, tapCount: 0, plannedTaps: 1
        )
    }

    /// Single-session path, kept for the callers that hand over one session.
    ///
    /// A plan whose steps all sit in tap 0 behaves exactly as it always has.
    /// Anything needing a later tap is **skipped with a reason naming the fix**,
    /// and the run is capped at one tap so it never goes looking for a second
    /// activation it cannot have. One session cannot be re-opened, and a
    /// cross-tap assertion run inside a torn-down one would report a verdict it
    /// never established. `plannedTaps` still counts what the plan needed, so
    /// such a run cannot record a clean pass.
    public func stream(using session: any TagSession) -> AsyncStream<TagTestEvent> {
        singleSessionRunner().stream(using: OneShotSessionFactory(session))
    }

    /// Single-session path. See `stream(using session:)`.
    @discardableResult
    public func run(using session: any TagSession) async -> TagTestReport {
        await singleSessionRunner().run(using: OneShotSessionFactory(session))
    }

    private func singleSessionRunner() -> TagTestRunner {
        var capped = options
        capped.maximumTaps = 1
        return TagTestRunner(plan: plan, options: capped)
    }

    // MARK: - Core

    private func execute(using factory: any TagSessionFactory, emit: (TagTestEvent) -> Void) async {
        let effective = plan.steps.filter { options.includeSafety.contains($0.safety) }
        emit(.planResolved(profile: plan.profile, stepCount: effective.count))

        let suiteTaps = Set(effective.map(\.tap)).sorted()
        let cleanupTap = TagTestPlan.cleanupTap(after: effective)
        let budget = max(options.maximumTaps, 1)
        // What the plan needs, NOT what this run is allowed. A run capped below
        // it skipped the cross-tap assertions, and `isCleanPass` has to be able
        // to see that: capping the number would make the shortfall invisible and
        // let a single-session run report a verdict it never established.
        let plannedTaps = cleanupTap + 1

        var results: [TagStepResult] = []
        var context: TagTestContext?
        var open: (session: any TagSession, tag: any ConnectedTag, tap: Int)?
        var tapsOpened = 0
        var halted = false
        // The tag was swapped mid-run. Cleanup cannot run against a tag it
        // cannot identify, and the report may not claim the original one was
        // left unprotected.
        var abandoned = false
        // Did a step marked `endsActivation` actually *run* in the tap that is
        // still open? Only then does cleanup need a fresh activation. Deriving
        // this from the plan instead would send a halted run out to collect two
        // more physical taps to reach a chip that never halted.
        var openTapEndedActivation = false
        var globalIndex = 0

        for tapIndex in suiteTaps {
            let stepsInTap = effective.filter { $0.tap == tapIndex }

            // Why the tap might not be opened at all. Deciding this *before*
            // asking for a session is the point: a halted suite must not stand
            // there demanding two more physical taps just to reach cleanup.
            var skipEveryStep: String?
            if abandoned {
                skipEveryStep = "the run was abandoned after the wrong tag was presented"
            } else if halted {
                skipEveryStep = "suite halted after an earlier failure"
            } else if tapIndex >= budget {
                skipEveryStep = "needs tap \(tapIndex + 1); this run is limited to \(budget) tap(s). "
                    + "Run the plan through a TagSessionFactory to take them all"
            }

            if skipEveryStep == nil, open?.tap != tapIndex {
                emit(.tapStarted(index: tapIndex, of: plannedTaps, uid: context?.uid))
                await close(open?.session, error: nil)
                open = nil
                switch await openTap(tapIndex, of: plannedTaps, using: factory, expecting: context?.uid) {
                case .opened(let session, let tag):
                    open = (session, tag, tapIndex)
                    openTapEndedActivation = false
                    tapsOpened += 1
                    if context == nil {
                        context = TagTestContext(
                            profile: plan.profile, uid: tag.uid, credentials: plan.credentials
                        )
                    }

                case .wrongTag(let failure):
                    results.append(failure)
                    emit(.stepFinished(failure))
                    abandoned = true
                    halted = true
                    skipEveryStep = "the run was abandoned after the wrong tag was presented"

                case .failed(let failure):
                    results.append(failure)
                    emit(.stepFinished(failure))
                    halted = true
                    skipEveryStep = "the session for this tap could not be opened"
                }
            }

            for step in stepsInTap {
                globalIndex += 1
                emit(.stepStarted(
                    id: step.id.rawValue, name: step.name, index: globalIndex, of: effective.count
                ))

                if let reason = skipEveryStep {
                    let result = Self.skip(step, reason: reason)
                    results.append(result)
                    emit(.stepFinished(result))
                    continue
                }
                // Unreachable: every branch that leaves no session open sets
                // `skipEveryStep`. Recorded rather than dropped anyway, because a
                // step that vanishes from the report is a step nobody notices
                // went untested.
                guard let current = open, var ctx = context else {
                    let result = Self.skip(step, reason: "no session was open for this tap")
                    results.append(result)
                    emit(.stepFinished(result))
                    continue
                }

                if halted {
                    let result = Self.skip(step, reason: "suite halted after an earlier failure")
                    results.append(result)
                    emit(.stepFinished(result))
                    continue
                }

                await current.session
                    .updateAlert("Testing \(plan.profile.displayName): \(globalIndex)/\(effective.count)")

                if !current.tag.capabilities.contains(step.requiredCapabilities) {
                    let result = Self.skip(step, reason: "required capability not advertised by this chip")
                    results.append(result)
                    emit(.stepFinished(result))
                    continue
                }

                let result = await run(step: step, on: current.tag, ctx: &ctx)
                context = ctx
                results.append(result)
                emit(.stepFinished(result))
                if step.endsActivation {
                    openTapEndedActivation = true
                }
                if result.status == .failed, options.stopOnFirstFailure {
                    halted = true
                }
            }
        }

        emit(.suiteFinished(passed: !results.contains { $0.status == .failed }))

        // --- Cleanup: always runs, best-effort, never fail-fast. ---
        //
        // Filtered by the same safety tier as the suite. Cleanup steps write
        // (`cleanup.eraseNDEF` erases the tag's message), so running them
        // unfiltered made a read-only pass write anyway — observed erasing a
        // real NDEF message off an ICODE SLIX2 during a run that announced
        // "write steps excluded". A read-only pass must mean read-only end to
        // end, or it is worthless on the one-of-a-kind tags it exists for.
        var cleanupResults: [TagStepResult] = []
        var leftProtected = false

        if !abandoned, tapsOpened > 0 {
            // Cleanup needs a fresh activation when the open one is finished
            // with: a step declared that its last frame ends it, or the suite
            // failed, and on a Type-2 chip a failure is usually a NAK that
            // returned it to HALT. A cleanup step run against a halted chip can
            // do nothing at all, which is how "cleanup always runs" quietly
            // becomes "cleanup always runs and always fails".
            //
            // Always exactly ONE more tap, never every tap the plan declares:
            // a suite that halted in tap 0 must not stand there collecting three
            // physical taps to reach a tidy-up. And never past the run's tap
            // budget, so a single-session run tidies up in the session it has
            // rather than not at all.
            let lastOpened = open?.tap ?? 0
            var target = lastOpened
            if openTapEndedActivation || halted {
                let fresh = lastOpened + 1
                target = fresh <= budget - 1 ? fresh : lastOpened
            }
            if open?.tap != target {
                emit(.tapStarted(index: target, of: plannedTaps, uid: context?.uid))
                await close(open?.session, error: nil)
                open = nil
                switch await openTap(target, of: plannedTaps, using: factory, expecting: context?.uid) {
                case .opened(let session, let tag):
                    open = (session, tag, target)
                    tapsOpened += 1

                case .wrongTag(let failure), .failed(let failure):
                    cleanupResults.append(failure)
                    emit(.cleanupStepFinished(failure))
                }
            }

            if let current = open, var ctx = context {
                emit(.cleanupStarted)
                for step in plan.cleanup where options.includeSafety.contains(step.safety) {
                    let result = await run(step: step, on: current.tag, ctx: &ctx)
                    cleanupResults.append(result)
                    emit(.cleanupStepFinished(result))
                }
                context = ctx
                leftProtected = await probeLeftProtected(tag: current.tag, ctx: ctx)
            } else {
                // Cleanup never reached the tag, so nothing here may claim it was
                // left unprotected. What the suite armed is the best evidence
                // available, and it is the conservative one.
                leftProtected = context?.armedProtection != nil
            }
        } else if abandoned {
            leftProtected = context?.armedProtection != nil
        }

        // `t2.ccVerify` sets this scratch key when it finds page 3 still blank.
        // Absent scratch means the step never ran, which is not the same as a
        // formatted tag, so this stays `nil` rather than defaulting to false.
        let ccBlank = context.map { $0.scratch[TagTestContext.unformattedCCKey] != nil }
        let report = TagTestReport(
            profile: plan.profile, uid: context?.uid ?? Data(),
            results: results, cleanupResults: cleanupResults,
            cleanupLeftTagProtected: leftProtected,
            capabilityContainerIsBlank: ccBlank,
            tapCount: tapsOpened, plannedTaps: plannedTaps
        )
        await close(open?.session, error: report.firstFailure?.name)
        emit(.finished(report))
    }

    // MARK: - Taps

    private enum TapOutcome {
        case opened(any TagSession, any ConnectedTag)
        case wrongTag(TagStepResult)
        case failed(TagStepResult)
    }

    /// Open one activation, insisting it is the same physical tag the run
    /// started on.
    private func openTap(
        _ index: Int, of total: Int,
        using factory: any TagSessionFactory,
        expecting uid: Data?
    ) async -> TapOutcome {
        // Anchored to the last recorded teardown, never to the moment
        // `invalidate` was called. Free on the first tap of a run, free again in
        // CI (a simulated session records no teardown), and it only bites on the
        // genuine back-to-back re-tap this loop creates.
        await NFCSessionClock.awaitCooldown()

        var attempt = 0
        var alert = index == 0
            ? options.alert
            : "Tap \(index + 1) of \(total). Hold the SAME tag against the top of your iPhone."
        while true {
            let session = factory.makeSession()
            do {
                let tag = try await session.start(alert: alert)
                guard let uid, tag.uid != uid else {
                    return .opened(session, tag)
                }
                await close(session, error: "Wrong tag")
                attempt += 1
                guard attempt <= options.wrongTagRetries else {
                    return .wrongTag(TagStepResult(
                        id: "session.wrongTag", name: "Tap \(index + 1): same tag",
                        safety: .readOnly, status: .failed,
                        detail: "a different tag was presented, so the run was abandoned",
                        error: TagError.unexpected(
                            "tap \(index + 1) saw uid=\(tag.uid.hexString), run started on uid=\(uid.hexString)"
                        )
                    ))
                }
                alert = "Wrong tag. Hold the tag the run started on."
                await NFCSessionClock.awaitCooldown()
            } catch let error as TagError {
                return .failed(Self.startFailure(error, tap: index))
            } catch {
                return .failed(Self.startFailure(
                    TagError.unexpected("session start failed: \(error)"), tap: index
                ))
            }
        }
    }

    private func close(_ session: (any TagSession)?, error: String?) async {
        guard let session else { return }
        // `invalidate` awaits the real CoreNFC teardown callback and records the
        // instant it landed, which is what the next tap's cooldown is measured
        // from. Simulated sessions have nothing to tear down and return at once.
        await session.invalidate(error: error)
    }

    /// The hard post-cleanup invariant: did the run leave the tag protected?
    ///
    /// Only probed when the run permits writes. `readProtectionState` is
    /// read-only for Type-2 and Type-4, but the **Type-5 implementation
    /// writes**: it detects a write gate by writing a data block back its own
    /// bytes. Harmless in content, still a write, so running it unconditionally
    /// punched a hole straight through the read-only pass, on ICODE SLIX, which
    /// is the exact chip that mode exists to protect. A read-only run can't
    /// leave a tag protected anyway (it never armed anything), and it is already
    /// barred from recording a clean pass.
    private func probeLeftProtected(tag: any ConnectedTag, ctx: TagTestContext) async -> Bool {
        guard options.includeSafety.contains(.reversibleWrite) else { return false }
        if let state = try? await tag.readProtectionState() {
            return state.passwordProtect
        }
        // The probe read nothing. On a Type-2 chip that is exactly what a halted
        // chip looks like, and a `try?` collapsing it to `nil` would force this
        // flag false on the one path where it matters. Fall back to the last
        // reading a step took while the tag was still answering.
        if let carried = ctx.scratch[TagTestContext.lastKnownProtectionKey] {
            return carried != Data([0x00])
        }
        return false
    }

    // MARK: - Steps

    /// Run one step, timing it and capturing the `NFCTrace` frames it emitted.
    private func run(step: TagTestStep, on tag: any ConnectedTag, ctx: inout TagTestContext) async -> TagStepResult {
        let before = NFCTrace.shared.snapshot().count
        let start = Date()
        var status: TagStepResult.Status = .passed
        var check: TagStepCheck?
        var thrown: TagError?
        do {
            let outcome = try await step.run(tag, &ctx)
            check = outcome
            status = outcome.satisfied ? .passed : .failed
        } catch let e as TagError {
            thrown = e
            status = .failed
        } catch {
            thrown = TagError.unexpected("\(error)")
            status = .failed
        }
        let ms = max(0, Int(Date().timeIntervalSince(start) * 1000))
        return TagStepResult(
            id: step.id.rawValue, name: step.name, safety: step.safety, status: status,
            detail: check?.detail ?? "", expected: check?.expected, actual: check?.actual,
            error: thrown, frames: Self.framesSince(before), milliseconds: ms
        )
    }

    private static func framesSince(_ before: Int) -> [NFCTrace.Event] {
        let after = NFCTrace.shared.snapshot()
        guard after.count > before else { return [] }
        return Array(after.suffix(after.count - before))
    }

    private static func skip(_ step: TagTestStep, reason: String) -> TagStepResult {
        TagStepResult(id: step.id.rawValue, name: step.name, safety: step.safety,
                      status: .skipped, skipReason: reason)
    }

    private static func startFailure(_ error: TagError, tap: Int) -> TagStepResult {
        TagStepResult(
            id: tap == 0 ? "session.start" : "session.start.tap\(tap)",
            name: tap == 0 ? "Open session" : "Open session for tap \(tap + 1)",
            safety: .readOnly, status: .failed, error: error
        )
    }
}

// MARK: - Single-session compatibility

/// Vends one already-made session, then refuses.
///
/// `TagSessionFactory.makeSession()` cannot throw, so the refusal has to be a
/// session whose `start(alert:)` throws. A factory that returned the same
/// session twice would be worse than useless: the second `start` would hand back
/// a tag over a torn-down session, and the cross-tap step would report a verdict
/// it read from a dead activation.
private struct OneShotSessionFactory: TagSessionFactory {
    private let box: Box

    init(_ session: any TagSession) {
        box = Box(session)
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var session: (any TagSession)?
        init(_ session: any TagSession) {
            self.session = session
        }

        func take() -> (any TagSession)? {
            lock.withLock {
                defer { session = nil }
                return session
            }
        }
    }

    func makeSession() -> TagSession {
        box.take() ?? ExhaustedSession()
    }
}

/// The second session a one-shot factory does not have.
private final class ExhaustedSession: TagSession, @unchecked Sendable {
    func start(alert: String) async throws -> ConnectedTag {
        throw TagError(
            kind: .sessionUnavailable,
            userMessage: "Hold the tag against your iPhone again.",
            diagnostics: "this plan needs another activation, and it was run over a single session. "
                + "Run it through a TagSessionFactory."
        )
    }

    func updateAlert(_ alert: String) async {}

    func invalidate(error: String?) async {}
}
