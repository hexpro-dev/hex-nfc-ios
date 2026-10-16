import Foundation
@testable import HexPromoKit
import XCTest

/// Upstream's manager cases, ported with the vendored sources. Method names are
/// upstream's verbatim; see `PromoTestWorld` for why.
///
/// These three are most of the reason the SDK was worth vendoring instead of
/// rewriting. Offline-first serving and null eviction are the behaviours a fresh
/// implementation gets subtly wrong, and they already had coverage.
///
/// `PromoManager`'s `init(baseURL:session:cache:debounceNanos:)` and `flushNow()`
/// are internal seams that exist for these cases, which is why the target
/// imports `@testable`.
@MainActor
final class PromoManagerTests: XCTestCase {
    private func makeManager() throws -> (PromoManager, URL) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HexPromoMgr-\(UUID().uuidString)", isDirectory: true)
        let cache = PromoDiskCache(directory: dir)
        let manager = try PromoManager(
            baseURL: XCTUnwrap(URL(string: "https://api.p.hex.pro")),
            session: session,
            cache: cache,
            debounceNanos: 1_000_000
        )
        return (manager, dir)
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        StubURLProtocol.shouldFail = false
        super.tearDown()
    }

    func testResolvesImagePromoAndCaches() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }

        StubURLProtocol.handler = { request in
            if request.url?.path.contains("/v1/promos/batch") == true {
                return (200, Data(PromoFixtures.batchJSON.utf8))
            }
            // media bytes
            return (200, Data([0x89, 0x50, 0x4E, 0x47]))
        }

        manager.register(bundleId: "pro.hex.nfc", platform: .ios, locationId: "home_bottom")
        manager.register(bundleId: "pro.hex.nfc", platform: .ios, locationId: "nonexistent")
        await manager.flushNow()

        let resolved = manager.resolution(for: "pro.hex.nfc|ios|home_bottom")
        guard case .resolved(let promo, let mediaURL) = resolved else {
            return XCTFail("Expected resolved, got \(resolved)")
        }
        XCTAssertEqual(promo.etag, "c0d9a05b4eaa72f1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mediaURL.path))

        // Null slot collapses.
        XCTAssertEqual(manager.resolution(for: "pro.hex.nfc|ios|nonexistent"), .empty)
    }

    func testOfflineFallbackServesCache() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }

        // First: successful fetch populates the cache.
        StubURLProtocol.handler = { request in
            if request.url?.path.contains("/v1/promos/batch") == true {
                return (200, Data(PromoFixtures.batchJSON.utf8))
            }
            return (200, Data([0x89, 0x50, 0x4E, 0x47]))
        }
        manager.register(bundleId: "pro.hex.nfc", platform: .ios, locationId: "home_bottom")
        await manager.flushNow()
        XCTAssertNotNil(manager.resolution(for: "pro.hex.nfc|ios|home_bottom").promo)

        // Now go offline with a fresh manager sharing the same cache dir.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let offlineManager = try PromoManager(
            baseURL: XCTUnwrap(URL(string: "https://api.p.hex.pro")),
            session: URLSession(configuration: config),
            cache: PromoDiskCache(directory: dir),
            debounceNanos: 1_000_000
        )
        StubURLProtocol.shouldFail = true

        offlineManager.register(bundleId: "pro.hex.nfc", platform: .ios, locationId: "home_bottom")
        await offlineManager.flushNow()

        let resolved = offlineManager.resolution(for: "pro.hex.nfc|ios|home_bottom")
        XCTAssertNotNil(resolved.promo, "Offline should serve the last cached promo")
    }

    func testNullEvictionThroughManager() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Round 1: slot resolves to a promo.
        StubURLProtocol.handler = { request in
            if request.url?.path.contains("/v1/promos/batch") == true {
                return (200, Data(PromoFixtures.batchJSON.utf8))
            }
            return (200, Data([0x89, 0x50, 0x4E, 0x47]))
        }
        manager.register(bundleId: "pro.hex.nfc", platform: .ios, locationId: "home_bottom")
        await manager.flushNow()
        XCTAssertNotNil(manager.resolution(for: "pro.hex.nfc|ios|home_bottom").promo)

        // Round 2: the same slot now resolves to null -> must evict + collapse.
        let nullJSON = """
        { "results": [ { "bundleId": "pro.hex.nfc", "platform": "ios", "locationId": "home_bottom", "promo": null } ] }
        """
        StubURLProtocol.handler = { _ in (200, Data(nullJSON.utf8)) }
        await manager.flushNow()

        XCTAssertEqual(manager.resolution(for: "pro.hex.nfc|ios|home_bottom"), .empty)
        let cached = await PromoDiskCache(directory: dir).cachedPromo(for: "pro.hex.nfc|ios|home_bottom")
        XCTAssertNil(cached, "Null eviction must remove the cached metadata entry")
    }
}
