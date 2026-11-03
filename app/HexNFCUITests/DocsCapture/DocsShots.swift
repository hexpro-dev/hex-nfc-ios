import XCTest

/// Reaches one documentation state and takes its shot.
typealias DocsScenario = @MainActor (DocsCapture) throws -> Void

/// Every scenario the harness can run, keyed by the asset name it saves. The
/// keys must match `docs-capture-catalogue.json` exactly: the test reports a
/// catalogue entry with no scenario, and fails on a scenario with no entry.
///
/// Each scenario starts from a fresh launch, so it does not depend on the one
/// before it except through what is on the tag and in the store. The catalogue's
/// order is what makes those dependencies hold (History is shot empty before
/// anything scans; the tag is protected only after every shot that needs it
/// open), and every scenario that protects the tag removes the protection again
/// before it returns, whether or not its shot was taken.
enum DocsShots {
    @MainActor
    static var scenarios: [String: DocsScenario] {
        var all: [String: DocsScenario] = [:]
        for group in [home, console, editor, library, scanAndWrite, operations, protection, otherTags, desfire] {
            all.merge(group) { _, _ in preconditionFailure("two scenarios save the same asset") }
        }
        return all
    }

    /// The password every protection scenario sets and removes, so a run that
    /// died half way can always be recovered by hand with Remove password.
    static let testPassword = "48455850"
    /// A password the test tag never holds, for the refused-password states. It
    /// is presented only while the tag has no attempt limit, so it costs nothing.
    static let wrongPassword = "11223344"

    // MARK: Checking the tag

    /// Identify the tag under the phone in the Advanced console and check it is
    /// the rig's chip. Returns its UID as uppercase hex without separators.
    @MainActor
    static func verifyTag(_ c: DocsCapture, chip: String) throws -> String {
        try c.launchHome()
        try c.tap(c.tile("Advanced"))
        try c.tap(c.button("Identify"))
        // Scrollback notes are translated, so each is found by the text its
        // catalogue entry opens with in the run's language.
        let identifiedPrefix = c.labelPrefix("Identified: %@ · %@")
        let identified = c.containing(identifiedPrefix)
        let unknown = c.containing(c.labelPrefix("Tag connected but the chip is unknown · %@"))
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline, !identified.exists, !unknown.exists {
            c.settle(0.5)
        }
        c.afterNFC()
        guard identified.exists else {
            throw DocsCaptureError(unknown.exists
                ? "the tag under the phone is a chip the app cannot name; this rig needs \(chip)"
                : "no tag was identified within 25 s; is the \(chip) under the top of the phone?")
        }
        // "Identified: NTAG213 · 04:BA:4A:92:1B:21:90", in every language with
        // the chip first and the UID after the same " · ". Right to left, each
        // argument arrives wrapped in invisible direction isolates (U+2068 and
        // U+2069), which would stop "NTAG213" matching, so those go first.
        let directionMarks = CharacterSet(
            charactersIn: "\u{200E}\u{200F}\u{061C}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}"
        )
        var plain = String.UnicodeScalarView()
        plain.append(contentsOf: identified.label.unicodeScalars.filter { !directionMarks.contains($0) })
        let line = String(plain).replacingOccurrences(of: identifiedPrefix, with: "")
        let parts = line.components(separatedBy: " · ")
        guard parts.count == 2 else { throw DocsCaptureError("unexpected identify line: \(identified.label)") }
        guard parts[0].hasPrefix(chip) else {
            throw DocsCaptureError("the tag under the phone is \(parts[0]); this rig needs \(chip)")
        }
        return parts[1].uppercased().filter(\.isHexDigit)
    }

    // MARK: Shared routes

    /// Home, Scan, and the tag editor the scan hands over to. A tag that the
    /// harness read-protected stops at the scan's locked state; it is opened with
    /// the harness's password, the only one it could hold.
    ///
    /// A tag resting on the phone is read reliably but not always: a read can
    /// end "Lost the tag mid-read", so a failed scan is tried again, up to
    /// three times, before the scenario gives up.
    @MainActor
    static func scanIntoEditor(_ c: DocsCapture) throws {
        var lastError: Error = DocsCaptureError("no scan attempted")
        for _ in 0 ..< 3 {
            do {
                try scanOnce(c)
                return
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    @MainActor
    private static func scanOnce(_ c: DocsCapture) throws {
        try c.launchHome()
        try c.tap(c.tile("Scan"))
        let editor = c.identified("editor.write")
        // Inside the scan and write sheets every element reports the sheet's
        // own identifier, so their states are found by their text.
        let locked = c.field("Tag password (4 bytes)")
        let failed = c.text("Scan failed")
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, !editor.exists, !locked.exists, !failed.exists {
            c.settle(0.5)
        }
        if failed.exists {
            throw DocsCaptureError("the scan failed")
        }
        if locked.exists, !editor.exists {
            c.afterNFC()
            try enterTagPassword(c, testPassword)
            try c.tap(c.button("Unlock & scan again"))
        }
        try c.waitForNFC(editor, timeout: 30)
    }

    /// Home, Build: the editor with no tag and no records.
    @MainActor
    static func buildEditor(_ c: DocsCapture) throws {
        try c.launchHome()
        try c.tap(c.tile("Build"))
        try c.waitFor(c.identified("editor.empty.add"), timeout: 15)
    }

    /// Add a record of `kind` (`uri`, `text`, `phone`, ...) from the editor,
    /// filling its fields with `fill` before saving.
    @MainActor
    static func addRecord(_ c: DocsCapture, _ kind: String, fill: (DocsCapture) throws -> Void = { _ in }) throws {
        let listAdd = c.identified("editor.add")
        try c.tap(listAdd.exists ? listAdd : c.identified("editor.empty.add"))
        try c.tap(c.identified("add.\(kind)"))
        try c.waitFor(c.identified("record.save"))
        try fill(c)
        try c.tap(c.identified("record.save"))
        try c.waitUntilGone(c.identified("record.save"))
    }

    @MainActor
    static func addURL(_ c: DocsCapture, _ url: String) throws {
        try addRecord(c, "uri") { c in try c.type(url, into: c.field("URL")) }
    }

    /// Write the editor's records and wait for the sheet to close itself.
    @MainActor
    static func writeFromEditor(_ c: DocsCapture) throws {
        try c.tap(c.identified("editor.write"))
        let sheet = c.identified("write.sheet")
        try c.waitFor(sheet)
        try c.waitUntilGone(sheet, timeout: 40)
        c.afterNFC()
    }

    @MainActor
    static func addText(_ c: DocsCapture, _ text: String) throws {
        try addRecord(c, "text") { c in try c.type(text, into: c.field("Text")) }
    }

    /// Put one Text record on the tag through Build.
    ///
    /// Everything the harness writes is text. A link on a tag lying in the
    /// field makes iOS read it in the background between the app's sessions:
    /// its "Website NFC Tag" banner covers the editor's Write button, and its
    /// read can make the app's own read fail and report the tag as protected.
    @MainActor
    static func writeTextToTag(_ c: DocsCapture, _ text: String) throws {
        try buildEditor(c)
        try addText(c, text)
        try writeFromEditor(c)
    }

    /// Ready the rig's tag: one Text record, so nothing an earlier run left on
    /// it can bring up iOS's background reading.
    /// The tag is made open first: a run that died mid-protection leaves it
    /// holding the harness's password, and a protected tag would refuse the write.
    @MainActor
    static func prepareTag(_ c: DocsCapture) throws {
        try ensureUnprotected(c)
        try writeTextToTag(c, "Hex NFC")
    }

    // MARK: Operations

    @MainActor
    static func openOperations(_ c: DocsCapture) throws {
        try c.tap(c.identified("editor.menu"))
        try c.tap(c.button("Operations…"))
        try c.waitFor(c.identified("operations.dangerousActions"), timeout: 10)
    }

    /// Open one Operations tile by its title.
    @MainActor
    static func openOperation(_ c: DocsCapture, _ title: String) throws {
        let tile = c.text(title)
        try c.reveal(tile)
        try c.tap(tile)
    }

    /// Tap 1 of a gated operation: start it and wait for the typed-UID card.
    @MainActor
    static func identifyTap(_ c: DocsCapture) throws -> XCUIElement {
        try c.tap(c.identified("operation.start"))
        let uidField = c.field("Type this tag's UID to confirm.")
        try c.waitForNFC(uidField, timeout: 30)
        return uidField
    }

    /// Type the tag's UID into the confirmation and press `confirmKey`.
    @MainActor
    static func confirm(_ c: DocsCapture, uidField: XCUIElement, _ confirmKey: String) throws {
        guard let uid = c.tagUID else { throw DocsCaptureError("the run has not read the tag's UID") }
        try c.type(uid, into: uidField)
        c.dismissKeyboard()
        let button = c.button(confirmKey)
        try c.reveal(button)
        try c.tap(button)
    }

    /// The current password, for an operation that asks for one at tap 1.
    @MainActor
    static func enterTagPassword(_ c: DocsCapture, _ password: String) throws {
        let field = c.field("Tag password (4 bytes)")
        try c.reveal(field)
        try c.type(password, into: field)
        c.dismissKeyboard()
    }

    // MARK: Protection

    /// Protect the tag with `testPassword`, write-only unless `readToo`, through
    /// Operations > Protect with password. Two taps.
    @MainActor
    static func protectTag(_ c: DocsCapture, readToo: Bool = false) throws {
        try scanIntoEditor(c)
        try openOperations(c)
        try openOperation(c, "Protect with password")
        let uidField = try identifyTap(c)
        try c.replace(c.field("Password (4 bytes)"), with: testPassword)
        c.dismissKeyboard()
        if readToo {
            let toggle = c.toggle("Also require password to read")
            try c.reveal(toggle)
            try c.flip(toggle, on: true)
        }
        try confirm(c, uidField: uidField, "Protect tag")
        try c.waitForNFC(c.text("Password set."), timeout: 40)
    }

    /// Remove the test password through Operations > Remove password. Two taps.
    @MainActor
    static func removeProtection(_ c: DocsCapture) throws {
        try scanIntoEditor(c)
        try openOperations(c)
        try openOperation(c, "Remove password")
        let uidField = try identifyTap(c)
        try enterTagPassword(c, testPassword)
        try confirm(c, uidField: uidField, "Remove password")
        try c.waitForNFC(c.text("Password removed."), timeout: 40)
    }

    /// Whether the tag under the phone reads as protected, from a fresh scan's
    /// Protection card.
    @MainActor
    static func tagIsProtected(_ c: DocsCapture) throws -> Bool {
        try scanIntoEditor(c)
        let card = c.identified("editor.protection")
        try c.waitFor(card)
        return !card.label.contains(c.label("Off"))
    }

    /// Leave the tag as the rig expects it: open. A scenario that died with the
    /// tag protected is recovered here, with the one password the harness uses.
    /// Remove password is tried up to three times: a removal can end with the
    /// tag lost mid-sequence, and the app reports the residue rather than
    /// guessing, so the only proof is a fresh scan that reads Off.
    @MainActor
    static func ensureUnprotected(_ c: DocsCapture) throws {
        for _ in 0 ..< 3 {
            guard try tagIsProtected(c) else { return }
            try? removeProtection(c)
        }
        guard try !tagIsProtected(c) else {
            throw DocsCaptureError(
                "the tag is still protected after three tries; recover it by hand with \(testPassword)"
            )
        }
    }

    /// Run `body` on a protected tag and remove the protection afterwards,
    /// whether or not `body` succeeded. A failure to clean up is the one error
    /// worth stopping for, so it wins over the body's.
    ///
    /// Protecting can itself end uncertain ("Couldn't confirm that protection
    /// switched on"), so the clean-up runs whether the protect step, the body
    /// or neither failed. When both fail, both are reported.
    @MainActor
    static func whileProtected(_ c: DocsCapture, readToo: Bool = false, _ body: () throws -> Void) throws {
        try ensureUnprotected(c)
        var failure: Error?
        do {
            try protectTag(c, readToo: readToo)
            try body()
        } catch {
            failure = error
        }
        do {
            try ensureUnprotected(c)
        } catch {
            throw DocsCaptureError(failure.map { "\($0); then, cleaning up: \(error)" } ?? "cleaning up: \(error)")
        }
        if let failure {
            throw failure
        }
    }
}
