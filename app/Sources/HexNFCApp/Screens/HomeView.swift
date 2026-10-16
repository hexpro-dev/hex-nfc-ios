#if os(iOS)
import HexNFCDesign
import SwiftUI

/// Pure launcher — owns no state. Routes the four primary tap targets into
/// `RootView`, which holds the sheet presentation state.
struct HomeView: View {
    let costs: DonationProgress
    let onScan: () -> Void
    let onBuild: () -> Void
    let onLibrary: () -> Void
    let onAdvanced: () -> Void
    let onSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HexTokens.Spacing.xl) {
                header
                grid
                developmentCostsSection
                // Hex Pro cross-promo. `HomePromoSlot` renders nothing at all
                // until a promo is configured for this slot, so it never leaves
                // an empty gap under the card above it.
                HomePromoSlot()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, HexTokens.Spacing.xl)
            .padding(.top, HexTokens.Spacing.xl)
            .padding(.bottom, HexTokens.Spacing.xxl)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                        .foregroundStyle(HexTokens.Color.textSecondary)
                }
                .hexPressStyle()
                .accessibilityLabel(Text("Settings"))
            }
        }
    }

    /// Hex Pro sub-division lockup: logo centered, with the product name in
    /// small muted uppercase right-aligned to the logo's edge, matching the
    /// apps.hex.pro header/footer branding. Tapping opens the product page.
    ///
    /// The name is set in IBM Plex Mono, which is the lockup face on the web
    /// and in Sol Alarm. This used to be SF Pro footnote at a flat 2pt of
    /// tracking, which was a second rendering of a lockup that is meant to be
    /// one thing. `HexTokens.Font.lockup` derives the size and the tracking
    /// from the mark's height, so both follow `logoHeight` on their own.
    private var header: some View {
        let logoHeight: CGFloat = 30
        let lockup = HexTokens.Font.lockup(logoHeight: logoHeight)
        return Button {
            open("https://apps.hex.pro/hex-nfc")
        } label: {
            VStack(alignment: .trailing, spacing: HexTokens.Spacing.xs) {
                Image("HexProLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(height: logoHeight)
                Text("Hex NFC")
                    .font(lockup.font)
                    .textCase(.uppercase)
                    .tracking(lockup.tracking)
                    .foregroundStyle(HexTokens.Color.textSecondary)
            }
        }
        .hexPressStyle()
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, HexTokens.Spacing.s)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Hex NFC by Hex Pro"))
        .accessibilityAddTraits(.isLink)
    }

    /// Transparency panel. The recovered figure comes from the shared Hex Pro
    /// costs API (with an offline fallback); the rainbow bar is the single
    /// eye-catching, off-brand flourish in the app.
    ///
    /// The button is deliberately informational. It used to read "Donate Now"
    /// under a heart, which is an in-app call to action pointing at a payment
    /// page outside IAP, and that is the shape App Review guideline 3.1.1 is
    /// written about. Naming the destination instead of the transaction keeps
    /// this on the "link to the developer's website" side of the line. Do not
    /// reintroduce donate/support/contribute wording, or the heart, here.
    private var developmentCostsSection: some View {
        HexCard {
            VStack(alignment: .leading, spacing: HexTokens.Spacing.m) {
                Text("Development Costs Recovered")
                    .font(HexTokens.Font.heading)
                    .foregroundStyle(HexTokens.Color.textPrimary)
                DonationProgressBar(fraction: costs.fraction)
                    .padding(.vertical, HexTokens.Spacing.xs)
                Text(verbatim: progressLabel)
                    .font(HexTokens.Font.footnote)
                    .foregroundStyle(HexTokens.Color.textSecondary)
                    .monospacedDigit()
                    .hexCopyable(progressLabel)
                HexButton("View Breakdown", systemImage: "arrow.up.right.square") {
                    open("https://apps.hex.pro/hex-nfc/costs")
                }
                .padding(.top, HexTokens.Spacing.xs)
            }
        }
    }

    private var progressLabel: String {
        String(
            localized: "\(costs.donatedText) of \(costs.totalText) · \(costs.percent)%",
            comment: "Development costs recovered, e.g. “$30 of $150 · 20%”"
        )
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        UIApplication.shared.open(url)
    }

    private var grid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: HexTokens.Spacing.l),
                GridItem(.flexible(), spacing: HexTokens.Spacing.l),
            ],
            spacing: HexTokens.Spacing.l
        ) {
            tile(systemImage: "dot.radiowaves.left.and.right", title: "Scan",
                 subtitle: "Read an NFC tag", action: onScan)
            tile(systemImage: "wand.and.stars", title: "Build",
                 subtitle: "From scratch", action: onBuild)
            tile(systemImage: "books.vertical", title: "Library",
                 subtitle: "Presets & history", action: onLibrary)
            tile(systemImage: "chevron.left.slash.chevron.right", title: "Advanced",
                 subtitle: "Raw command console", action: onAdvanced)
        }
        .accessibilityIdentifier("home.grid")
    }

    private func tile(
        systemImage: String,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HexCard {
                VStack(alignment: .leading, spacing: HexTokens.Spacing.m) {
                    ZStack {
                        RoundedRectangle(cornerRadius: HexTokens.Radius.s, style: .continuous)
                            .fill(HexTokens.Color.primary.opacity(0.16))
                            .frame(width: 42, height: 42)
                        Image(systemName: systemImage)
                            .foregroundStyle(HexTokens.Color.primaryLight)
                            .imageScale(.large)
                    }
                    Text(title)
                        .font(HexTokens.Font.title)
                        .foregroundStyle(HexTokens.Color.textPrimary)
                    Text(subtitle)
                        .font(HexTokens.Font.footnote)
                        .foregroundStyle(HexTokens.Color.textSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
            }
        }
        .hexPressStyle()
        .accessibilityIdentifier("home.tile.\(title)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text(subtitle))
        .accessibilityAddTraits(.isButton)
    }
}
#endif
