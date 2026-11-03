import XCTest

extension DocsShots {
    /// The scan and write sheets. The success states last about a second with
    /// the iOS NFC sheet still over them, so they are caught by polling and
    /// shot whole, as a reader sees them.
    @MainActor
    static let scanAndWrite: [String: DocsScenario] = [
        "write-sheet--done.png": { c in
            try buildEditor(c)
            try addText(c, "Hello from Hex NFC")
            try c.tap(c.identified("editor.write"))
            try c.catchTransient(c.text("Locked in"), timeout: 30)
            try c.shot("write-sheet--done.png", settle: 0.2)
        },
        "scan-sheet--tag-detected.png": { c in
            // Follows write-sheet--done, so the tag holds one known record.
            try c.launchHome()
            try c.tap(c.tile("Scan"))
            try c.catchTransient(c.text("Tag detected"), timeout: 30)
            try c.shot("scan-sheet--tag-detected.png", settle: 0.2)
        },
        "tag-editor--records.png": { c in
            try scanIntoEditor(c)
            try c.shot("tag-editor--records.png", to: .bottom(c.identified("editor.add")))
        },
        "scan-sheet--polling.png": { c in
            // Rig no-tag: nothing under the phone, so the sheet waits.
            try c.launchHome()
            try c.tap(c.tile("Scan"))
            try c.waitFor(c.text("Hold tag against the top of your iPhone"), timeout: 10)
            try pollingShot(c, "scan-sheet--polling.png", failure: "Scan failed")
        },
        "write-sheet--polling.png": { c in
            try buildEditor(c)
            try addText(c, "Hello from Hex NFC")
            try c.tap(c.identified("editor.write"))
            try c.waitFor(c.text("Hold tag against the top of your iPhone"), timeout: 10)
            try pollingShot(c, "write-sheet--polling.png", failure: "Write failed")
        },
    ]

    /// A waiting NFC sheet, captured only while it is still waiting, and then
    /// closed by ending the app. The app's own Cancel sits under the iOS sheet
    /// where no tap reaches it, and a sheet left open makes iOS refuse the next
    /// scenario's session ("Write failed", Chinese, 2026-10-27), so the app is
    /// terminated and the session given time to tear down.
    @MainActor
    static func pollingShot(_ c: DocsCapture, _ asset: String, failure: String) throws {
        c.settle(3)
        guard !c.text(failure).exists else {
            throw DocsCaptureError("the sheet stopped waiting (\(c.label(failure))) before \(asset) was taken")
        }
        try c.shot(asset, settle: 0.2)
        c.app.terminate()
        c.settle(5)
    }

    /// Operations screens that read the tag at most. Format confirms, but finds
    /// the factory Capability Container already in place and writes nothing.
    @MainActor
    static let operations: [String: DocsScenario] = [
        "operations--dangerous-actions.png": { c in
            try buildEditor(c)
            try openOperations(c)
            // The last tile, so the whole grid is on screen: five tiles make
            // three rows, and stopping at Format cut the third row off.
            try c.reveal(c.text("Remove NDEF setup"))
            try c.shot("operations--dangerous-actions.png",
                       from: .topOfAll("operations.dangerousActions"), to: .bottomOfAll("operations.dangerousActions"))
        },
        "operations-permanent-lock--idle.png": { c in
            try buildEditor(c)
            try openOperations(c)
            try openOperation(c, "Permanent lock")
            let start = c.identified("operation.start")
            try c.reveal(start)
            try c.shot("operations-permanent-lock--idle.png", to: .bottom(start))
        },
        "operations-remove-password--idle-warning.png": { c in
            try buildEditor(c)
            try openOperations(c)
            try openOperation(c, "Remove password")
            let start = c.identified("operation.start")
            try c.reveal(start)
            try c.shot("operations-remove-password--idle-warning.png", to: .bottom(start))
        },
        "operations-attempt-limit--form.png": { c in
            try buildEditor(c)
            try openOperations(c)
            try openOperation(c, "Attempt limit")
            let next = c.button("Continue")
            try c.reveal(next)
            try c.shot("operations-attempt-limit--form.png", to: .bottom(next))
        },
        "operations-memory-dump--reading.png": { c in
            try scanIntoEditor(c)
            try openOperations(c)
            // The tile starts its one tap as it opens.
            try openOperation(c, "Memory dump")
            try c.catchTransient(c.text("Reading…"), timeout: 20)
            try c.shot("operations-memory-dump--reading.png", settle: 0.2)
        },
        "operations-memory-dump--done-with-share.png": { c in
            try scanIntoEditor(c)
            try openOperations(c)
            try openOperation(c, "Memory dump")
            let ready = c.text("Memory dump ready.")
            try c.waitForNFC(ready, timeout: 30)
            let share = c.app.descendants(matching: .any)[c.label("Share .bin")].firstMatch
            try c.waitFor(share, timeout: 10)
            try c.shot("operations-memory-dump--done-with-share.png", from: .top(ready), to: .bottom(share))
        },
        "operations-erase--confirmation.png": { c in
            // Tap 1 only reads. The UID is never typed, so Erase tag stays disabled.
            try scanIntoEditor(c)
            try openOperations(c)
            try openOperation(c, "Erase")
            _ = try identifyTap(c)
            c.dismissKeyboard()
            let cancel = c.identified("operation.cancel")
            try c.reveal(cancel)
            try c.shot("operations-erase--confirmation.png", to: .bottom(cancel))
            try c.tap(cancel)
        },
        "operations-permanent-lock--uid-gate.png": { c in
            // Tap 1 only reads the lock bytes. The UID is never typed here: the
            // lock itself runs only on a sacrificial rig.
            try scanIntoEditor(c)
            try openOperations(c)
            try openOperation(c, "Permanent lock")
            _ = try identifyTap(c)
            c.dismissKeyboard()
            let cancel = c.identified("operation.cancel")
            try c.reveal(cancel)
            try c.shot("operations-permanent-lock--uid-gate.png", to: .bottom(cancel))
            try c.tap(cancel)
        },
        "operations-format--already-formatted.png": { c in
            try scanIntoEditor(c)
            try openOperations(c)
            try openOperation(c, "Format")
            let uidField = try identifyTap(c)
            try confirm(c, uidField: uidField, "Format tag")
            let result = c.text("Already formatted: nothing written.")
            try c.waitForNFC(result, timeout: 40)
            let footnote = c
                .text(
                    "Page 3 already holds this chip's Capability Container. If the tag still won't read, the data area is what needs rewriting: use Erase."
                )
            try c.shot("operations-format--already-formatted.png",
                       from: .top(result), to: .bottom(footnote.exists ? footnote : result))
        },
    ]
}
