import Foundation

/// The seed library of built-in raw command presets. The Advanced Console
/// surfaces these grouped by `family`. **Values curated, not copied** — names
/// are written in Hex Pro voice; functionally interchangeable byte sequences
/// (timing, addressing flags, padding bytes) are chosen independently.
public enum CommandPresetCatalog {
    /// All built-in presets, in a stable order suitable for direct display.
    public static let builtIn: [CommandPreset] = {
        var presets: [CommandPreset] = []
        presets.append(contentsOf: type2Common)
        presets.append(contentsOf: ntag21xCommon)
        presets.append(contentsOf: ntag213)
        presets.append(contentsOf: ntag215)
        presets.append(contentsOf: ntag216)
        presets.append(contentsOf: ntag213TT)
        presets.append(contentsOf: ntag424DNA)
        presets.append(contentsOf: mifareUltralightEV1_48)
        presets.append(contentsOf: mifareUltralightEV1_128)
        presets.append(contentsOf: mifareUltralightC)
        presets.append(contentsOf: type5Iso15693)
        presets.append(contentsOf: emV10)
        presets.append(contentsOf: emV11)
        presets.append(contentsOf: emV16)
        return presets
    }()

    /// Presets whose `family` matches the supplied family — used by the
    /// console to surface chip-appropriate commands first.
    public static func presets(for family: TagFamily) -> [CommandPreset] {
        builtIn.filter { $0.family == family }
    }

    /// Convenience: presets grouped by display section (family shortName).
    /// Insertion order preserved.
    public static func grouped() -> [(family: TagFamily, presets: [CommandPreset])] {
        var seen: [TagFamily] = []
        var bucket: [TagFamily: [CommandPreset]] = [:]
        for preset in builtIn {
            if bucket[preset.family] == nil {
                seen.append(preset.family)
            }
            bucket[preset.family, default: []].append(preset)
        }
        return seen.map { ($0, bucket[$0] ?? []) }
    }

    // MARK: - Shared builders

    /// Build a Type-2 "format NDEF" preset from the chip's canonical
    /// `ChipProfile.factoryCC`, so a console preset can never disagree with the
    /// app's own format operation or the chip simulators. Page 3 is **OTP** —
    /// writes OR bits and can never be cleared — so a hardcoded size byte that
    /// drifts from the datasheet permanently mis-declares a real tag's NDEF area.
    /// `blankTrailingPage` appends the page-5 clear the Ultralight EV1 sequences
    /// carry (the EM chains stop at page 4).
    private static func formatNDEFPreset(
        _ name: String,
        _ family: TagFamily,
        _ chip: ChipID,
        blankTrailingPage: Bool
    ) -> CommandPreset? {
        // No fallback CC. A chip without a datasheet-verified `factoryCC` gets
        // **no format preset at all** rather than one built from a guess: page 3
        // is OTP, so a preset that ships the wrong size byte hands the user a
        // one-shot, irreversible mis-format of a real tag. Callers `compactMap`
        // this away, so a missing profile costs a menu entry, not a tag.
        guard let cc = ChipCatalog.profile(for: chip)?.factoryCC else { return nil }
        let ccText = cc.map { String(format: "%02X", $0) }.joined(separator: ":")
        let declaredBytes = Int(cc[cc.startIndex + 2]) * 8
        var steps = ["A2:03:\(ccText)", "A2:04:03:00:FE:00"]
        if blankTrailingPage {
            steps.append("A2:05:00:00:00:00")
        }
        return CommandPreset(
            name: name,
            family: family,
            sequenceText: steps.joined(separator: ", "),
            notes: "Write the Capability Container \(ccText) (NDEF, \(declaredBytes) bytes) to the OTP page, then an empty NDEF TLV at page 4."
        )
    }

    // MARK: - Type 2 / ISO 14443-3A common

    static let type2Common: [CommandPreset] = [
        CommandPreset(
            name: "Read 16 bytes",
            family: .type2(.unknown),
            sequenceText: "30:00",
            notes: "READ command reads 16 bytes (4 pages) starting at the page in byte 2."
        ),
        CommandPreset(
            name: "Write 4 bytes",
            family: .type2(.unknown),
            sequenceText: "A2:04:00:00:00:00",
            notes: "WRITE command writes 4 bytes to the page in byte 2. Byte 2 must be a user-memory page."
        ),
        CommandPreset(
            name: "Halt",
            family: .type2(.unknown),
            sequenceText: "50:00:00",
            notes: "Force the tag into HALT state. Useful for stress tests of the polling loop."
        ),
    ]

    // MARK: - NTAG21x common

    static let ntag21xCommon: [CommandPreset] = [
        CommandPreset(
            name: "Get product version",
            family: .type2(.ntag215),
            sequenceText: "60",
            expectedResponseHex: "00:04:04:02:01:00:11:03",
            notes: "GET_VERSION returns 8 bytes identifying the chip. NTAG215 returns 00:04:04:02:01:00:11:03."
        ),
        CommandPreset(
            name: "Read signature",
            family: .type2(.ntag215),
            sequenceText: "3C:00",
            notes: "READ_SIG returns 32-byte ECDSA signature over the UID (NTAG21x/213-TT/424)."
        ),
        CommandPreset(
            name: "Read NFC counter",
            family: .type2(.ntag215),
            sequenceText: "39:02",
            notes: "READ_CNT returns the 24-bit NFC counter value. Increments on every NDEF read."
        ),
        CommandPreset(
            name: "Read multiple pages",
            family: .type2(.ntag215),
            sequenceText: "3A:04:0F",
            notes: "FAST_READ from page in byte 2 to page in byte 3 inclusive."
        ),
        CommandPreset(
            name: "Password auth (PWD_AUTH)",
            family: .type2(.ntag215),
            sequenceText: "1B:FF:FF:FF:FF",
            expectedResponseHex: "00:00",
            notes: "Send 4-byte password; chip responds with 2-byte PACK. Default password FF:FF:FF:FF."
        ),
    ]

    // MARK: - NTAG213-specific (NFC counter ACCESS byte at page 0x2A)

    static let ntag213: [CommandPreset] = [
        CommandPreset(
            name: "Enable NFC counter (NTAG213), replaces all of CFG1",
            family: .type2(.ntag213),
            sequenceText: "A2:2A:10:00:00:00",
            notes: "Sets NFC_CNT_EN in the ACCESS byte, which is byte 0 of CFG1 at page 0x2A: bit 7 PROT, "
                + "bit 6 CFGLCK, bit 4 NFC_CNT_EN, bits 2-0 AUTH_LIM. A WRITE replaces the whole page, so "
                + "sending this as it stands clears PROT and AUTH_LIM on a tag that had them set, and "
                + "zeroes byte 1, which ships as 05 on every NTAG213 surveyed. Read the page back with "
                + "30:29 and reissue with bytes 1-3 unchanged. AUTH0 is not on this page at all: it is "
                + "byte 3 of CFG0."
        ),
        CommandPreset(
            name: "Disable NFC counter (NTAG213), replaces all of CFG1",
            family: .type2(.ntag213),
            sequenceText: "A2:2A:00:00:00:00",
            notes: "Clears NFC_CNT_EN in the ACCESS byte at page 0x2A. Same whole-page caveat as its "
                + "twin above: read 30:29 first and preserve bytes 1-3."
        ),
    ]

    // MARK: - NTAG215-specific (ACCESS byte at page 0x84)

    static let ntag215: [CommandPreset] = [
        CommandPreset(
            name: "Enable NFC counter (NTAG215), replaces all of CFG1",
            family: .type2(.ntag215),
            sequenceText: "A2:84:10:00:00:00",
            notes: "Sets NFC_CNT_EN in the ACCESS byte, byte 0 of CFG1 at page 0x84. A WRITE replaces "
                + "the whole page, so this clears PROT and AUTH_LIM on a tag that had them set. Read "
                + "30:83 first and reissue with bytes 1-3 unchanged."
        ),
        CommandPreset(
            name: "Disable NFC counter (NTAG215), replaces all of CFG1",
            family: .type2(.ntag215),
            sequenceText: "A2:84:00:00:00:00",
            notes: "Clears NFC_CNT_EN at page 0x84. Same whole-page caveat as its twin above."
        ),
    ]

    // MARK: - NTAG216-specific (ACCESS byte at page 0xE4)

    static let ntag216: [CommandPreset] = [
        CommandPreset(
            name: "Enable NFC counter (NTAG216), replaces all of CFG1",
            family: .type2(.ntag216),
            sequenceText: "A2:E4:10:00:00:00",
            notes: "Sets NFC_CNT_EN in the ACCESS byte, byte 0 of CFG1 at page 0xE4. A WRITE replaces "
                + "the whole page, so this clears PROT and AUTH_LIM on a tag that had them set, and "
                + "zeroes byte 1, which ships as 05 on every NTAG216 surveyed. Read 30:E3 first and "
                + "reissue with bytes 1-3 unchanged."
        ),
        CommandPreset(
            name: "Disable NFC counter (NTAG216), replaces all of CFG1",
            family: .type2(.ntag216),
            sequenceText: "A2:E4:00:00:00:00",
            notes: "Clears NFC_CNT_EN at page 0xE4. Same whole-page caveat as its twin above."
        ),
    ]

    // MARK: - NTAG213 TT (tag tamper)

    static let ntag213TT: [CommandPreset] = [
        CommandPreset(
            name: "Tag tamper status",
            family: .type2(.ntag213TT),
            sequenceText: "30:24",
            notes: "Read page 0x24 to inspect TT_STATUS byte."
        ),
        CommandPreset(
            name: "Enable tag tamper, replaces all of TT_CONFIG",
            family: .type2(.ntag213TT),
            sequenceText: "A2:25:01:00:00:00",
            notes: "Sets TT_ENABLE in TT_CONFIG at page 0x25. A WRITE replaces all four bytes, and no "
                + "NTAG213 TT has been read in this repo, so what the other three hold on a delivered "
                + "tag is not known here. Read 30:25 first and reissue with bytes 1-3 unchanged."
        ),
        CommandPreset(
            name: "Disable tag tamper, replaces all of TT_CONFIG",
            family: .type2(.ntag213TT),
            sequenceText: "A2:25:00:00:00:00",
            notes: "Clears TT_ENABLE at page 0x25. Same whole-page caveat as its twin above."
        ),
    ]

    // MARK: - NTAG424 DNA (ISO 7816 APDU)

    static let ntag424DNA: [CommandPreset] = [
        CommandPreset(
            name: "Select NDEF application",
            family: .type4(.ntag424DNA),
            sequenceText: "00:A4:04:00:07:D2:76:00:00:85:01:01:00",
            expectedResponseHex: "90:00",
            notes: "SELECT by AID D2:76:00:00:85:01:01 (NDEF Tag Application)."
        ),
        CommandPreset(
            name: "Select CC file",
            family: .type4(.ntag424DNA),
            sequenceText: "00:A4:00:0C:02:E1:03",
            expectedResponseHex: "90:00",
            notes: "SELECT capability container by file ID E1:03."
        ),
        CommandPreset(
            name: "Read CC file",
            family: .type4(.ntag424DNA),
            sequenceText: "00:B0:00:00:0F",
            notes: "READ BINARY 15 bytes from offset 0. Returns CC file contents + 90:00."
        ),
        CommandPreset(
            name: "Select NDEF file",
            family: .type4(.ntag424DNA),
            sequenceText: "00:A4:00:0C:02:E1:04",
            expectedResponseHex: "90:00",
            notes: "SELECT NDEF file by file ID E1:04."
        ),
        CommandPreset(
            name: "Read NDEF length",
            family: .type4(.ntag424DNA),
            sequenceText: "00:B0:00:00:02",
            notes: "READ BINARY first 2 bytes of NDEF file: gives NLEN."
        ),
        CommandPreset(
            name: "Get file settings (file 02)",
            family: .type4(.ntag424DNA),
            sequenceText: "90:F5:00:00:01:02:00",
            notes: "Native DESFire-style GET FILE SETTINGS on file number 0x02."
        ),
        CommandPreset(
            name: "Authenticate EV2 First (skeleton)",
            family: .type4(.ntag424DNA),
            sequenceText: "90:71:00:00:02:00:00:00",
            notes: "AuthenticateEV2First on key 0. Full chain requires CMAC and is gated by Phase 6."
        ),
    ]

    // MARK: - MIFARE Ultralight EV1 (48b / 128b)

    static let mifareUltralightEV1_48: [CommandPreset] = [
        formatNDEFPreset(
            "Format NDEF (Ultralight EV1 48b)",
            .type2(.mifareUltralightEV1_48),
            .mifareUltralightEV1_48,
            blankTrailingPage: true
        ),
        CommandPreset(
            name: "Read counter (Ultralight EV1)",
            family: .type2(.mifareUltralightEV1_48),
            sequenceText: "39:00",
            notes: "READ_CNT 0x39 with counter index in byte 2 (00/01/02). EV1 has three independent 24-bit one-way counters."
        ),
        CommandPreset(
            name: "Increment counter (Ultralight EV1)",
            family: .type2(.mifareUltralightEV1_48),
            sequenceText: "A5:00:01:00:00:00",
            notes: "INCR_CNT 0xA5: increment counter index in byte 2 by the 24-bit value in bytes 3-5. One-way: a counter can never be decremented."
        ),
        CommandPreset(
            name: "Check tearing event (Ultralight EV1)",
            family: .type2(.mifareUltralightEV1_48),
            sequenceText: "3E:00",
            notes: "CHECK_TEARING_EVENT 0x3E with counter index in byte 2. Returns 1 byte: 0xBD means no tearing event occurred on that counter."
        ),
    ].compactMap { $0 }

    static let mifareUltralightEV1_128: [CommandPreset] = [
        formatNDEFPreset(
            "Format NDEF (Ultralight EV1 128b)",
            .type2(.mifareUltralightEV1_128),
            .mifareUltralightEV1_128,
            blankTrailingPage: true
        ),
        CommandPreset(
            name: "Read counter (Ultralight EV1 128b)",
            family: .type2(.mifareUltralightEV1_128),
            sequenceText: "39:00",
            notes: "READ_CNT 0x39 with counter index in byte 2 (00/01/02). EV1 has three independent 24-bit one-way counters."
        ),
        CommandPreset(
            name: "Increment counter (Ultralight EV1 128b)",
            family: .type2(.mifareUltralightEV1_128),
            sequenceText: "A5:00:01:00:00:00",
            notes: "INCR_CNT 0xA5: increment counter index in byte 2 by the 24-bit value in bytes 3-5. One-way: a counter can never be decremented."
        ),
        CommandPreset(
            name: "Check tearing event (Ultralight EV1 128b)",
            family: .type2(.mifareUltralightEV1_128),
            sequenceText: "3E:00",
            notes: "CHECK_TEARING_EVENT 0x3E with counter index in byte 2. Returns 1 byte: 0xBD means no tearing event occurred on that counter."
        ),
    ].compactMap { $0 }

    // MARK: - Type 5 / ISO 15693

    static let type5Iso15693: [CommandPreset] = [
        CommandPreset(
            name: "Get system info",
            family: .type5(.icodeSlix),
            sequenceText: "02:2B",
            notes: "ISO 15693 Get System Information. Flag byte 0x02 = high data rate, no addressing."
        ),
        CommandPreset(
            name: "Read single block",
            family: .type5(.icodeSlix),
            sequenceText: "02:20:00",
            notes: "Read single block at the index in byte 3."
        ),
        CommandPreset(
            name: "Read multiple blocks (0-3)",
            family: .type5(.icodeSlix),
            sequenceText: "02:23:00:03",
            notes: "Read blocks from byte 3 inclusive for (byte 4 + 1) blocks."
        ),
        CommandPreset(
            name: "Write single block",
            family: .type5(.icodeSlix),
            sequenceText: "02:21:00:00:00:00:00",
            notes: "Write 4 bytes at block index in byte 3. Block content in bytes 4-7."
        ),
        CommandPreset(
            name: "Lock block",
            family: .type5(.icodeSlix),
            sequenceText: "02:22:00",
            notes: "Permanently lock the block at index byte 3. Irreversible."
        ),
        CommandPreset(
            name: "Write AFI",
            family: .type5(.icodeSlix),
            sequenceText: "02:27:00",
            notes: "Set Application Family Identifier to byte 3."
        ),
        CommandPreset(
            name: "Lock AFI",
            family: .type5(.icodeSlix),
            sequenceText: "02:28",
            notes: "Permanently lock the AFI. Irreversible."
        ),
        CommandPreset(
            name: "Write DSFID",
            family: .type5(.icodeSlix),
            sequenceText: "02:29:00",
            notes: "Set Data Storage Format Identifier to byte 3."
        ),
        CommandPreset(
            name: "Lock DSFID",
            family: .type5(.icodeSlix),
            sequenceText: "02:2A",
            notes: "Permanently lock the DSFID. Irreversible."
        ),
        CommandPreset(
            name: "Get multi-block security status",
            family: .type5(.icodeSlix),
            sequenceText: "02:2C:00:03",
            notes: "Return per-block lock status from byte 3 for (byte 4 + 1) blocks."
        ),
    ]

    // MARK: - EM Microelectronic V10 / V11 / V16

    // MARK: - MIFARE Ultralight C

    /// Deliberately a short list. Ultralight C's entire command set is READ,
    /// WRITE, COMPATIBILITY_WRITE and AUTHENTICATE (rev 3.3 Table 14), so the
    /// Ultralight EV1 presets next door would offer five commands this chip
    /// NAKs (GET_VERSION, FAST_READ, READ_CNT, READ_SIG, PWD_AUTH), and a NAK
    /// returns a Type-2 tag to HALT for the rest of the activation.
    ///
    /// This used to end "Nothing here can halt a healthy tag", which was false:
    /// one entry below reads into the key pages, and a read there is answered
    /// with a NAK on a perfectly genuine chip. It is kept, because confirming
    /// that the key range is unreadable is a real diagnostic, and its name now
    /// says what it costs. It is the only entry here that ends the tap.
    ///
    /// `1A 00` is included because it is the most diagnostic frame on this chip,
    /// but note what it does: it opens a mutual handshake and leaves the card
    /// waiting for `AF ‖ ek(RndA ‖ RndB′)`, which the console cannot compute.
    /// Use it to confirm the chip answers `AF` + 8 bytes, then re-tap. It does
    /// not halt the tag: what NAKs is a **second** `1A 00` after a handshake has
    /// already completed (`docs/internal/chip-config-pages.md`), and this leaves
    /// the first one unfinished.
    static let mifareUltralightC: [CommandPreset] = [
        formatNDEFPreset(
            "Format NDEF (Ultralight C)",
            .type2(.mifareUltralightC),
            .mifareUltralightC,
            blankTrailingPage: true
        ),
        CommandPreset(
            name: "Read lock bytes, counter, AUTH0 and AUTH1",
            family: .type2(.mifareUltralightC),
            sequenceText: "30:28",
            notes: "Reads pages 28h-2Bh in one frame, and stops one page short of the key. Page 28h "
                + "bytes 0-1 are lock bytes 2-3; page 29h bytes 0-1 are the 16-bit one-way counter; "
                + "bytes 2-3 of both are RFU and read as 00. AUTH0 is byte 0 of page 2Ah (30h means "
                + "protection off); AUTH1 is byte 0 of page 2Bh (bit 0 set means write-only, clear "
                + "means reads are gated too). This replaces a 30:2A preset that read 2Ah-2Dh and so "
                + "ran into the key pages, which is the exact frame UltralightCLayout tells the "
                + "drivers never to send."
        ),
        CommandPreset(
            name: "Probe the key range at 2Ch, NAKs and ends the tap",
            family: .type2(.mifareUltralightC),
            sequenceText: "30:2C",
            notes: "The 3DES key at 2Ch-2Fh is write-only. A genuine MF0ICU2 answers a read there with "
                + "a NAK, and a NAK returns a Type-2 tag to HALT for the rest of the activation, so "
                + "nothing after this frame will be answered. Send it last, then re-tap. This used to "
                + "claim the pages read back as zeros and that anything else meant counterfeit "
                + "silicon; this repo's own live finding is that they do not read back at all."
        ),
        CommandPreset(
            name: "Start 3DES authenticate, leaves the handshake open",
            family: .type2(.mifareUltralightC),
            sequenceText: "1A:00",
            notes: "An Ultralight C answers AFh followed by 8 bytes of ek(RndB). It is a strong probe "
                + "for this chip but not a unique one: the EM V10 presets in this same file send 1Ah "
                + "too, and the EM simulator answers it. The handshake is left incomplete, so re-tap "
                + "before relying on anything after it. The frame does not itself halt the tag."
        ),
    ].compactMap { $0 }

    static let emV10: [CommandPreset] = [
        CommandPreset(
            name: "Read system config (EM V10)",
            family: .type2(.emV10),
            sequenceText: "30:00",
            notes: "Read 16 bytes from page 0. EM V10 system configuration block."
        ),
        CommandPreset(
            name: "Activate HF crypto mode (EM V10)",
            family: .type2(.emV10),
            sequenceText: "1A:00:00:00:00",
            notes: "Vendor-specific HF crypto activation."
        ),
        CommandPreset(
            name: "Read tamper alarm (EM V10)",
            family: .type2(.emV10),
            sequenceText: "30:08",
            notes: "Read tamper status block."
        ),
        formatNDEFPreset("V10 personalisation chain", .type2(.emV10), .emV10, blankTrailingPage: false),
    ].compactMap { $0 }

    static let emV11: [CommandPreset] = [
        CommandPreset(
            name: "Read system config (EM V11)",
            family: .type2(.emV11),
            sequenceText: "30:00",
            notes: "Read 16 bytes from page 0."
        ),
        CommandPreset(
            name: "Read tamper alarm (EM V11)",
            family: .type2(.emV11),
            sequenceText: "30:09",
            notes: "V11 places tamper status one page higher than V10."
        ),
        formatNDEFPreset("V11 personalisation chain", .type2(.emV11), .emV11, blankTrailingPage: false),
    ].compactMap { $0 }

    static let emV16: [CommandPreset] = [
        CommandPreset(
            name: "Read system config (EM V16)",
            family: .type2(.emV16),
            sequenceText: "30:00",
            notes: "Read 16 bytes from page 0."
        ),
        CommandPreset(
            name: "Read tamper alarm (EM V16)",
            family: .type2(.emV16),
            sequenceText: "30:0A",
            notes: "V16 places tamper status at page 0x0A."
        ),
        formatNDEFPreset("V16 personalisation chain", .type2(.emV16), .emV16, blankTrailingPage: false),
    ].compactMap { $0 }
}
