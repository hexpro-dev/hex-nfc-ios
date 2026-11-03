import XCTest

extension DocsShots {
    /// The home screen, Settings and the legal documents. None of these touches
    /// the tag.
    @MainActor
    static let home: [String: DocsScenario] = [
        "home--four-tiles.png": { c in
            try c.launchHome()
            try c.shot("home--four-tiles.png", to: .bottom(c.identified("home.grid")))
        },
        "home--development-costs-card.png": { c in
            try c.launchHome()
            let breakdown = c.button("View Breakdown")
            try c.reveal(breakdown)
            // The figure comes from the network once per launch; give it time.
            c.settle(3)
            try c.shot("home--development-costs-card.png",
                       from: .top(c.text("Development Costs Recovered")), to: .bottom(breakdown))
        },
        "home--promo-card.png": { c in
            try c.launchHome()
            let promo = c.identified("home.promo.creative")
            for _ in 0 ..< 4 {
                c.app.swipeUp()
                c.settle(0.5)
            }
            // Nothing renders until the server has answered and the image has
            // decoded, and nothing renders at all if no creative is configured.
            guard promo.waitForExistence(timeout: 25) else {
                throw DocsCaptureError(
                    "no promo creative appeared within 25 s; is one configured for pro.hex.nfc home_bottom?"
                )
            }
            try c.reveal(promo)
            c.settle(2)
            try c.shot("home--promo-card.png", from: .top(c.text("More from Hex Pro")), to: .bottom(promo))
        },
        "settings--default.png": { c in
            try openSettings(c)
            // Feel and Sync at their defaults, ending under Sync's footnote.
            // About is left out because its Version row names a version, which
            // the guide never does (conventions section 7).
            let footer = c
                .text(
                    "Mirror your presets and history to your iCloud account. Off by default. Takes effect the next time you open the app."
                )
            try c.waitFor(footer)
            try c.shot("settings--default.png", to: .bottom(footer))
        },
        "settings--sync-section.png": { c in
            try openSettings(c)
            let footer = c
                .text(
                    "Mirror your presets and history to your iCloud account. Off by default. Takes effect the next time you open the app."
                )
            try c.reveal(footer)
            try c.shot("settings--sync-section.png", from: .top(c.text("Sync")), to: .bottom(footer))
        },
        "settings--system-reduce-motion.png": { c in
            // The footnote follows iOS's own Reduce Motion, which a test cannot
            // switch; the rig asks the operator to turn it on.
            guard UIAccessibility.isReduceMotionEnabled else {
                throw DocsCaptureError(
                    "iOS Reduce Motion is off: turn on Settings > Accessibility > Motion > Reduce Motion"
                )
            }
            try openSettings(c)
            let note = c.text("System Reduce Motion is on: animations are already minimised.")
            try c.shot("settings--system-reduce-motion.png", from: .top(c.text("Feel")), to: .bottom(note))
        },
        "legal-terms--top.png": { c in
            try openSettings(c)
            let terms = c.button("Terms & Conditions")
            try c.reveal(terms)
            try c.tap(terms)
            // The legal text is drawn without the catalogue, so its masthead
            // reads the same in every language.
            let publisher = c.containing("Ars Vitae Pty Ltd", type: .staticText)
            try c.waitFor(publisher, timeout: 10)
            let firstSection = c.containing("1. Who we are", type: .staticText)
            let bottom: DocsCapture.Bottom = firstSection.exists ? .bottom(firstSection) : .bottom(publisher)
            try c.shot("legal-terms--top.png", to: bottom)
        },
    ]

    @MainActor
    static func openSettings(_ c: DocsCapture) throws {
        try c.launchHome()
        try c.tap(c.button("Settings"))
        try c.waitFor(c.text("Feel"), timeout: 10)
        c.settle(0.5)
    }
}
