@testable import HexNFCKit
@testable import HexNFCRecords
@testable import HexNFCTagSim
import XCTest

/// The abort-point suite for the ICODE SLIX2 protection client.
///
/// One test per place the `enable` / `disable` sequences can tear, driving the
/// **shipped** `Iso15693ProtectionClient` against `Iso15693Simulator` through a
/// frame-recording (and sometimes frame-substituting) transceive closure, so
/// what is asserted is the sequence production actually sends.
///
/// The governing constraint behind every one of them, SL2S2602 rev 4.2
/// §9.5.3.2: "If the IC receives an invalid password, it will not execute any
/// following command until a Power-On Reset." One wrong candidate ends the
/// activation, so no sequence here may present a second one in the same tap and
/// no error path may retry a password.
final class Iso15693OrderingTests: XCTestCase {
    private let oldPw = Data([0x11, 0x22, 0x33, 0x44])
    private let newPw = Data([0xDE, 0xAD, 0xBE, 0xEF])
    private let factory = Iso15693Passwords.factoryReadWrite

    /// Records every frame the client puts on the air, and can substitute the
    /// answer to a chosen frame (with or without letting it reach the chip).
    private final class Wire: @unchecked Sendable {
        private(set) var frames: [Data] = []
        var substitute: (@Sendable (Data, Int) -> Data?)?
        /// Frames whose substituted answer must NOT reach the simulator.
        var block: (@Sendable (Data, Int) -> Bool)?
        private let tag: ConnectedTag
        private var count = 0

        init(tag: ConnectedTag) {
            self.tag = tag
        }

        func client() -> Iso15693ProtectionClient {
            Iso15693ProtectionClient(transceive: { [self] command in
                let bytes = command.bytes
                frames.append(bytes)
                let index = count
                count += 1
                let blocked = block?(bytes, index) ?? false
                let faked = substitute?(bytes, index)
                if blocked {
                    guard let faked else { return Data() }
                    return faked
                }
                let real = try await tag.transceive(command)
                return faked ?? real
            })
        }

        var opcodes: [UInt8] {
            frames.map { $0[$0.startIndex + 1] }
        }

        func indices(ofOpcode opcode: UInt8) -> [Int] {
            frames.enumerated().compactMap { $0.element[$0.element.startIndex + 1] == opcode ? $0.offset : nil }
        }

        /// Frames that are a `SET_PASSWORD` for `kind` carrying `password`,
        /// unmasked with the simulator's deterministic nonce.
        func setPasswordIndices(kind: UInt8, password: Data) -> [Int] {
            frames.enumerated().compactMap { offset, frame in
                guard frame.count >= 7, frame[frame.startIndex + 1] == 0xB3,
                      frame[frame.startIndex + 2] == kind
                else { return nil }
                let xored = frame.subdata(in: (frame.startIndex + 3) ..< (frame.startIndex + 7))
                let mask = Data([0xC0, 0xDE, 0xC0, 0xDE])
                return NTAG424Crypto.xor(xored, mask) == password ? offset : nil
            }
        }
    }

    private func makeWire(_ sim: Iso15693Simulator) async throws -> Wire {
        try await Wire(tag: SimulatedSession(chip: sim).start(alert: ""))
    }

    // MARK: - enable

    /// The incident class starts with authenticating against a belief instead of
    /// a read. Nothing may be presented before the chip has been asked what it
    /// is gating, because a wrong guess costs the whole activation.
    func test_enable_readsTheGateBeforePresentingAnyPassword() async throws {
        let sim = Iso15693Simulator.slix2()
        let wire = try await makeWire(sim)
        try await wire.client().enable(writePassword: newPw, readPassword: nil)

        XCTAssertEqual(wire.opcodes.first, Iso15693Opcode.getNXPSystemInformation)
        let firstStatus = try XCTUnwrap(wire.indices(ofOpcode: Iso15693Opcode.getNXPSystemInformation).first)
        let firstPresent = wire.indices(ofOpcode: Iso15693Opcode.setPassword).first ?? Int.max
        XCTAssertLessThan(firstStatus, firstPresent, "the state read must precede every SET_PASSWORD")
    }

    /// The credential goes down and is proven before the gate goes up, so an
    /// abort between the two leaves an open tag rather than one gated behind a
    /// password nothing can establish.
    func test_enable_provesTheNewPasswordBeforeArmingTheGate() async throws {
        let sim = Iso15693Simulator.slix2()
        let wire = try await makeWire(sim)
        try await wire.client().enable(writePassword: newPw, readPassword: nil)

        let proof = try XCTUnwrap(wire.setPasswordIndices(kind: 0x02, password: newPw).first)
        let arm = try XCTUnwrap(wire.indices(ofOpcode: Iso15693Opcode.protectPage).last)
        XCTAssertLessThan(proof, arm, "the new password must be proven before PROTECT PAGE arms anything")
        XCTAssertEqual(sim.pageProtection, 0x20)
        XCTAssertEqual(sim.passwords[.write], newPw)
    }

    /// The house rule, on the one chip where it is cheap: disarm the gate before
    /// rewriting the credential. An abort in the middle then leaves a Public tag
    /// holding one of two known passwords, and a tag anyone can write is a tag
    /// anyone can repair.
    func test_enable_disarmsTheGateBeforeRewritingTheCredential() async throws {
        let sim = Iso15693Simulator.slix2()
        let first = try await makeWire(sim)
        try await first.client().enable(writePassword: oldPw, readPassword: nil)
        sim.beginActivation()

        let second = try await makeWire(sim)
        try await second.client().enable(
            writePassword: newPw, readPassword: nil, currentWritePassword: oldPw
        )

        let protectFrames = second.indices(ofOpcode: Iso15693Opcode.protectPage)
        let write = try XCTUnwrap(second.indices(ofOpcode: Iso15693Opcode.writePassword).first)
        let disarm = try XCTUnwrap(protectFrames.first)
        XCTAssertLessThan(disarm, write, "PROTECT PAGE 00h must precede the credential rewrite")
        XCTAssertEqual(second.frames[disarm].last, 0x00, "the first PROTECT PAGE must clear the conditions")
        XCTAssertEqual(sim.pageProtection, 0x20, "and the run must still end armed")
        XCTAssertEqual(sim.passwords[.write], newPw)
    }

    /// The A4/A6 abort, recovered in exactly one tap. The tag holds the new
    /// password; the app's next attempt presents it and finishes the job.
    func test_enable_afterAWritePasswordAbort_secondTapFinishesWithTheNewValue() async throws {
        let sim = Iso15693Simulator.slix2()
        let wire = try await makeWire(sim)
        final class Box: @unchecked Sendable { var sawWrite = false }
        let box = Box()
        wire.block = { bytes, _ in
            // Everything after the WRITE_PASSWORD is lost.
            if box.sawWrite {
                return true
            }
            if bytes[bytes.startIndex + 1] == Iso15693Opcode.writePassword {
                box.sawWrite = true
            }
            return false
        }
        wire.substitute = { bytes, _ in
            box.sawWrite && bytes[bytes.startIndex + 1] != Iso15693Opcode.writePassword
                ? Data() // silence, which the client must not read as a refusal
                : nil
        }
        do {
            try await wire.client().enable(writePassword: newPw, readPassword: nil)
            XCTFail("an abort after WRITE_PASSWORD must not report success")
        } catch is TagError {}

        XCTAssertEqual(sim.passwords[.write], newPw, "the write did land before the tear")
        XCTAssertEqual(sim.pageProtection, 0, "and nothing was armed, so the tag is still writable")

        // Next tap: the app leads with the value it was writing, and finishes.
        sim.beginActivation()
        let second = try await makeWire(sim)
        try await second.client().enable(
            writePassword: newPw, readPassword: nil, currentWritePassword: newPw
        )
        XCTAssertEqual(sim.pageProtection, 0x20)
    }

    /// The Type-5 twin of the Type-2 and Ultralight C AUTH0 aborts, and it is the
    /// worst-placed of the three: `PROTECT PAGE` is the command that arms the
    /// gate, and the write password has already landed and been proven above it.
    ///
    /// It was a bare `try`, so §9.6's generic refusal reached the owner as "The
    /// tag responded outside the expected protocol" with no residue at all,
    /// about a tag now holding a password they were being given no reason to
    /// keep. The report has to say the password landed and say what the gate is
    /// doing, and here the chip is still answering, so the gate can be read
    /// rather than guessed.
    func test_enable_aRefusedProtectPage_reportsThePasswordAsLandedAndReadsTheGate() async throws {
        let sim = Iso15693Simulator.slix2()
        let faults = FaultInjectingSessionFactory(chip: sim)
        faults.arm(TagFault(
            .predicate("PROTECT PAGE") { frame in
                frame.count > 1 && frame[frame.startIndex + 1] == Iso15693Opcode.protectPage
            },
            // §9.6 gives this silicon one refusal code for everything, so this is
            // the only refusal a test may put in its mouth.
            .refused(response: Data([0x01, 0x0F]), halts: false)
        ))
        let tag = try await faults.makeSession().start(alert: "")
        let client = Iso15693ProtectionClient(transceive: { try await tag.transceive($0) })

        do {
            try await client.enable(writePassword: newPw, readPassword: nil)
            XCTFail("a refused PROTECT PAGE must not report success")
        } catch let error as TagError {
            guard case .protectionIncomplete(let residue) = error.kind else {
                return XCTFail("expected .protectionIncomplete, got \(error.kind)")
            }
            XCTAssertEqual(residue.credential, .callerSupplied, "the password is on the tag")
            XCTAssertEqual(residue.gate, .provenOpen, "and the chip was asked what it is gating")
            XCTAssertTrue(residue.completed.contains(.gateProven))
            XCTAssertTrue(residue.failures.contains { $0.step == .gateArmed })
            XCTAssertEqual(
                String(localized: error.userMessage),
                String(localized: ProtectionResidue(
                    family: .type5, intent: .enable, gate: .provenOpen, credential: .callerSupplied
                ).userMessage)
            )
            XCTAssertNotEqual(
                String(localized: error.userMessage),
                String(localized: TagError.protocolError("").userMessage),
                "a transport sentence tells the owner nothing about the password their tag now holds"
            )
            XCTAssertFalse(
                error.diagnostics.contains(newPw.hexString),
                "a diagnostics string is written to be pasted into a bug report and may never carry a password"
            )
        }

        // Both halves of what the residue said, checked against the tag.
        XCTAssertEqual(sim.passwords[.write], newPw, "the credential really did land")
        XCTAssertEqual(sim.pageProtection, 0, "and nothing armed, so the next tap can finish the job")
    }

    /// The read-back that contradicts the arm, which is the whole reason the
    /// read-back exists: "an ACK is not proof". `PROTECT PAGE` answered `00` and
    /// the chip then reported Public.
    ///
    /// It used to throw a bare `verificationFailed`, whose sentence is "The tag
    /// wrote back something different from what was sent. Try the write again."
    /// On a tag holding the caller's brand-new write password, that is an
    /// instruction to discard a credential the tag is enforcing with, and it
    /// threw away the residue that recorded the password as written.
    ///
    /// The `00` answer here is substituted rather than provoked: the simulator
    /// commits what it acknowledges, and no capture in this repo shows SLIX2
    /// doing otherwise. What is under test is the report, not a claim about the
    /// silicon.
    func test_enable_aProtectPageReadBackMismatch_carriesTheResidueNotATryAgain() async throws {
        let sim = Iso15693Simulator.slix2()
        let wire = try await makeWire(sim)
        final class Box: @unchecked Sendable { var armed = false }
        let box = Box()
        wire.substitute = { bytes, _ in
            let opcode = bytes[bytes.startIndex + 1]
            if opcode == Iso15693Opcode.protectPage {
                box.armed = true
                return nil
            }
            guard opcode == Iso15693Opcode.getNXPSystemInformation, box.armed else { return nil }
            // Table 71: `00 ‖ pointer ‖ conditions ‖ lock bits ‖ feature flags`,
            // reporting the conditions the tag had before the arm.
            return Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        }

        do {
            try await wire.client().enable(writePassword: newPw, readPassword: nil)
            XCTFail("a read-back that contradicts the arm is not a success")
        } catch let error as TagError {
            guard case .protectionIncomplete(let residue) = error.kind else {
                return XCTFail("expected .protectionIncomplete, got \(error.kind)")
            }
            XCTAssertEqual(residue.credential, .callerSupplied, "which is the fact the old throw discarded")
            XCTAssertEqual(residue.gate, .unknown)
            XCTAssertTrue(residue.failures.contains { $0.step == .gateProven })
            XCTAssertEqual(
                String(localized: error.userMessage),
                String(localized: ProtectionResidue(
                    family: .type5, intent: .enable, gate: .unknown, credential: .callerSupplied
                ).userMessage)
            )
            XCTAssertNotEqual(
                String(localized: error.userMessage),
                String(localized: TagError.verificationFailed(diff: Data()).userMessage),
                "telling this owner to try the write again is telling them to discard a live credential"
            )
        }

        XCTAssertTrue(box.armed, "the arming PROTECT PAGE must actually have gone out")
        XCTAssertEqual(sim.passwords[.write], newPw)
        XCTAssertEqual(sim.pageProtection, 0x20, "and the tag really is armed, whatever it answered")
    }

    // MARK: - the lost-ACK rule

    /// §9.6 gives this silicon one refusal code for everything, and 2026-08-09
    /// caught a write-alike command answering it after the write had landed. So
    /// a refused `WRITE_PASSWORD` is a question, not a verdict, and the probe
    /// re-presents the **old** value: presenting the new one when the write did
    /// not land would kill the tap for nothing.
    func test_writePassword_lostAck_isResolvedByRepresentingTheOldValue() async throws {
        let sim = Iso15693Simulator.slix2()
        let wire = try await makeWire(sim)
        // The write reaches the chip; only the answer is lost.
        wire.substitute = { bytes, _ in
            bytes[bytes.startIndex + 1] == Iso15693Opcode.writePassword ? Data([0x01, 0x0F]) : nil
        }
        do {
            try await wire.client().enable(writePassword: newPw, readPassword: nil)
            XCTFail("an undetermined credential must not be reported as armed")
        } catch let error as TagError {
            guard case .protectionIncomplete(let residue) = error.kind else {
                return XCTFail("expected .protectionIncomplete, got \(error.kind)")
            }
            XCTAssertFalse(residue.metItsGoal)
            if case .unknown = residue.credential {} else {
                XCTFail("the credential is genuinely undetermined, got \(residue.credential)")
            }
            // And the sentence agrees with the verdict beside it. This used to
            // read "The password was saved to the tag, but protection did not
            // switch on", which is a claim about a credential the same object
            // had just called undetermined.
            XCTAssertEqual(residue.gate, .provenOpen, "the pre-arm read said Public, and nothing armed")
            XCTAssertEqual(
                String(localized: error.userMessage),
                String(localized: ProtectionResidue(
                    family: .type5, intent: .enable,
                    gate: .provenOpen, credential: .unknown(reason: "")
                ).userMessage)
            )
            XCTAssertNotEqual(
                String(localized: error.userMessage),
                String(localized: ProtectionResidue(
                    family: .type5, intent: .enable,
                    gate: .provenOpen, credential: .callerSupplied
                ).userMessage)
            )
        }

        let write = try XCTUnwrap(wire.indices(ofOpcode: Iso15693Opcode.writePassword).first)
        let probe = try XCTUnwrap(wire.setPasswordIndices(kind: 0x02, password: factory).last)
        XCTAssertGreaterThan(probe, write, "the disambiguation probe follows the refused write")
        XCTAssertTrue(
            wire.setPasswordIndices(kind: 0x02, password: newPw).allSatisfy { $0 < write },
            "the probe must never present the NEW value: that is an invalid password if the write was lost"
        )
        XCTAssertEqual(sim.passwords[.write], newPw, "the write had in fact landed")
    }

    /// The other shape: the frame never reached the tag. The old value still
    /// authenticates, which proves nothing changed, so the tap is still alive and
    /// earns exactly one retry.
    func test_writePassword_genuineRefusal_leavesTheTagUnchangedAndTheTapAlive() async throws {
        let sim = Iso15693Simulator.slix2()
        let wire = try await makeWire(sim)
        wire.block = { bytes, _ in bytes[bytes.startIndex + 1] == Iso15693Opcode.writePassword }
        wire.substitute = { bytes, _ in
            bytes[bytes.startIndex + 1] == Iso15693Opcode.writePassword ? Data([0x01, 0x0F]) : nil
        }
        do {
            try await wire.client().enable(writePassword: newPw, readPassword: nil)
            XCTFail("a genuinely refused credential write must not report success")
        } catch let error as TagError {
            guard case .protectionIncomplete = error.kind else {
                return XCTFail("expected .protectionIncomplete, got \(error.kind)")
            }
        }
        XCTAssertEqual(
            wire.indices(ofOpcode: Iso15693Opcode.writePassword).count, 2,
            "exactly one retry, never a loop"
        )
        XCTAssertEqual(sim.passwords[.write], factory, "the tag is untouched")
        XCTAssertFalse(sim.poisoned, "no wrong password was ever presented, so the tap is still alive")
    }

    // MARK: - disable

    /// Presenting a password to a tag that is not gated is the violation that
    /// costs an activation when the guess is wrong, and there was nothing to
    /// remove in the first place.
    func test_disable_onAnUnprotectedTag_presentsNoPasswordAtAll() async throws {
        let sim = Iso15693Simulator.slix2()
        let wire = try await makeWire(sim)
        let residue = try await wire.client().disable(currentWritePassword: oldPw)

        XCTAssertEqual(residue.gate, .provenOpen)
        XCTAssertTrue(residue.metItsGoal)
        XCTAssertTrue(wire.indices(ofOpcode: Iso15693Opcode.setPassword).isEmpty, "no password presented")
        XCTAssertTrue(wire.indices(ofOpcode: Iso15693Opcode.protectPage).isEmpty, "nothing written")
    }

    /// The 2026-09-04 incident, transplanted. A removal whose gate came down is a
    /// **success**; the credential tidy-up that follows is residue and may never
    /// turn it into a reported failure.
    func test_disable_reportsSuccessWhenTheGateIsDownEvenIfTheCredentialResetFails() async throws {
        let sim = Iso15693Simulator.slix2()
        let arm = try await makeWire(sim)
        try await arm.client().enable(writePassword: oldPw, readPassword: nil)
        sim.beginActivation()

        let wire = try await makeWire(sim)
        wire.block = { bytes, _ in bytes[bytes.startIndex + 1] == Iso15693Opcode.writePassword }
        wire.substitute = { bytes, _ in
            bytes[bytes.startIndex + 1] == Iso15693Opcode.writePassword ? Data([0x01, 0x0F]) : nil
        }
        let residue = try await wire.client().disable(currentWritePassword: oldPw)

        XCTAssertEqual(residue.gate, .provenOpen, "the chip said the conditions are Public")
        XCTAssertTrue(residue.metItsGoal, "a removal that opened the gate is not a failure")
        XCTAssertFalse(residue.isComplete, "and the failed password reset is reported as residue")
        XCTAssertEqual(residue.credential, .unchanged, "so the caller keeps the old password")
        XCTAssertEqual(sim.pageProtection, 0)
        XCTAssertEqual(sim.passwords[.write], oldPw)
    }

    /// The closing-the-door test. Removal restores the **datasheet** factory
    /// value (§9.2.3), which is exactly what `enable` presents by default, so
    /// protect, remove, protect closes. It could not before: removal wrote an
    /// invented `FF FF FF FF` and the next protect presented `00 00 00 00`,
    /// which §9.5.3.2 answers by refusing every following command in the tap.
    func test_disable_restoresTheFactoryWritePassword_soReprotectSucceeds() async throws {
        let sim = Iso15693Simulator.slix2()
        let arm = try await makeWire(sim)
        try await arm.client().enable(writePassword: oldPw, readPassword: nil)
        sim.beginActivation()

        let remove = try await makeWire(sim)
        let residue = try await remove.client().disable(currentWritePassword: oldPw)
        XCTAssertEqual(residue.credential, .factoryDefault)
        XCTAssertEqual(sim.passwords[.write], Iso15693Passwords.factoryReadWrite)
        sim.beginActivation()

        // The whole point: a second protect, with no credential in hand, works.
        let again = try await makeWire(sim)
        try await again.client().enable(writePassword: newPw, readPassword: nil)
        XCTAssertEqual(sim.pageProtection, 0x20)
        XCTAssertEqual(sim.passwords[.write], newPw)
        XCTAssertFalse(sim.poisoned)
    }

    /// Guards the deleted bug: removal used to present the **write** password to
    /// the **privacy** slot. §9.2.3 gives the two slots different factory values,
    /// so that was a guaranteed invalid password on any tag whose passwords
    /// differ, and §9.5.3.2 makes an invalid password end the activation.
    func test_disable_neverPresentsTheWritePasswordToThePrivacySlot() async throws {
        let sim = Iso15693Simulator.slix2()
        let arm = try await makeWire(sim)
        try await arm.client().enable(writePassword: oldPw, readPassword: nil)
        sim.beginActivation()

        let wire = try await makeWire(sim)
        let residue = try await wire.client().disable(currentWritePassword: oldPw, hadReadProtect: true)

        XCTAssertTrue(residue.metItsGoal)
        XCTAssertTrue(
            wire.setPasswordIndices(kind: 0x04, password: oldPw).isEmpty,
            "the write password must never be presented to the privacy identifier"
        )
        XCTAssertFalse(sim.poisoned, "and the tap must survive")
        XCTAssertFalse(residue.isComplete, "the untouched privacy slot is reported instead")
    }

    /// Within an activation that has authenticated, a write is accepted whether
    /// or not the gate is down, so a write probe here is a false green. The proof
    /// has to be the chip's own status command.
    func test_disable_verificationUsesTheChipStatusNotAWriteProbe() async throws {
        let sim = Iso15693Simulator.slix2()
        let arm = try await makeWire(sim)
        try await arm.client().enable(writePassword: oldPw, readPassword: nil)
        sim.beginActivation()

        let wire = try await makeWire(sim)
        try await wire.client().disable(currentWritePassword: oldPw)

        let disarm = try XCTUnwrap(wire.indices(ofOpcode: Iso15693Opcode.protectPage).last)
        let proof = try XCTUnwrap(
            wire.indices(ofOpcode: Iso15693Opcode.getNXPSystemInformation).first { $0 > disarm }
        )
        XCTAssertGreaterThan(proof, disarm)
        XCTAssertTrue(
            wire.indices(ofOpcode: Iso15693Opcode.writeSingleBlock).isEmpty,
            "a removal must not probe with a write"
        )
    }

    /// The chip's own account is consulted, and no write is put on the air, by a
    /// call whose contract is to read.
    func test_readProtectionState_isNonMutating_whenTheChipAnswersItsStatusCommand() async throws {
        let sim = Iso15693Simulator.slix2()
        let arm = try await makeWire(sim)
        try await arm.client().enable(writePassword: oldPw, readPassword: nil)
        sim.beginActivation()
        let writesBefore = sim.acceptedWrites

        let wire = try await makeWire(sim)
        let state = try await wire.client().readProtectionState()

        XCTAssertEqual(state?.passwordProtect, true)
        XCTAssertEqual(sim.acceptedWrites, writesBefore, "a state read must put no write on the air")
        XCTAssertTrue(wire.indices(ofOpcode: Iso15693Opcode.writeSingleBlock).isEmpty)
    }

    /// A plain 28-block ICODE gets no write put on the air by a scan.
    ///
    /// The live case, 2026-09-09: `E0:04:01:53:16:6A:F8:A2` left `02 AB`
    /// unanswered, so `readProtectionState` fell through to the behavioural
    /// probe and sent `21h`, writing block 1 back its own bytes. Content
    /// neutral, and still a write on a call whose contract is to read, spent
    /// answering a question about a feature this app will never offer that
    /// chip: only `.icodeSlix2` carries `.passwordAuth`.
    ///
    /// `nil`, not `TagProtection.none`. Nothing was probed, so the honest answer
    /// is that we cannot tell, and the two are different facts everywhere else
    /// in this codebase.
    func test_readProtectionState_onAPlainIcode_probesNothingAndPutsNoWriteOnTheAir() async throws {
        let sim = Iso15693Simulator()
        XCTAssertFalse(
            sim.answersNXPSystemInformation,
            "the premise: this geometry does not account for itself"
        )
        let tag = try await SimulatedSession(chip: sim).start(alert: "")
        let writesBefore = sim.acceptedWrites

        let state = try await tag.readProtectionState()

        XCTAssertNil(state, "no reading was taken, so no verdict may be reported")
        XCTAssertEqual(sim.acceptedWrites, writesBefore, "a scan must put no write on the air")
    }

    /// The fallback still works where it is permitted, so the gate is a gate and
    /// not a deletion. Driven through the client directly, because the only
    /// profile that permits it is the one geometry that answers `ABh` and so
    /// never reaches the fallback in production.
    func test_theWriteProbeStillRunsWhenTheCallerPermitsIt() async throws {
        let sim = Iso15693Simulator()
        let tag = try await SimulatedSession(chip: sim).start(alert: "")
        let permitted = Iso15693ProtectionClient(
            transceive: { try await tag.transceive($0) }, mayProbeByWriting: true
        )
        let writesBefore = sim.acceptedWrites

        let state = try await permitted.readProtectionState()

        XCTAssertEqual(state, TagProtection.none, "it probed, and found nothing gating")
        XCTAssertGreaterThan(sim.acceptedWrites, writesBefore, "the probe is a write, by construction")
    }

    /// A reading that a later command invalidated is not a reading.
    ///
    /// The state read at the top of `enable` sets `gate = .provenOpen` on a tag
    /// that answers Public, which is true when it is taken. `PROTECT PAGE` then
    /// goes out, and a chip that will not answer ABh afterwards leaves
    /// `verifyPageProtection` with nothing to say. That stale `.provenOpen` used
    /// to survive into the final residue, so a protect whose gate was never
    /// witnessed reported "protection did not switch on" as a certainty.
    func test_enable_whenTheArmIsNeverWitnessed_reportsAnUnknownGateNotTheStalePreArmRead() async throws {
        let sim = Iso15693Simulator.slix2()
        let wire = try await makeWire(sim)
        final class Box: @unchecked Sendable { var armed = false }
        let box = Box()
        wire.substitute = { bytes, _ in
            let opcode = bytes[bytes.startIndex + 1]
            if opcode == Iso15693Opcode.protectPage {
                box.armed = true
                return nil
            }
            // The chip stops answering its own status command once the gate is
            // armed, which is the one shape `verifyPageProtection` tolerates.
            return opcode == Iso15693Opcode.getNXPSystemInformation && box.armed ? Data([0x01, 0x0F]) : nil
        }

        let residue = try await wire.client().enable(writePassword: newPw, readPassword: nil)

        XCTAssertTrue(box.armed, "the arming PROTECT PAGE must actually have gone out")
        XCTAssertEqual(residue.gate, .unknown, "the pre-arm read is spent, and nothing witnessed the arm")
        XCTAssertTrue(residue.failures.contains { $0.step == .gateProven })
        XCTAssertEqual(
            String(localized: residue.userMessage),
            String(localized: ProtectionResidue(
                family: .type5, intent: .enable, gate: .unknown, credential: .callerSupplied
            ).userMessage)
        )
        XCTAssertNotEqual(
            String(localized: residue.userMessage),
            String(localized: ProtectionResidue(
                family: .type5, intent: .enable, gate: .provenOpen, credential: .callerSupplied
            ).userMessage),
            "which is the sentence the stale verdict produced"
        )
        XCTAssertEqual(sim.pageProtection, 0x20, "and the tag really is armed")
    }

    /// The lock-bits byte is read back and recorded, and deliberately does not
    /// refuse anything: the bit-3 assignment is not verified against Table 71,
    /// and refusing on an unverified bit would deny a legitimate protect.
    func test_enable_recordsAPageProtectionConditionLock_butDoesNotRefuseOnIt() async throws {
        let sim = Iso15693Simulator.slix2()
        sim.pageProtectionConditionLocked = true
        let wire = try await makeWire(sim)
        let residue = try await wire.client().enable(writePassword: newPw, readPassword: nil)

        XCTAssertTrue(residue.metItsGoal, "an unverified bit may not fail a protect that worked")
        XCTAssertTrue(
            residue.failures.contains { $0.step == .stateRead },
            "but it must be recorded: \(residue.diagnostics)"
        )
    }
}
