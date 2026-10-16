import SwiftUI

/// The hero "card" for a scanned transit IC card — an ID-1-proportioned panel
/// with the iconic transit-green gradient, a drawn IC-chip glyph, and a large
/// balance readout. Read-only and brand-neutral (it deliberately evokes the
/// physical card, never reproducing any real network's logo).
///
/// Purely presentational + token-driven so it can be snapshot-tested. The
/// premium sheen sweep is layered on by the hosting screen via `.hexHero`.
public struct TransitCardHero: View {
    private let systemName: String
    private let balanceText: String
    private let idmText: String

    /// - Parameters:
    ///   - systemName: e.g. "Transit IC (Suica / PASMO …)".
    ///   - balanceText: pre-formatted currency string, e.g. "¥1,230".
    ///   - idmText: colon-delimited hex IDm.
    public init(systemName: String, balanceText: String, idmText: String) {
        self.systemName = systemName
        self.balanceText = balanceText
        self.idmText = idmText
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: HexTokens.Spacing.l)
            balance
            Spacer(minLength: HexTokens.Spacing.s)
            footer
        }
        .padding(HexTokens.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .aspectRatio(1.585, contentMode: .fit) // ID-1 card proportions
        .background(cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: HexTokens.Radius.l, style: .continuous))
        .overlay(bevel)
        .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(systemName))
        .accessibilityValue(Text(balanceText))
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(alignment: .top, spacing: HexTokens.Spacing.m) {
            icChip
            Text(verbatim: systemName)
                .font(HexTokens.Font.heading)
                .foregroundStyle(HexTokens.Transit.cardText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Image(systemName: "wave.3.right")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(HexTokens.Transit.cardTextDim)
        }
    }

    private var balance: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Balance")
                .font(HexTokens.Font.footnote)
                .foregroundStyle(HexTokens.Transit.cardTextDim)
            Text(verbatim: balanceText)
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(HexTokens.Transit.cardText)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .hexCopyable(balanceText)
        }
    }

    private var footer: some View {
        Text(verbatim: idmText)
            .font(HexTokens.Font.mono)
            .foregroundStyle(HexTokens.Transit.cardTextDim)
            .lineLimit(1)
            .truncationMode(.middle)
            .hexCopyable(idmText)
    }

    /// A small drawn IC-chip glyph (gold rounded square with contact lines).
    private var icChip: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(HexTokens.Transit.chipGold)
                .frame(width: 34, height: 26)
            VStack(spacing: 3) {
                ForEach(0 ..< 3, id: \.self) { _ in
                    Rectangle()
                        .fill(.black.opacity(0.25))
                        .frame(height: 1.5)
                }
            }
            .padding(.horizontal, 6)
        }
        .accessibilityHidden(true)
    }

    private var cardSurface: some View {
        LinearGradient(
            colors: [HexTokens.Transit.cardTop, HexTokens.Transit.cardBottom],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(waveTexture)
    }

    /// Faint diagonal wave bands evoking the printed card art.
    private var waveTexture: some View {
        GeometryReader { geo in
            Path { path in
                let step = geo.size.height / 5
                for i in 0 ... 6 {
                    let y = CGFloat(i) * step
                    path.move(to: CGPoint(x: -geo.size.width, y: y))
                    path.addLine(to: CGPoint(x: geo.size.width, y: y - geo.size.width))
                }
            }
            .stroke(HexTokens.Transit.cardTexture, lineWidth: 18)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var bevel: some View {
        RoundedRectangle(cornerRadius: HexTokens.Radius.l, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.30), .white.opacity(0.02)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )
    }
}
