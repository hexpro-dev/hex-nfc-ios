#if DEBUG
@testable import HexNFCApp
import HexNFCKit
import HexNFCTagSim
import HexNFCTestKit
import XCTest

/// Covers the enforcement verifiers, which had **no tests at all** until a live
/// NTAG216 run on 2026-08-07 showed `Type2EnforcementStrategy` talking to a
/// halted tag.
///
/// The bug: the probe writes to a protected page expecting a refusal, and a
/// refusal returns a Type-2 tag to HALT (ISO/IEC 14443-3). The strategy then
/// authenticated and disabled in the same activation. Both frames died with
/// "Tag connection lost", and the run recorded a failed password handshake for
/// a tag that was enforcing perfectly.
///
/// That was the third instance of the same mistake, after `ulc.identify` and
/// `lockSignature`.
///
/// **What these tests can and cannot see.** `SimulatedSession` calls the
/// simulator's methods directly instead of replaying frames, so the HALT never
/// reaches it and a frame-level assertion is impossible from here — the same
/// structural gap that hid the permanent-lock payload bug. What is observable is
/// the *branch taken*: whether the probe finishes in-session or hands cleanup to
/// a fresh one. That is exactly the decision the bug got wrong.
@MainActor
final class EnforcementStrategyTests: XCTestCase {
    /// Each `makeSession()` is a fresh tap, so it clears the HALT the way real
    /// anticollision does. `TapFactory` in IrreversibleOpsTests only does this
    /// for ISO 15693.
    private final class RetapFactory: TagSessionFactory, @unchecked Sendable {
        let chip: NTAG21xSimulator
        /// Model a tag that stores AUTH0 but never acts on it — the clone
        /// behaviour the verifier exists to detect — by starting every session
        /// already authenticated, so the gate refuses nothing.
        let neverEnforces: Bool
        private(set) var tapCount = 0

        init(chip: NTAG21xSimulator, neverEnforces: Bool = false) {
            self.chip = chip
            self.neverEnforces = neverEnforces
        }

        func makeSession() -> TagSession {
            tapCount += 1
            let session = SimulatedSession(chip: chip)
            guard neverEnforces else { return session }
            return PreAuthenticatedSession(inner: session, chip: chip)
        }
    }

    /// Authenticates *after* the activation begins rather than before it.
    ///
    /// This used to authenticate in `makeSession()`, which worked only because
    /// the simulator carried authentication across sessions. It does not any
    /// more (a real tag is re-selected unauthenticated at every tap), so the
    /// clone has to be modelled inside the activation it applies to.
    private final class PreAuthenticatedSession: TagSession, @unchecked Sendable {
        private let inner: TagSession
        private let chip: NTAG21xSimulator

        init(inner: TagSession, chip: NTAG21xSimulator) {
            self.inner = inner
            self.chip = chip
        }

        func start(alert: String) async throws -> ConnectedTag {
            let tag = try await inner.start(alert: alert)
            _ = try? chip.authenticate(password: TagTestCredentials().type2Password)
            return tag
        }

        func updateAlert(_ alert: String) async {
            await inner.updateAlert(alert)
        }

        func invalidate(error: String?) async {
            await inner.invalidate(error: error)
        }
    }

    private func makeStrategy(
        _ sim: NTAG21xSimulator, neverEnforces: Bool = false
    ) throws -> Type2EnforcementStrategy {
        let profile = try XCTUnwrap(sim.profile)
        return Type2EnforcementStrategy(
            factory: RetapFactory(chip: sim, neverEnforces: neverEnforces),
            profile: profile,
            expectedUID: sim.uid,
            credentials: TagTestCredentials()
        )
    }

    /// The regression. After a refusal the probe must hand cleanup to a fresh
    /// session rather than authenticating in an activation that has ended.
    func test_probe_handsCleanupToAFreshSession_whenTheWriteIsRefused() async throws {
        let sim = NTAG216Simulator()
        let strategy = try makeStrategy(sim)
        try await strategy.arm()

        let result = await strategy.probe()
        guard case .needsCleanup(let outcome) = result else {
            return XCTFail("expected needsCleanup after a refusal, got \(result)")
        }
        XCTAssertEqual(outcome, .enforced)
        XCTAssertEqual(
            try sim.readProtectionState()?.passwordProtect, true,
            "the probe must not attempt an in-session disable after the refusal"
        )
    }

    /// An accepted write never halts the tag, so that path legitimately keeps
    /// going. Without this, "always assume the session is dead" would look
    /// correct and would cost a needless extra tap on every clone.
    func test_probe_finishesInSession_whenTheWriteIsAccepted() async throws {
        let sim = NTAG216Simulator()
        let strategy = try makeStrategy(sim, neverEnforces: true)
        try await strategy.arm()

        let result = await strategy.probe()
        guard case .doneInSession(let summary) = result else {
            return XCTFail("expected the session to survive an accepted write, got \(result)")
        }
        XCTAssertTrue(summary.contains("NOT enforced"), summary)
        XCTAssertEqual(try sim.readProtectionState()?.passwordProtect, false)
    }

    /// The verdict has to be right and the tag must not be left protected — the
    /// invariant the whole harness rests on.
    func test_armProbeRemove_leavesTheTagClean() async throws {
        let sim = NTAG216Simulator()
        let strategy = try makeStrategy(sim)

        try await strategy.arm()
        XCTAssertEqual(
            try sim.readProtectionState()?.passwordProtect, true,
            "arm must leave the tag protected"
        )

        _ = await strategy.probe()
        let removal = await strategy.disableOnce()
        guard case .done(let clean) = removal else {
            return XCTFail("expected the removal session to complete, got \(removal)")
        }
        XCTAssertTrue(clean, "the tag must verify unprotected after removal")
        XCTAssertEqual(try sim.readProtectionState()?.passwordProtect, false)
    }
}
#endif
