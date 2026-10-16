#if DEBUG && os(iOS)
import HexNFCDesign
import HexNFCKit
import HexNFCShaders
import SwiftUI

/// DEBUG-only, two-to-three-tap flow that proves a Type-2 tag actually ENFORCES
/// password protection on real silicon (the single-tap batch can only prove the
/// config was written). One tap starts a hands-off sequence; the user just keeps
/// the tag on the phone while it arms → tests → removes. Reached from the test
/// harness after a clean pass. Dev tool — copy is plain (exempt from the shipping
/// localization rule; stripped from release).
struct EnforcementCheckView: View {
    @Bindable var model: EnforcementCheckFlowModel
    let profile: ChipProfile
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HexTokens.Spacing.l) {
                    content
                }
                .padding(HexTokens.Spacing.l)
            }
            .background(HexTokens.Color.surface0.ignoresSafeArea())
            .navigationTitle("Verify enforcement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // Disabled mid-run so the user can't dismiss while the tag is
                    // briefly protected between sessions and strand it armed. The NFC
                    // system sheet's Cancel still lets them abort a live session.
                    Button("Done") { dismiss() }
                        .tint(HexTokens.Color.textSecondary)
                        .disabled(isRunning)
                }
            }
        }
        .interactiveDismissDisabled(isRunning)
    }

    private var isRunning: Bool {
        if case .running = model.phase {
            true
        } else {
            false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .intro:
            intro

        case .running:
            running

        case .done(let summary):
            resultBlock(icon: "checkmark.seal.fill", tint: HexTokens.Color.success, title: "Result", body: summary)
                .hexHero(.scanSuccess, trigger: summary)
            Button("Back") { model.reset() }.tint(HexTokens.Color.primaryLight)

        case .failed(let message, let diagnostics, let canRetry):
            resultBlock(
                icon: "xmark.octagon.fill",
                tint: HexTokens.Color.dangerText,
                title: message,
                body: diagnostics.isEmpty ? nil : diagnostics
            )
            .hexHero(.error, trigger: message)
            stepTracker // keep the progress visible so it's clear where it stopped
            HStack(spacing: HexTokens.Spacing.m) {
                if canRetry {
                    Button { model.retry() } label: {
                        Label("Retry", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(HexTokens.Color.primary)
                }
                Button { model.disableNow() } label: {
                    Label("Disable tag", systemImage: "lock.open").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(HexTokens.Color.warning)
            }
            Button("Back") { model.reset() }.tint(HexTokens.Color.primaryLight)
        }
    }

    // MARK: - Intro

    private var intro: some View {
        VStack(alignment: .leading, spacing: HexTokens.Spacing.m) {
            Text(model.introHeadline)
                .font(HexTokens.Font.heading)
                .foregroundStyle(HexTokens.Color.textPrimary)
            Text(model.introBody)
                .font(HexTokens.Font.footnote)
                .foregroundStyle(HexTokens.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            stepTracker
            noteRow(
                "The tag is briefly protected between steps (with the harness's fixed test credential). The sequence always finishes by removing it; if anything interrupts, a Retry / Disable button appears."
            )
            primaryButton("Start enforcement check") { model.start() }
        }
    }

    // MARK: - Running

    private var running: some View {
        VStack(alignment: .leading, spacing: HexTokens.Spacing.l) {
            HStack(spacing: HexTokens.Spacing.s) {
                Image(systemName: "wave.3.right")
                    .foregroundStyle(HexTokens.Color.primaryLight)
                Text("Keep the tag flat on the phone")
                    .font(HexTokens.Font.heading)
                    .foregroundStyle(HexTokens.Color.textPrimary)
            }
            stepTracker
            if !model.statusDetail.isEmpty {
                Text(model.statusDetail)
                    .font(HexTokens.Font.footnote)
                    .foregroundStyle(HexTokens.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .padding(HexTokens.Spacing.m)
        .background(HexTokens.Color.surface1)
        .clipShape(RoundedRectangle(cornerRadius: HexTokens.Radius.m, style: .continuous))
        .hexHero(.consolePulse, trigger: model.pulse)
        .animation(.easeInOut(duration: 0.25), value: model.activeStep)
        .animation(.easeInOut(duration: 0.25), value: model.completedSteps)
    }

    // MARK: - Step tracker

    private var stepTracker: some View {
        VStack(alignment: .leading, spacing: HexTokens.Spacing.s) {
            ForEach(EnforcementCheckFlowModel.Step.allCases, id: \.self) { step in
                HStack(spacing: HexTokens.Spacing.s) {
                    stepIcon(step)
                        .frame(width: 24, height: 24)
                    Text(step.title)
                        .font(HexTokens.Font.body)
                        .foregroundStyle(stepIsPending(step) ? HexTokens.Color.textSecondary : HexTokens.Color
                            .textPrimary)
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private func stepIcon(_ step: EnforcementCheckFlowModel.Step) -> some View {
        if model.completedSteps.contains(step) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(HexTokens.Color.success)
                .font(.system(size: 22))
        } else if model.activeStep == step {
            ProgressView().tint(HexTokens.Color.primaryLight)
        } else {
            Image(systemName: "circle")
                .foregroundStyle(HexTokens.Color.textSecondary.opacity(0.5))
                .font(.system(size: 20))
        }
    }

    private func stepIsPending(_ step: EnforcementCheckFlowModel.Step) -> Bool {
        !model.completedSteps.contains(step) && model.activeStep != step
    }

    // MARK: - Builders

    private func noteRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: HexTokens.Spacing.s) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(HexTokens.Color.textSecondary)
            Text(text)
                .font(HexTokens.Font.footnote)
                .foregroundStyle(HexTokens.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func resultBlock(icon: String, tint: Color, title: String, body: String?) -> some View {
        VStack(alignment: .leading, spacing: HexTokens.Spacing.s) {
            HStack(alignment: .top, spacing: HexTokens.Spacing.s) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(title).font(HexTokens.Font.heading).foregroundStyle(HexTokens.Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let body {
                Text(body)
                    .font(HexTokens.Font.mono)
                    .foregroundStyle(HexTokens.Color.textSecondary)
                    .textSelection(.enabled)
                    .hexCopyable(body)
            }
        }
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
}
#endif
