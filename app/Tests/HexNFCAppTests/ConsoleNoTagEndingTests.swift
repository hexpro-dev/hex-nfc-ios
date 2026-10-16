@testable import HexNFCApp
@testable import HexNFCDesign
@testable import HexNFCKit
@testable import HexNFCTagSim
import XCTest

/// The Advanced console with nothing in the field.
///
/// A run whose sheet was closed, or timed out, with no tag sent nothing, so it
/// is logged as a neutral note rather than an ERROR line and the status stays
/// neutral. Once the console has had a tag, from a run or from Identify, a
/// cancel is logged as the error it always was.
@MainActor
final class ConsoleNoTagEndingTests: XCTestCase {
    /// READ of page 0, which every Type-2 chip answers.
    private let command = "30:00"

    private func console(_ behaviours: [SimulatedSession.Behaviour]) -> AdvancedConsoleModel {
        let model = AdvancedConsoleModel(factory: ScriptedSessionFactory(chip: NTAG215Simulator(), behaviours))
        model.input = command
        return model
    }

    private func errorRows(_ model: AdvancedConsoleModel) -> [HexConsoleEntry] {
        model.entries.filter { $0.kind == .error }
    }

    // MARK: - Nothing in the field

    func test_run_cancelBeforeAnyTag_logsANeutralLineAndGoesIdle() async {
        let model = console([.cancelled])

        await model.run()

        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(errorRows(model).isEmpty, "no ERROR line: nothing was sent")
        XCTAssertEqual(model.entries.last?.kind, .note)
        XCTAssertEqual(model.entries.last?.body, AdvancedConsoleModel.note(for: .cancelled))
    }

    func test_run_timeoutBeforeAnyTag_isNoTagFound_andCanRunAgain() async {
        let model = console([.timeout, .ready])

        await model.run()
        XCTAssertEqual(model.phase, .noTagFound)
        XCTAssertTrue(errorRows(model).isEmpty)
        XCTAssertEqual(model.entries.last?.body, AdvancedConsoleModel.note(for: .timedOut))

        await model.run()
        XCTAssertEqual(model.phase, .finished, "a no-tag status does not block the next run")
    }

    func test_identify_cancelBeforeAnyTag_logsANeutralLine() async {
        let model = console([.cancelled])

        await model.identify()

        XCTAssertTrue(errorRows(model).isEmpty)
        XCTAssertEqual(model.entries.last?.body, AdvancedConsoleModel.note(for: .cancelled))
        XCTAssertEqual(model.phase, .idle, "Identify never moves the command status")
        XCTAssertFalse(model.isIdentifying)
    }

    func test_identify_timeoutBeforeAnyTag_logsANeutralLine() async {
        let model = console([.timeout])

        await model.identify()

        XCTAssertTrue(errorRows(model).isEmpty, "no ERROR line: nothing was sent")
        XCTAssertEqual(model.entries.last?.kind, .note)
        XCTAssertEqual(model.entries.last?.body, AdvancedConsoleModel.note(for: .timedOut))
        XCTAssertEqual(model.phase, .idle, "Identify never moves the command status")
        XCTAssertFalse(model.isIdentifying)
    }

    // MARK: - A tag in this session

    func test_run_cancelWhileADetectedTagIsBeingIdentified_isStillAnError() async {
        let model = console([.cancelledAfterDetection])

        await model.run()

        XCTAssertEqual(
            model.phase,
            .error(message: NoTagEndingCopy.cancelled, diagnostics: "simulator behaviour=cancelledAfterDetection")
        )
        XCTAssertEqual(errorRows(model).count, 1)
    }

    func test_identify_timeoutWhileADetectedTagIsBeingIdentified_isStillAnError() async {
        let model = console([.timedOutAfterDetection])

        await model.identify()

        XCTAssertEqual(errorRows(model).count, 1)
    }

    // MARK: - A tag in an earlier session of the same console

    func test_run_cancelAfterAnEarlierRunHadATag_isStillAnError() async {
        let model = console([.ready, .cancelled])
        await model.run()
        XCTAssertEqual(model.phase, .finished)

        await model.run()

        XCTAssertEqual(
            model.phase,
            .error(message: NoTagEndingCopy.cancelled, diagnostics: "simulator behaviour=cancelled")
        )
        XCTAssertEqual(errorRows(model).count, 1)
    }

    func test_run_timeoutAfterIdentifyHadATag_isStillAnError() async {
        let model = console([.ready, .timeout])
        await model.identify()
        XCTAssertNotNil(model.identifiedChip)

        await model.run()

        XCTAssertEqual(
            model.phase,
            .error(message: NoTagEndingCopy.timedOut, diagnostics: "simulator behaviour=timeout")
        )
    }

    // MARK: - An ending nothing can vouch for

    /// An error from outside the kit may have come from a tag, so the console
    /// logs the empty sheet after it as an error too.
    func test_run_cancelAfterARunEndedInAnErrorFromOutsideTheKit_isStillAnError() async {
        let model = AdvancedConsoleModel(factory: ScriptedSessionFactory([
            { ForeignErrorSession() },
            { SimulatedSession(chip: NTAG215Simulator(), behaviour: .cancelled) },
        ]))
        model.input = command
        await model.run()
        XCTAssertEqual(errorRows(model).count, 1)

        await model.run()

        XCTAssertEqual(
            model.phase,
            .error(message: NoTagEndingCopy.cancelled, diagnostics: "simulator behaviour=cancelled")
        )
        XCTAssertEqual(errorRows(model).count, 2)
    }

    func test_run_cancelAfterIdentifyEndedInAnErrorFromOutsideTheKit_isStillAnError() async {
        let model = AdvancedConsoleModel(factory: ScriptedSessionFactory([
            { ForeignErrorSession() },
            { SimulatedSession(chip: NTAG215Simulator(), behaviour: .cancelled) },
        ]))
        model.input = command
        await model.identify()
        XCTAssertEqual(errorRows(model).count, 1)

        await model.run()

        XCTAssertEqual(
            model.phase,
            .error(message: NoTagEndingCopy.cancelled, diagnostics: "simulator behaviour=cancelled")
        )
    }
}
