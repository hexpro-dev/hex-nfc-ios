import XCTest

extension DocsShots {
    /// The Advanced console. Identify, a READ and a scan only read the tag.
    @MainActor
    static let console: [String: DocsScenario] = [
        "advanced-console--idle.png": { c in
            try openConsole(c)
            try c.shot("advanced-console--idle.png", to: .bottom(c.containing(c.label("Halt"), type: .button)))
        },
        "advanced-console--identified.png": { c in
            try openConsole(c)
            try c.tap(c.button("Identify"))
            try c.waitForNFC(c.containing(c.labelPrefix("Identified: %@ · %@")), timeout: 25)
            c.afterNFC()
            let rows = presetRows(c)
            guard rows.count >= 2 else { throw DocsCaptureError("fewer than two presets under Search") }
            try c.shot("advanced-console--identified.png",
                       from: .below(c.app.segmentedControls.firstMatch), to: .bottom(rows[1]))
        },
        "advanced-console--run-finished.png": { c in
            try openConsole(c)
            try c.tap(c.containing(c.label("Read 16 bytes"), type: .button))
            try c.tap(c.button("Run"))
            let done = c.valued("Status", "Done")
            try c.waitForNFC(done, timeout: 25)
            c.afterNFC()
            showLatestScrollback(c)
            try c.shot("advanced-console--run-finished.png", from: .top(done), to: .above(c.text("Presets")))
        },
        "advanced-console--all-nfc-traffic.png": { c in
            // The trace holds this process's frames only, so scan first.
            try scanIntoEditor(c)
            try c.tap(c.button("Close"))
            try c.waitUntilGone(c.identified("editor.write"))
            try c.tap(c.tile("Advanced"))
            try c.tap(c.app.segmentedControls.buttons[c.label("All NFC traffic")])
            showLatestScrollback(c)
            try c.shot("advanced-console--all-nfc-traffic.png",
                       from: .top(c.app.segmentedControls.firstMatch), to: .above(c.text("Presets")))
        },
    ]

    @MainActor
    static func openConsole(_ c: DocsCapture) throws {
        try c.launchHome()
        try c.tap(c.tile("Advanced"))
        try c.waitFor(c.text("Presets"))
    }

    /// The preset rows under Search, top to bottom, whatever the tag has
    /// re-ordered them to. A row exposes more than one full-width button, at
    /// slightly different heights, so a row counts only once it starts below
    /// the bottom of the last one kept.
    @MainActor
    static func presetRows(_ c: DocsCapture) -> [XCUIElement] {
        let search = c.field("Search")
        let wide = c.app.frame.width * 0.6
        var rows: [XCUIElement] = []
        var floor: CGFloat = -.greatestFiniteMagnitude
        for button in c.elements(.button, below: search) where button.frame.width > wide {
            guard button.frame.minY >= floor - 2 else { continue }
            rows.append(button)
            floor = button.frame.maxY
        }
        return rows
    }

    /// The scrollback's auto-scroll can stop short of the newest line (a lazy
    /// stack scrolled to a row it has not measured yet), so swipe it the rest of
    /// the way. A plain swipe, inside the scrollback only.
    @MainActor
    static func showLatestScrollback(_ c: DocsCapture) {
        let scope = c.app.segmentedControls.firstMatch
        let presets = c.text("Presets")
        guard scope.exists, presets.exists else { return }
        let top = scope.frame.maxY
        let bottom = presets.frame.minY
        let scrollback = c.app.scrollViews.allElementsBoundByIndex.first {
            $0.frame.minY >= top && $0.frame.maxY <= bottom && $0.frame.height > 100
        }
        scrollback?.swipeUp()
        c.settle(1)
    }
}
