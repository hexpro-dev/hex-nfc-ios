import HexNFCKit
import XCTest

/// The Advanced console's preset names reach the user through the string
/// catalogue, and some of them carry the only warning a preset has.
///
/// `CommandPreset.name` is English and stays the preset's identity. The console
/// shows `localizedName`, which looks that name up at runtime, so the compiler
/// never sees a key to extract and nothing in the build notices a name with no
/// entry: it ships in English to every other locale. All of them did until
/// 2026-10-26, when Japanese documentation screenshots showed a Japanese
/// console full of English preset names.
///
/// `CommandPresetFidelityTests` makes a name say "replaces all of CFG1" when the
/// preset overwrites a whole configuration page, because `notes` are searched
/// and never shown. A translation that dropped the register would drop the
/// warning with it, so every chip, register and command identifier in the
/// English name has to survive into each translation.
///
/// The catalogue is read off disk through `#filePath`, in the idiom of
/// `LocalizableCatalogueTests`.
final class CommandPresetLocalisationTests: XCTestCase {
    private static let locales = ["ar", "es", "fr", "ja", "pt-BR", "zh-Hans"]

    private static var catalogueURL: URL {
        URL(fileURLWithPath: #filePath) // …/app/Tests/HexNFCAppTests/CommandPresetLocalisationTests.swift
            .deletingLastPathComponent() // …/HexNFCAppTests
            .deletingLastPathComponent() // …/Tests
            .deletingLastPathComponent() // …/app
            .appendingPathComponent("HexNFC/Localizable.xcstrings")
    }

    /// Each key's plain translations, by locale.
    private func translations() throws -> [String: [String: String]] {
        let data = try Data(contentsOf: Self.catalogueURL)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: [String: Any]])
        return strings.mapValues { entry in
            let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
            return localizations.compactMapValues { localization in
                (localization["stringUnit"] as? [String: Any])?["value"] as? String
            }
        }
    }

    func test_everyBuiltInPresetNameIsInTheCatalogue() throws {
        let catalogue = try translations()
        let missing = CommandPresetCatalog.builtIn.map(\.name).filter { catalogue[$0] == nil }
        XCTAssertTrue(
            missing.isEmpty,
            "Preset names with no catalogue entry, so English in every locale:\n" + missing.joined(separator: "\n")
        )
    }

    /// "NTAG213", "CFG1", "TT_CONFIG", "PWD_AUTH", "3DES": any word with a
    /// capital and no lower-case letter, two characters or more.
    func test_everyTranslationKeepsTheIdentifiersInTheName() throws {
        let catalogue = try translations()
        let identifier = try NSRegularExpression(pattern: #"\b[A-Z0-9_]*[A-Z][A-Z0-9_]*\b"#)
        var faults: [String] = []
        for name in CommandPresetCatalog.builtIn.map(\.name) {
            guard let byLocale = catalogue[name] else { continue } // reported above
            let range = NSRange(name.startIndex..., in: name)
            let tokens = identifier.matches(in: name, range: range)
                .compactMap { Range($0.range, in: name).map { String(name[$0]) } }
                .filter { $0.count >= 2 }
            for locale in Self.locales {
                guard let value = byLocale[locale] else {
                    faults.append("\(name) [\(locale)]: no translation")
                    continue
                }
                for token in tokens where !value.contains(token) {
                    faults.append("\(name) [\(locale)]: \"\(value)\" drops \(token)")
                }
            }
        }
        XCTAssertTrue(faults.isEmpty, faults.joined(separator: "\n"))
    }
}
