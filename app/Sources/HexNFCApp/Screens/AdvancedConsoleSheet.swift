#if os(iOS)
import HexNFCDesign
import HexNFCKit
import HexNFCShaders
import SwiftUI

/// Advanced APDU / raw-command console. A first-class card on Home — opened
/// from the Home grid. Layout:
///
///  - Top: input field + Run / Clear buttons + live phase chip.
///  - Middle: `HexConsole` scrollback (mono, syntax-tinted hex).
///  - Bottom: preset library — searchable, family-filtered, single-tap loads
///    into the input buffer.
struct AdvancedConsoleSheet: View {
    @Bindable var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var model: AdvancedConsoleModel
    @State private var isRunning: Bool = false
    /// Bumped once each time a command run reaches a terminal phase (`.finished`
    /// or `.error`) — fires the rainbow border pulse + its haptic on every run.
    @State private var runPulse: Int = 0
    /// The process-wide live NFC trace — every frame across every flow, not just
    /// this REPL's own command run. Shown in the "All NFC traffic" tab.
    @State private var traceModel = SessionTraceModel()
    @State private var scope: ConsoleScope = .thisRun

    private enum ConsoleScope: Hashable { case thisRun, allTraffic }

    init(appModel: AppModel) {
        self.appModel = appModel
        _model = State(initialValue: AdvancedConsoleModel(factory: appModel.sessionFactory))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: HexTokens.Spacing.m) {
                inputBar
                scopePicker
                HexConsole(entries: displayedEntries)
                    .frame(minHeight: 220)
                    .overlay(alignment: .topTrailing) {
                        if !displayedEntries.isEmpty {
                            HexCopyAllButton { copyAllText }
                                .padding(HexTokens.Spacing.s)
                        }
                    }
                    .hexConsolePulse(trigger: runPulse, cornerRadius: HexTokens.Radius.m)
                    .hexHero(.consolePulse, trigger: runPulse)
                presetLibrary
            }
            .padding(HexTokens.Spacing.l)
            .background(HexTokens.Color.surface0.ignoresSafeArea())
            .navigationTitle(Text("Advanced console"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .destructive) {
                        switch scope {
                        case .thisRun: model.clear()
                        case .allTraffic: traceModel.clear()
                        }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .tint(HexTokens.Color.textSecondary)
                    .accessibilityLabel(Text("Clear console"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(HexTokens.Color.primaryLight)
                        .hexPressHaptic()
                }
            }
            .toolbarBackground(HexTokens.Color.surface0, for: .navigationBar)
            .preferredColorScheme(.dark)
        }
        .hexHero(.consoleCommit, trigger: isRunning)
        .onChange(of: model.phase) { _, newPhase in
            // The chip is the only place a run's progress shows, and VoiceOver
            // focus is on the input field or Run while it changes, so the change
            // was silent unless the user went looking for the chip.
            AccessibilityNotification.Announcement(phaseAnnouncement(for: newPhase)).post()

            // One pulse per completed run — success or error.
            switch newPhase {
            case .finished, .error:
                runPulse &+= 1

            default:
                break
            }
        }
    }

    // MARK: Scope

    /// Segmented switch between this REPL's own command log and the live,
    /// app-wide NFC trace (scan/write/operations/identification frames).
    private var scopePicker: some View {
        Picker("Console scope", selection: $scope) {
            Text("This run").tag(ConsoleScope.thisRun)
            Text("All NFC traffic").tag(ConsoleScope.allTraffic)
        }
        .pickerStyle(.segmented)
    }

    private var displayedEntries: [HexConsoleEntry] {
        switch scope {
        case .thisRun: model.entries
        case .allTraffic: traceModel.entries
        }
    }

    private var copyAllText: String {
        switch scope {
        case .thisRun: model.logPlainText
        case .allTraffic: traceModel.logPlainText
        }
    }

    // MARK: Input

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: HexTokens.Spacing.s) {
            HStack(spacing: HexTokens.Spacing.s) {
                phaseChip
                Spacer()
                identifyButton
            }
            Toggle("Skip identification", isOn: $model.skipIdentification)
                .font(HexTokens.Font.footnote)
                .tint(HexTokens.Color.warning)
            if model.skipIdentification {
                Text(
                    "Commands go straight to the chip. Needed for chips that refuse GET_VERSION: the probe halts them and every later command fails."
                )
                .font(HexTokens.Font.footnote)
                .foregroundStyle(HexTokens.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: HexTokens.Spacing.s) {
                TextField("21:60:00, A2:04:E1:10:06:00", text: $model.input, axis: .vertical)
                    .lineLimit(1 ... 4)
                    .font(HexTokens.Font.mono)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled(true)
                    .padding(HexTokens.Spacing.m)
                    .background(
                        RoundedRectangle(cornerRadius: HexTokens.Radius.m, style: .continuous)
                            .fill(HexTokens.Color.surface1)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: HexTokens.Radius.m, style: .continuous)
                            .stroke(HexTokens.Stroke.cardInner, lineWidth: 1)
                    )
                    // The placeholder is a sample command, not a name: without
                    // this label VoiceOver announces "21:60:00, A2:04:E1:10:06:00"
                    // as what the field is called.
                    .accessibilityLabel(Text("Command"))
                Button(action: run) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(
                            LinearGradient(
                                colors: [HexTokens.Color.primaryLight, HexTokens.Color.primary],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: HexTokens.Radius.m, style: .continuous))
                        .opacity(canRun ? 1.0 : 0.4)
                }
                .hexPressStyle()
                .disabled(!canRun)
                .accessibilityLabel(Text("Run"))
            }
        }
    }

    private var canRun: Bool {
        !model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isRunning
            && !model.isIdentifying
    }

    private func run() {
        isRunning = true
        Task {
            await model.run()
            isRunning = false
        }
    }

    // MARK: Identify

    /// Right-aligned control on the status line: scans a tag, identifies its
    /// chip, and re-prioritises the preset library around it. Shows a spinner
    /// while polling and is disabled during a command run.
    private var identifyButton: some View {
        Button(action: identify) {
            HStack(spacing: HexTokens.Spacing.xs) {
                if model.isIdentifying {
                    ProgressView()
                        .controlSize(.small)
                        .tint(HexTokens.Color.primaryLight)
                } else {
                    Image(systemName: "dot.radiowaves.left.and.right")
                }
                Text("Identify")
                    .font(HexTokens.Font.footnote)
                    .lineLimit(1)
            }
            .padding(.horizontal, HexTokens.Spacing.s)
            .padding(.vertical, HexTokens.Spacing.xs)
            .background(Capsule().fill(HexTokens.Color.primary.opacity(0.15)))
            .foregroundStyle(HexTokens.Color.primaryLight)
            .opacity(isRunning ? 0.4 : 1.0)
        }
        .hexPressStyle()
        .disabled(model.isIdentifying || isRunning)
    }

    private func identify() {
        Task { await model.identify() }
    }

    @ViewBuilder
    private var phaseChip: some View {
        switch model.phase {
        case .idle:
            chip("Idle", systemImage: "circle", tint: HexTokens.Color.textSecondary)

        case .polling:
            chip("Polling…", systemImage: "dot.radiowaves.left.and.right", tint: HexTokens.Color.primaryLight)

        case .connected(let uid, let chipName):
            chip(
                "\(chipName) · \(String(uid.suffix(11)))",
                systemImage: "checkmark.circle",
                tint: HexTokens.Color.success
            )

        case .running:
            chip("Running…", systemImage: "play.circle", tint: HexTokens.Color.primaryLight)

        case .finished:
            chip("Done", systemImage: "checkmark.circle.fill", tint: HexTokens.Color.success)

        // A status, not an error: nothing was sent, so nothing went wrong.
        case .noTagFound:
            chip("No tag found", systemImage: "wave.3.right", tint: HexTokens.Color.textSecondary)

        case .error(let message, _):
            chip(LocalizedStringKey(message), systemImage: "exclamationmark.triangle", tint: HexTokens.Color.dangerText)
        }
    }

    private func chip(_ title: LocalizedStringKey, systemImage: String, tint: Color) -> some View {
        HStack(spacing: HexTokens.Spacing.xs) {
            Image(systemName: systemImage)
            Text(title)
                .font(HexTokens.Font.footnote)
                .lineLimit(1)
        }
        .padding(.horizontal, HexTokens.Spacing.s)
        .padding(.vertical, HexTokens.Spacing.xs)
        .background(
            Capsule().fill(tint.opacity(HexTokens.Opacity.tintWash))
        )
        .foregroundStyle(tint)
        // One element rather than an unlabelled icon followed by loose text.
        // The label stays put while the phase rides in `accessibilityValue`,
        // because the phase is state: a hint would be the wrong home for it,
        // and hints can be switched off in VoiceOver's settings.
        .accessibilityElement()
        .accessibilityLabel(Text("Status"))
        .accessibilityValue(Text(title))
    }

    /// The phase chip's text, resolved for `AccessibilityNotification.Announcement`,
    /// which takes a `String`. `phaseChip` builds the same text as a
    /// `LocalizedStringKey`, and a key cannot be resolved back into a string, so
    /// the two switches have to be kept in step.
    private func phaseAnnouncement(for phase: AdvancedConsoleModel.Phase) -> String {
        switch phase {
        case .idle:
            String(localized: "Idle")

        case .polling:
            String(localized: "Polling…")

        case .connected(let uid, let chipName):
            String(localized: "\(chipName) · \(String(uid.suffix(11)))")

        case .running:
            String(localized: "Running…")

        case .finished:
            String(localized: "Done")

        case .noTagFound:
            String(localized: "No tag found")

        case .error(let message, _):
            // The chip renders this through `LocalizedStringKey`, so look it up
            // the same way instead of speaking an untranslated key. `message` is
            // a runtime value, so it goes through `LocalizationValue.init(_:)`,
            // not the `stringLiteral:` initialiser the compiler reserves for
            // literals it extracts into the catalog.
            String(localized: String.LocalizationValue(message))
        }
    }

    // MARK: Preset library

    private var presetLibrary: some View {
        VStack(alignment: .leading, spacing: HexTokens.Spacing.s) {
            HStack(spacing: HexTokens.Spacing.s) {
                Text("Presets")
                    .font(HexTokens.Font.heading)
                    .foregroundStyle(HexTokens.Color.textPrimary)
                Spacer()
                presetsHeaderTrailing
            }
            TextField("Search", text: $model.searchText)
                .padding(.horizontal, HexTokens.Spacing.m)
                .padding(.vertical, HexTokens.Spacing.s)
                .background(
                    RoundedRectangle(cornerRadius: HexTokens.Radius.s, style: .continuous)
                        .fill(HexTokens.Color.surface1)
                )
            ScrollView {
                LazyVStack(spacing: HexTokens.Spacing.s) {
                    ForEach(model.filteredPresets) { preset in
                        PresetRow(
                            preset: preset,
                            isCompatible: model.compatibility(of: preset).isCompatible
                        ) {
                            model.loadPreset(preset)
                        }
                    }
                }
            }
            .frame(maxHeight: 240)
        }
    }

    /// Trailing element on the "Presets" header. Before an Identify scan it's the
    /// "N of M" count; after, it's the identified chip as a tap-to-clear pill.
    @ViewBuilder
    private var presetsHeaderTrailing: some View {
        if let chip = model.identifiedChip {
            Button { model.clearIdentification() } label: {
                HStack(spacing: HexTokens.Spacing.xs) {
                    Image(systemName: "checkmark.seal.fill")
                    Text(chip.displayName)
                        .lineLimit(1)
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(HexTokens.Color.textSecondary)
                }
                .font(HexTokens.Font.footnote)
                .padding(.horizontal, HexTokens.Spacing.s)
                .padding(.vertical, 2)
                .background(Capsule().fill(HexTokens.Color.success.opacity(0.15)))
                .foregroundStyle(HexTokens.Color.success)
            }
            .hexPressHaptic()
        } else {
            Text("\(model.filteredPresets.count) of \(model.presets.count)")
                .font(HexTokens.Font.footnote)
                .foregroundStyle(HexTokens.Color.textSecondary)
        }
    }
}

private struct PresetRow: View {
    let preset: CommandPreset
    /// `false` once a tag is identified and this preset's family doesn't apply —
    /// the row dims but stays tappable (running off-spec is allowed, just
    /// flagged). `true` when compatible or before any Identify scan.
    let isCompatible: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: HexTokens.Spacing.xs) {
                HStack {
                    Text(preset.name)
                        .font(HexTokens.Font.body)
                        .foregroundStyle(HexTokens.Color.textPrimary)
                    Spacer()
                    Text(preset.family.shortName)
                        .font(HexTokens.Font.footnote)
                        .foregroundStyle(HexTokens.Color.textSecondary)
                        .padding(.horizontal, HexTokens.Spacing.s)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(HexTokens.Color.surface2))
                }
                Text(preset.sequenceText)
                    .font(HexTokens.Font.mono)
                    .foregroundStyle(HexTokens.Color.primaryLight)
                    .lineLimit(1)
            }
            .padding(HexTokens.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: HexTokens.Radius.s, style: .continuous)
                    .fill(HexTokens.Color.surface1.opacity(0.6))
            )
        }
        .hexPressStyle(.medium)
        .opacity(isCompatible ? 1.0 : 0.4)
    }
}
#endif
