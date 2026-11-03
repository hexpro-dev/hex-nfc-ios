import XCTest

/// Every route into the tag editor that ends with a sheet over its record list,
/// driven through the mock session.
///
/// They exist for one failure: SwiftUI's `List` and UIKit disagreeing about the
/// row count while a sheet transition is running, which aborts the app with
/// "invalid number of items in section". 1.0.1 hit it on iOS 27 when Write
/// presented its sheet (2026-10-22). It depends on the iOS release and on
/// timing, so run these in the Release configuration, on each iOS the app
/// supports, with `-test-iterations` above one.
///
/// Every write is followed until its sheet has closed and the editor has taken
/// the reading back, because that hand-back changes rows during a dismissal.
/// The mock returns no reading, so the hand-back only changes rows against a
/// real tag: on a device with a writable tag in the field, run with
/// `TEST_RUNNER_HEXNFC_REAL_NFC=1 xcodebuild test ...`. That mode uses CoreNFC
/// and the app's real store, and it writes to the tag.
final class EditorSheetTransitionTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        // A failure inside a `HumanPace.run` block can skip its own restore.
        MainActor.assumeIsolated { HumanPace.restore() }
        super.tearDown()
    }

    @MainActor
    func test_scanAddRecordThenWrite() {
        let app = launch()
        scanIntoEditor(app)
        addTextRecord(app)
        writeAndWaitForHandBack(app)
    }

    @MainActor
    func test_historyRowThenWrite() {
        let app = launch()
        scanIntoEditor(app)
        tap(app.buttons["Close"])
        waitUntilGone(app.buttons["editor.write"])
        tap(app.staticTexts["Library"])
        tap(app.buttons["History"])
        let row = app.collectionViews.firstMatch.buttons.firstMatch
        tap(row, timeout: 10)
        XCTAssertTrue(app.buttons["editor.write"].waitForExistence(timeout: 10))
        // Edited first, so Write is offered whatever the history row holds.
        addTextRecord(app)
        writeAndWaitForHandBack(app)
    }

    @MainActor
    func test_buildAddRecordThenWrite() {
        let app = launch()
        tap(app.staticTexts["Build"])
        addTextRecord(app)
        writeAndWaitForHandBack(app)
    }

    /// The same route at a person's pace rather than a careful one: every tap
    /// goes in as soon as its control exists, so Write lands while the record
    /// editor is still sliding away. 1.0.1's second crash on iOS 27 came 7.6 s
    /// after launch, which is about this route done quickly. Build replaces
    /// the tag's contents on each write, so repeated runs do not fill it.
    @MainActor
    func test_buildAddRecordThenWriteAtSpeed() {
        let app = launch()
        tapNow(app.staticTexts["Build"])
        tapNow(app.buttons["Add record"])
        tapNow(app.buttons["add.text"])
        tapNow(app.buttons["record.save"])
        let write = app.buttons["editor.write"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: write)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 10), .completed)
        write.tap()
        XCTAssertTrue(element(app, "write.sheet").waitForExistence(timeout: 10))
        settle(4)
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// As above, with a URL typed in first, so Save closes the record editor
    /// with the keyboard still up and its dismissal runs alongside both sheet
    /// transitions. Saving an empty record, as the other tests do, never
    /// raises the keyboard at all.
    @MainActor
    func test_buildTypeURLThenSaveAndWriteAtSpeed() {
        let app = launch()
        tapNow(app.staticTexts["Build"])
        tapNow(app.buttons["Add record"])
        tapNow(app.buttons["add.uri"])
        let field = app.textFields["URL"]
        tapNow(field)
        field.typeText("https://hex.pro/nfc")
        tapNow(app.buttons["record.save"])
        let write = app.buttons["editor.write"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: write)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 10), .completed)
        write.tap()
        XCTAssertTrue(element(app, "write.sheet").waitForExistence(timeout: 10))
        settle(4)
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Erase from Operations, then Done. Done dismisses Operations, and the
    /// editor applies the "now empty" reading as that dismissal starts, which
    /// tears its record list down mid-transition: the shape of the 2026-09-27
    /// crash. Real tag only, since the mock has no raw operations.
    @MainActor
    func test_operationsEraseThenDone() throws {
        try XCTSkipUnless(usesRealNFC, "Erase needs a real tag")
        let app = launch()
        // Put a record on the tag, so the editor opens on its record list.
        tapNow(app.staticTexts["Build"])
        tapNow(app.buttons["Add record"])
        tapNow(app.buttons["add.uri"])
        let field = app.textFields["URL"]
        tap(field)
        field.typeText("https://hex.pro/erase")
        tap(app.buttons["record.save"])
        writeAndWaitForHandBack(app)
        tap(app.buttons["Close"])
        waitUntilGone(app.buttons["editor.write"])

        scanIntoEditor(app)
        XCTAssertTrue(element(app, "editor.row.uri").waitForExistence(timeout: 10))
        let looksLikeUID = NSPredicate(format: "label MATCHES '^([0-9A-F]{2}:)+[0-9A-F]{2}$'")
        let uidRow = app.buttons.matching(looksLikeUID).firstMatch
        XCTAssertTrue(uidRow.waitForExistence(timeout: 5))
        let uid = uidRow.label.replacingOccurrences(of: ":", with: "")

        tap(app.buttons["editor.menu"])
        tap(app.buttons["Operations…"])
        tap(app.staticTexts["Erase"])
        tap(app.buttons["operation.start"])
        let confirm = app.textFields["Type this tag's UID to confirm."]
        tap(confirm, timeout: 20)
        confirm.typeText(uid)
        tap(app.buttons["Erase tag"])
        XCTAssertTrue(app.staticTexts["Tag erased."].waitForExistence(timeout: 20))
        settle(4)
        // Done lives on the Operations root, a step back from the operation.
        tap(app.navigationBars["Erase"].buttons["Operations"])
        tapNow(app.buttons["Done"])
        settle(3)
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertFalse(element(app, "editor.row.uri").exists, "The erase reading never reached the editor")
    }

    /// The route both 1.0.1 crashes on iOS 27 took, read off the device log
    /// (2026-10-22): scan a tag holding two records, swipe one away with the
    /// row's Delete action, then Write. UIKit reported "after the update (4)
    /// ... before the update (3) ... (0 inserted, 0 deleted)" as WriteSheet
    /// began presenting. Deleting one of two records leaves the List mounted and
    /// live, so this route survived; the crash needed the last record to go
    /// (see `test_swipeDeleteEveryRecordThenWriteAtOnce`).
    @MainActor
    func test_swipeDeleteRecordThenWrite() {
        let app = launch()
        if usesRealNFC {
            // Two records on the tag, as on the tag in the log.
            tap(app.staticTexts["Build"])
            addTextRecord(app)
            addTextRecord(app)
            writeAndWaitForHandBack(app)
            tap(app.buttons["Close"])
            waitUntilGone(app.buttons["editor.write"])
            scanIntoEditor(app)
        } else {
            // The mock tag holds one URI record; add a second.
            scanIntoEditor(app)
            addTextRecord(app)
        }
        let isRecordRow = NSPredicate(format: "identifier BEGINSWITH 'editor.row.'")
        let rows = app.descendants(matching: .any).matching(isRecordRow)
        XCTAssertGreaterThanOrEqual(rows.count, 2)
        let row = rows.element(boundBy: 0)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        settle(1)
        row.swipeLeft()
        tapNow(app.buttons["Delete"])
        let write = app.buttons["editor.write"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: write)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 10), .completed)
        write.tap()
        XCTAssertTrue(element(app, "write.sheet").waitForExistence(timeout: 10))
        settle(4)
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// The confirmed 1.0.1 crash on iOS 27, at the pace it happened
    /// (2026-10-22): a tag with two records, each swiped away with its Delete
    /// action, and Write pressed the moment the last one goes, while the emptied
    /// list is still leaving. UIKit aborted with "after the update (4) ... before
    /// the update (3)". Only `HumanPace` can tap inside that window.
    @MainActor
    func test_swipeDeleteEveryRecordThenWriteAtOnce() throws {
        try XCTSkipUnless(HumanPace.isAvailable, "XCUITest's quiescence methods have moved")
        let app = launch()
        let rows = editorWithTwoRecords(app)
        // Built outside the fast block, so it adds as little as it can to the
        // gap between Delete and Write.
        let write = app.buttons["editor.write"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        swipeAwayEveryRecord(app, rows) {
            write.tap()
            return true
        }
        assertStillRunning(app)
    }

    /// The empty state's own Write, which appears as the list goes and is the
    /// natural next tap. It cannot be resolved ahead, so this one pays a lookup.
    @MainActor
    func test_swipeDeleteEveryRecordThenWriteToClearAtOnce() throws {
        try XCTSkipUnless(HumanPace.isAvailable, "XCUITest's quiescence methods have moved")
        let app = launch()
        let rows = editorWithTwoRecords(app)
        swipeAwayEveryRecord(app, rows) { tapIfItAppears(app.buttons["editor.write.clear"]) }
        assertStillRunning(app)
    }

    /// The empty state's Add record, which presents a sheet of its own.
    @MainActor
    func test_swipeDeleteEveryRecordThenAddAtOnce() throws {
        try XCTSkipUnless(HumanPace.isAvailable, "XCUITest's quiescence methods have moved")
        let app = launch()
        let rows = editorWithTwoRecords(app)
        swipeAwayEveryRecord(app, rows) { tapIfItAppears(app.buttons["editor.empty.add"]) }
        assertStillRunning(app)
    }

    /// Close, which dismisses the editor's own sheet over the departing list.
    @MainActor
    func test_swipeDeleteEveryRecordThenCloseAtOnce() throws {
        try XCTSkipUnless(HumanPace.isAvailable, "XCUITest's quiescence methods have moved")
        let app = launch()
        let rows = editorWithTwoRecords(app)
        let close = app.buttons["Close"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        swipeAwayEveryRecord(app, rows) {
            close.tap()
            return true
        }
        assertStillRunning(app)
    }

    /// The control: one of two records swiped away, then Write at once. The list
    /// stays mounted and its rows stay live, so this should never have crashed.
    @MainActor
    func test_swipeDeleteOneOfTwoThenWriteAtOnce() throws {
        try XCTSkipUnless(HumanPace.isAvailable, "XCUITest's quiescence methods have moved")
        let app = launch()
        let rows = editorWithTwoRecords(app)
        let write = app.buttons["editor.write"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let first = rows.element(boundBy: 0)
        var deleted = false
        // No assertions inside the block: see `HumanPace.restore()`.
        HumanPace.run {
            first.swipeLeft()
            let delete = app.buttons["Delete"]
            if delete.waitForExistence(timeout: 5) {
                delete.tap()
                write.tap()
                deleted = true
            }
        }
        XCTAssertTrue(deleted, "The record's Delete action never appeared")
        assertStillRunning(app)
    }

    @MainActor
    func test_deleteLastRecordReturnsToEmptyEditor() {
        let app = launch()
        tap(app.staticTexts["Build"])
        addTextRecord(app)
        tap(element(app, "editor.row.text"))
        tap(app.buttons["record.delete"])
        // A Build that never wrote anything is back to blank, not "cleared".
        XCTAssertTrue(app.staticTexts["Empty tag"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func test_writeTwiceFromOneEditor() {
        let app = launch()
        scanIntoEditor(app)
        addTextRecord(app)
        writeAndWaitForHandBack(app)
        // The first write landed, so Write is withdrawn until the next edit,
        // which also puts a row change straight after the sheet has gone.
        addTextRecord(app)
        writeAndWaitForHandBack(app)
    }

    // MARK: - Steps

    private var usesRealNFC: Bool {
        ProcessInfo.processInfo.environment["HEXNFC_REAL_NFC"] == "1"
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        // A real-tag run writes to the tag and uses the phone's own store, so
        // the review card must neither count it nor appear in it.
        app.launchArguments += ["--noReviewPrompt"]
        if !usesRealNFC {
            app.launchArguments += ["--useSimulatedNFC"]
        }
        app.launch()
        return app
    }

    /// The mock tag carries one URI record, so the editor opens on its list. A
    /// real tag carries whatever it carries.
    @MainActor
    private func scanIntoEditor(_ app: XCUIApplication) {
        tap(app.staticTexts["Scan"])
        XCTAssertTrue(app.buttons["editor.write"].waitForExistence(timeout: 20))
        if !usesRealNFC {
            XCTAssertTrue(element(app, "editor.row.uri").waitForExistence(timeout: 5))
        }
    }

    /// Add a Text record and save it, which appends a row and swaps one sheet
    /// for another in the same update.
    @MainActor
    private func addTextRecord(_ app: XCUIApplication) {
        let textRows = app.descendants(matching: .any).matching(identifier: "editor.row.text")
        let before = textRows.count
        // The record list's button, or the empty editor's.
        let listAdd = app.buttons["editor.add"]
        tap(listAdd.exists ? listAdd : app.buttons["Add record"])
        tap(app.buttons["add.text"])
        tap(app.buttons["record.save"])
        let landed = NSPredicate(format: "count > %d", before)
        let wait = XCTNSPredicateExpectation(predicate: landed, object: textRows)
        XCTAssertEqual(XCTWaiter().wait(for: [wait], timeout: 10), .completed)
    }

    /// Press Write and follow it through: the sheet appears, the write lands,
    /// the sheet closes itself and the editor applies the reading.
    @MainActor
    private func writeAndWaitForHandBack(_ app: XCUIApplication) {
        let write = app.buttons["editor.write"]
        XCTAssertTrue(write.waitForExistence(timeout: 10))
        XCTAssertTrue(write.isEnabled, "Write should be offered on this route")
        tap(write)
        let sheet = element(app, "write.sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        waitUntilGone(sheet, timeout: 30)
        settle()
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(write.waitForExistence(timeout: 5))
    }

    /// Let a dismissal and the animation it starts finish before asserting.
    @MainActor
    private func settle(_ seconds: TimeInterval = 2) {
        let never = XCTestExpectation(description: "settle")
        _ = XCTWaiter().wait(for: [never], timeout: seconds)
    }

    /// Tap once the target can take it. A real scan's editor arrives with an
    /// animation, and a tap fired at an element that exists but is still moving
    /// either does nothing or lands on whatever is under it by then.
    @MainActor
    private func tap(_ target: XCUIElement, timeout: TimeInterval = 10) {
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "Missing \(target)")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: target)
        XCTAssertEqual(XCTWaiter().wait(for: [ready], timeout: timeout), .completed, "Never hittable: \(target)")
        settle(0.5)
        target.tap()
    }

    /// An editor on a scanned tag holding two records, the shape of the tag in
    /// the 2026-10-22 log. Returns its record rows.
    @MainActor
    private func editorWithTwoRecords(_ app: XCUIApplication) -> XCUIElementQuery {
        if usesRealNFC {
            tap(app.staticTexts["Build"])
            addTextRecord(app)
            addTextRecord(app)
            writeAndWaitForHandBack(app)
            tap(app.buttons["Close"])
            waitUntilGone(app.buttons["editor.write"])
            scanIntoEditor(app)
        } else {
            scanIntoEditor(app)
            addTextRecord(app)
        }
        let isRecordRow = NSPredicate(format: "identifier BEGINSWITH 'editor.row.'")
        let rows = app.descendants(matching: .any).matching(isRecordRow)
        XCTAssertTrue(rows.element(boundBy: 1).waitForExistence(timeout: 10))
        settle(1)
        return rows
    }

    /// Swipe the first record away at an ordinary pace, as in the log, then the
    /// last one at a person's pace with `next` straight after its Delete. `next`
    /// returns whether it managed its tap.
    @MainActor
    private func swipeAwayEveryRecord(_ app: XCUIApplication, _ rows: XCUIElementQuery, then next: () -> Bool) {
        rows.element(boundBy: 0).swipeLeft()
        tapNow(app.buttons["Delete"])
        let last = rows.element(boundBy: 0)
        XCTAssertTrue(last.waitForExistence(timeout: 5))
        settle(1)
        var deleted = false
        var followedUp = false
        // No assertions inside the block: see `HumanPace.restore()`.
        HumanPace.run {
            last.swipeLeft()
            let delete = app.buttons["Delete"]
            if delete.waitForExistence(timeout: 5) {
                delete.tap()
                deleted = true
                followedUp = next()
            }
        }
        XCTAssertTrue(deleted, "The last record's Delete action never appeared")
        XCTAssertTrue(followedUp, "The tap after Delete found nothing to tap")
    }

    /// For a control that only exists once the list has gone.
    @MainActor
    private func tapIfItAppears(_ target: XCUIElement) -> Bool {
        guard target.waitForExistence(timeout: 2) else { return false }
        target.tap()
        return true
    }

    @MainActor
    private func assertStillRunning(_ app: XCUIApplication) {
        settle(3)
        XCTAssertEqual(app.state, .runningForeground, "The app died in the transition over the emptied list")
    }

    /// Tap as soon as the target exists, without waiting for it to settle.
    @MainActor
    private func tapNow(_ target: XCUIElement, timeout: TimeInterval = 10) {
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "Missing \(target)")
        target.tap()
    }

    @MainActor
    private func waitUntilGone(_ target: XCUIElement, timeout: TimeInterval = 10) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: target)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: timeout), .completed, "Still there: \(target)")
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }
}
