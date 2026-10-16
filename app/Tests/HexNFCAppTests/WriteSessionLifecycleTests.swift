import Foundation
@testable import HexNFCApp
@testable import HexNFCKit
@testable import HexNFCRecords
import HexNFCStorage
@testable import HexNFCTagSim
import XCTest

/// The second session after every successful write, and the close that came
/// before the system sheet had gone (bench 2026-09-19, finding 26).
///
/// On a real iPhone, each successful editor write was followed by a new reader
/// session (218 ms later on the one unfiltered capture), which iOS queued behind
/// the success tick and then refused with error 202. Two defects combined.
/// `WriteSheet` attached `.task` and `onDisappear` inside `hexWriteBurst`, which
/// rebuilds what it wraps when the burst starts, so the rebuild reset the
/// finished model to `.ready` and began it again. And the finished run, still
/// waiting out its own teardown, then cleared `currentSession`, so the `reset()`
/// that closed the sheet had nothing to invalidate and the new session stayed
/// queued until iOS killed it.
@MainActor
final class WriteSessionLifecycleTests: XCTestCase {
    private let records: [NDEFRecord] = [.uri(URIRecord(uri: "https://hex.pro"))]

    // MARK: - The second session

    /// The device sequence, driven through the model: a write finishes and
    /// waits on its teardown, a reset and a new run land inside that wait, and
    /// the finished run must not forget the new run's session when it resumes.
    func test_aFinishedRunDoesNotForgetTheSessionOfTheRunAfterIt() async {
        let chip = NTAG215Simulator()
        let finished = HoldingSession(inner: SimulatedSession(chip: chip), holds: [.invalidate])
        let next = HoldingSession(inner: SimulatedSession(chip: chip), holds: [.start])
        let factory = StagedFactory(sessions: [finished, next])
        let model = WriteFlowModel(
            factory: factory, dataArea: .replace(records), credentials: InMemoryTagCredentialStore(),
            uidConfirmation: .required
        )

        let first = Task { await model.begin() }
        await until { model.phase == .done && finished.isWaiting }

        // The rebuild: `onDisappear` then `.task`, while the write is still
        // tearing its session down.
        model.reset()
        let second = Task { await model.begin() }
        await until { next.isWaiting }

        // The finished run resumes and ends its own session.
        finished.release()
        await first.value

        // Closing the sheet has to reach the session the second run opened.
        model.reset()
        await until { next.wasInvalidated }

        // Which, as on CoreNFC, then ends in a cancel. The run it belonged to was
        // cancelled first, so it ends quietly rather than on an error card.
        next.release()
        await second.value
        XCTAssertEqual(factory.sessionsStarted, 2, "the stale run must not open a third")
        XCTAssertEqual(model.phase, .ready, "and a cancelled run leaves nothing behind a dismissed sheet")
    }

    /// `WriteSheet` is `#if os(iOS)`, so `swift test` on macOS never compiles
    /// it and no test can host it. This reads the source instead, as
    /// `SessionHolderStorageTests` does for `CoreNFCSession`.
    ///
    /// The rule it holds: the two modifiers that own the run are the last two in
    /// `body`. A modifier that swaps branches around what it wraps, or changes
    /// its identity, rebuilds that view, and a rebuild fires `onDisappear` and
    /// `.task` again, which on a finished write is a reset followed by a second
    /// run. Last is the only position no later edit can wrap.
    func test_theWriteSheetsRunHooksAreTheLastModifiersInBody() throws {
        let lines = try Self.writeSheetBody()
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") }
        let hooks: Set = [".task { await model.begin() }", ".onDisappear { model.reset() }"]
        XCTAssertEqual(
            Set(lines.suffix(2)), hooks,
            "WriteSheet.body must end with its two run hooks; it ends with \(lines.suffix(2))"
        )
    }

    // MARK: - Closing after the system sheet

    /// The sheet hands back once the system NFC sheet has gone, and CoreNFC
    /// reports that well after `invalidate` returns. So the wait follows the
    /// teardown report, not the invalidate.
    func test_theSystemSheetWaitFollowsTheTeardownReport() async {
        let chip = NTAG215Simulator()
        let session = HoldingSession(inner: SimulatedSession(chip: chip), holds: [.teardown])
        let model = WriteFlowModel(
            factory: StagedFactory(sessions: [session]), dataArea: .replace(records),
            credentials: InMemoryTagCredentialStore(), uidConfirmation: .required
        )

        let run = Task { await model.begin() }
        await until { model.phase == .done && session.isWaiting }
        let heard = Flag()
        let waiter = Task {
            await model.systemSheetDismissal()
            heard.set()
        }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        XCTAssertFalse(heard.isSet, "the session was invalidated, but its sheet has not been reported gone")

        session.release()
        await until { heard.isSet }
        guard heard.isSet else { return } // already failed; awaiting the waiter would hang
        await waiter.value
        await run.value
        XCTAssertTrue(session.wasInvalidated)
    }

    /// A sheet swiped away before the system sheet goes still hands its reading
    /// back, which the editor relies on. The dismissal resets the model, so the
    /// wait must not be tied to the run token.
    func test_aSheetDismissedEarlyStillHearsTheSystemSheetGo() async {
        let chip = NTAG215Simulator()
        let session = HoldingSession(inner: SimulatedSession(chip: chip), holds: [.teardown])
        let model = WriteFlowModel(
            factory: StagedFactory(sessions: [session]), dataArea: .replace(records),
            credentials: InMemoryTagCredentialStore(), uidConfirmation: .required
        )

        let run = Task { await model.begin() }
        await until { model.phase == .done && session.isWaiting }
        // In that order, as on screen: the sheet's hand-back task is waiting
        // from the moment the write lands, and the swipe comes after.
        let heard = Flag()
        let waiter = Task {
            await model.systemSheetDismissal()
            heard.set()
        }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        model.reset()

        session.release()
        // Bounded, so a wait tied to the run token fails here instead of
        // hanging the suite.
        await until { heard.isSet }
        guard heard.isSet else { return } // already failed; awaiting the waiter would hang
        await waiter.value
        await run.value
        XCTAssertEqual(model.phase, .ready)
    }

    private static func writeSheetBody() throws -> String {
        let url = URL(fileURLWithPath: #filePath) // …/app/Tests/HexNFCAppTests/WriteSessionLifecycleTests.swift
            .deletingLastPathComponent() // …/HexNFCAppTests
            .deletingLastPathComponent() // …/Tests
            .deletingLastPathComponent() // …/app
            .appendingPathComponent("Sources/HexNFCApp/Screens/WriteSheet.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "    var body: some View {\n"))
        let end = try XCTUnwrap(source.range(of: "\n    }\n", range: start.upperBound ..< source.endIndex))
        return String(source[start.upperBound ..< end.lowerBound])
    }
}

/// Hands out the sessions a test staged, in order, and fails loudly past them.
private final class StagedFactory: TagSessionFactory, @unchecked Sendable {
    private var sessions: [TagSession]
    private(set) var sessionsStarted = 0

    init(sessions: [TagSession]) {
        self.sessions = sessions
    }

    func makeSession() -> TagSession {
        sessionsStarted += 1
        guard !sessions.isEmpty else {
            XCTFail("the flow opened more sessions than the test staged")
            return SimulatedSession(chip: NTAG215Simulator())
        }
        return sessions.removeFirst()
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.withLock { value }
    }

    func set() {
        lock.withLock { value = true }
    }
}

/// Holds parts of a session open until the test lets them go.
///
/// `.start` is a session iOS has queued and not yet handed a tag; invalidating
/// it ends in a cancel, as CoreNFC's does. `.invalidate` is a teardown whose
/// report has not arrived by the time `invalidate`'s own wait gives up, which
/// on device is the 2 s safety net in `CoreNFCSession.invalidate(error:)`.
/// `.teardown` is the report itself, which after a successful write CoreNFC
/// gives only once its sheet has gone. Simulated sessions do all three
/// instantly, so none of these windows exists without this.
private final class HoldingSession: TagSession, @unchecked Sendable {
    enum Hold { case start, invalidate, teardown }

    private let inner: TagSession
    private let holds: Set<Hold>
    private let lock = NSLock()
    private var released = false
    private var waiting = false
    private var invalidated = false

    init(inner: TagSession, holds: Set<Hold>) {
        self.inner = inner
        self.holds = holds
    }

    var isWaiting: Bool {
        lock.withLock { waiting }
    }

    var wasInvalidated: Bool {
        lock.withLock { invalidated }
    }

    func release() {
        lock.withLock { released = true }
    }

    func start(alert: String) async throws -> ConnectedTag {
        if holds.contains(.start) {
            await hold()
            if wasInvalidated {
                throw TagError.sessionCancelled(diagnostics: "invalidated while polling")
            }
        }
        return try await inner.start(alert: alert)
    }

    func updateAlert(_ alert: String) async {
        await inner.updateAlert(alert)
    }

    func invalidate(error: String?) async {
        lock.withLock { invalidated = true }
        if holds.contains(.invalidate) {
            await hold()
        }
        await inner.invalidate(error: error)
    }

    func awaitTeardown(timeout _: Duration) async {
        if holds.contains(.teardown) {
            await hold()
        }
    }

    private func hold() async {
        lock.withLock { waiting = true }
        while !lock.withLock({ released }) {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}
