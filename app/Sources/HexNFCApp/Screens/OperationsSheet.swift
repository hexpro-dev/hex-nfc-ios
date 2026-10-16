#if os(iOS)
import HexNFCDesign
import HexNFCKit
import HexNFCRecords
import HexNFCShaders
import SwiftUI
import UniformTypeIdentifiers

/// Top-level operations launcher. Seven tiles → push to a per-op subview.
/// Each subview owns its own `OperationsFlowModel` for the duration of the
/// NFC interaction. Destructive operations gate behind `DestructiveConfirmation`.
struct OperationsSheet: View {
    @Bindable var appModel: AppModel
    /// Fired when an operation establishes something about a tag **by reading
    /// it**. Defaults to doing nothing, so a caller with no tag on screen can
    /// present this sheet exactly as before.
    ///
    /// This sheet deliberately does not know whether the reading is about the
    /// caller's tag. Every operation runs against whatever tag the user
    /// presents, which need not be the one behind this sheet, so the
    /// observation carries its own UID and the receiver decides.
    var onTagChanged: (TagObservation) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HexTokens.Spacing.xl) {
                    // Tools — recoverable operations.
                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible())],
                        spacing: HexTokens.Spacing.l
                    ) {
                        OperationTile(
                            title: "Protect with password",
                            systemImage: "lock",
                            tint: HexTokens.Color.warning,
                            destination: AnyView(
                                ProtectWithPasswordOperationView(appModel: appModel, onTagChanged: onTagChanged)
                            )
                        )
                        OperationTile(
                            title: "Remove password",
                            systemImage: "lock.open",
                            tint: HexTokens.Color.warning,
                            destination: AnyView(
                                RemovePasswordOperationView(appModel: appModel, onTagChanged: onTagChanged)
                            )
                        )
                        OperationTile(
                            title: "Memory dump",
                            systemImage: "doc.on.doc",
                            tint: HexTokens.Color.primaryLight,
                            destination: AnyView(MemoryDumpOperationView(appModel: appModel))
                        )
                    }

                    // Dangerous Actions — destructive / irreversible, set apart.
                    DangerousActionsSection {
                        LazyVGrid(
                            columns: [GridItem(.flexible()), GridItem(.flexible())],
                            spacing: HexTokens.Spacing.l
                        ) {
                            OperationTile(
                                title: "Erase",
                                systemImage: "trash",
                                tint: HexTokens.Color.dangerText,
                                destination: AnyView(EraseOperationView(appModel: appModel, onTagChanged: onTagChanged))
                            )
                            OperationTile(
                                title: "Format",
                                systemImage: "wand.and.rays",
                                tint: HexTokens.Color.dangerText,
                                destination: AnyView(FormatOperationView(
                                    appModel: appModel,
                                    onTagChanged: onTagChanged
                                ))
                            )
                            OperationTile(
                                title: "Permanent lock",
                                systemImage: "lock.shield",
                                tint: HexTokens.Color.dangerText,
                                destination: AnyView(PermanentLockOperationView(
                                    appModel: appModel,
                                    onTagChanged: onTagChanged
                                ))
                            )
                            OperationTile(
                                title: "Attempt limit",
                                systemImage: "exclamationmark.lock",
                                tint: HexTokens.Color.dangerText,
                                destination: AnyView(SetAttemptLimitOperationView(
                                    appModel: appModel,
                                    onTagChanged: onTagChanged
                                ))
                            )
                        }
                    }
                }
                .padding(HexTokens.Spacing.l)
            }
            .background(HexTokens.Color.surface0.ignoresSafeArea())
            .navigationTitle(Text("Operations"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(HexTokens.Color.primaryLight)
                }
            }
            .toolbarBackground(HexTokens.Color.surface0, for: .navigationBar)
            .preferredColorScheme(.dark)
        }
    }
}

/// Strongly-separated container for destructive / irreversible operations.
/// Danger-tinted heading, warning copy, and a danger border set it apart from
/// the recoverable tools above.
private struct DangerousActionsSection<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: HexTokens.Spacing.m) {
            HStack(spacing: HexTokens.Spacing.s) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(HexTokens.Color.dangerText)
                Text("Dangerous Actions")
                    .font(HexTokens.Font.heading)
                    .foregroundStyle(HexTokens.Color.dangerText)
            }
            Text(
                "Destructive or irreversible. Each one holds the tag twice: once to read its ID, then again to make the change, and you type the ID in between."
            )
            .font(HexTokens.Font.footnote)
            .foregroundStyle(HexTokens.Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            content()
        }
        .padding(HexTokens.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HexTokens.Radius.l, style: .continuous)
                .fill(HexTokens.Color.danger.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: HexTokens.Radius.l, style: .continuous)
                .stroke(HexTokens.Color.danger.opacity(0.4), lineWidth: 1)
        )
        .accessibilityIdentifier("operations.dangerousActions")
    }
}

private struct OperationTile: View {
    let title: LocalizedStringKey
    let systemImage: String
    let tint: Color
    let destination: AnyView

    var body: some View {
        NavigationLink(destination: destination) {
            VStack(alignment: .leading, spacing: HexTokens.Spacing.s) {
                Image(systemName: systemImage)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(tint)
                Text(title)
                    .font(HexTokens.Font.heading)
                    .foregroundStyle(HexTokens.Color.textPrimary)
                Text("Tap to begin")
                    .font(HexTokens.Font.footnote)
                    .foregroundStyle(HexTokens.Color.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
            .padding(HexTokens.Spacing.l)
            .background(
                RoundedRectangle(cornerRadius: HexTokens.Radius.l, style: .continuous)
                    .fill(HexTokens.Color.surface1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HexTokens.Radius.l, style: .continuous)
                    .stroke(HexTokens.Stroke.cardInner, lineWidth: HexTokens.Stroke.cardInnerWidth)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Per-operation views

private struct OperationContainer<Content: View>: View {
    let title: LocalizedStringKey
    let intro: LocalizedStringKey
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HexTokens.Spacing.l) {
                Text(intro)
                    .font(HexTokens.Font.body)
                    .foregroundStyle(HexTokens.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                content()
            }
            .padding(HexTokens.Spacing.l)
        }
        .background(HexTokens.Color.surface0.ignoresSafeArea())
        .navigationTitle(Text(title))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(HexTokens.Color.surface0, for: .navigationBar)
    }
}

private struct PhaseBanner: View {
    let phase: OperationsFlowModel.Phase
    /// What `.executing` is actually doing. Memory dump is a pure read, and the
    /// banner told its users the app was "Writing…" to a tag they had asked it
    /// only to read — the one operation here where that word is alarming and
    /// wrong.
    var executingLabel: LocalizedStringKey = "Writing…"
    /// Confirming operations poll twice; the second prompt says which tap it is
    /// so the user isn't left wondering why the tag is being asked for again.
    var pollingLabel: LocalizedStringKey = "Hold the tag against the top of your iPhone."

    var body: some View {
        switch phase {
        // A run the user backed out of before any tag is the starting state
        // again, and says nothing.
        case .idle, .cancelled:
            EmptyView()

        case .identifying:
            HStack(spacing: HexTokens.Spacing.s) {
                ProgressView().tint(HexTokens.Color.primaryLight)
                Text("Tap 1 of 2. Hold the tag to identify it.")
                    .font(HexTokens.Font.body)
                    .foregroundStyle(HexTokens.Color.textSecondary)
            }

        case .polling:
            HStack(spacing: HexTokens.Spacing.s) {
                ProgressView().tint(HexTokens.Color.primaryLight)
                Text(pollingLabel)
                    .font(HexTokens.Font.body)
                    .foregroundStyle(HexTokens.Color.textSecondary)
            }

        case .connected(let uid):
            HStack(spacing: HexTokens.Spacing.s) {
                Image(systemName: "checkmark.seal")
                    .foregroundStyle(HexTokens.Color.success)
                Text("Connected · \(uid)")
                    .font(HexTokens.Font.mono)
                    .foregroundStyle(HexTokens.Color.textSecondary)
                    .hexCopyable(uid)
            }

        case .awaitingConfirmation, .needsUnlock:
            // Both phases put their own card on screen, with its own heading and
            // its own explanation. A second line above it would say less.
            EmptyView()

        case .executing:
            HStack(spacing: HexTokens.Spacing.s) {
                ProgressView().tint(HexTokens.Color.primaryLight)
                Text(executingLabel)
                    .font(HexTokens.Font.body)
                    .foregroundStyle(HexTokens.Color.textSecondary)
            }

        case .verifying:
            HStack(spacing: HexTokens.Spacing.s) {
                ProgressView().tint(HexTokens.Color.primaryLight)
                Text("Verifying…")
                    .font(HexTokens.Font.body)
                    .foregroundStyle(HexTokens.Color.textSecondary)
            }

        case .done(let summary):
            VStack(alignment: .leading, spacing: HexTokens.Spacing.xs) {
                HStack(spacing: HexTokens.Spacing.s) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(HexTokens.Color.success)
                    Text(summaryText(summary))
                        .font(HexTokens.Font.heading)
                        .foregroundStyle(HexTokens.Color.success)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // A lock we couldn't witness this tap gets its reason spelled out
                // rather than a quieter headline and no explanation.
                if case .permanentlyLocked(verified: false) = summary {
                    Text(
                        "This chip's lock bits only take effect at the next tap, so it can't be checked in this session. Scan the tag again to confirm it now refuses writes."
                    )
                    .font(HexTokens.Font.footnote)
                    .foregroundStyle(HexTokens.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                // Same distinction, same reason: the chip acknowledged the write
                // and this tap could not read the byte back, which is missing
                // knowledge rather than a failed write.
                if case .attemptLimitSet(_, verified: false) = summary {
                    Text(
                        "The tag acknowledged the write, but this tap couldn't read the byte back. Start the operation again: the first tap reports the limit the tag is holding."
                    )
                    .font(HexTokens.Font.footnote)
                    .foregroundStyle(HexTokens.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                // The headline reports the setting the read-back proved. The
                // consequence is a warning, and goes where the unverified
                // sibling puts its explanation rather than in the success colour.
                if case .attemptLimitSet(_, verified: true) = summary {
                    Text("One more wrong try after that and it stops accepting its password for good.")
                        .font(HexTokens.Font.footnote)
                        .foregroundStyle(HexTokens.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // "Nothing written" is a fine answer to a tag that reads, and a
                // dead end to a tag that doesn't. Format only ever touches page
                // 3, so a tag whose Capability Container is already right and
                // which still refuses to read has its fault somewhere this
                // operation cannot reach. Name the one that can.
                if case .formatted(alreadyFormatted: true) = summary {
                    Text(
                        "Page 3 already holds this chip's Capability Container. If the tag still won't read, the data area is what needs rewriting: use Erase."
                    )
                    .font(HexTokens.Font.footnote)
                    .foregroundStyle(HexTokens.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

        case .noTagFound:
            NoTagFoundNotice(titleFont: HexTokens.Font.heading)

        case .error(let message, let diagnostics):
            VStack(alignment: .leading, spacing: HexTokens.Spacing.s) {
                HStack(spacing: HexTokens.Spacing.s) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(HexTokens.Color.dangerText)
                    Text(message)
                        .font(HexTokens.Font.heading)
                        .foregroundStyle(HexTokens.Color.dangerText)
                }
                DisclosureGroup("Diagnostics") {
                    Text(diagnostics)
                        .font(HexTokens.Font.mono)
                        .foregroundStyle(HexTokens.Color.textSecondary)
                        .textSelection(.enabled)
                        .hexCopyable(diagnostics)
                }
                .tint(HexTokens.Color.primaryLight)
            }
        }
    }

    private func summaryText(_ summary: OperationsFlowModel.Summary) -> LocalizedStringKey {
        switch summary {
        case .erased:
            "Tag erased."

        // The OTP page gets one write per tag, so "already correct, nothing
        // written" is worth saying out loud rather than reporting as a format.
        case .formatted(alreadyFormatted: true):
            "Already formatted: nothing written."

        case .formatted(alreadyFormatted: false):
            "Tag formatted."

        case .permanentlyLocked(verified: true):
            "Tag permanently locked."

        case .permanentlyLocked(verified: false):
            "Lock written."

        case .passwordSet:
            "Password set."

        case .passwordRemoved:
            "Password removed."

        // The number is the limit the operation asked for, and `verify` has
        // already thrown unless the ACCESS byte read back equal to it, so the
        // verified headline can only ever show the byte the tag holds. What the
        // number means is stated the way the stepper states it, as tries the
        // tag allows; the try that stops it is one past that, and goes in the
        // footnote below the headline rather than in the success colour.
        case .attemptLimitSet(let limit, verified: true):
            "This tag is now set to allow ^[\(limit) wrong try](inflect: true)."

        case .attemptLimitSet(_, verified: false):
            "Attempt limit written."

        case .memoryDumped:
            "Memory dump ready."
        }
    }
}

// MARK: Erase / Format / Lock — pure destructive (no inputs)

private struct EraseOperationView: View {
    @Bindable var appModel: AppModel
    var onTagChanged: (TagObservation) -> Void = { _ in }
    @State private var model: OperationsFlowModel

    init(appModel: AppModel, onTagChanged: @escaping (TagObservation) -> Void = { _ in }) {
        self.appModel = appModel
        self.onTagChanged = onTagChanged
        _model = State(initialValue: OperationsFlowModel(
            factory: appModel.sessionFactory,
            operation: .erase,
            credentials: appModel.library.tagCredentials
        ))
    }

    var body: some View {
        OperationContainer(
            title: "Erase",
            // Scoped deliberately. This screen is opened before a tag is tapped
            // and carries no chip gate, so anything it states has to be true of
            // every family it can be shown for. The residue is a Type-2 page-path
            // fact, measured on 2026-09-09, and it is written as one. Nothing here
            // points the user at a memory dump either: that operation refuses to
            // run on anything but Type-2.
            intro: "Write an empty message over the tag's data area. Readers will see a blank tag, the chip stays writable, and a data area that won't read is rebuilt.\n\nThis replaces the message rather than wiping the memory. On the tags Hex NFC writes page by page, the empty message is one page long, so the bytes of the old one stay where they were until something writes over them."
        ) {
            destructiveBody(
                model: model,
                alert: "Hold tag to erase.",
                actionTitle: "Erase tag",
                warning: "This clears the tag's records. It replaces the message rather than erasing the memory, so on the tags Hex NFC writes page by page the old bytes stay in the pages until something writes over them.",
                onTagChanged: onTagChanged
            )
        }
        .operationMoments(model)
    }
}

private struct FormatOperationView: View {
    @Bindable var appModel: AppModel
    var onTagChanged: (TagObservation) -> Void = { _ in }
    @State private var model: OperationsFlowModel

    init(appModel: AppModel, onTagChanged: @escaping (TagObservation) -> Void = { _ in }) {
        self.appModel = appModel
        self.onTagChanged = onTagChanged
        _model = State(initialValue: OperationsFlowModel(
            factory: appModel.sessionFactory,
            operation: .format,
            credentials: appModel.library.tagCredentials
        ))
    }

    var body: some View {
        OperationContainer(
            title: "Format",
            // Scoped the same way the Erase intro is, and for the same reason:
            // no chip is known until the tap, so every sentence has to hold for
            // both families. "It does not touch the data area." was true of the
            // Type-2 path and false of the Type-5 one, which wrote an empty
            // message over block 1 and took a SLIX2 owner's records with it
            // (2026-09-22). `Type5Formatter` now seeds that empty message only
            // into a blank area, so the promise holds everywhere and the user is
            // sent to the operation that does mean to clear a tag.
            intro: "Write the Capability Container so the chip declares itself as an NDEF tag. Use this on a fresh chip that wasn't shipped pre-formatted.\n\nRecords already on the tag stay where they are. A tag that has never held a message gets an empty one, so a reader sees a blank tag rather than a broken one. To clear a tag that has records on it, use Erase."
        ) {
            destructiveBody(
                model: model,
                alert: "Hold tag to format.",
                actionTitle: "Format tag",
                // The old warning ("Existing NDEF records become unreadable
                // until rewritten") contradicted the intro above and was not
                // true of either family: Type-2 refuses the write outright
                // unless page 3 is still blank, and a Type-5 tag reads the same
                // records back through the CC this writes. What is worth saying
                // is the part that cannot be taken back.
                warning: "This writes the Capability Container. On the chips that keep it in a write-once page there is no second attempt. Your records are left in place.",
                onTagChanged: onTagChanged
            )
        }
        .operationMoments(model)
    }
}

private struct PermanentLockOperationView: View {
    @Bindable var appModel: AppModel
    var onTagChanged: (TagObservation) -> Void = { _ in }
    @State private var model: OperationsFlowModel

    init(appModel: AppModel, onTagChanged: @escaping (TagObservation) -> Void = { _ in }) {
        self.appModel = appModel
        self.onTagChanged = onTagChanged
        _model = State(initialValue: OperationsFlowModel(
            factory: appModel.sessionFactory,
            operation: .permanentLock,
            credentials: appModel.library.tagCredentials
        ))
    }

    var body: some View {
        OperationContainer(
            title: "Permanent lock",
            intro: "Burn the static and dynamic lock bytes. Writes will fail forever after this completes. There is no undo."
        ) {
            destructiveBody(
                model: model,
                alert: "Hold tag to lock.",
                actionTitle: "Permanently lock this tag",
                warning: "This is permanent. The tag becomes read-only: for life. No password recovers it.",
                onTagChanged: onTagChanged
            )
        }
        .operationMoments(model)
    }
}

// MARK: Protect / Remove password — destructive + 4-byte hex input

//
// The standalone "Protect with password" applies REAL protection (PWD/PACK +
// AUTH0 + PROT) over the whole data area, with one simple read-protect toggle.
// Fuller control (start page, raw PACK) lives in the editor's
// `ProtectionConfigSheet`, where it can be saved into a reusable preset. The
// chip's attempt limit is not among them: it is a Dangerous Action of its own,
// because a preset is not pinned to one tag and this arms an outcome no later
// tap can undo. See `SetAttemptLimitOperationView`.

/// Three stages, and the first one is the safety property.
///
/// **Stage 1, before any tag has been seen**: what the operation does, what it
/// costs, and a button. No secret field at all. This screen used to open with a
/// Type-2 password already in it and a Continue button live, which is two
/// separate faults in one layout: a secret was committable before the app knew
/// which chip it was talking to, and the arm it built could only ever be Type-2,
/// so an NTAG424 DNA, an Ultralight C or an ICODE SLIX2 dead-ended on
/// `capabilityUnsupported` with copy that read as though the chip could not be
/// protected at all.
///
/// **Stage 2, once the identify tap has read the tag**: the chip it turned out
/// to be, the fields that chip's family actually takes, and the typed-UID gate.
/// `OperationsFlowModel.confirm()` refuses to open that gate until the fields
/// are a usable secret, so nothing can reach a tag half-answered.
///
/// **Stage 3**: the tap that writes.
private struct ProtectWithPasswordOperationView: View {
    @Bindable var appModel: AppModel
    var onTagChanged: (TagObservation) -> Void = { _ in }
    @State private var model: OperationsFlowModel
    /// The secret this run will put **on** the tag, per family. Distinct from
    /// whatever opens the tag now, which is the model's `unlockCredential` and
    /// is collected by the gate's own card.
    @State private var arm = ProtectionArm()
    /// The UID the fields were seeded for. A second identify of the same tag
    /// must not wipe what the user has typed, and a different tag must not
    /// inherit it.
    @State private var seededUID: Data?

    init(appModel: AppModel, onTagChanged: @escaping (TagObservation) -> Void = { _ in }) {
        self.appModel = appModel
        self.onTagChanged = onTagChanged
        _model = State(initialValue: OperationsFlowModel(
            factory: appModel.sessionFactory,
            // Nothing is staged until a tag has been read. See
            // `ProtectionArm.unstaged`, which is what keeps the identify tap
            // from asserting a family at a tag nothing has looked at.
            operation: .enableProtection(ProtectionArm.unstaged),
            credentials: appModel.library.tagCredentials
        ))
    }

    var body: some View {
        OperationContainer(
            title: "Protect with password",
            intro: "Lock this tag's data area so that writing to it needs a secret only you have. Lose that secret and the protected memory is gone. There is no recovery.\n\nHold the tag once and Hex NFC reads which chip it is, then asks for the kind of secret that chip takes: a 4-byte password on an NTAG21x, an Ultralight EV1 or an ICODE SLIX2, a 16-byte key on an NTAG424 DNA or an Ultralight C."
        ) {
            VStack(alignment: .leading, spacing: HexTokens.Spacing.l) {
                if case .awaitingConfirmation = model.phase, let reading = model.reading {
                    IdentifiedChipLine(name: reading.chipName)
                    armFields(for: reading.style?.family ?? .type2)
                }
                destructiveBody(
                    model: model,
                    alert: "Hold tag to protect.",
                    actionTitle: "Protect tag",
                    warning: "If you lose the password or key you set here, the protected memory on this tag can't be recovered.",
                    // The secret this run will write sits above the gate, so the
                    // first field on the screen is one of `armFields`, and it is
                    // the one that takes the keyboard.
                    claimsInitialFocus: false,
                    onTagChanged: onTagChanged
                )
            }
        }
        // Seeded from the reading, which is the only thing that says which
        // family's fields these are. `ProtectionCardSeed` is the editor card's
        // own rule and is reused rather than restated: a default that reads as
        // valid in a field nobody typed in has twice been able to re-key a live
        // tag.
        .onChange(of: model.reading) { _, reading in
            guard let reading, reading.uid != seededUID else { return }
            seededUID = reading.uid
            arm = ProtectionArm.seeded(
                family: reading.style?.family ?? .type2,
                // An unread gate counts as "may hold a credential". A SLIX2's
                // state cannot be established on a tap that is not allowed to
                // write, and a read-gated Type-2 keeps its configuration behind
                // the gate being described, so neither is a tag proven bare.
                tagReportsProtection: reading.protection?.passwordProtect ?? true
            )
            stage()
        }
        .onChange(of: arm) { _, _ in stage() }
        .operationMoments(model)
    }

    /// The fields this family actually takes.
    ///
    /// Same set, same labels and same order as `ProtectionConfigSheet`, because
    /// the two are meant to be one operation reached two ways. The read gate is
    /// offered on Type-2 and Type-4 only; `ProtectionArm.offersReadGate` says
    /// why, and `OperationsFlowModel.armable` is the backstop for a settings
    /// object that arrives carrying one anyway.
    @ViewBuilder
    private func armFields(for family: ProtectionStyle.Family) -> some View {
        switch family {
        case .type2:
            HexHexField(
                label: "Password (4 bytes)", hex: $arm.passwordHex, expectedBytes: 4,
                claimsInitialFocus: true
            )
            HexHexField(label: "PACK (2 bytes)", hex: $arm.packHex, expectedBytes: 2)
            readGate("Also require password to read")
            if arm.readProtect {
                Footnote("A read gate always covers the whole data area, from the chip's first data page.")
            }

        case .type4:
            HexHexField(
                label: "Key (16 bytes)", hex: $arm.keyHex, expectedBytes: 16,
                claimsInitialFocus: true
            )
            readGate("Also require key to read")

        case .type5:
            HexHexField(
                label: "Password (4 bytes)", hex: $arm.passwordHex, expectedBytes: 4,
                claimsInitialFocus: true
            )
            Footnote(
                "Sets the SLIX2 write password. Reads stay open. Lose the password and the protected memory can't be rewritten: there is no recovery, because a SLIX2 password can only be reset by presenting the current one."
            )

        case .ultralightC:
            HexHexField(
                label: "Key (16 bytes)", hex: $arm.keyHex, expectedBytes: 16,
                claimsInitialFocus: true
            )
            Footnote(
                "Write protection only. Hex NFC does not offer a read gate on these tags: a read-protected Ultralight C hides the pages Hex NFC identifies the chip from, so the app could no longer recognise the tag or offer to unlock it, even with the right key."
            )
        }
    }

    private func readGate(_ title: LocalizedStringKey) -> some View {
        Toggle(title, isOn: $arm.readProtect)
            .tint(HexTokens.Color.primary)
            .font(HexTokens.Font.body)
            .foregroundStyle(HexTokens.Color.textPrimary)
    }

    /// Hand the run what it is going to arm, or take it back away.
    ///
    /// Half-typed fields put the run back to `ProtectionArm.unstaged`, which is
    /// what keeps the typed-UID gate shut: the confirmation button is the only
    /// affirmative control at stage 2 and it must not go live on eight of
    /// thirty-two hex characters.
    private func stage() {
        // Keyed on the reading rather than on the phase, because the reading is
        // the thing that makes an arm legitimate: staged while the run is still
        // idle, `OperationsFlowModel.armingStyle` would assert a family on the
        // identify tap and the preamble would refuse a chip nothing had looked
        // at yet. `supplyProtection` ignores anything offered under a live
        // session, so the running phases need no guard here.
        guard let reading = model.reading else { return }
        let family = reading.style?.family ?? .type2
        model.supplyProtection(arm.pending(for: family) ?? ProtectionArm.unstaged)
    }
}

/// The mirror of the screen above, and the same three stages.
///
/// The secret this one needs is the one the tag is **holding**, which is the
/// run's `unlockCredential`, and it is collected by `OperationUnlockCard` at the
/// typed-UID gate rather than by a field of this screen's own. That is not a
/// saving of code: the card is the one consumer of the `ProtectionStyle`
/// vocabulary that decides how many bytes a family's secret is and how to
/// package them (`UnlockPrompt.swift`), shared with `ScanSheet` and `WriteSheet`
/// so the three cannot drift, and a second field here spelling the same three
/// answers out again is exactly where a fourth answer would appear.
///
/// So this screen is now as plain as Erase: intro, warning, button, and the tag
/// decides the rest.
private struct RemovePasswordOperationView: View {
    @Bindable var appModel: AppModel
    var onTagChanged: (TagObservation) -> Void = { _ in }
    @State private var model: OperationsFlowModel

    init(appModel: AppModel, onTagChanged: @escaping (TagObservation) -> Void = { _ in }) {
        self.appModel = appModel
        self.onTagChanged = onTagChanged
        _model = State(initialValue: OperationsFlowModel(
            factory: appModel.sessionFactory,
            operation: .disableProtection,
            credentials: appModel.library.tagCredentials
        ))
    }

    var body: some View {
        OperationContainer(
            title: "Remove password",
            intro: "Clear this tag's protection. The gate comes down, the secret goes back to the chip's factory default, and anyone can write the tag afterwards.\n\nHold the tag once and Hex NFC reads which chip it is, then asks for the secret it is holding now: a 4-byte password on an NTAG21x, an Ultralight EV1 or an ICODE SLIX2, a 16-byte key on an NTAG424 DNA or an Ultralight C."
        ) {
            VStack(alignment: .leading, spacing: HexTokens.Spacing.l) {
                if case .awaitingConfirmation = model.phase, let reading = model.reading {
                    IdentifiedChipLine(name: reading.chipName)
                }
                destructiveBody(
                    model: model,
                    alert: "Hold tag to remove the password.",
                    actionTitle: "Remove password",
                    warning: "After this, anyone can write this tag again.",
                    // `retry()` drops the run's credential, and the gate's card
                    // comes back empty because it seeds itself only from what
                    // the run is holding. So the plain retry cannot re-present
                    // the secret the tag just refused, and the title says what
                    // the next tap is waiting for.
                    retryTitle: "Enter a different password",
                    onTagChanged: onTagChanged
                )
            }
        }
        .operationMoments(model)
    }
}

/// What the identify tap turned out to be holding, said once at the top of
/// stage 2 so the fields below it are visibly about this tag rather than about
/// a family the screen assumed.
///
/// Silent for a chip that did not identify itself. The field labels below
/// already name the shape of secret being asked for, and a line saying the chip
/// is unknown would add a worry without adding a fact.
private struct IdentifiedChipLine: View {
    let name: String?

    var body: some View {
        if let name {
            HStack(alignment: .top, spacing: HexTokens.Spacing.s) {
                Image(systemName: "checkmark.seal")
                    .foregroundStyle(HexTokens.Color.success)
                Text("Tag identified: \(name).")
                    .font(HexTokens.Font.body)
                    .foregroundStyle(HexTokens.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier("operation.identifiedChip")
        }
    }
}

/// A secondary line under a field, at the size the rest of this sheet uses for
/// one.
private struct Footnote: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(HexTokens.Font.footnote)
            .foregroundStyle(HexTokens.Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Attempt limit: the chip's own one-way door, standalone and UID-confirmed

/// Arms `AUTH_LIM`, ACCESS bits 2-0 on an NTAG21x or Ultralight EV1.
///
/// This used to be a Stepper in the editor's Protection card, inside the
/// Advanced disclosure, next to the start page and the PACK. That put an
/// irreversible, per-tag decision onto a preset that is deliberately not pinned
/// to one chip, replayed across a whole stack of tags from the Library, and
/// carried into `.hexnfc` exports. CLAUDE.md already forbids exactly that shape
/// for a permanent lock, and this arms the same unrecoverable outcome, just
/// deferred until somebody mistypes a password.
///
/// So it sits here instead, beside the permanent lock: one tag, its UID typed
/// out in full between two taps, and a read-back before it reports success.
private struct SetAttemptLimitOperationView: View {
    @Bindable var appModel: AppModel
    var onTagChanged: (TagObservation) -> Void = { _ in }
    @State private var limit: Int = 3
    @State private var model: OperationsFlowModel?
    /// Whether a run this screen has already replaced may have had a tag.
    ///
    /// Start over builds a new flow model inside the same presentation, so the
    /// new one starts with no record of the tap before it. That tap may have
    /// armed the limit and lost the answer, and a cancel on the recovery tap
    /// must then be reported as it would have been on the old model rather than
    /// quietly handed back to the stepper. See `TagContact`.
    @State private var earlierRunMayHaveTouchedATag = false

    var body: some View {
        OperationContainer(
            title: "Attempt limit",
            // The number on this screen is AUTH_LIM as the chip holds it: the
            // value the stepper writes, the byte tap 1 reads back, and the
            // number the trace, the harness and the docs speak in. What the
            // copy says the number IS follows the datasheet and the bench, not
            // the old "stop after N": a limit of N allows N wrong tries and the
            // next one locks the password verification for good (NTAG213/215/216
            // rev 3.2 §8.8.2 and MF0ULx1 rev 3.3 §8.6.2, "as soon as this
            // internal counter reaches the number specified in AUTHLIM, any
            // further negative password verification leads to a permanent
            // locking"). Measured on NTAG213 only: tag C tolerated one wrong
            // password at a limit of 1 and then accepted the right one
            // (2026-09-14); tags A and B locked on the try past their limits
            // (2026-09-10); tag C accepted the right password at its limit and
            // survived a wrong one after it (2026-09-19). NTAG215/216 and
            // Ultralight EV1 carry the same
            // sentence and are unmeasured. The frames are in
            // `docs/internal/bench-results-2026-09.md`.
            //
            // Every consequence stated here is derived from the page gate. Once
            // the password stops opening the tag, AUTH0, ACCESS and PWD all sit
            // above AUTH0 and are therefore unwritable, so the protection cannot
            // be removed, and the pages the gate covers cannot be rewritten.
            // Both follow from the layout in `docs/internal/chip-config-pages.md`.
            //
            // What the copy does NOT say is "in a row". Both datasheets promise
            // the reset on success only "before reaching the limit", and tag B
            // measured that half (2026-09-10). Tag C at a limit of 1 then showed
            // an accepted password at the limit clearing the count (2026-09-19),
            // but that is one NTAG213 at one limit, and at a limit of 1 a reset
            // and a step back by one cannot be told apart. On an operation with
            // no undo the wrong direction to guess in is the reassuring one, and
            // "allows N wrong tries" read cumulatively understates the
            // tolerance, which is the safe direction.
            intro: "Tell this tag how many wrong tries to allow. One more wrong try after that and it stops accepting its password: the protection can never be removed and the protected memory can never be rewritten. There is no way back.\n\nThe tag has to be password-protected already, and you need the password it holds now. Hex NFC can read the limit a tag is set to. It cannot read how many tries have been used, because no command on these chips reports that.\n\nFor NTAG21x and Ultralight EV1 tags."
        ) {
            VStack(alignment: .leading, spacing: HexTokens.Spacing.l) {
                // The stepper, and nothing else, before the tag has been read.
                // The tag's password used to be collected here too, one field
                // above this one and one whole tap before anything had looked
                // at the chip. It is collected at the typed-UID gate now, by
                // the same card every other operation uses, so it sits beside
                // the `AttemptLimitReadout` that is about it: the user learns
                // how many wrong tries the tag already allows before typing the
                // password those tries will be counted against.
                Stepper(value: $limit, in: 1 ... 7) {
                    Text("Allow ^[\(limit) wrong try](inflect: true)")
                        .font(HexTokens.Font.body)
                        .foregroundStyle(HexTokens.Color.textPrimary)
                }
                .disabled(model != nil)
                if model == nil {
                    Button(action: launch) {
                        Text("Continue")
                            .font(HexTokens.Font.heading)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, HexTokens.Spacing.m)
                            .background(
                                LinearGradient(
                                    colors: [HexTokens.Color.primaryLight, HexTokens.Color.primary],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: HexTokens.Radius.m, style: .continuous))
                    }
                } else if let model {
                    // Tap 1 read the ACCESS byte to establish that the gate is
                    // armed at all, so what the tag already holds is in hand by
                    // the time the user is asked to type its UID. Saying it here
                    // is the only place in the app that reports it.
                    if case .awaitingConfirmation = model.phase {
                        AttemptLimitReadout(current: model.detectedAttemptLimit)
                    }
                    destructiveBody(
                        model: model,
                        alert: String(localized: "Hold tag to set the attempt limit."),
                        actionTitle: "Set the attempt limit",
                        warning: "Once this tag has had more wrong tries than it allows, it stops accepting its password. Nothing recovers it after that, and its protected memory stays protected for good.",
                        // The limit is frozen into the run at `launch()`, and a
                        // plain `retry()` leaves the stepper disabled behind a
                        // run that still carries the old number. Hand the whole
                        // form back instead. The password is not frozen anywhere
                        // any more: `retry()` drops it and the gate's card asks
                        // again, which matters most on this screen, because it
                        // is the one that arms the counter those tries are
                        // spent against.
                        retryTitle: "Start over",
                        onRetry: { startOver(from: model) },
                        onTagChanged: onTagChanged
                    )
                    // Scoped to the branch that owns a model: the flow model
                    // does not exist until Continue is pressed, because the
                    // limit it carries is chosen before tap 1.
                    .operationMoments(model)
                    Text(
                        "If the tag slips at the wrong moment, Hex NFC can't tell whether the limit landed. Start the operation again: the first tap reports the limit the tag is holding."
                    )
                    .font(HexTokens.Font.footnote)
                    .foregroundStyle(HexTokens.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        // A tap 1 closed before any tag hands the whole form back, stepper
        // included. The limit is frozen into the run at `launch()`, and the
        // plainest reason to back out of this sheet is to pick another number,
        // which the start state of a run that already exists would not allow.
        .onChange(of: model?.phase) { _, newValue in
            if newValue == .cancelled, let model {
                startOver(from: model)
            }
        }
    }

    /// Back to the stepper and Continue, carrying what the old run knew about
    /// the tag into the next one.
    private func startOver(from model: OperationsFlowModel) {
        earlierRunMayHaveTouchedATag = earlierRunMayHaveTouchedATag || model.mayHaveTouchedATag
        self.model = nil
    }

    private func launch() {
        // No credential here any more. The gate's own card collects it, and the
        // card asks for the password alone: `PWD_AUTH` compares the password and
        // echoes whatever PACK the tag stores, so opening the gate needs nothing
        // else, and asking for a PACK the user would have to look up would only
        // be a second thing to get wrong.
        model = OperationsFlowModel(
            factory: appModel.sessionFactory,
            operation: .setAttemptLimit(limit: limit),
            credentials: appModel.library.tagCredentials,
            earlierRunMayHaveTouchedATag: earlierRunMayHaveTouchedATag
        )
    }
}

/// What the tag already carries, stated before the UID is typed.
///
/// Three answers, and the third is why this is a view rather than a string: a
/// read-protected tag keeps its configuration pages out of reach until a password
/// is presented, so there is nothing to report. Rendering that as "no limit"
/// would be an invention, and rendering it as `0` would be the same invention
/// with a number on it.
private struct AttemptLimitReadout: View {
    let current: Int?

    var body: some View {
        HStack(alignment: .top, spacing: HexTokens.Spacing.s) {
            Image(systemName: "info.circle")
                .foregroundStyle(HexTokens.Color.textSecondary)
            Text(copy)
                .font(HexTokens.Font.footnote)
                .foregroundStyle(HexTokens.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var copy: LocalizedStringKey {
        guard let current else {
            return "This tag is read-protected, so the limit it holds now can't be read until its password is presented."
        }
        if current == 0 {
            return "This tag has no attempt limit set."
        }
        return "This tag is already set to allow ^[\(current) wrong try](inflect: true)."
    }
}

// MARK: Memory dump — no confirmation; surfaces a share sheet on success

private struct MemoryDumpOperationView: View {
    @Bindable var appModel: AppModel
    @State private var model: OperationsFlowModel
    @State private var dumpURL: URL?
    @Environment(\.dismiss) private var dismiss

    init(appModel: AppModel) {
        self.appModel = appModel
        _model = State(initialValue: OperationsFlowModel(
            factory: appModel.sessionFactory,
            operation: .memoryDump,
            credentials: appModel.library.tagCredentials
        ))
    }

    var body: some View {
        OperationContainer(
            title: "Memory dump",
            intro: "Read the tag's memory into a .bin file: including locked, password-protected and reserved pages, wherever the chip allows a read. Pages the chip refuses to decode are left out rather than attempted, because a refused read ends the session."
        ) {
            VStack(alignment: .leading, spacing: HexTokens.Spacing.l) {
                PhaseBanner(phase: model.phase, executingLabel: "Reading…")
                if case .done(.memoryDumped(let bytes)) = model.phase {
                    Text("Captured \(bytes.count) bytes.")
                        .font(HexTokens.Font.body)
                        .foregroundStyle(HexTokens.Color.textPrimary)
                    if let url = dumpURL {
                        ShareLink(item: url) {
                            Text("Share .bin")
                                .font(HexTokens.Font.heading)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, HexTokens.Spacing.m)
                                .background(
                                    LinearGradient(
                                        colors: [HexTokens.Color.primaryLight, HexTokens.Color.primary],
                                        startPoint: .top, endPoint: .bottom
                                    )
                                )
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: HexTokens.Radius.m, style: .continuous))
                        }
                    }
                }
                // Where the single tap stops on a tag that gates its reads.
                //
                // The dump walks the chip from page 0 in one `readMemory` call,
                // so the gate has to be open before that call starts and can
                // never be opened during it: a refused READ NAKs a Type-2 chip
                // and the NAK halts it for the rest of the activation, so the
                // read that discovered the gate would also end the tap. What the
                // user would see, on an operation that changes nothing, is a lost
                // tag. The preamble asks first, tears the session down, and lands
                // here so the password can be typed with no NFC sheet in the way.
                //
                // Still one tap, and deliberately no typed-UID gate: a dump reads
                // and writes nothing, and that gate is for Dangerous Actions.
                if model.phase == .needsUnlock {
                    OperationUnlockCard(model: model, continueTitle: "Unlock & dump") { credential in
                        // The button is disabled until the field parses.
                        guard let credential else { return }
                        Task { await model.unlock(with: credential) }
                    }
                }
                // A dump reads nothing but memory, so it keeps its single tap and
                // its auto-start — but it still needs a way back from a slipped
                // tag, a cancelled sheet, or a sheet that timed out empty.
                if offersTryAgain {
                    HexButton("Try again", systemImage: "arrow.clockwise", variant: .secondary) {
                        model.retry()
                        Task { await model.begin(alert: "Hold tag to dump memory.") }
                    }
                    .accessibilityIdentifier("operation.retry")
                }
            }
        }
        .task {
            if case .idle = model.phase {
                await model.begin(alert: "Hold tag to dump memory.")
            }
        }
        .onChange(of: model.phase) { _, newValue in
            if case .done(.memoryDumped(let bytes)) = newValue {
                dumpURL = persistDump(bytes)
            }
            // This screen opened the system sheet on arrival, so the place the
            // user was before it is the tile they tapped. Closed before any tag
            // was in play, the answer is to take them back there.
            if newValue == .cancelled {
                dismiss()
            }
        }
        .operationMoments(model)
    }

    private var offersTryAgain: Bool {
        switch model.phase {
        case .error, .noTagFound: true
        default: false
        }
    }

    private func persistDump(_ bytes: Data) -> URL? {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hex-nfc-dump-\(stamp).bin")
        do {
            try bytes.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}

/// Haptics for an operation screen, scoped to the transitions that mean
/// something.
///
/// This used to be a bare `.hexHero(.destructiveWarn, trigger: transitionCount)`,
/// which fired the *warning* pattern on every state change alike — and the
/// two-tap flow added three more states, so a single erase would buzz a danger
/// pattern seven times, including on success. A warning that fires constantly
/// stops reading as a warning. Now: warn once when the confirmation gate opens
/// (the moment there is something to be careful about), success on completion,
/// error on failure.
private struct OperationMoments: ViewModifier {
    let model: OperationsFlowModel

    func body(content: Content) -> some View {
        content
            .hexHero(.destructiveWarn, trigger: warn)
            .hexHero(.scanSuccess, trigger: done)
            .hexHero(.error, trigger: failed)
    }

    private var warn: Int {
        if case .awaitingConfirmation = model.phase {
            return model.transitionCount
        }
        return 0
    }

    private var done: Int {
        if case .done = model.phase {
            return model.transitionCount
        }
        return 0
    }

    private var failed: Int {
        if case .error = model.phase {
            return model.transitionCount
        }
        return 0
    }
}

private extension View {
    func operationMoments(_ model: OperationsFlowModel) -> some View {
        modifier(OperationMoments(model: model))
    }
}

// MARK: - Shared destructive body

/// The shared body for a confirming operation.
///
/// Ordering here is the safety property, not the layout. The screen opens
/// *idle*, showing what the operation does and what it costs, with an explicit
/// button to begin — these views used to fire `begin()` from `.task` the moment
/// the tile was tapped, so the system NFC sheet covered the warning before it
/// could be read. On an irreversible action the warning has to come first.
///
/// After that: tap 1 identifies, the sheet closes, the typed-UID gate appears
/// with nothing covering it, and tap 2 does the work.
@MainActor
private func destructiveBody(
    model: OperationsFlowModel,
    alert: String,
    actionTitle: LocalizedStringKey,
    warning: LocalizedStringKey,
    // What the retry button says. The default is right for the operations that
    // take no input; a screen that collected a credential says so instead,
    // because the credential is frozen into the run and a plain `retry()` would
    // present the same one again.
    retryTitle: LocalizedStringKey = "Try again",
    // What the retry button does. `nil` means `model.retry()`.
    onRetry: (@MainActor () -> Void)? = nil,
    // Whether the gate this renders owns the first input on the screen.
    //
    // False for a screen that puts its own fields above the gate, which today
    // means the Protect tile and its per-family secret. That screen focuses its
    // own first field, so neither the credential card nor the UID may claim the
    // keyboard from underneath it.
    claimsInitialFocus: Bool = true,
    // Delivered once, when the run reaches a terminal phase.
    onTagChanged: @escaping (TagObservation) -> Void = { _ in }
) -> some View {
    VStack(alignment: .leading, spacing: HexTokens.Spacing.l) {
        switch model.phase {
        // A run cancelled before any tag was in play is back where it started,
        // and looks it: nothing was read, so there is nothing to show but the
        // warning and the button again.
        case .idle, .cancelled:
            // The app never sends a credential the user did not choose without
            // saying so on the screen that sends it.
            if model.presentsFactoryDefault {
                Text(
                    "The next tap will present this tag's factory default password (FF FF FF FF) instead of the one you entered."
                )
                .font(HexTokens.Font.footnote)
                .foregroundStyle(HexTokens.Color.warning)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("operation.factoryDefaultQueued")
            }
            WarningCard(text: warning)
            HexButton(actionTitle, systemImage: "wave.3.right", variant: .primary) {
                Task { await model.begin(alert: alert) }
            }
            .accessibilityIdentifier("operation.start")
            Text("You'll hold the tag twice: once so we can read its ID, then again to make the change.")
                .font(HexTokens.Font.footnote)
                .foregroundStyle(HexTokens.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

        case .needsUnlock:
            // The credential the gate collected did not open the tag. No session
            // is open here and no task is suspended, so this card can simply be
            // walked away from; `Cancel` is the deliberate exit.
            OperationUnlockCard(model: model, continueTitle: "Unlock & continue") { credential in
                // The button is disabled until the field parses, so this is
                // never nil on this path; the closure is shared with the gate,
                // where a half-typed value has to clear the credential.
                guard let credential else { return }
                Task { await model.unlock(with: credential) }
            }
            // The same offer the error card carries, on the phase a refused
            // credential now lands on. Never automatic: if the factory default
            // is not what the tag holds it is one more wrong try.
            if model.recovery == .tryType2FactoryDefault {
                FactoryDefaultOffer { model.retryWithFactoryDefault() }
            }
            HexButton("Cancel", variant: .ghost) {
                model.cancel()
            }
            .accessibilityIdentifier("operation.cancel")

        case .noTagFound:
            // Tap 1 timed out with nothing in the field, so nothing was read and
            // nothing was written. "Try again" is tap 1 again: the warning was on
            // screen before the first attempt and comes back at the typed-UID
            // gate, which still stands between this button and any write.
            PhaseBanner(phase: model.phase)
            HexButton("Try again", systemImage: "wave.3.right", variant: .primary) {
                model.retry()
                Task { await model.begin(alert: alert) }
            }
            .accessibilityIdentifier("operation.retry")
            // A screen that owns a way back to its own form keeps it here too.
            // Set attempt limit's Start over is the only one, and a timed-out
            // tap 1 is as good a moment as any to choose another limit.
            if let onRetry {
                HexButton(retryTitle, systemImage: "arrow.clockwise", variant: .secondary) {
                    onRetry()
                }
                .accessibilityIdentifier("operation.startOver")
            }

        case .error:
            PhaseBanner(phase: model.phase)
            // A credential that went on the wire and did not open the tag names
            // one thing worth trying, and the app must not try it on its own: if
            // the factory default is not what the tag holds it is one more wrong
            // try, and on a limited tag a try is not free.
            if model.recovery == .tryType2FactoryDefault {
                FactoryDefaultOffer { model.retryWithFactoryDefault() }
            }
            // Two taps means twice the chances to cancel the system sheet or let
            // it time out, and neither is a reason to strand the screen.
            HexButton(retryTitle, systemImage: "arrow.clockwise", variant: .secondary) {
                if let onRetry {
                    onRetry()
                } else {
                    model.retry()
                }
            }
            .accessibilityIdentifier("operation.retry")

        default:
            PhaseBanner(phase: model.phase, pollingLabel: "Tap 2 of 2. Hold the same tag again.")
            // Only after a tap that actually authenticated. A removal on a tag
            // whose gate is already open sends no password at all, so without
            // `didOpenGate` this would tell the owner the factory default opened
            // a tag nothing was presented to.
            if case .done = model.phase, model.presentsFactoryDefault, model.didOpenGate {
                Text(
                    "The factory default password is what opened this tag, so an earlier removal had already gone through on it. The password you were keeping for this tag is not the one it holds."
                )
                .font(HexTokens.Font.footnote)
                .foregroundStyle(HexTokens.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("operation.factoryDefaultUsed")
            }
            if case .awaitingConfirmation(let uidHex) = model.phase {
                // The credential is collected **here**, in the window this flow
                // already has with no session open, so a confirming operation
                // never gains a tap for it. `confirm()` refuses to pass the gate
                // without one, so this field is what makes the button work
                // rather than an addition beside it.
                //
                // Shown for the whole gate, not only while the run is holding
                // nothing. It used to be conditioned on `unlockCredential ==
                // nil` as well, so the card vanished on the keystroke that
                // completed the password and there was no way back to a typo.
                // Every operation that needs a secret now collects it here, so
                // this is the only field there is to correct.
                if model.requiresUnlockCredential {
                    OperationUnlockCard(
                        model: model,
                        continueTitle: nil,
                        claimsInitialFocus: claimsInitialFocus
                    ) { credential in
                        model.supplyUnlockCredential(credential)
                    }
                }
                DestructiveConfirmationView(
                    title: actionTitle,
                    warning: warning,
                    // The whole UID, not a 4-character tail: tags from one batch can
                    // share their trailing bytes (live-confirmed on Ultralight C,
                    // 2026-08-07), which made the gate identical across a stack.
                    // See `IrreversibleOpsFlowModel.uidTail`.
                    uidTail: uidHex.replacingOccurrences(of: ":", with: ""),
                    actionTitle: actionTitle,
                    isBusy: false,
                    // The credential card above is the first input whenever it
                    // is shown, so the UID field stops raising the keyboard over
                    // it. Reported 2026-09-22: the gate opened focused on the
                    // second field on the screen.
                    focusesOnAppear: claimsInitialFocus && !model.requiresUnlockCredential,
                    onConfirm: { model.confirm() }
                )
                // The gate needs a way out that isn't the back button. Walking
                // away leaves `begin()` suspended on the confirmation
                // continuation forever; `cancel()` resolves it and returns the
                // screen to its starting state, ready to run again.
                HexButton("Cancel", variant: .ghost) {
                    model.cancel()
                }
                .accessibilityIdentifier("operation.cancel")
            }
        }
    }
    // Reported from one place rather than seven. `.error` is not optional here:
    // a partial permanent lock is *thrown*, so a `.done`-only observer would
    // never see the one outcome the card behind this sheet most needs to stop
    // being wrong about.
    .onChange(of: model.phase) { _, newValue in
        switch newValue {
        case .done, .error:
            if let observation = model.observation {
                onTagChanged(observation)
            }

        default:
            break
        }
    }
}

/// Collects the tag's credential for an operation, in the two places an
/// operation can need one.
///
/// At the typed-UID gate it is a field and nothing else: that window already
/// exists, with no NFC session open and the user's attention on it, so a
/// confirming operation collects its credential there and never gains a tap for
/// it. `OperationsFlowModel.confirm()` refuses to pass the gate without one, so
/// the field is what makes the existing button work rather than a button beside
/// it, and it fills `unlockCredential` as the user types.
///
/// On `.needsUnlock` it carries its own button, because that phase is the run
/// stopping to ask after a credential the tag refused, and the answer has to
/// restart tap 2.
///
/// The vocabulary is `ProtectionStyle`'s, shared with `ScanSheet` and
/// `WriteSheet` (see `UnlockPrompt.swift`), so the three cannot drift about how
/// many bytes a family's secret is or how to package it.
private struct OperationUnlockCard: View {
    let model: OperationsFlowModel
    /// The button's title, or `nil` at the gate, where the confirmation card's
    /// own button is what continues.
    let continueTitle: LocalizedStringKey?
    /// Whether this card holds the first input on the screen. False on a screen
    /// that renders its own fields above it.
    var claimsInitialFocus: Bool = true
    let onSupply: (TagCredential?) -> Void
    @State private var hex: String = ""

    /// What the tag reported, falling back to Type-2. The fallback is the same
    /// one `ScanSheet` makes and for the same reason: a screen with no reading
    /// still has to render a field, and 4 bytes is the shape every chip this
    /// sheet can reach except the two key families.
    private var style: ProtectionStyle {
        model.unlockStyle ?? .type2(.init())
    }

    private var credential: TagCredential? {
        guard let bytes = Data.parseHex(hex) else { return nil }
        return style.unlockCredential(from: bytes)
    }

    /// The scan sheet's wording, reused rather than re-translated. "Looks" is
    /// the honest register here: on a Type-2 tag the preamble read a gate, and
    /// on a SLIX2 it could not read one at all without putting a write on the
    /// air, so the app is part-inferring either way.
    private var promptCopy: LocalizedStringKey {
        switch style {
        case .type4:
            "This tag looks key-protected. Enter its 16-byte AES key, then hold it to the top of your iPhone again."

        case .ultralightC:
            "This tag looks key-protected. Enter its 16-byte 3DES key, then hold it to the top of your iPhone again."

        case .type2, .type5:
            "This tag looks password-protected. Enter its password, then hold it to the top of your iPhone again."
        }
    }

    private var failedCopy: LocalizedStringKey {
        style.unlockSecretIsKey
            ? "That key didn't unlock the tag. Check it and try again."
            : "That password didn't unlock the tag. Check it and try again."
    }

    private var isBadNews: Bool {
        model.unlockFailed || model.unlockRefusal?.unlockPromptCopy != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HexTokens.Spacing.m) {
            HStack(spacing: HexTokens.Spacing.s) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(HexTokens.Color.warning)
                Text("Tag is protected")
                    .font(HexTokens.Font.heading)
                    .foregroundStyle(HexTokens.Color.textPrimary)
            }
            // A refusal that read the tag's attempt limit replaces the card's
            // own words: on a tag whose AUTH_LIM is spent the chip refuses the
            // *correct* password, and "check it and try again" sends its owner
            // to doubt a password that is right and to spend another try.
            Group {
                if let refusalCopy = model.unlockRefusal?.unlockPromptCopy {
                    Text(refusalCopy)
                } else {
                    Text(model.unlockFailed ? failedCopy : promptCopy)
                }
            }
            .font(HexTokens.Font.body)
            .foregroundStyle(isBadNews ? HexTokens.Color.dangerText : HexTokens.Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            HexHexField(
                label: style.unlockSecretDescription,
                hex: $hex,
                expectedBytes: style.unlockSecretByteCount,
                claimsInitialFocus: claimsInitialFocus
            )
            if let continueTitle {
                HexButton(continueTitle, systemImage: "lock.open", variant: .primary) {
                    guard let credential else { return }
                    onSupply(credential)
                }
                .disabled(credential == nil)
                .accessibilityIdentifier("operation.unlock")
            }
        }
        // At the gate there is no button of its own, so the field is what fills
        // the credential. Supplying `nil` for a half-typed value is deliberate:
        // the gate's own button must not go live on four of eight characters.
        //
        // On appear as well as on change, and seeded from whatever the run is
        // already holding. Two things go wrong without that. A run whose
        // credential was cleared by `retry()` or `cancel()` comes back to a
        // field whose text survived the phase change, so the two disagree and
        // the gate stays shut until the identical value is retyped. And
        // `retryWithFactoryDefault()` puts the delivery password on the run
        // without anybody typing it, so an empty field there is the screen
        // disagreeing with the wire, which is bench 2026-09-09, finding 1.
        //
        // The seeding is scoped to the gate. On `.needsUnlock` the run is
        // holding the credential the tag has just refused, and filling the field
        // with it would invite the same frame a second time behind a button
        // reading "Unlock & continue": a Type-2 chip counts every refused
        // `PWD_AUTH`, and on a tag with an attempt limit those do not come back.
        .onAppear {
            guard continueTitle == nil else { return }
            if hex.isEmpty, let held = model.heldSecretHex {
                hex = held
            }
            onSupply(credential)
        }
        .onChange(of: hex) { _, _ in
            if continueTitle == nil {
                onSupply(credential)
            }
        }
        .padding(HexTokens.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HexTokens.Radius.l, style: .continuous)
                .fill(HexTokens.Color.warning.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: HexTokens.Radius.l, style: .continuous)
                .stroke(HexTokens.Color.warning.opacity(0.4), lineWidth: 1)
        )
        .accessibilityIdentifier("operation.needsCredential")
    }
}

/// The one thing worth trying after a Type-2 tag was presented a password that
/// did not open it: the value a torn removal leaves behind.
///
/// Deliberately a card with its own explanation and its own button, never an
/// automatic second attempt. If the factory default is not what the tag holds it
/// is one more wrong try, and on a tag configured with an attempt limit the try
/// past the limit locks the password for good.
///
/// The delivery value is named in the copy on purpose. It is published in the
/// chip datasheets, it is not the user's secret, and printing it lets someone
/// type it by hand, which is the escape hatch the 2026-09-04 incident's user
/// lacked.
private struct FactoryDefaultOffer: View {
    let onTry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: HexTokens.Spacing.m) {
            HStack(spacing: HexTokens.Spacing.s) {
                Image(systemName: "arrow.uturn.backward.circle")
                    .foregroundStyle(HexTokens.Color.warning)
                Text("Try the tag's factory default password")
                    .font(HexTokens.Font.heading)
                    .foregroundStyle(HexTokens.Color.textPrimary)
            }
            Text(
                "A password removal can finish on the tag and still report a failure. If that happened here, this tag is holding its factory default password (FF FF FF FF) rather than the one you entered."
            )
            .font(HexTokens.Font.body)
            .foregroundStyle(HexTokens.Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            Text(
                "If the factory default is not what this tag holds, this counts as a wrong try. A tag set with an attempt limit allows only so many, and one more after that stops it accepting its password for good."
            )
            .font(HexTokens.Font.footnote)
            .foregroundStyle(HexTokens.Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            HexButton("Try the factory default", systemImage: "key", variant: .secondary, action: onTry)
                .accessibilityIdentifier("operation.tryFactoryDefault")
        }
        .padding(HexTokens.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HexTokens.Radius.l, style: .continuous)
                .fill(HexTokens.Color.warning.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: HexTokens.Radius.l, style: .continuous)
                .stroke(HexTokens.Color.warning.opacity(0.4), lineWidth: 1)
        )
        .accessibilityIdentifier("operation.factoryDefaultOffer")
    }
}

/// The cost of the operation, stated before anything opens an NFC session.
private struct WarningCard: View {
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: HexTokens.Spacing.m) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(HexTokens.Color.dangerText)
            Text(text)
                .font(HexTokens.Font.body)
                .foregroundStyle(HexTokens.Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(HexTokens.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HexTokens.Radius.l, style: .continuous)
                .fill(HexTokens.Color.danger.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: HexTokens.Radius.l, style: .continuous)
                .stroke(HexTokens.Color.danger.opacity(0.4), lineWidth: 1)
        )
    }
}

// MARK: - Hex-byte input field

struct HexHexField: View {
    let label: LocalizedStringKey
    @Binding var hex: String
    let expectedBytes: Int
    /// Whether this field raises the keyboard when it appears.
    ///
    /// Default off, because most screens carry several of these and the answer
    /// to "which one" belongs to the screen rather than to the field. Exactly
    /// one field per screen should say yes, and it should be the first one
    /// visible.
    var claimsInitialFocus: Bool = false

    @FocusState private var focused: Bool
    /// Keyboard focus and VoiceOver focus are separate cursors. Raising the
    /// keyboard drags the reader into the field, past whatever the screen was
    /// trying to say first, so under VoiceOver this claims nothing and the user
    /// swipes to the field in reading order. Same rule as
    /// `DestructiveConfirmationView`.
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: HexTokens.Spacing.xs) {
            Text(label)
                .font(HexTokens.Font.footnote)
                .foregroundStyle(HexTokens.Color.textSecondary)
                // The field below now announces this same text as its own name,
                // so leaving this element visible to VoiceOver said it twice.
                .accessibilityHidden(true)
            TextField("", text: $hex)
                .focused($focused)
                .font(HexTokens.Font.mono)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled(true)
                .padding(.horizontal, HexTokens.Spacing.m)
                .padding(.vertical, HexTokens.Spacing.s)
                .background(
                    RoundedRectangle(cornerRadius: HexTokens.Radius.s, style: .continuous)
                        .fill(HexTokens.Color.surface1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: HexTokens.Radius.s, style: .continuous)
                        .stroke(borderColor, lineWidth: 1)
                )
                // The `TextField("", …)` has no name of its own, so every call
                // site (passwords, PACKs, AES keys) reached VoiceOver as an
                // unnamed text field. `label` is the visible name; say it here.
                .accessibilityLabel(Text(label))
                // Value, not hint: a hint is suppressible in VoiceOver's
                // settings, and whether a key parsed to the right length is not
                // optional information. The verdict was carried by
                // `borderColor` alone, which a VoiceOver user never sees.
                .accessibilityValue(spokenValue)
            Text(footnoteText)
                .font(HexTokens.Font.footnote)
                .foregroundStyle(HexTokens.Color.textSecondary)
                // Same verdict as the field's value now carries. Still on
                // screen, hidden from VoiceOver so it is not read a second time.
                .accessibilityHidden(true)
        }
        .onAppear {
            if claimsInitialFocus, !voiceOverEnabled {
                focused = true
            }
        }
    }

    /// Spoken value: the hex typed so far, then the parse verdict.
    ///
    /// The hex is spelled character by character because VoiceOver otherwise
    /// pronounces a pair like "AB" as a word, which is useless for checking a
    /// password or an AES key byte by byte. `speechSpellsOutCharacters()` is
    /// applied to that run *before* the concatenation, so it does not spread to
    /// the verdict after it and turn "OK" into "O, K".
    private var spokenValue: Text {
        let verdict = Text(footnoteText)
        guard !hex.isEmpty else { return verdict }
        return Text(verbatim: hex).speechSpellsOutCharacters()
            + Text(verbatim: ", ")
            + verdict
    }

    private var borderColor: Color {
        guard let parsed = Data.parseHex(hex) else { return HexTokens.Color.warning }
        return parsed.count == expectedBytes ? HexTokens.Color.success : HexTokens.Color.warning
    }

    private var footnoteText: LocalizedStringKey {
        if let parsed = Data.parseHex(hex), parsed.count == expectedBytes {
            return "OK"
        }
        return "Enter \(expectedBytes) bytes as hex (with or without `:` separators)."
    }
}

#endif
