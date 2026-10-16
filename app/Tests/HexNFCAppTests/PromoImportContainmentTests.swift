import Foundation
import XCTest

/// Pins the boundary the vendored promo SDK is allowed to cross.
///
/// `import HexPromoKit` appears in exactly one file in `HexNFCApp`:
/// `Promo/HomePromoSlot.swift`, which translates `PromoResolution` into the
/// app's own `PromoCreative` and hands that to the banner. The re-sync steps in
/// `app/Sources/HexPromoKit/PROVENANCE.md` are written on the assumption that
/// the scope holds; this is what enforces it.
///
/// The point is the blast radius. `Sources/HexPromoKit` is a byte-for-byte copy
/// of somebody else's repository, and the whole cost of a re-sync is re-reading
/// the call sites of whatever changed in its public surface. One importer means
/// that re-read is one file. Ten importers means it is a survey, and the kind of
/// survey nobody finishes, so the copy quietly stops being re-synced at all.
///
/// The directory is walked off disk through `#filePath` rather than asked of the
/// built module, because an import is a property of the source text and the
/// module has no memory of where it came from.
final class PromoImportContainmentTests: XCTestCase {
    /// The one file allowed to see the vendored SDK.
    private static let permittedImporter = "HomePromoSlot.swift"

    private static var appSources: URL {
        URL(fileURLWithPath: #filePath) // …/app/Tests/HexNFCAppTests/PromoImportContainmentTests.swift
            .deletingLastPathComponent() // …/HexNFCAppTests
            .deletingLastPathComponent() // …/Tests
            .deletingLastPathComponent() // …/app
            .appendingPathComponent("Sources/HexNFCApp", isDirectory: true)
    }

    /// Every `.swift` file under `HexNFCApp`, at any depth.
    private func sourceFiles() throws -> [URL] {
        let enumerator = FileManager.default.enumerator(at: Self.appSources, includingPropertiesForKeys: nil)
        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "swift" {
                files.append(url)
            }
        }
        return files
    }

    /// Whether a file carries a real `import HexPromoKit` statement.
    ///
    /// Compared against the whole line rather than by substring, so the several
    /// doc comments in `Promo/` that mention the module by name in prose do not
    /// read as importers. Anything after a `//` is dropped first, because a
    /// commented-out trailer on the import still leaves a live import.
    private func importsPromoKit(_ url: URL) throws -> Bool {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").contains { line in
            let code = line.components(separatedBy: "//")[0].trimmingCharacters(in: .whitespaces)
            return code == "import HexPromoKit" || code == "@testable import HexPromoKit"
        }
    }

    func test_exactlyOneFileInTheAppImportsTheVendoredSDK() throws {
        let files = try sourceFiles()
        XCTAssertFalse(files.isEmpty, "walked \(Self.appSources.path) and found no Swift at all")

        let importers = try files.filter { try importsPromoKit($0) }
            .map(\.lastPathComponent)
            .sorted()

        XCTAssertEqual(
            importers,
            [Self.permittedImporter],
            """
            the vendored SDK has leaked past its boundary. Importers: \(importers). \
            Translate at \(Self.permittedImporter) and pass PromoCreative on, so an \
            upstream API change stays readable in one sitting
            """
        )
    }

    /// Named on its own because `HomeView` is where the leak would start.
    ///
    /// The slot renders at the foot of Home, so wiring `PromoManager` straight
    /// into `HomeView` is the shortest path to the same pixels, and it is the
    /// change that would put a vendored type into a screen this app rewrites
    /// often. `HomeView` composes `HomePromoSlot()` and knows nothing else.
    func test_homeViewDoesNotImportTheVendoredSDK() throws {
        let homeView = Self.appSources.appendingPathComponent("Screens/HomeView.swift")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: homeView.path),
            "HomeView.swift moved; this guard is now pointing at nothing"
        )
        XCTAssertFalse(
            try importsPromoKit(homeView),
            "HomeView imports HexPromoKit; it should compose HomePromoSlot() and let that file do the translating"
        )
    }

    /// The same containment one level up, in the module graph.
    ///
    /// `HexPromoKit` is named three times in `app/Package.swift`: the target
    /// declaration, `HexNFCApp`'s dependency on it, and the ported test target's.
    /// A fourth mention means a second target can see the vendored copy, which
    /// the file-level check above cannot detect on its own.
    func test_onlyTheAppAndItsPortedTestsDependOnTheVendoredSDK() throws {
        let packageURL = Self.appSources
            .deletingLastPathComponent() // …/Sources
            .deletingLastPathComponent() // …/app
            .appendingPathComponent("Package.swift")
        let package = try String(contentsOf: packageURL, encoding: .utf8)
        let mentions = package.components(separatedBy: "\"HexPromoKit\"").count - 1
        XCTAssertEqual(
            mentions,
            3,
            "HexPromoKit is named somewhere new in Package.swift; only HexNFCApp and HexPromoKitTests may depend on it"
        )
    }
}
