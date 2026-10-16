@testable import HexNFCApp
@testable import HexNFCKit
@testable import HexNFCRecords
@testable import HexNFCTagSim
import XCTest

/// What a scan is allowed to say about a tag's lock bits.
///
/// The rule is the one the whole branch is built on: a verdict comes from a
/// read, an unread region is never rendered as "not locked", and no frame goes
/// out at a page this activation has not already had answered. That last one is
/// a safety property rather than an optimisation, because a READ above AUTH0 on
/// a read-protected chip is NAKed and a NAK halts the tag for the rest of the
/// tap.
final class LockStateScanTests: XCTestCase {
    private func scan(_ factory: TagSessionFactory) async -> ScanFlowModel {
        let model = await ScanFlowModel(factory: factory)
        await model.begin()
        return model
    }

    // MARK: - Verdicts off a real scan

    @MainActor
    func test_factoryTag_scansAsOpen() async {
        let model = await scan(SimulatedSessionFactory(makeChip: { NTAG213Simulator() }))
        XCTAssertEqual(model.detectedLock.state, .open)
        XCTAssertEqual(model.scannedTagInfo?.lock.state, .open)
    }

    /// The tag from the 2026-09-07 capture, locked through the shipped driver.
    /// A scan afterwards has to see it, which is the whole of the user's report:
    /// before this, a re-scan of a locked tag still read "Protection: Off".
    @MainActor
    func test_lockedTag_scansAsLocked() async throws {
        let chip = NTAG213Simulator()
        let profile = try XCTUnwrap(chip.profile)
        try await Type2LockDriver(uid: chip.uid, transceive: { chip.handle(command: $0.bytes) })
            .permanentLock(layout: profile.memoryLayout, family: profile.family, configLayout: nil)

        let model = await scan(SimulatedSessionFactory(chip: chip))
        XCTAssertEqual(model.detectedLock.state, .locked)
        XCTAssertEqual(model.scannedTagInfo?.lock.state, .locked)
    }

    /// A tag whose static bytes burned and whose dynamic page did not. Erasing
    /// it does not clear a lock bit, so the verdict has to survive an empty tag.
    @MainActor
    func test_partlyLockedTag_scansAsPartlyLocked() async throws {
        let chip = NTAG213Simulator()
        let profile = try XCTUnwrap(chip.profile)
        let staticPage = try XCTUnwrap(profile.memoryLayout.lockPages.first)
        // Only the static bytes, exactly as a static-first lock on a gated tag
        // left a real NTAG213.
        let existing = chip.handle(command: Data([0x30, UInt8(staticPage)])).prefix(4)
        var burned = Data(existing)
        burned[burned.startIndex + 2] = 0xFF
        burned[burned.startIndex + 3] = 0xFF
        _ = chip.handle(command: Data([0xA2, UInt8(staticPage)]) + burned)

        let model = await scan(SimulatedSessionFactory(chip: chip))
        XCTAssertEqual(model.detectedLock.state, .partlyLocked)
    }

    // MARK: - Frames

    /// A write-only password (PROT = 0) leaves reads open, so the lock read must
    /// still happen. Skipping it on "any protected tag" would lose the verdict
    /// for the commonest protected tag there is.
    @MainActor
    func test_writeOnlyProtectedTag_stillGetsAVerdict() async throws {
        let chip = NTAG213Simulator()
        try chip.enablePasswordProtection(
            password: Data([0xCA, 0xFE, 0xBA, 0xBE]), pack: Data([0x12, 0x34]),
            protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let model = await scan(SimulatedSessionFactory(chip: chip))
        XCTAssertEqual(model.detectedLock.state, .open)
        XCTAssertTrue(model.detectedProtection?.passwordProtect == true, "still reads as protected")
    }

    /// A read-protected tag gates every page above the Capability Container, so
    /// no lock frame may go out at all, and the absence must read as `.unknown`.
    @MainActor
    func test_readProtectedTag_sendsNoLockFramesAndClaimsNothing() async throws {
        let chip = NTAG213Simulator()
        let profile = try XCTUnwrap(chip.profile)
        let dynamicPage = try XCTUnwrap(profile.memoryLayout.dynamicLockPage)
        try chip.enablePasswordProtection(
            password: Data([0xCA, 0xFE, 0xBA, 0xBE]), pack: Data([0x12, 0x34]),
            protectFromPage: 4, readProtect: true, authLimit: 0
        )
        let faults = FaultInjectingSessionFactory(chip: chip)
        let model = await scan(faults)

        XCTAssertEqual(
            faults.report.frames(matching: .read(page: dynamicPage)).count, 0,
            "a READ above AUTH0 would NAK and halt the tag for the rest of the tap"
        )
        XCTAssertEqual(model.detectedLock.state, .unknown, "never 'not locked' from a read we did not take")
    }

    /// The config-page frame budget the protection tests assert has not moved:
    /// the lock read addresses page 2 and the dynamic lock page, neither of
    /// which is a configuration page.
    @MainActor
    func test_lockReadDoesNotDisturbTheConfigPageBudget() async throws {
        let chip = NTAG213Simulator()
        let layout = try XCTUnwrap(chip.profile?.type2ConfigLayout)
        let faults = FaultInjectingSessionFactory(chip: chip)
        _ = await scan(faults)

        XCTAssertEqual(faults.report.frames(matching: .read(page: layout.config0Page)).count, 1)
        XCTAssertEqual(faults.report.frames(matching: .read(page: 2)).count, 1)
        XCTAssertEqual(
            faults.report.frames(matching: .read(page: layout.dynamicLockPage ?? -1)).count, 1
        )
    }

    /// The lock read is best effort, and the scan is not allowed to care. Both
    /// frames are dropped here: the records, the protection state and the phase
    /// all have to come through untouched.
    @MainActor
    func test_aLostLockReadCostsOnlyTheVerdict() async throws {
        let chip = NTAG213Simulator()
        let profile = try XCTUnwrap(chip.profile)
        let faults = FaultInjectingSessionFactory(chip: chip)
        faults.arm(TagFault(.read(page: 2), .dropped))
        try faults.arm(TagFault(.read(page: XCTUnwrap(profile.memoryLayout.dynamicLockPage)), .dropped))

        let model = await scan(faults)
        XCTAssertEqual(model.phase, .ready, "the scan still completes")
        XCTAssertEqual(model.detectedLock.state, .unknown)
        XCTAssertFalse(model.protectionReadFailed, "the protection read is unaffected")
    }

    /// The blank / `capabilityUnsupported(.ndefRead)` branch reports too. An
    /// erase leaves a locked tag locked, so missing this branch is how a
    /// locked-then-erased tag would have kept reading "Off".
    @MainActor
    func test_theBlankTagBranchAlsoReportsALockVerdict() async {
        let chip = MifareUltralightEV1_48Simulator()
        let model = await scan(SimulatedSessionFactory(chip: chip))
        XCTAssertTrue(model.records.isEmpty)
        XCTAssertEqual(model.detectedLock.state, .open, "an unformatted tag still has readable lock bytes")
    }

    // MARK: - Claiming nothing by default

    @MainActor
    func test_reset_clearsTheVerdict() async {
        let model = await scan(SimulatedSessionFactory(makeChip: { NTAG213Simulator() }))
        XCTAssertEqual(model.detectedLock.state, .open)
        model.reset()
        XCTAssertEqual(model.detectedLock.state, .unknown)
    }

    func test_aTagInfoWithNoReadingClaimsNothing() {
        XCTAssertEqual(ScannedTagInfo().lock.state, .unknown)
        XCTAssertEqual(ScannedTagInfo(chipName: "NTAG213").lock.state, .unknown)
    }

    /// A history row carries no lock data, on the same rule as `needsFormatting`:
    /// a stored `false` goes stale the moment the tag is locked somewhere else.
    @MainActor
    func test_aRebuiltHistoryRowClaimsNothing() {
        let info = ScannedTagInfo(
            chipName: "NTAG213",
            uidHex: "04:37:2E:12:6B:67:81",
            capabilitySummary: "Read, Write",
            supportsPasswordProtection: true
        )
        XCTAssertEqual(info.lock.state, .unknown)
        XCTAssertFalse(EditFlowModel(tag: info, origin: .history).isWriteBlocked)
    }
}
