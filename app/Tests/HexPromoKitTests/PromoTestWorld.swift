import Foundation
@testable import HexPromoKit

/// Shared scaffolding for the ported HexPromoKit suite.
///
/// Everything in `Tests/HexPromoKitTests` is UPSTREAM's own test file, split
/// into four so the fixtures can be shared, and otherwise carried across as it
/// stands. The original is one 357-line file at
/// `sdk/swift/HexPromoKit/Tests/HexPromoKitTests/HexPromoKitTests.swift` in
/// `hexpro-dev/hex-promo`, and keeping the port close to it is what lets a
/// re-sync be diffed line by line rather than re-read.
///
/// That includes upstream's test METHOD names, which stay verbatim: `testFooBar`
/// against the `test_fooBar` spelling every other case in this repository uses.
/// These four files are the one place the house style loses on purpose. A
/// renamed method costs a diff hunk at every future re-sync and buys nothing,
/// because nobody reads these names looking for hex-nfc's conventions; they read
/// them against the upstream file.
///
/// What the port changed, in full. Concatenating the four files back into one
/// and diffing against the upstream path above turns up nothing beyond this
/// list, and it is worth re-running that diff rather than trusting the list,
/// because a re-syncer who trusts an incomplete one silently drops whatever it
/// left out.
///
/// Changed on purpose:
///
/// - upstream's `private enum Fixtures` is `PromoFixtures` here, and internal,
///   because the cases that read it now sit in three separate files.
/// - the force unwraps are gone. `app/Tests` is linted under `--strict` with
///   `force_unwrapping` opted in and, unlike `Sources/HexPromoKit`, it is not on
///   the exclude list, so upstream's `request.url!` below and the
///   `HTTPURLResponse` unwrap beside it would both fail the lint job. Upstream's
///   other two, in `PromoManagerTests`' `makeManager()` and
///   `testOfflineFallbackServesCache()`, would not: SwiftLint exempts
///   `URL(string:)!` on a string literal, which is why `PromoManager.swift:55`
///   does fire on the same spelling over a constant. They went anyway so the
///   rule reads the same everywhere, which is what made `makeManager()`
///   `throws` and put `try` on its three call sites.
/// - `override class func` below is `override static func`, the lint job again:
///   `static_over_final_class` fires on the class spelling inside a `final`
///   class, and the two mean the same thing in one.
///
/// Changed by the split and by this repository's tooling:
///
/// - the imports are re-sorted, which `sorted_imports` requires of upstream's
///   `XCTest` before `HexPromoKit`, and all four files carry a `Foundation`
///   import. This one needs it, having no `import XCTest` to reach Foundation
///   through.
/// - `// MARK: - Fixtures`, `- Decoding` and `- Disk cache` are gone, each
///   having become a file. `// MARK: - Manager (network stubbed)` stays,
///   because this file still holds two sections.
/// - SwiftFormat covers `app/Tests` where it excludes the vendored sources, and
///   it rewrote two places: the double space before `// no extension` in
///   `PromoDiskCacheTests.testSanitizeAndExtension`, and a blank line before
///   `stopLoading()` below.
/// - the doc comments are ours. Upstream carries one line on `StubURLProtocol`
///   and none on the cases.
///
/// The fixture identifiers are untouched. Upstream already writes them against
/// `pro.hex.nfc` and `home_bottom`, which are this app's real bundle id and its
/// real slot (`HexPromoSlot` in `HexNFCApp/Promo/PromoCreative.swift`), so a
/// failure message here names the wire shape this app actually sends.
enum PromoFixtures {
    static let imagePromoJSON = """
    {
      "creativeId": "b2f3-uuid",
      "mediaType": "image",
      "mediaUrl": "https://api.p.hex.pro/media/c0d9a05b4eaa72f1.png",
      "width": 1200,
      "height": 300,
      "aspectWidth": 1200,
      "aspectHeight": 300,
      "linkUrl": "https://apps.hex.pro",
      "linkType": "web",
      "etag": "c0d9a05b4eaa72f1"
    }
    """

    static let batchJSON = """
    {
      "results": [
        {
          "bundleId": "pro.hex.nfc",
          "platform": "ios",
          "locationId": "home_bottom",
          "promo": \(imagePromoJSON)
        },
        {
          "bundleId": "pro.hex.nfc",
          "platform": "ios",
          "locationId": "nonexistent",
          "promo": null
        }
      ]
    }
    """

    static func promo(etag: String, mediaType: PromoMediaType = .image) -> ResolvedPromo {
        ResolvedPromo(
            creativeId: "creative-\(etag)",
            mediaType: mediaType,
            mediaUrl: "https://api.p.hex.pro/media/\(etag).png",
            width: 1200,
            height: 300,
            aspectWidth: 1200,
            aspectHeight: 300,
            linkUrl: "https://apps.hex.pro",
            linkType: .web,
            etag: etag
        )
    }
}

// MARK: - Manager (network stubbed)

/// A URLProtocol that returns canned responses for the batch endpoint and media.
///
/// `handler` and `shouldFail` are process-wide static state, which is what
/// `URLProtocol` registration forces: URLSession instantiates the class itself,
/// so there is nowhere to inject. Every case that touches them clears them again
/// in `tearDown`.
final class StubURLProtocol: URLProtocol {
    /// (statusCode, body) keyed by URL path suffix; set per test.
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var shouldFail = false

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        if StubURLProtocol.shouldFail {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let (status, body) = StubURLProtocol.handler?(request) ?? (200, Data())
        // Upstream force-unwraps `request.url` and the response here. Both are
        // unwrapped instead, because `force_unwrapping` is on for `app/Tests`.
        // Reporting the failure through the client rather than a `fatalError`
        // also keeps a malformed stub URL readable as one failing case.
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: status,
                  httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
