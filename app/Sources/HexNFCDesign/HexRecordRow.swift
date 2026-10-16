import SwiftUI

/// Row used in the TagEditor list. Icon + title + truncated payload + drag
/// handle. Visually a flat surface1 card with the inner stroke.
public struct HexRecordRow: View {
    private let title: LocalizedStringKey
    private let subtitle: String
    private let systemImage: String
    private let accent: Color

    public init(
        title: LocalizedStringKey,
        subtitle: String,
        systemImage: String,
        accent: Color = HexTokens.Color.primaryLight
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.accent = accent
    }

    public var body: some View {
        HStack(spacing: HexTokens.Spacing.m) {
            ZStack {
                RoundedRectangle(cornerRadius: HexTokens.Radius.s, style: .continuous)
                    .fill(accent.opacity(0.18))
                    .frame(width: 36, height: 36)
                Image(systemName: systemImage)
                    .imageScale(.medium)
                    .foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(HexTokens.Font.heading)
                    .foregroundStyle(HexTokens.Color.textPrimary)
                Text(subtitle)
                    .font(HexTokens.Font.footnote)
                    .foregroundStyle(HexTokens.Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Image(systemName: "line.3.horizontal")
                .imageScale(.small)
                .foregroundStyle(HexTokens.Color.textSecondary.opacity(0.6))
        }
        .padding(HexTokens.Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: HexTokens.Radius.m, style: .continuous)
                .fill(HexTokens.Color.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HexTokens.Radius.m, style: .continuous)
                .strokeBorder(HexTokens.Stroke.cardInner, lineWidth: 1)
        )
    }
}
