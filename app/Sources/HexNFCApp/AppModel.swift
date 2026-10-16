import Foundation
import HexNFCKit
import HexNFCStorage
import Observation

/// Root model. One instance lives at the top of the SwiftUI environment;
/// every flow model is constructed from this.
///
/// The model intentionally holds *less* than a typical iOS root — sessions,
/// records, history are owned by per-flow models. This is the surface for
/// app-global state: which session factory to use, settings, the persistent
/// library, the connected tag (when one is held across screens).
@Observable
@MainActor
public final class AppModel {
    /// Factory used to construct `TagSession`s. Production wires
    /// `CoreNFCSessionFactory`; UI tests inject `SimulatedSessionFactory`
    /// from `HexNFCTagSim` and gate it on the `--useSimulatedNFC` launch arg.
    public let sessionFactory: TagSessionFactory

    /// Persistent presets + scan history. Lives behind a single repository
    /// on top of the `SwiftDataStack`. Phase 4 wires this in; earlier phases
    /// will see an in-memory stack.
    public let library: LibraryRepository

    public var settings: AppSettings

    /// How far the persistent store had to degrade at launch. Carried so
    /// Settings can admit that sync isn't running instead of showing a toggle
    /// that is on and doing nothing.
    public let storeFallback: SwiftDataStack.Fallback

    public init(
        sessionFactory: TagSessionFactory,
        library: LibraryRepository,
        settings: AppSettings = AppSettings(),
        storeFallback: SwiftDataStack.Fallback = .none
    ) {
        self.sessionFactory = sessionFactory
        self.library = library
        self.settings = settings
        self.storeFallback = storeFallback
    }
}

/// Lightweight settings container. Persisted via `UserDefaults`; missing keys
/// fall back to the documented defaults. Mutating-then-`save` is the supported
/// flow. Settings drive haptics and CloudKit gating, so the persistence path
/// must work from non-view code.
///
/// There is deliberately no `compatibilityMode`. One existed, was persisted, and
/// was never read by anything: no session consulted it, no timeout changed, and
/// its Settings row described behaviour ("single command per session, longer
/// timeouts, default on iPhone X / XS") that the app did not implement and never
/// defaulted on. A switch that does nothing is worse than an absent one, because
/// a user hitting a flaky tag will toggle it and believe they've tried something.
/// If per-device pacing is ever needed it belongs in `CoreNFCSession`, wired and
/// hardware-verified, and the row can come back then.
public struct AppSettings: Sendable, Equatable {
    public var hapticsEnabled: Bool
    public var iCloudSyncEnabled: Bool
    public var reduceMotionOverride: Bool

    public init(
        hapticsEnabled: Bool = true,
        iCloudSyncEnabled: Bool = false,
        reduceMotionOverride: Bool = false
    ) {
        self.hapticsEnabled = hapticsEnabled
        self.iCloudSyncEnabled = iCloudSyncEnabled
        self.reduceMotionOverride = reduceMotionOverride
    }

    private static let hapticsKey = "pro.hex.nfc.settings.haptics"
    private static let iCloudKey = "pro.hex.nfc.settings.iCloudSync"
    private static let reduceKey = "pro.hex.nfc.settings.reduceMotionOverride"
    /// Written by builds up to 1.0; removed with the dead toggle. Cleared on
    /// save so the key doesn't linger in a user's defaults forever.
    private static let retiredCompatKey = "pro.hex.nfc.settings.compatibility"

    public static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        AppSettings(
            hapticsEnabled: defaults.object(forKey: hapticsKey) as? Bool ?? true,
            iCloudSyncEnabled: defaults.bool(forKey: iCloudKey),
            reduceMotionOverride: defaults.bool(forKey: reduceKey)
        )
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(hapticsEnabled, forKey: Self.hapticsKey)
        defaults.set(iCloudSyncEnabled, forKey: Self.iCloudKey)
        defaults.set(reduceMotionOverride, forKey: Self.reduceKey)
        defaults.removeObject(forKey: Self.retiredCompatKey)
    }
}

/// Copy shown on the iOS NFC system sheet during a session.
///
/// It lives here rather than as a default-argument literal on each flow model
/// because it is *user-facing* text: the sheet is the most prominent thing on
/// screen during a tap, and it must go through the string catalogue like every
/// other string. It was a bare `String` literal on three `begin(alert:)`
/// defaults, so a Japanese-locale user (the whole audience for the transit
/// feature) read it in English while the translation sat in the bundle unused.
public enum NFCPrompt {
    public static var holdTag: String {
        String(localized: "Hold tag against the top of your iPhone")
    }
}
