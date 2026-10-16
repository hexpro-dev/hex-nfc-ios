@testable import HexNFCKit
import HexNFCTagSim
import HexNFCTestKit
import XCTest

/// A read-only pass must be read-only **end to end**.
///
/// The harness offers it for one-of-a-kind tags — a single ICODE SLIX, a transit
/// card — where the identity capture is the point and any write is a risk you
/// can't take twice. The first version filtered the *suite* by safety but ran
/// `plan.cleanup` unfiltered, so `cleanup.eraseNDEF` still fired: a live run on
/// 2026-08-06 announced "write steps excluded" and then erased a real NDEF
/// message off an ICODE SLIX2. These tests pin the promise the toggle makes.
final class ReadOnlyPassTests: XCTestCase {
    private var readOnly: TagTestRunner.Options {
        TagTestRunner.Options(includeSafety: [.readOnly])
    }

    /// The message on the tag must survive, cleanup included.
    func test_readOnlyPass_leavesAnExistingNDEFMessageIntact() async throws {
        let message = NDEFEnvelope.wrap(message: Data([0xD1, 0x01, 0x03, 0x54, 0x02, 0x65, 0x6E]))
        let simulator = NTAG213Simulator()
        try simulator.writeNDEF(message)
        let before = try simulator.readNDEF()
        XCTAssertFalse(before.isEmpty, "precondition: the tag carries a message")

        let profile = try XCTUnwrap(simulator.profile)
        let report = await TagTestRunner(plan: TagTestPlan.plan(for: profile), options: readOnly)
            .run(using: SimulatedSession(chip: simulator))

        XCTAssertTrue(report.passed, "read-only suite failed\n\(report.plainTextLog)")
        XCTAssertEqual(try simulator.readNDEF(), before, "a read-only pass must not erase the tag")
    }

    /// Nothing in a read-only run — suite or cleanup — may be a write.
    func test_readOnlyPass_runsNoWriteStepsInEitherPhase() async throws {
        let simulator = NTAG213Simulator()
        let profile = try XCTUnwrap(simulator.profile)
        let report = await TagTestRunner(plan: TagTestPlan.plan(for: profile), options: readOnly)
            .run(using: SimulatedSession(chip: simulator))

        let writes = (report.results + report.cleanupResults).filter { $0.safety != .readOnly }
        XCTAssertTrue(writes.isEmpty, "write steps ran: \(writes.map(\.name))")
    }

    /// Type-5 is the family the toggle was added for — the single ICODE SLIX.
    /// A factory-unformatted SLIX must come back exactly as it went in.
    func test_readOnlyPass_leavesAVirginType5TagUnformatted() async throws {
        let simulator = Iso15693Simulator(blockCount: 28, virgin: true)
        let profile = try XCTUnwrap(simulator.profile)
        let blockZeroBefore = try simulator.readMemory(range: 0 ..< 4)
        XCTAssertEqual(blockZeroBefore, Data([0x00, 0x00, 0x00, 0x00]), "precondition: no CC")

        let report = await TagTestRunner(plan: TagTestPlan.plan(for: profile), options: readOnly)
            .run(using: SimulatedSession(chip: simulator))

        XCTAssertTrue(report.passed, "read-only suite failed\n\(report.plainTextLog)")
        XCTAssertEqual(
            try simulator.readMemory(range: 0 ..< 4), blockZeroBefore,
            "a read-only pass must not format a virgin tag"
        )
    }

    /// The hole a step-safety audit cannot see: `TagTestRunner` probes
    /// `readProtectionState()` after cleanup, and the **Type-5 implementation
    /// writes** — it detects a write gate by writing a data block back its own
    /// bytes. That ran unconditionally, so a read-only pass still put a write on
    /// the air, on ICODE SLIX, the one-of-a-kind chip the mode exists for.
    ///
    /// A self-write leaves memory identical, so only a counter can prove this.
    func test_readOnlyPass_issuesNoWritesAtAll_includingTheProtectionProbe() async throws {
        let simulator = Iso15693Simulator(blockCount: 28)
        let profile = try XCTUnwrap(simulator.profile)
        let report = await TagTestRunner(plan: TagTestPlan.plan(for: profile), options: readOnly)
            .run(using: SimulatedSession(chip: simulator))

        XCTAssertTrue(report.passed, "read-only suite failed\n\(report.plainTextLog)")
        XCTAssertEqual(simulator.acceptedWrites, 0, "a read-only pass must put no write on the air")
    }

    /// The ordinary pass still determines the protection state — the gate that
    /// unlocks the irreversible ops must not be weakened by the fix above.
    func test_defaultPass_stillDeterminesTheProtectionState() async throws {
        let simulator = Iso15693Simulator(blockCount: 28)
        let profile = try XCTUnwrap(simulator.profile)
        let report = await TagTestRunner(plan: TagTestPlan.plan(for: profile))
            .run(using: SimulatedSession(chip: simulator))

        XCTAssertFalse(report.cleanupLeftTagProtected)
        XCTAssertTrue(report.isCleanPass, "\(report.footer)")
        XCTAssertGreaterThan(simulator.acceptedWrites, 0, "the ordinary pass does write")
    }

    /// The default (batch) options are unchanged — cleanup still writes, which is
    /// what makes an ordinary run leave a reusable blank tag behind.
    func test_defaultPass_stillRunsCleanupWrites() async throws {
        let simulator = NTAG213Simulator()
        let profile = try XCTUnwrap(simulator.profile)
        let report = await TagTestRunner(plan: TagTestPlan.plan(for: profile))
            .run(using: SimulatedSession(chip: simulator))

        XCTAssertTrue(report.cleanupResults.contains { $0.safety == .reversibleWrite },
                      "the ordinary pass must still erase the tag in cleanup")
    }
}
