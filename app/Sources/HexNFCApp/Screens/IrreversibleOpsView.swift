#if DEBUG && os(iOS)
import HexNFCDesign
import HexNFCKit
import HexNFCShaders
import SwiftUI

/// DEBUG-only gated flow for irreversible operations. Reached only from the test
/// harness, and only after the chip passed the full non-destructive suite this
/// run. One operation at a time, typed-UID confirmed. Dev tool — copy is plain
/// (exempt from the shipping localization rule; stripped from release).
struct IrreversibleOpsView: View {
    @Bindable var model: IrreversibleOpsFlowModel
    let profile: ChipProfile
    @Environment(\.dismiss) private var dismiss

    /// Applicability lives on `Operation` so it is unit-testable — this view is
    /// iOS-only and `swift test` can't reach it.
    private var applicableOperations: [IrreversibleOpsFlowModel.Operation] {
        IrreversibleOpsFlowModel.Operation.allCases.filter {
            $0.applies(to: profile)
                && $0.appliesToTag(capabilityContainerIsBlank: model.capabilityContainerIsBlank)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HexTokens.Spacing.l) {
                    banner
                    content
                }
                .padding(HexTokens.Spacing.l)
            }
            .background(HexTokens.Color.surface0.ignoresSafeArea())
            .navigationTitle("Irreversible ops")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.tint(HexTokens.Color.textSecondary)
                }
            }
        }
    }

    private var banner: some View {
        HStack(spacing: HexTokens.Spacing.s) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(HexTokens.Color.dangerText)
            Text("These actions permanently and irreversibly change the tag. Use sacrificial tags only.")
                .font(HexTokens.Font.footnote)
                .foregroundStyle(HexTokens.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(HexTokens.Spacing.m)
        .background(HexTokens.Color.danger.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: HexTokens.Radius.m, style: .continuous))
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            operationList

        case .confirming(let uidTail):
            DestructiveConfirmationView(
                title: LocalizedStringKey(model.operation.title),
                warning: LocalizedStringKey(model.operation.warning),
                uidTail: uidTail,
                actionTitle: LocalizedStringKey(model.operation.title),
                onConfirm: { model.confirmAndExecute() }
            )
            .hexHero(.destructiveWarn, trigger: uidTail)
            Button("Cancel") { model.cancel() }
                .tint(HexTokens.Color.textSecondary)

        case .executing:
            HStack(spacing: HexTokens.Spacing.s) {
                ProgressView().tint(HexTokens.Color.dangerText)
                Text("Hold the tag against the phone…").font(HexTokens.Font.body)
            }

        case .done(let summary):
            resultBlock(icon: "checkmark.seal.fill", tint: HexTokens.Color.success, title: "Done", body: summary)
            Button("Back") { model.cancel() }.tint(HexTokens.Color.primaryLight)

        case .error(let message, let diagnostics):
            resultBlock(
                icon: "xmark.octagon.fill",
                tint: HexTokens.Color.dangerText,
                title: message,
                body: diagnostics.isEmpty ? nil : diagnostics
            )
            Button("Back") { model.cancel() }.tint(HexTokens.Color.primaryLight)
        }
    }

    private var operationList: some View {
        VStack(alignment: .leading, spacing: HexTokens.Spacing.m) {
            Text("Select one operation")
                .font(HexTokens.Font.footnote)
                .foregroundStyle(HexTokens.Color.textSecondary)
            ForEach(applicableOperations) { op in
                Button {
                    model.select(op)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(op.title).font(HexTokens.Font.heading)
                            Text(op.isImplemented ? "Available" : "Not implemented in this build")
                                .font(HexTokens.Font.footnote)
                                .foregroundStyle(op.isImplemented ? HexTokens.Color.warning : HexTokens.Color
                                    .textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(HexTokens.Color.textSecondary)
                    }
                    .padding(HexTokens.Spacing.m)
                    .background(HexTokens.Color.surface1)
                    .clipShape(RoundedRectangle(cornerRadius: HexTokens.Radius.m, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(HexTokens.Color.textPrimary)
            }
            if applicableOperations.isEmpty {
                Text("No irreversible operations apply to this chip family.")
                    .font(HexTokens.Font.footnote)
                    .foregroundStyle(HexTokens.Color.textSecondary)
            }
        }
    }

    private func resultBlock(icon: String, tint: Color, title: String, body: String?) -> some View {
        VStack(alignment: .leading, spacing: HexTokens.Spacing.s) {
            HStack(spacing: HexTokens.Spacing.s) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(title).font(HexTokens.Font.heading).foregroundStyle(HexTokens.Color.textPrimary)
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
}
#endif
