@testable import HexNFCApp
@testable import HexNFCKit
@testable import HexNFCTagSim
import XCTest

// Session-counting test doubles, shared by the two typed-UID gates.
//
// They were written file-private for `ConfirmationGateTests` when Operations
// was the only flow with a gate. `WriteFlowModel` has one now, and the question
// both suites ask is the same: how many sessions did this take, and was one
// open while the user was typing. A copy per suite is how two answers to that
// question drift apart.
//
// The alert each session was opened with is recorded too, because a two-tap
// flow says something different on each tap and nothing else can see it: the
// string goes to `session.start` and no further.

/// Counts sessions so a test can assert *when* the NFC sheet is up, not just
/// what the flow ended up doing.
final class RecordingFactory: TagSessionFactory, @unchecked Sendable {
    let chip: ChipSimulator
    private(set) var sessionsStarted = 0
    private(set) var sessionsInvalidated = 0
    /// One entry per `start(alert:)`, in order.
    private(set) var alerts: [String] = []

    init(chip: ChipSimulator) {
        self.chip = chip
    }

    func makeSession() -> TagSession {
        sessionsStarted += 1
        return CountingSession(
            inner: SimulatedSession(chip: chip),
            onStart: { [weak self] alert in self?.alerts.append(alert) },
            onInvalidate: { [weak self] in self?.sessionsInvalidated += 1 }
        )
    }
}

/// Hands out a different chip per session, to model the user presenting the
/// wrong tag on a later tap.
///
/// The fallback is deliberately loud. A flow that opens more sessions than the
/// test staged chips for is a flow the test has stopped describing, and a silent
/// fresh `NTAG215Simulator` would let that pass as a green run.
final class SwappingFactory: TagSessionFactory, @unchecked Sendable {
    private var chips: [ChipSimulator]
    private(set) var sessionsStarted = 0
    private let onExhausted: () -> Void

    init(chips: [ChipSimulator], onExhausted: @escaping () -> Void = {}) {
        self.chips = chips
        self.onExhausted = onExhausted
    }

    func makeSession() -> TagSession {
        sessionsStarted += 1
        guard !chips.isEmpty else {
            onExhausted()
            return SimulatedSession(chip: NTAG215Simulator())
        }
        return SimulatedSession(chip: chips.removeFirst())
    }
}

final class CountingSession: TagSession, @unchecked Sendable {
    private let inner: TagSession
    private let onStart: @Sendable (String) -> Void
    private let onInvalidate: @Sendable () -> Void
    private var counted = false

    init(
        inner: TagSession,
        onStart: @escaping @Sendable (String) -> Void = { _ in },
        onInvalidate: @escaping @Sendable () -> Void
    ) {
        self.inner = inner
        self.onStart = onStart
        self.onInvalidate = onInvalidate
    }

    func start(alert: String) async throws -> ConnectedTag {
        onStart(alert)
        return try await inner.start(alert: alert)
    }

    func updateAlert(_ alert: String) async {
        await inner.updateAlert(alert)
    }

    func invalidate(error: String?) async {
        await inner.invalidate(error: error)
        guard !counted else { return } // idempotent, like the real session
        counted = true
        onInvalidate()
    }
}

/// Holds `start(alert:)` open until the test lets it go, so a cancel can land
/// while a tap is genuinely in flight. Two windows, chosen per test:
///
/// - The cooldown (the default). `currentSession?.invalidate()` does nothing
///   until CoreNFC has created the session, which it does only after the
///   inter-session cooldown, so the tag still arrives and the run token checked
///   after `start` returns is what stops the run.
/// - Polling (`cancelsOnInvalidate`). The reader session exists, so invalidating
///   it ends `start` in a cancel, as CoreNFC's does, and the stale-run guard in
///   the catch is what keeps the error card off a dismissed sheet.
///
/// A simulated session returns instantly, so without this neither window can be
/// reproduced at all.
final class BlockingFactory: TagSessionFactory, @unchecked Sendable {
    let chip: ChipSimulator
    private(set) var sessionsStarted = 0
    private let cancelsOnInvalidate: Bool
    private let lock = NSLock()
    private var waiting = false
    private var released = false
    private var made: [BlockingSession] = []

    init(chip: ChipSimulator, cancelsOnInvalidate: Bool = false) {
        self.chip = chip
        self.cancelsOnInvalidate = cancelsOnInvalidate
    }

    var isWaiting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return waiting
    }

    func release() {
        lock.lock()
        released = true
        lock.unlock()
    }

    /// Whether anything has invalidated a session this factory handed out.
    var anySessionInvalidated: Bool {
        made.contains { $0.wasInvalidated }
    }

    private func markWaiting() {
        lock.lock()
        waiting = true
        lock.unlock()
    }

    private func isReleased() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return released
    }

    func makeSession() -> TagSession {
        sessionsStarted += 1
        let session = BlockingSession(
            inner: SimulatedSession(chip: chip),
            cancelsOnInvalidate: cancelsOnInvalidate,
            onWait: { [weak self] in self?.markWaiting() },
            isReleased: { [weak self] in self?.isReleased() ?? true }
        )
        made.append(session)
        return session
    }
}

private final class BlockingSession: TagSession, @unchecked Sendable {
    private let inner: TagSession
    private let cancelsOnInvalidate: Bool
    private let onWait: @Sendable () -> Void
    private let isReleased: @Sendable () -> Bool
    private let lock = NSLock()
    private var invalidated = false

    init(
        inner: TagSession,
        cancelsOnInvalidate: Bool,
        onWait: @escaping @Sendable () -> Void,
        isReleased: @escaping @Sendable () -> Bool
    ) {
        self.inner = inner
        self.cancelsOnInvalidate = cancelsOnInvalidate
        self.onWait = onWait
        self.isReleased = isReleased
    }

    var wasInvalidated: Bool {
        lock.withLock { invalidated }
    }

    func start(alert: String) async throws -> ConnectedTag {
        onWait()
        while !isReleased() {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        // As CoreNFC does once the reader session exists: invalidated before
        // it found a tag, it ends in a cancel and does not go on to hand one up.
        if cancelsOnInvalidate, wasInvalidated {
            throw TagError.sessionCancelled(diagnostics: "invalidated while polling")
        }
        return try await inner.start(alert: alert)
    }

    func updateAlert(_ alert: String) async {
        await inner.updateAlert(alert)
    }

    func invalidate(error: String?) async {
        lock.withLock { invalidated = true }
        await inner.invalidate(error: error)
    }
}

/// Poll until `condition` holds, or fail the test.
///
/// A gated `begin()` suspends on a continuation until something confirms it, so
/// a test has to drive it from another task and wait for the phase rather than
/// awaiting the call. The timeout is the difference between a failing assertion
/// and a hung suite.
@MainActor
func until(
    timeout: TimeInterval = 2,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertTrue(condition(), "condition never held within \(timeout)s", file: file, line: line)
}

/// Wait for a write flow to reach a phase that is waiting on the user, so a run
/// that fails before the gate fails its own assertion instead of spinning to the
/// timeout and then calling a `confirm()` that does nothing.
/// `after` is the `transitionCount` the run started from, and it is load-bearing
/// on the unlock leg: a flow already sitting in `.needsUnlock` when
/// `unlock(with:)` is called satisfies "settled" before the new run has moved at
/// all, and the caller would then confirm nothing and await a task that never
/// finishes.
@MainActor
func untilSettled(
    _ model: WriteFlowModel,
    after transitionCount: Int? = nil,
    timeout: TimeInterval = 2,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    await until(timeout: timeout, file: file, line: line) {
        if let transitionCount, model.transitionCount <= transitionCount {
            return false
        }
        switch model.phase {
        case .awaitingConfirmation, .needsUnlock, .done, .error: return true
        default: return false
        }
    }
}

/// Run a write to completion, confirming the UID gate if it appears.
///
/// A gated `begin()` suspends on a continuation until something confirms it, so
/// a test that simply awaits it hangs rather than fails. Tests whose subject is
/// the write, not the gate, drive it through here; the ones whose subject is the
/// gate drive the task themselves and assert on what is open in between.
@MainActor
func beginConfirmingUID(
    _ model: WriteFlowModel,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let before = model.transitionCount
    let run = Task { await model.begin() }
    await untilSettled(model, after: before, file: file, line: line)
    if case .awaitingConfirmation = model.phase {
        model.confirm()
    }
    await run.value
}

/// Run a write that must *not* reach the UID gate: the mirror of
/// `beginConfirmingUID`, and what the exempt half of the Library differential
/// pair needs.
///
/// Written inline, a regression that wrongly gates such a run is a hang rather
/// than a failure: `waitForConfirmation()` has no deadline and `swift test`
/// applies no per-test timeout. The `reset()` is load-bearing too, because
/// `XCTFail` alone would leave `begin()` suspended and the `await` below would
/// hang on the failure it had just reported.
@MainActor
func beginExpectingNoGate(
    _ model: WriteFlowModel,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let before = model.transitionCount
    let run = Task { await model.begin() }
    await untilSettled(model, after: before, file: file, line: line)
    if case .awaitingConfirmation = model.phase {
        XCTFail("this write must not ask for the tag's UID", file: file, line: line)
        model.reset()
    }
    await run.value
}

/// The same, for the unlock leg: `unlock(with:)` awaits `begin()`, so on a gated
/// write it also spans the gate.
@MainActor
func unlockConfirmingUID(
    _ model: WriteFlowModel,
    with credential: TagCredential,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let before = model.transitionCount
    let run = Task { await model.unlock(with: credential) }
    await untilSettled(model, after: before, file: file, line: line)
    if case .awaitingConfirmation = model.phase {
        model.confirm()
    }
    await run.value
}
