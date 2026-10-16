import Foundation

/// A named, replayable raw command sequence the user can fire at a tag from
/// the Advanced Console. Phase 3 ships the built-in library via
/// `CommandPresetCatalog.builtIn`; user-saved presets land in SwiftData in
/// Phase 4 (an `@Model CommandPreset` in `HexNFCStorage` will wrap this
/// value type).
///
/// `family` is the chip family the preset is intended for. The console
/// shows all presets but greys out ones whose family doesn't match the
/// detected chip — running them anyway is fine, it just primes the user
/// that they're off-spec.
public struct CommandPreset: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let family: TagFamily
    public let sequenceText: String
    public let expectedResponseHex: String?
    public let isBuiltIn: Bool
    public let notes: String?

    public init(
        id: UUID = UUID(),
        name: String,
        family: TagFamily,
        sequenceText: String,
        expectedResponseHex: String? = nil,
        isBuiltIn: Bool = true,
        notes: String? = nil
    ) {
        self.id = id
        self.name = name
        self.family = family
        self.sequenceText = sequenceText
        self.expectedResponseHex = expectedResponseHex
        self.isBuiltIn = isBuiltIn
        self.notes = notes
    }
}
