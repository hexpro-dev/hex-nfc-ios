import Foundation

/// How well a `CommandPreset` matches the tag the user just identified in the
/// Advanced Console. Drives the console's "compatible first, off-family greyed
/// and sunk to the bottom" ordering. Advisory only — every preset stays
/// runnable regardless of match (running an off-spec command is fine, the
/// match just primes the user; see `CommandPreset.family`).
public enum PresetMatch: Hashable, Sendable {
    /// No tag identified yet — render normally, keep catalog order.
    case unscored
    /// The preset's family is exactly the identified chip.
    case exact
    /// Same transport, and either a generic-within-transport preset or a sibling
    /// in the same chip line (an NTAG213 command on an NTAG215, say).
    case compatible
    /// Different transport, or a different chip line — greyed and sorted last.
    case incompatible

    /// `true` for everything except `.incompatible` — the console greys out only
    /// the incompatible presets, leaving them visible and tappable.
    public var isCompatible: Bool {
        self != .incompatible
    }

    /// Sort key: exact above compatible/unscored above incompatible. Callers
    /// break ties by catalog order to keep the sort stable.
    public var sortRank: Int {
        switch self {
        case .exact: 3
        case .compatible, .unscored: 2
        case .incompatible: 0
        }
    }
}

extension TagFamily {
    /// The broad NFC transport. Raw commands never cross this boundary — an
    /// ISO 15693 block read can't be sent to a page-addressed Type-2 chip — so a
    /// mismatch here is always `.incompatible`.
    private enum Transport: Hashable {
        case type2
        case type4
        case type5
        case felica
        case unknown
    }

    private var transport: Transport {
        switch self {
        case .type2: .type2
        case .type4: .type4
        case .type5: .type5
        case .felica: .felica
        case .unknown: .unknown
        }
    }

    /// The chip *line* within a transport — a cluster of variants close enough in
    /// command set and memory layout that a preset for one is worth surfacing for
    /// another (an NTAG213 counter command on an NTAG215). `nil` means "generic
    /// across the whole transport" (Type-2 READ/WRITE/HALT, standard ISO 15693
    /// block I/O), which matches every chip of that transport.
    private enum ChipLine: Hashable {
        case ntag21x
        case ntag210Micro
        case ntag424
        case ultralightEV1
        case ultralightC
        case emMicro
        case desfire
        case iso15693
    }

    private var chipLine: ChipLine? {
        switch self {
        case .type2(let v):
            switch v {
            case .ntag213, .ntag213TT, .ntag215, .ntag216:
                .ntag21x

            // Deliberately its own line rather than folded into `.ntag21x`: the
            // µ die has no PWD_AUTH, FAST_READ or READ_CNT, so the NTAG21x
            // preset set would advertise three commands it NAKs.
            case .ntag210Micro:
                .ntag210Micro

            case .ntag424DNA:
                .ntag424

            case .mifareUltralightEV1_48, .mifareUltralightEV1_128:
                .ultralightEV1

            // Its own line, and emphatically not `.ultralightEV1`: the name is
            // the only thing the two share. Ultralight C is pre-EV1 silicon
            // whose entire command set is READ, WRITE, COMPATIBILITY_WRITE and
            // AUTHENTICATE (rev 3.3 Table 14). Folding it into the EV1 line
            // would offer GET_VERSION, FAST_READ, READ_CNT, READ_SIG and
            // PWD_AUTH presets, all five of which this chip NAKs, and a NAK
            // returns a Type-2 tag to HALT for the rest of the activation.
            case .mifareUltralightC:
                .ultralightC

            case .emV10, .emV11, .emV16:
                .emMicro

            case .unknown:
                nil
            }

        case .type4(let v):
            switch v {
            case .ntag424DNA, .desfireGeneric, .desfireEV1, .desfireEV2, .desfireEV3:
                .desfire

            case .ePassport, .unknown:
                nil
            }

        case .type5(let v):
            switch v {
            case .icodeSlix, .icodeSlix2, .icodeSlixS, .icodeSlixL, .generic:
                .iso15693

            case .unknown:
                nil
            }

        case .felica, .unknown:
            nil
        }
    }

    /// How a preset tagged with `self` matches a tag identified as `chip`.
    ///
    /// - An unidentifiable chip (`.unknown`) never greys anything — we can't
    ///   discriminate, so every preset stays `.compatible`.
    /// - An exact family match ranks highest.
    /// - Same transport with a generic-within-transport preset *or* an
    ///   under-identified chip *or* a shared chip line is `.compatible` — this is
    ///   where NTAG213 ⇄ NTAG213 TT and the rest of the NTAG21x line cross over.
    /// - Anything else is `.incompatible`.
    public func matches(identifiedChip chip: TagFamily) -> PresetMatch {
        if case .unknown = chip {
            return .compatible
        }
        if self == chip {
            return .exact
        }
        guard transport == chip.transport else { return .incompatible }
        // Same transport: a generic preset (or a chip pinned only to its
        // transport, e.g. an EM tag that NAKs GET_VERSION) applies broadly; two
        // specific chip lines must match to be compatible.
        guard let presetLine = chipLine, let identifiedLine = chip.chipLine else {
            return .compatible
        }
        return presetLine == identifiedLine ? .compatible : .incompatible
    }
}

public extension CommandPreset {
    /// Convenience: this preset's match against an identified chip family.
    func matches(identifiedChip chip: TagFamily) -> PresetMatch {
        family.matches(identifiedChip: chip)
    }
}
