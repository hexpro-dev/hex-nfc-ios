#if os(iOS)
import HexNFCDesign
import HexNFCKit
import HexNFCRecords
import HexNFCShaders
import SwiftUI

/// The editor that hosts the record list between scan and write. Owns its
/// `EditFlowModel`, presents `AddRecordSheet` for adding new records, and
/// `RecordEditorSheet` for editing existing ones, and `WriteSheet` for the
/// write-back loop.
struct TagEditorSheet: View {
    @Bindable var editModel: EditFlowModel
    let appModel: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var editing: NDEFRecord?
    /// A record the editor sheet asked to delete, removed from the list only
    /// after that sheet has finished dismissing.
    @State private var pendingDeletion: UUID?
    @State private var showingAdd = false
    /// The live write flow, owned here rather than built inside the sheet's
    /// content closure.
    ///
    /// The closure is re-invoked on every parent body evaluation, and a fresh
    /// `WriteFlowModel` per evaluation swaps the object under a `WriteSheet`
    /// whose `.task` has already fired: the new instance sits in `.ready`
    /// forever, `confirm()` and `reset()` reach the wrong one, and the running
    /// `begin()` is left suspended on a continuation nothing can resume. That
    /// was survivable while a write was one unattended second. It is not, now
    /// that the UID gate parks the flow for as long as the user takes to type.
    /// `RootView` and `OperationsSheet` already own their flow models this way.
    @State private var activeWriteModel: WriteFlowModel?
    @State private var showingOperations = false
    @State private var showingSavePreset = false
    @State private var showingProtection = false
    /// A reading delivered while a sheet was covering the editor.
    ///
    /// Applied when that sheet goes away rather than as it arrives. The row is
    /// behind `OperationsSheet` and `WriteSheet` at the moment the reading
    /// lands, so animating it there would change a card nobody can see and fire
    /// a haptic on top of the operation's own success haptic.
    @State private var pendingObservation: TagObservation?
    /// The arm the last write proved, held with the reading it came back with
    /// and applied only together with it. Dropped by anything that makes that
    /// reading stale: an Operations reading, or the Operations sheet opening.
    @State private var pendingArm: ProvenArm?
    /// The write most recently started, which is the only one whose hand-back
    /// may still record anything. `activeWriteModel` goes nil on a swipe
    /// dismissal, so it cannot tell a late hand-back from a superseded one.
    @State private var lastStartedWrite: WriteFlowModel?
    /// Bumped each time the Operations sheet opens, and captured when a write
    /// starts. A write's proof may be taken only if Operations has not opened
    /// since: Operations can re-key the tag and report nothing, and a late
    /// hand-back would otherwise bring back the proof its opening dropped.
    @State private var operationsEpoch = 0
    @State private var epochAtWriteStart = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            content
                .background(HexTokens.Color.surface0.ignoresSafeArea())
                .navigationTitle(Text("Tag"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close") { dismiss() }
                            .foregroundStyle(HexTokens.Color.textSecondary)
                            .hexPressHaptic()
                    }
                    // Menu and Write are distinct controls; the gap + hairline
                    // divider keep them from reading as one fused button while
                    // staying in the same top-trailing position.
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: HexTokens.Spacing.s) {
                            Menu {
                                Button {
                                    HexHeroMoment.tap.play()
                                    showingSavePreset = true
                                } label: {
                                    Label("Save as preset…", systemImage: "tray.and.arrow.down")
                                }
                                // Savable with records *or* a protection-only
                                // configuration (a preset that just locks tags).
                                .disabled(editModel.records.isEmpty && !editModel.protection.passwordProtect)
                                Button {
                                    HexHeroMoment.tap.play()
                                    showingOperations = true
                                } label: {
                                    Label("Operations…", systemImage: "wrench.and.screwdriver")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .foregroundStyle(HexTokens.Color.textSecondary)
                            }
                            .accessibilityIdentifier("editor.menu")

                            Rectangle()
                                .fill(HexTokens.Color.textSecondary.opacity(0.35))
                                .frame(width: 1, height: 18)
                                .accessibilityHidden(true)

                            // Offered only when a press would change something,
                            // by the rule on `EditFlowModel.isWriteOffered`, which
                            // is where it is tested. It used to be enabled for any
                            // non-empty record list, so an unedited scan wrote the
                            // tag's own state back onto it (2026-09-25).
                            Button("Write") { startWrite() }
                                // A tint, not a foreground style. `.disabled`
                                // only withdraws the tap and leaves the look to
                                // the button style, which greys a tint but cannot
                                // grey a fixed colour: this button stayed full
                                // blue while refusing every tap (2026-09-25).
                                .tint(HexTokens.Color.primaryLight)
                                .hexPressHaptic()
                                .disabled(!editModel.isWriteOffered)
                                .accessibilityIdentifier("editor.write")
                        }
                    }
                }
                .toolbarBackground(HexTokens.Color.surface0, for: .navigationBar)
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showingAdd) {
            AddRecordSheet { newRecord in
                editModel.append(newRecord)
                HexHeroMoment.commit.play()
                showingAdd = false
                editing = newRecord
            }
        }
        .sheet(item: $editing, onDismiss: deletePendingRecord) { record in
            RecordEditorSheet(initial: record) { updated in
                if let updated {
                    editModel.replace(updated)
                }
                editing = nil
            } onDelete: {
                pendingDeletion = record.id
                editing = nil
            }
        }
        .sheet(item: $activeWriteModel) { model in
            WriteSheet(
                model: model,
                onSuccess: { observation in
                    // The hand-back can come after the sheet was swiped away
                    // and another write started, so it closes and cleans only
                    // on behalf of its own write. The reading is about the
                    // tag, and `apply` discards one about a different tag.
                    let isCurrent = model === lastStartedWrite
                    if isCurrent {
                        // What this write carried, not what the editor holds
                        // now: an edit made while the hand-back was in flight
                        // was never written.
                        editModel.noteWritten(model.dataArea, to: model.writtenUID)
                    }
                    // Merged, never replaced, for the reason the Operations
                    // hand-back below gives. Assigning outright also dropped a
                    // pending reading whenever the write read nothing back.
                    if let observation, editModel.isAboutThisTag(observation.uid) {
                        pendingObservation = pendingObservation?.merging(observation) ?? observation
                        let proofStillHolds = isCurrent && !showingOperations
                            && epochAtWriteStart == operationsEpoch
                        pendingArm = proofStillHolds ? model.provenArm : nil
                    }
                    if activeWriteModel === model {
                        activeWriteModel = nil
                    }
                }
            )
        }
        .sheet(isPresented: $showingOperations) {
            OperationsSheet(appModel: appModel) { observation in
                // Merged, never replaced. Operations is a `NavigationStack` of
                // tiles, so running two operations without leaving the sheet is
                // the ordinary way to use it, and one tap only ever establishes
                // one kind of fact. Assigning outright meant a permanent lock
                // followed by a password removal (the sequence the locked card's
                // own copy invites) arrived carrying no lock at all.
                //
                // And only readings about this editor's tag: a merge across two
                // tags keeps the later one, which lost this tag's reading.
                guard editModel.isAboutThisTag(observation.uid) else { return }
                pendingObservation = pendingObservation?.merging(observation) ?? observation
                // A later reading than any write's, carrying no arm of ours.
                pendingArm = nil
            }
        }
        // Drained whenever nothing is covering the row, so the change is
        // animated where it can be seen and its haptic does not land on top of
        // the operation's own. The `pendingObservation` hook is what catches a
        // reading that arrives *after* its sheet has gone: `WriteSheet` reports
        // once the system NFC sheet has cleared, from a task that outlives a
        // swipe dismissal.
        .onChange(of: showingOperations) { _, showing in
            // On opening, from either entry point. Operations can re-key or
            // remove this tag's password and report nothing when its read-back
            // fails, so waiting for a reading to clear the proof is not enough.
            if showing {
                operationsEpoch += 1
                editModel.forgetProvenArm()
                pendingArm = nil
            }
            applyPendingObservation()
        }
        // Keyed on presence, not on the model: a flow model is a reference type
        // with no equality, and what this hook waits for is the sheet going away.
        .onChange(of: activeWriteModel == nil) { _, _ in applyPendingObservation() }
        .onChange(of: pendingObservation) { _, _ in applyPendingObservation() }
        .sheet(isPresented: $showingSavePreset) {
            SavePresetSheet(
                records: editModel.records,
                protection: editModel.protection,
                credential: editModel.protectionCredential,
                library: appModel.library,
                onSaved: { showingSavePreset = false }
            )
        }
        // Fired from the editor's root rather than from the row, and never from
        // under a sheet. The row itself can be *inserted* by the same change
        // that bumps the counter (`showsProtection` turns true for a chip with
        // no password backend the moment a lock verdict lands), and a modifier
        // inserted on that frame never sees its own `onChange`.
        .hexHero(.writeLockIn, trigger: editModel.lockMomentCount)
        .hexHero(.commit, trigger: editModel.protectionMomentCount)
        .sheet(isPresented: $showingProtection) {
            ProtectionConfigSheet(editModel: editModel)
        }
    }

    /// Show the protection affordance when the target can take it: a blank build
    /// (unknown target — the write validates) or a scanned chip that supports it.
    private var showsProtection: Bool {
        // A lock verdict brings the row back for a chip with no password
        // backend at all. NTAG 210u locks perfectly well and has no password
        // block (`type2ConfigLayout` is nil for it by design), so
        // `supportsPasswordProtection` alone would compute a verdict for it and
        // then hide it.
        editModel.tag == nil
            || editModel.tag?.supportsPasswordProtection == true
            || isLockClaimed
    }

    /// `true` when a reading says at least one lock bit is, or is very likely,
    /// burned. `.open` and `.unknown` are both false: one is a fact and the
    /// other is an absence of one, and neither is a claim about a lock.
    private var isLockClaimed: Bool {
        switch editModel.lockState {
        case .locked, .partlyLocked, .writtenNotWitnessed: true
        case .unknown, .open: false
        }
    }

    /// Apply a reading that arrived while a sheet was covering the editor.
    ///
    /// `apply` discards a reading about a different tag, so this is safe to call
    /// after any operation, including one the user pointed at some other tag.
    /// Build the write flow at the moment the user presses Write, which is the
    /// moment they consented to it, and hold it until the sheet closes.
    private func startWrite() {
        // Decided on the model, where it is tested, including the pin that
        // keeps a write whose arm was held back on the tag that already has it.
        let request = editModel.prepareWrite()
        let model = WriteFlowModel(
            factory: appModel.sessionFactory,
            dataArea: request.dataArea,
            credentials: appModel.library.tagCredentials,
            protection: request.protection,
            // If the user holds the credential (just configured it, or it
            // matches the existing lock), the write authenticates in one
            // tap; otherwise the write flow prompts via `.needsUnlock`.
            unlockCredential: editModel.protectionCredential,
            // Toggling protection off on a tag that had it removes the
            // lock after writing (authenticating first).
            removeProtection: request.removeProtection,
            // This route arms and removes protection on a tag the user scanned,
            // so it confirms which tag before it changes one (bench finding 19).
            uidConfirmation: .required,
            // And the tag it confirms against is the one this editor is about,
            // when it knows one. Without it the gate would only ask the user to
            // confirm the identity of whatever they are holding.
            targetUID: editModel.targetUID,
            pinnedUID: request.pinnedUID
        )
        lastStartedWrite = model
        epochAtWriteStart = operationsEpoch
        activeWriteModel = model
    }

    private func applyPendingObservation() {
        guard !showingOperations, activeWriteModel == nil, let observation = pendingObservation else { return }
        pendingObservation = nil
        let arm = pendingArm
        pendingArm = nil
        withAnimation(reduceMotion ? nil : HexTokens.Motion.lush) {
            _ = editModel.apply(observation, provenArm: arm)
        }
    }

    private var protectionSummary: LocalizedStringKey {
        // The lock is checked first, because it is the stronger fact and the
        // irreversible one: a tag can be both locked and password-protected, and
        // of the two only the lock can never be undone.
        //
        // `originalProtection`, not `protection`. The first is the baseline a
        // read-back rebases; the second is what the user has staged in the
        // Protection card and has not written yet. Reading the intent here would
        // let a tag that has never had a password report one, and let a tag that
        // has one report none, on the strength of a toggle.
        switch editModel.lockState {
        case .locked:
            // The password machinery survives a permanent lock: `lockBitMask`
            // sets lock and block-lock bits only, so AUTH0, ACCESS, PWD and PACK
            // stay writable. Saying "Permanently locked" alone would hide a
            // credential the user may still need to be rid of.
            return editModel.originalProtection.passwordProtect
                ? "Permanently locked · password still set"
                : "Permanently locked"

        case .partlyLocked:
            return editModel.originalProtection.passwordProtect
                ? "Partly locked · password still set"
                : "Partly locked · some of this tag is read-only for good"

        case .writtenNotWitnessed:
            return "Lock written · scan again to confirm"

        case .unknown, .open:
            break
        }
        // "We could not read it" is a third answer, and it used to be filed
        // under "Off". Only claim Off when the scan actually established it.
        if !editModel.protection.passwordProtect, editModel.protectionIsUnknown {
            return "Unknown · couldn't read this tag's protection"
        }
        guard editModel.protection.passwordProtect else { return "Off" }
        let readProtected = editModel.protection.effectiveReadProtect
        // Per-style rather than a binary "is it a key": two families now use a
        // 16-byte key and they are different ciphers, so "AES key" on an
        // Ultralight C would be actively wrong. The user has to know which
        // secret this tag wants back.
        switch editModel.protection.effectiveStyle {
        case .type4:
            return readProtected ? "AES key · read + write" : "AES key · write-only"

        case .ultralightC:
            return readProtected ? "3DES key · read + write" : "3DES key · write-only"

        case .type2, .type5:
            return readProtected ? "Password · read + write" : "Password · write-only"
        }
    }

    /// An open padlock states a fact. Use the question mark when we haven't got
    /// one, so the icon and the summary agree.
    private var protectionIcon: String {
        switch editModel.lockState {
        case .locked: return "lock.shield.fill"
        case .partlyLocked, .writtenNotWitnessed: return "lock.shield"
        case .unknown, .open: break
        }
        if editModel.protection.passwordProtect {
            return "lock.fill"
        }
        return editModel.protectionIsUnknown ? "lock.questionmark" : "lock.open"
    }

    /// The sentence under "Permanently locked".
    ///
    /// The password half is offered only when there is a password to remove
    /// *and* Operations is the place that can remove it. Its "Remove password"
    /// screen is the Type-2 4-byte PWD path and says so; a key-based family
    /// (NTAG424 DNA, Ultralight C, ICODE SLIX2) is removed from this very card,
    /// which a locked tag no longer opens. Promising that route on an Ultralight
    /// C would send the user somewhere that cannot help them.
    private var lockedDetail: LocalizedStringKey {
        guard editModel.originalProtection.passwordProtect,
              case .type2 = editModel.originalProtection.effectiveStyle
        else {
            return "Records and formatting can no longer be written."
        }
        return "Records and formatting can no longer be written. A password can still be removed under Operations."
    }

    /// Warning-tinted whenever the row states something the user cannot simply
    /// undo by tapping it: a password, or a lock.
    private var protectionTint: Color {
        editModel.protection.passwordProtect || isLockClaimed
            ? HexTokens.Color.warning
            : HexTokens.Color.textSecondary
    }

    /// The row's contents, shared by the tappable and the informational shapes so
    /// the two cannot drift apart.
    private func protectionRow(showsChevron: Bool) -> some View {
        HStack(spacing: HexTokens.Spacing.m) {
            Image(systemName: protectionIcon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(protectionTint)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 2) {
                Text("Protection")
                    .font(HexTokens.Font.heading)
                    .foregroundStyle(HexTokens.Color.textPrimary)
                Text(protectionSummary)
                    .font(HexTokens.Font.footnote)
                    .foregroundStyle(HexTokens.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Scoped to what the reading actually covers. A permanent lock
                // sets lock and block-lock bits; it does not touch the password
                // block. "Nothing can be changed" would be a falsehood shipped
                // about the one operation with no undo.
                if editModel.lockState == .locked {
                    Text(lockedDetail)
                        .font(HexTokens.Font.footnote)
                        .foregroundStyle(HexTokens.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(HexTokens.Color.textSecondary)
            }
        }
        .padding(HexTokens.Spacing.l)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: HexTokens.Radius.l, style: .continuous)
                .fill(HexTokens.Color.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HexTokens.Radius.l, style: .continuous)
                .stroke(HexTokens.Stroke.cardInner, lineWidth: HexTokens.Stroke.cardInnerWidth)
        )
    }

    @ViewBuilder
    private var protectionSection: some View {
        if showsProtection {
            Group {
                if editModel.lockState == .locked {
                    // Informational, not a disabled `Button`. `HexPressStyle`
                    // never consults `@Environment(\.isEnabled)`, so
                    // `.disabled(true)` would render at full opacity with its
                    // chevron intact and simply stop responding: a card that
                    // still looks tappable and does nothing, which is worse than
                    // the thing being fixed. There is also nothing behind it,
                    // because every control the Protection card offers applies
                    // itself through a write, and a locked tag refuses writes.
                    protectionRow(showsChevron: false)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("editor.protection.locked")
                } else {
                    Button {
                        HexHeroMoment.tap.play()
                        showingProtection = true
                    } label: {
                        protectionRow(showsChevron: true)
                    }
                    .hexPressStyle()
                    .accessibilityIdentifier("editor.protection")
                }
            }
        }
    }

    /// Names the fault, so the detail below can name the repair.
    private var unformattedTitle: LocalizedStringKey {
        editModel.tag?.formatState == .unreadableDataArea
            ? "This tag's data won't read"
            : "This tag isn't formatted"
    }

    /// Names the repair, and only a repair this state can actually take.
    private var unformattedDetail: LocalizedStringKey {
        editModel.tag?.formatState == .unreadableDataArea
            ? "This tag already has a Capability Container, so formatting won't help. Erase it to rewrite the data area."
            : "It has no Capability Container, so records written now won't be readable. Format it first."
    }

    /// Shown when no reader could find an NDEF message on the scanned tag. The
    /// write would otherwise appear to work and then fail its verify read, on a
    /// tag that only needed a repair, so the repair is offered here rather than
    /// left for the user to find under Operations.
    ///
    /// Two faults land here and they take opposite repairs. A tag with no
    /// Capability Container needs a format. A tag whose Capability Container is
    /// present and whose data area still will not read needs that data area
    /// rewritten, and a format on it writes nothing at all. Both routes open
    /// Operations; the copy is what says which tile to tap.
    @ViewBuilder
    private var unformattedNotice: some View {
        // Gated on the lock as well: both repairs are writes, and a permanently
        // locked tag refuses them. Offering one would send the user to an
        // operation that cannot succeed.
        if editModel.tag?.formatState.needsAttention == true, !editModel.isWriteBlocked {
            Button {
                HexHeroMoment.tap.play()
                showingOperations = true
            } label: {
                HStack(alignment: .top, spacing: HexTokens.Spacing.m) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(HexTokens.Color.warning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(unformattedTitle)
                            .font(HexTokens.Font.heading)
                            .foregroundStyle(HexTokens.Color.textPrimary)
                        Text(unformattedDetail)
                            .font(HexTokens.Font.footnote)
                            .foregroundStyle(HexTokens.Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(HexTokens.Color.textSecondary)
                }
                .padding(HexTokens.Spacing.l)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: HexTokens.Radius.l, style: .continuous)
                        .fill(HexTokens.Color.warning.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: HexTokens.Radius.l, style: .continuous)
                        .stroke(HexTokens.Color.warning.opacity(0.4), lineWidth: 1)
                )
            }
            .hexPressStyle()
            .accessibilityIdentifier("editor.unformatted")
        }
    }

    @ViewBuilder
    private var content: some View {
        if editModel.records.isEmpty {
            emptyState
        } else {
            recordList
        }
    }

    private var emptyState: some View {
        // `isDirty` while empty means the user deleted every record off a tag
        // that had some — the removal isn't on the tag until they Write, so we
        // surface that as the primary action. A genuinely blank build (not
        // dirty) keeps the original "add one to get started" framing.
        let clearedTag = editModel.isDirty
        return VStack(spacing: HexTokens.Spacing.l) {
            tagInfoCard
            unformattedNotice
            protectionSection
            Spacer(minLength: 0)
            Image(systemName: "tray")
                .font(.system(size: 56))
                .foregroundStyle(HexTokens.Color.textSecondary.opacity(0.6))
            Text(clearedTag ? "No records left" : "Empty tag")
                .font(HexTokens.Font.title)
                .foregroundStyle(HexTokens.Color.textPrimary)
            Text(clearedTag
                ? "You've removed every record. Write to clear the tag, or add one back."
                : "Add a record to get started.")
                .font(HexTokens.Font.body)
                .foregroundStyle(HexTokens.Color.textSecondary)
                .multilineTextAlignment(.center)
            VStack(spacing: HexTokens.Spacing.m) {
                // The toolbar's rule, not a copy of it, so the two cannot
                // disagree about whether there is anything to write.
                if clearedTag, editModel.isWriteOffered {
                    HexButton("Write to clear tag", systemImage: "square.and.arrow.up", variant: .primary) {
                        startWrite()
                    }
                    .accessibilityIdentifier("editor.write.clear")
                }
                HexButton("Add record", systemImage: "plus", variant: clearedTag ? .secondary : .primary) {
                    showingAdd = true
                }
            }
            .padding(.horizontal, HexTokens.Spacing.xxl)
            Spacer(minLength: 0)
        }
        .padding(HexTokens.Spacing.xl)
    }

    /// Meta card describing the scanned tag — chip model, maker, memory,
    /// supported operations, UID. Shared with the transit result view via
    /// `TagInfoCard`; renders nothing when there's no scanned tag.
    private var tagInfoCard: some View {
        TagInfoCard(tag: editModel.tag)
    }

    private var recordList: some View {
        // A `List` (not a `ScrollView`) is what makes `.swipeActions` and
        // `.onMove` live — both are no-ops outside a List. The header cards and
        // the add button ride as clear-background, separator-less rows so the
        // whole thing still scrolls and reads as the old card stack.
        List {
            Group {
                tagInfoCard
                unformattedNotice
                protectionSection
            }
            .listRowInsets(Self.cardRowInsets)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            ForEach(editModel.records) { record in
                Button {
                    editing = record
                } label: {
                    HexRecordRow(
                        title: LocalizedStringKey(RecordLocalization.title(for: record)),
                        subtitle: RecordLocalization.subtitle(for: record),
                        systemImage: RecordLocalization.icon(for: record)
                    )
                }
                .hexPressStyle()
                .listRowInsets(Self.cardRowInsets)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("editor.row.\(record.typeKey)")
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(RecordLocalization.title(for: record)))
                .accessibilityValue(Text(RecordLocalization.subtitle(for: record)))
                .accessibilityHint(Text("Double-tap to edit. Swipe left to delete. Drag to reorder."))
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        delete(record)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .onMove(perform: moveRecords)

            HexButton("Add record", systemImage: "plus", variant: .secondary) {
                showingAdd = true
            }
            .listRowInsets(Self.addRowInsets)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .accessibilityIdentifier("editor.add")
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(HexTokens.Color.surface0)
        .environment(\.defaultMinListRowHeight, 0)
        .accessibilityRotor("URLs") {
            ForEach(editModel.records) { record in
                if case .uri = record {
                    AccessibilityRotorEntry(RecordLocalization.subtitle(for: record), id: record.id)
                }
            }
        }
        .accessibilityRotor("Contacts") {
            ForEach(editModel.records) { record in
                if case .contact = record {
                    AccessibilityRotorEntry(RecordLocalization.subtitle(for: record), id: record.id)
                }
            }
        }
        .accessibilityRotor("Wi-Fi") {
            ForEach(editModel.records) { record in
                if case .wifiWPS = record {
                    AccessibilityRotorEntry(RecordLocalization.subtitle(for: record), id: record.id)
                }
            }
        }
    }

    // Row insets that reproduce the editor's old card rhythm inside a plain
    // List: `Spacing.l` side gutters with a half-`Spacing.s` gap above and below
    // each card, so adjacent cards sit `Spacing.s` apart like the old VStack.
    private static let cardRowInsets = EdgeInsets(
        top: HexTokens.Spacing.s / 2, leading: HexTokens.Spacing.l,
        bottom: HexTokens.Spacing.s / 2, trailing: HexTokens.Spacing.l
    )
    private static let addRowInsets = EdgeInsets(
        top: HexTokens.Spacing.s, leading: HexTokens.Spacing.l,
        bottom: HexTokens.Spacing.l, trailing: HexTokens.Spacing.l
    )

    /// Remove a record from the in-flight list. The physical tag is untouched
    /// until the next Write — this only edits the editor's working copy, so it
    /// needs no UID confirmation and stays undoable via the dirty bit.
    private func delete(_ record: NDEFRecord) {
        delete(id: record.id)
    }

    /// Deleted only once the record editor has gone. Removing the row and
    /// dismissing in the same update crashed on the last record (2026-09-27):
    /// the removal also swaps the list for the empty state, and
    /// UICollectionView was asked to animate a deletion from a list being torn
    /// down while the sheet's transition ran, which fails its item-count check
    /// and aborts.
    private func deletePendingRecord() {
        guard let id = pendingDeletion else { return }
        pendingDeletion = nil
        delete(id: id)
    }

    private func delete(id: UUID) {
        HexHeroMoment.destructiveWarn.play()
        withAnimation(HexTokens.Motion.snappy) {
            editModel.remove(id: id)
        }
    }

    private func moveRecords(from source: IndexSet, to destination: Int) {
        editModel.move(from: source, to: destination)
        HexHeroMoment.dragSnap.play()
    }
}
#endif
