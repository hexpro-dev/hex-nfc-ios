@testable import HexNFCApp
@testable import HexNFCKit
@testable import HexNFCRecords
import HexNFCStorage
@testable import HexNFCTagSim
import XCTest

/// The Operations sheet files what it is about to put on a tag, before the frame
/// that puts it there.
///
/// `TagCredentialStore` named this gap in its own header: the standalone protect
/// flow persisted nothing, so a tag protected from that sheet with a password the
/// user did not write down was gated behind a credential that existed in no
/// store. Neither an NTAG424 DNA nor an Ultralight C has a factory reset, and on
/// those two the secret is sixteen bytes nobody types from memory.
@MainActor
final class OperationsCredentialLedgerTests: XCTestCase {
    private let password = Data([0x0A, 0x0B, 0x0C, 0x0D])
    private let pack = Data([0x1E, 0x2F])

    // MARK: - Arming

    /// The record goes down before the arm, and is promoted to `.armed` once the
    /// driver's own read-back says the gate is up.
    func test_anArmFilesTheCredentialAndPromotesItOnSuccess() async throws {
        let chip = NTAG213Simulator()
        let store = InMemoryTagCredentialStore()
        let model = OperationsFlowModel(
            factory: SingleChipFactory(chip: chip),
            operation: .enableProtection(PendingProtection(
                settings: TagProtection(passwordProtect: true),
                credential: .type2(password: password, pack: pack)
            )),
            credentials: store
        )

        await runToCompletion(model)

        guard case .done(.passwordSet) = model.phase else {
            return XCTFail("expected the arm to complete, got \(model.phase)")
        }
        let record = try XCTUnwrap(store.record(forUID: chip.uid), "the arm filed nothing at all")
        XCTAssertEqual(record.stage, .armed)
        XCTAssertEqual(record.candidates.first, .type2(password: password, pack: pack))
        XCTAssertGreaterThanOrEqual(
            store.saveCount, 2,
            "the rule this store exists for is that the record is written BEFORE the frame that could "
                + "apply it, so there are two writes and the first one is not the outcome"
        )
    }

    /// An arm that never reaches its read-back leaves the record at `.applying`,
    /// which is the honest answer: either the new credential or one behind it may
    /// be what the tag now answers to.
    func test_anArmThatTearsLeavesTheRecordInFlight() async throws {
        let layout = try XCTUnwrap(Type2ConfigLayout.for(.ntag213))
        let chip = NTAG213Simulator()
        let faults = FaultInjectingSessionFactory(chip: chip)
        // Drop the PWD page write, which is the first credential frame the
        // driver sends, so the run throws with the record already filed. Dropped
        // rather than NAKed: the tag heard nothing, so nothing is refused and
        // nothing halts, which is the torn tap this rule is written for.
        faults.arm(TagFault(.write(page: layout.pwdPage), .dropped, on: .every))
        let store = InMemoryTagCredentialStore()
        let model = OperationsFlowModel(
            factory: faults,
            operation: .enableProtection(PendingProtection(
                settings: TagProtection(passwordProtect: true),
                credential: .type2(password: password, pack: pack)
            )),
            credentials: store
        )

        await runToCompletion(model)

        guard case .error = model.phase else {
            return XCTFail("expected the torn arm to fail, got \(model.phase)")
        }
        let record = try XCTUnwrap(
            store.record(forUID: chip.uid),
            "a credential the tag may be holding and the app is not is the dead-tag case this store "
                + "exists for, so a torn arm must leave a record behind"
        )
        XCTAssertEqual(record.stage, .applying)
        XCTAssertEqual(record.candidates.first, .type2(password: password, pack: pack))
    }

    // MARK: - Removing

    /// A removal that proved the tag open and its password back at the factory
    /// value is the one case the record is dropped on.
    func test_aProvenRemovalForgetsTheRecord() async throws {
        let chip = NTAG213Simulator()
        try chip.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let store = InMemoryTagCredentialStore()
        try store.save(
            TagCredentialRecord(stage: .armed, candidates: [.type2(password: password, pack: pack)]),
            forUID: chip.uid
        )
        let model = OperationsFlowModel(
            factory: SingleChipFactory(chip: chip),
            operation: .disableProtection,
            credentials: store
        )
        model.supplyUnlockCredential(.type2(password: password, pack: pack))

        await runToCompletion(model)

        guard case .done(.passwordRemoved) = model.phase else {
            return XCTFail("expected the removal to complete, got \(model.phase)")
        }
        XCTAssertNil(
            store.record(forUID: chip.uid),
            "the gate read back open and the credential read back as the factory value, which is the "
                + "only proof that forgetting it is safe"
        )
    }

    // MARK: - The ledger's own rules

    /// Settling a removal that could not prove both halves keeps the credential,
    /// filed as residue. A tag that is open but still holding the user's password
    /// cannot be re-keyed without it, and that combination is what the 2026-09-04
    /// incident left behind.
    func test_anUnprovenRemovalKeepsTheCredentialAsResidue() throws {
        let store = InMemoryTagCredentialStore()
        let uid = Data([0x04, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66])
        let ledger = TagCredentialLedger(store)

        let ticket = ledger.removing(.type2(password: password, pack: pack), forUID: uid)
        XCTAssertEqual(store.record(forUID: uid)?.stage, .removing, "filed before the frame, not after")
        ticket.settle(ProtectionResidue(
            family: .type2, intent: .disable, gate: .provenOpen, credential: .unknown(reason: "test")
        ))

        let record = try XCTUnwrap(store.record(forUID: uid))
        XCTAssertEqual(record.stage, .residue)
        XCTAssertEqual(record.candidates, [.type2(password: password, pack: pack)])
    }

    /// And the previous credential stays behind the new one, because between the
    /// two frames either could be the one the tag holds.
    func test_anArmKeepsThePreviousCredentialBehindTheNewOne() throws {
        let store = InMemoryTagCredentialStore()
        let uid = Data([0x04, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66])
        let older = ProtectionCredential.Material.type2(password: Data(repeating: 0x11, count: 4), pack: pack)
        try store.save(TagCredentialRecord(stage: .armed, candidates: [older]), forUID: uid)

        let ticket = TagCredentialLedger(store).arming(.type2(password: password, pack: pack), forUID: uid)

        XCTAssertEqual(
            store.record(forUID: uid)?.candidates,
            [.type2(password: password, pack: pack), older],
            "the new credential goes in front and the old one stays behind it"
        )
        ticket.settle(ProtectionResidue(
            family: .type2, intent: .enable, gate: .provenArmed(fromPage: 4),
            completed: [.credentialProven]
        ))
        XCTAssertEqual(store.record(forUID: uid)?.stage, .armed)
        XCTAssertEqual(store.record(forUID: uid)?.candidates.last, older)
    }

    // MARK: - Helpers

    private func runToCompletion(_ model: OperationsFlowModel) async {
        let run = Task { await model.begin() }
        await until {
            switch model.phase {
            case .awaitingConfirmation, .needsUnlock, .done, .error: true
            default: false
            }
        }
        if case .awaitingConfirmation = model.phase {
            model.confirm()
        }
        await run.value
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

private final class SingleChipFactory: TagSessionFactory, @unchecked Sendable {
    private let chip: ChipSimulator

    init(chip: ChipSimulator) {
        self.chip = chip
    }

    func makeSession() -> TagSession {
        SimulatedSession(chip: chip)
    }
}
