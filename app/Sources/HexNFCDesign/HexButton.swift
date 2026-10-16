import SwiftUI

public struct HexButton: View {
    public enum Variant: Sendable {
        case primary
        case secondary
        case ghost
        case destructive
    }

    private let title: LocalizedStringKey
    private let systemImage: String?
    private let variant: Variant
    private let action: () -> Void

    /// Read here rather than in `HexPressStyle`, because this is the view that
    /// paints fixed chrome and so the one that has to answer for it. Other users
    /// of the press style draw their own labels, and some already fade them.
    @Environment(\.isEnabled) private var isEnabled

    public init(
        _ title: LocalizedStringKey,
        systemImage: String? = nil,
        variant: Variant = .primary,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.variant = variant
        self.action = action
    }

    public var body: some View {
        // Chrome lives inside the label so `HexPressStyle` scales the whole
        // button (background included) on press and fires the tap haptic.
        Button(action: action) {
            HStack(spacing: HexTokens.Spacing.s) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .imageScale(.medium)
                }
                Text(title)
                    .font(HexTokens.Font.heading)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, HexTokens.Spacing.m)
            .padding(.horizontal, HexTokens.Spacing.l)
            .background(background)
            .foregroundStyle(foreground)
            .overlay(border)
            .clipShape(RoundedRectangle(cornerRadius: HexTokens.Radius.m, style: .continuous))
            // `.disabled` withdraws the tap and nothing else; the look is the
            // style's job, and `HexPressStyle` paints nothing. With the chrome
            // fixed in the label, every disabled HexButton read as live, the
            // unlock card's "Unlock & continue" among them (2026-09-25). 0.4 is
            // the value `DestructiveConfirmationView` already uses.
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
        }
        .hexPressStyle()
    }

    @ViewBuilder
    private var background: some View {
        switch variant {
        case .primary:
            // The gloss that used to come from a light top stop now comes from
            // a 1pt edge instead. The stop itself carried the white label at
            // 2.62:1; a 1pt stroke is nothing's text background, so the button
            // still reads as lit without any text sitting on the lit part.
            LinearGradient(
                colors: [HexTokens.Color.primaryCTATop, HexTokens.Color.primaryDeep],
                startPoint: .top, endPoint: .bottom
            )
            .overlay(alignment: .top) {
                HexTokens.Color.primaryLight.opacity(0.45).frame(height: 1)
            }

        case .secondary:
            HexTokens.Color.surface2

        case .ghost:
            Color.clear

        case .destructive:
            HexTokens.Color.dangerFill
        }
    }

    private var foreground: Color {
        switch variant {
        case .primary, .destructive: .white
        case .secondary: HexTokens.Color.textPrimary
        case .ghost: HexTokens.Color.primaryLight
        }
    }

    @ViewBuilder
    private var border: some View {
        switch variant {
        case .ghost:
            RoundedRectangle(cornerRadius: HexTokens.Radius.m, style: .continuous)
                .strokeBorder(HexTokens.Color.primary.opacity(0.5), lineWidth: 1)

        case .secondary:
            RoundedRectangle(cornerRadius: HexTokens.Radius.m, style: .continuous)
                .strokeBorder(HexTokens.Stroke.cardInner, lineWidth: 1)

        // A filled button's shape is carried by its fill alone, which is fine
        // until Increase Contrast flattens that fill: `#00509E` sits 2.43:1
        // from `surface0`, so without an edge the button would be *harder* to
        // find in the tier that asked for the opposite. `contrastEdge` draws
        // nothing until then, so this is unconditional and cannot be forgotten.
        case .primary, .destructive:
            RoundedRectangle(cornerRadius: HexTokens.Radius.m, style: .continuous)
                .strokeBorder(
                    HexTokens.Stroke.contrastEdge,
                    lineWidth: HexTokens.Stroke.contrastEdgeWidth
                )
        }
    }
}
