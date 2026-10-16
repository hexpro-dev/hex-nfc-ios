@testable import HexNFCKit
import HexNFCTagSim
import HexNFCTestKit
import XCTest

/// Anti-drift guard: runs the *same* `TagTestPlan.plan(for:)` the live harness
/// runs, but against each chip simulator. Because the plan and runner are
/// session-agnostic, a live step that fails an expectation the simulator passes
/// is — by construction — the divergence signal the harness is built to surface.
/// Here we assert every simulator satisfies its own plan and ends blank +
/// unprotected, so the plans stay honest as the simulators evolve.
/// Counts the sessions a `makeChip:` closure has been asked for, so a test can
/// vend a different tag on a later tap.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.withLock {
            defer { value += 1 }
            return value
        }
    }
}

final class TestKitPlanTests: XCTestCase {
    private func simulators() -> [(label: String, chip: ChipSimulator)] {
        [
            ("NTAG 210µ", NTAG210MicroSimulator()),
            ("NTAG213", NTAG213Simulator()),
            ("NTAG213 TT", NTAG213TTSimulator()),
            ("NTAG215", NTAG215Simulator()),
            ("NTAG216", NTAG216Simulator()),
            ("UL EV1 48", MifareUltralightEV1_48Simulator()),
            ("UL EV1 128", MifareUltralightEV1_128Simulator()),
            // Factory-state variants. A real MIFARE Ultralight EV1 ships with a
            // blank OTP Capability Container and a real ICODE SLIX2 with no CC at
            // all, and both refuse NDEF operations in that state. The plans must
            // stay clean against the *arrival* state, not just a formatted one.
            ("UL EV1 128 (virgin)", MifareUltralightEV1_128Simulator(virgin: true)),
            ("UL EV1 48 (virgin)", MifareUltralightEV1_48Simulator(virgin: true)),
            // Ultralight C ships unformatted, so the plain simulator IS the
            // factory-state case; the formatted one is the variant worth
            // naming, since it only exists after a gated `formatVirginCC`.
            ("Ultralight C (virgin)", MifareUltralightCSimulator()),
            ("Ultralight C (formatted)", MifareUltralightCSimulator(ndefMessage: Data())),
            ("EM V10", EmV10Simulator()),
            ("EM V11", EmV11Simulator()),
            ("EM V16", EmV16Simulator()),
            ("NTAG424 DNA", NTAG424DNASimulator()),
            ("DESFire EV3 4K", DESFireEV3Simulator()),
            ("ICODE SLIX", Iso15693Simulator()),
            ("ICODE SLIX2 (80 blocks)", Iso15693Simulator(blockCount: 80)),
            ("ICODE SLIX2 (virgin)", Iso15693Simulator(virgin: true)),
            ("Suica", SuicaSimulator()),
            ("ePassport", EPassportSimulator()),
        ]
    }

    func test_allSimulators_passPlanAndEndClean() async throws {
        for (label, simulator) in simulators() {
            let profile = try XCTUnwrap(simulator.profile, "\(label): simulator has no profile")
            let plan = TagTestPlan.plan(for: profile)
            let report = await TagTestRunner(plan: plan).run(using: SimulatedSessionFactory(chip: simulator))

            XCTAssertTrue(report.passed, "\(label): suite failed\n\(report.plainTextLog)")
            XCTAssertFalse(report.cleanupLeftTagProtected, "\(label): left protected\n\(report.footer)")
            XCTAssertFalse(
                report.cleanupResults.contains { $0.status == .failed },
                "\(label): cleanup failed\n\(report.plainTextLog)"
            )
            XCTAssertTrue(report.isCleanPass, "\(label): not a clean pass\n\(report.footer)")

            // Every skipped step must be a genuine capability skip — nothing the
            // chip advertises should go untested.
            for result in report.results where result.status == .skipped {
                XCTAssertEqual(
                    result.skipReason, "required capability not advertised by this chip",
                    "\(label): step '\(result.name)' skipped for a non-capability reason"
                )
            }
        }
    }

    /// The batch runner's default options must never include the irreversible
    /// tier — the destructive ceiling is enforced in code, not just convention.
    func test_defaultOptions_excludeIrreversible() {
        XCTAssertFalse(TagTestRunner.Options().includeSafety.contains(.irreversible))
    }

    // MARK: - Capability-container state on the report

    /// The gated `formatVirginCC` op is offered per *tag*, not per chip, so the
    /// report has to carry what `t2.ccVerify` saw. A live NTAG213 run on
    /// 2026-08-07 offered the OTP write on a pre-formatted tag because nothing
    /// plumbed this through.
    func test_report_carriesWhetherTheCapabilityContainerWasBlank() async throws {
        let formatted = NTAG213Simulator()
        let profile = try XCTUnwrap(formatted.profile)
        let report = await TagTestRunner(plan: TagTestPlan.plan(for: profile))
            .run(using: SimulatedSessionFactory(chip: formatted))
        XCTAssertEqual(
            report.capabilityContainerIsBlank, false,
            "a factory NTAG213 ships pre-formatted, so its CC is not blank"
        )
    }

    func test_report_reportsABlankCCOnAVirginTag() async throws {
        let virgin = MifareUltralightCSimulator()
        let profile = try XCTUnwrap(virgin.profile)
        let report = await TagTestRunner(plan: TagTestPlan.plan(for: profile))
            .run(using: SimulatedSessionFactory(chip: virgin))
        XCTAssertEqual(
            report.capabilityContainerIsBlank, true,
            "Ultralight C ships with page 3 blank (rev 3.3 Table 13)"
        )
    }

    // MARK: - Multi-tap

    /// The Type-2 credential questions live in three separate activations,
    /// because the tag will not answer them in one.
    ///
    /// AUTH0 latches at the next activation, so tap 0 can only read back what it
    /// just wrote; PWD and PACK read back as zeros by design, so the credential
    /// can only be asked by presenting one; and a refused `PWD_AUTH` NAKs, which
    /// returns the chip to HALT for the rest of the tap. Hence tap 1, tap 2, and
    /// a fourth activation for cleanup, which would otherwise run against a chip
    /// that answers nothing.
    func test_type2Plan_asksTheCredentialQuestionsInSeparateTaps() async throws {
        let sim = NTAG213Simulator()
        let profile = try XCTUnwrap(sim.profile)
        let plan = TagTestPlan.plan(for: profile)
        let factory = SimulatedSessionFactory(chip: sim)

        let report = await TagTestRunner(plan: plan).run(using: factory)

        XCTAssertTrue(report.passed, "suite failed\n\(report.plainTextLog)")
        XCTAssertEqual(report.plannedTaps, 4, "taps 0-2 for the suite, plus one for cleanup")
        XCTAssertEqual(report.tapCount, 4, "every planned tap must actually be opened")
        XCTAssertTrue(report.isCleanPass, "\(report.footer)")

        let byID = Dictionary(uniqueKeysWithValues: report.results.map { ($0.id, $0) })
        for id in ["t2.password.credentialReverts", "t2.password.oldCredentialRefused"] {
            let step = try XCTUnwrap(byID[id], "\(id) missing from the plan")
            XCTAssertEqual(step.status, .passed, "\(id): \(step.plainTextLine)")
        }
        let taps = Dictionary(uniqueKeysWithValues: plan.steps.map { ($0.id.rawValue, $0.tap) })
        XCTAssertEqual(taps["t2.password"], 0)
        XCTAssertEqual(taps["t2.password.credentialReverts"], 1)
        XCTAssertEqual(taps["t2.password.oldCredentialRefused"], 2)
        XCTAssertEqual(plan.cleanupTap, 3, "tap 2 ends its activation, so cleanup needs a fresh one")
    }

    /// The assertion the 2026-09-04 incident wanted, stated against the tag
    /// rather than against the runner's opinion of it.
    ///
    /// `sim.authenticate` is the seed-and-assert helper, not a production path:
    /// it reads the PWD page the driver can never read back (NTAG213 rev 3.2
    /// section 8.8 serves zeros there), which is the only way a test can say
    /// what credential the tag is actually holding.
    func test_afterAFullPass_theTagHoldsTheFactoryCredentialAndNotTheArmedOne() async throws {
        let sim = NTAG213Simulator()
        let profile = try XCTUnwrap(sim.profile)
        let plan = TagTestPlan.plan(for: profile)

        let report = await TagTestRunner(plan: plan).run(using: SimulatedSessionFactory(chip: sim))
        XCTAssertTrue(report.passed, "suite failed\n\(report.plainTextLog)")

        sim.beginActivation()
        XCTAssertEqual(
            try sim.authenticate(password: Type2Credential.factoryPassword),
            Type2Credential.factoryPack,
            "the removal must leave the datasheet factory credential, not an invented one"
        )
        sim.beginActivation()
        XCTAssertThrowsError(try sim.authenticate(password: plan.credentials.type2Password)) { error in
            XCTAssertEqual((error as? TagError)?.kind, .authFailed,
                           "the password the suite armed must no longer open the tag")
        }
    }

    /// A removal that opens the gate and never resets the credential leaves the
    /// tag holding a password the app believes is gone. That is the desync, and
    /// it is what tap 2 is for.
    ///
    /// `.dropped` rather than a NAK on purpose: the frame never reaches the chip,
    /// so nothing refuses and nothing halts. The removal therefore still proves
    /// the gate open, `t2.password` still passes (tidy-up is not allowed to fail
    /// an operation), and the *only* thing left to catch it is a later tap
    /// presenting the old credential.
    func test_aRemovalThatNeverResetTheCredential_isCaughtOnTheSecondTap() async throws {
        let sim = NTAG213Simulator()
        let profile = try XCTUnwrap(sim.profile)
        let layout = try XCTUnwrap(Type2ConfigLayout.for(.ntag213))
        let plan = TagTestPlan.plan(for: profile)

        let factory = FaultInjectingSessionFactory(chip: sim)
        // PWD write 1 is the arming credential; write 2 is the removal's reset.
        factory.arm(TagFault(.write(page: layout.pwdPage), .dropped, on: .nth(2)))

        let report = await TagTestRunner(plan: plan).run(using: factory)

        let byID = Dictionary(uniqueKeysWithValues: report.results.map { ($0.id, $0) })
        XCTAssertEqual(byID["t2.password"]?.status, .passed,
                       "the removal proved the gate open, so it is a success with residue")
        let probe = try XCTUnwrap(byID["t2.password.oldCredentialRefused"])
        XCTAssertEqual(probe.status, .failed, "the armed password still works: \(probe.plainTextLine)")
        XCTAssertFalse(report.passed, "a suite that found a live stale credential has not passed")

        // And the tag really is holding it, which is the whole claim.
        sim.beginActivation()
        XCTAssertEqual(try sim.authenticate(password: plan.credentials.type2Password),
                       plan.credentials.type2Pack)
    }

    /// A removal torn at the credential tidy-up still leaves the tag OPEN, and
    /// the report has to say so.
    ///
    /// `.lostACK` is the abort point the incident actually hit: the chip applies
    /// the write and the answer never arrives. The gate is already down by then,
    /// so the tag is unlocked either way, and a report that called this a failure
    /// is what stranded a real NTAG213.
    func test_aRemovalTornAtTheCredentialTidyUp_stillReportsTheTagAsOpen() async throws {
        let sim = NTAG213Simulator()
        let profile = try XCTUnwrap(sim.profile)
        let layout = try XCTUnwrap(Type2ConfigLayout.for(.ntag213))
        let plan = TagTestPlan.plan(for: profile)

        let factory = FaultInjectingSessionFactory(chip: sim)
        // PACK write 1 arms the credential; write 2 is the removal's reset, and
        // it is the last write of the sequence.
        factory.arm(TagFault(.write(page: layout.packPage), .lostACK, on: .nth(2)))

        let report = await TagTestRunner(plan: plan).run(using: factory)

        XCTAssertEqual(factory.report.swallowed.count, 1, "the fault must have fired exactly once")
        XCTAssertTrue(report.passed, "a torn tidy-up is not a failed removal\n\(report.plainTextLog)")
        XCTAssertFalse(report.cleanupLeftTagProtected, "the gate was down before the tear")

        // The tag itself, not the report: AUTH0 past the last page is open.
        sim.beginActivation()
        let state = try XCTUnwrap(try sim.readProtectionState())
        XCTAssertFalse(state.passwordProtect, "the tag must be left unprotected")
    }

    /// Nothing the batch runs may burn a lock bit, on a protected tag or any
    /// other.
    ///
    /// The second half of the 2026-09-04 incident was a permanent lock fired at a
    /// still-gated tag: page 2 sits below AUTH0 so the static lock bytes burned,
    /// page 0x28 sits above it so the dynamic lock was refused. The batch's
    /// defence is that it never sends the command at all, and this asserts that
    /// over the frames rather than over the plan's own labels.
    func test_theBatchNeverSendsALockWrite_andHoldsNoIrreversibleStep() async throws {
        let sim = NTAG213Simulator()
        let profile = try XCTUnwrap(sim.profile)
        let layout = try XCTUnwrap(profile.type2ConfigLayout)
        let plan = TagTestPlan.plan(for: profile)

        // No faults armed: the seam is a pure recorder here.
        let factory = FaultInjectingSessionFactory(chip: sim)
        let report = await TagTestRunner(plan: plan).run(using: factory)
        XCTAssertTrue(report.passed, "\(report.plainTextLog)")

        var lockPages = [layout.staticLockPage]
        if let dynamic = layout.dynamicLockPage {
            lockPages.append(dynamic)
        }
        for page in lockPages {
            XCTAssertTrue(
                factory.report.frames(matching: .write(page: page)).isEmpty,
                "the batch wrote lock page \(page)"
            )
        }
        XCTAssertFalse(sim.isLockedPermanent, "the batch must never lock a tag")
        XCTAssertTrue(
            (plan.steps + plan.cleanup).allSatisfy { $0.safety != .irreversible },
            "an irreversible step may not sit in a batch plan"
        )
    }

    /// A plan run over a single session skips the taps it cannot take, says so,
    /// and cannot record a clean pass.
    ///
    /// The compatibility path exists for the fourteen callers that hand over one
    /// session. What it must never do is let a cross-tap assertion report a
    /// verdict it never established, so the steps are skipped with a stated
    /// reason and the shortfall is visible on the report.
    func test_aSingleSessionRun_skipsTheCrossTapStepsAndIsNotACleanPass() async throws {
        let sim = NTAG213Simulator()
        let profile = try XCTUnwrap(sim.profile)
        let report = await TagTestRunner(plan: TagTestPlan.plan(for: profile))
            .run(using: SimulatedSession(chip: sim))

        XCTAssertEqual(report.tapCount, 1)
        XCTAssertEqual(report.plannedTaps, 4, "the plan still needed four; this run took one")
        XCTAssertFalse(report.isCleanPass, "\(report.footer)")

        let byID = Dictionary(uniqueKeysWithValues: report.results.map { ($0.id, $0) })
        for id in ["t2.password.credentialReverts", "t2.password.oldCredentialRefused"] {
            let step = try XCTUnwrap(byID[id])
            XCTAssertEqual(step.status, .skipped)
            XCTAssertTrue(
                step.skipReason?.contains("TagSessionFactory") == true,
                "the skip must name the fix, got \(step.skipReason ?? "nil")"
            )
        }
        // Cleanup still runs, in the one session there is. A halted run that
        // demanded three more physical taps before it would tidy up would be
        // worse than one that tidied up in the tap it already had.
        XCTAssertTrue(report.cleanupResults.contains { $0.safety == .reversibleWrite })
        XCTAssertFalse(report.cleanupResults.contains { $0.status == .failed },
                       "\(report.plainTextLog)")
        XCTAssertFalse(report.cleanupLeftTagProtected)
    }

    /// A read-only pass never asks for a second tap.
    ///
    /// The mode exists for one-of-a-kind tags, where the identity capture is the
    /// point and you may only get the one presentation. Its cap is what makes
    /// that promise, and the reversible tier is filtered out before the tap
    /// budget is ever consulted, so the cross-tap steps are not even planned.
    func test_aReadOnlyPass_takesExactlyOneTap() async throws {
        let sim = NTAG213Simulator()
        let profile = try XCTUnwrap(sim.profile)
        let options = TagTestRunner.Options(includeSafety: [.readOnly], maximumTaps: 1)
        let factory = SimulatedSessionFactory(chip: sim)

        let report = await TagTestRunner(plan: TagTestPlan.plan(for: profile), options: options)
            .run(using: factory)

        XCTAssertEqual(report.tapCount, 1)
        XCTAssertEqual(report.plannedTaps, 1, "no reversible step survived the filter, so no later tap")
        XCTAssertTrue(report.passed, "\(report.plainTextLog)")
    }

    /// A different tag presented for a later tap abandons the run.
    ///
    /// The cross-tap assertions are all of the form "the tag the suite armed now
    /// holds X". Answered by a second tag they are not weaker, they are about
    /// something else entirely, and cleanup aimed at a tag the run never touched
    /// is worse than no cleanup at all. So the run stops, says which tap saw the
    /// wrong UID, and refuses to claim anything about the tag it started on.
    func test_aDifferentTagOnALaterTap_abandonsTheRunRatherThanAnsweringWithIt() async throws {
        let first = NTAG213Simulator()
        let profile = try XCTUnwrap(first.profile)
        let stranger = NTAG213Simulator(uid: Data([0x04, 0x99, 0x99, 0x99, 0x99, 0x99, 0x99]))
        XCTAssertNotEqual(first.uid, stranger.uid, "precondition: two distinguishable tags")

        // Tap 0 gets the tag the run starts on; every later tap gets the other.
        let taps = Counter()
        let factory = SimulatedSessionFactory(makeChip: { taps.next() == 0 ? first : stranger })

        let report = await TagTestRunner(plan: TagTestPlan.plan(for: profile)).run(using: factory)

        let wrongTag = try XCTUnwrap(
            report.results.first { $0.id == "session.wrongTag" },
            "the run must record which tap saw the wrong tag\n\(report.plainTextLog)"
        )
        XCTAssertEqual(wrongTag.status, .failed)
        XCTAssertEqual(
            report.results.first { $0.id == "t2.password.oldCredentialRefused" }?.status, .skipped,
            "a cross-tap assertion may not be answered by a different tag"
        )
        XCTAssertTrue(report.cleanupResults.isEmpty, "cleanup must not run against a tag it cannot identify")
        XCTAssertFalse(report.isCleanPass)
    }

    /// The post-cleanup invariant must survive a chip that has stopped answering.
    ///
    /// `TagTestRunner` probes `readProtectionState()` after cleanup through a
    /// `try?`, and on a Type-2 chip a halted tag answers that with nothing. The
    /// `try?` collapses "it refused and halted" and "there is no password
    /// hardware here" into the same `nil`, and the flag would then read false
    /// about a tag that is still gated. That is the one report certain to be
    /// wrong about a tag someone has to recover by hand.
    ///
    /// So the fallback is the last reading a cleanup step took while the tag was
    /// still answering, and this run leaves the tag genuinely protected to prove
    /// the flag follows the tag rather than the silence.
    func test_aCleanupProbeThatReadsNothing_reportsTheLastReadingRatherThanClaimingOpen() async throws {
        let sim = NTAG213Simulator()
        let profile = try XCTUnwrap(sim.profile)
        let layout = try XCTUnwrap(Type2ConfigLayout.for(.ntag213))
        let plan = TagTestPlan.plan(for: profile)

        let factory = FaultInjectingSessionFactory(chip: sim)
        // AUTH0 write 1 arms the gate. Every one after it is refused, so the
        // removal cannot disarm it and neither can cleanup: the tag stays gated
        // and the NAK halts the chip each time.
        factory.arm(TagFault(.write(page: layout.config0Page), .type2NAK, on: .fromNth(2)))

        let report = await TagTestRunner(plan: plan).run(using: factory)

        XCTAssertFalse(report.passed, "the removal could not disarm the gate")
        XCTAssertTrue(
            report.cleanupResults.contains { $0.status == .failed },
            "cleanup could not remove the protection either\n\(report.plainTextLog)"
        )
        XCTAssertTrue(
            report.cleanupLeftTagProtected,
            "the tag is gated and the report must say so\n\(report.plainTextLog)"
        )
        XCTAssertFalse(report.isCleanPass)

        // And the tag really is gated, which is what the flag is about.
        sim.beginActivation()
        let state = try XCTUnwrap(try sim.readProtectionState())
        XCTAssertTrue(state.passwordProtect, "precondition of the assertion above")
    }
}
