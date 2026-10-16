@testable import HexNFCRecords
@testable import HexNFCStorage
import XCTest

@MainActor
final class LibraryRepositoryTests: XCTestCase {
    func makeRepo() throws -> LibraryRepository {
        let stack = try SwiftDataStack.inMemory()
        return LibraryRepository(stack: stack)
    }

    // MARK: - Presets

    func test_insertPreset_thenFetch_returnsSavedPreset() throws {
        let repo = try makeRepo()
        let records: [NDEFRecord] = [
            .uri(URIRecord(uri: "https://hex.pro")),
            .text(TextRecord(text: "hi")),
        ]
        let preset = try repo.insertPreset(name: "Office", records: records, notes: "front desk")
        XCTAssertEqual(preset.name, "Office")
        let fetched = try repo.fetchPresets()
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].decodedRecords().count, 2)
        XCTAssertEqual(fetched[0].notes, "front desk")
    }

    func test_fetchPresets_returnsMostRecentlyUpdatedFirst() throws {
        let repo = try makeRepo()
        let older = try repo.insertPreset(name: "Older", records: [.uri(URIRecord(uri: "a"))])
        let newer = try repo.insertPreset(name: "Newer", records: [.uri(URIRecord(uri: "b"))])
        // Force distinct timestamps so the sort is deterministic — SwiftData's
        // millisecond precision can otherwise tie when inserts happen back-to-back.
        older.updatedAt = Date(timeIntervalSinceNow: -10)
        newer.updatedAt = Date()
        let fetched = try repo.fetchPresets()
        XCTAssertEqual(fetched.first?.name, "Newer")
        XCTAssertEqual(fetched.count, 2)
    }

    func test_deletePreset_removesIt() throws {
        let repo = try makeRepo()
        let preset = try repo.insertPreset(name: "Tmp", records: [.text(TextRecord(text: "x"))])
        try repo.deletePreset(preset)
        XCTAssertTrue(try repo.fetchPresets().isEmpty)
    }

    func test_duplicatePreset_clonesContentsAndAppendsCopySuffix() throws {
        let repo = try makeRepo()
        let original = try repo.insertPreset(
            name: "Source",
            records: [.uri(URIRecord(uri: "https://hex.pro"))],
            notes: "original notes"
        )
        let copy = try repo.duplicatePreset(original)
        XCTAssertEqual(copy.name, "Source (copy)")
        XCTAssertEqual(copy.notes, "original notes")
        XCTAssertEqual(copy.decodedRecords().count, 1)
        XCTAssertEqual(try repo.fetchPresets().count, 2)
        XCTAssertNotEqual(copy.id, original.id)
    }

    // MARK: - History

    func test_recordScan_storesEntryWithLowercasedUID() throws {
        let repo = try makeRepo()
        let entry = try repo.recordScan(
            chipFamily: "NTAG215",
            uidHex: "04:A1:B2:C3:D4:E5:F6",
            records: [.uri(URIRecord(uri: "https://hex.pro"))]
        )
        XCTAssertEqual(entry.uidHex, "04a1b2c3d4e5f6")
        XCTAssertEqual(try repo.fetchHistory().count, 1)
    }

    func test_togglePin_flipsPinnedFlag() throws {
        let repo = try makeRepo()
        let entry = try repo.recordScan(chipFamily: "NTAG215", uidHex: "abcd", records: [])
        XCTAssertFalse(entry.pinned)
        try repo.togglePin(entry)
        XCTAssertTrue(entry.pinned)
        try repo.togglePin(entry)
        XCTAssertFalse(entry.pinned)
    }

    func test_purgeStale_dropsUnpinnedOlderThan90Days() throws {
        let repo = try makeRepo()
        let now = Date()
        // Old + unpinned — should purge.
        let oldUnpinned = try repo.recordScan(
            chipFamily: "NTAG215",
            uidHex: "11",
            records: [],
            at: now.addingTimeInterval(-100 * 24 * 60 * 60)
        )
        // Old + pinned — should keep.
        let oldPinned = try repo.recordScan(
            chipFamily: "NTAG215",
            uidHex: "22",
            records: [],
            at: now.addingTimeInterval(-100 * 24 * 60 * 60)
        )
        try repo.togglePin(oldPinned)
        // Recent — should keep.
        let recent = try repo.recordScan(
            chipFamily: "NTAG215",
            uidHex: "33",
            records: [],
            at: now.addingTimeInterval(-5 * 24 * 60 * 60)
        )

        let purged = try repo.purgeStale(now: now)
        XCTAssertEqual(purged, 1)
        let remaining = try repo.fetchHistory().map(\.uidHex).sorted()
        XCTAssertEqual(remaining.sorted(), ["22", "33"])
        _ = oldUnpinned
        _ = recent
    }

    func test_recordScan_storesFullSnapshot() throws {
        let repo = try makeRepo()
        let card = TransitCard(
            idmHex: "01:02:03:04:05:06:07:08",
            system: .suicaFamily,
            balanceYen: 1234,
            transactions: []
        )
        let entry = try repo.recordScan(
            chipFamily: "FeliCa",
            uidHex: "0102030405060708",
            records: [],
            chipName: "Suica",
            manufacturer: "Sony",
            totalBytes: 0,
            capabilitiesRaw: 0b1_0000_0000_0001, // ndefRead + transitRead
            transitCard: card
        )
        XCTAssertEqual(entry.chipName, "Suica")
        XCTAssertEqual(entry.manufacturer, "Sony")
        XCTAssertEqual(entry.capabilitiesRaw, 0b1_0000_0000_0001)
        XCTAssertEqual(entry.decodedTransitCard()?.balanceYen, 1234)
        XCTAssertEqual(entry.displayName, "Suica")
        XCTAssertEqual(entry.displayUID, "01:02:03:04:05:06:07:08")
    }

    func test_recordScan_dedupesExactDuplicate_andRefloatsTimestamp() throws {
        let repo = try makeRepo()
        let now = Date()
        // Two *independently constructed* record arrays, as two real taps of the
        // same tag produce: `NDEFCodec` mints a fresh `id: UUID` per payload on
        // every decode. Reusing one array here is what let the id leak into
        // `contentFingerprint` go unnoticed, so the arrays must not be shared.
        func scannedRecords() -> [NDEFRecord] {
            [.uri(URIRecord(uri: "https://hex.pro"))]
        }
        let first = try repo.recordScan(
            chipFamily: "NTAG215",
            uidHex: "04a1b2",
            records: scannedRecords(),
            chipName: "NTAG215",
            at: now.addingTimeInterval(-60)
        )
        // Identical content (different timestamp) collapses onto the same row.
        let second = try repo.recordScan(
            chipFamily: "NTAG215",
            uidHex: "04a1b2",
            records: scannedRecords(),
            chipName: "NTAG215",
            at: now
        )
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(second.scannedAt, now) // re-floated to the newest tap
        XCTAssertEqual(try repo.fetchHistory().count, 1)

        // A genuinely different scan (other records) is NOT deduped.
        _ = try repo.recordScan(
            chipFamily: "NTAG215",
            uidHex: "04a1b2",
            records: [.text(TextRecord(text: "changed"))],
            chipName: "NTAG215",
            at: now
        )
        XCTAssertEqual(try repo.fetchHistory().count, 2)
    }

    /// The same rule for a transit card: re-decoding one card mints 20 fresh
    /// transaction UUIDs, and those must not reach the fingerprint either.
    func test_recordScan_dedupesTransitCardAcrossSeparateDecodes() throws {
        let repo = try makeRepo()
        let now = Date()
        func card() throws -> TransitCard {
            let source = TransitCard(
                idmHex: "01:02:03:04:05:06:07:08",
                system: .suicaFamily,
                balanceYen: 1230,
                transactions: [
                    TransitTransaction(
                        kind: .ride,
                        date: DateComponents(year: 2024, month: 5, day: 20),
                        balanceYen: 1230,
                        entry: StationRef(lineCode: 1, stationCode: 8),
                        exit: StationRef(lineCode: 1, stationCode: 12),
                        sequence: 100
                    ),
                ]
            )
            // Round-trip so each call mints its own transaction identities,
            // exactly as a second tap of the same card would.
            let data = try JSONEncoder.preset.encode(source)
            return try JSONDecoder.preset.decode(TransitCard.self, from: data)
        }

        let first = try repo.recordScan(
            chipFamily: "FeliCa", uidHex: "0102030405060708", records: [],
            transitCard: card(), at: now.addingTimeInterval(-60)
        )
        let second = try repo.recordScan(
            chipFamily: "FeliCa", uidHex: "0102030405060708", records: [],
            transitCard: card(), at: now
        )
        XCTAssertEqual(first.id, second.id, "two taps of one transit card must collapse to one row")
        XCTAssertEqual(try repo.fetchHistory().count, 1)

        // A card with a different balance is a different scan.
        _ = try repo.recordScan(
            chipFamily: "FeliCa", uidHex: "0102030405060708", records: [],
            transitCard: TransitCard(
                idmHex: "01:02:03:04:05:06:07:08",
                system: .suicaFamily,
                balanceYen: 900,
                transactions: []
            ),
            at: now
        )
        XCTAssertEqual(try repo.fetchHistory().count, 2)
    }

    func test_recordScan_capsHistoryAtFiftyMostRecentUnpinned() throws {
        let repo = try makeRepo()
        let now = Date()
        // 60 distinct scans, oldest first.
        for i in 0 ..< 60 {
            _ = try repo.recordScan(
                chipFamily: "NTAG215",
                uidHex: String(format: "%04x", i),
                records: [],
                at: now.addingTimeInterval(TimeInterval(i))
            )
        }
        let entries = try repo.fetchHistory()
        XCTAssertEqual(entries.count, 50)
        // Newest kept, oldest trimmed.
        XCTAssertEqual(entries.first?.uidHex, String(format: "%04x", 59))
        XCTAssertFalse(entries.contains { $0.uidHex == String(format: "%04x", 0) })
    }

    func test_recordScan_pinnedEntriesSurviveTheCap() throws {
        let repo = try makeRepo()
        let now = Date()
        // An old scan, pinned — must survive even as newer scans push past 50.
        let pinned = try repo.recordScan(
            chipFamily: "NTAG215",
            uidHex: "beef",
            records: [],
            at: now
        )
        try repo.togglePin(pinned)
        for i in 0 ..< 60 {
            _ = try repo.recordScan(
                chipFamily: "NTAG215",
                uidHex: String(format: "n%04x", i),
                records: [],
                at: now.addingTimeInterval(TimeInterval(i + 1))
            )
        }
        let uids = try repo.fetchHistory().map(\.uidHex)
        XCTAssertTrue(uids.contains("beef")) // pinned survived
        // 50 unpinned + 1 pinned.
        XCTAssertEqual(uids.count, 51)
    }

    // MARK: - .hexnfc envelope

    func test_exportHexnfc_thenImport_roundTripsRecords() throws {
        let repo = try makeRepo()
        let originalRecords: [NDEFRecord] = [
            .uri(URIRecord(uri: "https://hex.pro")),
            .text(TextRecord(text: "round trip")),
        ]
        let preset = try repo.insertPreset(name: "Envelope test", records: originalRecords, notes: "n")
        let data = try repo.exportAsHexnfc(preset)
        let imported = try repo.importHexnfc(data)
        XCTAssertEqual(imported.name, "Envelope test")
        XCTAssertEqual(imported.notes, "n")
        XCTAssertEqual(imported.decodedRecords().count, originalRecords.count)
        // Two presets in the store now — the original + the imported copy.
        XCTAssertEqual(try repo.fetchPresets().count, 2)
    }
}
