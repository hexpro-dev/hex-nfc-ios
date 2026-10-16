import Foundation
import Security

/// The secret half of tag protection. The exact material differs by chip family:
/// Type-2 is a 4-byte password + 2-byte PACK; Type-4 (NTAG424 DNA) is a 16-byte
/// AES-128 key + its key slot; Type-5 (ICODE SLIX) is a 4-byte write password and
/// optionally a 4-byte read password. Stored only in the Keychain — never in
/// SwiftData and never in a `.hexnfc` export — so it can't sync to iCloud or leak
/// through a shared file.
public struct ProtectionCredential: Hashable, Sendable {
    /// Family-tagged secret bytes. The owning preset's `TagProtection.style`
    /// carries the matching non-secret settings; this carries only the secret.
    public enum Material: Hashable, Sendable {
        case type2(password: Data, pack: Data)
        case type4(aesKey: Data, keySlot: UInt8)
        case type5(write: Data?, read: Data?)
        /// MIFARE Ultralight C: a 16-byte 2-key 3DES key, stored in **cipher
        /// order** (the form the datasheet and tooling quote). The memory order
        /// the tag's key pages take is derived at write time by
        /// `UltralightCKey`, never persisted, so a blob can't be ambiguous.
        case ultralightC(key: Data)
    }

    public let material: Material

    public init(material: Material) {
        self.material = material
    }

    // MARK: Convenience initializers

    /// Type-2 (the historical default). Kept so existing call sites compile
    /// unchanged.
    public init(password: Data, pack: Data) {
        material = .type2(password: password, pack: pack)
    }

    public init(aesKey: Data, keySlot: UInt8) {
        material = .type4(aesKey: aesKey, keySlot: keySlot)
    }

    public init(slixWrite: Data?, slixRead: Data?) {
        material = .type5(write: slixWrite, read: slixRead)
    }

    public init(ultralightCKey: Data) {
        material = .ultralightC(key: ultralightCKey)
    }

    // MARK: Type-2 convenience accessors (back-compat for existing call sites)

    /// The 4-byte Type-2 password, or empty for other families. Only meaningful
    /// for a `.type2` credential.
    public var password: Data {
        if case .type2(let password, _) = material {
            return password
        }
        return Data()
    }

    /// The 2-byte Type-2 PACK, or empty for other families.
    public var pack: Data {
        if case .type2(_, let pack) = material {
            return pack
        }
        return Data()
    }
}

/// Device-local credential storage, keyed by the owning preset's UUID. Abstracted
/// so tests and previews can use an in-memory store instead of the Keychain.
public protocol ProtectionCredentialStoring: Sendable {
    func save(_ credential: ProtectionCredential, for id: UUID) throws
    func load(for id: UUID) -> ProtectionCredential?
    func delete(for id: UUID)
}

public enum ProtectionCredentialStoreError: Error {
    case keychain(OSStatus)
    case malformed
}

/// Self-describing Keychain blob (de)serialization, shared by the production
/// store. A pre-families blob is exactly 6 bytes (`PWD(4) ++ PACK(2)`) and is read
/// as Type-2; everything written by the families-aware build carries a
/// `0x01` version byte + a family tag, so the two never collide (a tagged Type-2
/// blob is 8 bytes, never 6).
enum ProtectionCredentialBlob {
    private static let version: UInt8 = 0x01
    private enum Tag {
        static let type2: UInt8 = 0x02
        static let type4: UInt8 = 0x04
        static let type5: UInt8 = 0x05
        /// Ultralight C. Deliberately not `0x03` (which would read as "Type-3"
        /// and imply a FeliCa credential we don't have); `0x1A` is the chip's
        /// own AUTHENTICATE opcode, which makes the blob self-explanatory in a
        /// hex dump and cannot collide with a family number.
        static let ultralightC: UInt8 = 0x1A
    }

    private enum Type5Flag {
        static let hasWrite: UInt8 = 0x01
        static let hasRead: UInt8 = 0x02
    }

    static func encode(_ credential: ProtectionCredential) -> Data {
        Data([version]) + encodeMaterial(credential.material)
    }

    /// The family tag plus the material body, without the version byte.
    ///
    /// Split out so the UID-keyed `TagCredentialBlob` can share one codec and
    /// one set of family tags. Two copies of a family mapping is how a family
    /// gets added to one store and not the other, and a tag byte that means two
    /// different things in two files is how a credential decodes into the wrong
    /// shape. The byte layout is unchanged: `encode` is still
    /// `version ‖ tag ‖ body`, which `ProtectionCredentialBlobTests` pins.
    static func encodeMaterial(_ material: ProtectionCredential.Material) -> Data {
        var blob = Data()
        switch material {
        case .type2(let password, let pack):
            blob.append(Tag.type2)
            blob.append(password)
            blob.append(pack)

        case .type4(let aesKey, let keySlot):
            blob.append(Tag.type4)
            blob.append(keySlot)
            blob.append(aesKey)

        case .type5(let write, let read):
            blob.append(Tag.type5)
            var flags: UInt8 = 0
            if write != nil {
                flags |= Type5Flag.hasWrite
            }
            if read != nil {
                flags |= Type5Flag.hasRead
            }
            blob.append(flags)
            if let write {
                blob.append(write)
            }
            if let read {
                blob.append(read)
            }

        case .ultralightC(let key):
            blob.append(Tag.ultralightC)
            blob.append(key)
        }
        return blob
    }

    static func decode(_ blob: Data) -> ProtectionCredential? {
        // Legacy first: a bare 6-byte blob is a pre-families Type-2 credential.
        if blob.count == 6 {
            return ProtectionCredential(password: Data(blob.prefix(4)), pack: Data(blob.suffix(2)))
        }
        let bytes = [UInt8](blob)
        guard bytes.count >= 2, bytes[0] == version else { return nil }
        return decodeMaterial(Data(bytes.dropFirst(1))).map(ProtectionCredential.init(material:))
    }

    /// Inverse of `encodeMaterial`: `tagged` is the family tag plus its body.
    static func decodeMaterial(_ tagged: Data) -> ProtectionCredential.Material? {
        let bytes = [UInt8](tagged)
        guard let tag = bytes.first else { return nil }
        let body = Array(bytes.dropFirst(1))
        switch tag {
        case Tag.type2:
            guard body.count == 6 else { return nil }
            return .type2(password: Data(body.prefix(4)), pack: Data(body.suffix(2)))

        case Tag.type4:
            guard body.count == 17 else { return nil } // slot(1) + key(16)
            return .type4(aesKey: Data(body.dropFirst(1)), keySlot: body[0])

        case Tag.ultralightC:
            guard body.count == 16 else { return nil }
            return .ultralightC(key: Data(body))

        case Tag.type5:
            guard let flags = body.first else { return nil }
            var rest = Array(body.dropFirst(1))
            var write: Data?
            var read: Data?
            if flags & Type5Flag.hasWrite != 0 {
                guard rest.count >= 4 else { return nil }
                write = Data(rest.prefix(4))
                rest.removeFirst(4)
            }
            if flags & Type5Flag.hasRead != 0 {
                guard rest.count >= 4 else { return nil }
                read = Data(rest.prefix(4))
                rest.removeFirst(4)
            }
            return .type5(write: write, read: read)

        default:
            return nil
        }
    }
}

/// Production store. Generic-password Keychain items with
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` so credentials never sync to
/// iCloud / other devices — matching the "settings sync, secret device-only"
/// decision.
public struct KeychainProtectionCredentialStore: ProtectionCredentialStoring {
    private let service: String

    public init(service: String = "pro.hex.nfc.protection") {
        self.service = service
    }

    public func save(_ credential: ProtectionCredential, for id: UUID) throws {
        let blob = ProtectionCredentialBlob.encode(credential)

        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        // Upsert: drop any existing item, then add fresh.
        SecItemDelete(base as CFDictionary)
        var attributes = base
        attributes[kSecValueData as String] = blob
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ProtectionCredentialStoreError.keychain(status)
        }
    }

    public func load(for id: UUID) -> ProtectionCredential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let blob = item as? Data else { return nil }
        return ProtectionCredentialBlob.decode(blob)
    }

    public func delete(for id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        SecItemDelete(query as CFDictionary) // errSecItemNotFound is fine
    }
}

/// In-memory store for tests and previews. Thread-safe via a lock so it can be
/// shared `Sendable`.
public final class InMemoryProtectionCredentialStore: ProtectionCredentialStoring, @unchecked Sendable {
    private var storage: [UUID: ProtectionCredential] = [:]
    private let lock = NSLock()

    public init() {}

    public func save(_ credential: ProtectionCredential, for id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[id] = credential
    }

    public func load(for id: UUID) -> ProtectionCredential? {
        lock.lock()
        defer { lock.unlock() }
        return storage[id]
    }

    public func delete(for id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        storage[id] = nil
    }
}
