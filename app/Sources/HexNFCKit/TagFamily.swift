import Foundation

/// High-level family of an NFC tag. Drives identification strategy, command set,
/// and the choice of which `ConnectedTag` implementation handles the session.
public enum TagFamily: Hashable, Sendable, Codable {
    case type2(Type2Variant)
    case type4(Type4Variant)
    case type5(Type5Variant)
    case felica
    case unknown

    public var shortName: String {
        switch self {
        case .type2(let v): v.shortName
        case .type4(let v): v.shortName
        case .type5(let v): v.shortName
        case .felica: "FeliCa"
        case .unknown: "Unknown"
        }
    }

    /// Whether a flow may read this family's protection state **before** it
    /// presents a credential, or has to authenticate first.
    ///
    /// Every argument below is about silicon, which is why the rule lives here
    /// beside the other per-family facts rather than inside whichever flow
    /// needed it first. It was a private static on `WriteFlowModel`, out of
    /// reach of the Operations preflight, `HexNFCTestKit`'s plans and the
    /// enforcement verifier, and a rule nobody can reach is a rule that gets
    /// copied.
    ///
    /// Type-2 is the exception and has to be. Its configuration pages sit at or
    /// above AUTH0, so on a read-protected tag the state read is itself
    /// refused, and a refusal halts the chip for the rest of the activation:
    /// the tag gets one command and spending it on a page it is certain to
    /// refuse costs the whole session (c52ace5). `Type2PasswordDriver` keeps
    /// the same rule one level down, where it can be kept safely: `openGate`
    /// reads state first and answers `.alreadyOpen` without a frame.
    ///
    /// Everything else reads first, for two measured reasons. A Type-4 read
    /// SELECTs, and a SELECT ends a live EV2 session (2026-09-20: a plain
    /// GetFileSettings refused `91 7E` inside a session and answered `91 00`
    /// straight after the SELECT), so a read after authenticating throws the
    /// session away. And on Type-5 and Ultralight C the credential a flow is
    /// handed may be one the tag has never held, so presenting it blind is what
    /// stopped those two families ever arming a tag.
    ///
    /// Ultralight C is `.type2` by transport and is **not** the exception. The
    /// rule is about the PWD_AUTH families whose configuration pages sit at or
    /// above AUTH0 (NTAG21x, UL EV1), where a refused read costs the tap. An
    /// Ultralight C keeps AUTH0 and AUTH1 at pages 2Ah/2Bh and answers a plain
    /// `30 28` on every tag this app can reach: a read-gated one hides the very
    /// pages `ChipCatalog` identifies the chip from, so it never arrives
    /// identified as an Ultralight C at all (bench finding 14).
    ///
    /// An unidentified chip answers `false`. Without a page map there is no
    /// telling where its configuration sits, and guessing wrong costs a tap on
    /// the family where that is most expensive.
    public static func gateIsSafeToReadBeforeAuthenticating(_ family: TagFamily?) -> Bool {
        switch family {
        case .type2(.mifareUltralightC): true
        case .type2: false
        case .none: false
        default: true
        }
    }
}

/// NFC Type 2 / ISO 14443-3A variants. The vast majority of consumer-grade NFC
/// tags fall here.
public enum Type2Variant: String, Hashable, Sendable, Codable, CaseIterable {
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
    case unknown

    public var shortName: String {
        switch self {
        case .ntag210Micro: "NTAG 210µ"
        case .ntag213: "NTAG213"
        case .ntag213TT: "NTAG213 TT"
        case .ntag215: "NTAG215"
        case .ntag216: "NTAG216"
        case .ntag424DNA: "NTAG424 DNA"
        case .mifareUltralightEV1_48: "MIFARE Ultralight EV1 (48b)"
        case .mifareUltralightEV1_128: "MIFARE Ultralight EV1 (128b)"
        case .mifareUltralightC: "MIFARE Ultralight C"
        case .emV10: "EM V10"
        case .emV11: "EM V11"
        case .emV16: "EM V16"
        case .unknown: "Type 2"
        }
    }

    /// Page count for the chip's user/system memory. Used by the memory editor
    /// to bound dumps and writes.
    public var pageCount: Int {
        switch self {
        // NT2H1001: 16 pages (00h–0Fh), 64 B total. Reads past 0Fh NAK.
        case .ntag210Micro: 16
        case .ntag213, .ntag213TT: 45
        case .ntag215: 135
        case .ntag216: 231
        case .mifareUltralightEV1_48: 20
        case .mifareUltralightEV1_128: 41

        // MF0ICU2: 48 pages (00h–2Fh), 192 B total (rev 3.3 §7.5 Table 5).
        case .mifareUltralightC: 48
        case .emV10, .emV11, .emV16: 16
        case .ntag424DNA: 0
        case .unknown: 0
        }
    }

    /// Number of bytes the chip's user-memory NDEF area can hold, after
    /// reserving CC, lock and config pages.
    ///
    /// Deliberately exhaustive, with no `default:` arm. A `default: return 0`
    /// here does not fail loudly, it makes a newly added chip report **zero
    /// usable NDEF bytes app-wide**, which reads as a chip that cannot hold a
    /// message rather than as a missing case. Adding a `Type2Variant` must
    /// break this build.
    public var ndefByteCapacity: Int {
        switch self {
        // 12 user pages (04h–0Fh) × 4 B. Identical to the plain NTAG210: the µ
        // saves die area by dropping the config pages, not user memory.
        case .ntag210Micro: 48
        case .ntag213, .ntag213TT: 144
        case .ntag215: 504
        case .ntag216: 888
        case .mifareUltralightEV1_48: 48
        case .mifareUltralightEV1_128: 128

        // MF0ICU2: 36 user pages (04h–27h) × 4 B (rev 3.3 §7.5.9).
        case .mifareUltralightC: 144
        case .ntag424DNA: 256

        // EM Microelectronic silicon carries a 12-page user area in
        // `ChipCatalog`, but no datasheet in this repo states an NDEF capacity,
        // so it stays 0 rather than being guessed from the layout.
        case .emV10, .emV11, .emV16: 0
        case .unknown: 0
        }
    }
}

/// NFC Type 4 / ISO 7816 variants. These chips speak APDU, not page-read commands.
public enum Type4Variant: String, Hashable, Sendable, Codable, CaseIterable {
    case ntag424DNA
    case desfireGeneric
    case desfireEV1
    case desfireEV2
    case desfireEV3
    case ePassport
    case unknown

    public var shortName: String {
        switch self {
        case .ntag424DNA: "NTAG424 DNA"
        case .desfireGeneric: "MIFARE DESFire"
        case .desfireEV1: "MIFARE DESFire EV1"
        case .desfireEV2: "MIFARE DESFire EV2"
        case .desfireEV3: "MIFARE DESFire EV3"
        case .ePassport: "ePassport"
        case .unknown: "Type 4"
        }
    }
}

/// NFC Type 5 / ISO 15693 variants. Block-addressed (not page-addressed)
/// 13.56MHz tags. ICODE SLIX is the dominant NXP family; the variants
/// differ mainly in memory size and the presence of EAS / Privacy modes.
public enum Type5Variant: String, Hashable, Sendable, Codable, CaseIterable {
    case icodeSlix
    case icodeSlix2
    case icodeSlixS
    case icodeSlixL
    case generic
    case unknown

    public var shortName: String {
        switch self {
        case .icodeSlix: "ICODE SLIX"
        case .icodeSlix2: "ICODE SLIX2"
        case .icodeSlixS: "ICODE SLIX-S"
        case .icodeSlixL: "ICODE SLIX-L"
        case .generic: "ISO 15693"
        case .unknown: "Type 5"
        }
    }
}
