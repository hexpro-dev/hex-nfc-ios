#if os(iOS)
import HexNFCDesign
import HexNFCRecords
import SwiftUI

/// One row in the transit history list: kind icon, date + route, and the
/// resulting balance. Route shows resolved station names where the bundled pack
/// covers them (with a tappable "ℹ︎" revealing the romaji reading); names that
/// aren't yet tap-confirmed render muted, and stops the pack can't name at all
/// show the line ("Ginza Line · ?") or the raw code. The crowd-source input for
/// unknown stops lives in a separate row (see `StationContributionRow`).
///
/// Only a rail ride draws a route. A bus fare, a top-up, a purchase or an
/// unclassifiable block keeps four bytes there that are not station codes, so
/// those rows name the transaction instead.
struct TransitHistoryRow: View {
    let transaction: TransitTransaction

    var body: some View {
        HStack(spacing: HexTokens.Spacing.m) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                routeView
                Text(verbatim: dateText)
                    .font(HexTokens.Font.footnote)
                    .foregroundStyle(HexTokens.Color.textSecondary)
            }
            Spacer(minLength: HexTokens.Spacing.s)
            let balanceText = TransitFormat.currency(transaction.balanceYen)
            Text(verbatim: balanceText)
                .font(HexTokens.Font.body.monospacedDigit())
                .foregroundStyle(HexTokens.Color.textPrimary)
                .hexCopyable(balanceText)
        }
        .padding(HexTokens.Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: HexTokens.Radius.m, style: .continuous)
                .fill(HexTokens.Color.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HexTokens.Radius.m, style: .continuous)
                .strokeBorder(HexTokens.Stroke.cardInner, lineWidth: HexTokens.Stroke.cardInnerWidth)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityLabelText))
        .accessibilityValue(Text(TransitFormat.currency(transaction.balanceYen)))
    }

    private var icon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: HexTokens.Radius.s, style: .continuous)
                .fill(HexTokens.Color.primaryLight.opacity(0.18))
                .frame(width: 36, height: 36)
            Image(systemName: transaction.kind.symbolName)
                .imageScale(.medium)
                .foregroundStyle(HexTokens.Color.primaryLight)
        }
    }

    private var dateText: String {
        guard let date = transaction.date else {
            return String(localized: "Date unknown")
        }
        return TransitFormat.date(date)
    }

    // MARK: - Route

    @ViewBuilder
    private var routeView: some View {
        if transaction.kind.legsAreRailStations {
            HStack(spacing: 4) {
                stationLabel(transaction.entry)
                if transaction.exit != nil {
                    // SF Symbol rather than a literal "→": U+2192 is not
                    // Bidi_Mirrored, so in Arabic the HStack mirrors the two
                    // stations but the glyph keeps pointing right, reversing the
                    // journey. `arrow.right` auto-mirrors with the layout.
                    Image(systemName: "arrow.right")
                        .font(HexTokens.Font.heading)
                        .foregroundStyle(HexTokens.Color.textSecondary)
                        .accessibilityHidden(true)
                    stationLabel(transaction.exit)
                }
            }
        } else {
            // Bus fares, top-ups, purchases and blocks we can't classify put
            // something other than a station in bytes 6-9, so the row names what
            // happened rather than inventing a route. See
            // `TransitTransaction.Kind.legsAreRailStations`.
            routeHeading(Text(Self.headingKey(for: transaction.kind)))
        }
    }

    /// What a row says in place of a route, for kinds whose bytes 6-9 are not
    /// rail station codes.
    private static func headingKey(for kind: TransitTransaction.Kind) -> LocalizedStringKey {
        switch kind {
        case .ride: "Ride"
        case .bus: "Bus fare"
        case .charge: "Charge"
        case .purchase: "Purchase"
        case .other: "Transaction"
        }
    }

    /// Plain-text twin of `headingKey(for:)` for VoiceOver.
    private static func headingText(for kind: TransitTransaction.Kind) -> String {
        switch kind {
        case .ride: String(localized: "Ride")
        case .bus: String(localized: "Bus fare")
        case .charge: String(localized: "Charge")
        case .purchase: String(localized: "Purchase")
        case .other: String(localized: "Transaction")
        }
    }

    private func routeHeading(_ text: Text) -> some View {
        text
            .font(HexTokens.Font.heading)
            .foregroundStyle(HexTokens.Color.textPrimary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    /// One station leg. Confirmed names show in full strength with a romaji
    /// tooltip; unconfirmed names show muted; unknown stops show the line (when
    /// known) or the raw code, muted — the inline input below offers to name it.
    @ViewBuilder
    private func stationLabel(_ ref: StationRef?) -> some View {
        if let ref {
            if let name = ref.resolvedName {
                HStack(spacing: 3) {
                    Text(verbatim: name)
                        .font(HexTokens.Font.heading)
                        .foregroundStyle(ref.verified ? HexTokens.Color.textPrimary : HexTokens.Color.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let romaji = ref.resolvedRomaji, !romaji.isEmpty {
                        StationRomajiInfo(romaji: romaji)
                    }
                }
            } else if let lineName = ref.lineName {
                Text(verbatim: "\(lineName) · ?")
                    .font(HexTokens.Font.heading)
                    .foregroundStyle(HexTokens.Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(verbatim: ref.rawCodeString)
                    .font(HexTokens.Font.heading)
                    .foregroundStyle(HexTokens.Color.textSecondary)
            }
        } else {
            routeHeading(Text("Unknown"))
        }
    }

    /// Full VoiceOver label. An explicit `accessibilityLabel` replaces whatever
    /// `.combine` would have merged from the children, so everything the row
    /// shows has to be restated here: the kind (carried visually only by the
    /// unlabelled SF Symbol), the route, and the date. Before this, a VoiceOver
    /// user heard the route and the balance and no date at all.
    private var accessibilityLabelText: String {
        var parts = [Self.headingText(for: transaction.kind)]
        // For a non-rail kind the route text *is* the kind name, so don't say it
        // twice.
        if transaction.kind.legsAreRailStations {
            parts.append(accessibilityRoute)
        }
        parts.append(dateText)
        return parts.joined(separator: ", ")
    }

    /// Plain-text route for VoiceOver (no interactive children to combine).
    private var accessibilityRoute: String {
        guard transaction.kind.legsAreRailStations else {
            return Self.headingText(for: transaction.kind)
        }
        func label(_ ref: StationRef?) -> String {
            guard let ref else { return String(localized: "Unknown") }
            if let name = ref.resolvedName {
                return name
            }
            if let line = ref.lineName {
                return line
            }
            return ref.rawCodeString
        }
        let entry = label(transaction.entry)
        if transaction.exit != nil {
            return String(
                format: String(localized: "%1$@ to %2$@"),
                entry,
                label(transaction.exit)
            )
        }
        return entry
    }
}

/// A small "ℹ︎" button beside a Japanese station name that reveals its romaji
/// reading in a popover tooltip. Owns its own presentation state so each leg in
/// a route toggles independently.
struct StationRomajiInfo: View {
    let romaji: String
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            Image(systemName: "info.circle")
                .font(HexTokens.Font.footnote)
                .foregroundStyle(HexTokens.Color.textSecondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Show English reading"))
        .accessibilityValue(Text(verbatim: romaji))
        .popover(isPresented: $showing) {
            Text(verbatim: romaji)
                .font(HexTokens.Font.body)
                .foregroundStyle(HexTokens.Color.textPrimary)
                .padding(.horizontal, HexTokens.Spacing.m)
                .padding(.vertical, HexTokens.Spacing.s)
                .presentationCompactAdaptation(.popover)
        }
    }
}

/// Shared formatters for transit display — currency in JPY, dates from the
/// card's `DateComponents`.
enum TransitFormat {
    private static let currencyFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "JPY"
        f.maximumFractionDigits = 0
        return f
    }()

    static func currency(_ yen: Int) -> String {
        currencyFormatter.string(from: NSNumber(value: yen)) ?? "¥\(yen)"
    }

    static func date(_ components: DateComponents) -> String {
        let calendar = Calendar(identifier: .gregorian)
        if let date = calendar.date(from: components) {
            return date.formatted(date: .abbreviated, time: .omitted)
        }
        // Fallback: raw Y/M/D.
        if let y = components.year, let m = components.month, let d = components.day {
            return String(format: "%04d-%02d-%02d", y, m, d)
        }
        return String(localized: "Date unknown")
    }
}
#endif
