@testable import HexNFCApp
@testable import HexNFCKit
@testable import HexNFCRecords
import HexNFCStorage
@testable import HexNFCTagSim
import XCTest

/// What each flow tells the review prompt when a session ends.
///
/// Driven through the simulators rather than by setting phases, so a route
/// into an outcome that forgets to report it fails here.
@MainActor
final class TagActivityRecordingTests: XCTestCase {
    private let records: [NDEFRecord] = [.uri(URIRecord(uri: "https://hex.pro"))]

    // MARK: - Scan

    func test_scan_aRead_isARead() async {
        let recorder = ActivityRecorderSpy()
        let model = ScanFlowModel(factory: SimulatedSessionFactory(chip: NTAG215Simulator()), activity: recorder)

        await model.begin()

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(recorder.activities, [.read])
    }

    func test_scan_aTransitCard_isSpecial() async {
        let recorder = ActivityRecorderSpy()
        let model = ScanFlowModel(factory: SimulatedSessionFactory(chip: SuicaSimulator()), activity: recorder)

        await model.begin()

        XCTAssertNotNil(model.transitCard)
        XCTAssertEqual(recorder.activities, [.specialRead])
    }

    func test_scan_aCompletePassport_isSpecial_andItsKeyPromptIsNot() async {
        let recorder = ActivityRecorderSpy()
        let model = ScanFlowModel(factory: SimulatedSessionFactory(chip: EPassportSimulator()), activity: recorder)

        await model.begin()
        XCTAssertEqual(model.phase, .needsPassportKey)
        XCTAssertEqual(recorder.activities, [], "asking for the key is not an outcome")

        await model.readPassport(with: EPassportSimulator.specimenMRZ)

        XCTAssertEqual(model.passportData?.isComplete, true)
        XCTAssertEqual(recorder.activities, [.specialRead])
    }

    func test_scan_aRefusedPassportKey_isAFailure() async {
        let recorder = ActivityRecorderSpy()
        let model = ScanFlowModel(factory: SimulatedSessionFactory(chip: EPassportSimulator()), activity: recorder)
        let wrong = PassportMRZ(documentNumber: "X1234567", dateOfBirth: "800101", dateOfExpiry: "300101")

        await model.begin()
        await model.readPassport(with: wrong)

        XCTAssertEqual(model.phase, .needsPassportKey)
        XCTAssertTrue(model.passportReadFailed)
        XCTAssertEqual(recorder.activities, [.failed])
    }

    func test_scan_cancelWithNoTag_isNotRecorded() async {
        let recorder = ActivityRecorderSpy()
        let model = ScanFlowModel(
            factory: ScriptedSessionFactory(chip: NTAG215Simulator(), [.cancelled]),
            activity: recorder
        )

        await model.begin()

        XCTAssertEqual(model.phase, .cancelled)
        XCTAssertEqual(recorder.activities, [])
    }

    func test_scan_timeoutWithNoTag_isNotRecorded() async {
        let recorder = ActivityRecorderSpy()
        let model = ScanFlowModel(
            factory: ScriptedSessionFactory(chip: NTAG215Simulator(), [.timeout]),
            activity: recorder
        )

        await model.begin()

        XCTAssertEqual(model.phase, .noTagFound)
        XCTAssertEqual(recorder.activities, [])
    }

    func test_scan_anError_isAFailure() async {
        let recorder = ActivityRecorderSpy()
        let model = ScanFlowModel(
            factory: ScriptedSessionFactory(chip: NTAG215Simulator(), [.cancelledAfterDetection]),
            activity: recorder
        )

        await model.begin()

        guard case .error = model.phase else { return XCTFail("expected an error, got \(model.phase)") }
        XCTAssertEqual(recorder.activities, [.failed])
    }

    // MARK: - Write

    func test_write_done_isAChangedTag() async {
        let recorder = ActivityRecorderSpy()
        let model = WriteFlowModel(
            factory: SimulatedSessionFactory(chip: NTAG215Simulator()),
            dataArea: .replace(records),
            credentials: InMemoryTagCredentialStore(),
            uidConfirmation: .required,
            activity: recorder
        )

        await model.begin()

        XCTAssertEqual(model.phase, .done)
        XCTAssertEqual(recorder.activities, [.changedTag])
    }

    func test_write_anError_isAFailure() async {
        let recorder = ActivityRecorderSpy()
        let model = WriteFlowModel(
            factory: ScriptedSessionFactory(chip: NTAG215Simulator(), [.cancelledAfterDetection]),
            dataArea: .replace(records),
            credentials: InMemoryTagCredentialStore(),
            uidConfirmation: .required,
            activity: recorder
        )

        await model.begin()

        guard case .error = model.phase else { return XCTFail("expected an error, got \(model.phase)") }
        XCTAssertEqual(recorder.activities, [.failed])
    }

    // MARK: - Operations

    func test_operation_erase_isAChangedTag() async {
        let recorder = ActivityRecorderSpy()
        let model = OperationsFlowModel(
            factory: SimulatedSessionFactory(chip: NTAG215Simulator()),
            operation: .erase,
            credentials: InMemoryTagCredentialStore(),
            activity: recorder
        )

        let run = Task { await model.begin() }
        await waitUntil {
            if case .awaitingConfirmation = model.phase {
                return true
            }
            return false
        }
        model.confirm()
        await run.value

        guard case .done(.erased) = model.phase else { return XCTFail("expected an erase, got \(model.phase)") }
        XCTAssertEqual(recorder.activities, [.changedTag])
    }

    /// A dump changes nothing on the tag, so it counts as the read it is.
    func test_operation_memoryDump_isARead() async {
        let recorder = ActivityRecorderSpy()
        let model = OperationsFlowModel(
            factory: SimulatedSessionFactory(chip: NTAG215Simulator()),
            operation: .memoryDump,
            credentials: InMemoryTagCredentialStore(),
            activity: recorder
        )

        await model.begin()

        guard case .done(.memoryDumped) = model.phase else { return XCTFail("expected a dump, got \(model.phase)") }
        XCTAssertEqual(recorder.activities, [.read])
    }

    func test_operation_anError_isAFailure() async {
        let recorder = ActivityRecorderSpy()
        let model = OperationsFlowModel(
            factory: ScriptedSessionFactory(chip: NTAG215Simulator(), [.cancelledAfterDetection]),
            operation: .memoryDump,
            credentials: InMemoryTagCredentialStore(),
            activity: recorder
        )

        await model.begin()

        guard case .error = model.phase else { return XCTFail("expected an error, got \(model.phase)") }
        XCTAssertEqual(recorder.activities, [.failed])
    }

    // MARK: - Helpers

    private func waitUntil(
        timeout: Duration = .milliseconds(500),
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor
private final class ActivityRecorderSpy: TagActivityRecording {
    private(set) var activities: [TagActivity] = []

    func record(_ activity: TagActivity) {
        activities.append(activity)
    }
}
