import Foundation
@testable import HexNFCKit
import XCTest

/// Every `ConnectedTag` that authenticates must **store** its session holders.
///
/// `ConnectedTag` gives each holder a default that returns a fresh instance per
/// access, which is right for a conformer with no credential path and a silent
/// bug for one that has it: `type2Session.isAuthenticated = true` then lands on
/// an object discarded on the next line. `CoreNFCConnectedTag` took that default
/// for the Type-2 holder from fe4c5bd until 2026-09-16, so on device a
/// read-protected tag the session had just unlocked was read back through the
/// high-level NDEF path with the gate still shut.
///
/// This reads the source text because the tag it is about is `#if os(iOS)`:
/// `swift test` on macOS never compiles `CoreNFCSession.swift`, so nothing in
/// the suite can hold a `CoreNFCConnectedTag` or observe its holders. The idiom
/// is `PromoImportContainmentTests`, which guards a boundary the same way.
final class SessionHolderStorageTests: XCTestCase {
    private static var coreNFCSession: String {
        get throws {
            let url = URL(fileURLWithPath: #filePath) // …/app/Tests/HexNFCKitTests/SessionHolderStorageTests.swift
                .deletingLastPathComponent() // …/HexNFCKitTests
                .deletingLastPathComponent() // …/Tests
                .deletingLastPathComponent() // …/app
                .appendingPathComponent("Sources/HexNFCKit/CoreNFCSession.swift")
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    /// The production tag stores all three, as stored properties.
    func test_theProductionTagStoresEverySessionHolder() throws {
        let source = try Self.coreNFCSession
        for holder in ["type2Session = Type2SessionHolder()",
                       "ev2Session = EV2SessionHolder()",
                       "ultralightCSession = UltralightCSessionHolder()"]
        {
            XCTAssertTrue(
                source.contains("let \(holder)"),
                "CoreNFCConnectedTag must store its own \(holder). A computed one, or the protocol's "
                    + "default, throws away every write to it."
            )
        }
    }

    /// And the authenticated read path reads the stored flag rather than a field
    /// of its own, which is what went stale.
    func test_theAuthenticatedReadPathConsultsTheStoredFlag() throws {
        let source = try Self.coreNFCSession
        XCTAssertTrue(
            source.contains("type2Session.isAuthenticated, chip?.memoryLayout.ndefRange != nil"),
            "the raw page read after a PWD_AUTH must gate on the holder the credential path writes"
        )
        XCTAssertFalse(
            source.contains("private var didAuthenticate"),
            "a second copy of this state is how it went stale the first time"
        )
    }

    /// The holders are per-tag, so two tags cannot share an authentication.
    func test_holdersAreNotShared() {
        let a = Type2SessionHolder()
        let b = Type2SessionHolder()
        a.isAuthenticated = true
        XCTAssertFalse(b.isAuthenticated)
    }
}
