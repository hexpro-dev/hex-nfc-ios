import XCTest

extension DocsShots {
    /// Shots of a protected tag, and of the protect and remove flows. Every
    /// scenario that protects the tag runs inside `whileProtected`, which
    /// removes the protection again whatever happens to the shot. Only the
    /// harness's own password is ever presented to a tag that has an attempt
    /// limit, so no try is ever spent against one.
    @MainActor
    static let protection: [String: DocsScenario] = [
        "operations-protect-with-password--fields.png": { c in
            try ensureUnprotected(c)
            try scanIntoEditor(c)
            try openOperations(c)
            try openOperation(c, "Protect with password")
            _ = try identifyTap(c)
            c.dismissKeyboard()
            let readToggle = c.toggle("Also require password to read")
            try c.reveal(readToggle)
            try c.shot("operations-protect-with-password--fields.png",
                       from: .top(c.identified("operation.identifiedChip")), to: .bottom(readToggle))
            try c.tap(c.identified("operation.cancel"))
        },
        "operations-protect-with-password--uid-confirmation.png": { c in
            try ensureUnprotected(c)
            try scanIntoEditor(c)
            try openOperations(c)
            try openOperation(c, "Protect with password")
            let uidField = try identifyTap(c)
            c.dismissKeyboard()
            let cancel = c.identified("operation.cancel")
            try c.reveal(cancel)
            try c.shot("operations-protect-with-password--uid-confirmation.png",
                       from: .top(c.text("Protect tag")), to: .bottom(cancel))
            _ = uidField
            try c.tap(cancel)
        },
        "tag-screen--protection-write-only.png": { c in
            try whileProtected(c) {
                try scanIntoEditor(c)
                let card = c.identified("editor.protection")
                try c.shot("tag-screen--protection-write-only.png",
                           from: .top(c.identified("editor.tagInfo")), to: .bottom(card))
            }
        },
        "protection-config--removal-footer.png": { c in
            try whileProtected(c) {
                try scanIntoEditor(c)
                try c.tap(c.identified("editor.protection"))
                let toggle = c.toggle("Password-protect this tag")
                try c.waitFor(toggle)
                try c.flip(toggle, on: false)
                c.settle(0.8)
                let footer = c
                    .text(
                        "Removes this tag's protection on the next write. Both locks go: the tag can be read and written by anyone afterwards, and the password returns to its factory default. You'll need the current password to do it."
                    )
                try c.reveal(footer)
                try c.shot("protection-config--removal-footer.png", from: .top(toggle), to: .bottom(footer))
                try c.tap(c.button("Cancel"))
            }
        },
        "operations--error.png": { c in
            // Permanent lock refuses a password-protected tag at tap 1, which
            // only reads: a real error the tag cannot be harmed by.
            try whileProtected(c) {
                try scanIntoEditor(c)
                try openOperations(c)
                try openOperation(c, "Permanent lock")
                try c.tap(c.identified("operation.start"))
                let retry = c.identified("operation.retry")
                try c.waitForNFC(retry, timeout: 30)
                try c.shot("operations--error.png", to: .bottom(retry))
            }
        },
        "write-sheet--needs-unlock.png": { c in
            try whileProtected(c) {
                try buildEditor(c)
                try addText(c, "Hello from Hex NFC")
                try c.tap(c.identified("editor.write"))
                let unlock = c.button("Unlock & write")
                try c.waitForNFC(unlock, timeout: 30)
                c.dismissKeyboard()
                try c.shot("write-sheet--needs-unlock.png", from: .top(c.text("Tag is protected")), to: .bottom(unlock))
                try c.tap(c.button("Cancel"))
            }
        },
        "write--confirm-remove-protection.png": { c in
            // Staged removal, tap 1, the password typed: the card that asks for
            // the UID before tap 2. Cancelled there, so nothing is sent.
            try whileProtected(c) {
                try scanIntoEditor(c)
                try c.tap(c.identified("editor.protection"))
                let toggle = c.toggle("Password-protect this tag")
                try c.waitFor(toggle)
                try c.flip(toggle, on: false)
                try c.tap(c.identified("protection.done"))
                try c.tap(c.identified("editor.write"))
                let unlock = c.button("Unlock & continue")
                try c.waitForNFC(unlock, timeout: 30)
                try enterTagPassword(c, testPassword)
                try c.tap(unlock)
                let title = c.text("Remove protection")
                try c.waitFor(title, timeout: 30)
                c.dismissKeyboard()
                try c.shot("write--confirm-remove-protection.png", from: .top(title), to: .bottom(c.button("Cancel")))
                try c.tap(c.button("Cancel"))
            }
        },
        "operations-remove-password--factory-default-offer.png": { c in
            // One refused password, presented while the tag has no attempt
            // limit, so it costs nothing. The offer is never taken.
            try whileProtected(c) {
                try scanIntoEditor(c)
                try openOperations(c)
                try openOperation(c, "Remove password")
                let uidField = try identifyTap(c)
                try enterTagPassword(c, wrongPassword)
                try confirm(c, uidField: uidField, "Remove password")
                let offer = c.identified("operation.factoryDefaultOffer")
                try c.waitForNFC(offer, timeout: 40)
                c.dismissKeyboard()
                let cancel = c.identified("operation.cancel")
                try c.reveal(cancel)
                try c.shot("operations-remove-password--factory-default-offer.png",
                           from: .top(c.identified("operation.needsCredential")), to: .bottom(cancel))
                try c.tap(cancel)
            }
        },
        "operations-remove-password--done.png": { c in
            try ensureUnprotected(c)
            try protectTag(c)
            try scanIntoEditor(c)
            try openOperations(c)
            try openOperation(c, "Remove password")
            let uidField = try identifyTap(c)
            try enterTagPassword(c, testPassword)
            try confirm(c, uidField: uidField, "Remove password")
            let removed = c.text("Password removed.")
            try c.waitForNFC(removed, timeout: 40)
            try c.shot("operations-remove-password--done.png", to: .bottom(removed))
            try ensureUnprotected(c)
        },
        "scan-sheet--protected.png": { c in
            try whileProtected(c, readToo: true) {
                try c.launchHome()
                try c.tap(c.tile("Scan"))
                try c.waitForNFC(c.field("Tag password (4 bytes)"), timeout: 30)
                c.dismissKeyboard()
                try c.shot(
                    "scan-sheet--protected.png",
                    from: .top(c.text("Tag is protected")),
                    to: .bottom(c.button("Unlock & scan again"))
                )
            }
        },
        "operations-attempt-limit--readout.png": { c in
            try whileProtected(c) {
                try scanIntoEditor(c)
                try openOperations(c)
                try openOperation(c, "Attempt limit")
                try c.tap(c.button("Continue"))
                _ = try identifyTap(c)
                c.dismissKeyboard()
                let cancel = c.identified("operation.cancel")
                try c.reveal(cancel)
                try c.shot("operations-attempt-limit--readout.png",
                           from: .top(c.text("This tag has no attempt limit set.")), to: .bottom(cancel))
                try c.tap(cancel)
            }
        },
        "operations-attempt-limit--verified.png": { c in
            // Sets a limit of 3, then `whileProtected` removes the password with
            // the right one straight away, which clears the limit. Nothing ever
            // presents a wrong password while the limit is set.
            try whileProtected(c) {
                try scanIntoEditor(c)
                try openOperations(c)
                try openOperation(c, "Attempt limit")
                try c.tap(c.button("Continue"))
                let uidField = try identifyTap(c)
                try enterTagPassword(c, testPassword)
                try confirm(c, uidField: uidField, "Set the attempt limit")
                // The success banner's footnote. The longer warning above the
                // confirm button goes away once the limit is set.
                let footnote = c.text("One more wrong try after that and it stops accepting its password for good.")
                try c.waitForNFC(footnote, timeout: 40)
                try c.shot("operations-attempt-limit--verified.png", to: .bottom(footnote))
            }
        },
    ]
}
