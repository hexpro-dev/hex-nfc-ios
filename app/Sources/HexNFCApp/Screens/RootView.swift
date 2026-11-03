#if os(iOS)
import HexNFCDesign
import HexNFCKit
import HexNFCRecords
import HexNFCShaders
import HexNFCStorage
import StoreKit
import SwiftUI

/// Top-level mount. The Xcode app target's `ContentView` calls into this.
/// One `NavigationStack` for the whole app + sheet presentations for the
/// scan / edit / write loop (per the plan — no per-tab stacks).
public struct RootView: View {
    @Bindable private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var showingScan = false
    @State private var showingBuild = false
    @State private var showingLibrary = false
    @State private var showingAdvanced = false
    @State private var showingSettings = false
    @State private var activeEditModel: EditFlowModel?
    @State private var activeWriteModel: WriteFlowModel?
    @State private var activeTransitCard: TransitCard?
    @State private var activeTransitTagInfo: ScannedTagInfo?
    @State private var activePassportData: PassportData?
    @State private var activePassportTagInfo: ScannedTagInfo?
    @State private var activeHealthDevice: HealthDeviceScan?
    @State private var activeHealthDeviceTagInfo: ScannedTagInfo?
    @State private var costs: DonationProgress = .fallback
    @State private var showingFeedback = false
    /// The "Loving Hex NFC?" card, when it is up. See `proposeReviewWhenIdle`.
    @State private var reviewCard: ReviewPromptCard.Stage?
    @State private var idleClock = IdleClock()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestReview) private var requestReview
    #if DEBUG
    @State private var showingHarness = false
    #endif

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        rootContent
            .hexReduceMotion(systemReduceMotion || model.settings.reduceMotionOverride)
    }

    @ViewBuilder
    private var rootContent: some View {
        NavigationStack {
            HomeView(
                costs: costs,
                onScan: { showingScan = true },
                onBuild: { startBuild() },
                onLibrary: { showingLibrary = true },
                onAdvanced: { showingAdvanced = true },
                onSettings: { showingSettings = true }
            )
            .safeAreaInset(edge: .bottom, spacing: 0) {
                reviewCardInset
            }
            .background(HexTokens.Color.surface0.ignoresSafeArea())
            .toolbarBackground(.hidden, for: .navigationBar)
            #if DEBUG
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingHarness = true } label: {
                        Image(systemName: "flask")
                    }
                    .tint(HexTokens.Color.textSecondary)
                    .accessibilityLabel("Live chip test")
                }
            }
            #endif
        }
        .tint(HexTokens.Color.primaryLight)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingScan) {
            // Inputs, not a model: this closure re-runs on every re-evaluation
            // of `rootContent`, so a `ScanFlowModel` built here would be swapped
            // in mid-scan and the live session left orphaned on the old one.
            // `ScanSheet` owns the model in `@State`; see its declaration.
            ScanSheet(
                factory: model.sessionFactory,
                library: model.library,
                activity: model.reviewPrompt,
                onComplete: { records, tagInfo, transitCard, passportData, healthDevice, protection, protectionIsUnknown in
                    showingScan = false
                    if let healthDevice {
                        // Health devices are identified, never read or written,
                        // and never persisted: a read-only result that points at
                        // an app which can read them, and no record editor.
                        activeHealthDeviceTagInfo = tagInfo
                        activeHealthDevice = healthDevice
                    } else if let passportData {
                        // Passports are read-only and never persisted — show the
                        // session-only result view, skipping the record editor.
                        activePassportTagInfo = tagInfo
                        activePassportData = passportData
                    } else if let transitCard {
                        // Transit cards are read-only — skip the record editor.
                        activeTransitTagInfo = tagInfo
                        activeTransitCard = transitCard
                    } else {
                        // Seed the editor with the tag's detected protection so a
                        // tag locked elsewhere reads as protected, not "Off". No
                        // secret is carried — `pendingProtection()` stays nil until
                        // the user enters a password, so the write won't re-apply.
                        //
                        // `protectionIsUnknown` keeps the third case out of the
                        // other two: `.none` here is the seed the editor has to
                        // start from either way, but when the read was refused it
                        // is a placeholder, not a finding, and the card says so.
                        activeEditModel = EditFlowModel(
                            records: records,
                            tag: tagInfo,
                            protection: protection ?? .none,
                            protectionIsUnknown: protectionIsUnknown,
                            origin: .liveScan
                        )
                    }
                }
            )
            .presentationDetents([.large])
            .interactiveDismissDisabled()
        }
        .sheet(item: $activeTransitCard) { card in
            TransitResultSheet(card: card, tagInfo: activeTransitTagInfo)
        }
        .sheet(item: $activePassportData) { data in
            PassportResultSheet(passport: data, tagInfo: activePassportTagInfo)
        }
        .sheet(item: $activeHealthDevice) { device in
            HealthDeviceResultSheet(device: device, tagInfo: activeHealthDeviceTagInfo)
        }
        .sheet(item: $activeEditModel) { editModel in
            TagEditorSheet(
                editModel: editModel,
                appModel: model
            )
        }
        .sheet(isPresented: $showingLibrary) {
            LibrarySheet(
                appModel: model,
                onWritePreset: { preset in
                    showingLibrary = false
                    let pending = Self.pendingProtection(for: preset, credentials: model.library.credentials)
                    activeWriteModel = WriteFlowModel(
                        factory: model.sessionFactory,
                        dataArea: .forPreset(records: preset.decodedRecords(), arming: pending != nil),
                        credentials: model.library.tagCredentials,
                        protection: pending,
                        // The preset's stored credential doubles as the unlock
                        // secret when re-writing a tag already locked with it.
                        unlockCredential: pending?.credential,
                        // The one route in the app that arms protection without
                        // confirming the tag's UID, and deliberately so.
                        //
                        // The editor route's hazard is a substitution between
                        // two acts: the app reads tag A, the user configures
                        // protection against what tag A reported, and the arming
                        // tap can land on tag B. Re-reading the UID is what
                        // catches that. A preset write has no earlier reading to
                        // disagree with. Which tag is presented is the whole of
                        // the instruction, and this sheet writes one tag and
                        // closes, so a confirmation would have no prior fact to
                        // check against and would cost an identify tap plus
                        // fourteen typed characters on every tag in a stack.
                        //
                        // The cost, stated plainly because the next reader will
                        // want to widen this: a tag presented by mistake is armed
                        // with the preset's credential, and the app does not hand
                        // that credential back. The unlock prompt is manual hex
                        // entry and nothing seeds it from the Keychain, so on an
                        // NTAG424 AES key, an Ultralight C 3DES key or a SLIX2
                        // password, which were generated here and shown once, the
                        // way back is to write the same preset again while it
                        // still exists. Deleting the preset drops that copy too.
                        uidConfirmation: .notRequired,
                        activity: model.reviewPrompt
                    )
                },
                onOpenHistoryEntry: { entry in
                    showingLibrary = false
                    let info = Self.tagInfo(from: entry)
                    if let card = entry.decodedTransitCard() {
                        // Transit scans re-open the read-only transit view, not
                        // the record editor (they carry no NDEF records).
                        activeTransitTagInfo = info
                        activeTransitCard = card
                    } else {
                        // The same third case the live scan carries, and this
                        // route was dropping it: a row with no stored reading
                        // got `?? .none` with `protectionIsUnknown` left at its
                        // default, so the card showed an open padlock and "Off"
                        // about a tag nothing ever established anything about.
                        // Nothing here re-reads the tag, so the row's own
                        // silence is the whole of what is known.
                        activeEditModel = EditFlowModel(
                            records: entry.decodedRecords(),
                            tag: info,
                            protection: entry.decodedProtection() ?? .none,
                            protectionIsUnknown: entry.protectionIsUnknown,
                            origin: .history
                        )
                    }
                }
            )
        }
        .sheet(item: $activeWriteModel) { writeModel in
            WriteSheet(
                model: writeModel,
                onSuccess: { _ in
                    // Writing a preset from the Library has no editor behind it,
                    // so there is nothing for the reading to update. Closes only
                    // its own write: the hand-back can arrive after the sheet was
                    // swiped away and another preset write started.
                    if activeWriteModel === writeModel {
                        activeWriteModel = nil
                    }
                }
            )
        }
        .sheet(isPresented: $showingAdvanced) {
            AdvancedConsoleSheet(appModel: model)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsSheet(model: model)
        }
        .sheet(isPresented: $showingFeedback) {
            FeedbackSheet()
        }
        #if DEBUG
        .sheet(isPresented: $showingHarness) {
            TestHarnessScreen(appModel: model)
        }
        #endif
        .onAppear {
            HexHapticsEngine.shared.prepare()
            _ = try? model.library.purgeStale()
        }
        .task {
            costs = await CostsClient.fetch()
        }
        .background(TouchActivityMonitor { idleClock.touched() })
        .task(id: IdleWatch(homeIsFrontmost: isHomeFrontmost, isActive: scenePhase == .active)) {
            await proposeReviewWhenIdle()
        }
        .onChange(of: isHomeFrontmost) { _, isFrontmost in
            if !isFrontmost {
                leftHomeWithCardUp()
            }
        }
    }

    private func startBuild() {
        activeEditModel = EditFlowModel(records: [], origin: .build)
    }

    /// Resolve a preset's protection into a write-flow bundle: settings from the
    /// preset, secret from the Keychain. `nil` when the preset isn't protected
    /// or the credential is absent (e.g. imported on another device) — the write
    /// then proceeds without applying protection.
    private static func pendingProtection(
        for preset: Preset,
        credentials: ProtectionCredentialStoring
    ) -> PendingProtection? {
        guard let settings = preset.decodedProtection(), settings.passwordProtect,
              let credential = credentials.load(for: preset.id),
              let tagCredential = Self.tagCredential(from: credential, settings: settings) else { return nil }
        return PendingProtection(settings: settings, credential: tagCredential)
    }

    /// Map a stored Keychain credential (`HexNFCStorage`) onto the kit's
    /// family-tagged `TagCredential` (`HexNFCKit`). The App layer is the only
    /// place that sees both modules, so the mapping lives here. The Type-5 kind
    /// comes from the settings (the stored material carries only the bytes).
    /// Returns `nil` when the stored material cannot form a valid credential —
    /// today only an Ultralight C key of the wrong length, which the blob
    /// decoder already rejects, so this is defence in depth rather than an
    /// expected path. Callers skip applying protection rather than proceeding
    /// with a credential that would fail on the tag.
    static func tagCredential(from credential: ProtectionCredential, settings: TagProtection) -> TagCredential? {
        switch credential.material {
        case .type2(let password, let pack):
            return .type2(password: password, pack: pack)

        case .type4(let aesKey, let keySlot):
            return .type4(aesKey: aesKey, keySlot: Int(keySlot))

        case .type5(let write, let read):
            let kind: ProtectionStyle.Type5Settings.Kind = if case .type5(let s) = settings.effectiveStyle {
                s.kind
            } else {
                .write
            }
            return .type5(password: write ?? read ?? Data(), kind: kind)

        case .ultralightC(let key):
            guard let key = try? UltralightCKey(cipherOrder: key) else { return nil }
            return .ultralightC(key: key)
        }
    }

    /// Rebuild the display-ready tag snapshot from a stored history row so a
    /// re-opened scan shows the same "Tag" meta card the live scan did.
    private static func tagInfo(from entry: HistoryEntry) -> ScannedTagInfo {
        // The catalogued chip behind the stored display name. It carries the two
        // things the row itself doesn't persist: the NDEF capacity and (more
        // importantly) the chip *family*, without which the protection backend
        // can't be resolved.
        let profile = entry.chipName.flatMap { name in
            ChipCatalog.all.first { $0.displayName == name }
        }
        // A history row stores the tag's protection settings, so re-opening one
        // used to show a tag marked protected with no Protection card to manage
        // it: `supportsPasswordProtection` defaulted to false and `protectionStyle`
        // to nil, which hid the affordance and, had it been shown, would have
        // configured Type-2 fields for every chip. Both come from the same gate
        // the live scan uses, rebuilt from the persisted capability bitmask.
        let style = ScannedTagInfo.protectionStyle(
            forChipNamed: entry.chipName,
            capabilitiesRaw: entry.capabilitiesRaw
        )
        return ScannedTagInfo(
            chipName: entry.chipName,
            // "Unknown" is what the scan stored for a chip it could not name,
            // in English. The live scan of that tag has no family, and its card
            // says "Tag" in the user's language, so the re-opened one does too.
            familyName: entry.chipFamily.isEmpty || entry.chipFamily == "Unknown" ? nil : entry.chipFamily,
            manufacturer: entry.manufacturer,
            uidHex: entry.uidHex.isEmpty ? nil : entry.displayUID,
            totalBytes: entry.totalBytes > 0 ? entry.totalBytes : nil,
            // NDEF capacity isn't persisted; recover it from the catalogued chip
            // so a re-opened history row shows the same "256 Bytes (416B Total)"
            // memory line the live scan did.
            ndefBytes: profile.map(\.ndefByteCapacity),
            capabilitySummary: ScannedTagInfo.capabilitySummary(fromRaw: entry.capabilitiesRaw),
            supportsPasswordProtection: style != nil,
            protectionStyle: style,
            featureSummary: ScannedTagInfo.featureSummary(fromRaw: entry.capabilitiesRaw)
        )
    }

    // MARK: - Review prompt

    /// Home with nothing in front of it: every sheet this view presents is
    /// down. The scan sheet counts as in front for as long as the iOS NFC card
    /// is up, because that card only ever opens over it.
    private var isHomeFrontmost: Bool {
        var anythingUp = showingScan || showingLibrary || showingAdvanced || showingSettings || showingFeedback
            || activeEditModel != nil || activeWriteModel != nil
            || activeTransitCard != nil || activePassportData != nil
        #if DEBUG
        anythingUp = anythingUp || showingHarness
        #endif
        return !anythingUp
    }

    private var reducesMotion: Bool {
        systemReduceMotion || model.settings.reduceMotionOverride
    }

    @ViewBuilder
    private var reviewCardInset: some View {
        if let stage = reviewCard {
            ReviewPromptCard(
                stage: stage,
                onLove: loveIt,
                onMeh: meh,
                onHide: hideReviewCard,
                onSendFeedback: sendFeedbackFromCard
            )
            .padding(.horizontal, HexTokens.Spacing.xl)
            .padding(.top, HexTokens.Spacing.m)
            .padding(.bottom, HexTokens.Spacing.s)
            .background(alignment: .bottom) {
                // Fades Home's content out under the card instead of letting
                // a tile show through the gap at its edges.
                LinearGradient(
                    colors: [HexTokens.Color.surface0.opacity(0), HexTokens.Color.surface0],
                    startPoint: .top,
                    endPoint: .center
                )
                .ignoresSafeArea(edges: .bottom)
            }
            .transition(reducesMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Waits until Home has gone ten seconds without a touch, then shows the
    /// card if `ReviewPromptModel` says this person may be asked.
    ///
    /// Restarted by `.task(id:)` whenever Home comes to the front or the app
    /// becomes active again, so the ten seconds always run from the moment
    /// Home was in view. A touch moves the deadline without restarting the
    /// task, which keeps touches from re-evaluating this view's body.
    private func proposeReviewWhenIdle() async {
        guard isHomeFrontmost, scenePhase == .active, reviewCard == nil else { return }
        idleClock.touched()
        while true {
            let remaining = idleClock.remaining(of: IdleClock.wait)
            if remaining <= .zero {
                break
            }
            do {
                try await Task.sleep(for: remaining)
            } catch {
                return
            }
        }
        guard isHomeFrontmost, reviewCard == nil, model.reviewPrompt.mayPropose else { return }
        model.reviewPrompt.proposed()
        withAnimation(reducesMotion ? nil : .spring(response: 0.45, dampingFraction: 0.85)) {
            reviewCard = .asking
        }
        AccessibilityNotification.Announcement(String(localized: "Loving Hex NFC?")).post()
    }

    private func loveIt() {
        model.reviewPrompt.answer(.loved)
        withAnimation { reviewCard = .thanks }
        Task {
            // Long enough for "Thank you!" to register before Apple's sheet,
            // if iOS shows one, comes up over it.
            try? await Task.sleep(for: .milliseconds(400))
            requestReview()
            try? await Task.sleep(for: .milliseconds(1600))
            if reviewCard == .thanks {
                withAnimation { reviewCard = nil }
            }
        }
    }

    private func meh() {
        // Settled now, not on the next tap: whatever follows, this person is
        // not asked again.
        model.reviewPrompt.answer(.declined)
        withAnimation { reviewCard = .feedbackOffer }
    }

    private func hideReviewCard() {
        if reviewCard == .asking {
            model.reviewPrompt.answer(.hidden)
        }
        withAnimation { reviewCard = nil }
    }

    private func sendFeedbackFromCard() {
        reviewCard = nil
        showingFeedback = true
    }

    /// Opening anything from Home while the card is asking is an answer of
    /// sorts, and the quietest one: it counts as "Hide". The other stages have
    /// already been answered and just go.
    private func leftHomeWithCardUp() {
        guard let stage = reviewCard else { return }
        if stage == .asking {
            model.reviewPrompt.answer(.hidden)
        }
        reviewCard = nil
    }
}

/// `id` is `nonisolated` here and on `WriteFlowModel` below because
/// `Identifiable.id` is a nonisolated requirement, and the object's address
/// reads no main-actor state.
/// What the idle wait restarts on. Touches are deliberately not part of it;
/// see `RootView.proposeReviewWhenIdle`.
private struct IdleWatch: Equatable {
    let homeIsFrontmost: Bool
    let isActive: Bool
}

/// When Home was last touched, kept outside SwiftUI's state so a touch moves
/// the idle deadline without re-evaluating `RootView`'s body, whose sheet
/// closures re-run on every pass.
@MainActor
private final class IdleClock {
    /// How long Home has to sit untouched before the review card may appear.
    static let wait: Duration = .seconds(10)

    private var lastTouch = ContinuousClock.now

    func touched() {
        lastTouch = .now
    }

    func remaining(of wait: Duration) -> Duration {
        wait - (ContinuousClock.now - lastTouch)
    }
}

extension EditFlowModel: Identifiable {
    public nonisolated var id: ObjectIdentifier {
        ObjectIdentifier(self)
    }
}

extension WriteFlowModel: Identifiable {
    public nonisolated var id: ObjectIdentifier {
        ObjectIdentifier(self)
    }
}
#endif
