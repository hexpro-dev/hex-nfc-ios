#if DEBUG && os(iOS)
import HexNFCDesign
import HexNFCKit
import HexNFCShaders
import HexNFCTestKit
import SwiftUI

/// DEBUG-only live-hardware test harness: place the phone flat, drop a chip on
/// top, identify it, confirm the detection, then run the shared `TagTestPlan`
/// against real silicon with a copyable, fail-fast console. Reached from the
/// hidden developer entry; never compiled into release. Dev tool — copy is plain
/// (exempt from the shipping localization rule).
struct TestHarnessScreen: View {
    private let appModel: AppModel
    @State private var model: TestHarnessModel
    @State private var registry = CleanPassRegistry()
    @State private var activeSheet: HarnessSheet?
    @Environment(\.dismiss) private var dismiss

    /// A single sheet slot for the two gated follow-up flows. One `.sheet`
    /// modifier — stacking two on the same view makes SwiftUI mis-present (blank).
    private enum HarnessSheet: Identifiable {
        case enforcement(EnforcementCheckFlowModel, ChipProfile)
        case irreversible(IrreversibleOpsFlowModel, ChipProfile)
        var id: ObjectIdentifier {
            switch self {
            case .enforcement(let model, _): ObjectIdentifier(model)
            case .irreversible(let model, _): ObjectIdentifier(model)
            }
        }
    }

    init(appModel: AppModel) {
        self.appModel = appModel
        _model = State(initialValue: TestHarnessModel(factory: appModel.sessionFactory))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: HexTokens.Spacing.m) {
                phaseChip
                if case .running = model.phase {
                    progressBar
                }
                if case .finished = model.phase {
                    progressBar
                }

                HexConsole(entries: model.entries)
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .topTrailing) {
                        if !model.entries.isEmpty {
                            HexCopyAllButton { model.logText }
                                .padding(HexTokens.Spacing.s)
                        }
                    }
                    .hexHero(.consolePulse, trigger: model.pulse)

                actions
            }
            .padding(HexTokens.Spacing.l)
            .background(HexTokens.Color.surface0.ignoresSafeArea())
            .navigationTitle("Live chip test")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.tint(HexTokens.Color.textSecondary)
                }
            }
        }
        .onAppear {
            model.onCleanPass = { profile, uid in
                registry.record(chipID: profile.id, uid: uid)
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .enforcement(let model, let profile):
                EnforcementCheckView(model: model, profile: profile)

            case .irreversible(let model, let profile):
                IrreversibleOpsView(model: model, profile: profile)
            }
        }
    }

    // MARK: - Phase-driven UI

    @ViewBuilder
    private var actions: some View {
        switch model.phase {
        case .idle:
            primaryButton("Scan & identify") { model.identify() }

        case .identifying:
            busyRow("Identifying…")

        case .confirm(let profile, _):
            VStack(spacing: HexTokens.Spacing.s) {
                Text("Detected \(profile.displayName)")
                    .font(HexTokens.Font.heading)
                    .foregroundStyle(HexTokens.Color.textPrimary)
                Toggle("Read-only pass", isOn: $model.readOnlyPass)
                    .font(HexTokens.Font.footnote)
                    .tint(HexTokens.Color.warning)
                if model.readOnlyPass {
                    Text("No writes reach the tag. For one-of-a-kind chips. Cannot record a clean pass.")
                        .font(HexTokens.Font.footnote)
                        .foregroundStyle(HexTokens.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: HexTokens.Spacing.m) {
                    Button("Cancel") { model.cancelConfirmation() }
                        .buttonStyle(.bordered)
                        .tint(HexTokens.Color.textSecondary)
                    primaryButton("Start test") { model.startRun() }
                }
            }

        case .running:
            // A multi-tap plan stalls between activations until the operator
            // puts the same tag back. The ordinary busy row is a one-line
            // truncating label, which is the wrong shape for an instruction.
            if let prompt = model.tapPrompt {
                tapPromptRow(prompt)
            } else {
                busyRow(model.currentStep.isEmpty ? "Running…" : model.currentStep)
            }

        case .finished(let report):
            finishedActions(report)

        case .error(let message):
            VStack(spacing: HexTokens.Spacing.s) {
                Text(message).font(HexTokens.Font.body).foregroundStyle(HexTokens.Color.dangerText)
                primaryButton("Try again") { model.identify() }
            }
        }
    }

    private func finishedActions(_ report: TagTestReport) -> some View {
        VStack(spacing: HexTokens.Spacing.s) {
            HStack(spacing: HexTokens.Spacing.s) {
                Image(systemName: report.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(report.passed ? HexTokens.Color.success : HexTokens.Color.dangerText)
                Text(report.passed ? "All steps passed" : "Failed: \(report.firstFailure?.name ?? "unknown")")
                    .font(HexTokens.Font.heading)
                    .foregroundStyle(HexTokens.Color.textPrimary)
            }
            primaryButton("Run again") { model.identify() }
            if report.isCleanPass, registry.hasCleanPass(for: report.profile.id) {
                HStack(spacing: HexTokens.Spacing.m) {
                    if EnforcementCheckFlowModel.supports(report.profile) {
                        secondaryButton(
                            "Verify enforcement",
                            systemImage: "lock.shield",
                            tint: HexTokens.Color.warning
                        ) {
                            let uid = registry.uid(for: report.profile.id) ?? report.uid
                            // `supports` already gated this button, so the
                            // initializer cannot fail here; if it somehow does,
                            // opening no sheet is the correct outcome. There is
                            // no safe fallback strategy to substitute.
                            if let model = EnforcementCheckFlowModel(
                                factory: appModel.sessionFactory, profile: report.profile, expectedUID: uid
                            ) {
                                activeSheet = .enforcement(model, report.profile)
                            }
                        }
                    }
                    secondaryButton(
                        "Irreversible ops",
                        systemImage: "exclamationmark.octagon",
                        tint: HexTokens.Color.dangerText
                    ) {
                        let uid = registry.uid(for: report.profile.id) ?? report.uid
                        activeSheet = .irreversible(
                            IrreversibleOpsFlowModel(
                                factory: appModel.sessionFactory,
                                expectedUID: uid,
                                capabilityContainerIsBlank: report.capabilityContainerIsBlank
                            ),
                            report.profile
                        )
                    }
                }
            }
        }
    }

    private var progressBar: some View {
        ProgressView(value: model.progress)
            .tint(HexTokens.Color.primaryLight)
    }

    @ViewBuilder
    private var phaseChip: some View {
        switch model.phase {
        case .idle: chip("Idle", "circle", HexTokens.Color.textSecondary)

        case .identifying: chip("Identifying…", "dot.radiowaves.left.and.right", HexTokens.Color.primaryLight)

        case .confirm(let p, let uid): chip(
                "\(p.displayName) · \(uid.hexString.suffix(11))",
                "checkmark.circle",
                HexTokens.Color.success
            )

        case .running: chip("Running…", "play.circle", HexTokens.Color.primaryLight)

        case .finished(let r): chip(
                r.passed ? "Passed" : "Failed",
                r.passed ? "checkmark.circle.fill" : "xmark.octagon.fill",
                r.passed ? HexTokens.Color.success : HexTokens.Color.dangerText
            )

        case .error: chip("Error", "exclamationmark.triangle", HexTokens.Color.dangerText)
        }
    }

    // MARK: - Small builders

    private func chip(_ title: String, _ systemImage: String, _ tint: Color) -> some View {
        HStack(spacing: HexTokens.Spacing.xs) {
            Image(systemName: systemImage)
            Text(title).font(HexTokens.Font.footnote).lineLimit(1)
        }
        .padding(.horizontal, HexTokens.Spacing.s)
        .padding(.vertical, HexTokens.Spacing.xs)
        .background(Capsule().fill(tint.opacity(HexTokens.Opacity.tintWash)))
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Present the same tag again." The run is not stuck, it is waiting on a
    /// person, so this reads as an instruction rather than as progress.
    private func tapPromptRow(_ text: String) -> some View {
        VStack(spacing: HexTokens.Spacing.xs) {
            Image(systemName: "wave.3.right")
                .font(HexTokens.Font.heading)
                .foregroundStyle(HexTokens.Color.warning)
            Text(text)
                .font(HexTokens.Font.body)
                .foregroundStyle(HexTokens.Color.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("It must be the tag the run started on.")
                .font(HexTokens.Font.footnote)
                .foregroundStyle(HexTokens.Color.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func busyRow(_ text: String) -> some View {
        HStack(spacing: HexTokens.Spacing.s) {
            ProgressView().tint(HexTokens.Color.primaryLight)
            Text(text).font(HexTokens.Font.body).foregroundStyle(HexTokens.Color.textSecondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(HexTokens.Font.heading)
                .frame(maxWidth: .infinity)
                .padding(.vertical, HexTokens.Spacing.m)
                .background(HexTokens.Color.primary)
                .foregroundStyle(HexTokens.Color.textPrimary)
                .clipShape(RoundedRectangle(cornerRadius: HexTokens.Radius.m, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// Half-width tinted follow-up button. Two of these sit side-by-side under the
    /// full-width "Run again", so each is a comfortable tap target.
    private func secondaryButton(_ title: String, systemImage: String, tint: Color,
                                 action: @escaping () -> Void) -> some View
    {
        Button(action: action) {
            VStack(spacing: HexTokens.Spacing.xs) {
                Image(systemName: systemImage).font(.system(size: 18, weight: .semibold))
                Text(title)
                    .font(HexTokens.Font.footnote.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, HexTokens.Spacing.m)
            .background(tint.opacity(0.15))
            .foregroundStyle(tint)
            .clipShape(RoundedRectangle(cornerRadius: HexTokens.Radius.m, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

#endif
