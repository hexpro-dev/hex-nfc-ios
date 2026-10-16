import Foundation
@testable import HexNFCKit
import HexNFCRecords
import HexNFCTagSim
import XCTest

/// What `Type2PasswordDriver` says about the one authentication attempt an
/// activation allows, and what it may not say about a gate it has not read.
///
/// Two separate rules live here because they share a fixture, and both are about
/// the same failing: a report that asserts more than the tag was asked.
final class Type2GateAttemptTests: XCTestCase {
    private let onTag = Data([0xA1, 0xB2, 0xC3, 0xD4])
    private let pack = Data([0x56, 0x78])
    private let wrong = Data([0xDE, 0xAD, 0xBE, 0xEF])

    // MARK: - One attempt, and a report of it

    /// A refused removal must put exactly one `PWD_AUTH` on the wire.
    ///
    /// A NAK returns a Type-2 chip to HALT for the rest of the activation, so a
    /// second credential in the same tap is answered by silence. Now that the app
    /// offers a factory-default *tap*, this is the guard against someone deciding
    /// the driver may as well try it here instead.
    func test_aRefusedRemovalSendsExactlyOnePasswordAuthPerActivation() async throws {
        let sim = NTAG213Simulator()
        try sim.enablePasswordProtection(
            password: onTag, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let faults = FaultInjectingSessionFactory(chip: sim)
        let tag = try await faults.makeSession().start(alert: "")

        do {
            _ = try await tag.disableProtection(using: .type2(password: wrong, pack: Data()))
            XCTFail("a removal with the wrong password must throw")
        } catch is TagError {
            // The verdict is in the frame log, below.
        }

        XCTAssertEqual(
            faults.report.frames(matching: .opcode(Type2PasswordDriver.pwdAuth)).count, 1,
            "one authentication attempt per activation: a retry is a second tap, never a second frame"
        )
    }

    /// The refusal has to carry what the driver **did**, because it cannot carry
    /// what the chip said. `authenticate` reports a stated refusal as
    /// `.authFailed` and a transport loss as `.authInconclusive`, and which one a
    /// phone produces for a wrong password is not settled in this repo. A failed
    /// `.gateOpened` step is the same either way.
    func test_aRefusedRemovalReportsTheAttemptItMade() async throws {
        let sim = NTAG213Simulator()
        try sim.enablePasswordProtection(
            password: onTag, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let tag = try await SimulatedSession(chip: sim).start(alert: "")

        do {
            _ = try await tag.disableProtection(using: .type2(password: wrong, pack: Data()))
            XCTFail("a removal with the wrong password must throw")
        } catch let error as TagError {
            guard case .protectionIncomplete(let residue) = error.kind else {
                return XCTFail("expected the refusal to carry a residue, got \(error.kind)")
            }
            XCTAssertEqual(residue.family, .type2)
            XCTAssertTrue(
                residue.failures.contains { $0.step == .gateOpened },
                "the residue is where 'a PWD_AUTH went on the wire and did not open the gate' is recorded"
            )
            XCTAssertEqual(residue.credential, .unchanged, "nothing was written")
            XCTAssertEqual(
                residue.gate, .provenArmed(fromPage: 4),
                "`disable` reads AUTH0 back before it presents anything, so the gate verdict came off a "
                    + "read-back in this same activation, which is what `GateVerdict` requires. A refusal "
                    + "means nothing was written, so that reading is still the truth about the gate."
            )
            XCTAssertEqual(
                String(localized: error.userMessage),
                String(localized: TagError.authFailed().userMessage),
                "the user still gets the plain explanation, not the residue's torn-sequence copy"
            )
            XCTAssertFalse(
                error.diagnostics.contains(wrong.hexString),
                "a diagnostics string is written to be pasted into a bug report and may never carry a password"
            )
        }

        // And the tag is exactly as it was.
        sim.beginActivation()
        XCTAssertEqual(try sim.authenticate(password: onTag), pack)
    }

    /// Without a 7-byte UID the page in `.provenArmed` could be a forgery, so no
    /// page is filed at all.
    ///
    /// `detectReadProtection` returns `nil` without reading when it has no UID to
    /// build a roll-over signature from, so a tag that rolled over serves page 0
    /// and `Type2ProtectionConfig` decodes it happily: byte 3 of page 0 is BCC0,
    /// not AUTH0. Filing that number as a proven gate would put a manufacturer
    /// checksum into a sentence the user reads as a page range.
    ///
    /// This pins the guard rather than leaving it to the one call site that has a
    /// UID by construction. Same guard, same reason, as `Type2LockDriver.refuseIfGated`.
    func test_aRefusalWithNoUIDFilesNoPage() async throws {
        let layout = try XCTUnwrap(Type2ConfigLayout.for(.ntag213))
        let sim = NTAG213Simulator()
        try sim.enablePasswordProtection(
            password: onTag, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        sim.beginActivation()

        let driver = Type2PasswordDriver(layout: layout, uid: nil) { command in
            sim.handle(command: command.bytes)
        }

        do {
            _ = try await driver.disable(currentPassword: wrong)
            XCTFail("a removal with the wrong password must throw")
        } catch let error as TagError {
            guard case .protectionIncomplete(let residue) = error.kind else {
                return XCTFail("expected the refusal to carry a residue, got \(error.kind)")
            }
            XCTAssertTrue(
                residue.failures.contains { $0.step == .gateOpened },
                "the attempt is still recorded; only the page is withheld"
            )
            XCTAssertEqual(
                residue.gate, .unknown,
                "no UID means no roll-over signature, so the AUTH0 byte this driver read could have come "
                    + "from a rolled-over page 0. `provenArmed` carries a page, so file nothing."
            )
        }

        sim.beginActivation()
        XCTAssertEqual(try sim.authenticate(password: onTag), pack, "and the tag is exactly as it was")
    }

    /// A removal that never had to authenticate reports no attempt, so nothing
    /// downstream can mistake an already-open tag for one a credential opened.
    func test_aRemovalOnAnOpenTagRecordsNoAttempt() async throws {
        let sim = NTAG213Simulator()
        let tag = try await SimulatedSession(chip: sim).start(alert: "")

        let residue = try await tag.disableProtection(using: .type2(password: wrong, pack: Data()))

        XCTAssertFalse(
            residue.completed.contains(.gateOpened),
            "an ungated tag is sent no password at all, so nothing opened its gate"
        )
        XCTAssertTrue(residue.failures.isEmpty)
        XCTAssertEqual(residue.gate, .provenOpen)
    }

    // MARK: - The gate verdict a torn re-key may report

    /// `enable` used to set `residue.gate = .provenOpen` in this catch, under the
    /// comment "the gate was never armed, so the tag is still open". That is true
    /// of a tag that arrives unarmed and false of a re-key: AUTH0 is written last,
    /// so a tear above it leaves an already-armed tag armed at exactly the page it
    /// came in with. Claiming `provenOpen` there asserts a protection state
    /// nothing read, on the one report a user acts on.
    func test_aReKeyThatTearsDoesNotClaimTheGateIsOpen() async throws {
        let layout = try XCTUnwrap(Type2ConfigLayout.for(.ntag213))
        let sim = NTAG213Simulator()
        try sim.enablePasswordProtection(
            password: onTag, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        sim.beginActivation()

        let faults = FaultInjectingSessionFactory(chip: sim)
        faults.arm(TagFault(.write(page: layout.packPage), .type2NAK))
        let tag = try await faults.makeSession().start(alert: "")

        do {
            _ = try await tag.enableProtection(
                .type2(
                    password: Data([0x0A, 0x0B, 0x0C, 0x0D]), pack: Data([0x1E, 0x2F]),
                    protectFromPage: 4, readProtect: false, authLimit: 0
                ),
                replacing: .type2(password: onTag, pack: pack)
            )
            XCTFail("a refused PACK write must throw")
        } catch let error as TagError {
            guard case .protectionIncomplete(let residue) = error.kind else {
                return XCTFail("expected protectionIncomplete, got \(error.kind)")
            }
            XCTAssertEqual(
                residue.gate, .unknown,
                "this tag arrived armed and its gate was never re-read, so there is no verdict to give"
            )
            XCTAssertTrue(residue.completed.contains(.gateOpened), "the re-key did authenticate first")
        }

        // The claim the old comment made, checked against the tag: it is still
        // protected.
        sim.beginActivation()
        XCTAssertEqual(
            try sim.readProtectionState()?.passwordProtect, true,
            "a torn re-key leaves the gate exactly where it was, which is why provenOpen was a fabrication"
        )
    }

    /// The other half of the same rule: on a tag that genuinely arrived unarmed,
    /// `provenOpen` is a reading and stays.
    func test_aFirstTimeProtectThatTearsStillReportsTheTagOpen() async throws {
        let layout = try XCTUnwrap(Type2ConfigLayout.for(.ntag213))
        let sim = NTAG213Simulator()
        let faults = FaultInjectingSessionFactory(chip: sim)
        faults.arm(TagFault(.write(page: layout.packPage), .type2NAK))
        let tag = try await faults.makeSession().start(alert: "")

        do {
            _ = try await tag.enableProtection(
                .type2(
                    password: onTag, pack: pack,
                    protectFromPage: 4, readProtect: false, authLimit: 0
                ),
                replacing: nil
            )
            XCTFail("a refused PACK write must throw")
        } catch let error as TagError {
            guard case .protectionIncomplete(let residue) = error.kind else {
                return XCTFail("expected protectionIncomplete, got \(error.kind)")
            }
            XCTAssertEqual(residue.gate, .provenOpen, "AUTH0 is written last, and this never reached it")
            XCTAssertFalse(residue.completed.contains(.gateOpened), "an unarmed tag is sent no password")
        }

        sim.beginActivation()
        XCTAssertEqual(try sim.readProtectionState(), TagProtection.none)
    }

    // MARK: - The gate verdict an AUTH0 abort may report

    /// The one abort point where the reading taken on the way in cannot be
    /// reused, and a lost ACK is why.
    ///
    /// AUTH0 is the write that arms the gate. This catch used to set
    /// `gate = arrivedArmed ? .unknown : .provenOpen`, so a first-time protect
    /// reported the tag as open from a reading taken *before* the command that
    /// closes it. `.lostACK` is CLAUDE.md's "a refusal may be a lost ACK" in its
    /// exact shape: the chip applied the write and the answer vanished, so the
    /// tag is armed with the password written moments earlier and the old verdict
    /// would have told its owner nothing was gated.
    func test_enable_aLostAuth0AckIsNotReportedAsAnOpenTag() async throws {
        let layout = try XCTUnwrap(Type2ConfigLayout.for(.ntag213))
        let sim = NTAG213Simulator()
        let faults = FaultInjectingSessionFactory(chip: sim)
        faults.arm(TagFault(.write(page: layout.config0Page), .lostACK))
        let tag = try await faults.makeSession().start(alert: "")

        do {
            _ = try await tag.enableProtection(
                .type2(
                    password: onTag, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
                ),
                replacing: nil
            )
            XCTFail("an AUTH0 write whose answer never arrived is not a success")
        } catch let error as TagError {
            guard case .protectionIncomplete(let residue) = error.kind else {
                return XCTFail("expected protectionIncomplete, got \(error.kind)")
            }
            XCTAssertEqual(
                residue.gate, .provenArmed(fromPage: 4),
                "the chip was asked afterwards, and it said the gate is up"
            )
            XCTAssertTrue(residue.completed.contains(.gateProven), "and that answer is what set the verdict")
            XCTAssertNotEqual(
                String(localized: error.userMessage),
                String(localized: ProtectionResidue(
                    family: .type2, intent: .enable, gate: .provenOpen, credential: .callerSupplied
                ).userMessage),
                "the sentence about a tag that did not switch on belongs to a tag that did not switch on"
            )
        }

        XCTAssertEqual(faults.report.swallowed.count, 1, "the AUTH0 write did reach the chip")

        // The claim the old verdict made, checked against the tag.
        sim.beginActivation()
        XCTAssertEqual(
            try sim.readProtectionState()?.passwordProtect, true,
            "the tag is armed, which is why provenOpen was a fabrication"
        )
        sim.beginActivation()
        XCTAssertEqual(try sim.authenticate(password: onTag), pack, "and it is the new password that opens it")
    }

    /// The other half: on a tag that really is still open, the verdict stays
    /// `provenOpen`, and now it is a reading rather than an inheritance. The
    /// recorded `.gateProven` step is the difference, and it is the whole point:
    /// the old code reached the same verdict without asking the chip anything.
    func test_enable_aDroppedAuth0WriteReportsAnOpenGateTheChipItselfConfirmed() async throws {
        let layout = try XCTUnwrap(Type2ConfigLayout.for(.ntag213))
        let sim = NTAG213Simulator()
        let faults = FaultInjectingSessionFactory(chip: sim)
        faults.arm(TagFault(.write(page: layout.config0Page), .dropped))
        let tag = try await faults.makeSession().start(alert: "")

        do {
            _ = try await tag.enableProtection(
                .type2(
                    password: onTag, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
                ),
                replacing: nil
            )
            XCTFail("a dropped AUTH0 write must throw")
        } catch let error as TagError {
            guard case .protectionIncomplete(let residue) = error.kind else {
                return XCTFail("expected protectionIncomplete, got \(error.kind)")
            }
            XCTAssertEqual(residue.gate, .provenOpen)
            XCTAssertTrue(
                residue.completed.contains(.gateProven),
                "provenOpen here has to come from the read-back, not from the read taken on the way in"
            )
            XCTAssertEqual(residue.credential, .callerSupplied, "PWD and PACK did land")
        }

        sim.beginActivation()
        XCTAssertEqual(try sim.readProtectionState(), TagProtection.none)
    }

    /// And when the chip will not answer the question, nothing is claimed.
    ///
    /// The AUTH0 write goes nowhere and neither does the read-back that would
    /// settle it. `.unknown` is what sends the owner back for another tap; the
    /// old verdict sent them away with "the password was saved, protection did
    /// not switch on" about a gate nothing had looked at since before the write.
    func test_enable_anAuth0AbortWhoseReReadCannotBeTakenClaimsNothing() async throws {
        let layout = try XCTUnwrap(Type2ConfigLayout.for(.ntag213))
        let sim = NTAG213Simulator()
        let faults = FaultInjectingSessionFactory(chip: sim)
        faults.arm(
            TagFault(.write(page: layout.config0Page), .dropped),
            // Occurrence 2: the first read of this page is the state read
            // `enable` opens with, the second is the catch's re-read.
            TagFault(.read(page: layout.config0Page), .dropped, on: .nth(2))
        )
        let tag = try await faults.makeSession().start(alert: "")

        do {
            _ = try await tag.enableProtection(
                .type2(
                    password: onTag, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
                ),
                replacing: nil
            )
            XCTFail("a dropped AUTH0 write must throw")
        } catch let error as TagError {
            guard case .protectionIncomplete(let residue) = error.kind else {
                return XCTFail("expected protectionIncomplete, got \(error.kind)")
            }
            XCTAssertEqual(residue.gate, .unknown)
            XCTAssertFalse(residue.completed.contains(.gateProven), "nothing witnessed the gate either way")
            XCTAssertEqual(
                String(localized: error.userMessage),
                String(localized: ProtectionResidue(
                    family: .type2, intent: .enable, gate: .unknown, credential: .callerSupplied
                ).userMessage)
            )
            XCTAssertFalse(
                error.diagnostics.contains(onTag.hexString),
                "a diagnostics string is written to be pasted into a bug report and may never carry a password"
            )
        }

        sim.beginActivation()
        XCTAssertEqual(try sim.readProtectionState(), TagProtection.none)
    }

    // MARK: - What the session flag may claim after an arm

    /// A clean arm ends with the tag open, and the flag says so because a
    /// `PWD_AUTH` succeeded, not because four writes were acknowledged.
    ///
    /// Worth pinning because the obvious reading of `enable` is wrong: a tag that
    /// arrives unarmed is sent no credential on the way in, so it looks as though
    /// an arm puts no `PWD_AUTH` on the wire at all. It puts exactly one. The
    /// closing credential proof presents the password to see the PACK come back,
    /// and that frame is what leaves the tag authenticated for the rest of the
    /// activation.
    func test_enable_onAFactoryTag_authenticatesThroughTheClosingProof() async throws {
        let sim = NTAG213Simulator()
        let faults = FaultInjectingSessionFactory(chip: sim)
        let tag = try await faults.makeSession().start(alert: "")

        let residue = try await tag.enableProtection(
            .type2(password: onTag, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0),
            replacing: nil
        )

        XCTAssertTrue(residue.metItsGoal)
        XCTAssertEqual(
            faults.report.frames(matching: .opcode(Type2PasswordDriver.pwdAuth)).count, 1,
            "an unarmed tag is sent nothing on the way in, and the credential proof is the one frame"
        )
        XCTAssertFalse(
            residue.completed.contains(.gateOpened),
            "`.gateOpened` stays narrow: a credential presented to a gate the tag already had. The "
                + "factory-default recovery copy is built on it meaning exactly that."
        )
        XCTAssertTrue(
            residue.completed.contains(.credentialProven),
            "the proof is the step that says this activation authenticated"
        )
        XCTAssertTrue(tag.type2Session.isAuthenticated)
    }

    /// And when that closing `PWD_AUTH` never completes, the flag stays false.
    ///
    /// This is the case the flag used to get wrong. `enable` does not throw here:
    /// the gate read back armed and the credential pages were acknowledged, so
    /// the operation returns with a residue naming the missing proof. Setting the
    /// session flag from that return told the rest of the activation the tag was
    /// open on the strength of the writes alone, which is an authentication
    /// recorded from a reading rather than from an exchange.
    func test_enable_whoseClosingProofIsLost_leavesTheSessionUnauthenticated() async throws {
        let sim = NTAG213Simulator()
        let faults = FaultInjectingSessionFactory(chip: sim)
        faults.arm(TagFault(.opcode(Type2PasswordDriver.pwdAuth), .dropped))
        let tag = try await faults.makeSession().start(alert: "")

        let residue = try await tag.enableProtection(
            .type2(password: onTag, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0),
            replacing: nil
        )

        XCTAssertEqual(
            residue.gate, .provenArmed(fromPage: 4),
            "the gate read back armed, so the arm itself did land"
        )
        XCTAssertFalse(
            residue.completed.contains(.credentialProven),
            "the one PWD_AUTH this sequence sent did not complete, so nothing was proven and nothing opened"
        )
        XCTAssertFalse(
            tag.type2Session.isAuthenticated,
            "a flag that says the tag is open is what lets a later step skip an authentication it needs"
        )
    }

    /// The other half: a re-key authenticates on the way in, and the flag may say
    /// so. Two frames go out here, one past the gate the tag arrived with and one
    /// to prove the new credential.
    func test_enable_reKeyingAnArmedTag_marksTheSessionAuthenticated() async throws {
        let sim = NTAG213Simulator()
        try sim.enablePasswordProtection(
            password: onTag, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        sim.beginActivation()

        let faults = FaultInjectingSessionFactory(chip: sim)
        let tag = try await faults.makeSession().start(alert: "")

        let residue = try await tag.enableProtection(
            .type2(
                password: Data([0x0A, 0x0B, 0x0C, 0x0D]), pack: Data([0x1E, 0x2F]),
                protectFromPage: 4, readProtect: false, authLimit: 0
            ),
            replacing: .type2(password: onTag, pack: pack)
        )

        XCTAssertTrue(residue.metItsGoal)
        XCTAssertTrue(
            residue.completed.contains(.gateOpened),
            "this tag did arrive with a gate, and a credential was presented to it"
        )
        XCTAssertEqual(
            faults.report.frames(matching: .opcode(Type2PasswordDriver.pwdAuth)).count, 2,
            "one to get past the gate this tag arrived with, one to prove the credential that replaced it"
        )
        XCTAssertTrue(tag.type2Session.isAuthenticated)
    }
}
