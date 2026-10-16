import Foundation

/// A MIFARE Ultralight C authentication key, which exists in **two different
/// byte orders** that must never be confused.
///
/// The card stores the 16 bytes across pages 2Ch–2Fh with each 8-byte half
/// byte-reversed relative to the value handed to the 3DES cipher:
///
///     memory[2Ch] = K[7]  K[6]  K[5]  K[4]
///     memory[2Dh] = K[3]  K[2]  K[1]  K[0]
///     memory[2Eh] = K[15] K[14] K[13] K[12]
///     memory[2Fh] = K[11] K[10] K[9]  K[8]
///
/// The default key is the clearest illustration, and the reason the two forms
/// get mixed up in the wild:
///
///     memory order   42 52 45 41 4B 4D 45 49 46 59 4F 55 43 41 4E 21  "BREAKMEIFYOUCAN!"
///     cipher order   49 45 4D 4B 41 45 52 42 21 4E 41 43 55 4F 59 46  "IEMKAERB!NACUOYF"
///
/// The cipher-order value is what the datasheet's worked example uses and what
/// Proxmark3's `hf mfu setkey --key` takes, so it is the form most references
/// quote, which is exactly how it ends up written into memory by mistake.
///
/// **Why this is a type and not a convention.** Writing the key in the wrong
/// order, combined with a lowered AUTH0, locks a tag out permanently. A raw
/// `Data` passed between `authenticate` and `writeKey` carries no evidence of
/// which order it is in, and both orders are 16 valid bytes, so the mistake is
/// invisible at every call site and only shows up on silicon. Making the two
/// orders separate, named accessors on one value means a caller has to say
/// which one it means, and the conversion exists in exactly one place.
///
/// Source: NXP MF0ICU2 rev 3.3 §7.5.7 (Tables 10, 11) and §7.5.10 (Table 13).
/// Note that **Table 10 contradicts the worked example directly beneath it**;
/// the example and Table 11 are correct. See `docs/internal/chip-config-pages.md`.
public struct UltralightCKey: Hashable, Sendable {
    /// The 16 bytes in the order the 3DES cipher consumes them (`K1‖K2`).
    public let cipherOrder: Data

    /// The 16 bytes in the order they sit in pages 2Ch–2Fh, i.e. the bytes a
    /// `WRITE` actually puts on the wire.
    public var memoryOrder: Data {
        Self.swappingHalves(cipherOrder)
    }

    /// Build from a key in cipher order (the form the datasheet example and
    /// most tooling quote).
    public init(cipherOrder bytes: Data) throws {
        guard bytes.count == Self.byteCount else {
            // Deliberately reports the length only. This is a secret, so the
            // diagnostics string (which is surfaced in the UI on a long-press
            // and pasted into bug reports) must never carry the bytes.
            throw TagError.protocolError(
                "An Ultralight C key is 16 bytes",
                diagnostics: "got \(bytes.count) bytes"
            )
        }
        cipherOrder = bytes
    }

    /// Build from the raw bytes as read from (or destined for) pages 2Ch–2Fh.
    public init(memoryOrder bytes: Data) throws {
        try self.init(cipherOrder: Self.swappingHalves(bytes))
    }

    public static let byteCount = 16

    /// Reverse each 8-byte half. This is an **involution**: applying it twice
    /// returns the original, which is why one function converts in both
    /// directions and why `UltralightCKeyTests` asserts round-tripping.
    static func swappingHalves(_ bytes: Data) -> Data {
        guard bytes.count == byteCount else { return bytes }
        let flat = [UInt8](bytes)
        return Data(flat[0 ..< 8].reversed() + flat[8 ..< 16].reversed())
    }

    /// The key every Ultralight C leaves the factory with (rev 3.3 Table 13),
    /// ASCII `BREAKMEIFYOUCAN!` as it sits in memory.
    ///
    /// Public because it is a published constant, not a secret: it is in the
    /// datasheet, in Proxmark3's default table, and on every unpersonalised
    /// tag. It is the key we authenticate with before writing a real one, and
    /// the key we restore when removing protection.
    public static let factoryDefault: UltralightCKey = // Force-try is safe and deliberate: a fixed 16-byte literal.
        // swiftlint:disable:next force_try
        try! UltralightCKey(memoryOrder: Data([
            0x42, 0x52, 0x45, 0x41, 0x4B, 0x4D, 0x45, 0x49,
            0x46, 0x59, 0x4F, 0x55, 0x43, 0x41, 0x4E, 0x21,
        ]))

    /// `true` when this is the published factory key, i.e. the tag is not
    /// personalised and offers no real protection. Used to warn rather than to
    /// refuse: authenticating with it is exactly how a virgin tag is opened.
    public var isFactoryDefault: Bool {
        self == Self.factoryDefault
    }
}

extension UltralightCKey: CustomStringConvertible {
    /// Never prints key bytes. This type is a secret at every call site, and it
    /// flows through error paths and trace notes where a default `Data`
    /// description would leak it.
    public var description: String {
        isFactoryDefault ? "UltralightCKey(factory default)" : "UltralightCKey(<redacted>)"
    }
}
