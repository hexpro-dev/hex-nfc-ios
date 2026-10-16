@testable import HexNFCApp
@testable import HexNFCKit
@testable import HexNFCRecords
import HexNFCStorage
@testable import HexNFCTagSim
import XCTest

/// What the app is allowed to conclude from a protection read that did not
/// return, and what it must never conclude.
///
/// The project's standing rule is that an ACK is not proof. Its mirror caused
/// two live incidents in a row: a refusal is not proof either. A config-page read
/// that fails means the tag is read-protected *or* that it slipped for an
/// instant, and the two arrive as the same error. Guessing "protected" tells the
/// user their tag is locked when it isn't, which reads as the app having locked
/// it — the exact report that produced this file.
final class ProtectionEvidenceTests: XCTestCase {
    // MARK: - The write flow must not invent a lock

    /// The reported bug. An unprotected NTAG213 drops one config-page read and
    /// the write flow asks for a password the tag has never had. The tag is
    /// answering the whole time, so there is nothing to guess about: retry.
    @MainActor
    func test_writeFlow_aDroppedProtectionReadDoesNotAskForAPassword() async throws {
        let chip = NTAG213Simulator()
        let configPage = try XCTUnwrap(chip.profile?.type2ConfigLayout).config0Page
        let faults = FaultInjectingSessionFactory(chip: chip)
        faults.arm(TagFault(.read(page: configPage), .dropped))
        let model = WriteFlowModel(
            factory: faults,
            dataArea: .replace([.uri(URIRecord(uri: "https://hex.pro"))]),
            credentials: InMemoryTagCredentialStore(),
            uidConfirmation: .required
        )
        await model.begin()

        XCTAssertEqual(
            model.phase,
            .done,
            "a dropped config read must not become a password prompt, got \(model.phase)"
        )
        XCTAssertEqual(
            faults.report.frames(matching: .read(page: configPage)).count, 2,
            "the flow owed the tag a second attempt"
        )
    }

    /// The other half of the same judgement, and the reason the first one can't
    /// be fixed by simply trusting every failed read: a genuinely read-protected
    /// tag must still reach the unlock prompt. Here the tag proves it by rolling
    /// the probe read over to page 0.
    @MainActor
    func test_writeFlow_aReadProtectedTagStillAsksForThePassword() async throws {
        let chip = NTAG213Simulator()
        try chip.enablePasswordProtection(
            password: Data([0xCA, 0xFE, 0xBA, 0xBE]), pack: Data([0x12, 0x34]),
            protectFromPage: 4, readProtect: true, authLimit: 0
        )
        let model = WriteFlowModel(
            factory: SimulatedSessionFactory(chip: chip),
            dataArea: .replace([.uri(URIRecord(uri: "https://hex.pro"))]),
            credentials: InMemoryTagCredentialStore(),
            uidConfirmation: .required
        )
        await model.begin()

        XCTAssertEqual(model.phase, .needsUnlock, "a read-protected tag must prompt, got \(model.phase)")
        XCTAssertFalse(model.unlockFailed, "nothing was tried, so nothing failed")
    }

    /// And the credential we already hold has to survive the probe: the pages it
    /// found gated are ours once we authenticate, so the flow must not read the
    /// pre-read's verdict back as "still locked" and bounce a tag it just opened.
    @MainActor
    func test_writeFlow_aReadProtectedTagWeHoldThePasswordForIsWrittenInOneTap() async throws {
        let chip = NTAG213Simulator()
        let pwd = Data([0xCA, 0xFE, 0xBA, 0xBE])
        let pack = Data([0x12, 0x34])
        try chip.enablePasswordProtection(
            password: pwd, pack: pack, protectFromPage: 4, readProtect: true, authLimit: 0
        )
        let model = WriteFlowModel(
            factory: SimulatedSessionFactory(chip: chip),
            dataArea: .replace([.uri(URIRecord(uri: "https://hex.pro"))]),
            credentials: InMemoryTagCredentialStore(),
            unlockCredential: .type2(password: pwd, pack: pack),
            uidConfirmation: .required
        )
        await model.begin()

        XCTAssertEqual(model.phase, .done, "holding the password should write in one tap, got \(model.phase)")
    }

    /// A tag lifted off the phone is a lost tag, and saying so is recoverable.
    /// Calling it protected is not: it sends the user hunting for a password
    /// that does not exist.
    @MainActor
    func test_writeFlow_aTagThatLeavesTheFieldIsNotCalledProtected() async {
        // Absence is armed on the factory, not on a frame, and that is the whole
        // point. The flow's first act is `ProtectionProbe.presence(of:)`, which
        // goes through `readMemory` and puts no frame on the wire; a tag that
        // only vanished at its next `transceive` would have answered that probe,
        // the probe would have recorded `.answered`, and the config read failing
        // straight after would then have been read as a refusal. That is the
        // 2026-08-14 report exactly: an absent tag called protected.
        let faults = FaultInjectingSessionFactory(chip: NTAG213Simulator())
        faults.tagLeavesTheField()
        let model = WriteFlowModel(
            factory: faults,
            dataArea: .replace([.uri(URIRecord(uri: "https://hex.pro"))]),
            credentials: InMemoryTagCredentialStore(),
            uidConfirmation: .required
        )
        await model.begin()

        guard case .error(_, let diagnostics) = model.phase else {
            return XCTFail("a vanished tag must surface as an error, not \(model.phase)")
        }
        XCTAssertNotEqual(model.phase, .needsUnlock, "and never as a password prompt")
        XCTAssertTrue(
            diagnostics.contains("left the field"),
            "the error the user sees must be the absent tag's own, not one manufactured further down: \(diagnostics)"
        )
    }

    /// The bench defect of 2026-09-22, and the third attempt at this same class
    /// of bug after `38e64fc` and `94fada1`.
    ///
    /// The heuristic those two left behind reads a tag that was answering and
    /// has gone quiet as one halted by its own NAK, which is a good guess and
    /// the wrong one here. A chip that has just answered `PWD_AUTH` with a PACK
    /// is authenticated, so it cannot refuse its own configuration pages for
    /// want of authentication. Silence after that point is the tag leaving, and
    /// nothing else.
    ///
    /// Getting it wrong costs more than a wrong message. The owner is told to
    /// re-enter a password the chip accepted, and offered the delivery default
    /// beside it, which is an invitation to spend a try against an `AUTH_LIM`
    /// the app cannot see.
    @MainActor
    func test_writeFlow_aTagThatLeavesAfterAcceptingThePasswordIsNotCalledRefused() async throws {
        let chip = NTAG213Simulator()
        let pwd = Data([0xCA, 0xFE, 0xBA, 0xBE])
        let pack = Data([0x12, 0x34])
        try chip.enablePasswordProtection(
            password: pwd, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let configPage = try XCTUnwrap(chip.profile?.type2ConfigLayout).config0Page
        let faults = FaultInjectingSessionFactory(chip: chip)
        // Not the first read of that page: that one happens before the
        // credential goes out, and the state-first rule means it must succeed
        // for the flow to know the tag is armed at all.
        faults.arm(TagFault(.read(page: configPage), .leavesTheField, on: .fromNth(2)))
        let model = WriteFlowModel(
            factory: faults,
            dataArea: .replace([.uri(URIRecord(uri: "https://hex.pro"))]),
            credentials: InMemoryTagCredentialStore(),
            unlockCredential: .type2(password: pwd, pack: pack),
            uidConfirmation: .required
        )
        await model.begin()

        XCTAssertNotEqual(
            model.phase, .needsUnlock,
            "the tag accepted this password, so it must never be reported as refusing it"
        )
        XCTAssertFalse(model.unlockFailed, "and nothing here refused a credential")
        XCTAssertTrue(
            faults.report.contains(.opcode(0x1B)),
            "the test is only meaningful if the credential actually went out"
        )
    }

    // MARK: - The scan flow owes the same standard

    /// The scan flow's failure mode is milder — it labels the state "Unknown"
    /// rather than inventing a lock — but a tag that is plainly still answering
    /// deserves the retry rather than the shrug.
    @MainActor
    func test_scanFlow_aDroppedProtectionReadIsRetriedRatherThanReportedUnknown() async throws {
        let chip = NTAG213Simulator()
        let configPage = try XCTUnwrap(chip.profile?.type2ConfigLayout).config0Page
        let faults = FaultInjectingSessionFactory(chip: chip)
        faults.arm(TagFault(.read(page: configPage), .dropped))
        let model = ScanFlowModel(factory: faults)
        await model.begin()

        XCTAssertEqual(model.phase, .ready)
        XCTAssertFalse(model.protectionReadFailed, "the tag answered on the retry, so the state is known")
        XCTAssertEqual(model.detectedProtection?.passwordProtect, false)
        XCTAssertEqual(
            faults.report.frames(matching: .read(page: configPage)).count, 2,
            "the flow owed the tag a second attempt"
        )
    }

    // MARK: - Configuring protection and not writing it must leave no trace

    /// The reported sequence, end to end: switch protection on in the editor,
    /// abandon it without writing, re-scan, delete every record, and clear the
    /// tag. The abandoned configuration must not ride along on that write, and
    /// the tag must scan afterwards without asking for anything.
    @MainActor
    func test_clearingATagAfterAnAbandonedProtectionConfigLeavesItUnprotected() async throws {
        let chip = NTAG213Simulator()
        let factory = SimulatedSessionFactory(chip: chip)

        let seeded: [NDEFRecord] = [.uri(URIRecord(uri: "https://hex.pro"))]
        let seed = WriteFlowModel(
            factory: factory,
            dataArea: .replace(seeded),
            credentials: InMemoryTagCredentialStore(),
            uidConfirmation: .required
        )
        await seed.begin()
        XCTAssertEqual(seed.phase, .done, "seed write should succeed, got \(seed.phase)")

        // Round one: the user opens Protection, switches it on, and closes the
        // editor without writing. This is exactly what `ProtectionConfigSheet`
        // commits on Done.
        let abandoned = EditFlowModel(records: seeded, origin: .liveScan)
        abandoned.protection = TagProtection(
            passwordProtect: true, protectFromPage: 4, readProtect: true, authLimit: 0
        )
        abandoned.protectionCredential = .type2(
            password: Data([0xFF, 0xFF, 0xFF, 0xFF]), pack: Data([0x00, 0x00])
        )
        XCTAssertNotNil(abandoned.pendingProtection(), "the abandoned editor really was configured to protect")

        // Round two: a fresh scan, which is where the next editor comes from.
        let scan = ScanFlowModel(factory: factory)
        await scan.begin()
        XCTAssertEqual(scan.phase, .ready)
        XCTAssertEqual(scan.detectedProtection?.passwordProtect, false, "nothing was written, so nothing is protected")

        let editor = EditFlowModel(
            records: scan.records,
            tag: scan.scannedTagInfo,
            protection: scan.detectedProtection ?? .none,
            origin: .liveScan
        )
        editor.records.removeAll()
        XCTAssertNil(editor.pendingProtection(), "a fresh editor carries no protection from the abandoned one")

        // Round three: "Write to clear tag", assembled the way `TagEditorSheet`
        // assembles it.
        let clear = WriteFlowModel(
            factory: factory,
            dataArea: .replace(editor.records),
            credentials: InMemoryTagCredentialStore(),
            protection: editor.protectionToSend(),
            unlockCredential: editor.protectionCredential,
            removeProtection: editor.wantsProtectionRemoved,
            uidConfirmation: .required,
            targetUID: editor.targetUID
        )
        await clear.begin()
        XCTAssertEqual(clear.phase, .done, "clearing should succeed, got \(clear.phase)")

        // The tag is cleared and exactly as unprotected as it was before.
        XCTAssertEqual(
            try chip.readProtectionState()?.passwordProtect,
            false,
            "the clear write must not have protected the tag"
        )
        XCTAssertEqual(try chip.authenticate(password: Data([0xFF, 0xFF, 0xFF, 0xFF])), Data([0x00, 0x00]))

        // And the next scan reads it, rather than asking for a password.
        let rescan = ScanFlowModel(factory: factory)
        await rescan.begin()
        XCTAssertEqual(rescan.phase, .ready, "a cleared tag must scan clean, got \(rescan.phase)")
        XCTAssertTrue(rescan.records.isEmpty)
        XCTAssertEqual(rescan.detectedProtection?.passwordProtect, false)
    }
}
