import Foundation
import XCTest

/// Text the app puts on the iOS NFC sheet goes through the string catalogue.
///
/// `TagSession.start(alert:)`, `updateAlert(_:)` and `invalidate(error:)` take a
/// `String`, because CoreNFC's sheet does, so a bare literal compiles and ships
/// in English to every locale. That has happened twice. Three `begin(alert:)`
/// defaults were literals until `NFCPrompt` replaced them; then eight operation
/// and console prompts and the cancel message were found on 2026-10-25, in
/// Japanese documentation screenshots of a Japanese app showing English on the
/// sheet. Wrap the literal in `String(localized:)` and give it a catalogue entry.
///
/// The sources are read off disk through `#filePath`, in the idiom of
/// `PromoImportContainmentTests`, because whether an argument was a literal is
/// a property of the source text. A file that is `#if DEBUG` from its first line
/// never ships, so the live-chip harness flows are skipped.
final class NFCSheetCopyTests: XCTestCase {
    private static var appSources: URL {
        URL(fileURLWithPath: #filePath) // …/app/Tests/HexNFCAppTests/NFCSheetCopyTests.swift
            .deletingLastPathComponent() // …/HexNFCAppTests
            .deletingLastPathComponent() // …/Tests
            .deletingLastPathComponent() // …/app
            .appendingPathComponent("Sources/HexNFCApp", isDirectory: true)
    }

    /// A string literal handed straight to one of the sheet's three inputs, or
    /// to an `alert:` parameter that forwards to one.
    private static let literalSheetCopy = #"\balert:\s*"|\bupdateAlert\(\s*"|\binvalidate\(error:\s*""#

    func test_nothingPutsABareLiteralOnTheNFCSheet() throws {
        let pattern = try NSRegularExpression(pattern: Self.literalSheetCopy)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: Self.appSources, includingPropertiesForKeys: nil))
        var scanned = 0
        var offences: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            if source.hasPrefix("#if DEBUG") {
                continue
            }
            scanned += 1
            for (index, line) in source.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") {
                    continue
                }
                if pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                    offences.append("\(url.lastPathComponent):\(index + 1): \(trimmed)")
                }
            }
        }
        // A walk that found nothing proves nothing: the path above is the
        // thing most likely to break.
        XCTAssertGreaterThan(scanned, 20, "the scan should reach the app's sources")
        XCTAssertTrue(
            offences.isEmpty,
            "English literals on the NFC sheet; wrap each in String(localized:) and add it to the catalogue:\n"
                + offences.sorted().joined(separator: "\n")
        )
    }
}
