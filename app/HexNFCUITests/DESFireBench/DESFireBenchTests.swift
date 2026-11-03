import XCTest

/// Runs the DESFire NDEF bench (`docs/internal/bench-desfire-ndef-2026-10.md`)
/// on a real phone over a real card, so a sitting can go ahead with nobody at
/// the phone. Skipped unless `HEXNFC_DESFIRE_BENCH` lists the steps to run.
///
/// The frames are the record, and they come from the device log
/// (`idevicesyslog -m HEXNFC`), not from here. This test only drives the
/// screens and prints what each one ended on, as `[BENCH]` lines in the
/// xcodebuild output.
///
/// Only the throwaway card is ever written. A step that writes, or presents a
/// key, refuses to start unless the card the run identified is the one
/// `HEXNFC_DESFIRE_THROWAWAY_UID` names, and at every typed-UID gate it checks
/// the UID the gate shows before typing it; anything else is cancelled at the
/// gate. The first step that fails ends the run.
///
/// Steps, in any order:
/// - `harness`: the DEBUG test harness's DESFire suite (DF-0b). Presents the
///   factory key, so throwaway only.
/// - `scan`: Home > Scan, and the editor it hands over to.
/// - `format`, `remove`, `erase`: the Operations tile through both taps.
///   Throwaway only.
/// - `formatRefused`, `removeRefused`: the tile's tap 1, which must refuse
///   without reaching the gate (DF-2).
/// - `writeText`: scan, add one Text record and write it. Throwaway only. Text
///   rather than a link, so iOS's background reading of a card resting on the
///   phone raises no banner over the next step.
/// - `consoleCard`, `consolePICC`: read-only frames from the Advanced console.
final class DESFireBenchTests: XCTestCase {
    @MainActor
    func test_desfireBench() throws {
        let env = ProcessInfo.processInfo.environment
        let steps = (env["HEXNFC_DESFIRE_BENCH"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        try XCTSkipIf(steps.isEmpty, "Set TEST_RUNNER_HEXNFC_DESFIRE_BENCH to the steps to run")
        let throwaway = env["HEXNFC_DESFIRE_THROWAWAY_UID"]
            .map { $0.uppercased().filter(\.isHexDigit) }
            .flatMap { $0.isEmpty ? nil : $0 }
        // A moment before the first tap, so the device log can be started once
        // the test session has taken the phone's log relay over.
        let delay = env["HEXNFC_DESFIRE_START_DELAY"].flatMap(TimeInterval.init) ?? 0

        let bench = try DESFireBench(throwawayUID: throwaway)
        bench.capture.settle(delay)
        try bench.identify()
        for step in steps {
            try XCTContext.runActivity(named: step) { _ in
                bench.log("step \(step)")
                do {
                    try bench.run(step)
                } catch {
                    bench.capture.attachFailure(step, error)
                    bench.log("FAILED \(step): \(error)")
                    throw error
                }
            }
        }
        bench.log("all steps finished")
    }
}

@MainActor
final class DESFireBench {
    let capture: DocsCapture
    let throwawayUID: String?
    private(set) var uid = ""

    private var c: DocsCapture {
        capture
    }

    init(throwawayUID: String?) throws {
        self.throwawayUID = throwawayUID
        capture = try DocsCapture(config: DocsCaptureConfig(
            enabled: true, locale: "en", rig: "desfire", assets: nil, sacrificeUID: nil,
            requiresSystemLanguage: false
        ))
    }

    func log(_ line: String) {
        print("[BENCH] \(line)")
    }

    /// The card under the phone, from the Advanced console's Identify.
    func identify() throws {
        uid = try DocsShots.verifyTag(c, chip: "MIFARE DESFire")
        c.tagUID = uid
        log("card \(uid)\(isThrowaway ? " (the throwaway)" : " (NOT the throwaway: read-only steps only)")")
    }

    var isThrowaway: Bool {
        throwawayUID != nil && uid == throwawayUID
    }

    private func requireThrowaway(_ step: String) throws {
        guard isThrowaway else {
            throw DocsCaptureError(
                "\(step) changes the card, and the card under the phone is \(uid), not the throwaway"
            )
        }
    }

    func run(_ step: String) throws {
        switch step {
        case "harness":
            try requireThrowaway(step)
            try harness()

        case "scan":
            try scan()

        case "format":
            try requireThrowaway(step)
            try gated(tile: "Format", action: "Format tag")

        case "remove":
            try requireThrowaway(step)
            try gated(tile: "Remove NDEF setup", action: "Remove NDEF setup")

        case "erase":
            try requireThrowaway(step)
            try gated(tile: "Erase", action: "Erase tag")

        case "formatRefused":
            try refusedAtTap1(tile: "Format")

        case "removeRefused":
            try refusedAtTap1(tile: "Remove NDEF setup")

        case "writeText":
            try requireThrowaway(step)
            try writeText()

        case "consoleCard":
            // PICC level: applications and free memory. Then the NDEF
            // application: the CC file's 15 bytes and the NDEF file's NLEN.
            try console(
                "90:5A:00:00:03:00:00:00:00, 90:6A:00:00:00, 90:6E:00:00:00, "
                    + "90:5A:00:00:03:01:00:00:00, 90:BD:00:00:07:01:00:00:00:0F:00:00:00, "
                    + "90:BD:00:00:07:02:00:00:00:02:00:00:00"
            )

        case "consolePICC":
            try console("90:5A:00:00:03:00:00:00:00, 90:6A:00:00:00, 90:6E:00:00:00")

        default:
            throw DocsCaptureError("no bench step named \(step)")
        }
    }

    // MARK: Steps

    /// Home > (DEBUG) Live chip test > Scan & identify > Start test.
    private func harness() throws {
        try c.launchHome()
        try c.tap(c.app.buttons["Live chip test"])
        try c.tap(c.button("Scan & identify"))
        let start = c.button("Start test")
        try c.waitForNFC(start, timeout: 30)
        let detected = c.containing("Detected ", type: .staticText)
        log("harness: \(detected.exists ? detected.label : "no Detected line")")
        try c.tap(start)
        let passed = c.text("All steps passed")
        let failed = c.containing("Failed: ", type: .staticText)
        try waitForAny([passed, failed], timeout: 120)
        c.afterNFC()
        log("harness: \(passed.exists ? "All steps passed" : failed.exists ? failed.label : "no verdict")")
        dumpTexts("harness")
        try c.tap(c.button("Done"))
    }

    /// Home > Scan, into the editor, and what the editor says about the card.
    private func scan() throws {
        try DocsShots.scanIntoEditor(c)
        dumpTexts("editor")
    }

    /// An Operations tile through both taps: tap 1 identifies, the gate is
    /// checked and typed, tap 2 changes the card.
    private func gated(tile: String, action: String) throws {
        try DocsShots.scanIntoEditor(c)
        try DocsShots.openOperations(c)
        try DocsShots.openOperation(c, tile)
        try c.tap(c.identified("operation.start"))
        let uidField = c.field("Type this tag's UID to confirm.")
        let retry = c.identified("operation.retry")
        try waitForAny([uidField, retry], timeout: 40)
        c.afterNFC()
        let identified = c.identified("operation.identifiedChip")
        if identified.exists {
            log("\(tile) tap 1: \(identified.label)")
        }
        guard uidField.exists else {
            dumpTexts("\(tile) tap 1")
            throw DocsCaptureError("\(tile) stopped at tap 1")
        }
        // The gate's own UID, beside the field, is the element labelled "UID"
        // that carries a value (the editor's info row underneath carries none).
        // It must be the throwaway's, and the card the run identified must be too.
        let shownUIDs = c.app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "UID")).allElementsBoundByIndex
            .compactMap { $0.exists ? ($0.value as? String) : nil }
            .map { $0.uppercased().filter(\.isHexDigit) }
            .filter { !$0.isEmpty }
        let shownUID = shownUIDs.first ?? ""
        guard isThrowaway, !shownUIDs.isEmpty, shownUIDs.allSatisfy({ $0 == throwawayUID }) else {
            try c.tap(c.identified("operation.cancel"))
            throw DocsCaptureError("\(tile): the gate shows \(shownUID), not the throwaway; cancelled at the gate")
        }
        log("\(tile) gate shows \(shownUID); confirming")
        try confirmGate(uidField: uidField, action: action)
        // Tap 2 ends on either the summary or the error card's retry button.
        let finished = c.app.descendants(matching: .any).matching(NSPredicate(
            format: "label IN %@",
            [
                "Card set up for NDEF.", "Already set up for NDEF: nothing written.",
                "NDEF setup removed. The card is blank.", "This card is already blank: nothing changed.",
                "Tag erased.",
            ]
        )).firstMatch
        try waitForAny([finished, retry], timeout: 60)
        c.afterNFC()
        dumpTexts("\(tile) tap 2")
        guard finished.exists else {
            throw DocsCaptureError("\(tile) ended on an error")
        }
        log("\(tile): \(finished.label)")
        // The editor applies what the operation learned only once Operations
        // closes, so its card is read after Done, not under the sheet. Done is
        // on the Operations list, one screen back from the operation.
        try c.tap(c.app.navigationBars[tile].buttons.firstMatch)
        try c.tap(c.button("Done"))
        try c.waitUntilGone(c.identified("operations.dangerousActions"))
        c.settle(1)
        dumpTexts("\(tile) editor after Done")
    }

    /// Tap 1 of a tile on a card it must refuse. The gate appearing is the
    /// failure DF-2 looks for, and it is cancelled without typing anything.
    private func refusedAtTap1(tile: String) throws {
        try DocsShots.scanIntoEditor(c)
        try DocsShots.openOperations(c)
        try DocsShots.openOperation(c, tile)
        try c.tap(c.identified("operation.start"))
        let uidField = c.field("Type this tag's UID to confirm.")
        let retry = c.identified("operation.retry")
        let alreadyBlank = c.text("This card is already blank: nothing changed.")
        try waitForAny([uidField, retry, alreadyBlank], timeout: 40)
        c.afterNFC()
        dumpTexts("\(tile) tap 1")
        if uidField.exists {
            try c.tap(c.identified("operation.cancel"))
            throw DocsCaptureError("\(tile) reached the typed-UID gate on a card it must refuse; cancelled")
        }
        log("\(tile) refused at tap 1")
    }

    /// Scan, add one Text record, write it.
    private func writeText() throws {
        try DocsShots.scanIntoEditor(c)
        try DocsShots.addText(c, "Hex NFC DESFire bench")
        try DocsShots.writeFromEditor(c)
        log("writeText: write sheet closed")
        dumpTexts("after write")
    }

    /// Advanced console, identification on, one run of `frames`.
    private func console(_ frames: String) throws {
        try DocsShots.openConsole(c)
        let skip = c.toggle("Skip identification")
        if skip.exists, (skip.value as? String) == "1" {
            try c.flip(skip, on: false)
        }
        let input = c.field("21:60:00, A2:04:E1:10:06:00")
        try c.replace(input, with: frames)
        c.dismissKeyboard()
        try c.tap(c.button("Run"))
        let done = c.valued("Status", "Done")
        try c.waitForNFC(done, timeout: 40)
        log("console ran: \(frames)")
    }

    // MARK: Helpers

    /// Type the UID and press the gate's own button. The tile and the start
    /// button can share its title, so the one pressed is the one that is on
    /// screen and takes a tap.
    private func confirmGate(uidField: XCUIElement, action: String) throws {
        try c.type(uid, into: uidField)
        c.dismissKeyboard()
        let buttons = c.app.buttons.matching(NSPredicate(format: "label == %@", action))
        for _ in 0 ..< 6 {
            if let button = buttons.allElementsBoundByIndex.first(where: { $0.exists && c.wholly($0) }) {
                c.settle(0.5)
                button.tap()
                return
            }
            c.app.swipeUp()
            c.settle(0.6)
        }
        throw DocsCaptureError("no \(action) button on screen at the gate")
    }

    private func waitForAny(_ targets: [XCUIElement], timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if targets.contains(where: \.exists) {
                return
            }
            c.settle(0.5)
        }
        throw DocsCaptureError("none of \(targets.count) expected states appeared within \(Int(timeout)) s")
    }

    /// Print every distinct line of text on screen, and keep a screenshot.
    private func dumpTexts(_ label: String) {
        var seen = Set<String>()
        for text in c.app.staticTexts.allElementsBoundByIndex where text.exists {
            // An info row reads as its caption, with what it says in the value.
            let value = (text.value as? String).map { $0.isEmpty ? "" : " = \($0)" } ?? ""
            let line = (text.label + value).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, seen.insert(line).inserted else { continue }
            log("  \(label) | \(line)")
        }
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "bench__\(label)"
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: "screen: \(label)") { $0.add(attachment) }
    }
}
