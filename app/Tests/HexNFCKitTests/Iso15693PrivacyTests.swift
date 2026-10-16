@testable import HexNFCKit
@testable import HexNFCRecords
@testable import HexNFCTagSim
import XCTest

/// ICODE privacy mode: the one-way door, the honest exit, and the structural
/// gate that keeps the ordinary write path away from both.
///
/// SL2S2602 rev 4.2 §9.5.3.9: a privacy-mode label "does not respond to any
/// command except GET RANDOM NUMBER and SET PASSWORD", and cannot be
/// inventoried. iOS only ever hands an app an `NFCISO15693Tag` that nfcd has
/// already inventoried, and Addressed mode is closed on both CoreNFC APIs
/// (live-confirmed 2026-08-07, `docs/internal/chip-config-pages.md`). So no
/// iPhone can discover such a tag and this app can never send it anything: the
/// exit route below is exercised here and inside the activation that arms
/// privacy, and **nowhere else**. None of it has run on silicon.
final class Iso15693PrivacyTests: XCTestCase {
    private let privacyPw = Data([0xA1, 0xB2, 0xC3, 0xD4])

    private final class Wire: @unchecked Sendable {
        private(set) var frames: [Data] = []
        /// Answer this frame with something other than what the chip would say.
        var substitute: (@Sendable (Data) -> Data?)?
        /// Keep this frame off the chip. With no `substitute` the caller sees
        /// silence, which the transport surfaces as a lost tag.
        var block: (@Sendable (Data) -> Bool)?
        private let tag: ConnectedTag

        init(tag: ConnectedTag) {
            self.tag = tag
        }

        func client() -> Iso15693ProtectionClient {
            Iso15693ProtectionClient(transceive: { [self] command in
                frames.append(command.bytes)
                let faked = substitute?(command.bytes)
                if block?(command.bytes) == true {
                    guard let faked else {
                        throw TagError.tagLost(diagnostics: "substituted silence")
                    }
                    return faked
                }
                let real = try await tag.transceive(command)
                return faked ?? real
            })
        }
    }

    private func makeWire(_ sim: Iso15693Simulator) async throws -> Wire {
        try await Wire(tag: SimulatedSession(chip: sim).start(alert: ""))
    }

    private func isPrivacySetPassword(_ frame: Data) -> Bool {
        frame.count >= 3
            && frame[frame.startIndex + 1] == Iso15693Opcode.setPassword
            && frame[frame.startIndex + 2] == 0x04
    }

    // MARK: - The structural gate

    /// Arming a door this app cannot open must be a deliberate act, never a
    /// settings-card default. The refusal comes before anything is written.
    func test_enable_refusesToArmPrivacyWithoutTheOptIn() async throws {
        let sim = Iso15693Simulator.slix2()
        let wire = try await makeWire(sim)
        do {
            try await wire.client().enable(writePassword: nil, readPassword: privacyPw)
            XCTFail("privacy must not be reachable from an ordinary protect")
        } catch let error as TagError {
            guard case .capabilityUnsupported = error.kind else {
                return XCTFail("expected .capabilityUnsupported, got \(error.kind)")
            }
        }
        XCTAssertFalse(sim.privacyMode)
        XCTAssertTrue(wire.frames.isEmpty, "the refusal must precede every frame")
    }

    func test_enable_withTheOptIn_armsPrivacyAndWriteProtectionTogether() async throws {
        let sim = Iso15693Simulator.slix2()
        let wire = try await makeWire(sim)
        try await wire.client().enable(
            writePassword: Data([0xDE, 0xAD, 0xBE, 0xEF]),
            readPassword: privacyPw,
            armPrivacyIrreversibly: true
        )
        XCTAssertTrue(sim.privacyMode)
        XCTAssertEqual(sim.pageProtection, 0x20)
        XCTAssertEqual(sim.passwords[.privacy], privacyPw)
    }

    /// The read password is never changed from its factory `00 00 00 00`
    /// (§9.2.3), so setting the `PROTECT PAGE` RH bit would gate reads behind a
    /// value anybody can present. That is protection-shaped and gates nothing,
    /// so the client must not arm it.
    func test_enable_neverArmsTheReadPageBit() async throws {
        let sim = Iso15693Simulator.slix2()
        let wire = try await makeWire(sim)
        try await wire.client().enable(
            writePassword: Data([0xDE, 0xAD, 0xBE, 0xEF]),
            readPassword: privacyPw,
            armPrivacyIrreversibly: true
        )
        XCTAssertEqual(
            sim.pageProtection & 0x11, 0,
            "no read-protect bit may be armed behind the factory read password"
        )
    }

    // MARK: - What a privacy tag actually answers

    func test_privacyTagAnswersOnlyGetRandomAndPrivacySetPassword() async throws {
        let sim = Iso15693Simulator.slix2()
        let arm = try await makeWire(sim)
        try await arm.client().armPrivacy(newPassword: privacyPw)
        XCTAssertTrue(sim.privacyMode)

        let tag = try await SimulatedSession(chip: sim).start(alert: "")
        for frame in [
            Data([0x02, Iso15693Opcode.select]),
            Data([0x02, Iso15693Opcode.readSingleBlock, 0x00]),
            Data([0x02, Iso15693Opcode.getSystemInformation]),
            Data([0x02, Iso15693Opcode.getNXPSystemInformation]),
        ] {
            do {
                _ = try await tag.transceive(RawCommand(bytes: frame))
                XCTFail("a privacy-mode label answers nothing: \(frame.hexString)")
            } catch let error as TagError {
                XCTAssertEqual(error.kind, .tagLost, "silence, not a refusal code")
            }
        }
        let nonce = try await tag.transceive(RawCommand(bytes: Data([0x02, Iso15693Opcode.getRandomNumber])))
        XCTAssertEqual(nonce.first, 0x00, "GET_RANDOM_NUMBER is one of the two commands it does answer")
    }

    // MARK: - The exit

    /// The exit has to work unaddressed, because `SELECT` is not one of the two
    /// commands a privacy tag answers. This is what
    /// `Iso15693Opcode.requiresAddressedOrSelectedMode`'s privacy carve-out is
    /// for, and it was dead code while `setPassword` hardcoded the Select flag.
    func test_exitPrivacy_sendsAnUnaddressedPrivacySetPassword() async throws {
        let sim = Iso15693Simulator.slix2()
        let arm = try await makeWire(sim)
        try await arm.client().armPrivacy(newPassword: privacyPw)

        let wire = try await makeWire(sim)
        try await wire.client().exitPrivacy(password: privacyPw)

        let presentation = try XCTUnwrap(wire.frames.first { isPrivacySetPassword($0) })
        XCTAssertEqual(
            presentation[presentation.startIndex], 0x02,
            "the exit must ride the plain flag, not the Select flag: a privacy tag cannot be selected"
        )
        XCTAssertFalse(
            Iso15693Opcode.requiresAddressedOrSelectedMode(
                opcode: Iso15693Opcode.setPassword, params: [UInt8](presentation.dropFirst(2))
            ),
            "which is exactly why the mode rule carves out the privacy identifier"
        )
        XCTAssertFalse(sim.privacyMode)
    }

    /// An ACK is not proof. The exit is only reported when a block read, which a
    /// privacy tag would not answer at all, comes back.
    func test_exitPrivacy_provesItselfWithARead() async throws {
        let sim = Iso15693Simulator.slix2()
        let arm = try await makeWire(sim)
        try await arm.client().armPrivacy(newPassword: privacyPw)

        let wire = try await makeWire(sim)
        // The chip "accepts" the presentation but stays in privacy mode.
        wire.substitute = { [self] frame in isPrivacySetPassword(frame) ? Data([0x00]) : nil }
        wire.block = { [self] frame in isPrivacySetPassword(frame) }
        do {
            try await wire.client().exitPrivacy(password: privacyPw)
            XCTFail("an ACK alone must not be reported as a recovered tag")
        } catch let error as TagError {
            XCTAssertEqual(error.kind, .verificationFailed)
        }
        XCTAssertTrue(sim.privacyMode)
    }

    // MARK: - Arming

    /// The door is not closed until the way back has been demonstrated on this
    /// exact tag. If the unaddressed presentation draws silence, nothing is
    /// armed at all.
    func test_armPrivacy_refusesWhenTheUnaddressedExitRouteIsSilent() async throws {
        let sim = Iso15693Simulator.slix2()
        let wire = try await makeWire(sim)
        wire.block = { [self] frame in
            isPrivacySetPassword(frame) && frame[frame.startIndex] == 0x02
        }
        do {
            try await wire.client().armPrivacy(newPassword: Iso15693Passwords.factoryPrivacyDestroy)
            XCTFail("arming must be refused when the exit route cannot be transmitted")
        } catch let error as TagError {
            guard case .capabilityUnsupported = error.kind else {
                return XCTFail("expected .capabilityUnsupported, got \(error.kind)")
            }
        }
        XCTAssertFalse(sim.privacyMode, "the one-way door stays open")
    }

    /// The full rehearsal: arm, prove the tag has gone quiet, walk back out,
    /// prove it answers again, and only then arm for real.
    func test_armPrivacy_exercisesTheExitThenRearms() async throws {
        let sim = Iso15693Simulator.slix2()
        let wire = try await makeWire(sim)
        try await wire.client().armPrivacy(newPassword: privacyPw)

        let opcodes = wire.frames.map { $0[$0.startIndex + 1] }
        let arms = opcodes.enumerated().compactMap { $0.element == Iso15693Opcode.enablePrivacy ? $0.offset : nil }
        XCTAssertEqual(arms.count, 2, "armed, released to prove the way back, then armed again")
        let exit = try XCTUnwrap(
            wire.frames.enumerated().first { $0.offset > arms[0] && isPrivacySetPassword($0.element) }?.offset
        )
        XCTAssertLessThan(exit, arms[1], "the exit is exercised between the two arms")
        XCTAssertTrue(sim.privacyMode, "and the tag ends where the caller asked")
        XCTAssertEqual(sim.passwords[.privacy], privacyPw)
    }

    /// A changed privacy password is proven by re-presenting it before anything
    /// is armed, so an abort leaves a discoverable tag whose password is one of
    /// two known values.
    func test_armPrivacy_provesTheNewPasswordBeforeArming() async throws {
        let sim = Iso15693Simulator.slix2()
        let wire = try await makeWire(sim)
        try await wire.client().armPrivacy(newPassword: privacyPw)

        let opcodes = wire.frames.map { $0[$0.startIndex + 1] }
        let write = try XCTUnwrap(opcodes.firstIndex(of: Iso15693Opcode.writePassword))
        let arm = try XCTUnwrap(opcodes.firstIndex(of: Iso15693Opcode.enablePrivacy))
        let proof = try XCTUnwrap(
            wire.frames.enumerated().first { $0.offset > write && isPrivacySetPassword($0.element) }?.offset
        )
        XCTAssertLessThan(proof, arm, "the new privacy password is proven before the door closes")
    }
}
