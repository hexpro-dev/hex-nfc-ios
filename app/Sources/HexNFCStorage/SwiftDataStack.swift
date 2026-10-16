import Foundation
import SwiftData

/// Owns the `ModelContainer` for the Phase 4 SwiftData store. Two modes:
///
/// - **On-disk** (`init(url:enableCloudKit:)`): the production path. iCloud
///   mirroring lives behind a flag — default off per the brand promise.
/// - **In-memory** (`init.inMemory`): the test path, also useful for
///   feature-flag previews and `--useSimulatedNFC` UI tests.
///
/// Migration policy: minor schema bumps add fields with sensible defaults;
/// major bumps land in a single VersionedSchema upgrade per release.
public final class SwiftDataStack: @unchecked Sendable {
    public let container: ModelContainer
    public let isInMemory: Bool

    public init(
        url: URL? = nil,
        enableCloudKit: Bool = false
    ) throws {
        let schema = Schema([
            Preset.self,
            HistoryEntry.self,
            SavedCommandPreset.self,
        ])
        let storeURL = url ?? SwiftDataStack.defaultStoreURL()
        let config = if enableCloudKit {
            // CloudKit private DB mirroring — gated by the Settings → iCloud
            // toggle. Default false. The container is named explicitly rather
            // than left to `.automatic`: automatic derives it from whichever
            // container the entitlement happens to list first, which makes a
            // future entitlement edit silently repoint everyone's data.
            ModelConfiguration(
                schema: schema,
                url: storeURL,
                cloudKitDatabase: .private(SwiftDataStack.cloudKitContainerID)
            )
        } else {
            ModelConfiguration(
                schema: schema,
                url: storeURL,
                cloudKitDatabase: .none
            )
        }
        container = try ModelContainer(for: schema, configurations: [config])
        isInMemory = false
    }

    /// In-memory store. Holds nothing across launches; used by tests and
    /// SwiftUI previews so the canvas doesn't pollute the user's library.
    public static func inMemory() throws -> SwiftDataStack {
        try SwiftDataStack(inMemory: true)
    }

    private init(inMemory: Bool) throws {
        let schema = Schema([
            Preset.self,
            HistoryEntry.self,
            SavedCommandPreset.self,
        ])
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        container = try ModelContainer(for: schema, configurations: [config])
        isInMemory = true
    }

    @MainActor
    public var context: ModelContext {
        container.mainContext
    }

    /// The CloudKit container backing iCloud sync. Must match the
    /// `com.apple.developer.icloud-container-identifiers` entitlement.
    public static let cloudKitContainerID = "iCloud.pro.hex.nfc"

    /// How far the store had to degrade before it opened.
    public enum Fallback: Sendable, Equatable {
        /// Opened exactly as asked.
        case none
        /// Sync was requested but the mirrored container would not open, so the
        /// store opened local-only. The library is intact; it just isn't syncing.
        case cloudKitUnavailable
        /// Even the on-disk store failed. Nothing written this launch survives
        /// it. Should be unreachable outside a full disk or a corrupt store.
        case storeUnavailable
    }

    /// Open the best store available, degrading one step at a time.
    ///
    /// The ordering is the whole point. A CloudKit failure (missing entitlement,
    /// no iCloud account, a container that isn't deployed) must cost the user
    /// their *sync*, never their *library* — so the second rung is the same
    /// on-disk store with mirroring switched off, and the in-memory store is a
    /// last resort rather than the immediate catch. This used to be
    /// `(try? cloudKit) ?? (try! inMemory())` at the call site, which quietly
    /// swapped a user's whole library for a scratch store the moment they
    /// turned sync on.
    public static func makeBestEffort(
        enableCloudKit: Bool,
        url: URL? = nil
    ) -> (stack: SwiftDataStack, fallback: Fallback) {
        if enableCloudKit {
            if let synced = try? SwiftDataStack(url: url, enableCloudKit: true) {
                return (synced, .none)
            }
            if let local = try? SwiftDataStack(url: url, enableCloudKit: false) {
                return (local, .cloudKitUnavailable)
            }
        } else if let local = try? SwiftDataStack(url: url, enableCloudKit: false) {
            return (local, .none)
        }
        // Nothing on disk would open. Better a working session than a crash on
        // launch, but the caller is expected to say so out loud. An in-memory
        // store failing too means the process cannot run at all.
        // swiftlint:disable:next force_try
        return (try! SwiftDataStack.inMemory(), .storeUnavailable)
    }

    /// `Application Support/HexNFC/store.sqlite` — keeps the store out of
    /// the user-facing Documents folder.
    private static func defaultStoreURL() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.temporaryDirectory
        let folder = base.appendingPathComponent("HexNFC", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("store.sqlite")
    }
}
