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
        app.launchArguments += ["--useSimulatedNFC"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Hex NFC"].waitForExistence(timeout: 5))
    }
}
