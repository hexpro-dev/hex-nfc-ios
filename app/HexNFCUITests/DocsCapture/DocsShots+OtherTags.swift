import XCTest

extension DocsShots {
    /// Shots that need a tag other than the everyday NTAG213, nothing at all,
    /// or an iOS setting, each on its own rig.
    @MainActor
    static let otherTags: [String: DocsScenario] = [
        "protection-config--ultralight-c-key.png": { c in
            // Rig ultralight-c. The key picker opens on Generate; Cancel stages
            // nothing.
            try scanIntoEditor(c)
            try c.tap(c.identified("editor.protection"))
            let toggle = c.toggle("Protect this tag with a key")
            try c.waitFor(toggle)
            try c.flip(toggle, on: true)
            let generate = c.identified("protection.generateKey")
            try c.waitFor(generate)
            try c.shot("protection-config--ultralight-c-key.png",
                       from: .top(toggle), to: .bottom(c.lastText(below: generate)))
            try c.tap(c.button("Cancel"))
        },
        "tag--not-formatted.png": { c in
            // Rig ultralight-ev1-blank. An unformatted tag reads no records, so
            // one is added in the editor to show the warning above a list. It is
            // never written: formatting is one-way, and the blank tag has to stay
            // blank for the next language.
            try scanIntoEditor(c)
            let warning = c.identified("editor.unformatted")
            try c.waitFor(warning)
            try addURL(c, "https://hex.pro/nfc")
            try c.shot("tag--not-formatted.png",
                       from: .top(c.identified("editor.tagInfo")), to: .bottom(c.identified("editor.row.uri")))
        },
        "operations-memory-dump--unsupported-chip.png": { c in
            // Rig mock. None of the tags on hand lacks memory reads, and the mock
            // tag has no chip family, so the app's own preflight refuses it with
            // the same message and screen a real unsupported chip gets.
            try scanIntoEditor(c)
            try openOperations(c)
            try openOperation(c, "Memory dump")
            let message = c.text("This tag does not support that operation.")
            try c.waitFor(message, timeout: 20)
            try c.shot("operations-memory-dump--unsupported-chip.png",
                       from: .top(message), to: .bottom(c.identified("operation.retry")))
        },
        "operations-permanent-lock--lock-written.png": { c in
            // Rig ultralight-c-sacrificial, irreversible. Only an Ultralight C
            // reports "Lock written." (its lock bytes take effect on the next
            // activation); an NTAG213 proves the lock in session and reports
            // "Tag permanently locked." instead.
            try scanIntoEditor(c)
            try openOperations(c)
            try openOperation(c, "Permanent lock")
            let uidField = try identifyTap(c)
            try confirm(c, uidField: uidField, "Permanently lock this tag")
            let written = c.text("Lock written.")
            try c.waitForNFC(written, timeout: 40)
            try c.shot("operations-permanent-lock--lock-written.png",
                       from: .top(written), to: .bottom(c.lastText(below: written)))
        },
        "tag-editor-protection--permanently-locked.png": { c in
            // Rig ntag213-sacrificial, irreversible the first time only: a tag
            // that is already locked is just scanned, so one locked tag serves
            // every language.
            try scanIntoEditor(c)
            if !c.identified("editor.protection.locked").exists {
                try openOperations(c)
                try openOperation(c, "Permanent lock")
                let uidField = try identifyTap(c)
                try confirm(c, uidField: uidField, "Permanently lock this tag")
                try c.waitForNFC(c.text("Tag permanently locked."), timeout: 40)
                try scanIntoEditor(c)
            }
            let card = c.identified("editor.protection.locked")
            try c.waitFor(card)
            try c.shot("tag-editor-protection--permanently-locked.png",
                       from: .top(c.identified("editor.tagInfo")), to: .bottom(card))
        },
    ]
}
