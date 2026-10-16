import Foundation
import HexNFCRecords
import SwiftData

/// One row in the scan history. Auto-populated by the scan flow on every
/// successful read; deduped against the existing rows and capped at the 50
/// most recent (unpinned) entries. The plan's brand promise is "no analytics" —
/// history lives only on-device, in the app's SwiftData store, and (optionally)
/// in the user's own iCloud DB.
///
/// Each row is a *full snapshot* of the tap: the chip identity, its memory and
/// capabilities, the decoded NDEF records, and — for Suica-family cards — the
/// decoded transit card. That's enough to re-open the exact same screen the
/// live scan produced without the tag present.
/// **CloudKit shape.** Optional-or-defaulted on every stored property, and no
/// `@Attribute(.unique)`: mirroring rejects unique constraints and needs a
/// default for each non-optional attribute. History dedup never relied on the
/// constraint — it compares `contentFingerprint` in `LibraryRepository`.
@Model
public final class HistoryEntry {
    public var id: UUID = UUID()
    public var scannedAt: Date = Date.distantPast
    /// Free-text chip family — `"NTAG215"`, `"NTAG424 DNA"`, `"ISO 15693"`.
    /// We don't bind to the `TagFamily` enum because adding cases there
    /// shouldn't migrate the on-disk history.
    public var chipFamily: String = ""
    /// Lowercased UID without separators, e.g. `"04a1b2c3d4e5f6"`. Easy to
    /// search; we re-format with `:` separators at render time (`displayUID`).
    public var uidHex: String = ""
    public var recordsJSONSnapshot: Data = Data()
    public var pinned: Bool = false

    // MARK: Full-snapshot fields

    //
    // Added so re-opening a history row shows the same metadata the live scan
    // did. All are optional or defaulted so SwiftData can lightweight-migrate
    // stores written before this change.

    /// Specific chip model (e.g. `"NTAG215"`) when identification resolved one,
    /// as opposed to just the `chipFamily`. `nil` for older rows / blank chips.
    public var chipName: String?
    /// Chip manufacturer (e.g. `"NXP Semiconductors"`), if known.
    public var manufacturer: String?
    /// Total user memory in bytes, or `0` when unknown (e.g. FeliCa).
    public var totalBytes: Int = 0
    /// Raw `TagCapability` bitmask captured at scan time. Re-localised to a
    /// "Supports" summary on read so it survives a language change.
    public var capabilitiesRaw: UInt32 = 0
    /// JSON-encoded `TransitCard` when the scan was a transit IC card. `nil`
    /// for ordinary NDEF / blank tags. Lets the row re-open the transit view.
    public var transitCardJSONSnapshot: Data?
    /// JSON-encoded `TagProtection` *settings* observed for this tap (e.g. the
    /// tag was write-protected from page 4). Settings only — the password is
    /// never logged to history. `nil` for unprotected scans.
    public var protectionJSONSnapshot: Data?

    public init(
        id: UUID = UUID(),
        scannedAt: Date = Date(),
        chipFamily: String,
        uidHex: String,
        records: [NDEFRecord] = [],
        pinned: Bool = false,
        chipName: String? = nil,
        manufacturer: String? = nil,
        totalBytes: Int = 0,
        capabilitiesRaw: UInt32 = 0,
        transitCard: TransitCard? = nil,
        protection: TagProtection? = nil
    ) {
        self.id = id
        self.scannedAt = scannedAt
        self.chipFamily = chipFamily
        self.uidHex = uidHex.lowercased().replacingOccurrences(of: ":", with: "")
        recordsJSONSnapshot = (try? JSONEncoder.preset.encode(records)) ?? Data()
        self.pinned = pinned
        self.chipName = chipName
        self.manufacturer = manufacturer
        self.totalBytes = totalBytes
        self.capabilitiesRaw = capabilitiesRaw
        transitCardJSONSnapshot = transitCard.flatMap { try? JSONEncoder.preset.encode($0) }
        protectionJSONSnapshot = protection.flatMap { try? JSONEncoder.preset.encode($0) }
    }

    public func decodedRecords() -> [NDEFRecord] {
        guard !recordsJSONSnapshot.isEmpty else { return [] }
        return (try? JSONDecoder.preset.decode([NDEFRecord].self, from: recordsJSONSnapshot)) ?? []
    }

    public func decodedTransitCard() -> TransitCard? {
        guard let data = transitCardJSONSnapshot, !data.isEmpty else { return nil }
        return try? JSONDecoder.preset.decode(TransitCard.self, from: data)
    }

    public func decodedProtection() -> TagProtection? {
        guard let data = protectionJSONSnapshot, !data.isEmpty else { return nil }
        return try? JSONDecoder.preset.decode(TagProtection.self, from: data)
    }

    /// `true` when this row holds no protection reading at all, so re-opening it
    /// may not present the tag as unprotected.
    ///
    /// A scan that read an unprotected tag stores `TagProtection.none`, which is
    /// a finding and reads as "Off". A missing snapshot is not that. It covers
    /// three cases, and the row does not record which: the protection read was
    /// refused (`ScanFlowModel.protectionReadFailed`), the chip has no
    /// protection backend to report (harmless, the editor hides the card for
    /// those), or the row predates the field. All three are honestly "unknown",
    /// and rendering any of them as "Off" is the same trade the live scan path
    /// stopped making after the refused read on 2026-08-14: a state we never
    /// learned, stated as a fact.
    ///
    /// It gates more than the padlock. The Protection card seeds its secret
    /// fields from `ProtectionCardSeed`, which treats a tag reporting no
    /// protection as safe to fill with a delivery password or a freshly
    /// generated key, and a tag nothing has read is not a tag proven bare.
    public var protectionIsUnknown: Bool {
        decodedProtection() == nil
    }

    /// Best label for a list row: the specific chip model if identified, else
    /// the family string.
    public var displayName: String {
        if let chipName, !chipName.isEmpty {
            return chipName
        }
        return chipFamily
    }

    /// UID re-formatted for display: uppercase, colon-delimited every 2 chars
    /// (matches the live-scan `Data.hexString` rendering).
    public var displayUID: String {
        var output = ""
        for (i, c) in uidHex.uppercased().enumerated() {
            if i > 0, i % 2 == 0 {
                output.append(":")
            }
            output.append(c)
        }
        return output
    }

    /// Stable signature of everything that makes a scan "the same tap": chip
    /// identity, memory, capabilities, records, and transit data — but not the
    /// timestamp or pin flag. Two scans of an unchanged tag share this, which is
    /// how `recordScan` collapses exact duplicates. base64 keeps it deterministic
    /// across launches (unlike `Data`/`String` hashValues, which are seeded).
    public var contentFingerprint: String {
        [
            uidHex,
            chipFamily,
            chipName ?? "",
            manufacturer ?? "",
            String(totalBytes),
            String(capabilitiesRaw),
            Self.contentKey(of: recordsJSONSnapshot),
            Self.contentKey(of: transitCardJSONSnapshot ?? Data()),
            Self.contentKey(of: protectionJSONSnapshot ?? Data()),
        ].joined(separator: "|")
    }

    /// A snapshot's JSON reduced to the part that describes the *tag*, for use
    /// in `contentFingerprint`.
    ///
    /// Every record payload struct carries a `var id: UUID` that the decoder
    /// mints fresh on each read (`NDEFCodec` builds `TextRecord(text:)` /
    /// `URIRecord(uri:)` with no id), and the synthesized `Codable` encodes it.
    /// Hashing the raw snapshot therefore produced a different fingerprint for
    /// every tap of the same physical tag, so the dedup in
    /// `LibraryRepository.recordScan` never matched and tapping one tag five
    /// times left five identical rows, pushing older scans out of the 50-row cap.
    ///
    /// Keys are dropped by name rather than by changing the wire format, so
    /// existing stores and `.hexnfc` exports keep decoding unchanged. Output is
    /// key-sorted so two encodings of the same content agree.
    static func contentKey(of json: Data) -> String {
        guard !json.isEmpty else { return "" }
        guard
            let parsed = try? JSONSerialization.jsonObject(with: json),
            let canonical = try? JSONSerialization.data(
                withJSONObject: stripIdentifiers(parsed),
                options: [.sortedKeys]
            )
        else {
            // Unparseable snapshot: fall back to the raw bytes rather than
            // collapsing every such row onto one fingerprint.
            return json.base64EncodedString()
        }
        return canonical.base64EncodedString()
    }

    /// Recursively drop every `id` key. Checked against `HexNFCRecords`: every
    /// `id` in the record models is a per-decode `UUID`, never tag content.
    private static func stripIdentifiers(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            out.reserveCapacity(dict.count)
            for (key, inner) in dict where key != "id" {
                out[key] = stripIdentifiers(inner)
            }
            return out
        }
        if let array = value as? [Any] {
            return array.map(stripIdentifiers)
        }
        return value
    }
}
