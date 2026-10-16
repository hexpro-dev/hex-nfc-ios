import Foundation

/// Static directory of known chip profiles, plus an identification routine
/// that maps a chip-specific probe response (GET_VERSION on NTAG, ATQA bytes
/// on Type-2, etc.) to a `ChipProfile`.
///
/// New chips are added by:
///   1. Inserting a `ChipProfile` in `Self.all`.
///   2. Adding a recognition rule in `identify(getVersion:)` or
///      `identify(memorySignature:)`, whichever the chip family probes with.
public enum ChipCatalog {
    public static let all: [ChipProfile] = [
        .ntag210Micro,
        .ntag213,
        .ntag213TT,
        .ntag215,
        .ntag216,
        .ntag424DNA,
        .mifareUltralightEV1_48,
        .mifareUltralightEV1_128,
        .mifareUltralightC,
        .emV10,
        .emV11,
        .emV16,
        .icodeSlix,
        .icodeSlix2,
        .genericIso15693,
        .genericFeliCa,
        .mifareDESFireEV1,
        .mifareDESFireEV2,
        .mifareDESFireEV3,
        .genericMifareDESFire,
        .ePassport,
    ]

    public static func profile(for id: ChipID) -> ChipProfile? {
        all.first { $0.id == id }
    }

    /// Classify an ISO 7816 tag as an electronic passport from the status word
    /// returned by SELECT of the eMRTD LDS1 application (AID `A0000002471001`).
    /// A `9000` (or a `62xx`/`63xx` warning that still means "selected") marks
    /// the chip as an ePassport; anything else is not one.
    public static func identify(eMRTDSelectStatus sw: UInt16) -> ChipProfile? {
        let sw1 = UInt8(sw >> 8)
        guard sw == 0x9000 || sw1 == 0x62 || sw1 == 0x63 else { return nil }
        return profile(for: .ePassport)
    }

    /// Identify by the response to the NTAG `GET_VERSION` (`0x60`) command.
    ///
    /// The 8-byte version block (NXP NTAG21x / MF0ULx1 datasheets, "Version
    /// information" tables) is:
    ///
    ///     [0] fixed header (00h)   [1] vendor ID (04h = NXP)
    ///     [2] product type         [3] product subtype
    ///     [4] major version        [5] minor version
    ///     [6] storage size         [7] protocol type
    ///
    /// **All four discriminating bytes are load-bearing — none may be dropped.**
    /// This previously keyed on `(subType, storageSize)` alone, on the claim
    /// that the pair was unique across NXP's HF catalog. It is not:
    ///
    ///   - `productType` separates NTAG (04h) from the Ultralight family (03h).
    ///     Without it, NTAG210 (`04 01 01 … 0B`) collided with MIFARE Ultralight
    ///     EV1 48 (`03 01 01 … 0B`) and NTAG212 with UL EV1 128 — each NTAG was
    ///     silently reported as the Ultralight.
    ///   - `major` separates the µ dies (02h) from every other NTAG21x (01h).
    ///     It was never read at all, making NTAG 210µ undetectable by
    ///     construction.
    ///   - `subType` is **input capacitance**, not a model: 01h = 17 pF,
    ///     02h = 50 pF, 04h = 50 pF + field-detect pin. A blanket
    ///     `(0x04, _) -> ntag424DNA` therefore swallowed NTAG213F / NTAG216F,
    ///     reporting them as an NTAG424 DNA — a different family and command
    ///     set entirely. NTAG424 DNA never reaches this decoder anyway: it
    ///     powers up in ISO 14443-4 and rejects the bare `60h` with `67 00`
    ///     (2 bytes, short of the `count >= 8` guard). It is identified by
    ///     `identify(type4Version:)` from the wrapped `90 60 00 00 00` form.
    ///
    /// Storage size is matched exactly rather than decoded, because the byte is
    /// a *range* when its low bit is set (`0Bh` means "between 32 and 64 bytes",
    /// which is 48 on every chip that reports it) and is shared across several
    /// unrelated dies. It disambiguates within a product line; it can never
    /// identify one on its own.
    ///
    /// Chips deliberately left unmatched (returning `nil`, so the caller shows an
    /// honest "unidentified" with the decoded fallback from `describe(getVersion:)`
    /// rather than a confident wrong answer): NTAG210, NTAG212, NTAG213F,
    /// NTAG216F. Their page maps are datasheet-known but unverified against real
    /// silicon here, and in this codebase a wrong page number bricks tags.
    public static func identify(getVersion response: Data) -> ChipProfile? {
        guard response.count >= 8 else { return nil }
        let vendor = response[1]
        let productType = response[2]
        let subType = response[3]
        let major = response[4]
        let storageSize = response[6]

        // NXP only. Product types: 0x04 NTAG, 0x03 MIFARE Ultralight family.
        guard vendor == 0x04 else { return nil }
        guard productType == 0x03 || productType == 0x04 else { return nil }

        switch (productType, subType, major, storageSize) {
        // NTAG21x standard line (major 01h). SubType is capacitance: the 213/215/216
        // ship as 50 pF (02h); the TT variant reports 05h.
        case (0x04, 0x02, 0x01, 0x0F): return .ntag213
        case (0x04, 0x02, 0x01, 0x11): return .ntag215
        case (0x04, 0x02, 0x01, 0x13): return .ntag216
        case (0x04, 0x05, 0x01, 0x0F): return .ntag213TT

        // NTAG 210µ (major 02h). 01h = NT2L1001 (17 pF), 02h = NT2H1001 (50 pF);
        // the dies are identical apart from input capacitance, so both map here.
        case (0x04, 0x01, 0x02, 0x0B): return .ntag210Micro
        case (0x04, 0x02, 0x02, 0x0B): return .ntag210Micro

        // MIFARE Ultralight EV1 (productType 03h).
        case (0x03, 0x01, 0x01, 0x0B): return .mifareUltralightEV1_48
        case (0x03, 0x01, 0x01, 0x0E): return .mifareUltralightEV1_128
        default: return nil
        }
    }

    /// Identify a **pre-EV1** Type-2 chip, which has no `GET_VERSION` at all, by
    /// its memory shape and delivery signature.
    ///
    /// The whole Ultralight C command set is READ, WRITE, COMPATIBILITY_WRITE
    /// and AUTHENTICATE (MF0ICU2 rev 3.3 Table 14), so `60h` is refused, and a
    /// refused command returns a Type-2 tag to HALT for the rest of the
    /// activation. That is why these tags read as "unidentified" until the
    /// session has re-polled: this decoder runs on the *second* pass, after
    /// `restartPolling()` has woken the tag.
    ///
    /// **Deliberately does not send `1A 00`.** Answering `AF` + 8 bytes would be
    /// the most direct confirmation that a chip speaks 3DES, but it leaves the
    /// card half-way through a mutual handshake, and any other command then
    /// aborts it into a NAK, which halts the tag again. Identification must hand
    /// the caller a *usable* tag. The handshake is exercised later, by the
    /// protection driver and the harness's `ulc.auth` step, in a session where a
    /// failure is recoverable.
    ///
    /// **Nor does it read the key pages.** `30 2C` returns a NAK on real
    /// silicon rather than masked zeros (live-confirmed 2026-08-07): reads are
    /// only decoded up to page 2Bh. A NAK halts the tag, so a "confirm the key
    /// is unreadable" probe would leave the caller holding a dead session.
    ///
    /// - Parameters:
    ///   - pageZero: 16 bytes from `30 00` (pages 00h-03h).
    ///   - configPages: 16 bytes from `30 28` (pages 28h-2Bh), or `nil` if the
    ///     read was refused, which rules out a 48-page chip.
    public static func identify(
        preEV1PageZero pageZero: Data,
        configPages: Data?
    ) -> ChipProfile? {
        guard pageZero.count >= 16, let configPages, configPages.count >= 16 else { return nil }
        let zero = [UInt8](pageZero)
        let config = [UInt8](configPages)

        // Manufacturer + BCC integrity. Without this a garbled read could match
        // the shape checks below by accident.
        guard zero[0] == 0x04 else { return nil } // NXP
        guard zero[3] == 0x88 ^ zero[0] ^ zero[1] ^ zero[2] else { return nil } // BCC0
        guard zero[8] == zero[4] ^ zero[5] ^ zero[6] ^ zero[7] else { return nil } // BCC1

        // A chip smaller than 48 pages rolls a READ of 28h back around to the
        // start of memory, so an echo of page 0 means "this address does not
        // exist" rather than "these are the config pages".
        guard Array(config.prefix(4)) != Array(zero.prefix(4)) else { return nil }

        // AUTH0 (page 2Ah byte 0) is only ever 03h-30h on this chip, and AUTH1
        // (2Bh byte 0) only uses bit 0 (rev 3.3 §7.5.8). Two bytes is not much
        // entropy on its own, which is why it is the last check rather than the
        // first.
        let auth0 = config[8]
        let auth1 = config[12]
        guard (UltralightCLayout.minimumProtectFromPage ... UltralightCLayout.protectionOff).contains(auth0),
              auth1 & ~UltralightCLayout.auth1WriteOnlyBit == 0 else { return nil }

        return profile(for: .mifareUltralightC)
    }

    /// Identify an NTAG424 DNA from its **wrapped-APDU** `GET_VERSION`
    /// (`90 60 00 00 00`) response.
    ///
    /// NTAG424 DNA powers up in ISO 14443-4 and speaks APDUs, so it rejects the
    /// bare NTAG21x `GET_VERSION` (`0x60`) with the ISO 7816 status word
    /// `67 00` ("wrong length") — which `identify(getVersion:)` can't decode.
    /// Its version must be requested in the DESFire-style wrapped form, whose
    /// first frame carries 7 bytes of NXP hardware info followed by the
    /// wrapped-native status word `91 AF` ("additional frame follows"). The chip
    /// simulator returns the whole block in one frame ending `91 00`; both forms
    /// decode here.
    ///
    /// Hardware-info layout (NXP NT4H2421Gx rev 3.2 §11.5.1):
    ///   `[0]` vendor (`0x04` = NXP)  ·  `[1]` HW type (`0x04` = NTAG 4xx)
    ///   `[2]` subtype  ·  `[3]` major (`0x30` = 424 DNA)  ·  `[4]` minor
    ///   `[5]` storage size  ·  `[6]` protocol
    ///
    /// Keyed on **vendor + HW type only**, so it's robust to the version/storage
    /// bytes and to whichever frame form the tag returns. DESFire reports HW
    /// type `0x01` (and arrives via its own `.desfire` family), so it is
    /// excluded here regardless.
    public static func identify(type4Version response: Data) -> ChipProfile? {
        var bytes = [UInt8](response)
        // Drop a trailing wrapped-native status word (91 AF / 91 00) if present,
        // leaving just the hardware-info block.
        if bytes.count >= 2, bytes[bytes.count - 2] == 0x91 {
            bytes.removeLast(2)
        }
        guard bytes.count >= 7 else { return nil }
        guard bytes[0] == 0x04, bytes[1] == 0x04 else { return nil }
        return profile(for: .ntag424DNA)
    }

    /// Identify a MIFARE DESFire from its native `GET_VERSION` (`0x60`)
    /// response, pinning the generation (EV1 / EV2 / EV3) and storage size.
    ///
    /// DESFire's `GET_VERSION` is multi-frame; the *first* frame carries the
    /// hardware info we need. CoreNFC returns it with the leading status byte
    /// (`0xAF`, "additional frame follows"), e.g. a 4 KB EV3 (Myki) reports
    /// `AF 04 01 01 33 00 18 05`.
    ///
    /// First-frame layout (after the status byte):
    ///   `[0]` vendor (`0x04` = NXP)  ·  `[1]` hardware type (`0x01` = DESFire)
    ///   `[2]` hw subtype             ·  `[3]` hw **major** ← generation
    ///   `[4]` hw minor               ·  `[5]` storage size (`2^(n>>1)` bytes)
    ///   `[6]` protocol
    ///
    /// Generation by hw-major: `0x00` D40/EV0, `0x01` EV1, `0x12` EV2,
    /// `0x33` EV3 (per NXP / libfreefare / Metrodroid). Returns `nil` for a
    /// non-NXP or non-DESFire response, and the generic DESFire profile when
    /// the generation byte is unrecognised (still better than "Unknown").
    /// The returned profile's `memoryLayout.byteCount` reflects the actual
    /// decoded storage, so it is synthesised here rather than looked up.
    public static func identify(desFireVersion response: Data) -> ChipProfile? {
        var bytes = [UInt8](response)
        // CoreNFC hands back the frame with its status byte; drop it.
        if bytes.count == 8 {
            bytes.removeFirst()
        }
        guard bytes.count >= 7 else { return nil }
        let vendor = bytes[0]
        let hwType = bytes[1]
        let hwMajor = bytes[3]
        let storage = bytes[5]
        guard vendor == 0x04, hwType == 0x01 else { return nil }

        let id: ChipID
        let variant: Type4Variant
        switch hwMajor {
        case 0x01: (id, variant) = (.mifareDESFireEV1, .desfireEV1)
        case 0x12: (id, variant) = (.mifareDESFireEV2, .desfireEV2)
        case 0x33: (id, variant) = (.mifareDESFireEV3, .desfireEV3)
        default: (id, variant) = (.genericMifareDESFire, .desfireGeneric)
        }

        let byteCount = desFireStorageBytes(storage) ?? 0
        return ChipProfile(
            id: id,
            family: .type4(variant),
            // DESFire data lives in key-protected applications, not a
            // blind-readable NDEF area — only raw transceive is advertised.
            capabilities: [.rawTransceive],
            displayName: variant.shortName,
            manufacturer: "NXP",
            memoryLayout: ChipMemoryLayout(pageSize: 1, pageCount: byteCount)
        )
    }

    /// Decode a **DESFire** storage-size byte: `2^(n >> 1)` bytes, with bit 0
    /// flagging an inexact (range) size. Returns `nil` if implausible.
    ///
    /// DESFire ships in exact powers of two, so discarding the range flag is
    /// safe here. It is **not** safe for NTAG/Ultralight — an NTAG 210µ reports
    /// `0Bh`, whose low bit means "between 2⁵ and 2⁶", and the true size is 48,
    /// not the 32 this returns. Type-2 sizes come from `ChipMemoryLayout`, never
    /// from this function.
    static func desFireStorageBytes(_ s: UInt8) -> Int? {
        let exponent = Int(s >> 1)
        guard (1 ... 30).contains(exponent) else { return nil }
        return 1 << exponent
    }

    /// Identify EM chips. EM Microelectronic doesn't expose GET_VERSION;
    /// the convention is to read system config block 0 (`READ 00`) and
    /// match on the first 2 bytes.
    public static func identify(emSignature signature: Data) -> ChipProfile? {
        guard signature.count >= 2 else { return nil }
        switch (signature[0], signature[1]) {
        case (0xE0, 0x10): return .emV10
        case (0xE0, 0x11): return .emV11
        case (0xE0, 0x16): return .emV16
        default: return nil
        }
    }

    /// Resolve an ISO 15693 / NFC Type-5 tag to a profile from its IC
    /// manufacturer code and a best-effort *Get System Information* probe.
    ///
    /// NXP (`0x04`) silicon is the ICODE family — resolved to the ICODE SLIX
    /// profile. That profile's 112-byte memory is a **datasheet estimate used
    /// only as a fallback**: when the tag self-reports its block geometry we
    /// honour that instead (a larger ICODE reports more than a plain SLIX). The
    /// *exact* variant (SLIX / SLIX2 / SLIX-S / SLIX-L) is deliberately not
    /// asserted — telling them apart needs the IC-reference byte mapped to a
    /// model, and one capture is not a mapping.
    ///
    /// **Live captures (2026-08-05 and 2026-08-07, harness `t5.systemInfo`):**
    ///
    /// | chip | blocks | IC ref | UID byte 2 | `GET_RANDOM_NUMBER` |
    /// |---|---|---|---|---|
    /// | ICODE SLIX  | 28 (112 B) | `0x01` | `0x01` | `00 D2 72` — supported |
    /// | ICODE SLIX2 | 80 (320 B) | `0x01` | `0x01` | supported |
    ///
    /// **The IC-reference byte is not a discriminator** — both report `0x01`,
    /// and so does UID byte 2. That kills the approach this comment used to
    /// propose. **Block geometry is the only discriminator that has held up**:
    /// 80 blocks is unambiguously SLIX2 (nothing else in the line has 2560-bit
    /// user memory), while 28 blocks is shared by SLI and SLIX and needs the
    /// behavioural probe above — a plain SLI has no privacy/password machinery
    /// and should not answer `B2`.
    ///
    /// **The geometry discriminator now also decides whether protection is
    /// offered at all.** Only `.icodeSlix2` carries `.passwordAuth`, because
    /// only the SLIX2 is known to have the read/write protection passwords and
    /// `PROTECT PAGE`; a 28-block answer could equally be an SLI, which has no
    /// password machinery whatever. `ProtectionStyle.backendStyle` and these
    /// capability sets have to stay in agreement (`ChipIdentificationTests`
    /// pins both): a family match there that this set does not back would offer
    /// the protection UI for a chip whose backend can only time out.
    ///
    /// Non-NXP Type-5 silicon (ST, EM, …) gets the generic ISO 15693 profile,
    /// likewise upgraded with the self-reported size, and likewise without
    /// `.passwordAuth`.
    ///
    /// Always returns a profile (never `nil`): an ISO 15693 tag whose system
    /// info we couldn't read is still an honest "ISO 15693", not "Unknown".
    public static func iso15693Profile(
        icManufacturerCode: UInt8,
        systemInfo: ISO15693SystemInfo?
    ) -> ChipProfile {
        let isNXP = icManufacturerCode == 0x04
        // 80 blocks is unambiguously SLIX2: nothing else in the ICODE line
        // carries 2560-bit user memory. 28 blocks stays `.icodeSlix`, which is
        // the conservative call, because that geometry is shared with the plain
        // SLI and only the `B2` behavioural probe separates them (see above).
        // Both share a capability set, so a mislabelled SLI would still be
        // driven correctly; only the display name would be optimistic.
        let base = if isNXP, systemInfo?.blockCount == 80 {
            ChipProfile.icodeSlix2
        } else if isNXP {
            ChipProfile.icodeSlix
        } else {
            ChipProfile.genericIso15693
        }
        guard let blockSize = systemInfo?.blockSize, blockSize > 0,
              let blockCount = systemInfo?.blockCount, blockCount > 0
        else {
            return base
        }
        // Replace the datasheet estimate with the chip's self-reported geometry.
        // The whole user area is the T5T NDEF area (mirrors `.icodeSlix`, whose
        // ndefRange spans every block), so ndef capacity tracks the real size.
        return ChipProfile(
            id: base.id,
            family: base.family,
            capabilities: base.capabilities,
            displayName: base.displayName,
            manufacturer: base.manufacturer,
            memoryLayout: ChipMemoryLayout(
                pageSize: blockSize,
                pageCount: blockCount,
                ndefRange: 0 ... (blockCount - 1)
            )
        )
    }
}

// MARK: - Canonical profiles

extension ChipProfile {
    /// NTAG 210µ ("210 micro", NT2H1001 / NT2L1001). The smallest NTAG21x die:
    /// 16 pages (64 B) total, of which pages 04h-0Fh (48 B) are user memory —
    /// byte-for-byte the same user area as a plain NTAG210. The µ saves area by
    /// deleting the four config pages (10h-13h), **not** by shrinking storage.
    ///
    /// Consequences, all from NT2L1001_NT2H1001 rev 3.0 Table 5 (an exhaustive
    /// command list) and §9.5:
    ///   - no PWD/PACK/AUTH0/ACCESS ⇒ **no `.passwordAuth`**, and
    ///     `Type2ConfigLayout.for(.ntag210Micro)` is `nil`
    ///   - no `FAST_READ` (3Ah) ⇒ no `.fastRead`
    ///   - no `READ_CNT` (39h) ⇒ no `.counterRead`
    ///   - static lock bytes at page 02h only, no dynamic lock page
    ///   - `READ_SIG` (3Ch) present — 32-byte ECDSA secp128r1 originality
    ///     signature, so `.signatureRead` stands
    static let ntag210Micro = ChipProfile(
        id: .ntag210Micro,
        family: .type2(.ntag210Micro),
        capabilities: [
            .ndefRead, .ndefWrite, .rawTransceive,
            .permanentLock,
            .memoryRead, .memoryWrite, .formatCC,
            .signatureRead,
        ],
        displayName: "NTAG 210µ",
        manufacturer: "NXP",
        memoryLayout: ChipMemoryLayout(
            pageSize: 4, pageCount: 16,
            ccPage: 3, ndefRange: 4 ... 15,
            lockPages: [2], dynamicLockPage: nil,
            pwdPage: nil, packPage: nil,
            configPages: []
        )
    )

    static let ntag213 = ChipProfile(
        id: .ntag213,
        family: .type2(.ntag213),
        capabilities: [
            .ndefRead, .ndefWrite, .rawTransceive,
            .passwordAuth, .permanentLock,
            .memoryRead, .memoryWrite, .formatCC,
            .signatureRead, .counterRead, .fastRead,
        ],
        displayName: "NTAG213",
        manufacturer: "NXP",
        memoryLayout: ChipMemoryLayout(
            pageSize: 4, pageCount: 45,
            ccPage: 3, ndefRange: 4 ... 39,
            lockPages: [2], dynamicLockPage: 40,
            pwdPage: 43, packPage: 44,
            configPages: [41, 42]
        )
    )

    static let ntag213TT = ChipProfile(
        id: .ntag213TT,
        family: .type2(.ntag213TT),
        capabilities: [
            .ndefRead, .ndefWrite, .rawTransceive,
            .passwordAuth, .permanentLock,
            .memoryRead, .memoryWrite, .formatCC,
            .signatureRead, .counterRead, .tamperStatus, .fastRead,
        ],
        displayName: "NTAG213 TT",
        manufacturer: "NXP",
        memoryLayout: ChipMemoryLayout(
            pageSize: 4, pageCount: 45,
            ccPage: 3, ndefRange: 4 ... 39,
            lockPages: [2], dynamicLockPage: 40,
            pwdPage: 43, packPage: 44,
            configPages: [41, 42]
        )
    )

    static let ntag215 = ChipProfile(
        id: .ntag215,
        family: .type2(.ntag215),
        capabilities: [
            .ndefRead, .ndefWrite, .rawTransceive,
            .passwordAuth, .permanentLock,
            .memoryRead, .memoryWrite, .formatCC,
            .signatureRead, .counterRead, .fastRead,
        ],
        displayName: "NTAG215",
        manufacturer: "NXP",
        memoryLayout: ChipMemoryLayout(
            pageSize: 4, pageCount: 135,
            ccPage: 3, ndefRange: 4 ... 129,
            lockPages: [2], dynamicLockPage: 130,
            pwdPage: 133, packPage: 134,
            configPages: [131, 132]
        )
    )

    static let ntag216 = ChipProfile(
        id: .ntag216,
        family: .type2(.ntag216),
        capabilities: [
            .ndefRead, .ndefWrite, .rawTransceive,
            .passwordAuth, .permanentLock,
            .memoryRead, .memoryWrite, .formatCC,
            .signatureRead, .counterRead, .fastRead,
        ],
        displayName: "NTAG216",
        manufacturer: "NXP",
        memoryLayout: ChipMemoryLayout(
            pageSize: 4, pageCount: 231,
            ccPage: 3, ndefRange: 4 ... 225,
            lockPages: [2], dynamicLockPage: 226,
            pwdPage: 229, packPage: 230,
            configPages: [227, 228]
        )
    )

    static let ntag424DNA = ChipProfile(
        id: .ntag424DNA,
        family: .type4(.ntag424DNA),
        capabilities: [
            .ndefRead, .ndefWrite, .rawTransceive,
            .passwordAuth, .signatureRead, .sunMessages,
        ],
        displayName: "NTAG424 DNA",
        manufacturer: "NXP",
        // Total user memory is 416 B across three ISO 7816-4 files —
        // CC (32) + NDEF (256) + protected/proprietary (128) — per the NXP
        // NT4H2421Gx datasheet. We report the full figure (not just the 256 B
        // NDEF file): the proprietary file is real storage, only gated behind
        // AES auth. Flat byte addressing (pageSize 1) since the chip is APDU-
        // driven, not page-addressed; dumps/raw reads are capability-gated off.
        memoryLayout: ChipMemoryLayout(
            pageSize: 1, pageCount: 416,
            ccPage: nil, ndefRange: nil
        )
    )

    static let mifareUltralightEV1_48 = ChipProfile(
        id: .mifareUltralightEV1_48,
        family: .type2(.mifareUltralightEV1_48),
        capabilities: [
            .ndefRead, .ndefWrite, .rawTransceive,
            .passwordAuth, .permanentLock,
            .memoryRead, .memoryWrite, .formatCC,
            // MF0ULx1 §8.5 / AN11340: Ultralight EV1 carries an NXP originality
            // signature over READ_SIG (0x3C) and three independent 24-bit one-way
            // counters (READ_CNT 0x39 / INCR_CNT 0xA5), unlike NTAG21x's single
            // counter. `.signatureRead` was previously omitted, which silently
            // skipped the harness's signature step on both EV1 variants.
            .counterRead, .signatureRead, .fastRead,
        ],
        displayName: "MIFARE Ultralight EV1 (48b)",
        manufacturer: "NXP",
        memoryLayout: ChipMemoryLayout(
            pageSize: 4, pageCount: 20,
            ccPage: 3, ndefRange: 4 ... 15,
            // MF0UL11 has no dynamic lock page — the 48-byte user area is fully
            // covered by the static lock bytes at page 2. CFG0=16, CFG1=17.
            lockPages: [2], dynamicLockPage: nil,
            pwdPage: 18, packPage: 19,
            configPages: [16, 17]
        )
    )

    static let mifareUltralightEV1_128 = ChipProfile(
        id: .mifareUltralightEV1_128,
        family: .type2(.mifareUltralightEV1_128),
        capabilities: [
            .ndefRead, .ndefWrite, .rawTransceive,
            .passwordAuth, .permanentLock,
            .memoryRead, .memoryWrite, .formatCC,
            .counterRead, .signatureRead, .fastRead,
        ],
        displayName: "MIFARE Ultralight EV1 (128b)",
        manufacturer: "NXP",
        memoryLayout: ChipMemoryLayout(
            pageSize: 4, pageCount: 41,
            ccPage: 3, ndefRange: 4 ... 35,
            lockPages: [2], dynamicLockPage: 36,
            pwdPage: 39, packPage: 40,
            configPages: [37, 38]
        )
    )

    /// MIFARE Ultralight C (MF0ICU2). Pre-EV1 silicon: 48 pages (192 B) with a
    /// 144 B user area at 04h-27h, and a 16-byte 2-key 3DES credential instead
    /// of the NTAG21x PWD/PACK pair.
    ///
    /// Every absent capability below is from rev 3.3 Table 14, which is an
    /// exhaustive command list containing only READ, WRITE, COMPATIBILITY_WRITE
    /// and AUTHENTICATE:
    ///   - no `GET_VERSION` (60h), which is why these tags were unidentifiable
    ///     until the halted-probe recovery landed
    ///   - no `PWD_AUTH` (1Bh) so **no `.passwordAuth`**; it authenticates with
    ///     `.tripleDESAuth` instead, and `Type2ConfigLayout.for` returns `nil`
    ///   - no `FAST_READ` (3Ah) so no `.fastRead`
    ///   - no `READ_SIG` (3Ch) so no `.signatureRead`
    ///   - no `READ_CNT` (39h) so no `.counterRead`. The chip does have a 16-bit
    ///     counter, but at page 29h via an ordinary READ, with increment
    ///     semantics unlike NTAG21x's (rev 3.3 §7.5.11). `.counterRead` in this
    ///     codebase means the 39h command specifically.
    ///
    /// `.formatCC` stands and matters: page 3 is blank at delivery (Table 13),
    /// so unlike NTAG 210µ this chip genuinely needs a format before first use.
    static let mifareUltralightC = ChipProfile(
        id: .mifareUltralightC,
        family: .type2(.mifareUltralightC),
        capabilities: [
            .ndefRead, .ndefWrite, .rawTransceive,
            .tripleDESAuth, .permanentLock,
            .memoryRead, .memoryWrite, .formatCC,
        ],
        displayName: "MIFARE Ultralight C",
        manufacturer: "NXP",
        memoryLayout: ChipMemoryLayout(
            pageSize: 4, pageCount: 48,
            ccPage: 3, ndefRange: 4 ... 39,
            // Static lock bytes at page 2 (bytes 2-3) cover pages 03h-0Fh;
            // lock bytes 2-3 at page 28h (bytes 0-1) cover 10h-27h and the
            // config area above it (rev 3.3 §7.5.2 / §7.5.3).
            lockPages: [2], dynamicLockPage: 40,
            // No PWD/PACK pages exist on this chip. AUTH0 (42) and AUTH1 (43)
            // are the config pages; the key occupies 44-47 and is write-only.
            pwdPage: nil, packPage: nil,
            configPages: [42, 43]
        )
    )

    static let emV10 = ChipProfile(
        id: .emV10,
        family: .type2(.emV10),
        capabilities: [.ndefRead, .ndefWrite, .rawTransceive, .memoryRead, .memoryWrite],
        displayName: "EM V10",
        manufacturer: "EM Microelectronic",
        memoryLayout: ChipMemoryLayout(pageSize: 4, pageCount: 16, ccPage: 3, ndefRange: 4 ... 15)
    )

    static let emV11 = ChipProfile(
        id: .emV11,
        family: .type2(.emV11),
        capabilities: [.ndefRead, .ndefWrite, .rawTransceive, .memoryRead, .memoryWrite],
        displayName: "EM V11",
        manufacturer: "EM Microelectronic",
        memoryLayout: ChipMemoryLayout(pageSize: 4, pageCount: 16, ccPage: 3, ndefRange: 4 ... 15)
    )

    static let emV16 = ChipProfile(
        id: .emV16,
        family: .type2(.emV16),
        capabilities: [.ndefRead, .ndefWrite, .rawTransceive, .memoryRead, .memoryWrite],
        displayName: "EM V16",
        manufacturer: "EM Microelectronic",
        memoryLayout: ChipMemoryLayout(pageSize: 4, pageCount: 16, ccPage: 3, ndefRange: 4 ... 15)
    )

    /// What **every** 28-block NXP Type-5 tag resolves to, which is why it does
    /// not advertise `.passwordAuth`.
    ///
    /// 28 blocks (112 B) is the geometry of the plain ICODE SLI as much as the
    /// SLIX, and the SLIX-S and SLIX-L sit in the same range. Of those, the SLI
    /// has no password machinery at all and the SLIX has only an EAS/AFI
    /// password; neither can be driven by the write-protection backend.
    /// `PROTECT PAGE` and the read/write protection passwords are SLIX2
    /// features (SL2S2602 §9.5.3.6, §9.2.3).
    ///
    /// The IC-reference byte does not separate them: it reads `0x01` on the
    /// SLIX and the SLIX2 alike, and so does UID byte 2 (live-verified
    /// 2026-08-07, see `iso15693Profile`). So the honest answer is to withhold
    /// the affordance rather than offer one that can only produce a ~320 ms
    /// timeout and then "Lost the tag mid-read" on a chip that answers B3h with
    /// nothing.
    ///
    /// This is a user-visible reduction for anyone holding a genuine SLIX-S,
    /// which does have read/write passwords. If a discriminator is ever found
    /// (the ABh feature-flag bytes are the obvious candidate) the capability
    /// comes back for exactly that chip. `ProtectionStyle.backendStyle` must
    /// stay in agreement with this set; `ChipIdentificationTests` pins both.
    static let icodeSlix = ChipProfile(
        id: .icodeSlix,
        family: .type5(.icodeSlix),
        capabilities: [
            .ndefRead, .ndefWrite, .rawTransceive,
            .permanentLock,
            .memoryRead, .memoryWrite, .formatCC,
        ],
        displayName: "ICODE SLIX",
        manufacturer: "NXP",
        memoryLayout: ChipMemoryLayout(pageSize: 4, pageCount: 28, ndefRange: 0 ... 27)
    )

    /// ICODE SLIX2 (SL2S2602). Four times the SLIX's memory: 80 blocks × 4 B =
    /// 320 B (2560-bit), and the only ICODE in this catalogue with the read and
    /// write protection passwords plus `PROTECT PAGE` that the Type-5
    /// protection backend drives. It is therefore the only Type-5 profile that
    /// advertises `.passwordAuth`; see `icodeSlix` for why its 28-block sibling
    /// does not.
    ///
    /// Distinguished from the SLIX by **block geometry alone**. The IC-reference
    /// byte reads `0x01` on both and so does UID byte 2, live-verified
    /// 2026-08-07, which is why three earlier code comments proposing an
    /// IC-reference discriminator were wrong.
    static let icodeSlix2 = ChipProfile(
        id: .icodeSlix2,
        family: .type5(.icodeSlix2),
        capabilities: [
            .ndefRead, .ndefWrite, .rawTransceive,
            .passwordAuth, .permanentLock,
            .memoryRead, .memoryWrite, .formatCC,
        ],
        displayName: "ICODE SLIX2",
        manufacturer: "NXP",
        memoryLayout: ChipMemoryLayout(pageSize: 4, pageCount: 80, ndefRange: 0 ... 79)
    )

    // MARK: Generic fallbacks

    //
    // Reported when a tag's *family* is known but the exact model can't be
    // fingerprinted over the air. They give the scan UI an honest name and a
    // conservative capability set instead of "Unknown".

    static let genericIso15693 = ChipProfile(
        id: .genericIso15693,
        family: .type5(.generic),
        // `.formatCC` is advertised because the Type-5 CC lives in a rewritable
        // block 0; `factoryType5CC` still returns nil until the tag self-reports
        // its geometry, and the format operation refuses cleanly in that case.
        capabilities: [.ndefRead, .ndefWrite, .rawTransceive, .memoryRead, .memoryWrite, .formatCC],
        displayName: "ISO 15693",
        manufacturer: "Unknown",
        memoryLayout: ChipMemoryLayout(pageSize: 4, pageCount: 0)
    )

    static let genericFeliCa = ChipProfile(
        id: .genericFeliCa,
        family: .felica,
        capabilities: [.ndefRead, .ndefWrite, .rawTransceive],
        displayName: "FeliCa",
        manufacturer: "Sony",
        memoryLayout: ChipMemoryLayout(pageSize: 16, pageCount: 0)
    )

    static let genericMifareDESFire = ChipProfile(
        id: .genericMifareDESFire,
        family: .type4(.desfireGeneric),
        // DESFire stores data in key-protected applications, not an NDEF area
        // we can read or write blind — so only raw transceive is advertised.
        // A DESFire that *does* host an NDEF app is still read opportunistically
        // by `readNDEF()`, which probes the tag at runtime.
        capabilities: [.rawTransceive],
        displayName: "MIFARE DESFire",
        manufacturer: "NXP",
        memoryLayout: ChipMemoryLayout(pageSize: 1, pageCount: 0)
    )

    // Per-generation DESFire entries. These exist so `profile(for:)` and the
    // display-name lookup in the scan history resolve a generation the app has
    // already identified, rather than returning nil.
    //
    // They deliberately declare **no storage size**: DESFire ships in 2/4/8 KB
    // SKUs that are indistinguishable by generation alone, so the authority on
    // actual capacity is `identify(desFireVersion:)`, which synthesises the
    // profile from the card's own GET_VERSION storage byte. A size here would be
    // a guess that silently overrides a measurement.
    static let mifareDESFireEV1 = desFireGeneration(.mifareDESFireEV1, .desfireEV1)
    static let mifareDESFireEV2 = desFireGeneration(.mifareDESFireEV2, .desfireEV2)
    static let mifareDESFireEV3 = desFireGeneration(.mifareDESFireEV3, .desfireEV3)

    private static func desFireGeneration(_ id: ChipID, _ variant: Type4Variant) -> ChipProfile {
        ChipProfile(
            id: id,
            family: .type4(variant),
            capabilities: [.rawTransceive],
            displayName: variant.shortName,
            manufacturer: "NXP",
            memoryLayout: ChipMemoryLayout(pageSize: 1, pageCount: 0)
        )
    }

    /// Electronic passport (ICAO eMRTD). Data lives behind BAC/PACE access
    /// control and is read-only after the holder supplies the MRZ — so no NDEF,
    /// no writes, only `.epassportRead` (plus raw transceive for diagnostics).
    /// Random per-tap UID and opaque file structure, so no memory layout.
    static let ePassport = ChipProfile(
        id: .ePassport,
        family: .type4(.ePassport),
        capabilities: [.epassportRead, .rawTransceive],
        displayName: "ePassport",
        // The chip vendor (NXP / Infineon / Thales …) isn't read, so we don't
        // claim one; "Unknown" is hidden by the info card.
        manufacturer: "Unknown",
        memoryLayout: ChipMemoryLayout(pageSize: 1, pageCount: 0)
    )
}

/// What could be decoded from a `GET_VERSION` block that `ChipCatalog` has no
/// profile for.
///
/// This is **display-only, on purpose**. It deliberately carries no page map,
/// no NDEF range and no capabilities: everything here is read straight off the
/// wire, whereas a memory layout is a datasheet claim. Synthesising a plausible
/// `ChipProfile` for an unrecognised chip would let the write paths address
/// pages nobody has verified exist — and on a Type-2 tag the CC and lock pages
/// are one-time-programmable, so a guess there is permanent.
///
/// The goal is narrower and safer: when the app can't name a chip, show the
/// user (and a bug report) exactly what the chip said about itself, so the next
/// unrecognised tag is diagnosable without a DEBUG build and a log tail.
public struct UnidentifiedChipReport: Hashable, Sendable {
    /// Raw 8-byte version block, as received.
    public let versionBlock: Data
    /// Decoded vendor name, or `nil` when the ID isn't one we know.
    public let vendor: String?
    /// Decoded product family, e.g. "NTAG" or "MIFARE Ultralight".
    public let productType: String?
    /// Human-readable storage figure, honouring the range flag.
    public let storage: String?
    /// `major.minor` product version.
    public let version: String?

    public init(versionBlock: Data, vendor: String?, productType: String?, storage: String?, version: String?) {
        self.versionBlock = versionBlock
        self.vendor = vendor
        self.productType = productType
        self.storage = storage
        self.version = version
    }

    /// Colon-delimited version block, for display and bug reports.
    public var versionHex: String {
        versionBlock.hexString
    }

    /// One-line summary of everything decoded, e.g.
    /// `"NXP · NTAG · 32-64 bytes · v2.0"`. `nil` when nothing decoded.
    public var summary: String? {
        let parts = [vendor, productType, storage, version].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension ChipCatalog {
    /// Best-effort decode of a `GET_VERSION` block the catalog can't match to a
    /// profile. Returns `nil` only when the block is too short to mean anything.
    ///
    /// Field layout is the one every NXP Type-2 datasheet shares (see
    /// `identify(getVersion:)`). Unknown byte values are reported as raw hex
    /// rather than guessed at — "product type 07h" is a useful thing to paste
    /// into a bug report; a confident wrong name is not.
    public static func describe(getVersion response: Data) -> UnidentifiedChipReport? {
        guard response.count >= 8 else { return nil }
        let vendorID = response[1]
        let productType = response[2]
        let major = response[4]
        let minor = response[5]
        let storageSize = response[6]

        let vendor: String? = vendorID == 0x04
            ? "NXP"
            : String(format: "Vendor %02Xh", vendorID)

        let product: String? = switch productType {
        case 0x03: "MIFARE Ultralight"
        case 0x04: "NTAG"
        default: String(format: "Product type %02Xh", productType)
        }

        return UnidentifiedChipReport(
            versionBlock: response,
            vendor: vendor,
            productType: product,
            storage: describeStorageSize(storageSize),
            version: "v\(major).\(minor)"
        )
    }

    /// Decode a Type-2 storage-size byte to a human-readable figure.
    ///
    /// The encoding is `n = byte >> 1`, and the **low bit is a range flag**: when
    /// clear the size is exactly `2^n`; when set it is somewhere strictly between
    /// `2^n` and `2^(n+1)`. Reporting the lower bound as if it were the size is
    /// the specific mistake that makes a 48-byte NTAG 210µ (`0Bh`) look like a
    /// 32-byte chip, so the range is surfaced honestly instead.
    static func describeStorageSize(_ byte: UInt8) -> String? {
        let exponent = Int(byte >> 1)
        guard (1 ... 30).contains(exponent) else { return nil }
        let lower = 1 << exponent
        if byte & 0x01 == 0 {
            return "\(lower) bytes"
        }
        return "\(lower)-\(lower << 1) bytes"
    }
}
