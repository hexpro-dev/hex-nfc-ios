import XCTest

/// UI golden-path tests. Filled in during Phase 2 with the three flows
/// defined in the plan:
///   1. Build URI tag → write → verify
///   2. Scan tag → add record → re-write
///   3. Advanced console runs an NTAG215 GET_VERSION preset
///
/// Tests will be driven against a simulated `TagSessionFactory` selected by
/// the `--useSimulatedNFC` launch argument — never against real silicon in
/// CI.
final class HexNFCUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func test_appLaunches() {
        let app = XCUIApplication()
        app.launchArguments += ["--useSimulatedNFC", "--noReviewPrompt"]
        app.launch()
        // The header is one element with the link trait and its children hidden
        // from accessibility, so the wordmark is not a static text of its own.
        let header = app.descendants(matching: .any)["Hex NFC by Hex Pro"]
        XCTAssertTrue(header.waitForExistence(timeout: 5))
    }

    /// The review card, shown by `--reviewPromptPreview` whatever has been
    /// counted: it rises once Home has sat untouched, "Meh." swaps in the
    /// feedback offer, and "Hide" takes the card away.
    @MainActor
    func test_reviewCard_mehThenHide() {
        let app = XCUIApplication()
        app.launchArguments += ["--useSimulatedNFC", "--reviewPromptPreview"]
        app.launch()
        let card = app.descendants(matching: .any)["reviewPrompt.card"]
        XCTAssertTrue(card.waitForExistence(timeout: 20), "the card rises after ten untouched seconds")

        app.buttons["reviewPrompt.meh"].tap()
        XCTAssertTrue(app.buttons["reviewPrompt.sendFeedback"].waitForExistence(timeout: 5))

        app.buttons["reviewPrompt.hide"].tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 5))
    }

    /// Scan a tag that carries a record and land in the editor's record list.
    @MainActor
    func test_scanOpensEditorWithRecords() {
        let app = XCUIApplication()
        app.launchArguments += ["--useSimulatedNFC", "--noReviewPrompt"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Scan"].waitForExistence(timeout: 5))
        app.staticTexts["Scan"].tap()
        let row = app.descendants(matching: .any)["editor.row.uri"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Build from scratch: the same editor sheet, presented empty and with no
    /// sheet dismissing ahead of it.
    @MainActor
    func test_buildOpensEmptyEditor() {
        let app = XCUIApplication()
        app.launchArguments += ["--useSimulatedNFC", "--noReviewPrompt"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Build"].waitForExistence(timeout: 5))
        app.staticTexts["Build"].tap()
        XCTAssertTrue(app.staticTexts["Empty tag"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.state, .runningForeground)
    }
}
