#if os(iOS)
import HexNFCDesign
import SwiftUI

/// The "Loving Hex NFC?" card that rises from the foot of Home.
///
/// It never blocks anything: it sits in Home's bottom inset, the screen above
/// it scrolls and every tile still works, and leaving Home without answering
/// counts as "Hide". `RootView` decides when it appears and what each answer
/// does; this view only draws the stage it is given.
///
/// The first stage asks how the app is going and nothing else. It mentions no
/// rating, no stars and no App Store, because App Review guideline 5.6.1 allows
/// only Apple's own review prompt to ask for those, and "Love it!" is what
/// hands over to it.
struct ReviewPromptCard: View {
    enum Stage: Equatable {
        case asking
        /// After "Love it!", behind Apple's rating sheet, which may or may not
        /// appear: iOS decides, and never shows it in TestFlight.
        case thanks
        /// After "Meh.".
        case feedbackOffer
    }

    let stage: Stage
    let onLove: () -> Void
    let onMeh: () -> Void
    let onHide: () -> Void
    let onSendFeedback: () -> Void

    var body: some View {
        HexCard(highlighted: true) {
            switch stage {
            case .asking:
                VStack(alignment: .leading, spacing: HexTokens.Spacing.m) {
                    Text("Loving Hex NFC?")
                        .font(HexTokens.Font.heading)
                        .foregroundStyle(HexTokens.Color.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    buttonRow {
                        HexButton("Love it!", variant: .primary, action: onLove)
                            .accessibilityIdentifier("reviewPrompt.loveIt")
                        HexButton("Meh.", variant: .secondary, action: onMeh)
                            .accessibilityIdentifier("reviewPrompt.meh")
                        HexButton("Hide", variant: .ghost, action: onHide)
                            .accessibilityIdentifier("reviewPrompt.hide")
                    }
                }

            case .thanks:
                HStack(spacing: HexTokens.Spacing.m) {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(HexTokens.Color.primaryLight)
                        .accessibilityHidden(true)
                    Text("Thank you!")
                        .font(HexTokens.Font.heading)
                        .foregroundStyle(HexTokens.Color.textPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .feedbackOffer:
                VStack(alignment: .leading, spacing: HexTokens.Spacing.m) {
                    Text("We want this to be the best app possible. If something's not right, we want to fix it.")
                        .font(HexTokens.Font.body)
                        .foregroundStyle(HexTokens.Color.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    buttonRow {
                        HexButton("Send Feedback", variant: .primary, action: onSendFeedback)
                            .accessibilityIdentifier("reviewPrompt.sendFeedback")
                        HexButton("Hide", variant: .ghost, action: onHide)
                            .accessibilityIdentifier("reviewPrompt.hide")
                    }
                }
            }
        }
        .shadow(color: .black.opacity(0.45), radius: 18, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reviewPrompt.card")
    }

    /// The buttons side by side while their labels fit on one line, stacked
    /// once they don't: at the larger text sizes, and in the languages whose
    /// words for "Love it!" run long.
    private func buttonRow(@ViewBuilder _ buttons: () -> some View) -> some View {
        let buttons = buttons()
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: HexTokens.Spacing.s) { buttons }
            VStack(spacing: HexTokens.Spacing.s) { buttons }
        }
    }
}
#endif
