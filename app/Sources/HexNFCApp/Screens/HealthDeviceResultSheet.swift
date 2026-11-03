#if os(iOS)
import HexNFCDesign
import HexNFCKit
import SwiftUI

/// Read-only result for a personal health device: an insulin pen, a meter,
/// anything speaking NFC Forum PHDC.
///
/// Says what the device is, says plainly that Hex NFC does not read what is on
/// it, and, when the maker is one the app can name, points at an app that
/// does. That last part is the point of the screen: someone who taps their pen
/// here wants their doses, and a dead end is what turns into a one-star review.
///
/// No Add or Write affordance, and no route to the record editor. The scan never
/// persisted anything, and this screen keeps nothing either.
struct HealthDeviceResultSheet: View {
    let device: HealthDeviceScan
    /// Hardware facts for the same tap (type, maker, UID).
    var tagInfo: ScannedTagInfo?

    @Environment(\.dismiss) private var dismiss
    @State private var heroAppeared = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: HexTokens.Spacing.l) {
                    hero
                    if let referral = device.referral {
                        referralCard(referral)
                    }
                    TagInfoCard(tag: tagInfo, extraRows: deviceRows)
                    footnotes
                }
                .padding(HexTokens.Spacing.l)
            }
            .background(HexTokens.Color.surface0.ignoresSafeArea())
            .navigationTitle(Text("Health device"))
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
        .accessibilityIdentifier("health.sheet")
    }

    private var hero: some View {
        HexCard(highlighted: true) {
            VStack(alignment: .leading, spacing: HexTokens.Spacing.m) {
                Image(systemName: "heart.text.square.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(HexTokens.Color.primaryLight)
                    .accessibilityHidden(true)
                switch device.maker {
                case .novoNordisk:
                    Text("Novo Nordisk smart pen")
                        .font(HexTokens.Font.title)
                        .foregroundStyle(HexTokens.Color.textPrimary)
                    Text(
                        "This looks like a NovoPen 6 or NovoPen Echo Plus. Hex NFC can tell what it is, but it doesn't read the pen's dose history."
                    )
                    .font(HexTokens.Font.body)
                    .foregroundStyle(HexTokens.Color.textSecondary)

                case nil:
                    Text("Health device")
                        .font(HexTokens.Font.title)
                        .foregroundStyle(HexTokens.Color.textPrimary)
                    Text(
                        "This device uses the NFC standard for health devices. Hex NFC can tell what it is, but it doesn't read its measurements. The app made for it can."
                    )
                    .font(HexTokens.Font.body)
                    .foregroundStyle(HexTokens.Color.textSecondary)
                }
            }
        }
        // Haptics only, as on the transit result: the visual moment already
        // played on the scan screen.
        .hexHero(.scanSuccess, trigger: heroAppeared ? 1 : 0)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("health.hero")
    }

    private func referralCard(_ referral: HealthDeviceReferral) -> some View {
        HexCard {
            VStack(alignment: .leading, spacing: HexTokens.Spacing.m) {
                Text("\(referral.appName) can read this pen and log your doses.")
                    .font(HexTokens.Font.body)
                    .foregroundStyle(HexTokens.Color.textPrimary)
                HexButton("Get \(referral.appName) on the App Store", systemImage: "arrow.down.app") {
                    UIApplication.shared.open(referral.appStoreURL)
                }
                .accessibilityIdentifier("health.referral.appStore")
                HexButton("See all apps that read this pen", systemImage: "arrow.up.right.square", variant: .ghost) {
                    UIApplication.shared.open(referral.compatibleAppsURL)
                }
                .accessibilityIdentifier("health.referral.compatibleApps")
            }
        }
    }

    private var footnotes: some View {
        VStack(alignment: .leading, spacing: HexTokens.Spacing.s) {
            Text(
                "Hex NFC only read what this device says about itself. Nothing was written to it, and nothing from it was saved."
            )
            if device.referral != nil {
                Text("Hex NFC isn't affiliated with the device's maker or the apps named here.")
            }
        }
        .font(HexTokens.Font.footnote)
        .foregroundStyle(HexTokens.Color.textSecondary.opacity(0.8))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Health-device facts the generic snapshot has no field for.
    private var deviceRows: [(label: LocalizedStringKey, value: String)] {
        var rows: [(label: LocalizedStringKey, value: String)] = []
        if let systemID = device.systemIDHex {
            rows.append((label: "System ID", value: systemID))
        }
        rows.append((label: "Protocol", value: "IEEE 11073-20601"))
        return rows
    }
}
#endif
