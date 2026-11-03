@testable import HexNFCApp
import XCTest

/// The home screen's Documentation button opens the guide in the app's language.
///
/// The addresses are hex-web's: English at the bare path, the rest under the
/// site's own language code. A wrong prefix is a 404 on the site, so each one
/// is written out rather than derived.
final class DocumentationLinkTests: XCTestCase {
    func test_eachShippedLocalisation_opensItsOwnGuide() {
        let expected: [String: String] = [
            "en": "https://apps.hex.pro/hex-nfc/docs",
            "ar": "https://apps.hex.pro/ar/hex-nfc/docs",
            "es": "https://apps.hex.pro/es/hex-nfc/docs",
            "fr": "https://apps.hex.pro/fr/hex-nfc/docs",
            "ja": "https://apps.hex.pro/ja/hex-nfc/docs",
            "pt-BR": "https://apps.hex.pro/pt-BR/hex-nfc/docs",
            "zh-Hans": "https://apps.hex.pro/zh/hex-nfc/docs",
        ]
        for (localization, address) in expected {
            XCTAssertEqual(
                DocumentationLink.url(forLocalization: localization).absoluteString,
                address,
                localization
            )
        }
    }

    /// A language the app does not ship shows English strings, so it gets the
    /// English guide, as does a bundle that reports no localisation at all.
    func test_unshippedOrMissingLocalisation_opensEnglishGuide() {
        for localization in ["de", "zh-Hant", "pt", "Base", nil] {
            XCTAssertEqual(
                DocumentationLink.url(forLocalization: localization).absoluteString,
                "https://apps.hex.pro/hex-nfc/docs",
                localization ?? "nil"
            )
        }
    }
}
