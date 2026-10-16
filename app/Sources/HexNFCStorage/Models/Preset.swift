import Foundation
import HexNFCRecords
import SwiftData

/// A user-saved tag image — name + the list of records, encoded as JSON.
/// Records are stored as `Data` to dodge a relational explosion across the
/// 18 record cases. Trade-off: changes to record schema require a one-time
/// migration of all stored presets. We accept that — schema churn happens
/// in two-week sprints, not daily.
/// **CloudKit shape.** Every stored property is either optional or carries a
/// declaration-site default, and none is `@Attribute(.unique)`: CloudKit
/// mirroring rejects unique constraints outright and requires a default for
/// every non-optional attribute. Nothing depended on the constraint anyway —
/// ids are freshly minted per insert and `LibraryRepository` works off object
/// references, never an upsert-by-id.
@Model
public final class Preset {
    public var id: UUID = UUID()
    public var name: String = ""
    public var notes: String = ""
    public var createdAt: Date = Date.distantPast
    public var updatedAt: Date = Date.distantPast
    /// JSON-encoded `[NDEFRecord]`. Decode via `decodedRecords()` on read,
    /// `setRecords(_:)` on write — both round-trip through the canonical
    /// codec so the on-disk form matches `.hexnfc` exports byte-for-byte.
    public var recordsJSON: Data = Data()
    /// Bit-packed `TagCapability` rawValue the records require to write.
    /// Lets the Library screen surface "this preset needs an NTAG215" warnings.
    public var requiredCapabilitiesRaw: UInt32 = 0
    /// Which third of the Hex Pro logo represents this preset visually.
    /// 0 = outer frame, 1 = caret, 2 = inverted caret. The Library cell
    /// renders the matching slice as the preset's icon.
    public var iconHexSlice: Int = 0
    /// JSON-encoded `TagProtection` *settings* (password-protect parameters),
    /// or `nil` for an unprotected preset. The secret (PWD/PACK) is **not**
    /// here — it lives in the Keychain keyed by `id`. Optional so SwiftData can
    /// lightweight-migrate stores written before this field existed.
    public var protectionJSON: Data?

    public init(
        id: UUID = UUID(),
        name: String,
        notes: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        records: [NDEFRecord] = [],
        requiredCapabilitiesRaw: UInt32 = 0,
        iconHexSlice: Int = 0,
        protection: TagProtection? = nil
    ) {
        self.id = id
        self.name = name
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        recordsJSON = (try? JSONEncoder.preset.encode(records)) ?? Data()
        self.requiredCapabilitiesRaw = requiredCapabilitiesRaw
        self.iconHexSlice = iconHexSlice
        protectionJSON = protection
            .map(Self.unpinningStartPage)
            .flatMap { try? JSONEncoder.preset.encode($0) }
    }

    /// Decode the stored `recordsJSON` payload back into records. Returns an
    /// empty array if the blob is empty or malformed — callers should not
    /// hard-fail on a single corrupted preset.
    public func decodedRecords() -> [NDEFRecord] {
        guard !recordsJSON.isEmpty else { return [] }
        return (try? JSONDecoder.preset.decode([NDEFRecord].self, from: recordsJSON)) ?? []
    }

    public func setRecords(_ records: [NDEFRecord]) {
        recordsJSON = (try? JSONEncoder.preset.encode(records)) ?? Data()
        updatedAt = Date()
    }

    /// Decode the stored protection settings, or `nil` if this preset is
    /// unprotected (or the blob is malformed).
    ///
    /// Normalised on the way out as well as on the way in, because the way in
    /// only covers rows this build wrote. A preset saved before this rule, or
    /// one arriving from another device over iCloud, still holds whatever it
    /// held.
    public func decodedProtection() -> TagProtection? {
        guard let data = protectionJSON, !data.isEmpty else { return nil }
        guard let decoded = try? JSONDecoder.preset.decode(TagProtection.self, from: data) else { return nil }
        return Self.unpinningStartPage(decoded)
    }

    public func setProtection(_ protection: TagProtection?) {
        protectionJSON = protection
            .map(Self.unpinningStartPage)
            .flatMap { try? JSONEncoder.preset.encode($0) }
        updatedAt = Date()
    }

    /// The same settings with any pinned AUTH0 dropped, so the page is resolved
    /// against whichever chip the preset is replayed onto.
    ///
    /// A preset is the one protection row that is deliberately not about a tag.
    /// It replays across a stack from the Library, it travels in a `.hexnfc`
    /// export and it syncs through iCloud, and `protectFromPage` is an absolute
    /// page number, so the same value means a different fraction of every chip
    /// it lands on.
    ///
    /// Nobody has to have chosen that number for it to get here. A scan of a
    /// tag somebody else armed from page 16 reads AUTH0 back as a reading,
    /// `EditFlowModel` rebases it into the editor's protection on purpose (the
    /// editor is about that tag, where the page is a fact worth keeping), and
    /// "Save as preset" then stores it verbatim. The Protection card's start
    /// page control lives inside a disclosure group that opens closed and the
    /// save sheet never shows a page at all, so the number can cross into a
    /// preset without ever being on screen. Replayed over a stack of blank
    /// NTAG21x it arms each one from page 16 and leaves pages 4 to 15 writable,
    /// and every check downstream agrees: the driver reads AUTH0 back at 16,
    /// which is exactly what it was told to write, and reports success.
    ///
    /// Dropping it rather than refusing it, for the reason `ProtectionSpec.make`
    /// gives for pinning a read gate: this is the batch path, there is no screen
    /// here to carry a refusal, and `nil` resolves to the chip's first data page,
    /// which gates more of the tag than the pinned number rather than less.
    ///
    /// The editor is untouched. A start page chosen for the tag in hand still
    /// reaches `ProtectionSpec.make` through `EditFlowModel.pendingProtection`,
    /// which never goes near a `Preset`.
    static func unpinningStartPage(_ protection: TagProtection) -> TagProtection {
        var result = protection
        result.protectFromPage = nil
        switch protection.style {
        case .type2(var settings):
            settings.protectFromPage = nil
            result.style = .type2(settings)

        case .ultralightC(var settings):
            settings.protectFromPage = nil
            result.style = .ultralightC(settings)

        case .type4, .type5, nil:
            break
        }
        return result
    }
}

// MARK: - Shared coders

extension JSONEncoder {
    static let preset: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

extension JSONDecoder {
    static let preset: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
