import Foundation
import Security

/// What this device believes about **one physical tag's** protection, keyed by
/// the tag's UID.
///
/// ## Why this exists at all
///
/// The only durable credential store before this one is keyed by *preset UUID*
/// (`ProtectionCredentialStore`), and it is written from the "Save as preset"
/// action. That leaves a hole with a tag in it: protect a tag from the editor
/// without saving a preset, dismiss the sheet, and the 16-byte AES or 3DES key
/// the app just programmed onto that tag exists nowhere. The tag is gated behind
/// a credential nobody holds, and neither an NTAG424 DNA nor a MIFARE Ultralight
/// C has a factory reset.
///
/// ## Where the rules about *when* to write live
///
/// Not here. This type stores and fetches; the ordering that makes a stored
/// credential worth anything (file it before the frame that could apply it, keep
/// the previous one behind the new one, delete only on a read-back that proves
/// both the gate down and the credential back at its factory value) is
/// `TagCredentialLedger` in the App layer, along with the asymmetry every one of
/// those follows from. It is stated once there because it was written out by
/// hand at four call sites, and at none at all on the route that needed it most.
///
/// ## Why it is a separate store, not a second key on the existing one
///
/// One store answers "what secret does this preset carry", the other "what
/// secret does this physical tag currently hold". Conflating them means deleting
/// a preset deletes the only key to every tag locked with it, which is a data
/// loss with no undo. Separate protocol, separate Keychain service, separate
/// blob version byte.
///
/// ## What is written, and what is not yet read
///
/// **Nothing in the app reads a record back to open a tag.** As of 2026-09-21
/// the production callers are `WriteFlowModel` and `OperationsFlowModel`, both
/// through `TagCredentialLedger`, so both routes that can change a tag's
/// credential now file it before the frame that applies it. Every recovery path
/// in `HexNFCKit` builds its own candidate list from the credential the caller
/// passed in and the published factory value, and asks this store nothing.
///
/// So half the argument this type exists for is met: the key is kept, and a tag
/// protected by either route is no longer one whose credential exists nowhere.
/// The other half, offering it back, is not built, and two consequences are
/// worth having written down rather than discovered:
///
/// - Reading a record back is a privacy decision as much as a recovery one. The
///   obvious uses (pre-filling an unlock prompt, seeding the "current secret"
///   field when a tag is re-keyed) all put a stored secret into a plain-text
///   field on a screen anyone holding the unlocked phone can open, so none of
///   them is here yet.
/// - Records accumulate. There is no screen listing them and no affordance for
///   forgetting one, so the only deletion is the proven-open one above.
public struct TagCredentialRecord: Hashable, Sendable {
    /// Where the tag is believed to be in a protection change. Diagnostics and
    /// candidate ordering only: no stage is ever treated as proof of what the
    /// tag holds, because only a successful authentication is that.
    public enum Stage: UInt8, Hashable, Sendable {
        /// The gate is believed up and `candidates[0]` is believed to open it.
        case armed = 1
        /// An apply is in flight, or was interrupted. Either `candidates[0]`
        /// (the new credential) or a later entry (the previous one) opens the
        /// tag.
        case applying = 2
        /// A removal is in flight, or was interrupted. The gate may already be
        /// down; the credential may still be the user's.
        case removing = 3
        /// A read-back proved the gate down, but the tag's credential is not
        /// provably the factory one. The tag is usable; it cannot be re-keyed
        /// without one of `candidates`.
        case residue = 4
    }

    public var stage: Stage
    /// Ordered, most likely first. Never empty.
    ///
    /// The order is a property of the record and, as of 2026-09-05, of nothing
    /// else: no code reads this store back, so no tap tries these in this or any
    /// other order. It is kept most-likely-first because the order is what a
    /// recovery path would need and cannot reconstruct later, and because on
    /// Ultralight C it would decide the outcome outright: a refused
    /// `AUTHENTICATE` halts the tag, so one candidate per activation is all the
    /// silicon offers and the first choice is most of the answer.
    public var candidates: [ProtectionCredential.Material]
    /// Last change. Diagnostics only; never used to decide anything.
    public var updatedAt: Date

    /// How many credentials one record keeps. Four covers "the new key, the key
    /// before it, the key before that, and the published factory key", which is
    /// every candidate any recovery path in this app builds.
    public static let maximumCandidates = 4

    public init(
        stage: Stage,
        candidates: [ProtectionCredential.Material],
        updatedAt: Date = Date()
    ) {
        self.stage = stage
        self.candidates = Array(candidates.prefix(Self.maximumCandidates))
        self.updatedAt = updatedAt
    }

    /// Put `material` at the front, dropping any duplicate of it and trimming to
    /// `maximumCandidates`. This is how the previous credential is kept behind
    /// the new one without the list growing without bound.
    public func promoting(_ material: ProtectionCredential.Material, stage: Stage) -> TagCredentialRecord {
        var promoted = [material]
        promoted.append(contentsOf: candidates.filter { $0 != material })
        return TagCredentialRecord(stage: stage, candidates: promoted)
    }
}

/// Device-local, UID-keyed credential storage.
public protocol TagCredentialStoring: Sendable {
    func record(forUID uid: Data) -> TagCredentialRecord?
    func save(_ record: TagCredentialRecord, forUID uid: Data) throws
    /// Call **only** after a read-back proved the tag open and its credential
    /// back at the published factory value. `TagCredentialLedger` is the single
    /// caller today, on the removal path of both flows; there is no "forget this
    /// tag" affordance anywhere in the app, and adding one is what would make a
    /// second rule necessary here.
    func delete(forUID uid: Data)
    /// Every UID with a record.
    ///
    /// No production code calls this. Its only callers are the store tests,
    /// which use it to assert that an upsert replaces a record rather than
    /// adding one and that a delete really removes it. There is no settings
    /// list, and until something offers a stored credential back there is
    /// nothing for one to show.
    func allUIDs() -> [Data]
}

public enum TagCredentialStoreError: Error, Equatable {
    case keychain(OSStatus)
    case malformed
    /// A record with no candidates would say "this tag is protected and I hold
    /// nothing", which is worse than no record at all: it would make a UI show a
    /// key that cannot be offered. Refused at the door.
    case empty
}

/// Self-describing blob.
///
///     0x02 | stage(1) | count(1) | [ len(1) | <tagged material> ] × N | updatedAt(8, BE)
///
/// The version byte is `0x02`, deliberately different from the preset store's
/// `0x01`, so a blob read from the wrong service decodes to `nil` rather than to
/// a plausible credential. The material body is exactly what
/// `ProtectionCredentialBlob.encodeMaterial(_:)` produces, so the two stores
/// share one codec and one set of family tags.
///
/// `updatedAt` is `timeIntervalSinceReferenceDate.bitPattern`, big-endian.
enum TagCredentialBlob {
    static let version: UInt8 = 0x02

    static func encode(_ record: TagCredentialRecord) -> Data {
        var blob = Data([version, record.stage.rawValue, UInt8(record.candidates.count)])
        for material in record.candidates {
            let body = ProtectionCredentialBlob.encodeMaterial(material)
            // A body longer than 255 bytes cannot happen: the largest family is
            // Type-4 at 18 bytes. The clamp is here so a future family cannot
            // silently truncate the length prefix.
            blob.append(UInt8(clamping: body.count))
            blob.append(body)
        }
        var stamp = record.updatedAt.timeIntervalSinceReferenceDate.bitPattern.bigEndian
        withUnsafeBytes(of: &stamp) { blob.append(contentsOf: $0) }
        return blob
    }

    static func decode(_ blob: Data) -> TagCredentialRecord? {
        let bytes = [UInt8](blob)
        guard bytes.count >= 3, bytes[0] == version,
              let stage = TagCredentialRecord.Stage(rawValue: bytes[1])
        else { return nil }
        let count = Int(bytes[2])
        var cursor = 3
        var candidates: [ProtectionCredential.Material] = []
        for _ in 0 ..< count {
            guard cursor < bytes.count else { return nil }
            let length = Int(bytes[cursor])
            cursor += 1
            guard length > 0, cursor + length <= bytes.count else { return nil }
            guard let material = ProtectionCredentialBlob
                .decodeMaterial(Data(bytes[cursor ..< (cursor + length)]))
            else { return nil }
            candidates.append(material)
            cursor += length
        }
        guard candidates.count == count, cursor + 8 <= bytes.count else { return nil }
        var pattern: UInt64 = 0
        for byte in bytes[cursor ..< (cursor + 8)] {
            pattern = (pattern << 8) | UInt64(byte)
        }
        let stamp = Double(bitPattern: pattern)
        guard stamp.isFinite else { return nil }
        return TagCredentialRecord(
            stage: stage,
            candidates: candidates,
            updatedAt: Date(timeIntervalSinceReferenceDate: stamp)
        )
    }
}

/// Production store. Generic-password items,
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and
/// `kSecAttrSynchronizable: false`, so a tag key can never reach iCloud or
/// another device. Nothing here ever touches SwiftData or a `.hexnfc` export.
public struct KeychainTagCredentialStore: TagCredentialStoring {
    private let service: String

    public init(service: String = "pro.hex.nfc.tag-protection") {
        self.service = service
    }

    /// The account string: the UID as uppercase hex with no separators. Stable,
    /// and the same shape the diagnostics print, so a Keychain item can be
    /// matched to a tag in a bug report by eye.
    static func account(forUID uid: Data) -> String {
        uid.map { String(format: "%02X", $0) }.joined()
    }

    static func uid(fromAccount account: String) -> Data? {
        let characters = [Character](account)
        guard !characters.isEmpty, characters.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(characters.count / 2)
        for index in stride(from: 0, to: characters.count, by: 2) {
            guard let byte = UInt8(String(characters[index ... index + 1]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        return Data(bytes)
    }

    private func base(forUID uid: Data) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account(forUID: uid),
            kSecAttrSynchronizable as String: false,
        ]
    }

    public func record(forUID uid: Data) -> TagCredentialRecord? {
        var query = base(forUID: uid)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let blob = item as? Data else { return nil }
        return TagCredentialBlob.decode(blob)
    }

    public func save(_ record: TagCredentialRecord, forUID uid: Data) throws {
        guard !record.candidates.isEmpty else { throw TagCredentialStoreError.empty }
        let query = base(forUID: uid)
        // Upsert, the same shape the preset store uses.
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = TagCredentialBlob.encode(record)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw TagCredentialStoreError.keychain(status)
        }
    }

    public func delete(forUID uid: Data) {
        SecItemDelete(base(forUID: uid) as CFDictionary) // errSecItemNotFound is fine
    }

    public func allUIDs() -> [Data] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
              let entries = items as? [[String: Any]]
        else { return [] }
        // A non-hex account is skipped rather than thrown on: an unreadable
        // neighbour in the same service must not hide every readable one.
        return entries.compactMap { entry in
            (entry[kSecAttrAccount as String] as? String).flatMap(Self.uid(fromAccount:))
        }
    }
}

/// Tests and previews.
public final class InMemoryTagCredentialStore: TagCredentialStoring, @unchecked Sendable {
    private var storage: [Data: TagCredentialRecord] = [:]
    private var saves = 0
    private let lock = NSLock()

    public init() {}

    /// How many times `save` has been called.
    ///
    /// A test hook with a purpose: the rule this store exists to enforce is that
    /// the credential is written **before** the frame that could apply it, and
    /// the only way to assert an ordering is to count.
    public var saveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return saves
    }

    public func record(forUID uid: Data) -> TagCredentialRecord? {
        lock.lock()
        defer { lock.unlock() }
        return storage[uid]
    }

    public func save(_ record: TagCredentialRecord, forUID uid: Data) throws {
        guard !record.candidates.isEmpty else { throw TagCredentialStoreError.empty }
        lock.lock()
        defer { lock.unlock() }
        storage[uid] = record
        saves += 1
    }

    public func delete(forUID uid: Data) {
        lock.lock()
        defer { lock.unlock() }
        storage[uid] = nil
    }

    public func allUIDs() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return Array(storage.keys)
    }
}
