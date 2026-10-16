@testable import HexNFC
import Testing

/// Host-app smoke tests.
///
/// Unit testing happens in the SPM package (`HexNFCKitTests`,
/// `HexNFCRecordsTests`, `HexNFCStorageTests`, `HexNFCAppTests`) — those run
/// without an iOS Simulator and cover the load-bearing logic. This target
/// stays minimal: it only verifies that the assembled app target itself
/// links and that types from the SPM modules are reachable from the host.
struct HexNFCTests {
    @Test func appTargetLinks() {
        #expect(MemoryLayout<HexNFC>.size >= 0)
    }
}
