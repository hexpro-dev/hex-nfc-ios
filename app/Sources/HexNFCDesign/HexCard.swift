import SwiftUI

/// Tagged surface with a 4% inner stroke, surface1 fill, radius m. The
/// fundamental "thing on the home screen" primitive.
///
///     HexCard {
///         Text("Scan")
///     }
public struct HexCard<Content: View>: View {
    private let content: Content
    private let highlighted: Bool

    public init(highlighted: Bool = false, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.highlighted = highlighted
    }

    public var body: some View {
        content
            .padding(HexTokens.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: HexTokens.Radius.m, style: .continuous)
                    .fill(HexTokens.Color.surface1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HexTokens.Radius.m, style: .continuous)
                    .strokeBorder(
                        highlighted ? HexTokens.Color.primary.opacity(0.4) : HexTokens.Stroke.cardInner,
                        lineWidth: HexTokens.Stroke.cardInnerWidth
                    )
            )
    }
}
