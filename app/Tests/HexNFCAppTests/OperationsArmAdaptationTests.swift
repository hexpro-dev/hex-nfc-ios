@testable import HexNFCApp
@testable import HexNFCKit
@testable import HexNFCRecords
import HexNFCStorage
@testable import HexNFCTagSim
import XCTest

/// The standalone Protect operation adapts to the chip it turns out to be
/// holding, and arms nothing until it has read one.
///
/// It used to build a Type-2 `PendingProtection` in the screen's `launch()`,
/// before any tap, so three of the four families this app can protect reached
/// the tag only to be refused: the preamble's own guard compares the staged
/// family against the chip's backend and threw `capabilityUnsupported` on the
/// identify tap. The user read that as the chip refusing to be protected, which
/// it was not, and the intro copy said the same thing in longer words.
@MainActor
final class OperationsArmAdaptationTests: XCTestCase {
    private let password = Data([0x0A, 0x0B, 0x0C, 0x0D])
    private let pack = Data([0x1E, 0x2F])

    private func protectRun(on chip: ChipSimulator) -> OperationsFlowModel {
        OperationsFlowModel(
            factory: SingleChipFactory(chip: chip),
            operation: .enableProtection(ProtectionArm.unstaged),
            credentials: InMemoryTagCredentialStore()
        )
    }

    // MARK: - Nothing is staged before a tag has been read

    /// A run built by the screen's `init` asserts no family, which is what lets
    /// the identify tap reach a chip of any family at all.
    func test_theRunStagesNothingUntilATagHasBeenRead() {
        let model = protectRun(on: NTAG213Simulator())

        XCTAssertTrue(model.requiresProtectionSettings)
        XCTAssertNil(
            model.armingStyle,
            "a staged style turns on the preamble's two chip guards, and on the identify tap there is "
                + "nothing yet to compare against but a guess"
        )
    }

    /// The four families the app has a protection backend for all reach the
    /// typed-UID gate. Each of the last three used to end the identify tap on
    /// `capabilityUnsupported`.
    func test_everyProtectableFamilyReachesTheGate() async {
        let chips: [(String, ChipSimulator)] = [
            ("NTAG213", NTAG213Simulator()),
            ("NTAG424 DNA", NTAG424DNASimulator()),
            ("Ultralight C", MifareUltralightCSimulator()),
            ("ICODE SLIX2", Iso15693Simulator(blockCount: 80)),
        ]
        for (name, chip) in chips {
            let model = protectRun(on: chip)
            let run = Task { await model.begin() }
            await untilSettledOrGated(model)
            guard case .awaitingConfirmation = model.phase else {
                model.cancel()
                await run.value
                return XCTFail("\(name) did not reach the gate, got \(model.phase)")
            }
            XCTAssertNotNil(model.reading?.style, "\(name) reached the gate with no family to render")
            model.cancel()
            await run.value
        }
    }

    /// The gate does not open while the arm is a placeholder, so a run cannot
    /// reach a tag carrying one.
    func test_theGateStaysShutWhileTheArmIsUnstaged() async {
        let chip = NTAG213Simulator()
        let faults = FaultInjectingSessionFactory(chip: chip)
        let model = OperationsFlowModel(
            factory: faults, operation: .enableProtection(ProtectionArm.unstaged),
            credentials: InMemoryTagCredentialStore()
        )

        let run = Task { await model.begin() }
        await untilSettledOrGated(model)
        model.confirm()
        for _ in 0 ..< 20 {
            await Task.yield()
        }

        guard case .awaitingConfirmation = model.phase else {
            await run.value
            return XCTFail("the gate must stay shut, got \(model.phase)")
        }
        XCTAssertEqual(faults.tapCount, 1, "no second session may open")
        XCTAssertEqual(try chip.readProtectionState()?.passwordProtect, false)

        model.cancel()
        await run.value
    }

    // MARK: - The arm the fields describe actually lands

    /// The end-to-end proof for the family whose key this route could never
    /// carry: fields typed at the gate, the tag armed with that 3DES key.
    func test_anUltralightCArmReachesTheTagWithItsOwnKey() async throws {
        let chip = try MifareUltralightCSimulator(
            ndefMessage: NDEFCodec.encode([.text(TextRecord(text: "seed"))])
        )
        let keyHex = Data((0 ..< 16).map { UInt8(0xA0 + $0) }).hexString
        let model = protectRun(on: chip)

        let run = Task { await model.begin() }
        await untilSettledOrGated(model)
        let family = try XCTUnwrap(model.reading?.style?.family)
        XCTAssertEqual(family, .ultralightC)
        var arm = ProtectionArm.seeded(family: family, tagReportsProtection: false)
        arm.keyHex = keyHex
        try model.supplyProtection(XCTUnwrap(arm.pending(for: family)))
        XCTAssertFalse(model.requiresProtectionSettings)
        XCTAssertFalse(model.requiresUnlockCredential, "a fresh tag holds nothing to present")
        model.confirm()
        await until {
            switch model.phase {
            case .done, .error, .needsUnlock: true
            default: false
            }
        }
        if case .done = model.phase {} else {
            let stuck = model.phase
            model.cancel()
            await run.value
            return XCTFail("expected the arm to complete, got \(stuck)")
        }
        await run.value

        guard case .done(.passwordSet) = model.phase else {
            return XCTFail("expected the arm to complete, got \(model.phase)")
        }
        XCTAssertEqual(
            chip.storedKey?.cipherOrder.hexString, keyHex,
            "the tag has to end up holding the key that was typed, not a generated one"
        )
    }

    // MARK: - The read gate, and the two families that must never get one

    func test_aReadGateIsOfferedOnTwoFamiliesOnly() {
        XCTAssertTrue(ProtectionArm.offersReadGate(.type2))
        XCTAssertTrue(ProtectionArm.offersReadGate(.type4))
        XCTAssertFalse(
            ProtectionArm.offersReadGate(.type5),
            "a SLIX2 read gate is privacy mode, and a privacy-mode tag answers no inventory, so CoreNFC "
                + "can never hand it back"
        )
        XCTAssertFalse(
            ProtectionArm.offersReadGate(.ultralightC),
            "a read-gated Ultralight C hides the pages the chip is identified from, so the app can "
                + "never offer to unlock it"
        )
    }

    /// The fields cannot describe a Type-5 read gate whatever the toggle says,
    /// because the screen does not render the toggle for that family and the arm
    /// builder writes `.write` regardless.
    func test_theFieldsNeverDescribeASlix2ReadGate() throws {
        var arm = ProtectionArm(passwordHex: password.hexString)
        arm.readProtect = true
        let pending = try XCTUnwrap(arm.pending(for: .type5))

        XCTAssertEqual(pending.settings.style, .type5(.init(kind: .write)))
        XCTAssertFalse(pending.settings.readProtect)
    }

    /// And the run corrects one that arrives anyway, so the rule holds for a
    /// model built straight from an `Operation` as well as for one the screen
    /// staged.
    ///
    /// Stated against the spec rather than against the wire on purpose. The
    /// SLIX2 simulator answers `readGateState()`, so a frame-level assertion here
    /// would not discriminate; `ProtectionSpec.type5`'s `read` field is what
    /// `Iso15693ProtectionClient.enable` branches on, and a non-nil one is
    /// privacy mode.
    func test_theArmCanNeverBuildASlix2ReadPassword() {
        for kind: ProtectionStyle.Type5Settings.Kind in [.write, .read, .readWrite] {
            let requested = PendingProtection(
                settings: TagProtection(passwordProtect: true, style: .type5(.init(kind: kind))),
                credential: .type5(password: password, kind: kind)
            )
            let armable = OperationsFlowModel.armable(requested)
            let spec = ProtectionSpec.make(
                settings: armable.settings, credential: armable.credential, defaultFirstDataPage: 4
            )
            guard case .type5(let write, let read, let resolvedKind)? = spec else {
                return XCTFail("expected a Type-5 spec for \(kind), got \(String(describing: spec))")
            }
            XCTAssertNil(read, "a read password arms privacy mode and the tag stops answering inventory")
            XCTAssertEqual(write, password)
            XCTAssertEqual(resolvedKind, .write)
        }
    }

    /// The same correction for the other family with an unreachable read gate.
    func test_theArmCanNeverBuildAnUltralightCReadGate() throws {
        let key = try UltralightCKey(cipherOrder: Data(repeating: 0x5A, count: 16))
        let requested = PendingProtection(
            settings: TagProtection(
                passwordProtect: true,
                style: .ultralightC(.init(protectFromPage: 4, readProtect: true))
            ),
            credential: .ultralightC(key: key)
        )

        let armable = OperationsFlowModel.armable(requested)

        XCTAssertEqual(armable.settings.style, .ultralightC(.init(protectFromPage: 4, readProtect: false)))
    }

    // MARK: - Seeding

    /// The editor card's rule, reused rather than restated: a default is only
    /// safe where there is nothing to overwrite. A tag that reports protection,
    /// or whose state could not be read, opens with an empty field, so the only
    /// affirmative control on the screen cannot re-key a live tag on a value
    /// nobody typed.
    func test_theSeedLeavesTheFieldEmptyForATagThatMayHoldACredential() {
        XCTAssertEqual(
            ProtectionArm.seeded(family: .type2, tagReportsProtection: true).passwordHex, ""
        )
        XCTAssertEqual(
            ProtectionArm.seeded(family: .type2, tagReportsProtection: false).passwordHex, "FF:FF:FF:FF"
        )
        XCTAssertEqual(
            ProtectionArm.seeded(family: .ultralightC, tagReportsProtection: true, randomKey: { "GENERATED" })
                .keyHex,
            "",
            "an Ultralight C that may already hold a key must not be handed a generated one: the write "
                + "re-keys it on the way past and nothing in the app ever shows that key again"
        )
        XCTAssertEqual(
            ProtectionArm.seeded(family: .ultralightC, tagReportsProtection: false, randomKey: { "GENERATED" })
                .keyHex,
            "GENERATED"
        )
    }

    /// Which families seed to an arm the gate will accept without the user
    /// typing anything, and which deliberately do not.
    ///
    /// Recorded because the owner hit a dead Protect button on an Ultralight C
    /// on 2026-09-22 and had to retype a character of a prefilled field before
    /// it woke up. Whatever caused that, this is the layer to rule in or out:
    /// the seed and the staging rule are pure, so if they agree here the fault
    /// is above them in the view.
    func test_whichFamiliesSeedToAnArmTheGateAccepts() {
        let stageable: [ProtectionStyle.Family: Bool] = [
            // A generated key, so the safe option is the one already chosen.
            .ultralightC: true,
            // The delivery password, on a tag that reports holding none.
            .type2: true,
            // Empty by design: an AES key is not something to generate quietly.
            .type4: false,
            // Empty by design, always, whatever the tag reports.
            .type5: false,
        ]
        for (family, expected) in stageable {
            let arm = ProtectionArm.seeded(family: family, tagReportsProtection: false)
            XCTAssertEqual(
                arm.pending(for: family) != nil, expected,
                "\(family) seeded on an unprotected tag"
            )
        }
    }

    /// A half-typed field is not an arm, so the gate cannot open on one.
    func test_aHalfTypedFieldIsNotAnArm() {
        var arm = ProtectionArm(passwordHex: "FF:FF:FF:FF", packHex: "00")
        XCTAssertNil(arm.pending(for: .type2), "a 1-byte PACK is not a PACK")
        arm.packHex = "00:00"
        XCTAssertNotNil(arm.pending(for: .type2))
        XCTAssertNil(ProtectionArm(keyHex: "AABB").pending(for: .type4))
    }

    // MARK: - Helpers

    private func untilSettledOrGated(_ model: OperationsFlowModel) async {
        await until {
            switch model.phase {
            case .awaitingConfirmation, .needsUnlock, .done, .error: true
            default: false
            }
        }
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

private final class SingleChipFactory: TagSessionFactory, @unchecked Sendable {
    private let chip: ChipSimulator

    init(chip: ChipSimulator) {
        self.chip = chip
    }

    func makeSession() -> TagSession {
        SimulatedSession(chip: chip)
    }
}
