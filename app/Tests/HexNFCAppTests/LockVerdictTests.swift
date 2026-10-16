@testable import HexNFCApp
@testable import HexNFCKit
@testable import HexNFCRecords
import HexNFCStorage
@testable import HexNFCTagSim
import XCTest

/// "An ACK is not proof, and the proof must ship", applied to the *verdict* the
/// user reads, not just to whether the app throws.
///
/// `.permanentLock` verifies behaviourally on chips that latch immediately, and
/// cannot on MIFARE Ultralight C, whose lock bytes are "valid upon the next REQA
/// or WUPA" (MF0ICU2 rev 3.3 §7.5.3). Before this, both outcomes printed the
/// same "Tag permanently locked.", one earned and one asserted, about the single
/// most irreversible operation in the app.
final class LockVerdictTests: XCTestCase {
    /// A chip that latches immediately (NTAG21x, MF0ULX1 §8.5.2) is probed, so
    /// the verdict is earned and says so.
    @MainActor
    func test_permanentLock_onAnImmediateLatchChip_reportsVerified() async {
        let simulator = NTAG215Simulator()
        let model = OperationsFlowModel(
            factory: ChipFactory(chip: simulator),
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

        guard case .done(.permanentlyLocked(verified: true)) = model.phase else {
            return XCTFail("expected a verified lock, got \(model.phase)")
        }
        XCTAssertTrue(simulator.isLockedPermanent)
    }

    /// Ultralight C cannot be judged this tap. The operation still succeeds: the
    /// lock bytes are written and the tag really is locked. But the summary must
    /// not claim a proof the datasheet says is impossible to obtain in-session.
    @MainActor
    func test_permanentLock_onUltralightC_succeedsButReportsUnverified() async {
        let simulator = MifareUltralightCSimulator()
        let model = OperationsFlowModel(
            factory: ChipFactory(chip: simulator),
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

        guard case .done(.permanentlyLocked(verified: false)) = model.phase else {
            return XCTFail(
                "Ultralight C latches at the next REQA/WUPA, so this tap must not claim a verified lock. Got \(model.phase)"
            )
        }
        XCTAssertTrue(simulator.isLockedPermanent, "the lock itself must still have been written")
    }
}

@MainActor
private func until(timeout: Duration = .milliseconds(500), _ predicate: @MainActor () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if predicate() {
            return
        }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }
}

private final class ChipFactory: TagSessionFactory, @unchecked Sendable {
    let chip: ChipSimulator
    init(chip: ChipSimulator) {
        self.chip = chip
    }

    func makeSession() -> TagSession {
        SimulatedSession(chip: chip)
    }
}
