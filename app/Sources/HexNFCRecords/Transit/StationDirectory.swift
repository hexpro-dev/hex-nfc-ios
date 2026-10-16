import Foundation

/// One station's mapping from raw FeliCa "saibane" codes to a human name.
///
/// **Provenance matters** (see `docs/internal/station-pack-provenance.md`): the
/// code↔name correspondence is an uncopyrightable *fact*, but a particular
/// compiled table can carry rights. Entries in the shipped packs are
/// independently assembled/verified from cleanly-licensed sources — Wikidata
/// (CC0) and first-party field taps in `StationPack.cc0.json`, ODPT (CC BY 4.0)
/// in `StationPack.odpt.json` — never copied verbatim from a denno.net-lineage /
/// GPL community table.
public struct StationEntry: Hashable, Sendable, Codable {
    public let line: UInt8
    public let station: UInt8
    /// Region code (a history block's byte 15: Kanto, Kansai, JR and so on).
    ///
    /// Part of the lookup key. `nil` means "no region recorded", which only ever
    /// matches as a last resort, so a row for one region cannot claim another
    /// region's code. Setting it wrongly changes which cards resolve this entry.
    public let area: UInt8?
    public let name: String
    public let nameRomaji: String?
    public let operatorName: String?
    /// True only when a field tap or primary source confirmed this mapping.
    /// `false` entries are triangulated and surfaced with an "unconfirmed"
    /// indicator in the UI, inviting a tap-confirmation contribution.
    public let verified: Bool
    /// Where the NAME came from (e.g. "Wikidata", "ODPT", "tap"). Drives the
    /// CC0-vs-CC BY attribution split and the merge precedence below.
    public let source: String?

    public init(
        line: UInt8,
        station: UInt8,
        area: UInt8? = nil,
        name: String,
        nameRomaji: String? = nil,
        operatorName: String? = nil,
        verified: Bool = false,
        source: String? = nil
    ) {
        self.line = line
        self.station = station
        self.area = area
        self.name = name
        self.nameRomaji = nameRomaji
        self.operatorName = operatorName
        self.verified = verified
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case line
        case station
        case area
        case name
        case source
        case verified
        case nameRomaji = "name_romaji"
        case operatorName = "operator"
    }

    /// Custom decode so older/partial packs missing `verified`/`source` still
    /// load (defaulting to unverified) instead of failing the whole pack.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        line = try c.decode(UInt8.self, forKey: .line)
        station = try c.decode(UInt8.self, forKey: .station)
        area = try c.decodeIfPresent(UInt8.self, forKey: .area)
        name = try c.decode(String.self, forKey: .name)
        nameRomaji = try c.decodeIfPresent(String.self, forKey: .nameRomaji)
        operatorName = try c.decodeIfPresent(String.self, forKey: .operatorName)
        verified = try c.decodeIfPresent(Bool.self, forKey: .verified) ?? false
        source = try c.decodeIfPresent(String.self, forKey: .source)
    }
}

/// One line's mapping from a raw saibane line code to a human line name.
///
/// Lines are coarser than stations: a single tap on any station of a line
/// confirms the *line* code even when that specific station isn't yet mapped.
/// `StationDirectory` uses this as a **partial fallback** — "Ginza Line · ?"
/// instead of a bare hex code — when the exact `(line,station)` is unknown.
public struct LineEntry: Hashable, Sendable, Codable {
    public let line: UInt8
    /// Region code this line name holds for, matching a history block's byte 15.
    /// `nil` means "no region recorded", which only ever matches as a last
    /// resort so a Kanto name can't claim a Kansai line code.
    public let area: UInt8?
    public let name: String
    public let nameRomaji: String?
    public let operatorName: String?
    public let verified: Bool
    public let source: String?

    public init(
        line: UInt8,
        area: UInt8? = nil,
        name: String,
        nameRomaji: String? = nil,
        operatorName: String? = nil,
        verified: Bool = false,
        source: String? = nil
    ) {
        self.line = line
        self.area = area
        self.name = name
        self.nameRomaji = nameRomaji
        self.operatorName = operatorName
        self.verified = verified
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case line
        case area
        case name
        case source
        case verified
        case nameRomaji = "name_romaji"
        case operatorName = "operator"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        line = try c.decode(UInt8.self, forKey: .line)
        area = try c.decodeIfPresent(UInt8.self, forKey: .area)
        name = try c.decode(String.self, forKey: .name)
        nameRomaji = try c.decodeIfPresent(String.self, forKey: .nameRomaji)
        operatorName = try c.decodeIfPresent(String.self, forKey: .operatorName)
        verified = try c.decodeIfPresent(Bool.self, forKey: .verified) ?? false
        source = try c.decodeIfPresent(String.self, forKey: .source)
    }
}

/// The two pack row types share the fields `precedence(verified:source:)` needs,
/// so one insert helper can merge either.
public protocol PackEntry {
    var verified: Bool { get }
    var source: String? { get }
}

extension StationEntry: PackEntry {}
extension LineEntry: PackEntry {}

/// Resolves Suica-family saibane codes to station names from the bundled,
/// cleanly-licensed packs. Pure and table-driven; returns `nil` for any code the
/// packs don't cover, so callers fall back to the line name (partial) or the raw
/// codes.
///
/// Two license-segregated station packs are merged at load
/// (`StationPack.cc0.json` and `StationPack.odpt.json`), plus the matching line
/// packs. When both cover a code, `precedence(of:)` decides: a verified entry
/// always wins; within a tier, CC0/community data beats ODPT.
public struct StationDirectory: Sendable {
    // Two tiers per pack type.
    //
    // `by*Area` is keyed on (area, line, station) and holds only the rows that
    // declare a region; `by*Any` is keyed on (line, station) alone and holds
    // every row. A saibane code means different things in different regions, so
    // a region-scoped lookup checks its own tier first.
    //
    // `ambiguous*` records the arealess keys that more than one region claims.
    // A region-scoped lookup that misses its own tier will fall back to the
    // arealess tier, which keeps today's single-region pack resolving even if
    // the region byte turns out not to match the `area` values the seed rows
    // carry, but it refuses that fallback for an ambiguous key, because there
    // the fallback would be a coin toss between two real regions.
    private let byKeyArea: [UInt32: StationEntry]
    private let byKeyAny: [UInt32: StationEntry]
    private let ambiguousKeys: Set<UInt32>
    private let byLineArea: [UInt32: LineEntry]
    private let byLineAny: [UInt32: LineEntry]
    private let ambiguousLineKeys: Set<UInt32>

    public init(entries: [StationEntry], lines: [LineEntry] = []) {
        var areaMap: [UInt32: StationEntry] = [:]
        var anyMap: [UInt32: StationEntry] = [:]
        var areasPerKey: [UInt32: Set<UInt8>] = [:]
        anyMap.reserveCapacity(entries.count)
        for entry in entries {
            let anyKey = Self.key(area: nil, line: entry.line, station: entry.station)
            if let area = entry.area {
                Self.insert(entry, into: &areaMap,
                            key: Self.key(area: area, line: entry.line, station: entry.station))
                areasPerKey[anyKey, default: []].insert(area)
            }
            Self.insert(entry, into: &anyMap, key: anyKey)
        }
        byKeyArea = areaMap
        byKeyAny = anyMap
        ambiguousKeys = Set(areasPerKey.filter { $0.value.count > 1 }.keys)

        var areaLines: [UInt32: LineEntry] = [:]
        var anyLines: [UInt32: LineEntry] = [:]
        var lineAreasPerKey: [UInt32: Set<UInt8>] = [:]
        for entry in lines {
            let anyKey = Self.lineKey(area: nil, line: entry.line)
            if let area = entry.area {
                Self.insert(entry, into: &areaLines, key: Self.lineKey(area: area, line: entry.line))
                lineAreasPerKey[anyKey, default: []].insert(area)
            }
            Self.insert(entry, into: &anyLines, key: anyKey)
        }
        byLineArea = areaLines
        byLineAny = anyLines
        ambiguousLineKeys = Set(lineAreasPerKey.filter { $0.value.count > 1 }.keys)
    }

    /// Insert honouring `precedence`; first-loaded wins an exact tie.
    private static func insert<E: PackEntry>(
        _ entry: E,
        into map: inout [UInt32: E],
        key: UInt32
    ) {
        if let existing = map[key] {
            if precedence(verified: entry.verified, source: entry.source)
                > precedence(verified: existing.verified, source: existing.source)
            {
                map[key] = entry
            }
        } else {
            map[key] = entry
        }
    }

    /// Merge precedence when two packs cover the same code: verified beats
    /// unverified (+2); within a tier, non-ODPT (CC0/community) beats ODPT (+1).
    /// First-loaded wins on an exact tie.
    private static func precedence(verified: Bool, source: String?) -> Int {
        (verified ? 2 : 0) + (source != "ODPT" ? 1 : 0)
    }

    public var count: Int {
        byKeyAny.count
    }

    public var lineCount: Int {
        byLineAny.count
    }

    /// Resolve a station entry, or `nil` if the packs don't cover the codes.
    ///
    /// Saibane codes are unique only within a region, so an `area`-matched entry
    /// wins. Failing that the area-agnostic tier answers, which keeps a pack
    /// written before regions were tracked working, *unless* two regions both
    /// claim the code: then there is no honest answer and this returns `nil`, so
    /// the UI shows the raw code and offers to have it named.
    public func entry(area: UInt8?, line: UInt8, station: UInt8) -> StationEntry? {
        let anyKey = Self.key(area: nil, line: line, station: station)
        guard let area else { return byKeyAny[anyKey] }
        if let hit = byKeyArea[Self.key(area: area, line: line, station: station)] {
            return hit
        }
        guard !ambiguousKeys.contains(anyKey) else { return nil }
        return byKeyAny[anyKey]
    }

    /// Area-agnostic lookup, for callers with no region byte to offer.
    public func entry(line: UInt8, station: UInt8) -> StationEntry? {
        entry(area: nil, line: line, station: station)
    }

    /// Convenience: resolve just the station display name.
    public func name(line: UInt8, station: UInt8) -> String? {
        entry(line: line, station: station)?.name
    }

    /// Resolve a line entry (partial fallback when the station is unmapped).
    /// Same region rule as `entry(area:line:station:)`.
    public func lineEntry(area: UInt8?, line: UInt8) -> LineEntry? {
        let anyKey = Self.lineKey(area: nil, line: line)
        guard let area else { return byLineAny[anyKey] }
        if let hit = byLineArea[Self.lineKey(area: area, line: line)] {
            return hit
        }
        guard !ambiguousLineKeys.contains(anyKey) else { return nil }
        return byLineAny[anyKey]
    }

    /// Area-agnostic line lookup.
    public func lineEntry(line: UInt8) -> LineEntry? {
        lineEntry(area: nil, line: line)
    }

    /// Convenience: resolve just the line display name.
    public func lineName(line: UInt8) -> String? {
        lineEntry(line: line)?.name
    }

    /// Lookup key. The high byte distinguishes "no area recorded" (0x00) from a
    /// real area code (0x01 | area), so area 0 and "unknown" never collide.
    private static func key(area: UInt8?, line: UInt8, station: UInt8) -> UInt32 {
        let areaTag: UInt32 = area.map { 0x0100 | UInt32($0) } ?? 0
        return (areaTag << 16) | (UInt32(line) << 8) | UInt32(station)
    }

    private static func lineKey(area: UInt8?, line: UInt8) -> UInt32 {
        key(area: area, line: line, station: 0)
    }

    // MARK: - Bundled packs

    private struct Pack: Decodable {
        let stations: [StationEntry]
    }

    private struct LinePackFile: Decodable {
        let lines: [LineEntry]
    }

    /// The directory loaded from the bundled station + line packs. Each missing
    /// or unreadable pack is skipped (→ fewer entries, raw-code fallback) rather
    /// than crashing, so a packaging slip degrades gracefully.
    public static let bundled: StationDirectory = loadBundled()

    private static func loadBundled() -> StationDirectory {
        // CC0 first so it wins ties against ODPT at equal verification tier.
        var all: [StationEntry] = []
        for name in ["StationPack.cc0", "StationPack.odpt"] {
            guard
                let url = Bundle.module.url(forResource: name, withExtension: "json"),
                let data = try? Data(contentsOf: url),
                let pack = try? JSONDecoder().decode(Pack.self, from: data)
            else { continue }
            all.append(contentsOf: pack.stations)
        }

        var allLines: [LineEntry] = []
        for name in ["LinePack.cc0", "LinePack.odpt"] {
            guard
                let url = Bundle.module.url(forResource: name, withExtension: "json"),
                let data = try? Data(contentsOf: url),
                let pack = try? JSONDecoder().decode(LinePackFile.self, from: data)
            else { continue }
            allLines.append(contentsOf: pack.lines)
        }

        return StationDirectory(entries: all, lines: allLines)
    }
}
