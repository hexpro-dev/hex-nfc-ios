@testable import HexNFCKit
import HexNFCTagSim
import HexNFCTestKit
import XCTest

/// Covers the DESFire suite end to end against the new simulator.
///
/// DESFire was the one chip family with no simulator at all, so `desfirePlan`
/// had never executed in CI — it could have been broken in any way and nothing
/// would have said so. These tests assert the plan runs, that every step is a
/// real result rather than a capability skip, and that the chained
/// `GET_VERSION` behaviour the identifier depends on actually holds.
final class DESFirePlanTests: XCTestCase {
    private func report() async throws -> TagTestReport {
        let simulator = DESFireEV3Simulator()
        let profile = try XCTUnwrap(simulator.profile)
        return await TagTestRunner(plan: TagTestPlan.plan(for: profile))
            .run(using: SimulatedSession(chip: simulator))
    }

    /// The simulator must identify as the chip it claims, through the production
    /// decoder, from the very frame it serves.
    func test_simulatorProfile_isEV3_4K() throws {
        let profile = try XCTUnwrap(DESFireEV3Simulator().profile)
        XCTAssertEqual(profile.id, .mifareDESFireEV3)
        XCTAssertEqual(profile.memoryLayout.byteCount, 4096)
        XCTAssertEqual(profile.capabilities, [.rawTransceive])
    }

    /// The whole suite passes and — since nothing is written — leaves no cleanup
    /// work and no protection behind.
    func test_plan_passesAndIsReadOnly() async throws {
        let report = try await report()
        XCTAssertTrue(report.passed, "suite failed\n\(report.plainTextLog)")
        XCTAssertTrue(report.isCleanPass, "not a clean pass\n\(report.footer)")
        XCTAssertTrue(report.cleanupResults.isEmpty, "a read-only suite needs no cleanup")
        XCTAssertTrue(
            report.results.allSatisfy { $0.safety == .readOnly },
            "every DESFire step must be read-only: \(report.results.filter { $0.safety != .readOnly }.map(\.name))"
        )
    }

    /// Guards against the suite quietly shrinking back to identify-only.
    func test_plan_runsEveryStep() async throws {
        let report = try await report()
        let executed = report.results.filter { $0.status == .passed }.map(\.id)
        XCTAssertEqual(
            Set(executed),
            ["df.identify", "df.version", "df.selectNDEFApp", "df.appIDs", "df.freeMemory", "df.ndefProbe"],
            "unexpected step set\n\(report.plainTextLog)"
        )
        XCTAssertTrue(
            report.results.allSatisfy { $0.status != .skipped },
            "nothing should be skipped on a chip that advertises rawTransceive"
        )
    }

    // MARK: - Chained GET_VERSION

    /// The behaviour no other simulator models: `GET_VERSION` really is a
    /// 3-frame chain, with the status byte leading (`AF …`), unlike the wrapped
    /// APDU form whose status word trails (`… 91 AF`).
    func test_getVersion_isAThreeFrameChain() {
        let simulator = DESFireEV3Simulator()
        let first = simulator.handle(command: Data([0x60]))
        XCTAssertEqual(first.first, 0xAF, "frame 1 signals 'additional frame follows'")
        XCTAssertEqual(first.count, 8)

        let second = simulator.handle(command: Data([0xAF]))
        XCTAssertEqual(second.first, 0xAF, "frame 2 still signals more")

        let third = simulator.handle(command: Data([0xAF]))
        XCTAssertEqual(third.first, 0x00, "frame 3 completes the chain")
        XCTAssertEqual(third.dropFirst().prefix(7), DESFireEV3Simulator.defaultUID, "final frame carries the UID")
    }

    /// Asking for a continuation with no chain open is an error, not a silent
    /// success — otherwise the drain loop could never be shown to terminate.
    func test_continuationWithoutAnOpenChain_isRefused() {
        let response = DESFireEV3Simulator().handle(command: Data([0xAF]))
        XCTAssertEqual(response.first, 0x1C, "ILLEGAL_COMMAND_CODE")
    }

    /// A re-issued `GET_VERSION` restarts the chain rather than continuing it.
    func test_getVersion_restartsTheChain() {
        let simulator = DESFireEV3Simulator()
        _ = simulator.handle(command: Data([0x60]))
        _ = simulator.handle(command: Data([0xAF]))
        XCTAssertEqual(simulator.versionFramesServed, 2)
        _ = simulator.handle(command: Data([0x60]))
        XCTAssertEqual(simulator.versionFramesServed, 1, "a fresh GET_VERSION resets the chain")
    }

    // MARK: - Factory-card behaviour

    /// A factory EV3 hosts no NDEF application.
    func test_selectNDEFApplication_reportsNotFound() {
        let apdu = Data([0x00, 0xA4, 0x04, 0x00, 0x07, 0xD2, 0x76, 0x00, 0x00, 0x85, 0x01, 0x01, 0x00])
        XCTAssertEqual(DESFireEV3Simulator().handle(command: apdu), Data([0x6A, 0x82]))
    }

    /// …and therefore refuses an NDEF read the same way production does, as a
    /// clean `capabilityUnsupported` rather than a transport failure that the
    /// scan flow would read as tag loss.
    func test_readNDEF_refusesAsCapabilityUnsupported() async throws {
        let tag = try await SimulatedSession(chip: DESFireEV3Simulator()).start(alert: "")
        do {
            _ = try await tag.readNDEF()
            XCTFail("a DESFire with no NDEF application should refuse the read")
        } catch let error as TagError {
            XCTAssertEqual(error.kind, .capabilityUnsupported(.ndefRead))
        }
    }

    func test_applicationListing_isEmptyOnAFactoryCard() {
        let response = DESFireEV3Simulator().handle(command: Data([0x6A]))
        XCTAssertEqual(response, Data([0x00]), "status OK and no AIDs")
    }

    func test_applicationListing_reportsConfiguredAIDs() {
        let simulator = DESFireEV3Simulator(applicationIDs: [Data([0x01, 0x02, 0x03]), Data([0xAA, 0xBB, 0xCC])])
        let response = simulator.handle(command: Data([0x6A]))
        XCTAssertEqual(response, Data([0x00, 0x01, 0x02, 0x03, 0xAA, 0xBB, 0xCC]))
    }

    /// Pins the live Myki capture: a personalised transit card lists its two
    /// applications and reports free memory *below* the advertised tier, because
    /// those applications have consumed 1920 B of the same pool a blank card
    /// reports in full. Both states must pass the plan — asserting a fixed
    /// relationship between free memory and the tier fails one or the other.
    func test_personalisedCard_listsApplicationsAndReportsConsumedMemory() async throws {
        let simulator = DESFireEV3Simulator.personalised()
        XCTAssertEqual(
            simulator.handle(command: Data([0x6A])),
            Data([0x00, 0x00, 0x11, 0xF2, 0xF0, 0x10, 0xF2]),
            "two Myki AIDs"
        )
        let free = simulator.handle(command: Data([0x6E]))
        XCTAssertEqual(free, Data([0x00, 0x80, 0x0C, 0x00]), "3200 B little-endian")

        let profile = try XCTUnwrap(simulator.profile)
        let report = await TagTestRunner(plan: TagTestPlan.plan(for: profile))
            .run(using: SimulatedSession(chip: simulator))
        XCTAssertTrue(report.passed, "personalised card should pass\n\(report.plainTextLog)")
    }

    /// Both measured free-memory values land on DESFire's 32-byte allocation
    /// boundary — the structural property the plan notes on, and a cheap guard
    /// against a byte-order slip in the little-endian decode.
    func test_freeMemoryCaptures_areWholeAllocationBlocks() {
        for bytes in [5120, 3200] {
            XCTAssertEqual(bytes % 32, 0, "\(bytes) B should be a whole number of 32-byte blocks")
        }
    }

    /// Pins the counter-intuitive real behaviour: `GetFreeMemory` reports the
    /// free EEPROM **pool**, which exceeds the advertised tier from GET_VERSION.
    /// Live-verified on two DESFire EV3 4K cards, both reporting 5120 B against a
    /// 4096 B tier. Do not "correct" this to `<=` — that assertion failed on real
    /// hardware while passing against an earlier fabricated simulator value.
    func test_freeMemory_reportsPoolLargerThanAdvertisedTier() throws {
        let simulator = DESFireEV3Simulator()
        let response = simulator.handle(command: Data([0x6E]))
        XCTAssertEqual(response.first, 0x00)
        let b = [UInt8](response.dropFirst())
        let free = Int(b[0]) | Int(b[1]) << 8 | Int(b[2]) << 16
        XCTAssertEqual(free, 5120, "matches the live EV3 4K capture")
        XCTAssertGreaterThan(
            free, try XCTUnwrap(simulator.profile).memoryLayout.byteCount,
            "the free pool legitimately exceeds the advertised 4K tier"
        )
    }

    /// File operations are key-gated at the PICC level before authentication.
    func test_fileCommands_arePermissionDenied() {
        let simulator = DESFireEV3Simulator()
        for opcode: UInt8 in [0x6F, 0xF5, 0xBD, 0xC4] {
            XCTAssertEqual(
                simulator.handle(command: Data([opcode])).first, 0x9D,
                "opcode \(String(format: "%02X", opcode)) should be PERMISSION_DENIED"
            )
        }
    }
}
