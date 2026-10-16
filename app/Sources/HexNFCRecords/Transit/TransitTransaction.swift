import Foundation

/// A reference to a station as recorded on the card: the raw FeliCa "saibane"
/// line + station codes, plus an optionally-resolved human name.
///
/// The card stores *only* the numeric codes (defined by the Japan Railway
/// Cybernetics Council). Turning them into "Shinjuku" needs an external,
/// cleanly-licensed name pack (`StationDirectory`); when the pack doesn't cover
/// a code, `resolvedName` is `nil` and the UI shows the raw codes instead.
public struct StationRef: Hashable, Sendable, Codable {
    public let lineCode: UInt8
    public let stationCode: UInt8
    /// Human-readable station name, if the directory could resolve it.
    public var resolvedName: String?
    /// Romaji (Latin-script) reading of `resolvedName`, when the pack has one.
    /// Drives the tappable "ℹ︎" tooltip beside a Japanese station name.
    public var resolvedRomaji: String?
    /// Whether `resolvedName` is tap/primary-confirmed. `false` for triangulated
    /// (unconfirmed) mappings — which the UI flags and invites confirming — and
    /// always `false` when unresolved.
    public var verified: Bool
    /// Resolved *line* name, set only as a partial fallback when the exact
    /// station code is unmapped but its line is known (e.g. "Ginza Line"). The
    /// UI shows this in place of a bare hex code, still tappable to confirm.
    public var lineName: String?
    /// Region code from byte 15 of the history block (Kanto, Kansai, JR, …).
    ///
    /// The saibane namespace is keyed on (region, line, station), not on
    /// (line, station): the same pair means different stations in different
    /// regions. Carrying it lets `StationDirectory` prefer a region-matched
    /// entry and lets a crowd-sourced suggestion say which region it is for.
    /// `nil` only for a `StationRef` built without one.
    public var regionCode: UInt8?

    public init(
        lineCode: UInt8,
        stationCode: UInt8,
        resolvedName: String? = nil,
        resolvedRomaji: String? = nil,
        verified: Bool = false,
        lineName: String? = nil,
        regionCode: UInt8? = nil
    ) {
        self.lineCode = lineCode
        self.stationCode = stationCode
        self.resolvedName = resolvedName
        self.resolvedRomaji = resolvedRomaji
        self.verified = verified
        self.lineName = lineName
        self.regionCode = regionCode
    }

    /// Raw codes formatted as `0xLL:0xSS` for display when unresolved.
    public var rawCodeString: String {
        String(format: "%02X:%02X", lineCode, stationCode)
    }

    /// Whether both codes are zero (no station recorded for this leg).
    public var isEmpty: Bool {
        lineCode == 0 && stationCode == 0
    }
}

/// One entry from a Suica-family card's transaction history (service `0x090F`).
///
/// Everything here is derived purely from the 16-byte history block — no
/// external database is needed for the balance, date, kind, or raw station
/// codes. Only the *names* on `entry`/`exit` need the station directory.
public struct TransitTransaction: Hashable, Sendable, Codable, Identifiable {
    /// What kind of transaction the block records, derived from the terminal
    /// (byte 0) and process (byte 1) codes.
    public enum Kind: String, Hashable, Sendable, Codable {
        case ride // rail fare payment (gate in/out)
        case bus // bus fare
        case charge // top-up / deposit
        case purchase // shop / vending purchase
        case other

        public var symbolName: String {
            switch self {
            case .ride: "tram.fill"
            case .bus: "bus.fill"
            case .charge: "yensign.circle.fill"
            case .purchase: "cart.fill"
            case .other: "creditcard.fill"
            }
        }

        /// Whether bytes 6-9 of the history block hold *rail station* codes for
        /// this kind. Only a rail ride records entry/exit saibane (line,
        /// station) pairs there.
        ///
        /// Every other kind puts something else in those four bytes. A bus fare
        /// stores a 16-bit bus line code and a 16-bit stop code in a namespace
        /// unrelated to rail. A shop purchase stores a packed time of day in
        /// 6-7 and a shop code in 8-9 (device traces 2026-08-20: `94:2B B4:91`,
        /// `04:0F 85:4B`). Reading either as a station names a place the user
        /// never went, so the decoder leaves `entry`/`exit` `nil` for them.
        ///
        /// A **charge** is the interesting case: bytes 6-7 do hold a real rail
        /// station code, the station the top-up machine sits at, with 8-9 zero
        /// (confirmed on both live cards, where it matched an adjacent ride's
        /// station). It is still `false` here, because a top-up is not a journey
        /// and rendering one station as a route would misread it. Naming the
        /// charge location is a feature we could add deliberately; it is not
        /// something to fall into by treating the leg as a journey.
        public var legsAreRailStations: Bool {
            self == .ride
        }
    }

    public let id: UUID
    public let kind: Kind
    /// Calendar date of the transaction (year/month/day only — the card stores
    /// no time of day for rail entries). `nil` if the date field was empty.
    public let date: DateComponents?
    /// Card balance in yen *after* this transaction.
    public let balanceYen: Int
    public let entry: StationRef?
    public let exit: StationRef?
    /// Monotonic transaction sequence number (bytes 12–14).
    public let sequence: Int

    public init(
        id: UUID = UUID(),
        kind: Kind,
        date: DateComponents?,
        balanceYen: Int,
        entry: StationRef?,
        exit: StationRef?,
        sequence: Int
    ) {
        self.id = id
        self.kind = kind
        self.date = date
        self.balanceYen = balanceYen
        self.entry = entry
        self.exit = exit
        self.sequence = sequence
    }

    // MARK: - Codable

    /// `id` is deliberately absent from the coding keys: it is a per-decode
    /// identity for SwiftUI's `ForEach`, not data the card carries.
    ///
    /// Encoding it made `HistoryEntry.contentFingerprint` differ on every scan
    /// of an *unchanged* card, because each decode minted 20 fresh UUIDs. Scan
    /// history dedup therefore never matched a transit card against itself, so
    /// repeated taps stacked duplicate rows and trimmed the user's other scans
    /// out of the 50-row cap.
    private enum CodingKeys: String, CodingKey {
        case kind
        case date
        case balanceYen
        case entry
        case exit
        case sequence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        kind = try container.decode(Kind.self, forKey: .kind)
        date = try container.decodeIfPresent(DateComponents.self, forKey: .date)
        balanceYen = try container.decode(Int.self, forKey: .balanceYen)
        entry = try container.decodeIfPresent(StationRef.self, forKey: .entry)
        exit = try container.decodeIfPresent(StationRef.self, forKey: .exit)
        sequence = try container.decode(Int.self, forKey: .sequence)
    }
}
