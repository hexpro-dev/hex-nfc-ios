import XCTest

/// Source-text guards over the editor's Write affordances, in the idiom of
/// `HistoryReopenProtectionTests`.
///
/// `TagEditorSheet.swift` and `RootView.swift` both open with `#if os(iOS)`, so
/// `swift test` on macOS compiles neither, and until this file nothing read
/// `TagEditorSheet` at all. The rule for when Write is offered, and what a press
/// sends, now lives on `EditFlowModel` and is covered by `WriteOfferTests`. What
/// is left uncovered is whether these screens ask the model rather than keeping
/// their own copy, which is how the toolbar came to enable Write for any
/// non-empty record list (2026-09-25).
final class EditorWriteGateSourceTests: XCTestCase {
    private static func screen(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath) // …/app/Tests/HexNFCAppTests/EditorWriteGateSourceTests.swift
            .deletingLastPathComponent() // …/HexNFCAppTests
            .deletingLastPathComponent() // …/Tests
            .deletingLastPathComponent() // …/app
            .appendingPathComponent("Sources/HexNFCApp/Screens/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
            .joined(separator: " ")
    }

    private static func section(
        of text: String,
        from start: String,
        to end: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        let after = try XCTUnwrap(
            text.components(separatedBy: start).dropFirst().first,
            "`\(start)` moved or was renamed, and this guard is now inert",
            file: file, line: line
        )
        return after.components(separatedBy: end)[0]
    }

    func test_bothWriteAffordancesAskTheModel() throws {
        let text = try Self.screen("TagEditorSheet.swift")

        let toolbar = try Self.section(
            of: text, from: "Button(\"Write\") { startWrite() }", to: ".accessibilityIdentifier(\"editor.write\")"
        )
        XCTAssertTrue(
            toolbar.contains(".disabled(!editModel.isWriteOffered)"),
            "the toolbar Write must be gated by the model's rule, where it is tested"
        )
        XCTAssertFalse(
            toolbar.contains("records.isEmpty"),
            "a local copy of the rule is how an unedited scan came to be offered its own state back"
        )

        let clear = try Self.section(
            of: text, from: "if clearedTag,", to: "HexButton(\"Write to clear tag\""
        )
        XCTAssertTrue(
            clear.contains("editModel.isWriteOffered"),
            "the clear button is a second Write, and must not disagree with the first"
        )
    }

    func test_theWriteSendsWhatTheModelSaysIsLeftToSend() throws {
        let text = try Self.screen("TagEditorSheet.swift")
        let start = try Self.section(
            of: text,
            from: "private func startWrite() {",
            to: "private func applyPendingObservation()"
        )

        XCTAssertTrue(
            start.contains("let request = editModel.prepareWrite()"),
            "the press is decided on the model, where it is tested, not assembled here"
        )
        for argument in [
            "dataArea: request.dataArea",
            "protection: request.protection",
            "removeProtection: request.removeProtection",
            "pinnedUID: request.pinnedUID",
        ] {
            XCTAssertTrue(start.contains(argument), "the write must take `\(argument)` from the request")
        }
        for bypass in ["pendingProtection()", "protectionToSend()", "editModel.dataAreaChange"] {
            XCTAssertFalse(
                start.contains(bypass),
                "`\(bypass)` read here bypasses the pin and the proof handling in prepareWrite()"
            )
        }
        XCTAssertTrue(
            start.contains("lastStartedWrite = model") && start.contains("epochAtWriteStart = operationsEpoch"),
            "a write records which it is and when it started, so its late hand-back can be judged"
        )
    }

    func test_aSuccessfulWriteHandsBackWhatItCarriedAndItsProof() throws {
        let text = try Self.screen("TagEditorSheet.swift")
        let success = try Self.section(
            of: text,
            from: "onSuccess: { observation in",
            to: ".sheet(isPresented: $showingOperations)"
        )

        XCTAssertTrue(
            success.contains("editModel.noteWritten(model.dataArea, to: model.writtenUID)"),
            "record what the write carried, not what the editor holds when the late hand-back lands"
        )
        XCTAssertFalse(success.contains("editModel.markClean()"))
        XCTAssertTrue(
            success.contains("let isCurrent = model === lastStartedWrite"),
            "only the latest write records anything; a swipe leaves activeWriteModel nil for every late hand-back"
        )
        XCTAssertTrue(
            success.contains("isCurrent && !showingOperations")
                && success.contains("epochAtWriteStart == operationsEpoch")
                && success.contains("pendingArm = proofStillHolds ? model.provenArm : nil"),
            "a proof may not come back after an Operations sheet opened, which can re-key and report nothing"
        )
        XCTAssertTrue(
            success.contains("pendingObservation?.merging(observation)"),
            "a write's reading is merged, so it cannot drop a pending Operations reading"
        )
    }

    func test_theProofReachesTheModelOnlyWithItsReading() throws {
        let text = try Self.screen("TagEditorSheet.swift")
        let drain = try Self.section(
            of: text, from: "private func applyPendingObservation() {", to: "private var protectionSummary"
        )
        XCTAssertTrue(
            drain.contains("editModel.apply(observation, provenArm: arm)"),
            "without the arm the whole fix is switched off in the app while every model test passes"
        )

        let operations = try Self.section(
            of: text, from: "OperationsSheet(appModel: appModel) { observation in",
            to: ".onChange(of: showingOperations)"
        )
        XCTAssertTrue(operations.contains("pendingArm = nil"), "an Operations reading is later than any write's proof")
    }

    func test_bothHandBacksHoldOnlyReadingsAboutThisTag() throws {
        let text = try Self.screen("TagEditorSheet.swift")
        let write = try Self.section(
            of: text, from: "onSuccess: { observation in", to: ".sheet(isPresented: $showingOperations)"
        )
        XCTAssertTrue(
            write.contains("if let observation, editModel.isAboutThisTag(observation.uid) {"),
            "a write's reading about another tag must not replace one about this tag"
        )
        let operations = try Self.section(
            of: text, from: "OperationsSheet(appModel: appModel) { observation in",
            to: ".onChange(of: showingOperations)"
        )
        XCTAssertTrue(
            operations.contains("guard editModel.isAboutThisTag(observation.uid) else { return }"),
            "an Operations run on another tag must not drop this tag's pending reading"
        )
    }

    func test_openingOperationsForgetsTheProof() throws {
        let text = try Self.screen("TagEditorSheet.swift")
        let hook = try Self.section(
            of: text, from: ".onChange(of: showingOperations) { _, showing in", to: "applyPendingObservation()"
        )
        XCTAssertTrue(
            hook.contains("editModel.forgetProvenArm()") && hook.contains("operationsEpoch += 1"),
            "Operations can re-key the tag and report nothing, so the proof cannot outlive its opening"
        )
    }

    func test_everyEditorRouteNamesItsOrigin() throws {
        let text = try Self.screen("RootView.swift")
        let calls = Array(text.components(separatedBy: "activeEditModel = EditFlowModel(").dropFirst())
        XCTAssertEqual(calls.count, 3, "scan, history and build; a new route needs a deliberate origin")
        for (call, origin) in zip(calls, ["origin: .liveScan", "origin: .history", "origin: .build"]) {
            XCTAssertTrue(
                String(call.prefix(300)).contains(origin),
                "expected \(origin): an editor opened with the wrong origin either offers a scan its own "
                    + "state back or hides Write from a history row"
            )
        }
    }
}
