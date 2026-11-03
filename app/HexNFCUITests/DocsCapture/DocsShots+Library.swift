import XCTest

extension DocsShots {
    /// The Library's Presets and History tabs.
    @MainActor
    static let library: [String: DocsScenario] = [
        "library-history--empty.png": { c in
            try openLibrary(c)
            try c.tap(c.button("History"))
            try clearHistory(c)
            let empty = c.text("The last 50 tags you scan show up here. Pin one to keep it.")
            try c.waitFor(empty)
            try c.shot("library-history--empty.png", from: .top(c.button("Presets")), to: .bottom(empty))
        },
        "library--presets-list.png": { c in
            try ensurePresets(c)
            try openLibrary(c)
            let rows = libraryRows(c)
            guard rows.count >= 2 else { throw DocsCaptureError("the Presets tab shows \(rows.count) rows, not two") }
            try c.shot("library--presets-list.png", from: .top(c.button("Presets")), to: .bottom(rows[1]))
        },
        "library--preset-swipe-leading.png": { c in
            // A full leading swipe fires Write, which writes the preset to the tag
            // under the phone, so this runs with the shots that rewrite the tag,
            // and swipes the unprotected preset: a stray write cannot protect it.
            try ensurePresets(c)
            try openLibrary(c)
            let row = presetCell(c, plainPresetName)
            try c.waitFor(row)
            // Read before the swipe: a row slid open reaches past the screen
            // edge, and `libraryRows` leaves out a row that is not inside it.
            // The crop only needs the rows' heights, which the swipe keeps.
            let rows = libraryRows(c)
            c.swipeLeading(row)
            let write = c.button("Write")
            try c.waitFor(write, timeout: 5)
            try c.shot("library--preset-swipe-leading.png",
                       from: .top(c.button("Presets")), to: .bottom(rows.last ?? row))
        },
        "library-history--list.png": { c in
            // Three different notes, each written and scanned back, so History
            // holds three rows from the one tag; rescanning the same contents
            // would only refresh a row. Earlier scans are cleared first, so
            // those three are all it shows.
            try openLibrary(c)
            try c.tap(c.button("History"))
            try clearHistory(c)
            for note in ["Front door", "Studio shelf", "Bike lock"] {
                try writeTextToTag(c, note)
                try scanIntoEditor(c)
            }
            try openLibrary(c)
            try c.tap(c.button("History"))
            let rows = libraryRows(c)
            guard let first = rows.first else { throw DocsCaptureError("History is empty after three scans") }
            c.swipeLeading(first)
            try c.tap(c.button("Pin"), timeout: 5)
            c.settle(1)
            let pinned = libraryRows(c)
            try c.shot("library-history--list.png",
                       from: .top(c.button("Presets")), to: .bottom(pinned.last ?? first))
        },
    ]

    static let plainPresetName = "Welcome note"
    static let protectedPresetName = "Staff only note"

    @MainActor
    static func openLibrary(_ c: DocsCapture) throws {
        try c.launchHome()
        try c.tap(c.tile("Library"))
        try c.waitFor(c.button("History"))
        c.settle(0.8)
    }

    /// A Library row by the name it shows. The row carries no label of its own,
    /// so it is found by the text inside it.
    @MainActor
    static func presetCell(_ c: DocsCapture, _ name: String) -> XCUIElement {
        c.app.cells.containing(NSPredicate(format: "label == %@", name)).firstMatch
    }

    /// The Library list's rows on screen, top to bottom. A deleted row stays in
    /// the tree for a moment after it has slid off to the left, and a gesture
    /// sent to it ends the run, so only rows inside the screen count.
    @MainActor
    static func libraryRows(_ c: DocsCapture) -> [XCUIElement] {
        let screen = c.app.frame
        return c.app.collectionViews.firstMatch.cells.allElementsBoundByIndex
            .filter { $0.exists && $0.frame.height > 0 }
            .filter { $0.frame.minX >= screen.minX - 1 && $0.frame.maxX <= screen.maxX + 1 }
            .sorted { $0.frame.minY < $1.frame.minY }
    }

    /// Delete every row on the open History tab. The run's first scans, which
    /// check the tag and clear what an earlier run left on it, land in History
    /// before any shot is taken.
    @MainActor
    static func clearHistory(_ c: DocsCapture) throws {
        for _ in 0 ..< 60 {
            c.settle(0.8)
            guard let row = libraryRows(c).first(where: { $0.isHittable }) else { return }
            c.swipeTrailing(row)
            let delete = c.button("Delete")
            if delete.waitForExistence(timeout: 2), delete.isHittable {
                delete.tap()
            }
        }
        throw DocsCaptureError("History still has rows after 60 deletions")
    }

    /// Two presets, one plain and one that applies protection, saved through
    /// Build. Neither writes the tag. Skipped when the Library already has them.
    @MainActor
    static func ensurePresets(_ c: DocsCapture) throws {
        try openLibrary(c)
        if presetCell(c, plainPresetName).exists, presetCell(c, protectedPresetName).exists {
            return
        }
        try savePreset(c, name: plainPresetName, text: "Welcome to the studio", protected: false)
        try savePreset(c, name: protectedPresetName, text: "Staff only", protected: true)
    }

    @MainActor
    static func savePreset(_ c: DocsCapture, name: String, text: String, protected: Bool) throws {
        try buildEditor(c)
        try addText(c, text)
        if protected {
            try turnOnProtection(c)
        }
        try c.tap(c.identified("editor.menu"))
        try c.tap(c.button("Save as preset…"))
        try c.type(name, into: c.field("Name"))
        try c.tap(c.identified("savePreset.save"))
        try c.waitUntilGone(c.identified("savePreset.save"))
    }
}
