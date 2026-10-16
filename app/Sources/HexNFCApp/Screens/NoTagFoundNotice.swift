#if os(iOS)
import HexNFCDesign
import SwiftUI

/// What a screen says when a session reached its time limit with no tag in the
/// field, on a flow that has never had one.
///
/// Neutral on purpose, and shared so the scan, write and operations screens say
/// the same thing. Nothing failed: there is no red, no warning triangle, no
/// "failed" headline and no diagnostics, because a session that never saw a tag
/// has nothing to diagnose. One hint is all it offers, and it is the one that
/// fixes most misses. The MIFARE Classic line stays because it is the case the
/// hint cannot fix, and a user holding one of those has otherwise no way to
/// learn that trying again will never work.
///
/// The screen supplies its own buttons, because "try again" means something
/// slightly different on each: a fresh scan, `WriteFlowModel.retry()`, or tap 1
/// of an operation.
struct NoTagFoundNotice: View {
    /// `title` on a screen of its own, `heading` inside an operation's banner.
    var titleFont: Font = HexTokens.Font.title

    var body: some View {
        VStack(alignment: .leading, spacing: HexTokens.Spacing.s) {
            HStack(spacing: HexTokens.Spacing.s) {
                Image(systemName: "wave.3.right")
                    .foregroundStyle(HexTokens.Color.textSecondary)
                    .accessibilityHidden(true)
                Text("No tag found")
                    .font(titleFont)
                    .foregroundStyle(HexTokens.Color.textPrimary)
            }
            Text("Hold the tag flat against the top of your iPhone, then try again.")
                .font(HexTokens.Font.body)
                .foregroundStyle(HexTokens.Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("If one tag is never found, however you hold it, it may be a MIFARE Classic, which iPhone can't read.")
                .font(HexTokens.Font.footnote)
                .foregroundStyle(HexTokens.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
#endif
