import Foundation

/// Bit-packed set of capabilities a chip exposes. Set on a `ConnectedTag` once
/// identification has run; consulted by every operation before it sends bytes.
///
/// Calling, say, `setPassword(...)` on a tag whose capabilities lack
/// `.passwordAuth` is a programming error and throws synchronously with
/// `TagError.capabilityUnsupported(.passwordAuth)` — the UI is responsible for
/// hiding the affordance, this is the belt-and-braces.
public struct TagCapability: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let ndefRead = TagCapability(rawValue: 1 << 0)
    public static let ndefWrite = TagCapability(rawValue: 1 << 1)
    public static let rawTransceive = TagCapability(rawValue: 1 << 2)
    public static let passwordAuth = TagCapability(rawValue: 1 << 3)
    public static let permanentLock = TagCapability(rawValue: 1 << 4)
    public static let memoryRead = TagCapability(rawValue: 1 << 5)
    public static let memoryWrite = TagCapability(rawValue: 1 << 6)
    public static let formatCC = TagCapability(rawValue: 1 << 7)
    public static let signatureRead = TagCapability(rawValue: 1 << 8)
    public static let counterRead = TagCapability(rawValue: 1 << 9)
    public static let sunMessages = TagCapability(rawValue: 1 << 10)
    public static let tamperStatus = TagCapability(rawValue: 1 << 11)
    /// Card carries a readable transit history (FeliCa Read Without Encryption,
    /// e.g. Suica-family service `0x090F`). Drives the transit result view.
    public static let transitRead = TagCapability(rawValue: 1 << 12)
    /// Card is an electronic passport (eMRTD): read its data groups after the
    /// holder supplies the MRZ access key. Read-only; drives the passport view.
    public static let epassportRead = TagCapability(rawValue: 1 << 13)
    /// Chip implements Type-2 `FAST_READ` (`3Ah`), which returns a page *range*
    /// in one frame rather than READ's fixed 4 pages.
    ///
    /// Declared per chip rather than assumed for the whole Type-2 family: the
    /// NTAG 210µ has an ordinary Capability Container but **no** FAST_READ
    /// (NT2L1001_NT2H1001 rev 3.0 Table 5 is an exhaustive command list and
    /// omits `3Ah`), so gating the harness step on the CC page alone would send
    /// a command real silicon NAKs and fail an otherwise clean run.
    public static let fastRead = TagCapability(rawValue: 1 << 14)
    /// Chip authenticates with a **16-byte 2-key 3DES mutual handshake**
    /// (`AUTHENTICATE`, `1Ah`) rather than the NTAG21x 4-byte PWD / 2-byte PACK
    /// exchange. Today only MIFARE Ultralight C.
    ///
    /// Kept distinct from `.passwordAuth` because the two are not
    /// interchangeable anywhere: the credential shape differs (16-byte key vs
    /// 4-byte password), the config bytes sit at a different offset with
    /// inverted polarity, and every seam in this codebase (`TagCredential`,
    /// `ProtectionSpec`, the Keychain blob tag, the protection sheet) is keyed
    /// on credential shape rather than transport. A chip advertising
    /// `.passwordAuth` is claiming the PWD/PACK backend can drive it.
    public static let tripleDESAuth = TagCapability(rawValue: 1 << 15)
}
