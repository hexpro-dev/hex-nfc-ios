import XCTest

/// Captures the documentation's screenshots on a real iPhone lying on a real
/// tag. Skipped unless `scripts/docs-screenshots` started the run, which sets
/// the language, the tag setup ("rig") and the shots to take; see
/// `docs/internal/docs-screenshots.md`.
///
/// Every shot the catalogue gives the rig runs in tier order, so nothing that
/// rewrites, protects or burns the tag runs before a shot that needs it as it
/// was. A shot that cannot be reached is recorded with a screenshot and the
/// accessibility tree, the app is relaunched, and the run carries on.
final class DocsCaptureTests: XCTestCase {
    @MainActor
    func test_captureDocsScreenshots() throws {
        let config = DocsCaptureConfig.fromEnvironment()
        try XCTSkipUnless(config.enabled, "Run through scripts/docs-screenshots, which sets HEXNFC_DOCS_CAPTURE")

        let catalogue = try DocsCatalogue.load()
        let scenarios = DocsShots.scenarios
        let unwritten = catalogue.shots.keys.filter { scenarios[$0] == nil }.sorted()
        let uncatalogued = scenarios.keys.filter { catalogue.shots[$0] == nil }.sorted()
        guard let rig = catalogue.rigs[config.rig] else {
            throw DocsCaptureError("no rig named \(config.rig) in the catalogue")
        }

        let capture = try DocsCapture(config: config)
        let order = catalogue.runOrder(rig: config.rig, only: config.assets)
        var failed: [[String: String]] = []
        var verifiedUID: String?

        if config.requiresSystemLanguage,
           !config.systemLanguageMatches || DocsCaptureConfig.systemAppearance != "dark"
        {
            let reason = "the phone is set to \(DocsCaptureConfig.systemLanguage) in \(DocsCaptureConfig.systemAppearance) "
                + "appearance; system UI is retaken with the phone in \(config.appLanguage) (Settings > General > "
                + "Language & Region) and Dark (Settings > Display & Brightness, Automatic off)"
            try capture.attachSummary(summary(config, verifiedUID: nil, order: order, capture: capture,
                                              failed: [["asset": "system-language", "reason": reason]],
                                              unwritten: unwritten, uncatalogued: uncatalogued))
            throw DocsCaptureError(reason)
        }

        if let chip = rig.chip, !order.isEmpty {
            do {
                // Two attempts, as a shot gets: one dropped read on the resting
                // tag should not cost the whole run.
                for attempt in 1 ... 2 {
                    do {
                        verifiedUID = try DocsShots.verifyTag(capture, chip: chip)
                        capture.tagUID = verifiedUID
                        if rig.prepare == "text-record" {
                            try DocsShots.prepareTag(capture)
                        }
                        break
                    } catch where attempt == 1 {
                        verifiedUID = nil
                    }
                }
            } catch {
                capture.attachFailure("rig-check", error)
                try capture.attachSummary(summary(config, verifiedUID: nil, order: order, capture: capture,
                                                  failed: [["asset": "rig-check", "reason": "\(error)"]],
                                                  unwritten: unwritten, uncatalogued: uncatalogued))
                throw error
            }
        }

        for (asset, shot) in order {
            guard let reach = scenarios[asset] else {
                failed.append(["asset": asset, "reason": "no scenario is written for this shot"])
                continue
            }
            // A rig whose every shot changes the card (the DESFire throwaway)
            // runs only on the card named, whatever the shot's tier.
            if rig.requiresSacrificeUID == true, shot.tier != .irreversible {
                guard let allowed = config.sacrificeUID, verifiedUID == allowed else {
                    failed.append([
                        "asset": asset,
                        "reason": "the tag under the phone is \(verifiedUID ?? "unread"), not \(config.sacrificeUID ?? "the --sacrifice-uid tag")",
                    ])
                    continue
                }
            }
            if shot.tier == .irreversible {
                guard rig.requiresSacrificeUID == true, let allowed = config.sacrificeUID else {
                    failed.append([
                        "asset": asset,
                        "reason": "irreversible: needs a sacrificial rig and HEXNFC_DOCS_SACRIFICE_UID",
                    ])
                    continue
                }
                guard verifiedUID == allowed else {
                    failed.append([
                        "asset": asset,
                        "reason": "irreversible: the tag under the phone is \(verifiedUID ?? "unread"), not \(allowed)",
                    ])
                    continue
                }
            }
            // A shot that fails is tried once more from a fresh launch: an NFC
            // read on a resting tag occasionally drops, and one dropped read
            // should not cost the shot. An irreversible shot gets one attempt.
            let attempts = shot.tier == .irreversible ? 1 : 2
            for attempt in 1 ... attempts {
                var error: Error?
                XCTContext.runActivity(named: attempt == 1 ? asset : "\(asset) (retry)") { _ in
                    do {
                        try reach(capture)
                        if !capture.took(asset) {
                            throw DocsCaptureError("the scenario finished without taking \(asset)")
                        }
                    } catch let caught {
                        error = caught
                    }
                }
                guard let error else { break }
                if attempt == attempts {
                    failed.append(["asset": asset, "reason": "\(error)"])
                    capture.attachFailure(asset, error)
                }
            }
        }

        try capture.attachSummary(summary(config, verifiedUID: verifiedUID, order: order, capture: capture,
                                          failed: failed, unwritten: unwritten, uncatalogued: uncatalogued))
        XCTAssertTrue(uncatalogued.isEmpty, "Scenarios with no catalogue entry: \(uncatalogued)")
        XCTAssertTrue(
            failed.isEmpty,
            failed.map { "\($0["asset"] ?? ""): \($0["reason"] ?? "")" }.joined(separator: "\n")
        )
    }

    @MainActor
    private func summary(
        _ config: DocsCaptureConfig,
        verifiedUID: String?,
        order: [(asset: String, shot: DocsCatalogue.Shot)],
        capture: DocsCapture,
        failed: [[String: String]],
        unwritten: [String],
        uncatalogued: [String]
    ) -> [String: Any] {
        [
            "locale": config.locale,
            "rig": config.rig,
            "tagUID": verifiedUID as Any? ?? NSNull(),
            "requested": order.map(\.asset),
            "captured": order.map(\.asset).filter { capture.took($0) },
            "failed": failed,
            "catalogueWithoutScenario": unwritten,
            "scenarioWithoutCatalogue": uncatalogued,
        ]
    }
}
