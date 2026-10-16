#if DEBUG
@testable import HexNFCApp
@testable import HexNFCKit
@testable import HexNFCTagSim
import XCTest

/// Coverage for the gated irreversible-ops flow — the one part of the app that
/// issues commands a tag can never come back from.
///
/// **Why this file exists.** Every op here runs exactly once per tag, on real
/// silicon, with no undo. Until now the primitives underneath (`permanentLock`,
/// `formatCC`) had simulator tests but the *orchestration* had none: the UID
/// equality check, the OTP "already has a CC" refusal, `lockSignature`'s
/// behavioural proof and its clone-silicon recovery branch, and the two-tap
/// SLIX latch had never executed outside a live tap. That is the wrong way
/// round — the reversible batch had 500 tests and the one-way path had zero.
///
/// These tests drive `IrreversibleOpsFlowModel` end to end against the
/// simulators, so the sequence that will run on hardware runs here first.
@MainActor
final class IrreversibleOpsTests: XCTestCase {
    // MARK: - Applicability

    //
    // `Operation.applies(to:)` decides which one-way command is put in front of
    // a given tag. Offering the wrong one is how a tag dies for no reason.

    /// LOCK_SIG exists only on the customisable-signature dies. Swept across the
    /// whole catalog rather than spot-checked: the bug this guards against is a
    /// future capability edit widening the gate to every chip advertising
    /// `.signatureRead`, which is most of the Type-2 family.
    func test_lockSignature_isOfferedOnNTAG210MicroAndNothingElse() {
        for profile in ChipCatalog.all {
            XCTAssertEqual(
                IrreversibleOpsFlowModel.Operation.lockSignature.applies(to: profile),
                profile.id == .ntag210Micro,
                "\(profile.id) offered lockSignature: \(profile.id != .ntag210Micro)"
            )
        }
    }

    /// The OTP CC write is Type-2 only. A Type-5 CC lives in a rewritable block,
    /// so formatting one is an ordinary reversible operation and must not be
    /// dressed up as irreversible.
    func test_formatVirginCC_appliesOnlyToType2ChipsWithAKnownFactoryCC() throws {
        for profile in ChipCatalog.all {
            guard IrreversibleOpsFlowModel.Operation.formatVirginCC.applies(to: profile) else { continue }
            guard case .type2 = profile.family else {
                return XCTFail("\(profile.id) is not Type-2 but was offered the OTP CC write")
            }
            XCTAssertNotNil(profile.factoryCC, "\(profile.id) offered a CC write with no datasheet CC")
        }
        let ev1 = try? XCTUnwrap(ChipCatalog.profile(for: .mifareUltralightEV1_128))
        XCTAssertEqual(try IrreversibleOpsFlowModel.Operation.formatVirginCC.applies(to: XCTUnwrap(ev1)), true)
    }

    // MARK: - The per-tag CC gate

    /// Reported from a live NTAG213 run on 2026-08-07: "Write Capability
    /// Container" was offered on a tag that arrived pre-formatted, where the op
    /// can only ever refuse. `applies(to:)` is chip-level and cannot see it —
    /// a written CC is a fact about the tag.
    func test_formatVirginCC_isHiddenOnATagWhoseCCIsAlreadyWritten() {
        let format = IrreversibleOpsFlowModel.Operation.formatVirginCC
        XCTAssertFalse(
            format.appliesToTag(capabilityContainerIsBlank: false),
            "a tag with a written OTP page must not be offered a one-shot CC write"
        )
        XCTAssertTrue(format.appliesToTag(capabilityContainerIsBlank: true))
    }

    /// Unknown must stay offered. The suite may not have run `t2.ccVerify` at
    /// all, and hiding the op then would remove the only path that formats a
    /// genuinely virgin tag. The execute-time guard still refuses a non-blank
    /// page 3, so the cost of being wrong here is an error, not a bad write.
    func test_formatVirginCC_staysOfferedWhenTheCCStateIsUnknown() {
        XCTAssertTrue(
            IrreversibleOpsFlowModel.Operation.formatVirginCC
                .appliesToTag(capabilityContainerIsBlank: nil)
        )
    }

    /// The gate is specific to the CC write. Nothing else may be suppressed by
    /// it — a permanent lock on a formatted tag is exactly the normal case.
    func test_ccGate_doesNotSuppressAnyOtherOperation() {
        for op in IrreversibleOpsFlowModel.Operation.allCases where op != .formatVirginCC {
            XCTAssertTrue(
                op.appliesToTag(capabilityContainerIsBlank: false),
                "\(op) must not be gated on the capability container"
            )
        }
    }

    func test_slixPasswordLatch_appliesOnlyToType5() {
        for profile in ChipCatalog.all {
            guard IrreversibleOpsFlowModel.Operation.slixPasswordLatch.applies(to: profile) else { continue }
            guard case .type5 = profile.family else {
                return XCTFail("\(profile.id) is not Type-5 but was offered the SLIX latch")
            }
        }
    }

    /// Every operation offered for a chip must either be implemented or be
    /// visibly a placeholder — there is no third state in which a command gets
    /// issued half-wired.
    func test_placeholders_areNeverTreatedAsImplemented() {
        for op in [IrreversibleOpsFlowModel.Operation.slixDestroy, .desfireChangeKey] {
            XCTAssertFalse(op.isImplemented, "\(op.title) must stay a gated placeholder")
        }
    }

    // MARK: - Clean-pass registry

    //
    // The precondition for reaching any of this: the chip passed the full
    // non-destructive suite this run, on a known tag.

    func test_registry_isKeyedPerChipID_andStartsEmpty() {
        let registry = CleanPassRegistry()
        XCTAssertFalse(registry.hasCleanPass(for: .ntag213))
        XCTAssertNil(registry.uid(for: .ntag213))

        let uid = Data([0x04, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66])
        registry.record(chipID: .ntag213, uid: uid)
        XCTAssertTrue(registry.hasCleanPass(for: .ntag213))
        XCTAssertEqual(registry.uid(for: .ntag213), uid)

        // A clean pass on one chip must not unlock a sibling — lock pages and
        // config layouts differ per variant.
        XCTAssertFalse(registry.hasCleanPass(for: .ntag216))
        XCTAssertNil(registry.uid(for: .ntag216))
    }

    /// The registry hands its UID straight to the flow model as `expectedUID`,
    /// so "which tag is this op allowed to touch" is decided here. Re-running
    /// the suite on a second tag of the same type must re-point the gate at the
    /// tag actually in hand.
    func test_registry_tracksTheMostRecentTagPerChip() {
        let registry = CleanPassRegistry()
        let first = Data([0x04, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA])
        let second = Data([0x04, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB])
        registry.record(chipID: .ntag213, uid: first)
        registry.record(chipID: .ntag213, uid: second)
        XCTAssertEqual(registry.uid(for: .ntag213), second)
    }

    // MARK: - Gates

    /// Selecting a placeholder must fail in-app, before any RF activity.
    func test_selectingAPlaceholder_reportsNotImplemented_andOpensNoSession() {
        let factory = TapFactory(chip: Iso15693Simulator())
        let model = IrreversibleOpsFlowModel(factory: factory, expectedUID: Iso15693Simulator.defaultUID)
        model.select(.slixDestroy)
        XCTAssertTrue(model.isErrored, "expected an error phase, got \(model.phase)")
        XCTAssertEqual(factory.tapCount, 0, "a placeholder must never open a session")
    }

    /// The typed-UID confirmation is the gate. Executing without passing through
    /// `.confirming` must do nothing at all.
    func test_confirmAndExecute_withoutConfirmation_isANoOp() async {
        let simulator = NTAG215Simulator()
        let factory = TapFactory(chip: simulator)
        let model = IrreversibleOpsFlowModel(factory: factory, expectedUID: simulator.uid)

        model.confirmAndExecute() // straight from .idle
        await Task.yield()

        XCTAssertTrue(model.isIdle, "expected .idle, got \(model.phase)")
        XCTAssertEqual(factory.tapCount, 0)
        XCTAssertFalse(simulator.isLockedPermanent, "no command may be issued without confirmation")
    }

    /// Positive control for the refusal tests below. Without it, "the tag was
    /// not locked" would also be satisfied by a flow that never locks anything,
    /// and every gate test in this file would pass vacuously.
    func test_permanentLock_locksTheTag_whenTheUIDMatches() async {
        let simulator = NTAG215Simulator()
        let model = IrreversibleOpsFlowModel(factory: TapFactory(chip: simulator), expectedUID: simulator.uid)
        await model.perform(.permanentLock)

        XCTAssertTrue(model.isDone, "expected success, got \(model.phase)")
        XCTAssertTrue(simulator.isLockedPermanent)
    }

    /// The wrong tag presented at the sheet must be refused **before** the
    /// command goes out. Asserting the phase alone would pass even if the lock
    /// had already been issued, so this asserts the chip's state too.
    func test_uidMismatch_refuses_andIssuesNoCommand() async {
        let simulator = NTAG215Simulator()
        let factory = TapFactory(chip: simulator)
        let wrongUID = Data([0x04, 0x99, 0x99, 0x99, 0x99, 0x99, 0x99])
        XCTAssertNotEqual(simulator.uid, wrongUID)

        let model = IrreversibleOpsFlowModel(factory: factory, expectedUID: wrongUID)
        await model.perform(.permanentLock)

        XCTAssertTrue(model.isErrored, "expected refusal, got \(model.phase)")
        XCTAssertFalse(simulator.isLockedPermanent, "a mismatched UID must not be locked")
    }

    // MARK: - Write Capability Container (OTP)

    /// The happy path, and the reason the op exists: prove the constant we ship
    /// is what the silicon ends up holding. UL EV1 128 B → `E1 10 10 00`.
    func test_formatVirginCC_writesTheDatasheetCC_andVerifiesTheReadBack() async throws {
        let simulator = MifareUltralightEV1_128Simulator(virgin: true)
        let profile = try XCTUnwrap(simulator.profile)
        let expected = try XCTUnwrap(profile.factoryCC)
        let ccPage = try XCTUnwrap(profile.memoryLayout.ccPage)
        XCTAssertEqual(simulator.pages[ccPage], Data([0x00, 0x00, 0x00, 0x00]), "virgin EV1 ships with a blank CC")

        let model = IrreversibleOpsFlowModel(factory: TapFactory(chip: simulator), expectedUID: simulator.uid)
        await model.perform(.formatVirginCC)

        XCTAssertTrue(model.isDone, "expected success, got \(model.phase)")
        XCTAssertEqual(simulator.pages[ccPage], expected)
        XCTAssertEqual(expected, Data([0xE1, 0x10, 0x10, 0x00]), "128 B of user memory, per MF0ULx1")
    }

    /// The guard that matters most. Page 3 is one-time-programmable: a second
    /// write can only OR bits in, so a CC written over an existing one is
    /// corrupt and uncorrectable. The op must refuse and write **nothing**.
    func test_formatVirginCC_refusesWhenACCIsAlreadyPresent_andWritesNothing() async throws {
        let simulator = MifareUltralightEV1_128Simulator() // already formatted
        let profile = try XCTUnwrap(simulator.profile)
        let ccPage = try XCTUnwrap(profile.memoryLayout.ccPage)
        let before = simulator.pages[ccPage]
        XCTAssertEqual(before.first, 0xE1, "precondition: this tag already has a CC")

        let model = IrreversibleOpsFlowModel(factory: TapFactory(chip: simulator), expectedUID: simulator.uid)
        await model.perform(.formatVirginCC)

        XCTAssertTrue(model.isErrored, "expected refusal, got \(model.phase)")
        XCTAssertEqual(simulator.pages[ccPage], before, "the OTP page must be untouched")
    }

    /// NTAG 210µ ships NDEF-preformatted (rev 3.0 Table 4), so the op is offered
    /// but always refuses on a factory tag — worth pinning, because it means a
    /// 210µ can never spend its one CC write by accident.
    func test_formatVirginCC_refusesOnAFactoryNTAG210Micro() async throws {
        let simulator = NTAG210MicroSimulator()
        let ccPage = try XCTUnwrap(simulator.profile?.memoryLayout.ccPage)
        let before = simulator.pages[ccPage]

        let model = IrreversibleOpsFlowModel(factory: TapFactory(chip: simulator), expectedUID: simulator.uid)
        await model.perform(.formatVirginCC)

        XCTAssertTrue(model.isErrored, "expected refusal, got \(model.phase)")
        XCTAssertEqual(simulator.pages[ccPage], before)
    }

    // MARK: - Permanently lock signature (LOCK_SIG)

    /// The full sequence that will run on hardware: READ_SIG → `AC 02` →
    /// READ_SIG unchanged → `AC 00` must be refused.
    ///
    /// **The order is the assertion.** The unlock probe exists to be refused,
    /// and a refusal returns a Type-2 tag to HALT, so it has to be the last
    /// frame the operation issues. Now that `NTAG21xSimulator.nak()` halts,
    /// putting the read-back after the probe fails this test — which is how the
    /// live NTAG 210µ run of 2026-08-07 behaved, locking the signature
    /// correctly and then reporting failure on a read that could not land.
    func test_lockSignature_permanentlyLocks_andProvesItBehaviourally() async {
        let simulator = NTAG210MicroSimulator()
        let signatureBefore = simulator.signature
        XCTAssertEqual(simulator.signatureLock, .locked, "factory state is reversibly locked")

        let model = IrreversibleOpsFlowModel(factory: TapFactory(chip: simulator), expectedUID: simulator.uid)
        await model.perform(.lockSignature)

        XCTAssertTrue(model.isDone, "expected success, got \(model.phase)")
        XCTAssertEqual(simulator.signatureLock, .permanentlyLocked)
        XCTAssertEqual(simulator.signature, signatureBefore, "permanent lock must not alter the signature")
        // And the state really is terminal — this is what the op's `AC 00` probe
        // observed, re-asserted directly against the chip.
        XCTAssertEqual(simulator.handle(command: Data([0xAC, 0x00])), Data([0x00]), "unlock must NAK")
        XCTAssertEqual(simulator.signatureLock, .permanentlyLocked)
    }

    /// Defence in depth: `applies(to:)` already keeps this off plain NTAG21x,
    /// but if it were ever issued there the chip NAKs `AC 02` and the op must
    /// stop at the unacknowledged lock rather than proceeding to probe.
    func test_lockSignature_stopsWhenTheChipNAKsTheLock() async {
        let simulator = NTAG215Simulator()
        let model = IrreversibleOpsFlowModel(factory: TapFactory(chip: simulator), expectedUID: simulator.uid)
        await model.perform(.lockSignature)

        XCTAssertTrue(model.isErrored, "expected refusal, got \(model.phase)")
        XCTAssertEqual(simulator.signatureLock, .locked, "state must be untouched")
    }

    /// "Refusing to lock a signature we can't verify" — if READ_SIG doesn't
    /// return 32 bytes, we cannot prove afterwards that the signature survived,
    /// so `AC 02` must never be issued.
    func test_lockSignature_refusesWhenTheSignatureCannotBeVerified() async {
        let simulator = ShortSignatureMicroSimulator()
        let model = IrreversibleOpsFlowModel(factory: TapFactory(chip: simulator), expectedUID: simulator.uid)
        await model.perform(.lockSignature)

        XCTAssertTrue(model.isErrored, "expected refusal, got \(model.phase)")
        XCTAssertEqual(simulator.signatureLock, .locked, "LOCK_SIG must not have been issued")
    }

    // MARK: - SLIX write-password latch (two taps)

    /// The only coverage `Iso15693ProtectionClient` has outside a live tap.
    ///
    /// The factory calls `endSession()` between taps, which is the whole point:
    /// a SLIX2 leaves the write gate open for the remainder of the tap that set
    /// the password, so a harness that reused one activation would report
    /// "NOT ENFORCED" against silicon that enforces perfectly well.
    func test_slixPasswordLatch_observesEnforcement_thenResetsToTheFactoryValue() async throws {
        let simulator = Iso15693Simulator.slix2()
        let factory = TapFactory(chip: simulator)
        let model = IrreversibleOpsFlowModel(
            factory: factory,
            expectedUID: simulator.uid,
            interSessionCooldown: .zero
        )
        await model.perform(.slixPasswordLatch)

        let summary = try XCTUnwrap(model.doneSummary, "expected success, got \(model.phase)")
        XCTAssertTrue(summary.contains("ENFORCED"), summary)
        XCTAssertFalse(summary.contains("NOT ENFORCED"), "the gate should have refused the unauthenticated write")
        XCTAssertEqual(factory.tapCount, 2, "arming and probing must happen on separate activations")

        // **The gate is not permanent.** This asserted the opposite until
        // 2026-08-07, on the belief that setting a password armed the gate and
        // that the gate latched. Neither is true: `PROTECT PAGE` (§9.5.3.6)
        // arms it and `PROTECT PAGE` with status `00h` clears it, staying
        // reversible until `LOCK PAGE PROTECTION CONDITION`, which is never
        // sent. Only the password itself is unclearable, hence the reset to the
        // delivered-IC value rather than a claim the credential is gone.
        //
        // **And that value is the datasheet's, not an invented one.** This
        // asserted `FF FF FF FF` until the removal path was corrected: the app
        // wrote a value nothing else in the system expected, while `enable`
        // presents `00 00 00 00` (SL2S2602 §9.2.3) by default, so protect,
        // remove, protect could never close. Worse, §9.5.3.2 makes the failed
        // presentation stop the IC executing anything further until a power-on
        // reset, so the wrong guess took the whole tap with it.
        XCTAssertEqual(simulator.pageProtection, 0, "removal must clear the access conditions")
        XCTAssertEqual(simulator.passwords[.write], Iso15693Passwords.factoryReadWrite)

        // Prove the reset landed: on a fresh tap the factory password unlocks
        // writes. Without this the op could report success having left the tag
        // holding the harness password.
        simulator.endSession()
        let tag = try await SimulatedSession(chip: simulator).start(alert: "")
        _ = try await tag.authenticate(.type5(password: Iso15693Passwords.factoryReadWrite, kind: .write))
        let write = try await tag.transceive(RawCommand(
            bytes: Data([0x02, Iso15693Opcode.writeSingleBlock, 0x02, 0x00, 0x00, 0x00, 0x00]),
            name: "WRITE_SINGLE_BLOCK (factory password)"
        ))
        XCTAssertEqual(write.first, 0x00, "the factory password must unlock writes: \(write.hexString)")

        // And the door is now closed both ways: a second protect, with no
        // credential in hand, works. That is what the invented default broke.
        simulator.endSession()
        let reprotect = try await SimulatedSession(chip: simulator).start(alert: "")
        try await reprotect.enableProtection(.type5(write: Data([0x5A, 0x5A, 0x5A, 0x5A]), read: nil, kind: .write))
        XCTAssertEqual(simulator.pageProtection, 0x20, "protect → remove → protect must close")
    }

    /// **A UID tail does not identify a tag.**
    ///
    /// Two MIFARE Ultralight C tags from our own stock, live-dumped 2026-08-07,
    /// share SN3-SN6 exactly and differ only in SN1-SN2. The typed-UID gate used
    /// the last four hex characters, so every tag in that batch showed `7780`
    /// and the confirmation could not distinguish one from another.
    ///
    /// The scan-time full-UID comparison always prevented acting on the wrong
    /// tag, so this was never a route to bricking one, but the gate exists to
    /// make the choice deliberate and it was not doing that.
    @MainActor
    func test_typedUIDGate_distinguishesTagsThatShareAUIDTail() {
        let tagA = Data([0x04, 0xB8, 0xEC, 0xCA, 0x79, 0x77, 0x80])
        let tagB = Data([0x04, 0xAB, 0x51, 0xCA, 0x79, 0x77, 0x80])
        XCTAssertEqual(tagA.suffix(4), tagB.suffix(4), "precondition: these tags share their tail")

        let a = IrreversibleOpsFlowModel(factory: TapFactory(chip: NTAG213Simulator()), expectedUID: tagA)
        let b = IrreversibleOpsFlowModel(factory: TapFactory(chip: NTAG213Simulator()), expectedUID: tagB)
        let codeA = a.uidTail
        let codeB = b.uidTail
        XCTAssertNotEqual(codeA, codeB, "the gate must not read identically for two tags")
        // The whole UID is transcribed, so it carries every distinguishing byte.
        XCTAssertEqual(codeA.count, 14)
    }
}

// MARK: - Helpers

private extension IrreversibleOpsFlowModel {
    var isIdle: Bool {
        if case .idle = phase {
            return true
        }
        return false
    }

    var isDone: Bool {
        if case .done = phase {
            return true
        }
        return false
    }

    var isErrored: Bool {
        if case .error = phase {
            return true
        }
        return false
    }

    var doneSummary: String? {
        if case .done(let summary) = phase {
            return summary
        }
        return nil
    }

    /// Select → confirm → run, awaiting the flow's terminal phase. Mirrors what
    /// the view does: `select` moves to the typed-UID confirmation, and only a
    /// matching entry calls `confirmAndExecute`.
    func perform(_ operation: Operation, timeout: Duration = .seconds(2)) async {
        select(operation)
        guard case .confirming = phase else { return }
        confirmAndExecute()
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if isDone || isErrored {
                return
            }
            await Task.yield()
        }
    }
}

/// Vends one session per tap over the **same** chip, ending the previous
/// activation on the way in. Modelling the tap boundary is load-bearing for the
/// SLIX latch, whose write unlock lasts exactly one activation.
private final class TapFactory: TagSessionFactory, @unchecked Sendable {
    let chip: ChipSimulator
    private(set) var tapCount = 0

    init(chip: ChipSimulator) {
        self.chip = chip
    }

    func makeSession() -> TagSession {
        tapCount += 1
        (chip as? Iso15693Simulator)?.endSession()
        return SimulatedSession(chip: chip)
    }
}

/// An NTAG 210µ whose READ_SIG comes back short — the case where the op cannot
/// prove the signature survived and so must never issue the lock.
private final class ShortSignatureMicroSimulator: NTAG21xSimulator, @unchecked Sendable {
    init() {
        super.init(
            variant: .ntag210Micro,
            profile: ChipCatalog.require(.ntag210Micro),
            uid: NTAG210MicroSimulator.defaultUID,
            signature: Data(repeating: 0x5A, count: 16)
        )
    }

    override func versionBlock() -> Data {
        Data([0x00, 0x04, 0x04, 0x02, 0x02, 0x00, 0x0B, 0x03])
    }
}
#endif
