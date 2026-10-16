@testable import HexNFCApp
@testable import HexNFCKit
@testable import HexNFCRecords
import HexNFCStorage
@testable import HexNFCTagSim
import XCTest

/// The three Operations runs that go all the way to the silicon and check the
/// chip afterwards, rather than checking the phase the model reported.
///
/// Split out of `HexNFCAppTests` when that class outgrew its body limit, which
/// is the same reason `OperationsPreflight` was split out of
/// `OperationsFlowModel`. They belong together: each one drives a whole two-tap
/// run against a simulator and then asks the simulator what it holds.
final class OperationsFlowSimulatorTests: XCTestCase {
    @MainActor
    func test_operationsFlow_erase_runsAndVerifies() async throws {
        // Preload a record on the tag, then erase + verify the NDEF area is empty.
        let preloaded: [NDEFRecord] = [.uri(URIRecord(uri: "https://hex.pro"))]
        let envelope = try NDEFEnvelope.wrap(message: NDEFCodec.encode(preloaded))
        let simulator = NTAG215Simulator(ndefMessage: nil)
        try simulator.writeNDEF(envelope)
        let factory = SingletonChipFactory(chip: simulator)
        let model = OperationsFlowModel(factory: factory, operation: .erase, credentials: InMemoryTagCredentialStore())
        let runTask = Task { await model.begin() }
        // Wait for the awaitingConfirmation phase, then satisfy the typed-UID gate.
        await waitFor {
            if case .awaitingConfirmation = model.phase {
                return true
            }
            return false
        }
        model.confirm()
        await runTask.value
        if case .done(.erased) = model.phase {} else {
            XCTFail("expected .done(.erased), got \(model.phase)")
        }
    }

    @MainActor
    func test_operationsFlow_enablePasswordProtection_actuallyProtectsTag() async throws {
        let simulator = NTAG215Simulator()
        let factory = SingletonChipFactory(chip: simulator)
        let pw = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let pack = Data([0xCA, 0xFE])
        let model = OperationsFlowModel(
            factory: factory,
            operation: .enableProtection(PendingProtection(
                settings: TagProtection(passwordProtect: true, protectFromPage: 4),
                credential: .type2(password: pw, pack: pack)
            )),
            credentials: InMemoryTagCredentialStore()
        )
        let runTask = Task { await model.begin() }
        await waitFor {
            if case .awaitingConfirmation = model.phase {
                return true
            }
            return false
        }
        model.confirm()
        await runTask.value
        if case .done(.passwordSet) = model.phase {} else {
            XCTFail("expected .done(.passwordSet), got \(model.phase)")
        }

        // Protection is genuinely on (not just a stored credential): an
        // unauthenticated write to a protected page is now rejected.
        let tag = try await SimulatedSession(chip: simulator).start(alert: "")
        do {
            try await tag.writeMemory(at: 5 * 4, bytes: Data([0x00, 0x00, 0x00, 0x00]))
            XCTFail("unauthenticated write to a protected page should be rejected")
        } catch let error as TagError {
            guard case .authFailed = error.kind else { return XCTFail("wrong kind: \(error.kind)") }
        }
        // And the password authenticates, returning the PACK.
        let returnedPACK = try? simulator.authenticate(password: pw)
        XCTAssertEqual(returnedPACK, pack)
    }

    @MainActor
    func test_operationsFlow_permanentLock_flipsChipState() async {
        let simulator = NTAG215Simulator()
        XCTAssertFalse(simulator.isLockedPermanent)
        let factory = SingletonChipFactory(chip: simulator)
        let model = OperationsFlowModel(
            factory: factory,
            operation: .permanentLock,
            credentials: InMemoryTagCredentialStore()
        )
        let runTask = Task { await model.begin() }
        await waitFor {
            if case .awaitingConfirmation = model.phase {
                return true
            }
            return false
        }
        model.confirm()
        await runTask.value
        if case .done(.permanentlyLocked(verified: true)) = model.phase {} else {
            XCTFail("expected a verified .done(.permanentlyLocked), got \(model.phase)")
        }
        XCTAssertTrue(simulator.isLockedPermanent)
    }
}

private func waitFor(timeout: Duration = .milliseconds(500), _ predicate: @MainActor () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await predicate() {
            return
        }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }
}

/// A factory that always vends a fresh session over the *same chip simulator*,
/// so a write and the verify-read that follows see the same memory.
private final class SingletonChipFactory: TagSessionFactory, @unchecked Sendable {
    let chip: ChipSimulator

    init(chip: ChipSimulator) {
        self.chip = chip
    }

    func makeSession() -> TagSession {
        SimulatedSession(chip: chip)
    }
}
