#if os(iOS)
import HexNFCDesign
import HexNFCKit
import HexNFCRecords
import HexNFCShaders
import SwiftUI

/// Read-only presentation for a scanned Japanese transit IC card (Suica
/// family). Shows the card hero (balance) and the transaction history. Transit
/// cards cannot be written or edited by this app, so there is deliberately no
/// Add/Write affordance — this bypasses `TagEditorSheet` entirely.
struct TransitResultSheet: View {
    let card: TransitCard
    /// Hardware facts for the same tap (chip, maker, memory, UID). Shown in the
    /// shared meta card so users can see the technical data behind the card.
    var tagInfo: ScannedTagInfo?

    @Environment(\.dismiss) private var dismiss
    @State private var heroAppeared = false
    /// Saibane codes the user has already submitted a name for this session, so
    /// their inline input collapses and stays collapsed across scrolling.
    @State private var submittedCodes: Set<UInt32> = []
    private let submissionClient = StationSubmissionClient()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: HexTokens.Spacing.l) {
                    hero
                    TagInfoCard(tag: resolvedTagInfo, extraRows: transitRows)
                    history
                }
                .padding(HexTokens.Spacing.l)
            }
            .background(HexTokens.Color.surface0.ignoresSafeArea())
            .navigationTitle(Text("Transit card"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(HexTokens.Color.textSecondary)
                }
            }
            .toolbarBackground(HexTokens.Color.surface0, for: .navigationBar)
            .preferredColorScheme(.dark)
        }
        .task {
            heroAppeared = true
        }
        .accessibilityIdentifier("transit.sheet")
    }

    private var hero: some View {
        TransitCardHero(
            systemName: systemName,
            balanceText: TransitFormat.currency(card.balanceYen),
            idmText: card.idmHex
        )
        // Haptics only. `.hexHero` composes haptics, not shaders, so there is
        // no sweep here and never was; this used to claim one, along with a
        // reduce-motion fallback for it and a "brief beat" before it, none of
        // which existed. The absence is correct rather than a gap: this tap
        // already had its visual flourish one screen back, in `ScanSheet`'s
        // `.hexScanReveal`. A second one on arrival would be the same moment
        // played twice.
        .hexHero(.scanSuccess, trigger: heroAppeared ? 1 : 0)
        .accessibilityIdentifier("transit.hero")
    }

    @ViewBuilder
    private var history: some View {
        if card.hasHistory {
            VStack(alignment: .leading, spacing: HexTokens.Spacing.s) {
                Text("History")
                    .font(HexTokens.Font.heading)
                    .foregroundStyle(HexTokens.Color.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if hasUnknownStations {
                    helpCard
                }
                ForEach(card.transactions) { txn in
                    TransitHistoryRow(transaction: txn)
                    // Inline "name this stop" input under the first row that
                    // references each unknown code (deduped across the history).
                    if let legs = firstOccurrenceUnknowns[txn.id] {
                        ForEach(legs, id: \.self) { ref in
                            if !submittedCodes.contains(Self.key(ref)) {
                                StationContributionRow(
                                    station: ref,
                                    onSubmit: { name in submit(ref, name: name) },
                                    onComplete: { submittedCodes.insert(Self.key(ref)) }
                                )
                            }
                        }
                    }
                }
                disclaimer
            }
        } else {
            VStack(spacing: HexTokens.Spacing.m) {
                Image(systemName: "clock.badge.questionmark")
                    .font(.system(size: 44))
                    .foregroundStyle(HexTokens.Color.textSecondary.opacity(0.6))
                Text("No transaction history on this card")
                    .font(HexTokens.Font.body)
                    .foregroundStyle(HexTokens.Color.textSecondary)
                    .multilineTextAlignment(.center)
                disclaimer
            }
            .frame(maxWidth: .infinity)
            .padding(.top, HexTokens.Spacing.xl)
        }
    }

    /// Invitation shown above the history when any stop is unnamed. Frames the
    /// ask around the fact that the user has been to these stops (they're on the
    /// card), which is what makes a typed name a clean first-party observation.
    ///
    /// The second line is the disclosure. Submitting uploads free text the user
    /// typed, and this is the point of collection: the only other statement is
    /// in Settings > Legal, three screens away, and the app's own NFC purpose
    /// string tells them tag contents stay on the device.
    private var helpCard: some View {
        HStack(alignment: .top, spacing: HexTokens.Spacing.m) {
            Image(systemName: "mappin.slash")
                .foregroundStyle(HexTokens.Color.primaryLight)
            VStack(alignment: .leading, spacing: HexTokens.Spacing.xs) {
                Text("Some of these stops aren't named yet. You've been to them. Help fill in the blanks below.")
                    .font(HexTokens.Font.footnote)
                    .foregroundStyle(HexTokens.Color.textPrimary)
                Text(
                    "A name you send goes to us for review and may ship in a later update. It carries the stop's codes, the card type, and the name you typed. Nothing else from the card is sent."
                )
                .font(HexTokens.Font.footnote)
                .foregroundStyle(HexTokens.Color.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(HexTokens.Spacing.m)
        .background(
            HexTokens.Color.surface1,
            in: RoundedRectangle(cornerRadius: HexTokens.Radius.l, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HexTokens.Radius.l, style: .continuous)
                .strokeBorder(HexTokens.Color.primaryLight.opacity(0.35), lineWidth: 1)
        )
    }

    /// Fire-and-forget submission of a typed station name. Privacy: sends only
    /// the saibane codes, the region byte, the name and the card's system code.
    /// Never the IDm, the balance or the history.
    ///
    /// The region byte is what makes a suggestion usable: the same
    /// (line, station) pair names different stations in different regions, so
    /// without it two regions' submissions for one code are indistinguishable
    /// and collide in the generator.
    private func submit(_ ref: StationRef, name: String) {
        let suggestion = StationSubmissionClient.Suggestion(
            line: Int(ref.lineCode),
            station: Int(ref.stationCode),
            area: ref.regionCode.map(Int.init),
            name: name,
            systemCode: systemCodeHex
        )
        Task { await submissionClient.submit(suggestion) }
    }

    /// Unknown (un-nameable) legs of a transaction: a station leg the pack
    /// couldn't resolve to a name. Empty legs (no station recorded) are skipped.
    ///
    /// Rail rides only. On a top-up, a shop purchase or a bus fare, bytes 6-9 of
    /// the history block are a terminal, shop or bus-stop identifier rather than
    /// a saibane station code, so there is no station to name and a suggestion
    /// built from those bytes would poison the shared pack. The decoder already
    /// leaves those legs `nil`; this gate keeps the invitation honest if that
    /// ever changes. See `TransitTransaction.Kind.legsAreRailStations`.
    private func unknownLegs(of txn: TransitTransaction) -> [StationRef] {
        guard txn.kind.legsAreRailStations else { return [] }
        return [txn.entry, txn.exit]
            .compactMap { $0 }
            .filter { $0.resolvedName == nil && !$0.isEmpty }
    }

    /// Maps each transaction to the unknown legs that *first* appear at it, so a
    /// repeated unknown code only ever gets one inline input (under its newest
    /// occurrence).
    private var firstOccurrenceUnknowns: [UUID: [StationRef]] {
        var seen = Set<UInt32>()
        var map: [UUID: [StationRef]] = [:]
        for txn in card.transactions {
            var legs: [StationRef] = []
            for ref in unknownLegs(of: txn) where !seen.contains(Self.key(ref)) {
                seen.insert(Self.key(ref))
                legs.append(ref)
            }
            if !legs.isEmpty {
                map[txn.id] = legs
            }
        }
        return map
    }

    private var hasUnknownStations: Bool {
        !firstOccurrenceUnknowns.isEmpty
    }

    /// Dedup key for the inline inputs. Includes the region byte, because the
    /// same (line, station) pair in two regions is two different stations.
    private static func key(_ ref: StationRef) -> UInt32 {
        (UInt32(ref.regionCode ?? 0) << 16)
            | (UInt32(ref.lineCode) << 8)
            | UInt32(ref.stationCode)
    }

    /// Honest note: only entries the station pack covers show names.
    private var disclaimer: some View {
        Text("Station names are shown where available; other stops appear as their raw transit codes.")
            .font(HexTokens.Font.footnote)
            .foregroundStyle(HexTokens.Color.textSecondary.opacity(0.8))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, HexTokens.Spacing.s)
    }

    /// Technical facts to show beneath the balance. FeliCa exposes little over
    /// the air (no GET_VERSION-style chip/memory data — only the IDm, system
    /// code, and history service), so we merge whatever the live scan captured
    /// with facts that hold for every FeliCa transit card: it's Sony's NFC-F
    /// technology, and the IDm always comes off the card.
    private var resolvedTagInfo: ScannedTagInfo {
        let live = tagInfo
        let liveMaker = live?.manufacturer
        let maker = (liveMaker == nil || liveMaker == "Unknown") ? "Sony" : liveMaker
        return ScannedTagInfo(
            chipName: live?.chipName ?? String(localized: "FeliCa"),
            familyName: String(localized: "NFC-F (ISO/IEC 18092)"),
            manufacturer: maker,
            uidHex: live?.uidHex ?? card.idmHex,
            totalBytes: live?.totalBytes,
            ndefBytes: live?.ndefBytes
        )
    }

    /// Transit-only facts the generic snapshot has no field for.
    private var transitRows: [(label: LocalizedStringKey, value: String)] {
        [
            (label: "System code", value: systemCodeHex),
            // `.formatted()` so the count follows the locale's numbering system,
            // matching the balance above it and `TagInfoCard.formatCount` on the
            // same card. `String(Int)` is always Western digits.
            (label: "Transactions", value: card.transactions.count.formatted()),
        ]
    }

    private var systemCodeHex: String {
        switch card.system {
        case .suicaFamily:
            "0x0003"

        case .unknown(let code):
            String(format: "0x%04X", code)
        }
    }

    private var systemName: String {
        switch card.system {
        case .suicaFamily:
            String(localized: "Transit IC (Suica / PASMO …)")

        case .unknown(let code):
            String(localized: "Transit IC") + String(format: " (0x%04X)", code)
        }
    }
}
#endif
