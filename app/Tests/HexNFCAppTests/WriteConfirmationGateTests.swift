@testable import HexNFCApp
@testable import HexNFCKit
@testable import HexNFCRecords
import HexNFCStorage
@testable import HexNFCTagSim
import XCTest

/// The typed-UID gate on the write route (bench finding 19).
///
/// Two routes armed a Type-2 password gate and only one confirmed the tag.
/// Operations identifies the tag, asks for its UID with no NFC session open, and
/// refuses a different tag on the change tap; the scan screen's Protection card
/// wrote PWD, PACK, ACCESS and AUTH0 in a single tap with no confirmation
/// (2026-09-10, 11:39:18 and 11:41:36). This suite is the shape of the fix, and
/// the thing it has to keep proving is not that the card exists but *when*: how
/// many sessions a write takes, and whether one is open while the user types.
@MainActor
final class WriteConfirmationGateTests: XCTestCase {
    private let password = Data([0x11, 0x22, 0x33, 0x44])
    private let pack = Data([0xAA, 0xBB])
    private let records: [NDEFRecord] = [.uri(URIRecord(uri: "https://hex.pro"))]

    private func armingProtection() -> PendingProtection {
        PendingProtection(
            settings: TagProtection(passwordProtect: true, protectFromPage: 4, readProtect: false, authLimit: 0),
            credential: .type2(password: password, pack: pack)
        )
    }

    /// Everything the Library preset route passes, with the policy left open.
    /// The only difference between the two halves of the differential pair below.
    private func presetShapedModel(
        _ policy: WriteFlowModel.UIDConfirmation,
        factory: TagSessionFactory
    ) -> WriteFlowModel {
        WriteFlowModel(
            factory: factory,
            dataArea: .replace(records),
            credentials: InMemoryTagCredentialStore(),
            protection: armingProtection(),
            unlockCredential: .type2(password: password, pack: pack),
            uidConfirmation: policy
        )
    }

    // MARK: - The gate

    /// The shape of the whole change: two taps, the card between them, and no
    /// session open while it is up.
    func test_armingProtection_asksForTheUIDWithNoSessionOpen_thenWritesOnTheSecondTap() async throws {
        let chip = NTAG215Simulator()
        let factory = RecordingFactory(chip: chip)
        let model = WriteFlowModel(
            factory: factory, dataArea: .replace(records), credentials: InMemoryTagCredentialStore(),
            protection: armingProtection(), uidConfirmation: .required
        )

        let before = model.transitionCount
        let run = Task { await model.begin() }
        await untilSettled(model, after: before)

        guard case .awaitingConfirmation(let uidHex) = model.phase else {
            return XCTFail("expected the gate, got \(model.phase)")
        }
        XCTAssertEqual(uidHex, chip.uid.hexString, "the card shows the UID the identify tap read")
        XCTAssertEqual(factory.sessionsStarted, 1, "tap 1 only")
        XCTAssertEqual(factory.sessionsInvalidated, 1, "and its session is torn down before the card goes up")
        XCTAssertEqual(factory.alerts.first, "Hold the tag to identify it.")
        // Tap 1 wrote nothing: the tag is still unprotected and still blank.
        XCTAssertEqual(try? chip.readProtectionState()?.passwordProtect, false)
        XCTAssertTrue(try NDEFCodec.isEmptyMessage(chip.readNDEF()), "the identify tap must not write")

        model.confirm()
        await run.value

        XCTAssertEqual(model.phase, .done, "expected .done, got \(model.phase)")
        XCTAssertEqual(factory.sessionsStarted, 2, "identify, then write")
        XCTAssertEqual(try chip.authenticate(password: password), pack)
        let tag = try await SimulatedSession(chip: chip).start(alert: "")
        do {
            try await tag.writeMemory(at: 5 * 4, bytes: Data([0x00, 0x00, 0x00, 0x00]))
            XCTFail("unauthenticated write should be rejected after protection")
        } catch let error as TagError {
            guard case .authFailed = error.kind else { return XCTFail("wrong kind: \(error.kind)") }
        }
    }

    /// Removal is gated too: Operations gates `.disableProtection`, and a stack
    /// protected from one preset shares a password, so a removal aimed at the
    /// wrong tag would otherwise succeed silently.
    func test_removingProtection_isGatedToo() async throws {
        let chip = NTAG215Simulator()
        try chip.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let factory = RecordingFactory(chip: chip)
        let model = WriteFlowModel(
            factory: factory, dataArea: .replace(records), credentials: InMemoryTagCredentialStore(),
            unlockCredential: .type2(password: password, pack: pack),
            removeProtection: true, uidConfirmation: .required
        )

        let before = model.transitionCount
        let run = Task { await model.begin() }
        await untilSettled(model, after: before)
        guard case .awaitingConfirmation = model.phase else {
            return XCTFail("a removal must confirm the tag too, got \(model.phase)")
        }
        XCTAssertEqual(try? chip.readProtectionState()?.passwordProtect, true, "tap 1 removes nothing")

        model.confirm()
        await run.value

        XCTAssertEqual(model.phase, .done, "expected .done, got \(model.phase)")
        XCTAssertEqual(try? chip.readProtectionState()?.passwordProtect, false)
    }

    // MARK: - What is not gated

    /// A write that changes no protection state is what it always was.
    func test_aPlainRecordWrite_isNotGated() async {
        let factory = RecordingFactory(chip: NTAG215Simulator())
        let model = WriteFlowModel(
            factory: factory, dataArea: .replace(records), credentials: InMemoryTagCredentialStore(),
            uidConfirmation: .required
        )

        await beginExpectingNoGate(model)

        XCTAssertEqual(model.phase, .done)
        XCTAssertEqual(factory.sessionsStarted, 1, "records only: one tap, as before")
    }

    /// And so is a write to a tag already protected with a password we hold.
    func test_writingToAProtectedTagWeHoldThePasswordFor_isNotGated() async throws {
        let chip = NTAG215Simulator()
        try chip.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let factory = RecordingFactory(chip: chip)
        let model = WriteFlowModel(
            factory: factory, dataArea: .replace(records), credentials: InMemoryTagCredentialStore(),
            unlockCredential: .type2(password: password, pack: pack), uidConfirmation: .required
        )

        await beginExpectingNoGate(model)

        XCTAssertEqual(model.phase, .done, "a held password still writes in one tap, got \(model.phase)")
        XCTAssertEqual(factory.sessionsStarted, 1)
    }

    // MARK: - The Library exemption

    /// The differential pair. One argument differs, and it is the whole of the
    /// product decision: a preset write arms in one tap, the same configuration
    /// from the editor takes two.
    ///
    /// The exempt half asserts the tag is actually protected afterwards, not
    /// merely that the flow reached `.done`: an "exemption" implemented by
    /// skipping the apply would pass a weaker assertion.
    func test_theLibraryPresetShape_armsInOneTapWhenExempt() async throws {
        let chip = NTAG215Simulator()
        let factory = RecordingFactory(chip: chip)
        let model = presetShapedModel(.notRequired, factory: factory)

        await beginExpectingNoGate(model)

        XCTAssertEqual(model.phase, .done, "expected .done, got \(model.phase)")
        XCTAssertFalse(model.requiresUIDConfirmation, "the caller's policy is what makes this route exempt")
        XCTAssertEqual(factory.sessionsStarted, 1, "one tap per tag is the whole point of a preset")
        XCTAssertEqual(try chip.authenticate(password: password), pack, "and it really did arm the tag")
    }

    func test_theSamePresetShape_isGatedWhenRequired() async {
        let chip = NTAG215Simulator()
        let factory = RecordingFactory(chip: chip)
        let model = presetShapedModel(.required, factory: factory)

        let before = model.transitionCount
        let run = Task { await model.begin() }
        await untilSettled(model, after: before)
        guard case .awaitingConfirmation = model.phase else {
            return XCTFail("the same model with .required must gate, got \(model.phase)")
        }
        model.confirm()
        await run.value

        XCTAssertEqual(model.phase, .done)
        XCTAssertEqual(factory.sessionsStarted, 2)
    }

    // MARK: - A different tag

    /// The gate was satisfied against one tag. Another one does not inherit it.
    func test_aDifferentTagOnTheWriteTap_isRefusedAndNeitherTagIsTouched() async throws {
        let identified = NTAG215Simulator()
        let presented = NTAG213Simulator()
        var exhausted = false
        let factory = SwappingFactory(chips: [identified, presented]) { exhausted = true }
        let model = WriteFlowModel(
            factory: factory, dataArea: .replace(records), credentials: InMemoryTagCredentialStore(),
            protection: armingProtection(), uidConfirmation: .required
        )

        let before = model.transitionCount
        let run = Task { await model.begin() }
        await untilSettled(model, after: before)
        guard case .awaitingConfirmation = model.phase else {
            return XCTFail("expected the gate, got \(model.phase)")
        }
        model.confirm()
        await run.value

        guard case .error(_, let diagnostics) = model.phase else {
            return XCTFail("a different tag must fail the write, got \(model.phase)")
        }
        XCTAssertTrue(diagnostics.contains(identified.uid.hexString), "Got: \(diagnostics)")
        XCTAssertTrue(diagnostics.contains(presented.uid.hexString), "Got: \(diagnostics)")
        XCTAssertFalse(exhausted, "the flow opened more sessions than the test staged")
        for (name, chip) in [("identified", identified as ChipSimulator), ("presented", presented)] {
            XCTAssertEqual(try? chip.readProtectionState()?.passwordProtect, false, "\(name) tag was protected")
            XCTAssertTrue(try NDEFCodec.isEmptyMessage(chip.readNDEF()), "\(name) tag was written")
        }
    }

    /// The editor knows which tag it is about, so presenting another one fails on
    /// the identify tap rather than asking the user to confirm a tag they did not
    /// mean to be holding.
    func test_aTagOtherThanTheEditorsOwn_failsOnTheIdentifyTapWithoutAskingForItsUID() async {
        let presented = NTAG213Simulator()
        let factory = RecordingFactory(chip: presented)
        let model = WriteFlowModel(
            factory: factory, dataArea: .replace(records), credentials: InMemoryTagCredentialStore(),
            protection: armingProtection(), uidConfirmation: .required,
            targetUID: NTAG215Simulator().uid
        )

        await model.begin()

        guard case .error(_, let diagnostics) = model.phase else {
            return XCTFail("expected a refusal on tap 1, got \(model.phase)")
        }
        XCTAssertTrue(diagnostics.contains(presented.uid.hexString), "Got: \(diagnostics)")
        XCTAssertEqual(factory.sessionsStarted, 1, "and no second tap was asked for")
        XCTAssertEqual(try? presented.readProtectionState()?.passwordProtect, false)
    }

    // MARK: - Stops

    /// Cancelling at the gate resolves the suspended `begin()` and opens nothing.
    func test_cancellingAtTheGate_endsTheRunWithoutASecondSession() async throws {
        let chip = NTAG215Simulator()
        let factory = RecordingFactory(chip: chip)
        let model = WriteFlowModel(
            factory: factory, dataArea: .replace(records), credentials: InMemoryTagCredentialStore(),
            protection: armingProtection(), uidConfirmation: .required
        )

        let before = model.transitionCount
        let run = Task { await model.begin() }
        await untilSettled(model, after: before)
        model.reset()
        await run.value

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(factory.sessionsStarted, 1, "the write tap must never open")
        XCTAssertEqual(try? chip.readProtectionState()?.passwordProtect, false)
        XCTAssertTrue(try NDEFCodec.isEmptyMessage(chip.readNDEF()))
    }

    /// A chip with no protection backend fails on tap 1, before the user is asked
    /// to type anything, and with the records still in hand.
    func test_aChipThatCannotBeProtected_failsOnTheIdentifyTap() async throws {
        let chip = UnknownType2Simulator()
        let factory = RecordingFactory(chip: chip)
        let model = WriteFlowModel(
            factory: factory, dataArea: .replace(records), credentials: InMemoryTagCredentialStore(),
            protection: armingProtection(), uidConfirmation: .required
        )

        await model.begin()

        guard case .error = model.phase else { return XCTFail("expected an error, got \(model.phase)") }
        XCTAssertEqual(factory.sessionsStarted, 1, "and it never reached the gate")
        XCTAssertTrue(try NDEFCodec.isEmptyMessage(chip.readNDEF()), "records must not be stranded")
    }

    /// The family check runs in the shared preamble, so it also protects the
    /// exempt route: a Type-2 configuration replayed onto an NTAG424 is refused
    /// before the records go on the tag, rather than at driver dispatch after.
    func test_aType2PresetAgainstA424_isRefusedBeforeAnythingIsWritten() async throws {
        let chip = NTAG424DNASimulator()
        let factory = RecordingFactory(chip: chip)
        let model = presetShapedModel(.notRequired, factory: factory)

        await beginExpectingNoGate(model)

        guard case .error(_, let diagnostics) = model.phase else {
            return XCTFail("expected a refusal, got \(model.phase)")
        }
        XCTAssertTrue(diagnostics.contains("type2"), "Got: \(diagnostics)")
        XCTAssertTrue(diagnostics.contains("type4"), "Got: \(diagnostics)")
        XCTAssertEqual(factory.sessionsStarted, 1)
        // The point of moving the check into the shared preamble: the records
        // are still in hand rather than stranded on a tag that cannot carry the
        // protection they were staged with.
        let readBack = try await SimulatedSession(chip: chip).start(alert: "").readNDEF()
        XCTAssertTrue(NDEFCodec.isEmptyMessage(readBack), "nothing may be written, got \(readBack.hexString)")
    }

    // MARK: - The unlock leg

    /// A tag whose password the app does not hold: tap 1 reports it, the user
    /// types the password, and the gate follows without a second identify tap.
    /// Two holds in total, as before this change.
    func test_anUnheldPassword_promptsOnTapOneAndDoesNotCostASecondIdentify() async throws {
        let chip = NTAG215Simulator()
        try chip.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let factory = RecordingFactory(chip: chip)
        let model = WriteFlowModel(
            factory: factory, dataArea: .replace(records), credentials: InMemoryTagCredentialStore(),
            removeProtection: true, uidConfirmation: .required
        )

        await model.begin()
        XCTAssertEqual(model.phase, .needsUnlock, "tap 1 reports the lock, got \(model.phase)")
        XCTAssertEqual(factory.sessionsStarted, 1)

        let beforeUnlock = model.transitionCount
        let run = Task { await model.unlock(with: .type2(password: password, pack: pack)) }
        await untilSettled(model, after: beforeUnlock)
        guard case .awaitingConfirmation = model.phase else {
            return XCTFail("expected the gate after the password, got \(model.phase)")
        }
        XCTAssertEqual(factory.sessionsStarted, 1, "the UID tap 1 read is not thrown away")

        model.confirm()
        await run.value

        XCTAssertEqual(model.phase, .done, "expected .done, got \(model.phase)")
        XCTAssertEqual(factory.sessionsStarted, 2, "two holds in total")
        XCTAssertEqual(try? chip.readProtectionState()?.passwordProtect, false)
    }

    // MARK: - Other families

    /// The card is the only route that arms these, and their keys have no
    /// factory reset, so the gate covers them too.
    func test_theKeyFamiliesAreGated() async throws {
        let key = Data((0 ..< 16).map { UInt8(0x30 &+ $0) })
        let fixtures: [(String, ChipSimulator, PendingProtection)] = try [
            (
                "Ultralight C",
                // Seeded, so the fixture is a *formatted* Ultralight C. A factory
                // one ships with page 3 blank (rev 3.3 Table 13) and cannot carry
                // a message at all, which is a different test's subject.
                MifareUltralightCSimulator(
                    ndefMessage: NDEFCodec.encode([.text(TextRecord(text: "seed"))])
                ),
                PendingProtection(
                    settings: TagProtection(passwordProtect: true, style: .ultralightC(.init())),
                    credential: .ultralightC(key: UltralightCKey(cipherOrder: key))
                )
            ),
            (
                "NTAG424",
                NTAG424DNASimulator(),
                PendingProtection(
                    settings: TagProtection(
                        passwordProtect: true,
                        style: .type4(.init(keySlot: 0, readProtect: false))
                    ),
                    credential: .type4(aesKey: key, keySlot: 0)
                )
            ),
        ]
        for (name, chip, protection) in fixtures {
            let factory = RecordingFactory(chip: chip)
            let model = WriteFlowModel(
                factory: factory, dataArea: .replace(records), credentials: InMemoryTagCredentialStore(),
                protection: protection, uidConfirmation: .required
            )

            let before = model.transitionCount
            let run = Task { await model.begin() }
            await untilSettled(model, after: before)
            guard case .awaitingConfirmation = model.phase else {
                XCTFail("\(name): expected the gate, got \(model.phase)")
                model.reset()
                await run.value
                continue
            }
            XCTAssertEqual(factory.sessionsStarted, 1, "\(name)")
            model.confirm()
            await run.value

            XCTAssertEqual(model.phase, .done, "\(name): expected .done, got \(model.phase)")
            XCTAssertEqual(factory.sessionsStarted, 2, "\(name)")
            XCTAssertEqual(try? chip.readProtectionState()?.passwordProtect, true, "\(name)")
        }
    }

    // MARK: - Stopping a run that is already inside begin()

    /// `reset()` while tap 1 is in flight stops the run before anything is
    /// written, which `currentSession?.invalidate()` alone cannot do: on device
    /// that call is a no-op until CoreNFC has actually created the session,
    /// which it does only after the inter-session cooldown. The run token is
    /// what closes that window, and nothing else exercises it.
    func test_cancellingWhileTheIdentifyTapIsInFlight_stopsTheRun() async throws {
        let chip = NTAG215Simulator()
        let factory = BlockingFactory(chip: chip)
        let model = WriteFlowModel(
            factory: factory, dataArea: .replace(records), credentials: InMemoryTagCredentialStore(),
            protection: armingProtection(), uidConfirmation: .required
        )

        let run = Task { await model.begin() }
        await until { factory.isWaiting }
        model.reset()
        factory.release()
        await run.value

        XCTAssertEqual(model.phase, .ready, "a cancelled run leaves no error card behind a dismissed sheet")
        XCTAssertEqual(factory.sessionsStarted, 1, "and never opens the write tap")
        XCTAssertEqual(try? chip.readProtectionState()?.passwordProtect, false)
        XCTAssertTrue(try NDEFCodec.isEmptyMessage(chip.readNDEF()))
    }

    /// The same cancel once the reader session exists. CoreNFC ends a polling
    /// session that is invalidated in a cancel, so this time the run's catch
    /// sees an error, and a run the user has already walked away from must end
    /// quietly rather than leave an error card on a dismissed sheet.
    func test_cancellingWhileTheIdentifyTapIsPolling_endsQuietly() async throws {
        let chip = NTAG215Simulator()
        let factory = BlockingFactory(chip: chip, cancelsOnInvalidate: true)
        let model = WriteFlowModel(
            factory: factory, dataArea: .replace(records), credentials: InMemoryTagCredentialStore(),
            protection: armingProtection(), uidConfirmation: .required
        )

        let run = Task { await model.begin() }
        await until { factory.isWaiting }
        model.reset()
        // `reset()` invalidates from a task of its own; let that land first, so
        // the session ends in a cancel rather than handing up the tag.
        await until { factory.anySessionInvalidated }
        factory.release()
        await run.value

        XCTAssertEqual(model.phase, .ready, "a cancel the user asked for is not an error")
        XCTAssertEqual(factory.sessionsStarted, 1, "and the write tap never opens")
        XCTAssertEqual(try? chip.readProtectionState()?.passwordProtect, false)
        XCTAssertTrue(try NDEFCodec.isEmptyMessage(chip.readNDEF()))
    }

    /// The identify tap says it is reading the tag, so it must not write. On a
    /// SLIX2 the protection state is established by *attempting a write*
    /// (`Iso15693ProtectionClient.mayProbeByWriting`), which is the one family
    /// where "read-only" needed an argument rather than an assertion.
    func test_theIdentifyTapDoesNotProbeASlixByWriting() async {
        // 80 blocks is the SLIX2, the one Type-5 profile this app offers
        // protection for.
        let chip = Iso15693Simulator(blockCount: 80)
        let faults = FaultInjectingSessionFactory(chip: chip)
        let model = WriteFlowModel(
            factory: faults, dataArea: .replace(records), credentials: InMemoryTagCredentialStore(),
            protection: PendingProtection(
                settings: TagProtection(passwordProtect: true, style: .type5(.init(kind: .write))),
                credential: .type5(password: password, kind: .write)
            ),
            uidConfirmation: .required
        )

        let before = model.transitionCount
        let run = Task { await model.begin() }
        await untilSettled(model, after: before)
        let identifyTap = faults.report.frames(inTap: faults.tapCount)
        model.reset()
        await run.value

        // The frames a SLIX2 probe would use to establish protection by writing:
        // a block write, and the password commands that precede one.
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

    // MARK: - What the extra tap costs a limited tag

    /// One password frame per activation, and the identify tap spends no more
    /// than the single-tap write did.
    ///
    /// The tag has an attempt limit, where a wasted try is not recoverable. A
    /// wrong held password is refused on tap 1, the run stops there, and the
    /// refusal is the last frame of that activation.
    func test_aWrongHeldPasswordOnALimitedTag_spendsExactlyOneTryAndStops() async throws {
        let chip = NTAG213Simulator()
        try chip.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 3
        )
        let faults = FaultInjectingSessionFactory(chip: chip)
        let model = WriteFlowModel(
            factory: faults, dataArea: .replace(records), credentials: InMemoryTagCredentialStore(),
            unlockCredential: .type2(password: Data([0x00, 0x00, 0x00, 0x01]), pack: Data()),
            removeProtection: true, uidConfirmation: .required
        )

        await model.begin()

        XCTAssertEqual(model.phase, .needsUnlock, "expected the prompt, got \(model.phase)")
        let passwordFrames = faults.report.frames(matching: .opcode(Type2PasswordDriver.pwdAuth))
        XCTAssertEqual(passwordFrames.count, 1, "one authentication attempt per activation")
        let tap = faults.report.frames(inTap: faults.tapCount)
        XCTAssertEqual(
            tap.last?.request.first, Type2PasswordDriver.pwdAuth,
            "nothing is sent to a chip the refusal has halted"
        )
    }

    // MARK: A refused credential ends the tap, limit or no limit

    /// The 2026-09-21 defect. The early exit keyed on the attempt limit, and
    /// `ProtectionSpec.make` forces `authLimit: 0` on every tag this app arms,
    /// so on the ordinary armed tag it never fired: the flow went on to read a
    /// chip the NAK had already returned to HALT. Measured on silicon as
    /// `READ p3` at 13:35:00.793, 13:35:01.105 and 13:35:01.418, all failing.
    ///
    /// The sibling above covers the limited tag, which the old predicate did
    /// catch. This is the same assertion about the tag it did not.
    func test_aRefusedPasswordOnAnUnlimitedTagStopsTheTapImmediately() async throws {
        let chip = NTAG213Simulator()
        try chip.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let faults = FaultInjectingSessionFactory(chip: chip)
        let model = WriteFlowModel(
            factory: faults, dataArea: .replace(records), credentials: InMemoryTagCredentialStore(),
            unlockCredential: .type2(password: Data([0x00, 0x00, 0x00, 0x01]), pack: Data()),
            removeProtection: true, uidConfirmation: .required
        )

        await model.begin()

        XCTAssertEqual(model.phase, .needsUnlock, "expected the prompt, got \(model.phase)")
        XCTAssertEqual(
            faults.report.frames(matching: .opcode(Type2PasswordDriver.pwdAuth)).count, 1,
            "one authentication attempt per activation, on a tag with no limit too"
        )
        let tap = faults.report.frames(inTap: faults.tapCount)
        XCTAssertEqual(
            tap.last?.request.first, Type2PasswordDriver.pwdAuth,
            "nothing is sent to a chip the refusal has halted"
        )
    }

    /// The other half of the same defect. The driver composes copy for this
    /// refusal and the flow used to throw it away, so the prompt fell back to
    /// "That password didn't unlock the tag." about a tap that had established
    /// no such thing.
    func test_theDriversRefusalReachesTheUnlockPrompt() async throws {
        let chip = NTAG213Simulator()
        try chip.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let model = WriteFlowModel(
            factory: FaultInjectingSessionFactory(chip: chip), dataArea: .replace(records),
            credentials: InMemoryTagCredentialStore(),
            unlockCredential: .type2(password: Data([0x00, 0x00, 0x00, 0x01]), pack: Data()),
            removeProtection: true, uidConfirmation: .required
        )

        await model.begin()

        XCTAssertEqual(model.phase, .needsUnlock)
        XCTAssertTrue(model.unlockFailed)
        XCTAssertNotNil(
            model.unlockRefusal,
            "the refusal this tap produced is what the prompt has to say something about"
        )
    }

    /// The boundary the widened predicate must not cross.
    ///
    /// `TagError.readProtected` wears `.authFailed` so the existing protection
    /// classification keeps matching, but it is thrown before any
    /// authentication: the state read itself was refused. It carries
    /// `presentedACredential: false`, so it keeps the state-read route and the
    /// flow still reaches the prompt by way of `ProtectionProbe`.
    func test_aReadProtectedTagStillTakesTheStateReadRoute() async throws {
        let chip = NTAG213Simulator()
        try chip.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: true, authLimit: 0
        )
        let model = WriteFlowModel(
            factory: FaultInjectingSessionFactory(chip: chip), dataArea: .replace(records),
            credentials: InMemoryTagCredentialStore(),
            unlockCredential: nil,
            removeProtection: true, uidConfirmation: .required
        )

        await model.begin()

        XCTAssertEqual(model.phase, .needsUnlock, "a read-gated tag asks for its password")
        XCTAssertFalse(
            model.unlockFailed,
            "nothing was presented, so nothing failed: the first-run copy is the right copy"
        )
    }
}
