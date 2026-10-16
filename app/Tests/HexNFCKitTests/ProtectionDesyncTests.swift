import Foundation
import HexNFCKit
import HexNFCRecords
import HexNFCTagSim
import XCTest

/// Regression cover for the 2026-09-04 NTAG213 incident and the bug class behind
/// it: a credential-mutating sequence tears partway, and the app's belief about
/// the tag diverges from what the tag actually holds.
///
/// Every test here drives the **shipped** frames. That is the point: the four
/// writes that stranded a real tag had never once executed in CI, because the
/// simulator answered `disableProtection` from its own in-memory model instead
/// of from the frame builder.
final class ProtectionDesyncTests: XCTestCase {
    private let password = Data([0xA1, 0xB2, 0xC3, 0xD4])
    private let pack = Data([0x56, 0x78])

    // MARK: - The incident

    /// The exact end state the incident left: AUTH0 open, PWD back at the
    /// factory default, and a user still holding their original password.
    ///
    /// Before the fix this was an inescapable dead end. The app authenticated
    /// unconditionally, the chip NAKed, the NAK halted it for the rest of the
    /// activation, and every retry repeated it.
    func test_removal_onATagAlreadyUnprotected_sendsNoPasswordAtAll() async throws {
        let sim = NTAG213Simulator()
        let tag = try await SimulatedSession(chip: sim).start(alert: "")

        // Reproduce the incident's end state: protection off, factory credential.
        try sim.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        try sim.disablePasswordProtection(currentPassword: password)
        sim.beginActivation()

        // The user presents the password they set, which the tag no longer holds.
        let residue = try await tag.disableProtection(using: .type2(password: password, pack: pack))

        XCTAssertTrue(residue.metItsGoal, "the tag is open, so the removal met its goal")
        XCTAssertEqual(residue.gate, .provenOpen)
        XCTAssertFalse(
            residue.completed.contains(.gateOpened),
            "an already-open tag must not be sent a PWD_AUTH at all: a refusal would halt it"
        )
    }

    /// `authenticate` on an ungated tag reports `.alreadyOpen` without a frame.
    func test_authenticate_onAnUngatedTag_reportsAlreadyOpenWithoutAFrame() async throws {
        let sim = NTAG213Simulator()
        let tag = try await SimulatedSession(chip: sim).start(alert: "")

        let opening = try await tag.authenticate(.type2(password: Data([0xDE, 0xAD, 0xBE, 0xEF]), pack: Data()))

        XCTAssertEqual(opening.route, .alreadyOpen)
        XCTAssertFalse(sim.isHalted, "no frame was sent, so nothing could have NAKed and halted the tag")
    }

    // MARK: - Torn removal

    /// The incident's abort point: the gate is proven open, then the credential
    /// tidy-up fails. That must be reported as a **success with residue**, never
    /// as a failure, because the tag really is unlocked.
    func test_removalTornAtTheCredentialReset_isReportedAsSuccessWithResidue() async throws {
        let sim = NTAG213Simulator()
        let layout = try XCTUnwrap(Type2ConfigLayout.for(.ntag213))
        try sim.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        sim.beginActivation()

        // Refuse every write to the PWD page, and nothing else. `.type2NAK` also
        // halts the chip, which the hand-rolled double this replaced did not:
        // the refusal lands after the gate has already read back open, so it
        // costs the tidy-up and nothing else, which is exactly the shape of the
        // incident.
        let faults = FaultInjectingSessionFactory(chip: sim)
        faults.arm(TagFault(.write(page: layout.pwdPage), .type2NAK))
        let tag = try await faults.makeSession().start(alert: "")

        let residue = try await tag.disableProtection(using: .type2(password: password, pack: pack))

        XCTAssertTrue(residue.metItsGoal, "the gate read back open, so the removal succeeded")
        XCTAssertEqual(residue.gate, .provenOpen)
        XCTAssertFalse(residue.isComplete, "the credential reset did not finish, and that must be recorded")
        XCTAssertEqual(residue.credential, .unknown(reason: "PWD reset did not complete"))
        XCTAssertTrue(
            residue.failures.contains { $0.step == .credentialWritten },
            "the residue must name the step that failed"
        )
    }

    /// A removal that cannot open the gate must NOT touch the credential. This is
    /// the ordering guarantee: nothing destructive happens before the gate is
    /// proven down.
    func test_removalThatCannotDisarmTheGate_leavesTheCredentialUntouched() async throws {
        let sim = NTAG213Simulator()
        let layout = try XCTUnwrap(Type2ConfigLayout.for(.ntag213))
        try sim.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        sim.beginActivation()

        let faults = FaultInjectingSessionFactory(chip: sim)
        faults.arm(TagFault(.write(page: layout.config0Page), .type2NAK))
        let tag = try await faults.makeSession().start(alert: "")

        do {
            _ = try await tag.disableProtection(using: .type2(password: password, pack: pack))
            XCTFail("a removal that cannot disarm the gate must throw")
        } catch let error as TagError {
            guard case .protectionIncomplete(let residue) = error.kind else {
                return XCTFail("expected protectionIncomplete, got \(error.kind)")
            }
            XCTAssertFalse(residue.metItsGoal)
            XCTAssertEqual(residue.credential, .unchanged, "the credential must not be touched")
        }

        // The original password still works, so the tag is recoverable.
        sim.beginActivation()
        XCTAssertEqual(try sim.authenticate(password: password), pack)
    }

    // MARK: - Writes a removal does not need to make

    /// A removal writes ACCESS only when ACCESS is going to change.
    ///
    /// The write sits above AUTH0 in the sequence, so it goes out while the gate
    /// is still up and can still be refused, and on a tag protected for writes
    /// only the bytes it sends are the bytes already on the page. Measured on an
    /// NTAG213 (2026-09-21): the state read returned CFG1 = 00 05 00 00 and the
    /// next frame wrote 00 05 00 00 back. That is an abort point bought for
    /// nothing, in a sequence CLAUDE.md requires to be recoverable at every one.
    func test_removal_whenAccessIsAlreadyClear_writesOnlyTheGate() async throws {
        let sim = NTAG213Simulator()
        let layout = try XCTUnwrap(Type2ConfigLayout.for(.ntag213))
        // Write-only protection with no attempt limit: PROT is 0 and AUTH_LIM is
        // 0, so the ACCESS byte a removal would write is the one already there.
        try sim.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        sim.beginActivation()

        let faults = FaultInjectingSessionFactory(chip: sim)
        let tag = try await faults.makeSession().start(alert: "")

        let residue = try await tag.disableProtection(using: .type2(password: password, pack: pack))

        XCTAssertTrue(residue.metItsGoal, "the gate read back open, so the removal succeeded")
        XCTAssertTrue(
            residue.completed.contains(.accessWritten),
            "the step's goal is that ACCESS now reads as the disarmed value, and it does. A skipped "
                + "write that met the goal is not a step that failed, and reporting it as missing "
                + "would make a clean removal look partial to every verdict downstream."
        )
        XCTAssertTrue(residue.isComplete, "nothing was refused and nothing was lost")
        XCTAssertTrue(
            faults.report.frames(matching: .write(page: layout.config1Page)).isEmpty,
            "the bytes were already on the page, so no frame had anything to carry"
        )
        XCTAssertEqual(
            faults.report.frames(matching: .write(page: layout.config0Page)).count, 1,
            "AUTH0 is the gate and is always written: its read-back is what makes this a success"
        )

        sim.beginActivation()
        XCTAssertEqual(try sim.readProtectionState(), TagProtection.none)
    }

    /// And the boundary: a tag whose ACCESS byte really does differ still gets
    /// the write. A read-gated tag carries the PROT bit, so the disarmed value
    /// is not the value on the page.
    func test_removal_fromAReadGatedTag_stillWritesAccess() async throws {
        let sim = NTAG213Simulator()
        let layout = try XCTUnwrap(Type2ConfigLayout.for(.ntag213))
        try sim.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: true, authLimit: 0
        )
        sim.beginActivation()

        let faults = FaultInjectingSessionFactory(chip: sim)
        let tag = try await faults.makeSession().start(alert: "")

        let residue = try await tag.disableProtection(using: .type2(password: password, pack: pack))

        XCTAssertTrue(residue.metItsGoal)
        XCTAssertEqual(
            faults.report.frames(matching: .write(page: layout.config1Page)).count, 1,
            "PROT is set on this tag, so clearing it is a real change and the frame has to go out"
        )

        sim.beginActivation()
        XCTAssertEqual(try sim.readProtectionState(), TagProtection.none)
    }

    // MARK: - Permanent lock

    /// The second half of the incident: a permanent lock on a still-protected
    /// tag burned the static lock bytes and was refused the dynamic ones.
    func test_permanentLock_onAProtectedTag_refusesBeforeBurningAnything() async throws {
        let sim = NTAG213Simulator()
        let tag = try await SimulatedSession(chip: sim).start(alert: "")
        try sim.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        sim.beginActivation()

        let lockBefore = try sim.readMemory(range: 8 ..< 12)

        do {
            _ = try await tag.permanentLock()
            XCTFail("a permanent lock must refuse a tag whose password gate is armed")
        } catch let error as TagError {
            guard case .protectionIncomplete(let residue) = error.kind else {
                return XCTFail("expected protectionIncomplete, got \(error.kind)")
            }
            XCTAssertEqual(residue.gate, .provenArmed(fromPage: 4))
        }

        XCTAssertEqual(
            try sim.readMemory(range: 8 ..< 12), lockBefore,
            "not one irreversible bit may be burned by a refused lock"
        )
    }

    /// On an unprotected tag the lock still works, and reports what it burned.
    func test_permanentLock_onAnUnprotectedTag_reportsEveryStage() async throws {
        let sim = NTAG213Simulator()
        let tag = try await SimulatedSession(chip: sim).start(alert: "")

        let outcome = try await tag.permanentLock()

        XCTAssertFalse(outcome.isPartial, "a clean lock is not partial")
        XCTAssertFalse(outcome.burnedNothing)
        XCTAssertEqual(outcome.order.first, .dynamicLock, "the gated page is attempted first")
    }
}
