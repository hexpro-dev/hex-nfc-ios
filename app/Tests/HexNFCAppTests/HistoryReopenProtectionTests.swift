import XCTest

/// A source-text guard over the history route in `RootView.swift`, read off disk
/// through `#filePath` in the idiom of `OperationsSheetAffordanceTests`.
///
/// `RootView.swift` opens with `#if os(iOS)`, so `swift test` on macOS compiles
/// none of it and no ordinary assertion can reach the call site. The
/// `xcodebuild -destination generic/platform=iOS` job type-checks the file and is
/// deliberately independent of this one; what this checks is that the argument
/// is still being passed.
///
/// The defect: a row re-opened into `EditFlowModel(… protection: … ?? .none)`
/// with `protectionIsUnknown` left at its `false` default, which put an open
/// padlock and the word "Off" on a tag whose protection nothing had ever read.
/// The live scan path stopped saying that after the refused read on 2026-08-14;
/// this route kept saying it. `HistoryEntry.protectionIsUnknown` carries the
/// reason and is covered in `TagProtectionStorageTests`, so the only thing left
/// uncovered is whether this screen asks it.
final class HistoryReopenProtectionTests: XCTestCase {
    private static var rootViewURL: URL {
        URL(fileURLWithPath: #filePath) // …/app/Tests/HexNFCAppTests/HistoryReopenProtectionTests.swift
            .deletingLastPathComponent() // …/HexNFCAppTests
            .deletingLastPathComponent() // …/Tests
            .deletingLastPathComponent() // …/app
            .appendingPathComponent("Sources/HexNFCApp/Screens/RootView.swift")
    }

    func test_reopeningAHistoryRowCarriesWhatTheRowDoesNotKnow() throws {
        let source = try String(contentsOf: Self.rootViewURL, encoding: .utf8)
        let route = try XCTUnwrap(
            source.components(separatedBy: "onOpenHistoryEntry: { entry in").dropFirst().first,
            "the history route moved or was renamed, and this guard is now inert"
        )
        let flattened = route.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")

        XCTAssertTrue(
            flattened.contains(
                "protection: entry.decodedProtection() ?? .none, "
                    + "protectionIsUnknown: entry.protectionIsUnknown"
            ),
            "a history row's editor must be told the row holds no reading; without it the "
                + "Protection card claims Off, and seeds its secret fields as if the tag were bare"
        )
    }
}
