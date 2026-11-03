import XCTest

extension DocsShots {
    /// The tag editor, Add record, the record editors and the Protection card,
    /// all reached through Build, so the tag is never touched.
    @MainActor
    static let editor: [String: DocsScenario] = [
        "add-record--grid.png": { c in
            try buildEditor(c)
            try c.tap(c.identified("editor.empty.add"))
            try c.waitFor(c.identified("add.qr"))
            try c.shot("add-record--grid.png", to: .bottom(c.identified("add.wifi")))
        },
        "qr-import--permission-prompt.png": { c in
            // A fresh install has not been asked for the camera. Allow camera is
            // never tapped, so the next language starts from the same state.
            try buildEditor(c)
            try c.tap(c.identified("editor.empty.add"))
            try c.tap(c.identified("add.qr"))
            let allow = c.button("Allow camera")
            try c.waitFor(allow)
            try c.shot("qr-import--permission-prompt.png", to: .bottom(allow))
        },
        "record-editor--location-coordinates.png": { c in
            try buildEditor(c)
            try c.tap(c.identified("editor.empty.add"))
            try c.tap(c.identified("add.map"))
            let longitude = c.field("Longitude")
            try c.waitFor(longitude)
            c.dismissKeyboard()
            try c.shot("record-editor--location-coordinates.png", to: .bottom(longitude))
        },
        "record-editor--wifi.png": { c in
            try buildEditor(c)
            try c.tap(c.identified("editor.empty.add"))
            try c.tap(c.identified("add.wifi"))
            try c.waitFor(c.field("Network name (SSID)"))
            c.dismissKeyboard()
            let footer = c
                .text(
                    "iPhone will not auto-connect from NFC, but Android readers will. Hex NFC writes the record to spec so any reader can pick it up."
                )
            try c.reveal(footer)
            try c.shot("record-editor--wifi.png", to: .bottom(footer))
        },
        "tag-editor--empty.png": { c in
            try buildEditor(c)
            try c.shot("tag-editor--empty.png", to: .bottom(c.identified("editor.empty.add")))
        },
        "tag-editor--url-record.png": { c in
            try buildEditor(c)
            try addURL(c, "https://hex.pro/nfc")
            try c.shot("tag-editor--url-record.png", to: .bottom(c.identified("editor.add")))
        },
        "tag-editor--record-list.png": { c in
            try buildEditor(c)
            try addURL(c, "https://hex.pro/nfc")
            try addRecord(c, "text") { c in try c.type("Hello from Hex NFC", into: c.field("Text")) }
            try addRecord(c, "phone") { c in try c.type("+61255501234", into: c.field("Phone number")) }
            try c.shot("tag-editor--record-list.png", to: .bottom(c.identified("editor.add")))
        },
        "protection-card--type2-advanced.png": { c in
            try openProtectionCard(c)
            let readToggle = c.toggle("Also require password to read")
            try c.reveal(readToggle)
            try c.shot("protection-card--type2-advanced.png",
                       from: .top(c.toggle("Password-protect this tag")),
                       to: .bottom(readToggle))
            try c.tap(c.button("Cancel"))
        },
        "protection-config--type2-advanced.png": { c in
            try openProtectionCard(c)
            try c.flip(c.toggle("Custom start page"), on: true)
            let pack = c.field("PACK (2 bytes)")
            try c.reveal(pack)
            try c.shot("protection-config--type2-advanced.png", from: .top(c.button("Advanced")), to: .bottom(pack))
            try c.tap(c.button("Cancel"))
        },
        "save-preset--protection-section.png": { c in
            try buildEditor(c)
            try turnOnProtection(c)
            try c.tap(c.identified("editor.menu"))
            try c.tap(c.button("Save as preset…"))
            let name = c.field("Name")
            try c.type(protectedPresetName, into: name)
            c.dismissKeyboard()
            let keychain = c
                .text("The secret is stored only on this device (Keychain). It never syncs or travels in an export.")
            try c.reveal(keychain)
            try c.shot("save-preset--protection-section.png", from: .top(name), to: .bottom(keychain))
            try c.tap(c.button("Cancel"))
        },
        "write-sheet--write-failed.png": { c in
            // A location with neither coordinates nor a map URL is refused before
            // any NFC session opens, so this failure needs no tag and writes nothing.
            try buildEditor(c)
            try addRecord(c, "map")
            try c.tap(c.identified("editor.write"))
            let failed = c.text("Write failed")
            try c.waitFor(failed, timeout: 15)
            try c.shot("write-sheet--write-failed.png", from: .top(failed), to: .bottom(c.button("Try again")))
        },
    ]

    /// Build, then the Protection card with the password switch on and
    /// Advanced open. Nothing is staged until Done.
    @MainActor
    static func openProtectionCard(_ c: DocsCapture) throws {
        try buildEditor(c)
        try c.tap(c.identified("editor.protection"))
        let toggle = c.toggle("Password-protect this tag")
        try c.waitFor(toggle)
        try c.flip(toggle, on: true)
        let advanced = c.button("Advanced")
        try c.reveal(advanced)
        try c.tap(advanced)
        c.settle(0.8)
    }

    /// Stage password protection on the editor (with the card's seeded values)
    /// and close the card with Done. Writes nothing.
    @MainActor
    static func turnOnProtection(_ c: DocsCapture) throws {
        try c.tap(c.identified("editor.protection"))
        let toggle = c.toggle("Password-protect this tag")
        try c.waitFor(toggle)
        try c.flip(toggle, on: true)
        try c.tap(c.identified("protection.done"))
        try c.waitUntilGone(c.identified("protection.done"))
    }
}
