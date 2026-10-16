@testable import HexNFCKit
@testable import HexNFCRecords
@testable import HexNFCTagSim
import XCTest

/// End-to-end: a simulated Suica card driven through `SimulatedSession` and the
/// `FeliCaReadable` seam into `TransitReader`. Exercises the same orchestration
/// the device path runs, minus CoreNFC.
final class TransitReaderTests: XCTestCase {
    private func connectedTag(_ sim: SuicaSimulator) async throws -> FeliCaReadable {
        let session = SimulatedSession(chip: sim)
        let tag = try await session.start(alert: "hold steady")
        return try XCTUnwrap(tag as? FeliCaReadable)
    }

    func test_readsBalanceAndHistory() async throws {
        let felica = try await connectedTag(SuicaSimulator())
        let card = try await TransitReader().read(felica)

        let unwrapped = try XCTUnwrap(card)
        XCTAssertEqual(unwrapped.system, .suicaFamily)
        XCTAssertEqual(unwrapped.balanceYen, 1230)
        XCTAssertEqual(unwrapped.transactions.count, 5)
        XCTAssertEqual(unwrapped.idmHex, SuicaSimulator.defaultIDm.hexString)
    }

    func test_resolvesSeededStationNames() async throws {
        let felica = try await connectedTag(SuicaSimulator())
        let read = try await TransitReader().read(felica)
        let card = try XCTUnwrap(read)

        let first = card.transactions[0]
        XCTAssertEqual(first.kind, .ride)
        XCTAssertEqual(first.entry?.resolvedName, "新宿") // line 1 / station 8
        XCTAssertEqual(first.exit?.resolvedName, "渋谷") // line 1 / station 12
    }

    func test_unmappedCodesFallBackToRaw() async throws {
        // A ride between codes the seed pack doesn't cover.
        let history = [
            SuicaSimulator.makeBlock(
                terminal: 0x16, process: 0x01, year: 2024, month: 6, day: 1,
                entryLine: 0x7A, entryStation: 0x55, exitLine: 0x7A, exitStation: 0x56,
                balanceYen: 500, sequence: 200
            ),
        ]
        let felica = try await connectedTag(SuicaSimulator(history: history))
        let read = try await TransitReader().read(felica)
        let card = try XCTUnwrap(read)

        let txn = card.transactions[0]
        XCTAssertNil(txn.entry?.resolvedName)
        XCTAssertEqual(txn.entry?.rawCodeString, "7A:55")
    }

    func test_transactionKinds() async throws {
        let felica = try await connectedTag(SuicaSimulator())
        let read = try await TransitReader().read(felica)
        let card = try XCTUnwrap(read)
        XCTAssertEqual(card.transactions.map(\.kind), [.ride, .charge, .bus, .ride, .purchase])
    }

    /// Bytes 6-9 are only saibane codes on a rail ride. The sample history's
    /// charge, bus and purchase blocks carry values there that *collide* with
    /// seeded rail codes (01:08 = Shinjuku, 01:0C = Shibuya), so if the reader
    /// ever resolves them again this fails with a real station name attached to
    /// a top-up.
    func test_nonRailBlocksCarryNoStationLegs() async throws {
        let felica = try await connectedTag(SuicaSimulator())
        let read = try await TransitReader().read(felica)
        let card = try XCTUnwrap(read)

        for txn in card.transactions where txn.kind != .ride {
            XCTAssertNil(txn.entry, "\(txn.kind) must expose no entry station")
            XCTAssertNil(txn.exit, "\(txn.kind) must expose no exit station")
        }
        // And the rail rides in the same history still resolve, so the gate
        // isn't just suppressing everything.
        let rides = card.transactions.filter { $0.kind == .ride }
        XCTAssertEqual(rides.count, 2)
        XCTAssertEqual(rides.first?.entry?.resolvedName, "新宿")
    }

    /// A charge block whose bytes 6-9 exactly match a seeded station must not
    /// borrow that station's name.
    func test_chargeDoesNotResolveCollidingRailCode() async throws {
        let history = [
            SuicaSimulator.makeNonRailBlock(
                terminal: 0x16, process: 0x02, year: 2024, month: 6, day: 2,
                aux6: 0x01, aux7: 0x08,
                balanceYen: 2000, sequence: 300
            ),
        ]
        let felica = try await connectedTag(SuicaSimulator(history: history))
        let read = try await TransitReader().read(felica)
        let card = try XCTUnwrap(read)

        let txn = card.transactions[0]
        XCTAssertEqual(txn.kind, .charge)
        XCTAssertNil(txn.entry)
        XCTAssertNil(txn.entry?.resolvedName)
    }

    /// Re-decoding the same card must produce byte-identical JSON, or
    /// `HistoryEntry.contentFingerprint` never matches and every tap of an
    /// unchanged card stacks another history row.
    func test_encodingIsStableAcrossReads() async throws {
        let readA = try await TransitReader().read(connectedTag(SuicaSimulator()))
        let readB = try await TransitReader().read(connectedTag(SuicaSimulator()))
        let first = try XCTUnwrap(readA)
        let second = try XCTUnwrap(readB)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(
            try encoder.encode(first),
            try encoder.encode(second),
            "two reads of the same card must encode identically"
        )
    }
}
