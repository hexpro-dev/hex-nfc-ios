@testable import HexNFCApp
@testable import HexNFCKit
@testable import HexNFCRecords
@testable import HexNFCTagSim
import XCTest

/// The capstone: the two routes do the same thing to the same tag.
///
/// "These need to be functionally identical, they shouldn't be different in any
/// way regardless of which path you pick" is the requirement eighteen commits on
/// this branch were written against, one operation at a time. Nothing checked
/// it. No test built both flow models against the same simulator state for the
/// same intent, so the property was maintained by whoever happened to remember
/// it, and the next person to touch either route had no way to find out they had
/// broken it.
///
/// One method per operation, each asserting over the cells `RouteParityMatrix`
/// declares. Every failure names its cell, because "the two routes disagree" on
/// its own sends the reader back through 36 combinations to find out where.
///
/// Five things are asserted per cell:
///  1. The two routes agree on the class of ending, **and** both match a pinned
///     expectation. Agreement alone is satisfied by both being broken, which is
///     the failure mode a parity suite is most likely to have.
///  2. The protection the tag reports afterwards agrees whole, AUTH0 included,
///     and its shape matches a pinned expectation.
///  3. An erase reads back an empty message on both. An arm and a removal read
///     back a data area byte-identical to the one the tag carried before the run.
///     That read-back is the only evidence there is:
///     `SimulatedConnectedTag.writeNDEF` does not go through `transceive`, so no
///     data-area write ever reaches the frame recorder and "no write frame
///     reached the data area" would pass on a route that rewrote every page.
///  4. The redacted frame signatures of the work tap agree.
///  5. The credential-bearing frames of the work tap agree in number, and the
///     number matches what was measured. `NFCTraceRedaction` decides which
///     frames those are; see `RouteParity.expectedCredentialFrames` for why this
///     is a count rather than a bound of one.
@MainActor
final class RouteParityTests: XCTestCase {
    // MARK: - The census

    /// A suite that quietly shrinks is worse than none, so the shape of the
    /// matrix is itself pinned. Moving a cell into `exclusions` is allowed; doing
    /// it without a reason, or without moving these numbers, is not.
    func test_theMatrixStillCoversWhatItSaysItCovers() {
        XCTAssertEqual(
            RouteParity.allCells.count, RouteParity.cellCount,
            "the product of the three axes changed; the census has to change with it"
        )
        XCTAssertEqual(RouteParity.exclusions.count, RouteParity.excludedCount)
        XCTAssertEqual(RouteParity.included.count, RouteParity.includedCount)
        XCTAssertEqual(
            RouteParity.included.count + RouteParity.exclusions.count, RouteParity.allCells.count,
            "every cell is either asserted or excluded, and no cell is both"
        )
        XCTAssertEqual(
            Set(RouteParity.included).union(RouteParity.exclusions.map(\.cell)),
            Set(RouteParity.allCells)
        )
        for exclusion in RouteParity.exclusions {
            XCTAssertFalse(
                exclusion.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(exclusion.cell) is excluded with no reason"
            )
        }
        for operation in RouteParity.Operation.allCases {
            XCTAssertFalse(
                RouteParity.cells(for: operation).isEmpty,
                "\(operation.label) has no cells left, so its test asserts nothing"
            )
        }
    }

    // MARK: - One method per operation

    func test_erasingBehavesTheSameOnBothRoutes() async throws {
        try await assertParity(over: .erase)
    }

    func test_armingBehavesTheSameOnBothRoutes() async throws {
        try await assertParity(over: .arm)
    }

    func test_removingProtectionBehavesTheSameOnBothRoutes() async throws {
        try await assertParity(over: .remove)
    }

    // MARK: - The assertions

    private func assertParity(
        over operation: RouteParity.Operation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for cell in RouteParity.cells(for: operation) {
            let run = try await RouteParityHarness.runBothRoutes(cell, file: file, line: line)
            assertOutcome(run, file: file, line: line)
            assertProtection(run, file: file, line: line)
            assertDataArea(run, file: file, line: line)
            assertFrames(run, file: file, line: line)
        }
    }

    private func assertOutcome(_ run: ParityRun, file: StaticString, line: UInt) {
        XCTAssertEqual(
            run.operations.outcome, run.editor.outcome,
            "\(run.cell): the two routes ended differently", file: file, line: line
        )
        let expected = RouteParity.expectedOutcome(run.cell)
        XCTAssertEqual(
            run.operations.outcome, expected,
            "\(run.cell): Operations ended \(run.operations.outcome), expected \(expected)",
            file: file, line: line
        )
        XCTAssertEqual(
            run.editor.outcome, expected,
            "\(run.cell): the editor ended \(run.editor.outcome), expected \(expected)",
            file: file, line: line
        )
        XCTAssertLessThanOrEqual(
            run.operations.credentialRequests, 1,
            "\(run.cell): Operations asked for a credential \(run.operations.credentialRequests) times; "
                + "the tag accepted the first one, so a second ask is a run that lost track of it",
            file: file, line: line
        )
        XCTAssertLessThanOrEqual(
            run.editor.credentialRequests, 1,
            "\(run.cell): the editor asked for a credential \(run.editor.credentialRequests) times",
            file: file, line: line
        )
        XCTAssertEqual(
            run.operations.credentialRequests, run.editor.credentialRequests,
            "\(run.cell): one route asked the user for a credential and the other did not",
            file: file, line: line
        )
    }

    private func assertProtection(_ run: ParityRun, file: StaticString, line: UInt) {
        XCTAssertEqual(
            run.operations.gate, run.editor.gate,
            "\(run.cell): the tags report different protection afterwards: "
                + "Operations \(run.operations.gate), the editor \(run.editor.gate)",
            file: file, line: line
        )
        let expected = RouteParity.expectedGate(run.cell)
        XCTAssertEqual(
            run.operations.gate.gateClass, expected,
            "\(run.cell): Operations left the tag \(run.operations.gate.gateClass), expected \(expected)",
            file: file, line: line
        )
        XCTAssertEqual(
            run.editor.gate.gateClass, expected,
            "\(run.cell): the editor left the tag \(run.editor.gate.gateClass), expected \(expected)",
            file: file, line: line
        )
    }

    private func assertDataArea(_ run: ParityRun, file: StaticString, line: UInt) {
        XCTAssertEqual(
            run.operations.dataArea, run.editor.dataArea,
            "\(run.cell): the two routes left different bytes in the data area",
            file: file, line: line
        )
        switch run.cell.operation {
        case .erase:
            XCTAssertEqual(
                run.operations.dataArea, .empty,
                "\(run.cell): Operations did not clear the tag", file: file, line: line
            )
            XCTAssertEqual(
                run.editor.dataArea, .empty,
                "\(run.cell): the editor did not clear the tag", file: file, line: line
            )

        case .arm, .remove:
            // A protection change is about the configuration and nothing else. A
            // route that read the message off the tag and put it straight back
            // would pass a "did the bytes change" test, which is why the seed is
            // a message neither operation would ever write.
            XCTAssertEqual(
                run.operations.dataArea, run.dataAreaBefore,
                "\(run.cell): Operations touched the data area on a protection-only change",
                file: file, line: line
            )
            XCTAssertEqual(
                run.editor.dataArea, run.dataAreaBefore,
                "\(run.cell): the editor touched the data area on a protection-only change",
                file: file, line: line
            )
            XCTAssertNotEqual(
                run.dataAreaBefore, .empty,
                "\(run.cell): the fixture has to carry bytes an untouched read-back can be told apart from",
                file: file, line: line
            )
        }
    }

    private func assertFrames(_ run: ParityRun, file: StaticString, line: UInt) {
        XCTAssertEqual(
            run.operations.workTapFrames, run.editor.workTapFrames,
            "\(run.cell): the work taps put different frames on the wire.\n"
                + "  Operations: \(run.operations.workTapFrames)\n"
                + "  editor    : \(run.editor.workTapFrames)",
            file: file, line: line
        )
        XCTAssertFalse(
            run.operations.workTapFrames.isEmpty,
            "\(run.cell): no frames were recorded at all, so the comparison above proved nothing",
            file: file, line: line
        )
        XCTAssertEqual(
            run.operations.credentialFramesInWorkTap, run.editor.credentialFramesInWorkTap,
            "\(run.cell): the two routes spend different numbers of the tag's credential frames",
            file: file, line: line
        )
        let expected = RouteParity.expectedCredentialFrames(run.cell)
        XCTAssertEqual(
            run.operations.credentialFramesInWorkTap, expected,
            "\(run.cell): Operations put \(run.operations.credentialFramesInWorkTap) credential frames "
                + "on the work tap, and \(expected) were measured",
            file: file, line: line
        )
        XCTAssertEqual(
            run.editor.credentialFramesInWorkTap, expected,
            "\(run.cell): the editor put \(run.editor.credentialFramesInWorkTap) credential frames "
                + "on the work tap, and \(expected) were measured",
            file: file, line: line
        )
    }
}
