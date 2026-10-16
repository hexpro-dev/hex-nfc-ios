import Foundation

/// How a permanent lock fills a Type-2 chip's **dynamic** lock page.
///
/// Split out of `CoreNFCSession.permanentLock()` so the value is reachable from
/// tests. `SimulatedSession.permanentLock()` delegates straight to the
/// simulator's own lock model rather than replaying frames, so the bytes
/// production actually puts on the wire have no simulator coverage at all —
/// this type is what closes that gap.
///
/// ## Why this is a per-chip bit mask, not `FF FF FF`
///
/// The dynamic lock page is **not** three bytes of usable lock bits. Every
/// NTAG21x mixes lock bits, block-locking (BL) bits and **RFUI** bits inside
/// those three bytes, and the layout differs per chip because the granularity
/// does (2 pages on NTAG213, 16 on NTAG215/216). NTAG213/215/216 rev 3.2
/// §8.5.3 is explicit:
///
/// > Set all bits marked with RFUI to 0, when writing to the dynamic lock bytes.
///
/// and, in the same section, that a bit set to 1 can never be cleared. Writing
/// `FF` blanket-sets 6 RFUI bits on an NTAG213, 12 on an NTAG215 and 3 on an
/// NTAG216, permanently, during the one operation with no undo.
///
/// A live MIFARE Ultralight C read-back (2026-08-07) showed its RFU bytes
/// discarding the write and reading back `00`, so on that silicon the mistake
/// was inert. That is an observation about one chip and one die, not a licence
/// to keep writing reserved bits.
public enum Type2LockWrite {
    /// Which bits of each dynamic-lock byte are lock or BL bits, per chip.
    ///
    /// Index = byte offset within the page. Anything not covered by the mask is
    /// RFUI and must stay `0`.
    ///
    /// - NTAG213 (page 28h, 2-page granularity, rev 3.2 Fig 10)
    ///   byte 0 = lock 16–31 (8 bits); byte 1 = lock 32–39 in bits 0–3, RFUI
    ///   4–7; byte 2 = BL 16–39 in bits 0–5, RFUI 6–7.
    /// - NTAG215 (page 82h, 16-page granularity, Fig 11)
    ///   byte 0 = lock 16–129 (8 bits); byte 1 = **entirely RFUI**;
    ///   byte 2 = BL in bits 0–3, RFUI 4–7.
    /// - NTAG216 (page E2h, 16-page granularity, Fig 12)
    ///   byte 0 = lock 16–143 (8 bits); byte 1 = lock 144–225 in bits 0–5, RFUI
    ///   6–7; byte 2 = BL in bits 0–6, RFUI 7.
    /// - MIFARE Ultralight C (page 28h, MF0ICU2 rev 3.3 §7.5.3)
    ///   bytes 0–1 are lock bytes 2–3; bytes 2–3 are RFU.
    /// - Ultralight EV1 128 (page 24h, MF0ULX1 rev 3.3 §8.5.3 Fig 9)
    ///   byte 0 = lock 16–31 (8 bits); byte 1 = lock 32–35 in bits 0–1, RFUI
    ///   2–7; byte 2 = BL 16–35 in bits 0–4, RFUI 5–7.
    ///
    /// Byte 3 is RFUI on every chip here. NTAG21x reads it back as `BDh`; do not
    /// mistake that for something to write.
    static func lockBitMask(for family: TagFamily) -> [UInt8] {
        guard case .type2(let variant) = family else { return [] }
        switch variant {
        case .ntag213, .ntag213TT:
            return [0xFF, 0x0F, 0x3F, 0x00]

        case .ntag215:
            return [0xFF, 0x00, 0x0F, 0x00]

        case .ntag216:
            return [0xFF, 0x3F, 0x7F, 0x00]

        case .mifareUltralightC:
            return [0xFF, 0xFF, 0x00, 0x00]

        case .mifareUltralightEV1_128:
            return [0xFF, 0x03, 0x1F, 0x00]

        default:
            // Chips with no dynamic lock page never reach here; anything else is
            // a chip added without its datasheet consulted. All bits is the
            // historical value and the wrong default, but narrowing it to a
            // guess would silently leave pages writable — which is why
            // `Type2LockWriteTests` fails the moment a catalog chip lands here.
            return [0xFF, 0xFF, 0xFF, 0x00]
        }
    }

    /// Which bits of each dynamic-lock byte are **lock** bits, with the
    /// block-locking bits excluded.
    ///
    /// Used only for *reading*, never for writing: a permanent lock still sets
    /// every bit in `lockBitMask`. The distinction is that a BL bit locks a lock
    /// *bit*, not a page, so a tag whose L bits are all set refuses every write
    /// whether or not its BL bits were ever touched. Encoders that lock a tag
    /// without setting the BL bits are common, and scoring them against the full
    /// mask reported a completely write-protected tag as only partly locked.
    ///
    /// The split is read straight off the same figures `lockBitMask` cites:
    /// NTAG213/215/216 rev 3.2 §8.5.3 Figures 10-12 and MF0ULX1 rev 3.3 §8.5.3
    /// Figure 9 mark the BL bits in byte 2, and MF0ICU2 rev 3.3 §7.5.3 puts
    /// Ultralight C's lock and block-lock bits together inside bytes 0-1, where
    /// they cannot be separated.
    static func dynamicLockBitsOnlyMask(for family: TagFamily) -> [UInt8] {
        guard case .type2(let variant) = family else { return [] }
        switch variant {
        case .ntag213, .ntag213TT:
            return [0xFF, 0x0F, 0x00, 0x00]

        case .ntag215:
            return [0xFF, 0x00, 0x00, 0x00]

        case .ntag216:
            return [0xFF, 0x3F, 0x00, 0x00]

        case .mifareUltralightC:
            // Lock and block-lock bits share bytes 0-1 here, so there is nothing
            // to exclude.
            return [0xFF, 0xFF, 0x00, 0x00]

        case .mifareUltralightEV1_128:
            return [0xFF, 0x03, 0x00, 0x00]

        default:
            return lockBitMask(for: family)
        }
    }

    /// Which bits of the two **static** lock bytes are lock bits.
    ///
    /// Page 2 byte 2 is `LOCK0`: bits 0-2 are the block-locking bits BL-CC,
    /// BL-9-4 and BL-15-10, bit 3 is L-CC and bits 4-7 are L-4 to L-7. Byte 3 is
    /// `LOCK1`, entirely L-8 to L-15 (NTAG213/215/216 rev 3.2 §8.5.2 Fig 8;
    /// MF0ULX1 rev 3.3 §8.5.2; MF0ICU2 rev 3.3 §7.5.2 all carry the same map).
    /// There is no RFUI here, which is why the static bytes can be compared as
    /// values while the dynamic page cannot.
    static let staticLockBitsOnlyMask: [UInt8] = [0xF8, 0xFF]

    /// The full page payload a permanent lock writes to `dynamicLockPage`:
    /// every lock and BL bit set, every RFUI bit left at `0`.
    public static func dynamicLockPayload(for family: TagFamily, pageSize: Int) -> Data {
        let mask = lockBitMask(for: family)
        var payload = Data(repeating: 0x00, count: pageSize)
        for index in 0 ..< min(mask.count, pageSize) {
            payload[payload.startIndex + index] = mask[index]
        }
        return payload
    }
}
