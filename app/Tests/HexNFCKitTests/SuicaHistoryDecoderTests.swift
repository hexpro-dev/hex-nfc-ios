@testable import HexNFCRecords
@testable import HexNFCTagSim
import XCTest

/// Byte-level tests for the Suica history decoder. The blocks are built with the
/// simulator's `makeBlock`, so these also guard that the simulator and decoder
/// agree on the layout.
final class SuicaHistoryDecoderTests: XCTestCase {
    func test_decodesBalanceLittleEndian() {
        let block = SuicaSimulator.makeBlock(
            terminal: 0x16, process: 0x01, year: 2024, month: 5, day: 20,
            balanceYen: 1230, sequence: 100
        )
        let txn = SuicaHistoryDecoder.decodeBlock(block)
        XCTAssertEqual(txn?.balanceYen, 1230)
    }

    func test_balanceUsesBothBytes() {
        // 0x1234 = 4660 — proves byte 11 (high) is read, not just byte 10.
        let block = SuicaSimulator.makeBlock(
            terminal: 0x16, process: 0x01, year: 2024, month: 1, day: 1,
            balanceYen: 4660, sequence: 1
        )
        XCTAssertEqual(SuicaHistoryDecoder.decodeBlock(block)?.balanceYen, 4660)
    }

    func test_decodesDateBitPacking() {
        let block = SuicaSimulator.makeBlock(
            terminal: 0x16, process: 0x01, year: 2024, month: 5, day: 20,
            balanceYen: 1000, sequence: 1
        )
        let date = SuicaHistoryDecoder.decodeBlock(block)?.date
        XCTAssertEqual(date?.year, 2024)
        XCTAssertEqual(date?.month, 5)
        XCTAssertEqual(date?.day, 20)
    }

    func test_decodesStationCodes() {
        let block = SuicaSimulator.makeBlock(
            terminal: 0x16, process: 0x01, year: 2024, month: 5, day: 20,
            entryLine: 1, entryStation: 8, exitLine: 1, exitStation: 12,
            balanceYen: 1000, sequence: 1
        )
        let txn = SuicaHistoryDecoder.decodeBlock(block)
        XCTAssertEqual(txn?.entry?.lineCode, 1)
        XCTAssertEqual(txn?.entry?.stationCode, 8)
        XCTAssertEqual(txn?.exit?.lineCode, 1)
        XCTAssertEqual(txn?.exit?.stationCode, 12)
        XCTAssertNil(txn?.entry?.resolvedName, "decoder must not resolve names")
    }

    /// The decoder must only read bytes 6-9 as station codes on a rail ride.
    /// Every other kind stores something else there (bus line/stop codes, shop
    /// and terminal identifiers, a packed time on a purchase), and reading those
    /// as saibane codes names a station the user never visited.
    func test_onlyRailRidesExposeStationLegs() {
        /// Identical bytes 6-9 (01:08 / 01:0C, both seeded rail codes) on every kind.
        func legs(terminal: UInt8, process: UInt8) -> (StationRef?, StationRef?) {
            let block = SuicaSimulator.makeNonRailBlock(
                terminal: terminal, process: process,
                year: 2024, month: 6, day: 1,
                aux6: 0x01, aux7: 0x08, aux8: 0x01, aux9: 0x0C,
                balanceYen: 1000, sequence: 1
            )
            let txn = SuicaHistoryDecoder.decodeBlock(block)
            return (txn?.entry, txn?.exit)
        }

        let ride = legs(terminal: 0x16, process: 0x01)
        XCTAssertEqual(ride.0?.lineCode, 0x01)
        XCTAssertEqual(ride.0?.stationCode, 0x08)
        XCTAssertEqual(ride.1?.stationCode, 0x0C)

        for (terminal, process) in [(UInt8(0x16), UInt8(0x02)), // charge
                                    (UInt8(0x05), UInt8(0x0D)), // bus
                                    (UInt8(0xC7), UInt8(0x46))]
        { // purchase
            let (entry, exit) = legs(terminal: terminal, process: process)
            XCTAssertNil(entry, "terminal \(terminal) process \(process) must expose no entry")
            XCTAssertNil(exit, "terminal \(terminal) process \(process) must expose no exit")
        }
    }

    /// The other half of the same rule: a non-rail block still decodes its
    /// balance, date, kind and sequence. Suppressing the legs must not suppress
    /// the row.
    func test_nonRailBlocksStillDecodeEverythingElse() {
        let block = SuicaSimulator.makeNonRailBlock(
            terminal: 0xC7, process: 0x46, year: 2024, month: 5, day: 10,
            aux6: 0x11, aux7: 0x2E, aux8: 0x03, aux9: 0x9F,
            balanceYen: 1180, sequence: 96
        )
        let txn = SuicaHistoryDecoder.decodeBlock(block)
        XCTAssertEqual(txn?.kind, .purchase)
        XCTAssertEqual(txn?.balanceYen, 1180)
        XCTAssertEqual(txn?.sequence, 96)
        XCTAssertEqual(txn?.date?.day, 10)
    }

    /// `id` must stay out of the encoded form: it is minted fresh on every
    /// decode, and encoding it made the scan-history fingerprint differ on every
    /// tap of an unchanged card.
    func test_idIsNotEncoded() throws {
        let txn = TransitTransaction(
            kind: .ride, date: DateComponents(year: 2024, month: 5, day: 20),
            balanceYen: 1230,
            entry: StationRef(lineCode: 1, stationCode: 8),
            exit: StationRef(lineCode: 1, stationCode: 12),
            sequence: 100
        )
        // Key-sorted, matching `JSONEncoder.preset`, the encoder that actually
        // builds `HistoryEntry.contentFingerprint`.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(txn)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("\"id\""), "id must not be encoded: \(json)")

        let round = try JSONDecoder().decode(TransitTransaction.self, from: data)
        XCTAssertEqual(round.kind, txn.kind)
        XCTAssertEqual(round.balanceYen, txn.balanceYen)
        XCTAssertEqual(round.entry, txn.entry)
        XCTAssertEqual(round.sequence, txn.sequence)
        XCTAssertEqual(try encoder.encode(round), data)
    }

    /// Every process code we claim a meaning for, pinned. The table is the
    /// felicalib / farebot / metrodroid one the decoder's header cites.
    func test_classifiesDocumentedProcessCodes() {
        /// Terminal 0x00 is in NONE of the terminal sets, so the process byte is
        /// the only thing that can decide. Using a gate terminal here would let
        /// the `.ride` fallback rescue a process code accidentally dropped from
        /// `rideProcesses`, and the test would pass while real hardware regressed.
        func kind(_ process: UInt8, terminal: UInt8 = 0x00) -> TransitTransaction.Kind? {
            SuicaHistoryDecoder.decodeBlock(
                SuicaSimulator.makeBlock(
                    terminal: terminal, process: process,
                    year: 2024, month: 1, day: 1, balanceYen: 1, sequence: 1
                )
            )?.kind
        }

        // Rail fare events: ordinary exit, fare adjustments, window exit,
        // Shinkansen. 0x04 and 0x06 used to be classified as top-ups.
        for process: UInt8 in [0x01, 0x04, 0x05, 0x06, 0x13, 0x84, 0x85] {
            XCTAssertEqual(kind(process), .ride, "process \(process) should be a ride")
        }
        // Deposits: charge, entry/exit auto-charge, bus top-up, bonus charge,
        // register deposit. All but 0x02 used to fall through to .ride/.bus.
        for process: UInt8 in [0x02, 0x14, 0x15, 0x1F, 0x48, 0x49] {
            XCTAssertEqual(kind(process), .charge, "process \(process) should be a charge")
        }
        for process: UInt8 in [0x0D, 0x0F, 0x23] {
            XCTAssertEqual(kind(process), .bus, "process \(process) should be a bus fare")
        }
        for process: UInt8 in [0x03, 0x46, 0x4A, 0x4B, 0xC6, 0xCB] {
            XCTAssertEqual(kind(process), .purchase, "process \(process) should be a purchase")
        }
        // Card lifecycle: new issue, window deduction, re-issue. Not journeys.
        for process: UInt8 in [0x07, 0x08, 0x11] {
            XCTAssertEqual(kind(process), .other, "process \(process) should be other")
        }
    }

    /// An unrecognised process byte must not be assumed to be a journey: `.ride`
    /// is the one verdict that makes the app read bytes 6-9 as stations and
    /// invite the user to name them.
    func test_unknownProcessFallsBackToTerminalThenOther() {
        func kind(terminal: UInt8, process: UInt8) -> TransitTransaction.Kind? {
            SuicaHistoryDecoder.decodeBlock(
                SuicaSimulator.makeBlock(
                    terminal: terminal, process: process,
                    year: 2024, month: 1, day: 1, balanceYen: 1, sequence: 1
                )
            )?.kind
        }
        let unknown: UInt8 = 0x7E // in no documented set

        XCTAssertEqual(kind(terminal: 0xC7, process: unknown), .purchase, "POS console")
        XCTAssertEqual(kind(terminal: 0x05, process: unknown), .bus, "vehicle console")
        XCTAssertEqual(kind(terminal: 0x16, process: unknown), .ride, "ticket gate")
        // Console we can't place either: say so rather than guessing a journey.
        XCTAssertEqual(kind(terminal: 0x99, process: unknown), .other)
        XCTAssertNil(
            SuicaHistoryDecoder.decodeBlock(
                SuicaSimulator.makeNonRailBlock(
                    terminal: 0x99, process: unknown, year: 2024, month: 1, day: 1,
                    aux6: 0x01, aux7: 0x08, balanceYen: 1, sequence: 1
                )
            )?.entry,
            "an unclassified block must not expose station legs"
        )
    }

    /// Byte 15 is the region code and scopes the saibane namespace. It reaches
    /// both legs so the directory lookup and a crowd-sourced suggestion can say
    /// which region the code belongs to.
    func test_decodesRegionCodeOntoBothLegs() {
        var bytes = [UInt8](SuicaSimulator.makeBlock(
            terminal: 0x16, process: 0x01, year: 2024, month: 5, day: 20,
            entryLine: 1, entryStation: 8, exitLine: 1, exitStation: 12,
            balanceYen: 1000, sequence: 1
        ))
        bytes[15] = 0x03
        let txn = SuicaHistoryDecoder.decodeBlock(Data(bytes))
        XCTAssertEqual(txn?.entry?.regionCode, 0x03)
        XCTAssertEqual(txn?.exit?.regionCode, 0x03)
    }

    func test_mapsTransactionKinds() {
        func kind(terminal: UInt8, process: UInt8) -> TransitTransaction.Kind? {
            SuicaHistoryDecoder.decodeBlock(
                SuicaSimulator.makeBlock(
                    terminal: terminal, process: process,
                    year: 2024, month: 1, day: 1, balanceYen: 1, sequence: 1
                )
            )?.kind
        }
        XCTAssertEqual(kind(terminal: 0x16, process: 0x01), .ride)
        XCTAssertEqual(kind(terminal: 0x16, process: 0x02), .charge)
        XCTAssertEqual(kind(terminal: 0xC7, process: 0x46), .purchase)
        XCTAssertEqual(kind(terminal: 0x05, process: 0x0D), .bus)
    }

    func test_skipsBlankBlocks() {
        let blank = Data(repeating: 0, count: 16)
        let real = SuicaSimulator.makeBlock(
            terminal: 0x16, process: 0x01, year: 2024, month: 5, day: 20,
            balanceYen: 1230, sequence: 100
        )
        let decoded = SuicaHistoryDecoder.decode(blocks: [real, blank, blank])
        XCTAssertEqual(decoded.count, 1)
    }

    func test_currentBalanceUsesNewestNonBlankBlock() {
        let newest = SuicaSimulator.makeBlock(
            terminal: 0x16, process: 0x01, year: 2024, month: 5, day: 20,
            balanceYen: 777, sequence: 100
        )
        let older = SuicaSimulator.makeBlock(
            terminal: 0x16, process: 0x01, year: 2024, month: 5, day: 1,
            balanceYen: 999, sequence: 99
        )
        XCTAssertEqual(SuicaHistoryDecoder.currentBalance(blocks: [newest, older]), 777)
        XCTAssertEqual(SuicaHistoryDecoder.currentBalance(blocks: []), 0)
    }

    func test_malformedBlockIsSkipped() {
        let short = Data([0x01, 0x02, 0x03])
        XCTAssertNil(SuicaHistoryDecoder.decodeBlock(short))
        XCTAssertTrue(SuicaHistoryDecoder.decode(blocks: [short]).isEmpty)
    }
}
