@testable import HexNFCApp
@testable import HexNFCKit
@testable import HexNFCRecords
import HexNFCStorage
@testable import HexNFCTagSim
import XCTest

/// One channel for "what opens this tag", and what happens to a run that has
/// nothing in it.
///
/// Two of the six operations used to carry the credential inside the enum case
/// and a third carried one as `replacing:`, while the other three had nowhere
/// to put one at all. Two homes for one fact is the shape that dropped the
/// Ultralight C arm's caller-resolved key: the spec carried a `currentKey`, the
/// call carried `replacing:`, and the arm preferred the one the caller had not
/// resolved. So the credential now lives on the model, beside
/// `WriteFlowModel.unlockCredential`, and the operation names the verb plus,
/// for an arm, the settings and the secret it is going to write.
@MainActor
final class OperationsCredentialTests: XCTestCase {
    private let onTag = Data([0xA1, 0xB2, 0xC3, 0xD4])
    private let pack = Data([0x56, 0x78])

    // MARK: - An operation that needs a credential refuses without one

    /// The gate does not open for a run that needs a credential and holds none,
    /// so tap 2 is never spent discovering what tap 1 already knew.
    func test_theGateDoesNotOpenForARunHoldingNoCredential() async throws {
        let sim = NTAG213Simulator()
        try sim.enablePasswordProtection(
            password: onTag, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let faults = FaultInjectingSessionFactory(chip: sim)
        let model = OperationsFlowModel(
            factory: faults,
            operation: .disableProtection,
            credentials: InMemoryTagCredentialStore()
        )

        let run = Task { await model.begin() }
        await until {
            if case .awaitingConfirmation = model.phase {
                return true
            }
            return false
        }
        XCTAssertTrue(model.requiresUnlockCredential)

        model.confirm()
        // A refused `confirm()` is a no-op, so the run stays suspended on its
        // continuation and nothing moves. Give it a few turns to prove that
        // rather than racing a cancel against a gate that did open.
        for _ in 0 ..< 20 {
            await Task.yield()
        }

        guard case .awaitingConfirmation = model.phase else {
            await run.value
            return XCTFail("the gate must stay shut, got \(model.phase)")
        }
        XCTAssertEqual(faults.tapCount, 1, "no second session may open")
        XCTAssertFalse(
            faults.report.contains(.opcode(Type2PasswordDriver.pwdAuth)),
            "nothing may be presented to the tag when there is nothing to present"
        )
        XCTAssertEqual(
            try sim.readProtectionState()?.passwordProtect, true,
            "the tag must still be protected"
        )

        model.cancel()
        await run.value
    }

    /// The attempt limit needs a Type-2 password specifically, and says so
    /// rather than dispatching a key at a chip that cannot take one.
    func test_theAttemptLimitRefusesACredentialFromAnotherFamily() async throws {
        let sim = NTAG213Simulator()
        try sim.enablePasswordProtection(
            password: onTag, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let model = OperationsFlowModel(
            factory: SingleChipFactory(chip: sim),
            operation: .setAttemptLimit(limit: 3),
            credentials: InMemoryTagCredentialStore()
        )
        model.supplyUnlockCredential(.type4(aesKey: Data(repeating: 0, count: 16), keySlot: 0))

        await runToCompletion(model)

        // The preamble tries the key on the tap that writes, the chip will not
        // take it, and the run stops at the prompt rather than at an error card.
        XCTAssertEqual(model.phase, .needsUnlock, "got \(model.phase)")
        XCTAssertTrue(model.unlockFailed)
    }

    // MARK: - The channel is open exactly where the user types

    /// The typed-UID gate is the window this flow already has with no session
    /// open, so it is where a credential is collected, and what is supplied
    /// there is what tap 2 presents.
    ///
    /// The guard is "no session is open", not "no run is in flight". `begin()`
    /// is suspended on its continuation at the gate, so a run-in-flight guard
    /// would refuse the credential at the one moment the user can type one.
    func test_theCredentialSuppliedAtTheGateIsWhatTapTwoPresents() async throws {
        let sim = NTAG213Simulator()
        try sim.enablePasswordProtection(
            password: onTag, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let faults = FaultInjectingSessionFactory(chip: sim)
        let model = OperationsFlowModel(
            factory: faults,
            operation: .disableProtection,
            credentials: InMemoryTagCredentialStore()
        )

        let run = Task { await model.begin() }
        await until {
            if case .awaitingConfirmation = model.phase {
                return true
            }
            return false
        }
        XCTAssertTrue(model.requiresUnlockCredential, "the tag reported a gate over the pages a removal writes")
        XCTAssertFalse(
            faults.report.contains(.opcode(Type2PasswordDriver.pwdAuth)),
            "the identify tap is over, and it presented nothing"
        )

        model.supplyUnlockCredential(.type2(password: onTag, pack: pack))
        XCTAssertEqual(model.presentedType2Password, onTag)

        model.confirm()
        await run.value

        guard case .done(.passwordRemoved) = model.phase else {
            return XCTFail("expected the removal to complete, got \(model.phase)")
        }
        XCTAssertEqual(try sim.readProtectionState(), TagProtection.none)
    }

    // MARK: - What an arm presents when it holds nothing

    /// `Type2PasswordDriver.enable` falls back to `currentPassword ?? password`,
    /// so an arm holding nothing presents the password it is about to write.
    /// The model's record of what goes on the wire has to mirror that, or the
    /// factory-default classifier keys on a frame that was never sent.
    func test_anArmHoldingNothingPresentsThePasswordItIsAboutToWrite() {
        let newPassword = Data([0x0A, 0x0B, 0x0C, 0x0D])
        let model = OperationsFlowModel(
            factory: SingleChipFactory(chip: NTAG213Simulator()),
            operation: .enableProtection(PendingProtection(
                settings: TagProtection(passwordProtect: true, protectFromPage: 4),
                credential: .type2(password: newPassword, pack: Data([0x1E, 0x2F]))
            )),
            credentials: InMemoryTagCredentialStore()
        )

        XCTAssertNil(model.unlockCredential, "the standalone Protect screen has read nothing off the tag")
        XCTAssertEqual(model.presentedType2Password, newPassword)

        model.supplyUnlockCredential(.type2(password: onTag, pack: pack))

        XCTAssertEqual(
            model.presentedType2Password, onTag,
            "once something is held, that is what opens the gate and the new password is only written"
        )
    }

    /// An operation that presents nothing reports nothing, whatever it is.
    func test_anOperationWithNoCredentialPresentsNothing() {
        for operation in [OperationsFlowModel.Operation.erase, .format, .permanentLock, .memoryDump] {
            let model = OperationsFlowModel(
                factory: SingleChipFactory(chip: NTAG213Simulator()),
                operation: operation,
                credentials: InMemoryTagCredentialStore()
            )
            XCTAssertNil(model.presentedType2Password, "\(operation) presents no credential")
        }
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
            // The gate refuses to open for a run that needs a credential and
            // holds none, which some of these fixtures are deliberately in.
            // Confirming such a run leaves `begin()` suspended on its
            // continuation, which hangs the suite rather than failing it, so ask
            // the same question the gate asks and cancel instead.
            if model.requiresUnlockCredential, model.unlockCredential == nil {
                model.cancel()
            } else {
                model.confirm()
            }
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

/// Vends sessions over one chip, so state carries across taps as it does on a
/// physical tag. Deliberately local, like the equivalents in
/// `ConfirmationGateTests` and `FactoryDefaultRecoveryTests`.
private final class SingleChipFactory: TagSessionFactory, @unchecked Sendable {
    private let chip: ChipSimulator

    init(chip: ChipSimulator) {
        self.chip = chip
    }

    func makeSession() -> TagSession {
        SimulatedSession(chip: chip)
    }
}
