#if os(iOS)
import HexNFCDesign
import HexNFCRecords
import SwiftUI

/// Inline "help us name this stop" input shown beneath a history row whose
/// station the bundled pack can't name. The user — who has necessarily been to
/// this stop, since it's on their card — types its name and submits. The control
/// optimistically shows "Thanks!" then collapses, so contributing costs nothing.
///
/// Submission is fire-and-forget via `onSubmit` (the network call is best-effort
/// and never blocks the UI). `onComplete` fires after the "Thanks!" beat so the
/// parent can persist the collapsed state across scrolling.
struct StationContributionRow: View {
    let station: StationRef
    let onSubmit: (String) -> Void
    let onComplete: () -> Void

    private enum Phase { case input, thanks, hidden }
    @State private var phase: Phase = .input
    @State private var name: String = ""

    var body: some View {
        switch phase {
        case .hidden:
            EmptyView()

        case .thanks:
            thanks

        case .input:
            input
        }
    }

    /// Context line: name the line if we know it, else generic.
    private var promptText: String {
        if let line = station.lineName {
            return String(format: String(localized: "Unknown stop on %@"), line)
        }
        return String(localized: "Unknown stop")
    }

    private var input: some View {
        VStack(alignment: .leading, spacing: HexTokens.Spacing.xs) {
            Text(verbatim: promptText)
                .font(HexTokens.Font.footnote)
                .foregroundStyle(HexTokens.Color.textSecondary)
            HStack(spacing: HexTokens.Spacing.s) {
                Image(systemName: "mappin.and.ellipse")
                    .font(HexTokens.Font.footnote)
                    .foregroundStyle(HexTokens.Color.textSecondary)
                TextField(text: $name) {
                    Text("Name this station")
                }
                .textFieldStyle(.plain)
                .font(HexTokens.Font.body)
                .foregroundStyle(HexTokens.Color.textPrimary)
                .submitLabel(.send)
                .onSubmit(send)
                Button(action: send) {
                    Text("Submit")
                        .font(HexTokens.Font.footnote)
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSubmit ? HexTokens.Color.primaryLight : HexTokens.Color.textSecondary)
                .disabled(!canSubmit)
            }
        }
        .padding(.horizontal, HexTokens.Spacing.m)
        .padding(.vertical, HexTokens.Spacing.s)
        .background(
            RoundedRectangle(cornerRadius: HexTokens.Radius.m, style: .continuous)
                .fill(HexTokens.Color.surface0)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HexTokens.Radius.m, style: .continuous)
                .strokeBorder(HexTokens.Color.primaryLight.opacity(0.5), lineWidth: 1)
        )
        .padding(.leading, HexTokens.Spacing.xl) // indent under its history row
    }

    private var thanks: some View {
        HStack(spacing: HexTokens.Spacing.s) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(HexTokens.Color.success)
            Text("Thanks!")
                .font(HexTokens.Font.footnote)
                .foregroundStyle(HexTokens.Color.success)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, HexTokens.Spacing.m)
        .padding(.vertical, HexTokens.Spacing.s)
        .padding(.leading, HexTokens.Spacing.xl)
        .transition(.opacity)
    }

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
        withAnimation(HexTokens.Motion.standard) { phase = .thanks }
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            withAnimation(HexTokens.Motion.standard) { phase = .hidden }
            onComplete()
        }
    }
}
#endif
