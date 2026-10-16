@testable import HexNFCApp
@testable import HexNFCKit
@testable import HexNFCRecords
import HexNFCStorage
@testable import HexNFCTagSim
import XCTest

/// The typed-UID gate has to sit *between* two NFC sessions, never inside one.
///
/// The system NFC sheet is modal: while it is up the app behind it takes no
/// touches, so a confirmation field presented during a live session cannot be
/// typed into and the session just runs out. The DEBUG harness had this right
/// from the start (`IrreversibleOpsFlowModel` confirms in-app before opening a
/// session, and `docs/internal/test-harness.md` gives the reason outright); the
/// shipping operations flow connected first and asked second.
final class ConfirmationGateTests: XCTestCase {
    /// The ordering itself: by the time the user is asked to type, the identify
    /// session must already be closed.
    @MainActor
    func test_confirmationIsAskedWithNoSessionOpen() async {
        let chip = NTAG215Simulator()
        let factory = RecordingFactory(chip: chip)
        let model = OperationsFlowModel(factory: factory, operation: .erase, credentials: InMemoryTagCredentialStore())

        let run = Task { await model.begin() }
        await until {
            if case .awaitingConfirmation = model.phase {
                return true
            }
            return false
        }

        XCTAssertEqual(factory.sessionsStarted, 1, "identify should have opened exactly one session")
        XCTAssertEqual(
            factory.sessionsInvalidated, 1,
            "the identify session must be closed before the user is asked to type. The NFC sheet blocks typing"
        )

        model.confirm()
        await run.value
        guard case .done(.erased) = model.phase else {
            return XCTFail("expected the erase to complete on tap 2, got \(model.phase)")
        }
        XCTAssertEqual(factory.sessionsStarted, 2, "the operation itself is the second tap")
    }

    /// A read-only operation needs no gate, so it must stay a single tap.
    @MainActor
    func test_nonConfirmingOperationStaysOneTap() async {
        let factory = RecordingFactory(chip: NTAG215Simulator())
        let model = OperationsFlowModel(
            factory: factory,
            operation: .memoryDump,
            credentials: InMemoryTagCredentialStore()
        )

        await model.begin()

        guard case .done(.memoryDumped) = model.phase else {
            return XCTFail("expected a dump, got \(model.phase)")
        }
        XCTAssertEqual(factory.sessionsStarted, 1, "a memory dump must not ask for the tag twice")
    }

    /// The check the old single-session flow couldn't make: confirming against
    /// one tag must not authorise a destructive write to a different one. Tags
    /// from a single batch have been seen sharing their UID tail, and a stack of
    /// blanks is easy to mix up mid-operation.
    @MainActor
    func test_aDifferentTagOnTapTwoIsRefused() async {
        let first = NTAG215Simulator()
        let second = NTAG213Simulator() // different chip, different UID
        let factory = SwappingFactory(chips: [first, second])
        let model = OperationsFlowModel(
            factory: factory,
            operation: .permanentLock,
            credentials: InMemoryTagCredentialStore()
        )

        let run = Task { await model.begin() }
        await until {
            if case .awaitingConfirmation = model.phase {
                return true
            }
            return false
        }
        model.confirm()
        await run.value

        guard case .error = model.phase else {
            return XCTFail("a swapped tag must not inherit the confirmation, got \(model.phase)")
        }
        XCTAssertFalse(first.isLockedPermanent, "the confirmed tag was never presented again")
        XCTAssertFalse(second.isLockedPermanent, "the substituted tag must not be locked")
    }

    /// Cancelling at the gate must actually stop. `cancel()` used to resume the
    /// waiting continuation and let the run fall straight through into the
    /// operation. It only *looked* cancelled because the invalidated session
    /// made the command fail.
    @MainActor
    func test_cancellingAtTheGateDoesNotRunTheOperation() async {
        let chip = NTAG215Simulator()
        let factory = RecordingFactory(chip: chip)
        let model = OperationsFlowModel(
            factory: factory,
            operation: .permanentLock,
            credentials: InMemoryTagCredentialStore()
        )

        let run = Task { await model.begin() }
        await until {
            if case .awaitingConfirmation = model.phase {
                return true
            }
            return false
        }
        model.cancel()
        await run.value

        XCTAssertFalse(chip.isLockedPermanent, "a cancelled permanent lock must not touch the tag")
        XCTAssertEqual(factory.sessionsStarted, 1, "no second session should ever open")
        guard case .idle = model.phase else {
            return XCTFail("expected .idle after cancelling, got \(model.phase)")
        }
    }

    /// A cancel belongs to the run it cancelled, not to whatever is running when
    /// the suspended run gets around to noticing.
    ///
    /// The outcome travels on the continuation for this reason. With a shared
    /// `isCancelled` flag, a second run starting between `cancel()` and the first
    /// run's check would clear the flag on entry, the first run would read
    /// "not cancelled" and open a session of its own, and an irreversible
    /// operation the user had cancelled would go ahead against whatever tag was
    /// presented next.
    @MainActor
    func test_aCancelledRunStaysCancelledWhenAnotherStartsImmediately() async {
        let chip = NTAG215Simulator()
        let factory = RecordingFactory(chip: chip)
        let model = OperationsFlowModel(
            factory: factory,
            operation: .permanentLock,
            credentials: InMemoryTagCredentialStore()
        )

        let first = Task { await model.begin() }
        await until {
            if case .awaitingConfirmation = model.phase {
                return true
            }
            return false
        }

        // Cancel and restart without giving the first run a chance to resume.
        model.cancel()
        let second = Task { await model.begin() }
        await until {
            if case .awaitingConfirmation = model.phase {
                return true
            }
            return false
        }

        model.cancel()
        await first.value
        await second.value

        XCTAssertEqual(
            factory.sessionsStarted, 2,
            "two identify taps and nothing else. A third session means the cancelled run resumed into its operation"
        )
        XCTAssertFalse(chip.isLockedPermanent, "neither cancelled run may touch the tag")
    }

    /// A failed run has to be recoverable in place. Two taps means twice the
    /// chances to cancel the system sheet or let it time out, and the screen
    /// only ever called `begin()` once, so an error stranded it until the user
    /// navigated away and came back.
    @MainActor
    func test_retryAfterAFailureRunsTheWholeFlowAgain() async {
        let chip = NTAG215Simulator()
        let factory = FailFirstFactory(chip: chip)
        let model = OperationsFlowModel(factory: factory, operation: .erase, credentials: InMemoryTagCredentialStore())

        await model.begin()
        guard case .error = model.phase else {
            return XCTFail("expected the first identify to fail, got \(model.phase)")
        }

        model.retry()
        guard case .idle = model.phase else {
            return XCTFail("retry should return the screen to idle, got \(model.phase)")
        }

        let run = Task { await model.begin() }
        await until {
            if case .awaitingConfirmation = model.phase {
                return true
            }
            return false
        }
        model.confirm()
        await run.value

        guard case .done(.erased) = model.phase else {
            return XCTFail("the retried run should complete, got \(model.phase)")
        }
    }

    /// Retrying re-identifies rather than resuming at tap 2. Consent must not
    /// survive a failure whose cause we don't know: the tag that comes back may
    /// not be the one that went in.
    @MainActor
    func test_retryReIdentifiesRatherThanResumingAtTapTwo() async {
        let factory = RecordingFactory(chip: NTAG215Simulator())
        let model = OperationsFlowModel(
            factory: factory,
            operation: .permanentLock,
            credentials: InMemoryTagCredentialStore()
        )

        let first = Task { await model.begin() }
        await until {
            if case .awaitingConfirmation = model.phase {
                return true
            }
            return false
        }
        model.cancel()
        await first.value
        XCTAssertEqual(factory.sessionsStarted, 1)

        model.retry()
        let second = Task { await model.begin() }
        await until {
            if case .awaitingConfirmation = model.phase {
                return true
            }
            return false
        }

        XCTAssertEqual(
            factory.sessionsStarted, 2,
            "the second run must identify again, not reuse the earlier confirmation"
        )
        model.cancel()
        await second.value
    }

    /// `retry()` must not be able to yank the state machine out from under a
    /// live session.
    @MainActor
    func test_retryIsIgnoredWhileARunIsInFlight() async {
        let model = OperationsFlowModel(
            factory: RecordingFactory(chip: NTAG215Simulator()),
            operation: .erase,
            credentials: InMemoryTagCredentialStore()
        )
        let run = Task { await model.begin() }
        await until {
            if case .awaitingConfirmation = model.phase {
                return true
            }
            return false
        }

        model.retry()

        guard case .awaitingConfirmation = model.phase else {
            return XCTFail("retry must be a no-op mid-run, got \(model.phase)")
        }
        model.cancel()
        await run.value
    }
}

/// Fails the first session it vends, then behaves normally. Models a cancelled
/// or timed-out first tap.
private final class FailFirstFactory: TagSessionFactory, @unchecked Sendable {
    let chip: ChipSimulator
    private var vended = 0
    init(chip: ChipSimulator) {
        self.chip = chip
    }

    func makeSession() -> TagSession {
        vended += 1
        return vended == 1
            ? SimulatedSession(chip: chip, behaviour: .tagLost)
            : SimulatedSession(chip: chip)
    }
}

@MainActor
private func until(timeout: Duration = .seconds(2), _ predicate: @MainActor () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if predicate() {
            return
        }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }
}
