import Foundation
@testable import HexPromoKit
import XCTest

/// Upstream's disk-cache cases, ported with the vendored sources. Method names
/// are upstream's verbatim; see `PromoTestWorld` for why.
///
/// The two reference-counting cases (`testEtagChangeRemovesOldOrphanedMedia` and
/// `testSharedEtagNotDeletedWhileStillReferenced`) are the ones worth inheriting
/// rather than rewriting. Media files
/// are named by etag, so two slots serving the same creative share a single file
/// on disk and eviction has to count references instead of deleting by name. A
/// fresh implementation gets that wrong quietly: the banner keeps rendering
/// until the file is gone, so the bug only shows up on the second slot.
final class PromoDiskCacheTests: XCTestCase {
    private func makeCache() -> (PromoDiskCache, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HexPromoTests-\(UUID().uuidString)", isDirectory: true)
        return (PromoDiskCache(directory: dir), dir)
    }

    func testStoreAndReadBack() async throws {
        let (cache, dir) = makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let key = "pro.hex.nfc|ios|home_bottom"
        let promo = PromoFixtures.promo(etag: "abc123")

        try await cache.storeMedia(for: promo, data: Data([0x1, 0x2, 0x3]))
        await cache.upsert(key: key, promo: promo)

        let cached = await cache.cachedPromo(for: key)
        XCTAssertEqual(cached?.etag, "abc123")
        let mediaExists = await cache.mediaExists(for: promo)
        XCTAssertTrue(mediaExists)
        let existingURL = await cache.existingMediaURL(for: promo)
        XCTAssertNotNil(existingURL)
    }

    func testNullEvictionRemovesMetadataAndMedia() async throws {
        let (cache, dir) = makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let key = "pro.hex.nfc|ios|home_bottom"
        let promo = PromoFixtures.promo(etag: "toEvict")
        try await cache.storeMedia(for: promo, data: Data([0xFF]))
        await cache.upsert(key: key, promo: promo)

        // Precondition
        let beforeMedia = await cache.mediaExists(for: promo)
        XCTAssertTrue(beforeMedia)

        // Evict
        await cache.evict(key: key)

        let after = await cache.cachedPromo(for: key)
        XCTAssertNil(after, "Metadata entry must be gone")
        let afterMedia = await cache.mediaExists(for: promo)
        XCTAssertFalse(afterMedia, "Media file must be deleted on null eviction")
    }

    func testEtagChangeRemovesOldOrphanedMedia() async throws {
        let (cache, dir) = makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let key = "pro.hex.nfc|ios|home_bottom"
        let old = PromoFixtures.promo(etag: "oldEtag")
        let new = PromoFixtures.promo(etag: "newEtag")

        try await cache.storeMedia(for: old, data: Data([0x1]))
        await cache.upsert(key: key, promo: old)
        try await cache.storeMedia(for: new, data: Data([0x2]))
        await cache.upsert(key: key, promo: new)

        let oldExists = await cache.mediaExists(for: old)
        let newExists = await cache.mediaExists(for: new)
        XCTAssertFalse(oldExists, "Superseded media should be pruned")
        XCTAssertTrue(newExists)
    }

    func testSharedEtagNotDeletedWhileStillReferenced() async throws {
        let (cache, dir) = makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let keyA = "pro.hex.nfc|ios|a"
        let keyB = "pro.hex.nfc|ios|b"
        let promo = PromoFixtures.promo(etag: "shared")

        try await cache.storeMedia(for: promo, data: Data([0x9]))
        await cache.upsert(key: keyA, promo: promo)
        await cache.upsert(key: keyB, promo: promo)

        // Evicting one slot must NOT delete media still used by the other.
        await cache.evict(key: keyA)
        let stillThere = await cache.mediaExists(for: promo)
        XCTAssertTrue(stillThere)

        await cache.evict(key: keyB)
        let goneNow = await cache.mediaExists(for: promo)
        XCTAssertFalse(goneNow)
    }

    func testSanitizeAndExtension() {
        XCTAssertEqual(PromoDiskCache.sanitize("c0d9a05b4eaa72f1"), "c0d9a05b4eaa72f1")
        XCTAssertEqual(PromoDiskCache.sanitize("\"weak/etag\""), "_weak_etag_")
        XCTAssertEqual(PromoDiskCache.fileExtension(for: PromoFixtures.promo(etag: "x")), "png")
        let video = PromoFixtures.promo(etag: "v")
        let mp4 = ResolvedPromo(
            creativeId: video.creativeId, mediaType: .video,
            mediaUrl: "https://api.p.hex.pro/media/abc", // no extension
            width: nil, height: nil, aspectWidth: 16, aspectHeight: 9,
            linkUrl: nil, linkType: .none, etag: "v"
        )
        XCTAssertEqual(PromoDiskCache.fileExtension(for: mp4), "mp4")
    }
}
