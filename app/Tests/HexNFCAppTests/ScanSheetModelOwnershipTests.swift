import XCTest

/// Source-text guards over who owns the scan flow model.
///
/// `RootView` presented `ScanSheet` from a `.sheet(isPresented:)` closure that
/// constructed the `ScanFlowModel` inline, and `ScanSheet` held it in a plain
/// `@Bindable` property. SwiftUI re-runs a sheet's content closure whenever the
/// presenting body is re-evaluated, which `RootView` does on the launch `costs`
/// fetch landing and on any observed change to `AppModel`. The sheet's property
/// was then replaced mid-scan by a fresh `.idle` model while `.task` went on
/// driving the instance it had captured, so the screen could sit on "Hold tag
/// against the top of your iPhone" through a read that had already completed,
/// with `onChange(of: model.phase)` watching a model nothing was driving.
///
/// Both files open with `#if os(iOS)`, so `swift test` on macOS never compiles a
/// line of either and no ordinary assertion can reach them. Reading the source
/// is the coverage the macOS job can give, the same idiom as
/// `OperationsSheetAffordanceTests` and `SessionHolderStorageTests`; the
/// `xcodebuild -destination generic/platform=iOS` job is what type-checks them.
final class ScanSheetModelOwnershipTests: XCTestCase {
    private static func screenSource(_ fileName: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath) // …/app/Tests/HexNFCAppTests/ScanSheetModelOwnershipTests.swift
            .deletingLastPathComponent() // …/HexNFCAppTests
            .deletingLastPathComponent() // …/Tests
            .deletingLastPathComponent() // …/app
            .appendingPathComponent("Sources/HexNFCApp/Screens/\(fileName)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func scanSheetSource() throws -> String {
        let text = try Self.screenSource("ScanSheet.swift")
        XCTAssertTrue(
            text.contains("struct ScanSheet: View"),
            "read ScanSheet.swift but it does not declare `struct ScanSheet: View`. The file moved or "
                + "the type was renamed, and the guards below are inert."
        )
        return text
    }

    private func rootViewSource() throws -> String {
        let text = try Self.screenSource("RootView.swift")
        XCTAssertTrue(
            text.contains(".sheet(isPresented: $showingScan)"),
            "read RootView.swift but it does not present the scan sheet from `$showingScan`. The file "
                + "moved or the presentation changed shape, and the guards below are inert."
        )
        return text
    }

    /// The sheet owns its model, so the presentation outlives a parent redraw.
    ///
    /// `@State` is the load-bearing word. A `@Bindable`, a `let` or a `var` is
    /// re-initialised from the freshly built struct on every update; only
    /// `@State` keeps the first instance for the life of the view's identity.
    func test_theScanSheetOwnsItsFlowModelInState() throws {
        let source = try scanSheetSource()

        XCTAssertTrue(
            source.contains("@State private var model: ScanFlowModel"),
            "ScanSheet must hold its ScanFlowModel in `@State`. Any other property wrapper (or none) is "
                + "replaced when the presenting view re-evaluates its body, which strands the live session "
                + "on the discarded model."
        )
        XCTAssertTrue(
            source.contains("_model = State(initialValue: ScanFlowModel("),
            "ScanSheet must build the ScanFlowModel in its own init, into the `@State` storage. Assigning "
                + "a model handed in from outside re-opens the swap this guard is about."
        )
        XCTAssertFalse(
            source.contains("@Bindable var model: ScanFlowModel"),
            "ScanSheet held its model in `@Bindable` until 2026-09-22, and that is exactly the property "
                + "wrapper the parent redraw substitutes. Do not put it back."
        )
    }

    /// `RootView` hands the sheet its inputs, never a constructed model.
    func test_rootViewHandsTheScanSheetItsInputs() throws {
        let source = try rootViewSource()

        XCTAssertFalse(
            source.contains("ScanFlowModel("),
            "RootView must not construct a ScanFlowModel. The only place it ever did was the "
                + "`.sheet(isPresented: $showingScan)` content closure, which SwiftUI re-runs on every "
                + "re-evaluation of the root body. Pass `factory:` and `library:` and let ScanSheet own it."
        )
        let call = source.components(separatedBy: "ScanSheet(").dropFirst().first ?? ""
        let arguments = call.components(separatedBy: "onComplete:")[0]
        XCTAssertTrue(
            arguments.contains("factory:") && arguments.contains("library:"),
            "RootView must hand ScanSheet the pieces it needs to build its own model. Found these "
                + "arguments before `onComplete:` instead: \(arguments)"
        )
    }

    /// The general form of the same defect, over every flow model `RootView`
    /// builds rather than only the scan one.
    ///
    /// A model built in argument position inside a sheet closure is thrown away
    /// and rebuilt on every parent redraw. Built on the right of an assignment
    /// it lands in one of `RootView`'s `@State` slots, which is how the edit and
    /// write sheets are presented (`.sheet(item:)`), and the slot is what keeps
    /// it alive. The count is asserted so that constructions leaving `RootView`
    /// fail the guard loudly rather than leave it checking nothing.
    func test_everyFlowModelInRootViewIsBuiltIntoAStateSlot() throws {
        let lines = try rootViewSource().components(separatedBy: "\n")
        var checked = 0

        for (index, line) in lines.enumerated() where line.contains("FlowModel(") {
            checked += 1
            // Everything left of the construction, minus the type's own name:
            // `activeEditModel = EditFlowModel(` leaves `activeEditModel =`.
            let beforeCall = line.components(separatedBy: "FlowModel(")[0]
            let prefix = String(beforeCall.reversed().drop { $0.isLetter || $0.isNumber || $0 == "_" }.reversed())
            XCTAssertTrue(
                prefix.trimmingCharacters(in: .whitespaces).hasSuffix("="),
                "the flow model built at RootView.swift line \(index + 1) is not assigned to anything. A "
                    + "model constructed in argument position lives only until the next re-evaluation of "
                    + "`rootContent`, and the presented sheet is handed a fresh one mid-flow. Assign it to a "
                    + "`@State` slot and present that, or let the sheet build its own in `@State`."
            )
        }

        XCTAssertEqual(
            checked, 4,
            "expected four flow-model constructions in RootView (edit from a scan, write from a preset, "
                + "edit from a history row, edit from Build). Found \(checked). One was added or removed "
                + "without this guard moving."
        )
    }
}
