@testable import HexNFCApp
@testable import HexNFCKit
@testable import HexNFCRecords
import HexNFCStorage
@testable import HexNFCTagSim
import XCTest

/// A memory dump on a read-gated tag asks for the password instead of walking
/// into the gate.
///
/// The dump reads from page 0 upward in **one** `readMemory` call, so the gate
/// has to be open before it starts and can never be opened during it: a refused
/// READ NAKs a Type-2 chip and the NAK halts it for the rest of the activation,
/// so the read that found the gate would also end the tap. What the user would
/// see on a pure read is a lost tag.
///
/// It keeps its single tap. A dump changes nothing, and CLAUDE.md reserves the
/// typed-UID gate for Dangerous Actions, so the credential is collected on
/// `.needsUnlock` and the same tap is held again.
@MainActor
final class OperationsDumpUnlockTests: XCTestCase {
    private let password = Data([0x0A, 0x0B, 0x0C, 0x0D])
    private let pack = Data([0x1E, 0x2F])

    private func readGatedNTAG213() throws -> NTAG213Simulator {
        let chip = NTAG213Simulator()
        try chip.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: true, authLimit: 0
        )
        return chip
    }

    /// The gate is met before the dump's own read, and the session is torn down
    /// so the prompt can be typed into.
    func test_aReadGatedDumpStopsToAskRatherThanWalkingIntoTheGate() async throws {
        let chip = try readGatedNTAG213()
        let faults = FaultInjectingSessionFactory(chip: chip)
        let model = OperationsFlowModel(
            factory: faults,
            operation: .memoryDump,
            credentials: InMemoryTagCredentialStore()
        )

        await model.begin()

        XCTAssertEqual(model.phase, .needsUnlock)
        XCTAssertEqual(faults.tapCount, 1)
        XCTAssertNotNil(model.unlockStyle, "the prompt has to know which shape of secret to ask for")
        XCTAssertFalse(
            model.operation.requiresUIDConfirmation,
            "a dump changes nothing, so it must not gain the typed-UID gate a Dangerous Action has"
        )
    }

    /// And the credential the prompt collects finishes the dump on the next tap.
    func test_theSuppliedPasswordFinishesTheDump() async throws {
        let chip = try readGatedNTAG213()
        let model = OperationsFlowModel(
            factory: SingleChipFactory(chip: chip), operation: .memoryDump,
            credentials: InMemoryTagCredentialStore()
        )

        await model.begin()
        XCTAssertEqual(model.phase, .needsUnlock)

        await model.unlock(with: .type2(password: password, pack: pack))

        guard case .done(.memoryDumped(let bytes)) = model.phase else {
            return XCTFail("expected the dump to complete, got \(model.phase)")
        }
        XCTAssertEqual(bytes.count, try XCTUnwrap(chip.profile).readablePageCount * 4)
    }

    /// A tag that is merely write-protected is not read-gated, so the dump runs
    /// in one tap and asks for nothing. The rule is the read gate, not
    /// protection: a credential demanded here would be a counted `PWD_AUTH`
    /// spent on a tag that was going to answer anyway.
    func test_aWriteOnlyGateDoesNotStopADump() async throws {
        let chip = NTAG213Simulator()
        try chip.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let faults = FaultInjectingSessionFactory(chip: chip)
        let model = OperationsFlowModel(
            factory: faults,
            operation: .memoryDump,
            credentials: InMemoryTagCredentialStore()
        )

        await model.begin()

        guard case .done(.memoryDumped) = model.phase else {
            return XCTFail("expected the dump to complete in one tap, got \(model.phase)")
        }
        XCTAssertFalse(
            faults.report.contains(.opcode(Type2PasswordDriver.pwdAuth)),
            "nothing may be presented to a tag whose reads are open"
        )
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

/// The permanent lock is the one operation that must never show a credential
/// field, and the reason is the preflight rather than the screen.
///
/// Its warning has to be the first thing read, and a password field above it
/// would displace that. It does not need one: a gate the identify tap found
/// armed is refused on that tap, because the dynamic lock page sits above AUTH0
/// and burning the static region on a still-gated tag is how a real tag was left
/// half-locked (2026-09-04). So the lock either refuses or runs open.
@MainActor
final class PermanentLockNeedsNoCredentialTests: XCTestCase {
    private let password = Data([0x0A, 0x0B, 0x0C, 0x0D])
    private let pack = Data([0x1E, 0x2F])

    func test_anOpenTagReachesTheGateAskingForNothing() async {
        let model = OperationsFlowModel(
            factory: SingleChipFactory(chip: NTAG213Simulator()), operation: .permanentLock,
            credentials: InMemoryTagCredentialStore()
        )

        let run = Task { await model.begin() }
        await until {
            switch model.phase {
            case .awaitingConfirmation, .needsUnlock, .done, .error: true
            default: false
            }
        }
        let gated = model.requiresUnlockCredential
        let phase = model.phase
        model.cancel()
        await run.value

        guard case .awaitingConfirmation = phase else {
            return XCTFail("an unlocked, unprotected tag must reach the gate, got \(phase)")
        }
        XCTAssertFalse(gated, "there is no gate to open, so nothing may be asked for")
    }

    func test_aGatedTagIsRefusedOnTheIdentifyTapRatherThanAskedForAPassword() async throws {
        let chip = NTAG213Simulator()
        try chip.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let model = OperationsFlowModel(
            factory: SingleChipFactory(chip: chip), operation: .permanentLock,
            credentials: InMemoryTagCredentialStore()
        )

        await model.begin()

        guard case .error(_, let diagnostics) = model.phase else {
            return XCTFail("a gated tag must be refused before any lock bit burns, got \(model.phase)")
        }
        XCTAssertTrue(
            diagnostics.contains("Remove the password first"), "Got: \(diagnostics)"
        )
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
