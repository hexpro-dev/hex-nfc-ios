@testable import HexNFCApp
@testable import HexNFCKit
@testable import HexNFCRecords
import HexNFCStorage
@testable import HexNFCTagSim
import XCTest

/// What the identify tap asks the tag, and what it refuses before the user is
/// asked to type a UID.
///
/// `preflight` had a body for `.setAttemptLimit` and a bare `break` for the
/// other five, so every refusal this flow can make arrived on tap 2. Measured
/// 2026-09-21: tap 1 at 13:35:26 logged "resolved ntag213" and then asked the
/// tag nothing, with its AUTH0 and ACCESS one `30 29` away.
///
/// Two rules run through all of it. Every read here is one the preamble proved
/// safe, because on a Type-2 chip a refused READ NAKs and the NAK halts the chip
/// for the rest of the activation, so a preflight that reads above AUTH0 spends
/// the tap it is trying to save. And tap 1 touches nothing: no credential goes
/// out, and no write-shaped frame does either.
@MainActor
final class OperationsPreflightTests: XCTestCase {
    private let password = Data([0xCA, 0xFE, 0xBA, 0xBE])
    private let pack = Data([0x12, 0x34])

    // MARK: - Tap 1 touches nothing

    /// Tap 1's copy says it is identifying the tag. Passing it the credential
    /// would put a `PWD_AUTH` on a tap that promised not to, and on a tag with
    /// an attempt limit that try is not free.
    func test_theIdentifyTapPresentsNoCredential() async throws {
        let chip = NTAG213Simulator()
        try chip.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let faults = FaultInjectingSessionFactory(chip: chip)
        let model = OperationsFlowModel(
            factory: faults,
            operation: .disableProtection,
            credentials: InMemoryTagCredentialStore()
        )
        model.supplyUnlockCredential(.type2(password: password, pack: pack))

        let run = Task { await model.begin() }
        await untilSettledOrGated(model)

        guard case .awaitingConfirmation = model.phase else {
            return XCTFail("a protected tag must reach the gate, got \(model.phase)")
        }
        XCTAssertFalse(
            faults.report.contains(.opcode(Type2PasswordDriver.pwdAuth)),
            "the identify tap needs a reading, not an open gate"
        )
        XCTAssertEqual(chip.failedAuthAttempts, 0)

        model.cancel()
        await run.value
    }

    /// On a SLIX2 the protection read *is* a write probe, so the tap that told
    /// the user it is reading the tag must put no write on the air.
    /// `WriteConfirmationGateTests` guards the same thing on the write route.
    func test_theIdentifyTapDoesNotProbeASlixByWriting() async {
        // 80 blocks is the SLIX2, the one Type-5 profile this app offers
        // protection for.
        let chip = Iso15693Simulator(blockCount: 80)
        let faults = FaultInjectingSessionFactory(chip: chip)
        let model = OperationsFlowModel(
            factory: faults,
            operation: .enableProtection(PendingProtection(
                settings: TagProtection(passwordProtect: true, style: .type5(.init(kind: .write))),
                credential: .type5(password: Data([0x5A, 0x5A, 0x5A, 0x5A]), kind: .write)
            )),
            credentials: InMemoryTagCredentialStore()
        )

        let run = Task { await model.begin() }
        await untilSettledOrGated(model)
        let identifyTap = faults.report.frames(inTap: faults.tapCount)
        model.cancel()
        await run.value

        let writeOpcodes: Set<UInt8> = [
            Iso15693Opcode.writeSingleBlock, Iso15693Opcode.lockBlock,
            Iso15693Opcode.setPassword, Iso15693Opcode.writePassword,
            Iso15693Opcode.protectPage,
        ]
        let writes = identifyTap.filter { frame in
            frame.request.contains { writeOpcodes.contains($0) }
        }
        XCTAssertTrue(writes.isEmpty, "the identify tap put \(writes.count) write-shaped frame(s) on the air")
    }

    // MARK: - Format

    /// The refusal that stands between tap 2 and an irreversible OR into page 3.
    /// `formatCC` keeps its own copy of it; this is the same refusal one tap
    /// earlier, with nothing typed and nothing written.
    func test_aDifferentCapabilityContainerIsRefusedOnTheIdentifyTap() async {
        let chip = NTAG213Simulator()
        // A valid CC belonging to a different chip: ORing NTAG213's 0x12 into
        // this 0x06 gives 0x16, a size byte belonging to no chip at all.
        let foreign = Data([Type2CC.magic, Type2CC.version, 0x06, 0x00])
        chip.pages[3] = foreign
        let model = OperationsFlowModel(
            factory: SingleChipFactory(chip: chip),
            operation: .format,
            credentials: InMemoryTagCredentialStore()
        )

        await runToCompletion(model)

        guard case .error(let message, let diagnostics) = model.phase else {
            return XCTFail("a foreign CC must be refused, got \(model.phase)")
        }
        // Exactly what `formatCC` throws, which is the point: the same refusal,
        // one tap earlier. `TagError.protocolError` puts its first argument in
        // the diagnostics, so that is where the sentence is on both routes.
        XCTAssertEqual(message, String(localized: TagError.protocolError("").userMessage))
        XCTAssertTrue(
            diagnostics.contains(String(localized: "This tag already has a different Capability Container.")),
            "Got: \(diagnostics)"
        )
        XCTAssertTrue(diagnostics.contains("OTP bits cannot be cleared"), "Got: \(diagnostics)")
        XCTAssertEqual(chip.pages[3], foreign, "page 3 is OTP and must be exactly as it was")
        XCTAssertNil(model.reading, "a refused identify tap publishes no reading")
    }

    /// A chip family with no Capability Container at all.
    func test_aFamilyWithNoCapabilityContainerIsRefusedOnTheIdentifyTap() async {
        let model = OperationsFlowModel(
            factory: SingleChipFactory(chip: UnknownType2Simulator()),
            operation: .format,
            credentials: InMemoryTagCredentialStore()
        )

        await runToCompletion(model)

        guard case .error(_, let diagnostics) = model.phase else {
            return XCTFail("an unidentified chip has no factory CC to write, got \(model.phase)")
        }
        XCTAssertTrue(diagnostics.contains("CC format unsupported"), "Got: \(diagnostics)")
    }

    /// **No fourth refusal for a read-gated tag.** Page 3 sits below every AUTH0
    /// this app can write, so the pre-read is answered on a gated tag exactly as
    /// it is on an open one, and there is nothing here for a read gate to stop.
    /// A refusal invented for it would need a simulator taught behaviour no
    /// trace has shown.
    func test_aReadGatedTagIsNotRefusedAFormat() async throws {
        let chip = NTAG213Simulator()
        try chip.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: true, authLimit: 0
        )
        let model = OperationsFlowModel(
            factory: SingleChipFactory(chip: chip),
            operation: .format,
            credentials: InMemoryTagCredentialStore()
        )

        let run = Task { await model.begin() }
        await untilSettledOrGated(model)

        guard case .awaitingConfirmation = model.phase else {
            return XCTFail("a read-gated tag must still reach the gate, got \(model.phase)")
        }
        model.cancel()
        await run.value
    }

    // MARK: - Permanent lock

    /// The gate refusal `Type2LockDriver.refuseIfGated` composes, one tap
    /// earlier. The driver keeps its own: this is the belt and that is the
    /// braces, which is the standing rule for a write with no undo.
    func test_aGatedTagIsRefusedTheLockBeforeTheUIDIsEverTyped() async throws {
        let chip = NTAG213Simulator()
        try chip.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let model = OperationsFlowModel(
            factory: SingleChipFactory(chip: chip),
            operation: .permanentLock,
            credentials: InMemoryTagCredentialStore()
        )

        // Deliberately not `runToCompletion`. The driver refuses a gated tag too,
        // so a run that reached the typed-UID gate and was confirmed would end in
        // the same `.error` with the same message: what this test is about is
        // that the user never typed a UID for it.
        guard case .error(let message, _) = await identifyTap(model).phase else {
            return XCTFail("a gated tag must be refused the lock on tap 1, got \(model.phase)")
        }
        XCTAssertEqual(
            message,
            String(
                localized: "This tag is password protected, so it cannot be permanently locked. Remove the password first, then lock it."
            )
        )
        XCTAssertFalse(chip.isLockedPermanent, "nothing may burn on a tap that only identifies")
    }

    /// An already-locked tag says so before the user types anything.
    func test_anAlreadyLockedTagIsRefusedOnTheIdentifyTap() async throws {
        let chip = NTAG213Simulator()
        try chip.permanentLock()
        let model = OperationsFlowModel(
            factory: SingleChipFactory(chip: chip),
            operation: .permanentLock,
            credentials: InMemoryTagCredentialStore()
        )

        await runToCompletion(model)

        guard case .error(let message, _) = model.phase else {
            return XCTFail("a locked tag must be refused, got \(model.phase)")
        }
        XCTAssertEqual(message, String(localized: TagError.lockedPermanent().userMessage))
    }

    /// The lock read happens here and only here, and only once the gate is
    /// proven open. On an unlocked tag it reaches the reading.
    func test_theLockStateIsReadOnTheIdentifyTapOfALockAndNowhereElse() async {
        let chip = NTAG213Simulator()
        let lock = OperationsFlowModel(
            factory: SingleChipFactory(chip: chip),
            operation: .permanentLock,
            credentials: InMemoryTagCredentialStore()
        )

        let run = Task { await lock.begin() }
        await untilSettledOrGated(lock)
        XCTAssertEqual(lock.reading?.lock?.state, .open, "the gate is open, so the lock pages are readable")
        lock.cancel()
        await run.value

        let erase = OperationsFlowModel(
            factory: SingleChipFactory(chip: chip),
            operation: .erase,
            credentials: InMemoryTagCredentialStore()
        )
        let eraseRun = Task { await erase.begin() }
        await untilSettledOrGated(erase)
        XCTAssertNil(
            erase.reading?.lock,
            "an erase is recoverable and tap 2's own write is the cheaper answer, so it reads no lock bytes"
        )
        erase.cancel()
        await eraseRun.value
    }

    /// And nowhere the gate was not proven open. A chip with no password block
    /// has nothing to report a gate from, so the reading stays silent rather
    /// than sending a frame at a page nothing established as readable.
    func test_noLockIsReadWhenTheGateWasNotProvenOpen() async throws {
        let model = OperationsFlowModel(
            factory: SingleChipFactory(chip: NTAG210MicroSimulator()),
            operation: .permanentLock,
            credentials: InMemoryTagCredentialStore()
        )

        let identify = await identifyTap(model)
        guard case .awaitingConfirmation = identify.phase else {
            return XCTFail("an NTAG 210u has lock bytes and no gate, so the lock must be offered")
        }
        let reading = try XCTUnwrap(identify.reading)
        XCTAssertNil(reading.protection, "there is no password block to read a gate from")
        XCTAssertNil(
            reading.lock,
            "nothing proved the gate open, so nothing may address the lock pages"
        )
    }

    // MARK: - Protection

    /// A removal on a tag the reading positively says is open.
    func test_aRemovalOnAnOpenTagIsRefusedOnTheIdentifyTap() async {
        let chip = NTAG213Simulator()
        let model = OperationsFlowModel(
            factory: SingleChipFactory(chip: chip),
            operation: .disableProtection,
            credentials: InMemoryTagCredentialStore()
        )
        model.supplyUnlockCredential(.type2(password: password, pack: pack))

        await runToCompletion(model)

        guard case .error(let message, _) = model.phase else {
            return XCTFail("an open tag has nothing to remove, got \(model.phase)")
        }
        XCTAssertEqual(message, String(localized: "This tag has no password set, so there is nothing to remove."))
    }

    /// And the other half of that rule, which is the one that matters. A tag
    /// whose configuration tap 1 could not read is not refused: the run
    /// proceeds and tap 2 decides.
    ///
    /// A read-gated tag is that tag. Its configuration pages sit behind the very
    /// gate the removal exists to take down, so the preamble stops for a
    /// credential rather than reading them, and `reading.protection` is nil. A
    /// refusal keyed on "the reading says protected" rather than on "the reading
    /// says open" would turn every read-gated tag away from the one screen that
    /// can unprotect it, and a torn removal leaves exactly that shape.
    func test_aRemovalOnATagWhoseGateCouldNotBeReadStillReachesTheUIDGate() async throws {
        let chip = NTAG213Simulator()
        try chip.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: true, authLimit: 0
        )
        let model = OperationsFlowModel(
            factory: SingleChipFactory(chip: chip),
            operation: .disableProtection,
            credentials: InMemoryTagCredentialStore()
        )
        model.supplyUnlockCredential(.type2(password: password, pack: pack))

        let run = Task { await model.begin() }
        await untilSettledOrGated(model)

        guard case .awaitingConfirmation = model.phase else {
            return XCTFail("a tag whose gate could not be read must still reach the gate, got \(model.phase)")
        }
        XCTAssertNil(model.reading?.protection, "nothing read the configuration, so nothing may report it")
        model.cancel()
        await run.value
    }

    /// A chip with no protection backend can be neither armed nor unarmed, and
    /// saying so on tap 1 costs the user nothing.
    func test_aChipWithNoProtectionBackendIsRefused() async {
        let model = OperationsFlowModel(
            factory: SingleChipFactory(chip: NTAG210MicroSimulator()),
            operation: .disableProtection,
            credentials: InMemoryTagCredentialStore()
        )
        model.supplyUnlockCredential(.type2(password: password, pack: pack))

        await runToCompletion(model)

        guard case .error(_, let diagnostics) = model.phase else {
            return XCTFail("an NTAG 210u has no password block, got \(model.phase)")
        }
        XCTAssertTrue(diagnostics.contains("no protection backend"), "Got: \(diagnostics)")
    }

    // MARK: - The reading itself

    func test_theReadingCarriesWhatTapOneEstablishedAndIsClearedWithTheRun() async throws {
        let chip = NTAG213Simulator()
        let model = OperationsFlowModel(
            factory: SingleChipFactory(chip: chip),
            operation: .erase,
            credentials: InMemoryTagCredentialStore()
        )

        let run = Task { await model.begin() }
        await untilSettledOrGated(model)

        let reading = try XCTUnwrap(model.reading)
        XCTAssertEqual(reading.uid, chip.uid)
        XCTAssertEqual(reading.chip, .ntag213)
        XCTAssertEqual(reading.chipName, chip.profile?.displayName)
        XCTAssertEqual(reading.firstDataPage, chip.profile?.memoryLayout.ndefRange?.lowerBound)
        XCTAssertEqual(reading.protection?.passwordProtect, false)
        XCTAssertFalse(reading.protectionIsUnknown)

        model.cancel()
        await run.value
        XCTAssertNil(model.reading, "cancelling must not leave a reading behind")
    }

    /// A tag whose state tap 1 could not establish says so rather than reporting
    /// an open gate it never read.
    func test_aGatedTagsReadingSaysTheProtectionStateIsUnknown() async throws {
        let chip = NTAG213Simulator()
        try chip.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let model = OperationsFlowModel(
            factory: SingleChipFactory(chip: chip),
            operation: .disableProtection,
            credentials: InMemoryTagCredentialStore()
        )
        model.supplyUnlockCredential(.type2(password: password, pack: pack))

        let run = Task { await model.begin() }
        await untilSettledOrGated(model)

        XCTAssertEqual(model.reading?.protectionIsUnknown, true)
        XCTAssertNil(
            model.reading?.protection,
            "the preamble stopped for a credential rather than reading the configuration, so there "
                + "is no reading to report"
        )
        model.cancel()
        await run.value
    }

    // MARK: - Helpers

    private func runToCompletion(_ model: OperationsFlowModel) async {
        let run = Task { await model.begin() }
        await untilSettledOrGated(model)
        if case .awaitingConfirmation = model.phase {
            model.confirm()
        }
        await run.value
    }

    /// Run to the first phase that is waiting on the user, and hand back what
    /// the model held there rather than what it holds afterwards.
    ///
    /// A run stopped at the typed-UID gate has to be cancelled or its task never
    /// returns, and `cancel()` puts the model back to `.idle` and drops the
    /// reading with it, so a caller that asserted afterwards would be asserting
    /// on nothing at all and passing for the wrong reason.
    private func identifyTap(
        _ model: OperationsFlowModel
    ) async -> (phase: OperationsFlowModel.Phase, reading: OperationsFlowModel.TagReading?) {
        let run = Task { await model.begin() }
        await untilSettledOrGated(model)
        let settled = (phase: model.phase, reading: model.reading)
        if case .awaitingConfirmation = settled.phase {
            model.cancel()
        }
        await run.value
        return settled
    }

    private func untilSettledOrGated(_ model: OperationsFlowModel) async {
        await until {
            switch model.phase {
            case .awaitingConfirmation, .needsUnlock, .done, .error: true
            default: false
            }
        }
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
