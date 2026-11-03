import XCTest

/// What one capture run was asked to do, read from the environment that
/// `scripts/docs-screenshots` hands the test runner (xcodebuild forwards every
/// `TEST_RUNNER_`-prefixed variable with the prefix removed).
struct DocsCaptureConfig {
    /// Off unless the host script asked for a capture, so an ordinary UI test
    /// run never drives the phone through the screenshot scenarios.
    let enabled: Bool
    /// A docs locale: `en`, `zh`, `ar`, `es`, `ja`, `fr` or `pt-BR`.
    let locale: String
    /// The tag setup lying under the phone, a key of the catalogue's `rigs`.
    let rig: String
    /// The assets to capture, or `nil` for every shot the catalogue gives the rig.
    let assets: Set<String>?
    /// The UID the run may change irreversibly, as uppercase hex without
    /// separators. An irreversible shot refuses to start without it, and refuses
    /// any tag whose UID differs.
    let sacrificeUID: String?
    /// Set for a run that retakes the shots showing iOS's own UI (the NFC
    /// sheet), which follow the phone's language rather than the app's. Such a
    /// run refuses to start unless the phone is set to `locale`.
    let requiresSystemLanguage: Bool

    /// The phone's own language, as `en-AU` or `zh-Hans-CN`. The test runner
    /// is launched without the app's `-AppleLanguages`, so this is the setting
    /// in iOS Settings, which is what the NFC sheet is drawn in.
    static var systemLanguage: String {
        Locale.preferredLanguages.first ?? "unknown"
    }

    /// Whether the phone is set to the run's language.
    var systemLanguageMatches: Bool {
        let system = Self.systemLanguage
        return system == appLanguage || system.hasPrefix(appLanguage + "-")
    }

    /// The phone's own appearance, `dark` or `light`. The app always draws
    /// dark, but the NFC sheet iOS draws over it follows this, and on
    /// Automatic it turns light at sunrise.
    static var systemAppearance: String {
        UIScreen.main.traitCollection.userInterfaceStyle == .dark ? "dark" : "light"
    }

    static func fromEnvironment() -> DocsCaptureConfig {
        let env = ProcessInfo.processInfo.environment
        let assets = env["HEXNFC_DOCS_ASSETS"].map {
            Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }
        return DocsCaptureConfig(
            enabled: env["HEXNFC_DOCS_CAPTURE"] == "1",
            locale: env["HEXNFC_DOCS_LOCALE"] ?? "en",
            rig: env["HEXNFC_DOCS_RIG"] ?? "ntag213",
            assets: assets?.isEmpty == true ? nil : assets,
            sacrificeUID: env["HEXNFC_DOCS_SACRIFICE_UID"]
                .map { $0.uppercased().filter(\.isHexDigit) }
                .flatMap { $0.isEmpty ? nil : $0 },
            requiresSystemLanguage: env["HEXNFC_DOCS_REQUIRE_SYSTEM_LANGUAGE"] == "1"
        )
    }

    /// The language the app runs in. The catalogue calls Simplified Chinese
    /// `zh-Hans`; the docs call it `zh`.
    var appLanguage: String {
        switch locale {
        case "zh": "zh-Hans"
        default: locale
        }
    }

    /// The region, which decides number and date formats on screen. Arabic
    /// takes Egypt's: Gregorian dates with the month names most Arabic readers
    /// know, and Arabic-Indic digits. Saudi Arabia's region shows Hijri dates,
    /// which readers elsewhere do not use day to day.
    var appLocale: String {
        switch locale {
        case "en": "en_AU"
        case "zh": "zh_CN"
        case "ar": "ar_EG"
        case "es": "es_ES"
        case "ja": "ja_JP"
        case "fr": "fr_FR"
        case "pt-BR": "pt_BR"
        default: locale
        }
    }
}

/// The capture catalogue, `docs-capture-catalogue.json`: which tag setup each
/// shot needs, how far it changes the tag, and where it falls in the run. The
/// host script reads the same file to plan runs and to tell the operator which
/// tag to put under the phone.
struct DocsCatalogue: Decodable {
    struct Rig: Decodable {
        let chip: String?
        let description: String
        let requiresSacrificeUID: Bool?
        /// `text-record`: write one Text record before the first shot, so
        /// nothing an earlier run left on the tag can bring up iOS's
        /// background reading.
        let prepare: String?
    }

    struct Shot: Decodable {
        let rig: String
        let tier: Tier
        let order: Int
    }

    /// How far a shot's scenario changes the tag. A run sorts by tier first, so
    /// nothing that rewrites, protects or burns a tag runs before a shot that
    /// needs it untouched.
    enum Tier: String, Decodable, Comparable {
        case readOnly = "read-only"
        case rewritesTag = "rewrites-tag"
        case protectsTag = "protects-tag"
        case irreversible

        private var rank: Int {
            switch self {
            case .readOnly: 0
            case .rewritesTag: 1
            case .protectsTag: 2
            case .irreversible: 3
            }
        }

        static func < (lhs: Tier, rhs: Tier) -> Bool {
            lhs.rank < rhs.rank
        }
    }

    let rigs: [String: Rig]
    let shots: [String: Shot]

    static func load() throws -> DocsCatalogue {
        let bundle = Bundle(for: DocsCaptureTests.self)
        guard let url = bundle.url(forResource: "docs-capture-catalogue", withExtension: "json") else {
            throw DocsCaptureError("docs-capture-catalogue.json is not in the UI test bundle")
        }
        return try JSONDecoder().decode(DocsCatalogue.self, from: Data(contentsOf: url))
    }

    /// The rig's shots in run order: tier, then the catalogue's order.
    func runOrder(rig: String, only assets: Set<String>?) -> [(asset: String, shot: Shot)] {
        shots
            .filter { $0.value.rig == rig && (assets?.contains($0.key) ?? true) }
            .map { (asset: $0.key, shot: $0.value) }
            .sorted { ($0.shot.tier, $0.shot.order, $0.asset) < ($1.shot.tier, $1.shot.order, $1.asset) }
    }
}

struct DocsCaptureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) {
        self.description = description
    }
}

/// Drives the app into the states the documentation shows and saves a
/// screenshot of each, with the frames `scripts/docs-screenshots` crops it by.
///
/// Scenarios find controls through `label(_:)`, which looks the English
/// catalogue key up in the run's language, so one scenario serves every
/// locale. Helpers throw rather than assert, so one shot that cannot be
/// reached is reported and the run moves on to the next.
@MainActor
final class DocsCapture {
    let app = XCUIApplication()
    let config: DocsCaptureConfig
    /// The UID of the tag under the phone, as uppercase hex without separators,
    /// from the identify that opens every run. Typed back at UID confirmations.
    var tagUID: String?
    private let strings: [String: String]
    private var shotsTaken: [String] = []

    init(config: DocsCaptureConfig) throws {
        self.config = config
        strings = try DocsCapture.loadStrings(locale: config.locale)
    }

    /// `docs-capture-strings.json` is generated by the host script from
    /// `Localizable.xcstrings` before every build and is not committed. English
    /// runs work without it; every other language needs it.
    private static func loadStrings(locale: String) throws -> [String: String] {
        let bundle = Bundle(for: DocsCaptureTests.self)
        guard let url = bundle.url(forResource: "docs-capture-strings", withExtension: "json") else {
            if locale == "en" {
                return [:]
            }
            throw DocsCaptureError(
                "docs-capture-strings.json is missing: run scripts/docs-screenshots, which generates it"
            )
        }
        let file = try JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: url))
        guard let table = file[locale] else {
            if locale == "en" {
                return [:]
            }
            throw DocsCaptureError("docs-capture-strings.json has no \(locale) table")
        }
        return table
    }

    // MARK: Strings

    /// The on-screen text for an English catalogue key in this run's language.
    func label(_ key: String) -> String {
        strings[key] ?? key
    }

    /// A catalogue key with format arguments, such as `"%lld of %lld"`.
    func label(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: label(key), locale: Locale(identifier: config.appLocale), arguments: arguments)
    }

    /// The fixed text a format key opens with in this run's language, up to
    /// its first argument: `"Identified: "` for `"Identified: %@ · %@"`, or
    /// `"識別しました: "` in Japanese. For finding a line whose arguments the
    /// scenario cannot know in advance.
    func labelPrefix(_ key: String) -> String {
        let value = label(key)
        let prefix = value.range(of: "%").map { String(value[..<$0.lowerBound]) } ?? value
        return prefix.isEmpty ? value : prefix
    }

    // MARK: Launching

    /// The rig with no real tag at all: the app's own simulated session, for
    /// the one state none of the tags on hand can produce.
    var usesSimulatedNFC: Bool {
        config.rig == "mock"
    }

    /// Start the app afresh in the run's language, on its home screen.
    ///
    /// `--noReviewPrompt` because a capture writes to real tags and sits on
    /// Home: the review card would otherwise rise into screenshots, and count
    /// the run against the owner's own prompt on their phone.
    func launchHome() throws {
        app.launchArguments = [
            "-AppleLanguages", "(\(config.appLanguage))",
            "-AppleLocale", config.appLocale,
            "--noReviewPrompt",
        ] + (usesSimulatedNFC ? ["--useSimulatedNFC"] : [])
        app.launch()
        try waitFor(tile("Scan"), timeout: 15)
        settle(1)
    }

    // MARK: Finding

    //
    // Every lookup by label is a predicate, never a subscript: XCUITest refuses
    // a subscript string over 128 characters with an exception that ends the
    // whole run, and the app's footnotes are longer than that.

    /// A button by its catalogue key. Home's four tiles are left out: they stay
    /// in the tree under every sheet, and "Advanced" is also the Protection
    /// card's disclosure row. Reach a tile with `tile(_:)`.
    func button(_ key: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "label == %@ AND NOT (identifier BEGINSWITH 'home.tile.')",
            label(key)
        ))
        .firstMatch
    }

    /// One of the home screen's four tiles: Scan, Build, Library or Advanced.
    func tile(_ key: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home.tile.' AND label == %@", label(key)))
            .firstMatch
    }

    func text(_ key: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@", label(key))).firstMatch
    }

    /// A switch by its catalogue key.
    func toggle(_ key: String) -> XCUIElement {
        app.switches.matching(NSPredicate(format: "label == %@", label(key))).firstMatch
    }

    /// An element by accessibility identifier, whatever its type.
    func identified(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The first element of a type whose label contains `fragment`. For labels
    /// that combine several strings (a preset row's name, chip and bytes), with
    /// `label` or `labelPrefix` supplying the fragment, and for text the app
    /// draws without the catalogue (the legal documents).
    func containing(_ fragment: String, type: XCUIElement.ElementType = .any) -> XCUIElement {
        app.descendants(matching: type)
            .matching(NSPredicate(format: "label CONTAINS %@", fragment))
            .firstMatch
    }

    /// Elements of a type that start below `reference`, top to bottom. For rows
    /// whose labels vary with the tag, such as the Advanced console's presets
    /// after an identify.
    func elements(_ type: XCUIElement.ElementType, below reference: XCUIElement) -> [XCUIElement] {
        // Reading any property of an element that is not there is a failure
        // XCUITest raises rather than throws, and it ends the whole run.
        guard reference.exists else { return [] }
        let floor = reference.frame.maxY
        return app.descendants(matching: type).allElementsBoundByIndex
            .filter { $0.exists && $0.frame.minY >= floor && $0.frame.height > 0 }
            .sorted { $0.frame.minY < $1.frame.minY }
    }

    /// An element whose accessibility label is `labelKey` and whose value is
    /// `valueKey`, both looked up. The Advanced console's status chip is one.
    func valued(_ labelKey: String, _ valueKey: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ AND value == %@", label(labelKey), label(valueKey)))
            .firstMatch
    }

    /// A text field by its caption key. A multi-line field is a text view to
    /// XCUITest, so one query matches either, whichever the sheet has drawn.
    /// A field with only a prompt reports it as its label in English but as
    /// `placeholderValue` alone in Japanese, so either one matches.
    func field(_ key: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "(elementType == %d OR elementType == %d) AND (label == %@ OR placeholderValue == %@)",
            XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue,
            label(key), label(key)
        )).firstMatch
    }

    /// The lowest static text that starts below `reference`. For a crop that
    /// should take in a footnote whose wording the scenario does not name.
    func lastText(below reference: XCUIElement) throws -> XCUIElement {
        guard let last = elements(.staticText, below: reference).last(where: { $0.isHittable }) else {
            throw DocsCaptureError("no text below \(reference)")
        }
        return last
    }

    // MARK: Acting

    /// Whether the run's language reads right to left, which mirrors every
    /// leading and trailing edge.
    var rightToLeft: Bool {
        config.locale == "ar"
    }

    /// Reveal a list row's leading swipe actions (Pin, Write) with a plain
    /// swipe away from the leading edge: rightwards in English, leftwards in
    /// Arabic.
    func swipeLeading(_ row: XCUIElement) {
        rightToLeft ? row.swipeLeft() : row.swipeRight()
    }

    /// Reveal a list row's trailing swipe actions (Delete).
    func swipeTrailing(_ row: XCUIElement) {
        rightToLeft ? row.swipeRight() : row.swipeLeft()
    }

    /// Set a switch on or off, and check it took. A tap at a SwiftUI toggle's
    /// centre lands on its label, which does not flip it, so the tap goes to the
    /// trailing edge, where the switch is drawn: the right in English, the left
    /// in Arabic.
    func flip(_ toggle: XCUIElement, on: Bool) throws {
        try waitFor(toggle)
        try reveal(toggle)
        let want = on ? "1" : "0"
        for _ in 0 ..< 2 {
            if (toggle.value as? String) == want {
                return
            }
            let edge: CGFloat = rightToLeft ? 0.08 : 0.92
            toggle.coordinate(withNormalizedOffset: CGVector(dx: edge, dy: 0.5)).tap()
            settle(0.8)
        }
        guard (toggle.value as? String) == want else {
            throw DocsCaptureError("\(toggle) would not turn \(on ? "on" : "off")")
        }
    }

    /// Type into a field, after tapping it to give it focus.
    func type(_ text: String, into target: XCUIElement) throws {
        try tap(target)
        target.typeText(text)
    }

    /// Replace a field's contents. Deletes rather than selecting all, because
    /// select-all needs a press-and-hold, and no synthesised press-and-drag runs
    /// on the owner's phone.
    func replace(_ target: XCUIElement, with text: String) throws {
        try tap(target)
        let current = (target.value as? String) ?? ""
        if !current.isEmpty {
            target.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        }
        target.typeText(text)
    }

    /// Put the keyboard away, so it neither covers the subject nor ends up in
    /// the picture. The keyboard's own return key first; for a keyboard without
    /// one, a tap on the navigation bar's title, which is not a control.
    func dismissKeyboard() {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return }
        let keys = keyboard.buttons.matching(NSPredicate(format: "label IN %@", ["return", "Return", "done", "Done"]))
        if keys.firstMatch.exists {
            keys.firstMatch.tap()
        }
        if keyboard.exists, app.navigationBars.firstMatch.exists {
            app.navigationBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        settle(0.8)
    }

    /// Scroll until all of `target` is on screen and can take a tap, with plain
    /// swipes. Hittable alone is not enough: a button whose middle is on screen
    /// takes a tap with its bottom cut off by the screen edge, and a crop that
    /// ends on it then cuts through it (French, 2026-10-26).
    func reveal(_ target: XCUIElement, swipes: Int = 6) throws {
        for _ in 0 ..< swipes {
            if wholly(target) {
                return
            }
            app.swipeUp()
            settle(0.6)
        }
        guard wholly(target) else { throw DocsCaptureError("could not scroll all of \(target) onto the screen") }
    }

    /// Whether all of `element` is on screen and takes a tap, so a crop may end
    /// on its edge without cutting it.
    func wholly(_ element: XCUIElement) -> Bool {
        element.exists && element.isHittable && app.frame.insetBy(dx: -1, dy: -1).contains(element.frame)
    }

    /// Poll for a state that only lasts a moment. `waitForExistence` waits for
    /// the app to go idle between checks, which can outlast a one-second state.
    ///
    /// The poll runs inside `HumanPace`, which switches XCUITest's wait-for-idle
    /// off: the success states animate for their whole second, and an idle wait
    /// before each check outlasted them.
    func catchTransient(_ target: XCUIElement, timeout: TimeInterval = 20) throws {
        var caught = false
        // No assertions inside the block: see `HumanPace.restore()`.
        HumanPace.run {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if target.exists {
                    caught = true
                    return
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        guard caught else { throw DocsCaptureError("never caught: \(target)") }
    }

    /// Tap once the target exists and can take a tap. A sheet arrives with an
    /// animation, and a tap at an element that is still moving lands on
    /// whatever is under it by then.
    func tap(_ target: XCUIElement, timeout: TimeInterval = 10) throws {
        try waitFor(target, timeout: timeout)
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: target)
        guard XCTWaiter().wait(for: [hittable], timeout: timeout) == .completed else {
            throw DocsCaptureError("never hittable: \(target)")
        }
        settle(0.5)
        target.tap()
    }

    func waitFor(_ target: XCUIElement, timeout: TimeInterval = 10) throws {
        guard target.waitForExistence(timeout: timeout) else {
            throw DocsCaptureError("never appeared: \(target)")
        }
    }

    /// Wait for the state an NFC tap ends in, then for the iOS sheet to close,
    /// so the next tap or swipe does not land while the sheet is up.
    func waitForNFC(_ target: XCUIElement, timeout: TimeInterval = 40) throws {
        try waitFor(target, timeout: timeout)
        afterNFC()
    }

    func waitUntilGone(_ target: XCUIElement, timeout: TimeInterval = 10) throws {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: target)
        guard XCTWaiter().wait(for: [gone], timeout: timeout) == .completed else {
            throw DocsCaptureError("never went away: \(target)")
        }
    }

    /// Let the iOS NFC sheet finish closing. It stays up for about 2.7 s after
    /// the app ends a session, and reading an element's properties while it is
    /// on screen sends XCUITest looking for an alert that is not there, which
    /// ends the run.
    func afterNFC() {
        settle(3)
    }

    /// Let an animation finish. The app's shaders and haptic moments run for up
    /// to about a second after a state change.
    func settle(_ seconds: TimeInterval) {
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "settle")], timeout: seconds)
    }

    // MARK: Shooting

    /// Where a crop band starts.
    enum Top {
        /// Just below the status bar: the whole screen from the top.
        case statusBar
        /// The element's top edge; the crop line moves up into the gap above it.
        case top(XCUIElement)
        /// Below the element; the crop line moves down into the gap after it.
        case below(XCUIElement)
        /// The highest top edge of everything carrying `identifier`. SwiftUI
        /// copies an identifier set on a container onto each child, so the first
        /// match is only the first child.
        case topOfAll(String)
    }

    /// Where a crop band ends.
    enum Bottom {
        /// The foot of the screen.
        case screen
        /// The element's bottom edge; the crop line moves down into the gap below it.
        case bottom(XCUIElement)
        /// Above the element; the crop line moves up into the gap before it.
        case above(XCUIElement)
        /// The lowest bottom edge of everything carrying `identifier`.
        case bottomOfAll(String)
    }

    /// Save the screen as `asset` with the band the host script crops it to.
    /// The script never cuts through a control: it moves each edge, in the
    /// direction the case names, to the middle of the nearest gap between
    /// controls, and never above the status bar.
    func shot(
        _ asset: String,
        from top: Top = .statusBar,
        to bottom: Bottom = .screen,
        settle seconds: TimeInterval = 1.5
    ) throws {
        settle(seconds)
        let topEdge: [String: Any]
        switch top {
        case .statusBar:
            topEdge = ["edge": "statusBar"]
        case .top(let element):
            try waitFor(element, timeout: 5)
            topEdge = ["edge": "element", "y": Double(element.frame.minY), "search": "up"]
        case .below(let element):
            try waitFor(element, timeout: 5)
            topEdge = ["edge": "element", "y": Double(element.frame.maxY), "search": "down"]
        case .topOfAll(let identifier):
            let top = try frames(identifier).map(\.minY).min() ?? 0
            topEdge = ["edge": "element", "y": Double(top), "search": "up"]
        }
        let bottomEdge: [String: Any]
        switch bottom {
        case .screen:
            bottomEdge = ["edge": "screen"]
        case .bottom(let element):
            try waitFor(element, timeout: 5)
            bottomEdge = ["edge": "element", "y": Double(element.frame.maxY), "search": "down"]
        case .above(let element):
            try waitFor(element, timeout: 5)
            bottomEdge = ["edge": "element", "y": Double(element.frame.minY), "search": "up"]
        case .bottomOfAll(let identifier):
            let bottom = try frames(identifier).map(\.maxY).max() ?? 0
            bottomEdge = ["edge": "element", "y": Double(bottom), "search": "down"]
        }
        try waitOutNotificationBanner(asset)
        let screenshot = XCUIScreen.main.screenshot()
        let image = screenshot.image
        let meta: [String: Any] = [
            "asset": asset,
            "locale": config.locale,
            "rig": config.rig,
            "scale": Double(image.scale),
            "screen": ["width": Double(image.size.width), "height": Double(image.size.height)],
            "statusBar": statusBarHeight(screenHeight: Double(image.size.height)),
            "crop": ["top": topEdge, "bottom": bottomEdge],
            "simulatedNFC": usesSimulatedNFC,
            "device": DocsCapture.machineIdentifier(),
            "ios": UIDevice.current.systemVersion,
            "systemLanguage": DocsCaptureConfig.systemLanguage,
            "systemAppearance": DocsCaptureConfig.systemAppearance,
            "capturedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        attach(screenshot.pngRepresentation, name: "docs-capture__\(config.locale)__\(asset)", type: "public.png")
        try attach(JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]),
                   name: "docs-capture__\(config.locale)__\(asset).json", type: "public.json")
        shotsTaken.append(asset)
    }

    /// Hold the shot while a notification banner is on screen, and refuse it if
    /// the banner stays. A banner carries someone's name and message, and a
    /// Teams message landed in a Chinese capture (2026-10-27). Turning on Do Not
    /// Disturb before a run is the real fix; this is the backstop. The banner's
    /// identifier is the one SpringBoard has used since iOS 16, not yet seen to
    /// match on iOS 27, so a run still has its captures checked by eye.
    private func waitOutNotificationBanner(_ asset: String) throws {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let banner = springboard.otherElements.matching(identifier: "NotificationShortLookView").firstMatch
        let deadline = Date().addingTimeInterval(12)
        while banner.exists, Date() < deadline {
            settle(1)
        }
        if banner.exists {
            throw DocsCaptureError("a notification banner covered the screen for \(asset); turn on Do Not Disturb")
        }
    }

    /// The frames of everything carrying `identifier`, in points.
    private func frames(_ identifier: String) throws -> [CGRect] {
        try waitFor(identified(identifier), timeout: 5)
        let found = app.descendants(matching: .any).matching(identifier: identifier).allElementsBoundByIndex
            .filter { $0.exists && $0.frame.height > 0 }
            .map(\.frame)
        guard !found.isEmpty else { throw DocsCaptureError("nothing on screen carries \(identifier)") }
        return found
    }

    /// The screen as it stood when a scenario gave up, with the accessibility
    /// tree, so a failed shot can be diagnosed from the result bundle alone.
    func attachFailure(_ asset: String, _ error: Error) {
        attach(XCUIScreen.main.screenshot().pngRepresentation,
               name: "docs-capture-failure__\(config.locale)__\(asset)", type: "public.png")
        let text = "\(error)\n\n\(app.debugDescription)"
        attach(Data(text.utf8), name: "docs-capture-failure__\(config.locale)__\(asset).txt", type: "public.plain-text")
    }

    func attachSummary(_ summary: [String: Any]) throws {
        try attach(JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]),
                   name: "docs-capture-summary__\(config.locale)__\(config.rig).json", type: "public.json")
    }

    func took(_ asset: String) -> Bool {
        shotsTaken.contains(asset)
    }

    private func attach(_ data: Data, name: String, type: String) {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: type)
        attachment.name = name
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: name) { $0.add(attachment) }
    }

    /// The status bar's height in points: SpringBoard's own status bar when the
    /// accessibility tree exposes it, otherwise the safe-area inset for the
    /// screen height, which is what the status bar occupies on every iPhone with
    /// a Dynamic Island or a notch.
    private func statusBarHeight(screenHeight: Double) -> Double {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let bar = springboard.statusBars.firstMatch
        if bar.exists, bar.frame.height > 0, bar.frame.height < 80 {
            return Double(bar.frame.maxY)
        }
        switch screenHeight {
        case 956, 874: return 62
        case 932, 852: return 59
        case 926, 844: return 47
        default: return 62
        }
    }

    private static func machineIdentifier() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
