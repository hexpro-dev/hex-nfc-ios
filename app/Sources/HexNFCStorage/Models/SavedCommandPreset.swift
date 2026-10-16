import Foundation
import SwiftData

/// A user-saved raw-command preset. Mirrors `CommandPreset` from
/// `HexNFCKit` (value type) but lives on disk. The Advanced Console reads
/// these in addition to the built-in catalog when the user is online.
///
/// We don't reuse the value type directly because SwiftData wants `@Model`
/// classes, not value-type-backed wrappers — and the built-in catalog
/// shouldn't be storage-coupled.
/// **CloudKit shape.** Optional-or-defaulted throughout, no unique constraint:
/// mirroring rejects `@Attribute(.unique)` and requires a default on every
/// non-optional attribute.
@Model
public final class SavedCommandPreset {
    public var id: UUID = UUID()
    public var name: String = ""
    /// Free-text chip family — matches `TagFamily.shortName` for display.
    public var familyShortName: String = ""
    public var sequenceText: String = ""
    public var expectedResponseHex: String?
    public var notes: String?
    public var createdAt: Date = Date.distantPast

    public init(
        id: UUID = UUID(),
        name: String,
        familyShortName: String,
        sequenceText: String,
        expectedResponseHex: String? = nil,
        notes: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.familyShortName = familyShortName
        self.sequenceText = sequenceText
        self.expectedResponseHex = expectedResponseHex
        self.notes = notes
        self.createdAt = createdAt
    }
}
