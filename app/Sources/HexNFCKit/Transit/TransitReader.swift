import Foundation
import HexNFCRecords

/// Orchestrates reading a Japanese transit IC card (Suica family) from a
/// `FeliCaReadable` tag and decoding it into a `TransitCard`.
///
/// Pure of CoreNFC: it works against the `FeliCaReadable` seam, so it is
/// exercised identically by the device path and by the chip simulator in tests.
/// Byte-level interpretation lives in `SuicaHistoryDecoder`; station-name
/// resolution in `StationDirectory`. This type only sequences the reads and
/// wires those two together.
public struct TransitReader: Sendable {
    /// Suica-family transaction-history service, readable without encryption.
    public static let historyServiceCode: UInt16 = 0x090F
    /// The card retains the 20 most-recent transactions.
    public static let historyBlockCount = 20
    /// Cap blocks per read — real cards intermittently fail on larger requests.
    public static let maxBlocksPerRead = 10

    private let directory: StationDirectory

    public init(directory: StationDirectory = .bundled) {
        self.directory = directory
    }

    /// Read and decode a transit card. Returns `nil` if the tag is not a
    /// system we decode (i.e. not `0x0003`). Throws `TagError` if the FeliCa
    /// reads themselves fail.
    public func read(_ tag: FeliCaReadable) async throws -> TransitCard? {
        let system = TransitSystem(systemCode: tag.systemCode)
        guard system.isDecodable else { return nil }

        let blocks = try await readHistoryBlocks(tag)
        let decoded = SuicaHistoryDecoder.decode(blocks: blocks)
        let resolved = decoded.map(resolveNames)
        let balance = SuicaHistoryDecoder.currentBalance(blocks: blocks)

        return TransitCard(
            idmHex: tag.idm.hexString,
            system: system,
            balanceYen: balance,
            transactions: resolved
        )
    }

    // MARK: - Reads

    /// Page the history service in chunks of `maxBlocksPerRead`.
    private func readHistoryBlocks(_ tag: FeliCaReadable) async throws -> [Data] {
        var all: [Data] = []
        all.reserveCapacity(Self.historyBlockCount)
        var start = 0
        while start < Self.historyBlockCount {
            let end = min(start + Self.maxBlocksPerRead, Self.historyBlockCount)
            let page = try await tag.readWithoutEncryption(
                serviceCode: Self.historyServiceCode,
                blocks: start ..< end
            )
            all.append(contentsOf: page)
            start = end
        }
        return all
    }

    // MARK: - Name resolution

    private func resolveNames(_ txn: TransitTransaction) -> TransitTransaction {
        // Only a rail ride's legs are saibane codes the rail directory can
        // answer for. The decoder already nils the others out, so this is a
        // second gate rather than the only one, but it keeps the rule stated
        // where the lookup happens.
        guard txn.kind.legsAreRailStations else { return txn }
        let entry = txn.entry.map(resolve)
        let exit = txn.exit.map(resolve)
        guard entry != txn.entry || exit != txn.exit else { return txn }
        return TransitTransaction(
            id: txn.id,
            kind: txn.kind,
            date: txn.date,
            balanceYen: txn.balanceYen,
            entry: entry,
            exit: exit,
            sequence: txn.sequence
        )
    }

    private func resolve(_ ref: StationRef) -> StationRef {
        // The region byte scopes the lookup: saibane codes repeat across
        // regions, so an unscoped hit can name a Kanto station for a Kansai tap.
        if let entry = directory.entry(area: ref.regionCode, line: ref.lineCode, station: ref.stationCode) {
            var resolved = ref
            resolved.resolvedName = entry.name
            resolved.resolvedRomaji = entry.nameRomaji
            resolved.verified = entry.verified
            return resolved
        }
        // Partial fallback: station unmapped, but we know the line.
        if let line = directory.lineEntry(area: ref.regionCode, line: ref.lineCode) {
            var resolved = ref
            resolved.lineName = line.name
            return resolved
        }
        return ref
    }
}
