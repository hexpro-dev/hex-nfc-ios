import SwiftUI

public struct HexBadge: View {
    public enum Tone: Sendable { case neutral, primary, success, warning, danger }

    private let title: LocalizedStringKey
    private let tone: Tone

    /// Opacity of the tinted capsule a badge prints its own tone over.
    ///
    /// Public because `WCAGContrastTests` measures against it, and a guard that
    /// carried its own copy of the number would keep passing after this one
    /// changed. Both sides of that ratio are the same hue, so this value is
    /// what decides whether the label separates from its capsule at all.
    public static let washOpacity = HexTokens.Opacity.tintWash

    public init(_ title: LocalizedStringKey, tone: Tone = .neutral) {
        self.title = title
        self.tone = tone
    }

    public var body: some View {
        Text(title)
            .font(HexTokens.Font.footnote.weight(.semibold))
            .padding(.horizontal, HexTokens.Spacing.s)
            .padding(.vertical, 2)
            .foregroundStyle(foreground)
            .background(
                Capsule().fill(background)
            )
    }

    private var background: Color {
        switch tone {
        case .neutral: HexTokens.Color.surface2
        case .primary: HexTokens.Color.primary.opacity(Self.washOpacity)
        case .success: HexTokens.Color.success.opacity(Self.washOpacity)
        case .warning: HexTokens.Color.warning.opacity(Self.washOpacity)
        case .danger: HexTokens.Color.dangerText.opacity(Self.washOpacity)
        }
    }

    private var foreground: Color {
        switch tone {
        case .neutral: HexTokens.Color.textSecondary
        case .primary: HexTokens.Color.primaryLight
        case .success: HexTokens.Color.success
        case .warning: HexTokens.Color.warning
        case .danger: HexTokens.Color.dangerText
        }
    }
}
