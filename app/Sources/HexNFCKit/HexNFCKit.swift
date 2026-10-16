import Foundation
import HexNFCRecords

/// Module marker. The NFC abstraction layer.
///
/// Production code wires `CoreNFCSession` (iOS-only, guarded with `#if os(iOS)`);
/// tests wire `SimulatedSession` from `HexNFCTagSim`. The `TagSession` and
/// `ConnectedTag` protocols are the load-bearing surface; nothing outside
/// this module is allowed to `import CoreNFC`.
public enum HexNFCKit {
    public static let moduleName = "HexNFCKit"
}
