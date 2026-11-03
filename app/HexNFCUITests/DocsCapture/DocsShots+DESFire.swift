import XCTest

extension DocsShots {
    /// A MIFARE DESFire EV3 that Format sets up for NDEF and Remove NDEF setup
    /// returns to blank. Rig `desfire-ev3-throwaway`: both operations change the
    /// card, so the run refuses any card but the one `--sacrifice-uid` names.
    ///
    /// Each scenario first puts the card in the state it starts from, so a retry
    /// after a dropped read, or a run that stopped half way, still finds it. The
    /// catalogue's order leaves the card set up, as it was before the run.
    @MainActor
    static let desfire: [String: DocsScenario] = [
        "operations-remove-ndef-setup--removed.png": { c in
            try ensureDESFire(c, setUp: true)
            let result = c.text("NDEF setup removed. The card is blank.")
            try runDESFireOperation(c, tile: "Remove NDEF setup", action: "Remove NDEF setup", until: result)
            try c.shot("operations-remove-ndef-setup--removed.png", to: .bottom(result))
        },
        "tag--not-set-up-for-ndef.png": { c in
            try ensureDESFire(c, setUp: false)
            try scanIntoEditor(c)
            let warning = c.identified("editor.unformatted")
            try c.waitFor(warning)
            try c.shot("tag--not-set-up-for-ndef.png",
                       from: .top(c.identified("editor.tagInfo")), to: .bottom(warning))
        },
        "operations-format--ndef-set-up.png": { c in
            try ensureDESFire(c, setUp: false)
            let result = c.text("Card set up for NDEF.")
            try runDESFireOperation(c, tile: "Format", action: "Format tag", until: result)
            try c.shot("operations-format--ndef-set-up.png", to: .bottom(result))
        },
    ]

    /// Scan the card and, if it is not in the state wanted, run the operation
    /// that puts it there. A blank card shows the editor's "not set up" warning;
    /// a set-up card does not.
    @MainActor
    static func ensureDESFire(_ c: DocsCapture, setUp: Bool) throws {
        try scanIntoEditor(c)
        c.settle(1)
        let isBlank = c.identified("editor.unformatted").exists
        if setUp, isBlank {
            try runDESFireOperation(c, tile: "Format", action: "Format tag", until: c.text("Card set up for NDEF."))
        } else if !setUp, !isBlank {
            try runDESFireOperation(
                c, tile: "Remove NDEF setup", action: "Remove NDEF setup",
                until: c.text("NDEF setup removed. The card is blank.")
            )
        }
    }

    /// Scan, open the operation, take both taps, and wait for `result`.
    @MainActor
    static func runDESFireOperation(_ c: DocsCapture, tile: String, action: String, until result: XCUIElement) throws {
        try scanIntoEditor(c)
        try openOperations(c)
        try openOperation(c, tile)
        let uidField = try identifyTap(c)
        guard let uid = c.tagUID else { throw DocsCaptureError("the run has not read the tag's UID") }
        try c.type(uid, into: uidField)
        c.dismissKeyboard()
        // The tile and the start button can carry the action's title too, so
        // the button pressed is the one wholly on screen.
        let buttons = c.app.buttons.matching(NSPredicate(format: "label == %@", c.label(action)))
        var pressed = false
        for _ in 0 ..< 6 {
            if let button = buttons.allElementsBoundByIndex.first(where: { $0.exists && c.wholly($0) }) {
                c.settle(0.5)
                button.tap()
                pressed = true
                break
            }
            c.app.swipeUp()
            c.settle(0.6)
        }
        guard pressed else { throw DocsCaptureError("no \(action) button on screen at the gate") }
        try c.waitForNFC(result, timeout: 60)
    }
}
