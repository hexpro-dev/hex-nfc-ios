#if DEBUG
import Foundation
import HexNFCKit
import Observation

/// Tracks which chips have passed the full non-destructive suite *cleanly* in the
/// current app run. The gated irreversible-ops flow stays disabled for a chip
/// until it appears here — the "confirm all other functionality first" precondition
/// the user asked for. In-memory only (per app run), keyed by exact `ChipID`
/// because irreversible operations (lock pages) differ per variant.
@MainActor
@Observable
public final class CleanPassRegistry {
    private var passes: [ChipID: Data] = [:]

    public init() {}

    /// Record a verified clean pass — suite green, cleanup green, tag unprotected.
    public func record(chipID: ChipID, uid: Data) {
        passes[chipID] = uid
    }

    public func hasCleanPass(for chipID: ChipID) -> Bool {
        passes[chipID] != nil
    }

    /// The UID that produced the clean pass (irreversible ops require the same tag).
    public func uid(for chipID: ChipID) -> Data? {
        passes[chipID]
    }
}
#endif
