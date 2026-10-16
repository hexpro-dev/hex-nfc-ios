#if os(iOS)
import HexNFCDesign
import HexNFCKit
import HexNFCRecords
import HexNFCShaders
import SwiftUI

/// Second half of the scan → edit → write loop. Drives `WriteFlowModel`
/// through polling → writing → verifying → done, firing the matching
/// haptic + shader pair at each transition. Surfaces a verification diff
/// inline when the chip writes back something different.
struct WriteSheet: View {
    @Bindable var model: WriteFlowModel
    /// Called once the success moment has played out.
    ///
    /// Carries what the write read back off the tag, or `nil` when the write
    /// carried no protection change and so established nothing new. The editor
    /// uses it to stop showing the protection state the tag had *before* this
    /// write.
    let onSuccess: (TagObservation?) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Centre of the hexagon logo (in the burst coordinate space), so the
    /// success ring emanates from the logo rather than the geometric centre.
    @State private var logoCenter: CGPoint?
    @State private var unlockHex = ""

    // MARK: - Family-aware unlock

    /// The protection family the unlock prompt should collect a credential for,
    /// defaulting to Type-2 (the common writable tag) before detection.
    private var unlockFamily: ProtectionStyle {
        model.unlockStyle ?? .type2(.init())
    }

    /// Byte count, noun and credential shape all come from `ProtectionStyle`
    /// (see `UnlockPrompt.swift`) so this sheet and `ScanSheet` cannot drift, and
    /// so a new credential shape is one edit rather than two.
    private var unlockIsKey: Bool {
        unlockFamily.unlockSecretIsKey
    }

    private var unlockExpectedBytes: Int {
        unlockFamily.unlockSecretByteCount
    }

    private var unlockFieldLabel: LocalizedStringKey {
        unlockFamily.unlockSecretDescription
    }

    /// Names the cipher for the same reason the field label does: an NTAG424 and
    /// an Ultralight C both want a 16-byte key, and they are not the same key.
    private var unlockPromptCopy: LocalizedStringKey {
        switch unlockFamily {
        case .type4:
            "This tag is key-protected. Enter its 16-byte AES key to write to it, then hold it to the top of your iPhone again."

        case .ultralightC:
            "This tag is key-protected. Enter its 16-byte 3DES key to write to it, then hold it to the top of your iPhone again."

        case .type2, .type5:
            "This tag is password-protected. Enter its password to write to it, then hold it to the top of your iPhone again."
        }
    }

    private var unlockFailedCopy: LocalizedStringKey {
        unlockIsKey
            ? "That key didn't unlock the tag. Check it and try again."
            : "That password didn't unlock the tag. Check it and try again."
    }

    /// Build the family-tagged credential from the entered hex, or `nil` if it
    /// isn't the expected length yet.
    private func makeUnlockCredential() -> TagCredential? {
        guard let bytes = Data.parseHex(unlockHex) else { return nil }
        return unlockFamily.unlockCredential(from: bytes)
    }

    var body: some View {
        ZStack {
            HexTokens.Color.surface0.ignoresSafeArea()
            content
                .padding(HexTokens.Spacing.xl)
        }
        .hexHero(.scanIdle, isActive: model.phase == .polling || model.phase == .identifying)
        .hexHero(.destructiveWarn, trigger: isAwaitingConfirmation ? 1 : 0)
        .hexHero(.writeTransmit, trigger: model.phase == .writing ? 1 : 0)
        .hexHero(.writeVerify, trigger: model.phase == .verifying ? 1 : 0)
        .hexHero(.writeTransmit, trigger: model.phase == .applyingProtection ? 1 : 0)
        .hexHero(.writeTransmit, trigger: model.phase == .removingProtection ? 1 : 0)
        .hexHero(.writeLockIn, trigger: model.phase == .done ? 1 : 0)
        .hexHero(.error, trigger: errorTriggerValue)
        // Visual half of the lock-in: a rainbow ring bursts from the logo, an
        // inner trail ripples out, and the screen edge glows then fades.
        .hexWriteBurst(trigger: model.phase == .done ? 1 : 0, origin: logoCenter)
        .onPreferenceChange(WriteBurstOriginKey.self) { logoCenter = $0 }
        .accessibilityIdentifier("write.sheet")
        .onChange(of: model.phase) { _, newPhase in
            // Closed before any tag was in play: back to the editor, or to Home
            // for a preset written from the Library (which closed itself when
            // the write began, as it does for every outcome on that route),
            // with nothing written and so nothing to say. `onDisappear` below
            // resets the model.
            if newPhase == .cancelled {
                dismiss()
                return
            }
            if case .done = newPhase {
                // Hand back once two things are true: the full burst (ring →
                // trail → edge glow) has played, and "Locked in" has been seen
                // in the clear. The burst fires as the write lands, under the
                // system NFC sheet, which iOS keeps up for about 2.7 s; closing
                // on a 1.7 s timer took "Locked in" away before the card had gone
                // (operator, 2026-09-19). An unstructured task on purpose: it
                // outlives a swipe dismissal, and the editor needs the reading.
                let doneAt = ContinuousClock.now
                Task {
                    await model.systemSheetDismissal()
                    let burstEnds = doneAt.advanced(by: .milliseconds(1700))
                    let seenInTheClear = ContinuousClock.now.advanced(by: .milliseconds(800))
                    try? await Task.sleep(until: max(burstEnds, seenInTheClear), clock: .continuous)
                    onSuccess(model.observation)
                }
            }
        }
        // Last in the chain, and they have to stay last. These two own the run:
        // `.task` starts it and `onDisappear` ends it, and SwiftUI fires both
        // again whenever it rebuilds the view they are attached to. An effect
        // modifier can do that: `hexWriteBurst` swaps branches around what it
        // wraps when the burst starts. Inside it, the rebuild reset the finished
        // write to `.ready` and the new `.task` began it again, so every
        // successful write opened a second session that iOS refused with error
        // 202 (bench 2026-09-19).
        .task { await model.begin() }
        // A swipe-dismiss at the gate would otherwise leave `begin()` suspended
        // on a continuation nothing can resume.
        .onDisappear { model.reset() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        // `.cancelled` holds the polling screen while the sheet slides away.
        case .ready, .polling, .cancelled:
            polling

        case .identifying:
            identifying

        case .awaitingConfirmation(let uidHex):
            confirmation(uidHex: uidHex)

        case .writing:
            writing

        case .verifying:
            verifying

        case .applyingProtection:
            applyingProtection

        case .removingProtection:
            removingProtection

        case .needsUnlock:
            needsUnlock

        case .done:
            done

        case .noTagFound:
            noTagFound

        case .error(let message, let diagnostics):
            errorView(message: message, diagnostics: diagnostics)
        }
    }

    /// Tap 1 of a confirmed write: the same hexagon as `polling`, with the count
    /// said out loud so the second hold is expected rather than a surprise.
    private var identifying: some View {
        VStack(spacing: HexTokens.Spacing.l) {
            HexTransition(state: .present, size: 120)
            Text("Hold tag against the top of your iPhone")
                .font(HexTokens.Font.title)
                .multilineTextAlignment(.center)
                .foregroundStyle(HexTokens.Color.textPrimary)
            Text("Tap 1 of 2. Hold the tag to identify it.")
                .font(HexTokens.Font.body)
                .foregroundStyle(HexTokens.Color.textSecondary)
                .multilineTextAlignment(.center)
        }
        .accessibilityIdentifier("write.identifying")
    }

    /// The typed-UID gate, shown with no NFC session open, exactly as Operations
    /// asks for it. The warning is family-aware, which Operations never needed:
    /// this is the only route that arms an AES or 3DES key, and neither has a
    /// factory reset.
    private func confirmation(uidHex: String) -> some View {
        VStack(alignment: .leading, spacing: HexTokens.Spacing.l) {
            DestructiveConfirmationView(
                title: confirmationTitle,
                warning: confirmationWarning,
                // The whole UID, not a 4-character tail: tags from one batch can
                // share their trailing bytes (live-confirmed on Ultralight C,
                // 2026-08-07), which made the gate identical across a stack.
                uidTail: uidHex.replacingOccurrences(of: ":", with: ""),
                actionTitle: confirmationTitle,
                isBusy: false,
                onConfirm: { model.confirm() }
            )
            // Walking away from the gate would otherwise leave `begin()`
            // suspended on the confirmation continuation forever. `reset()`
            // resolves it, and `.onDisappear` covers a swipe-dismiss.
            HexButton("Cancel", variant: .ghost) {
                model.reset()
                dismiss()
            }
        }
        .accessibilityIdentifier("write.awaitingConfirmation")
    }

    private var confirmationTitle: LocalizedStringKey {
        model.removeProtection ? "Remove protection" : "Protect tag"
    }

    /// Reuses the warnings the app already ships, and already translates: the
    /// Protection card's own key warnings for the two key families, the
    /// Operations password warning for the two password families, and the
    /// Operations removal warning for a removal. A removal carries no
    /// `PendingProtection`, so there is no family to switch on there and the
    /// family-neutral sentence is also the only one that implements cleanly.
    private var confirmationWarning: LocalizedStringKey {
        if model.removeProtection {
            return "After this, anyone can write this tag again."
        }
        switch model.protection?.settings.effectiveStyle {
        case .type4:
            return "Lose this key and you can never rewrite this tag. There is no factory reset for an NTAG424. Store it safely."

        case .ultralightC:
            return "Lose this key and the protected memory can never be rewritten. Ultralight C has no factory reset. Store it safely."

        case .type2, .type5, nil:
            return "If you lose this password, protected memory on this tag is irrecoverable."
        }
    }

    private var polling: some View {
        VStack(spacing: HexTokens.Spacing.l) {
            HexTransition(state: .present, size: 120)
            Text("Hold tag against the top of your iPhone")
                .font(HexTokens.Font.title)
                .multilineTextAlignment(.center)
                .foregroundStyle(HexTokens.Color.textPrimary)
            // The tap that does the writing, on a run that confirmed a tag. It
            // has to say which tap this is and that it must be the same tag,
            // because the refusal for any other one is unexplained otherwise.
            if model.isSecondTap {
                Text("Tap 2 of 2. Hold the same tag again.")
                    .font(HexTokens.Font.body)
                    .foregroundStyle(HexTokens.Color.textSecondary)
                    .multilineTextAlignment(.center)
            }
            HexButton("Cancel", variant: .ghost) {
                model.reset()
                dismiss()
            }
        }
    }

    private var writing: some View {
        VStack(spacing: HexTokens.Spacing.l) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(HexTokens.Color.primary)
                .scaleEffect(1.5)
            Text("Writing…")
                .font(HexTokens.Font.heading)
                .foregroundStyle(HexTokens.Color.primaryLight)
        }
    }

    private var verifying: some View {
        VStack(spacing: HexTokens.Spacing.l) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(HexTokens.Color.primaryLight)
                .scaleEffect(1.5)
            Text("Verifying…")
                .font(HexTokens.Font.heading)
                .foregroundStyle(HexTokens.Color.primaryLight)
        }
    }

    private var applyingProtection: some View {
        VStack(spacing: HexTokens.Spacing.l) {
            Image(systemName: "lock.fill")
                .font(.system(size: 44))
                .foregroundStyle(HexTokens.Color.warning)
            ProgressView()
                .progressViewStyle(.circular)
                .tint(HexTokens.Color.warning)
                .scaleEffect(1.5)
            Text("Applying protection…")
                .font(HexTokens.Font.heading)
                .foregroundStyle(HexTokens.Color.warning)
        }
        .accessibilityIdentifier("write.applyingProtection")
    }

    private var removingProtection: some View {
        VStack(spacing: HexTokens.Spacing.l) {
            Image(systemName: "lock.open.fill")
                .font(.system(size: 44))
                .foregroundStyle(HexTokens.Color.primaryLight)
            ProgressView()
                .progressViewStyle(.circular)
                .tint(HexTokens.Color.primaryLight)
                .scaleEffect(1.5)
            Text("Removing protection…")
                .font(HexTokens.Font.heading)
                .foregroundStyle(HexTokens.Color.primaryLight)
        }
        .accessibilityIdentifier("write.removingProtection")
    }

    /// Shown when the target tag is already password-protected and we don't hold
    /// (a correct) password for it. Collects the tag password and retries the
    /// write — the next tap authenticates before writing.
    private var needsUnlock: some View {
        VStack(alignment: .leading, spacing: HexTokens.Spacing.l) {
            HStack(spacing: HexTokens.Spacing.s) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(HexTokens.Color.warning)
                Text("Tag is protected")
                    .font(HexTokens.Font.title)
                    .foregroundStyle(HexTokens.Color.textPrimary)
            }
            Group {
                if let refusalCopy = model.unlockRefusal?.unlockPromptCopy {
                    Text(refusalCopy)
                } else {
                    Text(model.unlockFailed ? unlockFailedCopy : unlockPromptCopy)
                }
            }
            .font(HexTokens.Font.body)
            .foregroundStyle(
                model.unlockFailed || model.unlockRefusal?.unlockPromptCopy != nil
                    ? HexTokens.Color.dangerText : HexTokens.Color.textPrimary
            )
            // Outside the prompt/refusal branch above, so it also stands under
            // the attempt-limit copy.
            if model.awaitsUIDConfirmation {
                Text(
                    "A protection change takes two holds: the first reads the tag's ID so you can confirm it, the second makes the change."
                )
                .font(HexTokens.Font.footnote)
                .foregroundStyle(HexTokens.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            // The field + credential adapt to the tag's family: a 4-byte password
            // for Type-2 / SLIX, a 16-byte AES key for an NTAG424, a 16-byte 3DES
            // key for an Ultralight C.
            HexHexField(label: unlockFieldLabel, hex: $unlockHex, expectedBytes: unlockExpectedBytes)
            // "Unlock & write" is a false promise on a gated run: the next
            // thing the user sees is the UID card, not a write.
            HexButton(
                model.awaitsUIDConfirmation ? "Unlock & continue" : "Unlock & write",
                systemImage: "lock.open",
                variant: .primary
            ) {
                guard let credential = makeUnlockCredential() else { return }
                Task { await model.unlock(with: credential) }
            }
            .disabled(makeUnlockCredential() == nil)
            .accessibilityIdentifier("write.unlock")
            HexButton("Cancel", variant: .ghost) {
                model.reset()
                dismiss()
            }
        }
        .accessibilityIdentifier("write.needsUnlock")
    }

    private var done: some View {
        VStack(spacing: HexTokens.Spacing.l) {
            HexTransition(state: .present, size: 120)
                .background(burstOriginReader)
            Text("Locked in")
                .font(HexTokens.Font.title)
                .foregroundStyle(HexTokens.Color.textPrimary)
            Text("Your tag is now writing this image.")
                .font(HexTokens.Font.body)
                .foregroundStyle(HexTokens.Color.textSecondary)
                .multilineTextAlignment(.center)
        }
        .accessibilityIdentifier("write.done")
    }

    /// The tap timed out with nothing in the field, on a write that has never
    /// had a tag, so nothing was written and there is no failure to report.
    /// Neutral, with no error haptic: `errorTriggerValue` is zero here.
    private var noTagFound: some View {
        VStack(alignment: .leading, spacing: HexTokens.Spacing.l) {
            NoTagFoundNotice()
            HStack(spacing: HexTokens.Spacing.m) {
                HexButton("Close", variant: .secondary) {
                    model.reset()
                    dismiss()
                }
                HexButton("Try again", variant: .primary) {
                    Task { await model.retry() }
                }
            }
        }
        .accessibilityIdentifier("write.noTagFound")
    }

    private func errorView(message: String, diagnostics: String) -> some View {
        VStack(alignment: .leading, spacing: HexTokens.Spacing.l) {
            HStack(spacing: HexTokens.Spacing.s) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(HexTokens.Color.dangerText)
                Text("Write failed")
                    .font(HexTokens.Font.title)
                    .foregroundStyle(HexTokens.Color.textPrimary)
            }
            Text(message)
                .font(HexTokens.Font.body)
                .foregroundStyle(HexTokens.Color.textPrimary)
            DisclosureGroup("Diagnostics") {
                Text(diagnostics)
                    .font(HexTokens.Font.mono)
                    .foregroundStyle(HexTokens.Color.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .tint(HexTokens.Color.primaryLight)
            HStack(spacing: HexTokens.Spacing.m) {
                HexButton("Close", variant: .secondary) {
                    model.reset()
                    dismiss()
                }
                HexButton("Try again", variant: .primary) {
                    // `retry()`, not `reset()` + `begin()`: a slipped tag must
                    // not cost the user a re-typed password as well as a
                    // re-typed UID.
                    Task { await model.retry() }
                }
            }
        }
    }

    private var isAwaitingConfirmation: Bool {
        if case .awaitingConfirmation = model.phase {
            return true
        }
        return false
    }

    private var errorTriggerValue: Int {
        if case .error = model.phase {
            return model.transitionCount
        }
        return 0
    }

    /// Reports the logo's centre in the burst coordinate space so the ring
    /// originates from the logo. Lives in the logo's `background` so it tracks
    /// the logo's frame exactly.
    private var burstOriginReader: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .named(HexWriteBurst.coordinateSpaceName))
            Color.clear.preference(
                key: WriteBurstOriginKey.self,
                value: CGPoint(x: frame.midX, y: frame.midY)
            )
        }
    }
}

/// Carries the write-success logo centre up to `WriteSheet`, which feeds it to
/// `.hexWriteBurst(origin:)`.
private struct WriteBurstOriginKey: PreferenceKey {
    static let defaultValue: CGPoint? = nil
    static func reduce(value: inout CGPoint?, nextValue: () -> CGPoint?) {
        value = nextValue() ?? value
    }
}
#endif
