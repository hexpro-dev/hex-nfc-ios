import Foundation

/// Static profile of a known chip, looked up via `ChipCatalog`.
public struct ChipProfile: Hashable, Sendable, Codable {
    public let id: ChipID
    public let family: TagFamily
    public let capabilities: TagCapability
    public let displayName: String
    public let manufacturer: String
    public let memoryLayout: ChipMemoryLayout

    public init(
        id: ChipID,
        family: TagFamily,
        capabilities: TagCapability,
        displayName: String,
        manufacturer: String,
        memoryLayout: ChipMemoryLayout
    ) {
        self.id = id
        self.family = family
        self.capabilities = capabilities
        self.displayName = displayName
        self.manufacturer = manufacturer
        self.memoryLayout = memoryLayout
    }
}

/// Stable, equatable identifier for a chip model. Not the same as a tag UID —
/// this names the *kind* of silicon, not the individual tag.
public enum ChipID: Hashable, Sendable, Codable {
    case ntag210Micro
    case ntag213
    case ntag213TT
    case ntag215
    case ntag216
    case ntag424DNA
    case mifareUltralightEV1_48
    case mifareUltralightEV1_128
    case mifareUltralightC
    case emV10
    case emV11
    case emV16
    case icodeSlix
    case icodeSlix2
    case genericIso15693
    case genericFeliCa
    case genericMifareDESFire
    case mifareDESFireEV1
    case mifareDESFireEV2
    case mifareDESFireEV3
    case ePassport
    case unknown
}

/// Describes how a chip's memory is partitioned. Used by the memory editor and
/// chip simulators alike to know which pages are CC, which carry NDEF, and
/// which hold password/config bytes.
public struct ChipMemoryLayout: Hashable, Sendable, Codable {
    public let pageSize: Int
    public let pageCount: Int
    public let ccPage: Int?
    public let ndefRange: ClosedRange<Int>?
    public let lockPages: [Int]
    public let dynamicLockPage: Int?
    public let pwdPage: Int?
    public let packPage: Int?
    public let configPages: [Int]

    public init(
        pageSize: Int,
        pageCount: Int,
        ccPage: Int? = nil,
        ndefRange: ClosedRange<Int>? = nil,
        lockPages: [Int] = [],
        dynamicLockPage: Int? = nil,
        pwdPage: Int? = nil,
        packPage: Int? = nil,
        configPages: [Int] = []
    ) {
        self.pageSize = pageSize
        self.pageCount = pageCount
        self.ccPage = ccPage
        self.ndefRange = ndefRange
        self.lockPages = lockPages
        self.dynamicLockPage = dynamicLockPage
        self.pwdPage = pwdPage
        self.packPage = packPage
        self.configPages = configPages
    }
}

public extension ChipMemoryLayout {
    /// Total addressable byte count for this chip.
    var byteCount: Int {
        pageSize * pageCount
    }
}

/// What an ISO 15693 / NFC Type-5 tag reports about itself via *Get System
/// Information* (`0x2B`). Every field is optional: the response's info-flags
/// byte declares which are present, and a weak read (iOS ISO 15693 is only
/// ~10-15% reliable in the field, see
/// `docs/site/content/en/developer/chip-support-matrix.md`)
/// can return a frame that omits or truncates them. CoreNFC surfaces an absent
/// field as `-1`; map those in via `init(coreNFCBlockSize:blockCount:icReference:)`.
public struct ISO15693SystemInfo: Equatable, Sendable {
    /// Self-reported block size in bytes (1…32), or `nil` if the response
    /// omitted the VICC-memory-size field.
    public let blockSize: Int?
    /// Self-reported number of blocks (1…256), or `nil` if absent.
    public let blockCount: Int?
    /// IC reference byte. Captured and logged, but **not** a variant
    /// discriminator: an ICODE SLIX (28 blocks) and an ICODE SLIX2 (80 blocks)
    /// both report `0x01`, live-verified 2026-08-07. So does UID byte 2 on
    /// both. Block geometry is the only discriminator that has held up.
    public let icReference: UInt8?

    public init(blockSize: Int?, blockCount: Int?, icReference: UInt8?) {
        self.blockSize = blockSize
        self.blockCount = blockCount
        self.icReference = icReference
    }

    /// Build from CoreNFC's `getSystemInfoAndUID` fields, where a value of `-1`
    /// means the tag's response did not carry that field — including the
    /// partial-frame case where one half of the memory-size field arrived and
    /// the other did not.
    public init(coreNFCBlockSize: Int, blockCount: Int, icReference: Int) {
        blockSize = coreNFCBlockSize >= 0 ? coreNFCBlockSize : nil
        self.blockCount = blockCount >= 0 ? blockCount : nil
        self.icReference = (0 ... 0xFF).contains(icReference) ? UInt8(icReference) : nil
    }

    /// Total self-reported user memory in bytes, when *both* block dimensions
    /// are present and sane — otherwise `nil`, so the caller falls back to the
    /// chip's datasheet memory estimate rather than computing a bogus size from
    /// half a truncated field.
    public var memoryBytes: Int? {
        guard let blockSize, let blockCount, blockSize > 0, blockCount > 0 else { return nil }
        return blockSize * blockCount
    }
}

/// Canonical Type-2 configuration-page map — the single source of truth for
/// where AUTH0, the ACCESS byte, the password/PACK and the lock bytes live on
/// each NTAG21x / MIFARE Ultralight EV1 variant. Both the production
/// `CoreNFCConnectedTag` and the chip simulators read protection-page numbers
/// from here, so the two can never drift.
///
/// Byte conventions are fixed across the family:
///   - **AUTH0** = `config0Page`, byte `auth0ByteOffset` (3). First page (≥)
///     that password protection covers; `0xFF` ⇒ nothing protected.
///   - **ACCESS** = `config1Page`, byte `accessByteOffset` (0). Bit 7 = `PROT`
///     (1 ⇒ read+write protected, 0 ⇒ write-only); bits 2–0 = `AUTH_LIM`
///     (failed-auth attempt limit, 0 ⇒ unlimited — never auto-bricks).
public struct Type2ConfigLayout: Hashable, Sendable {
    public let config0Page: Int
    public let config1Page: Int
    public let pwdPage: Int
    public let packPage: Int
    /// Static lock bytes live in bytes 2–3 of this page (covers pages 3…15).
    public let staticLockPage: Int
    /// Dynamic lock bytes page, or `nil` for small chips (MF0UL11) whose user
    /// area is fully covered by the static lock bytes.
    public let dynamicLockPage: Int?

    /// Byte offset of AUTH0 within `config0Page`.
    public static let auth0ByteOffset = 3
    /// Byte offset of the ACCESS byte within `config1Page`.
    public static let accessByteOffset = 0
    /// PROT bit mask within the ACCESS byte (read+write protection when set).
    public static let protBitMask: UInt8 = 0x80
    /// AUTH_LIM mask within the ACCESS byte (failed-auth attempt limit).
    public static let authLimMask: UInt8 = 0x07

    /// `true` when CFG0, CFG1, PWD and PACK are four consecutive pages, so a
    /// single `30 <config0Page>` READ serves all four with no roll-over.
    ///
    /// It holds for every variant in the catalogue, because on all of them the
    /// configuration block is the *last* four pages of the chip: NTAG213/213TT
    /// 41-44 of 45, NTAG215 131-134 of 135, NTAG216 227-230 of 231, MF0UL11
    /// 16-19 of 20, MF0UL21 37-40 of 41.
    ///
    /// Checked rather than assumed on purpose. A chip added later with a
    /// scattered configuration block would otherwise have its state silently
    /// mis-decoded from one frame; instead the driver falls back to two READs.
    public var configBlockIsContiguous: Bool {
        config1Page == config0Page + 1
            && pwdPage == config0Page + 2
            && packPage == config0Page + 3
    }

    public init(
        config0Page: Int,
        config1Page: Int,
        pwdPage: Int,
        packPage: Int,
        staticLockPage: Int,
        dynamicLockPage: Int?
    ) {
        self.config0Page = config0Page
        self.config1Page = config1Page
        self.pwdPage = pwdPage
        self.packPage = packPage
        self.staticLockPage = staticLockPage
        self.dynamicLockPage = dynamicLockPage
    }

    /// The config-page map for a Type-2 variant, or `nil` for variants without
    /// NTAG21x-style password protection (EM Microelectronic and bare
    /// ISO 14443-3A silicon, or the Type-4 NTAG424 DNA, which speaks a
    /// different command set entirely).
    ///
    /// Returning `nil` is also how a chip with *no* password hardware is
    /// modelled (EM Microelectronic, NTAG 210µ) — it is not merely "unknown".
    ///
    /// Page numbers are **datasheet-verified** (see `docs/internal/chip-config-pages.md`):
    ///   - NTAG213/215/216 — NXP NTAG213/215/216 datasheet (NT2H1x11), config
    ///     pages = last four pages: CFG0, CFG1, PWD, PACK; static lock page 2;
    ///     dynamic lock page = 0x28 / 0x82 / 0xE2.
    ///   - MIFARE Ultralight EV1 — NXP MF0ULx1 datasheet rev 3.x. MF0UL11
    ///     (48 B): CFG0=0x10, CFG1=0x11, PWD=0x12, PACK=0x13, **no dynamic lock
    ///     page** (static lock at page 2 covers the whole user area). MF0UL21
    ///     (128 B): dynamic lock 0x24, CFG0=0x25 … PACK=0x28.
    ///
    /// A wrong page here bricks real tags — do not edit without re-verifying
    /// against the datasheet (`Tests/.../TagProtectionTests` guards the values).
    public static func `for`(_ variant: Type2Variant) -> Type2ConfigLayout? {
        switch variant {
        case .ntag213, .ntag213TT:
            .init(config0Page: 41, config1Page: 42, pwdPage: 43, packPage: 44,
                  staticLockPage: 2, dynamicLockPage: 40)

        case .ntag215:
            .init(config0Page: 131, config1Page: 132, pwdPage: 133, packPage: 134,
                  staticLockPage: 2, dynamicLockPage: 130)

        case .ntag216:
            .init(config0Page: 227, config1Page: 228, pwdPage: 229, packPage: 230,
                  staticLockPage: 2, dynamicLockPage: 226)

        case .mifareUltralightEV1_48:
            // MF0UL11: CFG0=0x10, CFG1=0x11, PWD=0x12, PACK=0x13. The 48-byte
            // user area (pages 3…15) is fully covered by the static lock bytes
            // at page 2 — there is no separate dynamic lock page.
            .init(config0Page: 16, config1Page: 17, pwdPage: 18, packPage: 19,
                  staticLockPage: 2, dynamicLockPage: nil)

        case .mifareUltralightEV1_128:
            // MF0UL21: dynamic lock bytes at 0x24, CFG0=0x25 … PACK=0x28.
            .init(config0Page: 37, config1Page: 38, pwdPage: 39, packPage: 40,
                  staticLockPage: 2, dynamicLockPage: 36)

        case .mifareUltralightC:
            // MF0ICU2 is page-addressed like the chips above but its credential
            // is a 16-byte 2-key 3DES key with a mutual handshake, not a PWD
            // with a PACK reply. Its AUTH0 (page 2Ah) and AUTH1 (page 2Bh) are
            // byte 0, not byte 3, and AUTH1's polarity is inverted relative to
            // the NTAG21x PROT bit (0 means read+write restricted, 1 means
            // write-only). Returning a layout here would hand the chip to the
            // PWD/PACK backend via `ProtectionStyle.backendStyle`, which cannot
            // drive it. `UltralightCProtectionDriver` owns this chip instead.
            // (MF0ICU2 rev 3.3 §7.5.8 Table 12.)
            nil

        case .ntag210Micro, .ntag424DNA, .emV10, .emV11, .emV16, .unknown:
            // NTAG 210µ has no configuration pages at all — the µ die drops the
            // four CFG0/CFG1/PWD/PACK pages the plain NTAG210 carries at
            // 10h–13h, which is where its area saving comes from. Its memory
            // stops at page 0Fh, so there is nothing here to address.
            // (NT2L1001_NT2H1001 rev 3.0 §9.5 memory organization + Table 5
            // command overview, which lists no PWD_AUTH.)
            nil
        }
    }
}

public extension ChipProfile {
    /// Canonical Type-2 protection-page map for this chip, if it is a Type-2
    /// variant that supports NTAG21x-style password protection.
    var type2ConfigLayout: Type2ConfigLayout? {
        guard case .type2(let variant) = family else { return nil }
        return Type2ConfigLayout.for(variant)
    }

    /// Bytes the chip's NDEF area can actually hold — the *usable* figure, as
    /// distinct from `memoryLayout.byteCount` (total addressable memory). For
    /// page-addressed Type-2 / Type-5 chips this is the NDEF page range times the
    /// page size; the APDU-driven NTAG424 DNA has no page range, so its 256-byte
    /// NDEF file (one of three ISO 7816-4 files within its 416 B of user memory)
    /// is stated explicitly. `0` when the chip exposes no blind-readable NDEF
    /// area (DESFire, bare ISO 15693 / FeliCa) — callers then show the total
    /// figure alone.
    var ndefByteCapacity: Int {
        if case .type4(.ntag424DNA) = family {
            return 256
        }
        guard let range = memoryLayout.ndefRange else { return 0 }
        let raw = (range.upperBound - range.lowerBound + 1) * memoryLayout.pageSize
        // Type-5 `ndefRange` spans **every** block, including the ones that can
        // never hold NDEF payload, so the raw span overstates what a user can
        // actually write. Type-2 has no such correction because its range
        // already starts past the UID/lock/CC pages (`4...39`).
        //
        // The authority is the Capability Container this app writes: MLEN
        // counts the T5T area after the CC in 8-byte units, so an 80-block
        // SLIX2 declares 39 × 8 = 312 B, not the 320 B the raw span implies.
        // The difference is block 0 (the CC itself) and, on a SLIX2, block 79
        // (the 16-bit counter, which "cannot be used to store user data" —
        // SL2S2602 §8.1.1). Reporting 320 invited a write that could not fit.
        if case .type5 = family, let cc = factoryType5CC, cc.count >= 3 {
            return Int(cc[cc.startIndex + 2]) * 8
        }
        return raw
    }

    /// How many pages a plain `READ` may address before the chip NAKs.
    ///
    /// Normally the whole chip, but **MIFARE Ultralight C decodes reads only up
    /// to page 2Bh**: its key pages at 2Ch–2Fh are not merely masked to zeros,
    /// they are not decoded at all, and a read of them returns a NAK
    /// (live-confirmed 2026-08-07: `30 2C` → `00`).
    ///
    /// That matters far beyond the four pages, because **a NAK returns a Type-2
    /// tag to HALT for the rest of the activation**. A full memory dump that
    /// walks to `pageCount` would therefore not just fail at the last page, it
    /// would kill the session and make every following operation look like a
    /// dropped tag.
    var readablePageCount: Int {
        if case .type2(.mifareUltralightC) = family {
            return UltralightCLayout.readDecodedPageCount
        }
        return memoryLayout.pageCount
    }

    /// Factory Type-2 Capability Container bytes for this chip, written back when
    /// a format/blank restores the tag to a reusable state. The magic + version
    /// (`E1 10`) are fixed; byte 2 is the NDEF size field (usable bytes ÷ 8).
    /// `nil` for chips whose CC is chip-managed (NTAG424), block-geometry-derived
    /// (ICODE SLIX — see `factoryType5CC`), or absent (FeliCa/DESFire).
    ///
    /// **These are datasheet constants, not derived values — do not "simplify"
    /// them into `ndefByteCapacity / 8`.** NXP reserves a different margin per
    /// chip: NTAG213 declares its full 144 B, but NTAG215 declares 496 of 504 B
    /// and NTAG216 declares 872 of 888 B. A derivation would silently mis-declare
    /// both. Page 3 is **OTP** (writes OR bits and can never be cleared), so a
    /// wrong value here permanently mis-declares a real tag's NDEF area.
    ///
    /// Sources: NXP NTAG213/215/216 data sheet (NTAG213_215_216) §8.5.6 "Capability
    /// container"; NXP MF0ULX1 MIFARE Ultralight EV1 data sheet §8.5 / AN11340
    /// "NDEF configuration". Guarded by `FactoryCCTests`.
    ///
    /// Single source of truth shared by the app's `formatCC`, the console format
    /// presets and the chip simulators, so the three can't drift.
    var factoryCC: Data? {
        let sizeByte: UInt8
        switch id {
        // NTAG 210µ (NT2H1001) — 48 B usable, declares 48 (0x06 × 8). The chip
        // ships with this CC already written; NT2L1001_NT2H1001 rev 3.0 Table 4
        // "Memory content at delivery" gives page 03h = E1 10 06 00.
        case .ntag210Micro: sizeByte = 0x06

        // NTAG213 / 213 TT — 144 B usable, declares 144 (0x12 × 8).
        case .ntag213, .ntag213TT: sizeByte = 0x12

        // NTAG215 — 504 B usable, declares 496 (0x3E × 8).
        case .ntag215: sizeByte = 0x3E

        // NTAG216 — 888 B usable, declares 872 (0x6D × 8).
        case .ntag216: sizeByte = 0x6D

        // MF0UL11 — 48 B usable, declares 48 (0x06 × 8).
        case .mifareUltralightEV1_48: sizeByte = 0x06

        // MF0UL21 — 128 B usable, declares 128 (0x10 × 8).
        case .mifareUltralightEV1_128: sizeByte = 0x10

        // MF0ICU2 (Ultralight C) — 144 B usable, declares 144 (0x12 × 8). The
        // same value as NTAG213 because the two chips genuinely share a
        // 36-page (04h–27h) user area, not because it was copied across: this
        // chip ships with page 3 blank (rev 3.3 Table 13 "Initial memory
        // organization"), so it is the one chip in our stock whose CC we ever
        // actually write.
        case .mifareUltralightC: sizeByte = 0x12

        // EM V10/V11/V16 — no public datasheet in this repo; all three carry the
        // same 12-page (48 B) NDEF area in `ChipCatalog`, so the size byte is
        // taken from that layout rather than a datasheet. Re-verify if a real EM
        // tag ever contradicts it.
        case .emV10, .emV11, .emV16: sizeByte = 0x06

        default: return nil
        }
        return Data([Type2CC.magic, Type2CC.version, sizeByte, 0x00])
    }
}

/// Constants for the NFC Forum **Type-2** Capability Container (page 3).
///
/// The Type-2 sibling of `Type5CC`. It exists so the "is this tag already
/// formatted?" test has one spelling: page 3 is **OTP**, so a format that runs
/// against a written CC ORs bits in and can never be corrected, and the guard
/// against that was previously a bare `0xE1` literal repeated at each call
/// site — present in the DEBUG operation and missing from the shipping one.
public enum Type2CC {
    /// CC byte 0. Identifies the page as an NFC Forum Capability Container;
    /// a virgin OTP page reads `00`.
    public static let magic: UInt8 = 0xE1
    /// CC byte 1: NFC Forum Type-2 mapping version 1.0.
    public static let version: UInt8 = 0x10

    /// Whether page 3 already carries a Capability Container, i.e. the tag has
    /// been formatted and its OTP page must not be written again.
    public static func isFormatted(_ page3: Data) -> Bool {
        page3.first == magic
    }
}
