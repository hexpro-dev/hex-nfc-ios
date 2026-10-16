import Foundation
@testable import HexPromoKit
import XCTest

/// Upstream's decoding cases, ported with the vendored sources.
///
/// Method names are upstream's verbatim; `PromoTestWorld` carries the reason and
/// the full list of what the port changed.
///
/// What these pin is the wire contract, which is the half of the SDK that has to
/// survive the server moving first. Both enums decode leniently on purpose, so a
/// creative type the API learns before this build does collapses one slot rather
/// than failing the whole batch response.
final class PromoDecodingTests: XCTestCase {
    func testDecodeBatchWithPromoAndNull() throws {
        let data = Data(PromoFixtures.batchJSON.utf8)
        let response = try JSONDecoder().decode(BatchResponse.self, from: data)

        XCTAssertEqual(response.results.count, 2)

        let first = response.results[0]
        XCTAssertEqual(first.cacheKey, "pro.hex.nfc|ios|home_bottom")
        let promo = try XCTUnwrap(first.promo)
        XCTAssertEqual(promo.mediaType, .image)
        XCTAssertEqual(promo.linkType, .web)
        XCTAssertEqual(promo.aspectWidth, 1200)
        XCTAssertEqual(promo.aspectHeight, 300)
        XCTAssertEqual(promo.etag, "c0d9a05b4eaa72f1")
        XCTAssertEqual(promo.aspectRatio, 4.0, accuracy: 0.0001)
        XCTAssertTrue(promo.isTappable)

        XCTAssertNil(response.results[1].promo)
        XCTAssertEqual(response.results[1].cacheKey, "pro.hex.nfc|ios|nonexistent")
    }

    func testUnknownLinkTypeFallsBackToNone() throws {
        let json = PromoFixtures.imagePromoJSON.replacingOccurrences(of: "\"web\"", with: "\"carrier_billing\"")
        let promo = try JSONDecoder().decode(ResolvedPromo.self, from: Data(json.utf8))
        XCTAssertEqual(promo.linkType, .none)
        XCTAssertFalse(promo.isTappable)
    }

    func testUnknownMediaTypeFallsBackToImage() throws {
        let json = PromoFixtures.imagePromoJSON.replacingOccurrences(of: "\"image\"", with: "\"lottie\"")
        let promo = try JSONDecoder().decode(ResolvedPromo.self, from: Data(json.utf8))
        XCTAssertEqual(promo.mediaType, .image)
    }

    func testNullDimensionsDecode() throws {
        let json = PromoFixtures.imagePromoJSON
            .replacingOccurrences(of: "\"width\": 1200", with: "\"width\": null")
            .replacingOccurrences(of: "\"height\": 300", with: "\"height\": null")
        let promo = try JSONDecoder().decode(ResolvedPromo.self, from: Data(json.utf8))
        XCTAssertNil(promo.width)
        XCTAssertNil(promo.height)
        XCTAssertEqual(promo.aspectWidth, 1200)
    }

    func testCacheKeyBuilder() {
        XCTAssertEqual(
            PromoCacheKey.make(bundleId: "pro.hex.nfc", platform: "ios", locationId: "home_bottom"),
            "pro.hex.nfc|ios|home_bottom"
        )
    }
}
