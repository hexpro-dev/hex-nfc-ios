@testable import HexNFCApp
import HexNFCShaders
import XCTest

/// Phase 5 lock-in tests:
///  * Every named `HexHapticPattern` has a real `.ahap` resource in the
///    `HexNFCShaders` bundle — the placeholder is gone.
///  * `AppSettings` round-trips through `UserDefaults` via `save()` / `load()`,
///    with sensible defaults when nothing is persisted.
final class Phase5Tests: XCTestCase {
    func test_everyHapticPattern_hasAhapResourceInBundle() {
        let bundle = HexNFCShaders.resourceBundle
        for pattern in HexHapticPattern.allCases {
            let url = bundle.url(forResource: pattern.fileName, withExtension: "ahap")
            XCTAssertNotNil(
                url,
                "Missing .ahap for \(pattern.rawValue) — Phase 5 deliverable."
            )
        }
    }

    func test_noPlaceholderAhapInBundle() {
        // The Phase 0 stub must be gone.
        let stale = HexNFCShaders.resourceBundle.url(forResource: "placeholder", withExtension: "ahap")
        XCTAssertNil(stale, "placeholder.ahap should be removed in Phase 5.")
    }

    // MARK: - AppSettings persistence

    private func freshDefaults() throws -> UserDefaults {
        let suiteName = "pro.hex.nfc.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    func test_appSettings_load_returnsDefaults_whenStoreEmpty() throws {
        let defaults = try freshDefaults()
        let loaded = AppSettings.load(from: defaults)
        XCTAssertTrue(loaded.hapticsEnabled, "Haptics default on")
        XCTAssertFalse(loaded.iCloudSyncEnabled, "iCloud default off")
        XCTAssertFalse(loaded.reduceMotionOverride, "Reduce-Motion default off")
    }

    func test_appSettings_save_thenLoad_roundTrips() throws {
        let defaults = try freshDefaults()
        var settings = AppSettings.load(from: defaults)
        settings.hapticsEnabled = false
        settings.iCloudSyncEnabled = true
        settings.reduceMotionOverride = true
        settings.save(to: defaults)
        let reloaded = AppSettings.load(from: defaults)
        XCTAssertEqual(settings, reloaded)
    }

    func test_appSettings_disabledHaptics_persistAcrossLoad() throws {
        let defaults = try freshDefaults()
        AppSettings(hapticsEnabled: false).save(to: defaults)
        XCTAssertFalse(AppSettings.load(from: defaults).hapticsEnabled)
    }

    /// The retired "compatibility mode" key is cleared on the next save, so a
    /// user who toggled the dead switch doesn't carry its value around forever.
    /// It was persisted but never read by anything: no session consulted it and
    /// no timeout changed, so the switch only ever looked like it did something.
    func test_appSettings_save_clearsTheRetiredCompatibilityKey() throws {
        let defaults = try freshDefaults()
        defaults.set(true, forKey: "pro.hex.nfc.settings.compatibility")

        AppSettings.load(from: defaults).save(to: defaults)

        XCTAssertNil(defaults.object(forKey: "pro.hex.nfc.settings.compatibility"))
    }
}
