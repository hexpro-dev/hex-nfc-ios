import Foundation
@testable import HexNFCKit

/// NXP NTAG 210µ ("210 micro") — NT2H1001 (50 pF) / NT2L1001 (17 pF).
///
/// Datasheet: NXP NT2L1001_NT2H1001 rev 3.0 (doc 343930). The smallest die in
/// the NTAG21x family and, protocol-wise, the most *reduced* — which is exactly
/// what makes it worth simulating. It is not "an NTAG213 with less memory":
///
///   - **16 pages total (00h–0Fh), 64 B.** Reads past 0Fh NAK; the base class's
///     `readPages` roll-over already models the wrap within that window
///     (reading 0Dh returns 0Dh, 0Eh, 0Fh, 00h).
///   - **48 B user memory at pages 04h–0Fh** — byte-for-byte identical to the
///     plain NTAG210. The µ saves die area by deleting the four config pages
///     (10h–13h), not by shrinking storage.
///   - **No config pages ⇒ no password.** `Type2ConfigLayout.for(.ntag210Micro)`
///     returns `nil`, so the base class skips CFG0/CFG1/PWD/PACK seeding,
///     `currentAUTH0()` is `nil`, and PWD_AUTH / enable / disable all throw
///     `capabilityUnsupported(.passwordAuth)` without any code here.
///   - **No FAST_READ (3Ah), no READ_CNT (39h).** Both now NAK in the base class
///     because this profile advertises neither `.fastRead` nor `.counterRead`.
///   - **READ_SIG (3Ch) present** — 32-byte ECDSA secp128r1 originality
///     signature. (Seritag claims the µ has no signature; NXP §9.6 says it
///     does, and NXP wins.)
///
/// Unlike MIFARE Ultralight EV1, this chip ships **NDEF-preformatted**: rev 3.0
/// Table 4 "Memory content at delivery" gives page 03h = `E1 10 06 00` and page
/// 04h = `03 00 FE 00` (an empty NDEF TLV). So there is deliberately no
/// `virgin:` variant — a blank-CC NTAG 210µ is not a factory state.
public final class NTAG210MicroSimulator: NTAG21xSimulator, @unchecked Sendable {
    public init(
        uid: Data = NTAG210MicroSimulator.defaultUID,
        ndefMessage: Data? = nil
    ) {
        super.init(
            variant: .ntag210Micro,
            profile: ChipCatalog.require(.ntag210Micro),
            uid: uid,
            ndefMessage: ndefMessage,
            signature: Data((0 ..< 32).map { UInt8($0 ^ 0x21) })
        )
    }

    /// `00 04 04 02 02 00 0B 03` — the exact block captured from real silicon
    /// and matched against rev 3.0 §11.1 Table 11.
    ///
    /// Byte 3 (`02h`) is **input capacitance** (50 pF = NT2H1001; `01h` would be
    /// the 17 pF NT2L1001), not a model discriminator. Byte 4 (`02h`) is the
    /// major version and is what marks this as a µ die — every non-µ NTAG21x
    /// reports `01h`. Byte 6 (`0Bh`) has its low bit set, meaning "between 2⁵
    /// and 2⁶ bytes"; NXP states the actual figure is 48.
    override public func versionBlock() -> Data {
        Data([0x00, 0x04, 0x04, 0x02, 0x02, 0x00, 0x0B, 0x03])
    }

    public static let defaultUID: Data = .init([0x04, 0x21, 0x21, 0x21, 0x21, 0x21, 0x21])
}
