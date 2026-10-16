#if os(iOS)
import HexNFCDesign
import HexNFCKit
import SwiftUI

/// Meta card describing the scanned tag — chip model, maker, memory, supported
/// operations, UID. Shared by the record editor and the transit-card result so
/// users always see the technical facts behind the tag they tapped. Renders
/// nothing when there's no scanned tag (blank build / preset).
struct TagInfoCard: View {
    let tag: ScannedTagInfo?
    /// Optional caller-supplied rows appended after the standard ones — used by
    /// the transit view to surface facts the generic snapshot has no slot for
    /// (system code, protocol, transaction count). Empty for the editor.
    var extraRows: [(label: LocalizedStringKey, value: String)] = []

    var body: some View {
        if let tag, tag.hasContent {
            VStack(alignment: .leading, spacing: HexTokens.Spacing.s) {
                HStack(spacing: HexTokens.Spacing.s) {
                    Image(systemName: "sensor.tag.radiowaves.forward.fill")
                        .foregroundStyle(HexTokens.Color.primaryLight)
                    let chipLabel = tag.chipName ?? tag.familyName ?? String(localized: "Tag")
                    Text(verbatim: chipLabel)
                        .font(HexTokens.Font.heading)
                        .foregroundStyle(HexTokens.Color.textPrimary)
                        .hexCopyable(chipLabel)
                    Spacer(minLength: 0)
                }
                if tag.chipName != nil, let family = tag.familyName {
                    infoRow("Type", family)
                }
                if let maker = tag.manufacturer, maker != "Unknown" {
                    infoRow("Maker", maker)
                }
                if let bytes = tag.totalBytes {
                    infoRow("Memory", Self.formatMemory(ndef: tag.ndefBytes, total: bytes))
                }
                // A tag no reader can find a message on looks identical to an
                // empty one everywhere else on this card, and behaves completely
                // differently at write time. Say so, and say which of the two
                // faults it is: they take opposite repairs.
                if tag.formatState.needsAttention {
                    HStack(alignment: .firstTextBaseline, spacing: HexTokens.Spacing.m) {
                        Text("Status")
                            .font(HexTokens.Font.footnote)
                            .foregroundStyle(HexTokens.Color.textSecondary)
                        Spacer(minLength: HexTokens.Spacing.s)
                        Label(
                            tag.formatState == .noCapabilityContainer
                                ? "Not formatted" : "Data won't read",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(HexTokens.Font.body)
                        .foregroundStyle(HexTokens.Color.warning)
                    }
                }
                if let summary = tag.capabilitySummary {
                    infoRow("Supports", summary)
                }
                // Silicon features identification already knew about and the card
                // never showed: the signature, tap counter, tamper loop and SUN
                // are what tell an NTAG213 TT apart from a plain NTAG213.
                if let features = tag.featureSummary {
                    infoRow("Features", features)
                }
                if let uid = tag.uidHex {
                    infoRow("UID", uid, mono: true)
                }
                // Only ever populated when the chip couldn't be named. Shows
                // what the tag said about itself so an unrecognised chip is
                // diagnosable from this card rather than only from a DEBUG log.
                if tag.chipName == nil, let summary = tag.unidentifiedSummary {
                    infoRow("Reported", summary)
                }
                if tag.chipName == nil, let version = tag.unidentifiedVersionHex {
                    infoRow("Version bytes", version, mono: true)
                }
                // What the silicon volunteered about itself this tap. Read after
                // the records, so an absent row means "the chip didn't say",
                // never "the scan failed".
                diagnosticRows(tag.diagnostics)
                ForEach(Array(extraRows.enumerated()), id: \.offset) { _, row in
                    infoRow(row.label, row.value)
                }
            }
            .padding(HexTokens.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                HexTokens.Color.surface1,
                in: RoundedRectangle(cornerRadius: HexTokens.Radius.l, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HexTokens.Radius.l, style: .continuous)
                    .strokeBorder(HexTokens.Stroke.cardInner, lineWidth: HexTokens.Stroke.cardInnerWidth)
            )
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("editor.tagInfo")
        }
    }

    /// Memory line: usable NDEF capacity with the chip's total addressable
    /// memory in parentheses (e.g. "256 Bytes (416B Total)"). Falls back to a
    /// single figure — `formatBytes` (binary KB or raw bytes) — when there's no
    /// distinct NDEF area (DESFire, FeliCa) or it equals the total (e.g. ICODE
    /// SLIX, where the whole user memory is the NDEF area).
    static func formatMemory(ndef: Int?, total: Int) -> String {
        if let ndef, ndef > 0, ndef < total {
            return "\(ndef) Bytes (\(total)B Total)"
        }
        return formatBytes(total)
    }

    /// Human-friendly memory size: whole binary KB above 1 KB (e.g. 4096 → "4 KB"),
    /// otherwise raw bytes (e.g. 888 → "888 Bytes").
    static func formatBytes(_ bytes: Int) -> String {
        if bytes >= 1024, bytes % 1024 == 0 {
            return "\(bytes / 1024) KB"
        }
        return "\(bytes) Bytes"
    }

    /// The chip's read-only self-report. Each row renders only when that chip
    /// actually answered, so most tags show none of them and an NTAG213 TT shows
    /// three.
    @ViewBuilder
    private func diagnosticRows(_ diagnostics: TagDiagnostics) -> some View {
        // Tamper first: on a TT this is the whole reason the chip exists, and
        // "opened" is the one reading here a user might act on.
        if let tamper = diagnostics.tamper {
            HStack(alignment: .firstTextBaseline, spacing: HexTokens.Spacing.m) {
                Text("Tamper")
                    .font(HexTokens.Font.footnote)
                    .foregroundStyle(HexTokens.Color.textSecondary)
                Spacer(minLength: HexTokens.Spacing.s)
                switch tamper {
                case .intact:
                    Label("Seal intact", systemImage: "checkmark.seal.fill")
                        .font(HexTokens.Font.body)
                        .foregroundStyle(HexTokens.Color.success)

                case .opened:
                    Label("Opened", systemImage: "seal.slash.fill")
                        .font(HexTokens.Font.body)
                        .foregroundStyle(HexTokens.Color.dangerText)
                }
            }
        }

        if let taps = diagnostics.tapCount {
            infoRow("Times read", Self.formatCount(taps))
        } else if diagnostics.counterDisabled {
            // Not the same as "no counter": the hardware is there and switched
            // off, which is the factory default and is worth distinguishing.
            infoRow("Times read", String(localized: "Counter off"))
        }

        if !diagnostics.ultralightCounters.isEmpty {
            let joined = diagnostics.ultralightCounters
                .map(Self.formatCount)
                .joined(separator: " · ")
            infoRow("Counters", joined)
            if diagnostics.countersIntact == false {
                infoRow("Counters", String(localized: "Tearing event detected"))
            }
        }

        // Set only when the data area is what refused to read, so this row is
        // absent from every ordinary scan. Worded as bytes rather than as a
        // verdict on the chip: an NTAG213 whose data area begins `04` answers
        // every read perfectly well and needs one page written, and a tag some
        // other system fills with its own bytes is not broken at all.
        if let prologue = diagnostics.dataAreaPrologue {
            infoRow("Data area", prologue.hexString, mono: true)
        }

        if let signature = diagnostics.originalitySignature {
            // The verdict is the useful part; the 32 bytes ride along for a bug
            // report via the same long-press copy every other row has.
            HStack(alignment: .firstTextBaseline, spacing: HexTokens.Spacing.m) {
                Text("Signature")
                    .font(HexTokens.Font.footnote)
                    .foregroundStyle(HexTokens.Color.textSecondary)
                Spacer(minLength: HexTokens.Spacing.s)
                Label("NXP originality signature", systemImage: "checkmark.seal")
                    .font(HexTokens.Font.body)
                    .foregroundStyle(HexTokens.Color.textPrimary)
                    .multilineTextAlignment(.trailing)
                    .hexCopyable(signature.hexString)
            }
        } else if diagnostics.signatureIsShort {
            // Deliberately worded as an observation, not an accusation: a short
            // reply means this chip does not answer READ_SIG the way genuine NXP
            // silicon does. That is all we actually know; we never verify the
            // signature against NXP's public key.
            HStack(alignment: .firstTextBaseline, spacing: HexTokens.Spacing.m) {
                Text("Signature")
                    .font(HexTokens.Font.footnote)
                    .foregroundStyle(HexTokens.Color.textSecondary)
                Spacer(minLength: HexTokens.Spacing.s)
                Label("Not a standard NXP signature", systemImage: "questionmark.circle")
                    .font(HexTokens.Font.body)
                    .foregroundStyle(HexTokens.Color.warning)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    /// Grouped digits, so a six-figure tap count stays readable.
    static func formatCount(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    private func infoRow(_ label: LocalizedStringKey, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: HexTokens.Spacing.m) {
            Text(label)
                .font(HexTokens.Font.footnote)
                .foregroundStyle(HexTokens.Color.textSecondary)
            Spacer(minLength: HexTokens.Spacing.s)
            Text(verbatim: value)
                .font(mono ? HexTokens.Font.mono : HexTokens.Font.body)
                .foregroundStyle(HexTokens.Color.textPrimary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .hexCopyable(value)
        }
    }
}
#endif
