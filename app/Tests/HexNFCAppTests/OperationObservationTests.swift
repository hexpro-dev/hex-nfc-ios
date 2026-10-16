@testable import HexNFCApp
@testable import HexNFCKit
@testable import HexNFCRecords
import HexNFCStorage
@testable import HexNFCTagSim
import XCTest

/// What an operation is allowed to tell the screen behind it.
///
/// `OperationsFlowModel.observation` is the channel that stops the editor's
/// Protection card showing a state the tag no longer has. It carries only what a
/// read-back returned, and it carries the UID of the tag the run actually
/// touched, because this sheet runs against whatever tag the user presents and
/// that need not be the one the caller is showing.
final class OperationObservationTests: XCTestCase {
    /// Drive a run to its end, satisfying the typed-UID gate if it gets that
    /// far. A run the identify tap refuses never reaches the gate, and waiting
    /// for one that will not come is a timeout rather than a verdict.
    @MainActor
    private func run(_ model: OperationsFlowModel) async {
        let task = Task { await model.begin() }
        await until {
            switch model.phase {
            case .awaitingConfirmation, .needsUnlock, .done, .error: true
            default: false
            }
        }
        if case .awaitingConfirmation = model.phase {
            model.confirm()
        }
        await task.value
    }

    // MARK: - Permanent lock

    /// The user's own case: a permanent lock on a chip that latches immediately.
    /// The reading has to reach the card, and it has to be about this tag.
    @MainActor
    func test_permanentLock_publishesAProvenLockForTheOperatedTag() async {
        let chip = NTAG213Simulator()
        let model = OperationsFlowModel(
            factory: ChipFactory(chip: chip),
            operation: .permanentLock,
            credentials: InMemoryTagCredentialStore()
        )
        await run(model)

        let observation = try? XCTUnwrap(model.observation)
        XCTAssertEqual(observation?.uid, chip.uid)
        XCTAssertEqual(observation?.lock?.state, .locked)
        XCTAssertNil(observation?.protection, "a lock establishes nothing about a password")
    }

    /// Ultralight C latches at the next REQA/WUPA, so this tap cannot witness
    /// the lock. The card must say "scan again to confirm" and never "locked".
    @MainActor
    func test_permanentLock_onUltralightC_publishesWrittenNotWitnessed() async {
        let chip = MifareUltralightCSimulator()
        let model = OperationsFlowModel(
            factory: ChipFactory(chip: chip),
            operation: .permanentLock,
            credentials: InMemoryTagCredentialStore()
        )
        await run(model)

        XCTAssertEqual(model.observation?.lock?.state, .writtenNotWitnessed)
    }

    /// The half-burn. It arrives as a **thrown** `permanentLockIncomplete`, so a
    /// `.done`-only observer would never see the one outcome the card most needs
    /// to stop being wrong about. The tag here is gated, which is what makes the
    /// dynamic lock write refuse.
    @MainActor
    func test_aRefusedLockPublishesNoBurnRatherThanAFailure() async throws {
        let chip = NTAG213Simulator()
        try chip.enablePasswordProtection(
            password: Data([0xCA, 0xFE, 0xBA, 0xBE]), pack: Data([0x12, 0x34]),
            protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let model = OperationsFlowModel(
            factory: ChipFactory(chip: chip),
            operation: .permanentLock,
            credentials: InMemoryTagCredentialStore()
        )
        await run(model)

        guard case .error = model.phase else {
            return XCTFail("a gated tag must refuse the lock, got \(model.phase)")
        }
        // Refused on the identify tap, so nothing burned, nothing was read, and
        // the user never typed a UID: the card must keep saying exactly what it
        // said before.
        XCTAssertNotEqual(model.observation?.lock?.state, .locked)
        XCTAssertFalse(chip.isLockedPermanent)
    }

    /// A lock that commits and then throws from **verification** rather than from
    /// the lock itself.
    ///
    /// Modelled here as the clone-silicon case `Type2LockDriver` names: the
    /// static lock write is answered with an ACK the chip never acted on, so the
    /// dynamic page really is burned, the behavioural probe finds page 4 still
    /// writable, and `verify` throws `verificationFailed`. That is **not** a
    /// `permanentLockIncomplete`, so a catch that handled only that case dropped
    /// the outcome and left the card saying the tag was untouched, about a tag
    /// whose dynamic lock bits are burned for good.
    @MainActor
    func test_aLockThatThrowsFromVerificationStillPublishesWhatBurned() async throws {
        let chip = NTAG213Simulator()
        let profile = try XCTUnwrap(chip.profile)
        let staticPage = try XCTUnwrap(profile.memoryLayout.lockPages.first)
        let faults = FaultInjectingSessionFactory(chip: chip)
        // An ACK the chip never saw: the driver records the stage as committed,
        // and pages 3 to 15 are in fact still writable.
        faults.arm(TagFault(.write(page: staticPage), .refused(response: Data([0x0A]), halts: false)))
        let model = OperationsFlowModel(
            factory: faults,
            operation: .permanentLock,
            credentials: InMemoryTagCredentialStore()
        )
        await run(model)

        guard case .error = model.phase else {
            return XCTFail("a tag that still accepts writes must fail verification, got \(model.phase)")
        }
        let state = try XCTUnwrap(model.observation?.lock?.state)
        XCTAssertNotEqual(state, .open, "never 'not locked' about a tag whose dynamic bits are burned")
        XCTAssertNotEqual(state, .unknown)
        XCTAssertEqual(model.observation?.lock?.regions[.dynamicLock], .allSet)
    }

    // MARK: - Protection

    @MainActor
    func test_enableProtection_publishesTheStateItReadBack() async {
        let chip = NTAG213Simulator()
        let model = OperationsFlowModel(
            factory: ChipFactory(chip: chip),
            operation: .enableProtection(PendingProtection(
                settings: TagProtection(passwordProtect: true, protectFromPage: 4),
                credential: .type2(password: Data([0xCA, 0xFE, 0xBA, 0xBE]), pack: Data([0x12, 0x34]))
            )),
            credentials: InMemoryTagCredentialStore()
        )
        await run(model)

        XCTAssertEqual(model.observation?.uid, chip.uid)
        XCTAssertEqual(model.observation?.protection?.passwordProtect, true)
        XCTAssertNil(model.observation?.lock, "arming a password establishes nothing about lock bits")
    }

    @MainActor
    func test_disableProtection_publishesTheStateItReadBack() async throws {
        let chip = NTAG213Simulator()
        let password = Data([0xCA, 0xFE, 0xBA, 0xBE])
        try chip.enablePasswordProtection(
            password: password, pack: Data([0x12, 0x34]),
            protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let model = OperationsFlowModel(
            factory: ChipFactory(chip: chip),
            operation: .disableProtection,
            credentials: InMemoryTagCredentialStore()
        )
        model.supplyUnlockCredential(.type2(password: password, pack: Data()))
        await run(model)

        XCTAssertEqual(model.observation?.protection?.passwordProtect, false)
    }

    /// A refusal is a reading, and the identify tap is where both happen.
    ///
    /// Remove password on a tag whose gate tap 1 reads as already open refuses
    /// with "nothing to remove", and until 2026-09-22 it published nothing,
    /// because `publish` was guarded on a UID that is not set until tap 2
    /// connects. So the card that sent the user here, still saying "Password,
    /// write-only" about a tag the app had just read as open, never heard the
    /// one thing that would have corrected it. That card also feeds
    /// `pendingProtection()`, so an editor holding a credential would have
    /// re-armed the tag on the next write.
    @MainActor
    func test_aRefusedRemovalStillPublishesTheGateItRead() async {
        let chip = NTAG213Simulator()
        let model = OperationsFlowModel(
            factory: ChipFactory(chip: chip),
            operation: .disableProtection,
            credentials: InMemoryTagCredentialStore()
        )
        await run(model)

        guard case .error = model.phase else {
            return XCTFail("an open tag has nothing to remove, got \(model.phase)")
        }
        XCTAssertEqual(model.observation?.uid, chip.uid)
        XCTAssertEqual(
            model.observation?.protection?.passwordProtect, false,
            "the refusal's own evidence has to reach the card it contradicts"
        )
    }

    /// The same rule on the operation that reads the most and threw the most
    /// away. An attempt limit on an unarmed tag refuses because the gate is
    /// open, which is a fact about protection the editor wants.
    @MainActor
    func test_aRefusedAttemptLimitStillPublishesTheConfigurationItRead() async {
        let chip = NTAG213Simulator()
        let model = OperationsFlowModel(
            factory: ChipFactory(chip: chip),
            operation: .setAttemptLimit(limit: 3),
            credentials: InMemoryTagCredentialStore()
        )
        await run(model)

        guard case .error = model.phase else {
            return XCTFail("an open gate cannot carry an attempt limit, got \(model.phase)")
        }
        XCTAssertEqual(model.observation?.protection?.passwordProtect, false)
    }

    // MARK: - Erase

    /// The repair route for the tag `UnformattedTagTests` describes: its
    /// Capability Container is fine and its data area begins with a byte no
    /// reader will walk. Erase rewrites that page, and the read-back that
    /// follows is what lets the editor's notice stop standing.
    @MainActor
    func test_eraseRepairsAnUnreadableDataAreaAndPublishesIt() async {
        let chip = NTAG213Simulator()
        chip.pages[4] = Data([0x04, 0x03, 0xA0, 0x0C])
        chip.pages[5] = Data([0x34, 0x03, 0x00, 0xFE])
        let model = OperationsFlowModel(
            factory: ChipFactory(chip: chip),
            operation: .erase,
            credentials: InMemoryTagCredentialStore()
        )
        await run(model)

        guard case .done = model.phase else {
            return XCTFail("erase must repair a data area it can rewrite, got \(model.phase)")
        }
        XCTAssertEqual(model.observation?.ndefReadable, true)
        XCTAssertEqual(model.observation?.uid, chip.uid)
        XCTAssertNil(model.observation?.lock, "an erase establishes nothing about lock bits")
    }

    /// A factory Ultralight C ships with page 3 blank (MF0ICU2 rev 3.3
    /// Table 13). The page write succeeds and the reader's own path refuses the
    /// tag, because there is no Capability Container for it to walk. That used
    /// to fail the whole operation, about a tag whose pages had already been
    /// rewritten.
    ///
    /// It passes now, and it must **not** claim the tag reads: nothing here
    /// established that, and on this tag it is false until a format.
    @MainActor
    func test_erasingATagWithNoCapabilityContainerSucceedsWithoutClaimingItReads() async {
        let chip = MifareUltralightCSimulator()
        let model = OperationsFlowModel(
            factory: ChipFactory(chip: chip),
            operation: .erase,
            credentials: InMemoryTagCredentialStore()
        )
        await run(model)

        guard case .done = model.phase else {
            return XCTFail("the pages were written, so this is not a failed erase, got \(model.phase)")
        }
        XCTAssertNotEqual(
            model.observation?.ndefReadable, true,
            "no reader walked this tag, so nothing may say one did"
        )
    }

    // MARK: - Delivery discipline

    /// A run that fails before it connects must not re-deliver the previous
    /// run's reading to the screen behind it.
    ///
    /// The second run is given an absent tag deliberately. Since 2026-09-22 the
    /// identify tap publishes what it reads, so a second run against a tag that
    /// answers would establish its own reading within milliseconds and this
    /// test could not tell "cleared" from "cleared and then read again". A tag
    /// that never answers establishes nothing, which is the case the rule is
    /// about.
    @MainActor
    func test_beginClearsThePreviousRunsReading() async {
        let chip = NTAG213Simulator()
        let faults = FaultInjectingSessionFactory(chip: chip)
        let model = OperationsFlowModel(
            factory: faults,
            operation: .permanentLock,
            credentials: InMemoryTagCredentialStore()
        )
        await run(model)
        XCTAssertNotNil(model.observation)

        faults.tagLeavesTheField()
        model.retry()
        model.cancel()
        await run(model)

        guard case .error = model.phase else {
            return XCTFail("an absent tag cannot be locked, got \(model.phase)")
        }
        XCTAssertNil(model.observation, "a new run starts having established nothing")
    }

    /// A memory dump reads user memory and nothing about protection or locks, so
    /// it has nothing to say and must say nothing.
    @MainActor
    func test_aPureReadOperationPublishesNothing() async {
        let chip = NTAG213Simulator()
        let model = OperationsFlowModel(
            factory: ChipFactory(chip: chip),
            operation: .memoryDump,
            credentials: InMemoryTagCredentialStore()
        )
        await model.begin()
        XCTAssertNil(model.observation)
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
