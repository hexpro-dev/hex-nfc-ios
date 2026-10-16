import Foundation
import HexNFCRecords
import SwiftData

/// High-level Library API on top of `SwiftDataStack`. The UI layer only
/// talks to this — never directly to `ModelContext`. Two reasons:
///
/// 1. Tests can swap in an in-memory stack via `SwiftDataStack.inMemory()`.
/// 2. The `.hexnfc` export/import format stays anchored to the public JSON
///    shape rather than the on-disk SwiftData schema.
@MainActor
public final class LibraryRepository {
    public let stack: SwiftDataStack
    /// Device-local store for the secrets belonging to a **preset**, keyed by
    /// preset UUID. Defaults to the Keychain in production; tests inject
    /// `InMemoryProtectionCredentialStore`. Deleting a preset deletes its
    /// credential (see `deletePreset`).
    public let credentials: ProtectionCredentialStoring

    /// Device-local store for the secrets belonging to a **physical tag**, keyed
    /// by UID.
    ///
    /// Deliberately separate from `credentials`, and deliberately not tied to
    /// any preset's lifetime: a key programmed onto a tag outlives the preset
    /// that suggested it, and on an NTAG424 DNA or a MIFARE Ultralight C losing
    /// it means losing the tag. Nothing in this type deletes from it. See the
    /// note on `deletePreset` and `purgeStale`.
    public let tagCredentials: TagCredentialStoring

    public init(
        stack: SwiftDataStack,
        credentials: ProtectionCredentialStoring = KeychainProtectionCredentialStore(),
        tagCredentials: TagCredentialStoring = KeychainTagCredentialStore()
    ) {
        self.stack = stack
        self.credentials = credentials
        self.tagCredentials = tagCredentials
    }

    // MARK: - Presets

    @discardableResult
    public func insertPreset(
        name: String,
        records: [NDEFRecord],
        notes: String = "",
        requiredCapabilitiesRaw: UInt32 = 0,
        iconHexSlice: Int = 0,
        protection: TagProtection? = nil,
        credential: ProtectionCredential? = nil
    ) throws -> Preset {
        // `hasStoredCredential` must reflect whether we actually stash a secret,
        // so the write flow knows if it can apply protection without re-prompting.
        var resolvedProtection = protection
        resolvedProtection?.hasStoredCredential = (credential != nil)

        let preset = Preset(
            name: name,
            notes: notes,
            records: records,
            requiredCapabilitiesRaw: requiredCapabilitiesRaw,
            iconHexSlice: iconHexSlice,
            protection: resolvedProtection
        )
        stack.context.insert(preset)
        try stack.context.save()
        if let credential {
            try credentials.save(credential, for: preset.id)
        }
        return preset
    }

    public func fetchPresets() throws -> [Preset] {
        var descriptor = FetchDescriptor<Preset>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.includePendingChanges = true
        return try stack.context.fetch(descriptor)
    }

    public func deletePreset(_ preset: Preset) throws {
        let id = preset.id
        stack.context.delete(preset)
        try stack.context.save()
        // Drop the orphaned protection secret, if any.
        //
        // **`tagCredentials` is deliberately not touched here**, and this is the
        // obvious next tidy-up, which is why the note is worth its lines. A
        // preset is an intention; a tag credential describes a physical tag that
        // is still out there with a key on it. Deleting a preset must never
        // delete the only key to every tag somebody locked with it, because
        // neither chip family that uses one has a factory reset. The one place a
        // tag credential is dropped is a proven-clean removal, and the one place
        // a user can drop it by hand is an explicit "forget this tag's key".
        credentials.delete(for: id)
    }

    @discardableResult
    public func duplicatePreset(_ preset: Preset) throws -> Preset {
        let copy = Preset(
            name: "\(preset.name) (copy)",
            notes: preset.notes,
            createdAt: Date(),
            updatedAt: Date(),
            records: preset.decodedRecords(),
            requiredCapabilitiesRaw: preset.requiredCapabilitiesRaw,
            iconHexSlice: preset.iconHexSlice,
            protection: preset.decodedProtection()
        )
        stack.context.insert(copy)
        try stack.context.save()
        // Carry the protection secret across to the copy so it stays writable.
        if let credential = credentials.load(for: preset.id) {
            try credentials.save(credential, for: copy.id)
        }
        return copy
    }

    public func renamePreset(_ preset: Preset, to newName: String) throws {
        preset.name = newName
        preset.updatedAt = Date()
        try stack.context.save()
    }

    // MARK: - History

    /// Number of (unpinned) history rows kept. Older unpinned scans past this
    /// are trimmed after each insert.
    public nonisolated static let historyLimit = 50

    @discardableResult
    public func recordScan(
        chipFamily: String,
        uidHex: String,
        records: [NDEFRecord],
        chipName: String? = nil,
        manufacturer: String? = nil,
        totalBytes: Int = 0,
        capabilitiesRaw: UInt32 = 0,
        transitCard: TransitCard? = nil,
        protection: TagProtection? = nil,
        at date: Date = Date(),
        limit: Int = LibraryRepository.historyLimit
    ) throws -> HistoryEntry {
        let entry = HistoryEntry(
            scannedAt: date,
            chipFamily: chipFamily,
            uidHex: uidHex,
            records: records,
            chipName: chipName,
            manufacturer: manufacturer,
            totalBytes: totalBytes,
            capabilitiesRaw: capabilitiesRaw,
            transitCard: transitCard,
            protection: protection
        )

        // Dedupe exact duplicates: if an identical snapshot already exists,
        // re-float it to `date` rather than stacking another copy. This keeps a
        // tag you keep tapping from flooding the list.
        // Narrow by UID before fingerprinting: `contentFingerprint` parses and
        // re-serialises each row's snapshot JSON, and doing that for all 50 rows
        // on every scan is work the tap does not need. A duplicate necessarily
        // shares the UID, which is a plain string compare.
        let fingerprint = entry.contentFingerprint
        let candidates = try fetchHistory().filter { $0.uidHex == entry.uidHex }
        if let existing = candidates.first(where: { $0.contentFingerprint == fingerprint }) {
            existing.scannedAt = date
            try stack.context.save()
            return existing
        }

        stack.context.insert(entry)
        try stack.context.save()
        try trimHistory(limit: limit)
        return entry
    }

    /// Keep only the `limit` most recent *unpinned* entries; pinned rows are
    /// always retained and don't count against the cap.
    @discardableResult
    public func trimHistory(limit: Int = LibraryRepository.historyLimit) throws -> Int {
        var descriptor = FetchDescriptor<HistoryEntry>(
            predicate: #Predicate { $0.pinned == false },
            sortBy: [SortDescriptor(\.scannedAt, order: .reverse)]
        )
        descriptor.includePendingChanges = true
        let unpinned = try stack.context.fetch(descriptor)
        guard unpinned.count > limit else { return 0 }
        let overflow = Array(unpinned[limit...])
        for entry in overflow {
            stack.context.delete(entry)
        }
        try stack.context.save()
        return overflow.count
    }

    public func fetchHistory(includeUnpinned: Bool = true) throws -> [HistoryEntry] {
        var descriptor = if includeUnpinned {
            FetchDescriptor<HistoryEntry>(
                sortBy: [SortDescriptor(\.scannedAt, order: .reverse)]
            )
        } else {
            FetchDescriptor<HistoryEntry>(
                predicate: #Predicate { $0.pinned == true },
                sortBy: [SortDescriptor(\.scannedAt, order: .reverse)]
            )
        }
        descriptor.includePendingChanges = true
        return try stack.context.fetch(descriptor)
    }

    public func togglePin(_ entry: HistoryEntry) throws {
        entry.pinned.toggle()
        try stack.context.save()
    }

    public func deleteHistory(_ entry: HistoryEntry) throws {
        stack.context.delete(entry)
        try stack.context.save()
    }

    /// Drop unpinned history older than 90 days. Called on app launch and
    /// after every successful scan-history insert.
    ///
    /// **It must never reach `tagCredentials`.** An old history entry means the
    /// tag has not been seen for a while, which is not evidence that its key is
    /// no longer needed. A record is about 90 bytes; a tag nobody can re-key is
    /// permanent.
    @discardableResult
    public func purgeStale(now: Date = Date()) throws -> Int {
        let cutoff = now.addingTimeInterval(-90 * 24 * 60 * 60)
        let descriptor = FetchDescriptor<HistoryEntry>(
            predicate: #Predicate { $0.pinned == false && $0.scannedAt < cutoff }
        )
        let stale = try stack.context.fetch(descriptor)
        for entry in stale {
            stack.context.delete(entry)
        }
        if !stale.isEmpty {
            try stack.context.save()
        }
        return stale.count
    }

    // MARK: - .hexnfc envelope

    /// JSON wrapper used for share-sheet exports and incoming imports.
    ///
    /// Version history:
    ///   - **1** — name/notes/records.
    ///   - **2** — adds optional `protection` *settings* (never the secret).
    ///     v1 files still decode: `protection` is optional → `nil`.
    ///   - **3** — `protection` may carry a Type-4/Type-5 `style`. v1/v2 still
    ///     decode (`style` is optional → Type-2). A new *Type-2* export is
    ///     byte-identical to v2 (`style` stays nil), so cross-app interop holds;
    ///     the bump is only meaningful for Type-4/Type-5 presets.
    public struct HexnfcEnvelope: Codable, Sendable {
        public let version: Int
        public let name: String
        public let notes: String
        public let records: [NDEFRecord]
        public let exportedAt: Date
        /// Protection settings only. The password/PACK stay device-local in the
        /// Keychain and are never written into an export, so an imported preset
        /// carries `hasStoredCredential == false` and re-prompts on first write.
        public let protection: TagProtection?

        public init(
            version: Int = 3,
            name: String,
            notes: String = "",
            records: [NDEFRecord],
            exportedAt: Date = Date(),
            protection: TagProtection? = nil
        ) {
            self.version = version
            self.name = name
            self.notes = notes
            self.records = records
            self.exportedAt = exportedAt
            self.protection = protection
        }
    }

    public func exportAsHexnfc(_ preset: Preset) throws -> Data {
        // Carry protection settings, but force `hasStoredCredential = false`:
        // the secret never leaves the device, so the importer must re-enter it.
        //
        // The pinned start page is already gone: `decodedProtection` drops it,
        // which also cleans a row written before that rule existed. See
        // `Preset.unpinningStartPage`.
        var protection = preset.decodedProtection()
        protection?.hasStoredCredential = false
        let envelope = HexnfcEnvelope(
            name: preset.name,
            notes: preset.notes,
            records: preset.decodedRecords(),
            protection: protection
        )
        return try JSONEncoder.preset.encode(envelope)
    }

    @discardableResult
    public func importHexnfc(_ data: Data) throws -> Preset {
        let envelope = try JSONDecoder.preset.decode(HexnfcEnvelope.self, from: data)
        // No credential travels in a `.hexnfc` file — import settings only.
        return try insertPreset(
            name: envelope.name,
            records: envelope.records,
            notes: envelope.notes,
            protection: envelope.protection
        )
    }
}
