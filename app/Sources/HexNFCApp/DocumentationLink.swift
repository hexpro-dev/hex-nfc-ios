import Foundation

/// The Hex NFC guide on apps.hex.pro, in the language the app is showing.
///
/// hex-web serves the English guide at the bare path and each other language
/// under a prefix (`/ja/hex-nfc/docs`). Its prefixes are its own language
/// codes, which match the app's localisation names everywhere but Simplified
/// Chinese: `zh-Hans` here, `zh` there. A localisation the site has no guide
/// for opens the English one rather than a 404.
///
/// The language comes from `Bundle.main.preferredLocalizations`, the one the
/// app's own strings resolved to, so a reader with the app set to Japanese in
/// Settings > Apps gets the Japanese guide whatever the phone's language is.
enum DocumentationLink {
    private static let english = "https://apps.hex.pro/hex-nfc/docs"

    /// hex-web's prefix for each localisation the app ships besides English.
    private static let sitePrefixes: [String: String] = [
        "ar": "ar",
        "es": "es",
        "fr": "fr",
        "ja": "ja",
        "pt-BR": "pt-BR",
        "zh-Hans": "zh",
    ]

    static var current: URL {
        url(forLocalization: Bundle.main.preferredLocalizations.first)
    }

    static func url(forLocalization localization: String?) -> URL {
        let address = localization
            .flatMap { sitePrefixes[$0] }
            .map { "https://apps.hex.pro/\($0)/hex-nfc/docs" } ?? english
        // Every address is a literal or one with a literal prefix spliced in,
        // and the tests open each of them, so this cannot fail.
        // swiftlint:disable:next force_unwrapping
        return URL(string: address)!
    }
}
