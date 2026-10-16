@testable import HexNFCKit
import XCTest

/// The iOS inter-session cooldown floor.
///
/// `invalidate` already waits for real teardown, which killed the race where a
/// half-dead session dropped the next tag. What it can't cover is the opaque
/// window *after* teardown, which iOS signals with no event, so every
/// back-to-back flow needs a floor anchored to the last teardown. It used to
/// exist only in the DEBUG harness, which meant the shipping retry paths (scan
/// retry, the unlock re-tap, the passport re-tap, write retry) re-polled
/// immediately and could hit a dropped tag or error 202.
final class NFCSessionClockTests: XCTestCase {
    override func setUp() {
        super.setUp()
        NFCSessionClock.reset()
    }

    override func tearDown() {
        NFCSessionClock.reset()
        super.tearDown()
    }

    /// The first session of a launch has nothing to wait for. If this ever
    /// regressed, every cold scan would gain a needless multi-second stall.
    func test_noTeardownYet_returnsImmediately() async {
        let start = ContinuousClock.now
        await NFCSessionClock.awaitCooldown()
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(100))
    }

    /// After a teardown, the next session waits, and waits roughly the proven
    /// figure, not a token pause.
    func test_afterATeardown_waitsOutTheCooldown() async {
        NFCSessionClock.recordTeardown()
        let start = ContinuousClock.now
        await NFCSessionClock.awaitCooldown()
        let waited = start.duration(to: .now)
        XCTAssertGreaterThan(
            waited, NFCSessionTiming.interSessionCooldown - .milliseconds(150),
            "the floor must actually be honoured, not rounded away"
        )
        XCTAssertLessThan(waited, NFCSessionTiming.interSessionCooldown + .seconds(1))
    }

    /// Anchored to the teardown instant, so real elapsed time counts against it.
    /// This is why a flow with a human step in it (typing a password, entering
    /// an MRZ) pays nothing: the wait is already over by the time it re-polls.
    func test_timeAlreadyElapsed_countsAgainstTheFloor() async {
        NFCSessionClock.recordTeardown()
        try? await Task.sleep(for: NFCSessionTiming.interSessionCooldown + .milliseconds(50))
        let start = ContinuousClock.now
        await NFCSessionClock.awaitCooldown()
        XCTAssertLessThan(
            start.duration(to: .now), .milliseconds(100),
            "a wait already served must not be served twice"
        )
    }
}
