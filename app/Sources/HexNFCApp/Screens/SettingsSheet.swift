#if os(iOS)
import HexNFCDesign
import HexNFCShaders
import SwiftUI

struct SettingsSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var activeLegalDocument: LegalDocument?

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Feel")) {
                    Toggle("Haptics", isOn: hapticsBinding)
                        .accessibilityHint(Text("Plays subtle vibrations during scan, write, and other key moments."))
                    Toggle("Reduce Motion", isOn: reduceMotionBinding)
                        .accessibilityHint(Text("Override the system Reduce Motion preference for this app."))
                    if systemReduceMotion {
                        Text("System Reduce Motion is on: animations are already minimised.")
                            .font(HexTokens.Font.footnote)
                            .foregroundStyle(HexTokens.Color.textSecondary)
                    }
                }
                Section(header: Text("Sync")) {
                    Toggle("iCloud sync", isOn: iCloudBinding)
                    // The SwiftData stack is built once, at launch, from this
                    // flag — so flipping it here genuinely does nothing until the
                    // app is restarted. Saying so beats leaving the user to
                    // wonder why nothing synced.
                    Text(
                        "Mirror your presets and history to your iCloud account. Off by default. Takes effect the next time you open the app."
                    )
                    .font(HexTokens.Font.footnote)
                    .foregroundStyle(HexTokens.Color.textSecondary)
                    // A toggle that reads "on" while nothing is syncing is worse
                    // than one that is off. Sign in to iCloud, run out of
                    // storage, or lose the network at launch and the store opens
                    // local-only; say so rather than letting the switch lie.
                    if model.settings.iCloudSyncEnabled, model.storeFallback == .cloudKitUnavailable {
                        Label(
                            "Sync is not running. Your library is safe on this device, but iCloud was unavailable when the app started. Check that you are signed in to iCloud, then reopen the app.",
                            systemImage: "exclamationmark.icloud"
                        )
                        .font(HexTokens.Font.footnote)
                        .foregroundStyle(HexTokens.Color.textSecondary)
                    }
                }
                Section(header: Text("About")) {
                    // Home carries a titled "More from Hex Pro" card, so the old
                    // "shows no ads" line was contradicted on the same device.
                    // The banner is named here in the same terms the Privacy
                    // Policy uses for it, rather than quietly dropped. Keep the
                    // "third-party" qualifier: this sentence sends the reader to
                    // the Privacy Policy, so claiming more than that document
                    // does is a claim we cannot stand behind. And no "only
                    // promotion in the app" line, because the development-costs
                    // card on Home links out to a page that takes money.
                    Text(
                        "Hex NFC is free and source-available, with no analytics and no accounts. What you scan stays on your device. The home screen may show a banner for another Hex Pro app. There is no third-party ad network, no tracking and no personalisation behind it: everyone sees the same banner. See the Privacy Policy for the few things the app fetches over the network."
                    )
                    .font(HexTokens.Font.body)
                    if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                       let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                    {
                        HStack {
                            Text("Version")
                            Spacer()
                            Text("\(version) (\(build))")
                                .foregroundStyle(HexTokens.Color.textSecondary)
                                .monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                Section(header: Text("Legal")) {
                    legalRow(.terms)
                    legalRow(.privacy)
                }
            }
            .scrollContentBackground(.hidden)
            .background(HexTokens.Color.surface0.ignoresSafeArea())
            .navigationTitle(Text("Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(HexTokens.Color.primaryLight)
                }
            }
            .toolbarBackground(HexTokens.Color.surface0, for: .navigationBar)
            .preferredColorScheme(.dark)
            .sheet(item: $activeLegalDocument) { document in
                LegalSheet(document: document)
            }
        }
    }

    /// Row that opens the full-text card for one legal document.
    private func legalRow(_ document: LegalDocument) -> some View {
        Button {
            activeLegalDocument = document
        } label: {
            HStack {
                Text(document.title)
                    .foregroundStyle(HexTokens.Color.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(HexTokens.Font.footnote)
                    .foregroundStyle(HexTokens.Color.textSecondary)
            }
        }
        .accessibilityHint(Text("Opens the full text."))
    }

    // MARK: - Bindings that auto-persist + propagate side effects.

    private var hapticsBinding: Binding<Bool> {
        Binding(
            get: { model.settings.hapticsEnabled },
            set: { newValue in
                model.settings.hapticsEnabled = newValue
                model.settings.save()
                HexHapticsEngine.shared.setEnabled(newValue)
            }
        )
    }

    private var reduceMotionBinding: Binding<Bool> {
        Binding(
            get: { model.settings.reduceMotionOverride },
            set: { newValue in
                model.settings.reduceMotionOverride = newValue
                model.settings.save()
            }
        )
    }

    private var iCloudBinding: Binding<Bool> {
        Binding(
            get: { model.settings.iCloudSyncEnabled },
            set: { newValue in
                model.settings.iCloudSyncEnabled = newValue
                model.settings.save()
            }
        )
    }
}

#endif
