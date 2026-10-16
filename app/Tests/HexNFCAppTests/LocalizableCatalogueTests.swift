import XCTest

/// The string catalogue is data, and nothing in the build checks it.
///
/// `xcodebuild` compiles `Localizable.xcstrings` into per-locale tables and
/// exits 0 for a missing locale, a missing plural category, a `%lld` that one
/// variant forgot, or a state that is not `translated`; each of those ships as
/// English, "(null)", or a bare number to the users of that locale. The
/// catalogue is edited by script in this repo (2026-09-14 and after), which is
/// exactly how a category goes missing without anyone reading the diff.
///
/// The file is read off disk through `#filePath`, in the idiom of
/// `PromoImportContainmentTests`, because the built module has no memory of
/// where its strings came from.
final class LocalizableCatalogueTests: XCTestCase {
    /// The locales the app ships. A product decision, so hardcoded.
    private static let locales: Set<String> = ["ar", "es", "fr", "ja", "pt-BR", "zh-Hans"]

    /// The CLDR plural categories each locale's variations carry in this
    /// catalogue. Spanish, French and Brazilian Portuguese also define `many`
    /// for the millions and the catalogue leaves it to `other`, which is what
    /// every existing entry does and what a count of tries or records needs.
    private static let pluralCategories: [String: Set<String>] = [
        "ar": ["zero", "one", "two", "few", "many", "other"],
        "es": ["one", "other"],
        "fr": ["one", "other"],
        "ja": ["other"],
        "pt-BR": ["one", "other"],
        "zh-Hans": ["other"],
    ]

    /// Arabic spells out zero, one and two ("no records", "one record", "two
    /// records"), so those variants carry no number. Every other category, in
    /// every locale, must.
    private static let categoriesWithoutANumber: [String: Set<String>] = [
        "ar": ["zero", "one", "two"],
    ]

    private static var catalogueURL: URL {
        URL(fileURLWithPath: #filePath) // …/app/Tests/HexNFCAppTests/LocalizableCatalogueTests.swift
            .deletingLastPathComponent() // …/HexNFCAppTests
            .deletingLastPathComponent() // …/Tests
            .deletingLastPathComponent() // …/app
            .appendingPathComponent("HexNFC/Localizable.xcstrings")
    }

    private func strings() throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: Self.catalogueURL)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["sourceLanguage"] as? String, "en")
        return try XCTUnwrap(root["strings"] as? [String: [String: Any]])
    }

    // MARK: - Completeness

    /// Every key reaches every locale, and every unit is a finished translation.
    ///
    /// The seven strings the September bench fixes added were English in six
    /// locales on `main` until this test's branch landed: their translations
    /// were done on 2026-09-14 in an agent worktree that was never merged, and
    /// nothing said so. A key without a locale is visible in the file and
    /// invisible in the build.
    func test_everyKeyIsTranslatedIntoEveryLocale() throws {
        var gaps: [String] = []
        for (key, entry) in try strings() {
            let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
            let missing = Self.locales.subtracting(localizations.keys)
            if !missing.isEmpty {
                gaps.append("\(key.prefix(60)): missing \(missing.sorted())")
            }
            for (locale, localization) in localizations where Self.locales.contains(locale) {
                for (path, state) in Self.states(in: localization) where state != "translated" {
                    gaps.append("\(key.prefix(60)) [\(locale)] \(path): \(state)")
                }
            }
        }
        XCTAssertTrue(gaps.isEmpty, "Untranslated:\n" + gaps.sorted().joined(separator: "\n"))
    }

    // MARK: - Plurals

    /// A key whose English inflects on a count carries a plural variation in
    /// every locale, and each variation carries exactly its locale's
    /// categories, each with the number in it.
    ///
    /// `^[%lld wrong try](inflect: true)` is "1 wrong try" and "3 wrong tries"
    /// in English through automatic grammar agreement, which no other locale
    /// gets. A translation that is a plain string unit reads "1 intentos" to
    /// the user who chose the limit of one.
    func test_everyInflectedKeyIsPluralisedInEveryLocale() throws {
        var faults: [String] = []
        for (key, entry) in try strings() where key.contains("(inflect: true)") {
            XCTAssertTrue(key.contains("%lld"), "an inflected key counts something: \(key)")
            let inflections = key.components(separatedBy: "(inflect: true)").count - 1
            let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
            for locale in Self.locales.sorted() {
                guard let localization = localizations[locale] else { continue } // reported above
                let variations = Self.pluralVariations(in: localization)
                if variations.count != inflections {
                    faults.append(
                        "\(key.prefix(60)) [\(locale)]: \(variations.count) plural variations for \(inflections) inflected counts"
                    )
                }
                let expected = try XCTUnwrap(Self.pluralCategories[locale])
                let exempt = Self.categoriesWithoutANumber[locale] ?? []
                for (name, categories, numberToken) in variations {
                    if Set(categories.keys) != expected {
                        faults.append(
                            "\(key.prefix(60)) [\(locale)] \(name): categories \(categories.keys.sorted()), expected \(expected.sorted())"
                        )
                    }
                    for (category, value) in categories
                        where !exempt.contains(category) && !value.contains(numberToken)
                    {
                        faults
                            .append(
                                "\(key.prefix(60)) [\(locale)] \(name).\(category): no \(numberToken) in \"\(value)\""
                            )
                    }
                }
            }
        }
        XCTAssertTrue(faults.isEmpty, "Plural faults:\n" + faults.sorted().joined(separator: "\n"))
    }

    /// Every plural variation of one localization, wherever the catalogue keeps
    /// them: at the top level (`variations.plural`) for a key that is nothing
    /// but the count, or under each substitution (`substitutions.<name>`) for a
    /// key that carries other arguments too. Each comes back with a name for
    /// the message, its categories' values, and the token the number appears
    /// as (`%lld` at the top level, `%arg` inside a substitution).
    private static func pluralVariations(
        in localization: [String: Any]
    ) -> [(name: String, categories: [String: String], numberToken: String)] {
        func values(_ plural: [String: [String: Any]]) -> [String: String] {
            plural.compactMapValues { ($0["stringUnit"] as? [String: Any])?["value"] as? String }
        }
        var found: [(name: String, categories: [String: String], numberToken: String)] = []
        if let plural = ((localization["variations"] as? [String: Any])?["plural"]) as? [String: [String: Any]] {
            found.append(("plural", values(plural), "%lld"))
        }
        for (name, substitution) in localization["substitutions"] as? [String: [String: Any]] ?? [:] {
            guard (substitution["formatSpecifier"] as? String) == "lld",
                  let plural = ((substitution["variations"] as? [String: Any])?["plural"]) as? [String: [String: Any]]
            else { continue }
            found.append((name, values(plural), "%arg"))
        }
        return found.sorted { $0.name < $1.name }
    }

    /// Every `stringUnit.state` in one localization, with a path for the
    /// message. A localization is a unit, a plural variation of units, or a unit
    /// plus substitutions that each hold a plural variation of units.
    private static func states(in localization: [String: Any], path: String = "") -> [(String, String)] {
        var found: [(String, String)] = []
        if let unit = localization["stringUnit"] as? [String: Any] {
            found.append((path.isEmpty ? "stringUnit" : path, unit["state"] as? String ?? "missing"))
        }
        if let plural = ((localization["variations"] as? [String: Any])?["plural"]) as? [String: [String: Any]] {
            for (category, variant) in plural {
                found += states(in: variant, path: "\(path)plural.\(category)")
            }
        }
        if let substitutions = localization["substitutions"] as? [String: [String: Any]] {
            for (name, substitution) in substitutions {
                found += states(in: substitution, path: "\(path)\(name).")
            }
        }
        return found
    }
}
