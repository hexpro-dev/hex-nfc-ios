@testable import HexNFCRecords
import XCTest

final class StationDirectoryTests: XCTestCase {
    func test_resolvesKnownCode() {
        let dir = StationDirectory(entries: [
            StationEntry(line: 1, station: 8, name: "新宿", nameRomaji: "Shinjuku"),
        ])
        XCTAssertEqual(dir.name(line: 1, station: 8), "新宿")
        XCTAssertEqual(dir.entry(line: 1, station: 8)?.nameRomaji, "Shinjuku")
    }

    func test_unknownCodeReturnsNil() {
        let dir = StationDirectory(entries: [
            StationEntry(line: 1, station: 8, name: "新宿"),
        ])
        XCTAssertNil(dir.name(line: 9, station: 9))
    }

    func test_emptyDirectory() {
        let dir = StationDirectory(entries: [])
        XCTAssertEqual(dir.count, 0)
        XCTAssertNil(dir.name(line: 1, station: 1))
    }

    /// Guards that the bundled packs ship and parse, and that a seeded entry
    /// resolves. (Couples to the seed on purpose — it's small and PROVISIONAL.)
    func test_bundledPacksLoadSeed() {
        let dir = StationDirectory.bundled
        XCTAssertGreaterThan(dir.count, 0, "station packs failed to load")
        XCTAssertEqual(dir.name(line: 1, station: 8), "新宿")
    }

    /// The triangulated seed rows are CC0/Wikidata-sourced and not yet
    /// tap-verified, so they must surface as unverified.
    func test_bundledSeedIsUnverifiedWikidata() {
        let entry = StationDirectory.bundled.entry(line: 1, station: 8)
        XCTAssertEqual(entry?.verified, false)
        XCTAssertEqual(entry?.source, "Wikidata")
    }

    /// The owner's real card taps ship as VERIFIED — the first verified rows in
    /// the pack. (Ginza, Tokyo Metro Ginza Line — saibane 227/54.)
    func test_bundledHasVerifiedTapEntry() {
        let entry = StationDirectory.bundled.entry(line: 227, station: 54)
        XCTAssertEqual(entry?.name, "銀座")
        XCTAssertEqual(entry?.verified, true)
        XCTAssertEqual(entry?.source, "tap")
    }

    /// Line packs load and resolve a line name (partial-fallback source).
    func test_bundledLineResolves() {
        XCTAssertEqual(StationDirectory.bundled.lineName(line: 227), "Ginza Line")
        XCTAssertGreaterThan(StationDirectory.bundled.lineCount, 0)
    }

    /// Partial fallback: an unmapped station on a known line still yields the
    /// line name (so the UI shows "Ginza Line · ?" not a raw hex code).
    func test_partialLineFallback() {
        let dir = StationDirectory.bundled
        XCTAssertNil(dir.entry(line: 227, station: 200), "station 200 should be unmapped")
        XCTAssertEqual(dir.lineName(line: 227), "Ginza Line")
    }

    /// A verified entry must win over an unverified one for the same code,
    /// regardless of load order.
    func test_mergePrecedence_verifiedWins() {
        let dir = StationDirectory(entries: [
            StationEntry(line: 1, station: 1, name: "ODPT名", operatorName: "x", verified: false, source: "ODPT"),
            StationEntry(line: 1, station: 1, name: "東京", verified: true, source: "tap"),
        ])
        let e = dir.entry(line: 1, station: 1)
        XCTAssertEqual(e?.name, "東京")
        XCTAssertEqual(e?.verified, true)
    }

    /// At equal verification tier, CC0/community data beats ODPT.
    func test_mergePrecedence_cc0BeatsODPT() {
        let dir = StationDirectory(entries: [
            StationEntry(line: 2, station: 5, name: "ODPT名", verified: false, source: "ODPT"),
            StationEntry(line: 2, station: 5, name: "Wiki名", verified: false, source: "Wikidata"),
        ])
        XCTAssertEqual(dir.entry(line: 2, station: 5)?.source, "Wikidata")
    }

    /// Line directory lookup via the direct initializer.
    func test_lineDirectoryLookup() {
        let dir = StationDirectory(entries: [], lines: [
            LineEntry(line: 5, name: "Test Line", verified: true, source: "tap"),
        ])
        XCTAssertEqual(dir.lineName(line: 5), "Test Line")
        XCTAssertNil(dir.lineName(line: 6))
    }

    // MARK: - Region scoping

    /// A saibane code means different things in different regions, so a
    /// region-scoped lookup must prefer the row for that region.
    func test_areaScopedLookupPrefersMatchingRegion() {
        let directory = StationDirectory(entries: [
            StationEntry(line: 1, station: 1, area: 0, name: "東京", verified: true, source: "tap"),
            StationEntry(line: 1, station: 1, area: 3, name: "大阪", verified: true, source: "tap"),
        ])
        XCTAssertEqual(directory.entry(area: 0, line: 1, station: 1)?.name, "東京")
        XCTAssertEqual(directory.entry(area: 3, line: 1, station: 1)?.name, "大阪")
    }

    /// When two regions claim a code and the card is from neither, there is no
    /// honest answer: return nothing rather than pick one. The UI then shows the
    /// raw code and offers to have it named.
    func test_ambiguousCodeFromAThirdRegionResolvesToNothing() {
        let directory = StationDirectory(entries: [
            StationEntry(line: 1, station: 1, area: 0, name: "東京", verified: true, source: "tap"),
            StationEntry(line: 1, station: 1, area: 3, name: "大阪", verified: true, source: "tap"),
        ])
        XCTAssertNil(directory.entry(area: 9, line: 1, station: 1))
    }

    /// A single-region pack still answers a card from any region: with only one
    /// candidate there is nothing to be ambiguous about, and refusing would be a
    /// regression for every card scanned today.
    func test_unambiguousCodeStillResolvesForAnyRegion() {
        let directory = StationDirectory(entries: [
            StationEntry(line: 1, station: 1, area: 0, name: "東京", verified: true, source: "tap"),
        ])
        XCTAssertEqual(directory.entry(area: 0, line: 1, station: 1)?.name, "東京")
        XCTAssertEqual(directory.entry(area: 7, line: 1, station: 1)?.name, "東京")
        XCTAssertEqual(directory.entry(line: 1, station: 1)?.name, "東京")
    }

    /// The same rules for the line-name fallback, which previously applied a
    /// Kanto line name to any card that shared the code.
    func test_lineFallbackIsRegionScoped() {
        let directory = StationDirectory(entries: [], lines: [
            LineEntry(line: 227, area: 0, name: "Ginza Line", verified: true, source: "tap"),
            LineEntry(line: 227, area: 3, name: "Other Line", verified: true, source: "tap"),
        ])
        XCTAssertEqual(directory.lineEntry(area: 0, line: 227)?.name, "Ginza Line")
        XCTAssertEqual(directory.lineEntry(area: 3, line: 227)?.name, "Other Line")
        XCTAssertNil(directory.lineEntry(area: 9, line: 227))
    }
}
