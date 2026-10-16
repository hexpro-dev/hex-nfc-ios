import Foundation
import HexNFCRecords

/// Module marker. SwiftData persistence stack for `Preset`, `ScanHistoryEntry`,
/// and `CommandPreset`. iCloud private DB mirroring is one configuration flag
/// behind the Settings → iCloud Sync toggle (default off).
public enum HexNFCStorage {
    public static let moduleName = "HexNFCStorage"
}
