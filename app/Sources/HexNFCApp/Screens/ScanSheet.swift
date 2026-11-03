#if os(iOS)
import HexNFCDesign
import HexNFCKit
import HexNFCRecords
import HexNFCShaders
import HexNFCStorage
import SwiftUI

/// First half of the scan → edit → write loop. Hosts `ScanFlowModel`, fires
/// the moment composer on every phase change, and surfaces an error pane
/// with a retry pill when the chip slips or the session times out.
struct ScanSheet: View {
    /// Built here, in `@State`, rather than handed in already constructed.
    ///
    /// `RootView` presents this from a `.sheet(isPresented:)` closure, and
    /// SwiftUI re-runs that closure every time the presenting body is
    /// re-evaluated: the launch `costs` fetch landing, a settings change, any
    /// observed property of `AppModel` moving. A model held in a plain property
    /// is then replaced mid-scan by a fresh `.idle` one, while `.task` carries
    /// on driving the instance it captured on the first pass. The screen sits on
    /// "Hold tag against the top of your iPhone" through a read that has already
    /// finished, and the `onChange(of: model.phase)` that hands the result back
    /// is watching a model nothing is driving. `@State` keeps the first instance
    /// for the life of the presentation, so the session, the screen and the
    /// hand-back are all the same object. Same reason, same shape as
    /// `AdvancedConsoleSheet` and `TestHarnessScreen`.
    @State private var model: ScanFlowModel
    /// The `Bool` is `protectionIsUnknown`: the protection read was refused
    /// rather than answering "this chip has none". A `nil` protection with the
    /// flag set means we do not know, which is not the same as "Off".
    let onComplete: (
        [NDEFRecord], ScannedTagInfo?, TransitCard?, PassportData?, HealthDeviceScan?, TagProtection?, Bool
    ) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var hasFiredReadyHaptic = false
    @State private var unlockHex = ""
    // Passport MRZ key entry (session-only; never stored).
    @State private var passportDocNumber = ""
    @State private var passportDOB = Self.defaultPassportDOB
    @State private var passportExpiry = Self.defaultPassportExpiry
    // Passport key read by the camera (session-only; never stored): the key
    // that locked, then its alternates, most likely first.
    @State private var showsMRZScanner = false
    @State private var capturedKeys: [PassportMRZ] = []
    @State private var capturedIndex = 0
    /// Which captured key the last read used, so a refusal can move on.
    @State private var attemptedCapturedIndex: Int?
    /// The passport refused a captured key and the prompt moved to the next.
    @State private var movedToAlternate = false
    @Environment(\.scenePhase) private var scenePhase

    init(
        factory: TagSessionFactory,
        library: LibraryRepository?,
        activity: TagActivityRecording?,
        onComplete: @escaping (
            [NDEFRecord], ScannedTagInfo?, TransitCard?, PassportData?, HealthDeviceScan?, TagProtection?, Bool
        ) -> Void
    ) {
        _model = State(initialValue: ScanFlowModel(factory: factory, library: library, activity: activity))
        self.onComplete = onComplete
    }

    // MARK: - Family-aware unlock

    /// The protection family to collect a credential for, from the scanned tag's
    /// detected style (defaults to Type-2 before identification).
    private var unlockFamily: ProtectionStyle {
        model.scannedTagInfo?.protectionStyle ?? .type2(.init())
    }

    /// Shared with `WriteSheet` via `ProtectionStyle` (see `UnlockPrompt.swift`).
    private var unlockIsKey: Bool {
        unlockFamily.unlockSecretIsKey
    }

    private var unlockExpectedBytes: Int {
        unlockFamily.unlockSecretByteCount
    }

    private var unlockFieldLabel: LocalizedStringKey {
        unlockFamily.unlockSecretDescription
    }

    /// Names the cipher, because "16-byte key" doesn't identify which secret to
    /// go and find: an NTAG424 wants AES and an Ultralight C wants 3DES, both 16
    /// bytes. The field label below already distinguishes them (see
    /// `UnlockPrompt.swift`); this sentence used to say "AES" for both.
    private var unlockPromptCopy: LocalizedStringKey {
        switch unlockFamily {
        case .type4:
            "This tag looks key-protected. Enter its 16-byte AES key, then hold it to the top of your iPhone again."

        case .ultralightC:
            "This tag looks key-protected. Enter its 16-byte 3DES key, then hold it to the top of your iPhone again."

        case .type2, .type5:
            "This tag looks password-protected. Enter its password, then hold it to the top of your iPhone again."
        }
    }

    private var unlockFailedCopy: LocalizedStringKey {
        unlockIsKey
            ? "That key didn't unlock the tag. Check it and try again."
            : "That password didn't unlock the tag. Check it and try again."
    }

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
        .task {
            await model.begin()
        }
        // Moment composer: each transition fires the matching haptic. The
        // scan-success moment also gets its signature visual — the rainbow
        // chromatic-aberration sweep layered with a radial shockwave.
        .hexHero(.scanIdle, isActive: model.phase == .polling)
        .hexHero(.scanDetected, trigger: model.phase == .connected ? 1 : 0)
        .hexHero(.scanReading, trigger: model.phase == .reading ? 1 : 0)
        // Passports get their own richer reveal on the result sheet, so the
        // generic success flourish (haptic + rainbow sweep grid) is suppressed
        // for them and fires only for ordinary NDEF / transit reads.
        .hexHero(.scanSuccess, trigger: genericSuccessTrigger)
        .hexScanReveal(trigger: genericSuccessTrigger)
        // Passport unlock reveal: builds LIVE during the read (behind iOS's NFC
        // card, which is only a partial bottom sheet), bursts as the read
        // completes, then recedes. Owns the success haptic for passports.
        .hexPassportReveal(
            progress: model.passportReadProgress,
            finished: passportRevealFinished,
            isActive: passportRevealActive
        )
        .hexHero(.error, trigger: errorTriggerValue)
        .fullScreenCover(isPresented: $showsMRZScanner) {
            PassportMRZScannerSheet { lock in
                capturedKeys = [lock.key] + lock.alternates
                capturedIndex = 0
                attemptedCapturedIndex = nil
                movedToAlternate = false
            }
        }
        .onChange(of: model.passportReadFailed) { _, failed in
            followCapturedKeyRefusal(failed: failed)
        }
        .onChange(of: model.phase) { _, newPhase in
            // The user closed the system sheet before any tag was in play. They
            // asked to scan and then changed their mind, so the answer is to put
            // them back on Home, not to tell them the scan failed.
            if newPhase == .cancelled {
                dismiss()
                return
            }
            guard case .ready = newPhase, !hasFiredReadyHaptic else { return }
            hasFiredReadyHaptic = true
            Task {
                // Non-passport reads hold ~1s so the sweep + shockwave play out.
                // A passport's reveal plays here on the scan screen, so hold long
                // enough for its burst + recede to finish before we hand off.
                let holdNanos: UInt64 = model.passportData == nil ? 1_000_000_000 : 750_000_000
                try? await Task.sleep(nanoseconds: holdNanos)
                onComplete(
                    model.records, model.scannedTagInfo, model.transitCard,
                    model.passportData, model.healthDevice, model.detectedProtection,
                    model.protectionReadFailed
                )
            }
        }
        .accessibilityIdentifier("scan.sheet")
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        // `.cancelled` keeps the polling screen, still, for the moment the sheet
        // takes to slide away, so nothing new flashes up on the way out.
        case .idle, .polling, .cancelled:
            pollingView

        case .connected, .reading:
            // While a passport reads, let the full-screen unlock reveal own the
            // screen (iOS's NFC card already shows the progress copy). Other
            // reads keep the standard "Reading…" view.
            if passportRevealActive {
                Color.clear
            } else {
                readingView
            }

        case .ready:
            // A passport's success moment is the reveal's burst/recede, not the
            // generic "Tag detected" card (which would also read "No NDEF records").
            if model.passportData != nil {
                Color.clear
            } else {
                successView
            }

        case .locked:
            lockedView

        case .needsPassportKey:
            passportKeyView

        case .noTagFound:
            noTagFoundView

        case .error(let message, let diagnostics):
            errorView(message: message, diagnostics: diagnostics)
        }
    }

    /// Shown when the tapped chip is an electronic passport. Collects the MRZ
    /// access key (document number + date of birth + date of expiry) and re-taps
    /// to read. The copy is explicit that nothing here is collected or stored.
    private var passportKeyView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HexTokens.Spacing.l) {
                HStack(spacing: HexTokens.Spacing.s) {
                    Image(systemName: "person.text.rectangle")
                        .foregroundStyle(HexTokens.Color.primaryLight)
                    Text("Passport detected")
                        .font(HexTokens.Font.title)
                        .foregroundStyle(HexTokens.Color.textPrimary)
                }
                passportPromptMessage
                    .font(HexTokens.Font.body)
                    .foregroundStyle(model.passportReadFailed ? HexTokens.Color.dangerText : HexTokens.Color
                        .textPrimary)

                if let captured = activeCapturedKey {
                    capturedKeyCard(captured)
                } else {
                    if MRZCameraController.isAvailable {
                        HexButton("Scan photo page", systemImage: "camera.viewfinder", variant: .secondary) {
                            showsMRZScanner = true
                        }
                        .accessibilityIdentifier("passport.scanPhotoPage")
                    }
                    manualPassportFields
                }

                Label(
                    "These details stay on your device, are used only for this read, and are never stored or sent anywhere.",
                    systemImage: "lock.shield"
                )
                .font(HexTokens.Font.footnote)
                .foregroundStyle(HexTokens.Color.textSecondary)

                HexButton("Read passport", systemImage: "wave.3.right", variant: .primary) {
                    let mrz: PassportMRZ
                    if let captured = activeCapturedKey {
                        attemptedCapturedIndex = capturedIndex
                        mrz = captured
                    } else {
                        attemptedCapturedIndex = nil
                        mrz = PassportMRZ(
                            documentNumber: passportDocNumber,
                            dateOfBirth: Self.mrzDate(passportDOB),
                            dateOfExpiry: Self.mrzDate(passportExpiry)
                        )
                    }
                    Task { await model.readPassport(with: mrz) }
                }
                .disabled(
                    activeCapturedKey == nil && passportDocNumber.trimmingCharacters(in: .whitespaces).isEmpty
                )
                .accessibilityIdentifier("passport.read")

                HexButton("Cancel", variant: .ghost) {
                    model.reset()
                    dismiss()
                }
            }
        }
        .accessibilityIdentifier("scan.needsPassportKey")
    }

    // MARK: - Passport key from the camera

    /// The captured key the next read will use.
    private var activeCapturedKey: PassportMRZ? {
        capturedKeys.indices.contains(capturedIndex) ? capturedKeys[capturedIndex] : nil
    }

    private var passportPromptMessage: Text {
        if model.passportReadFailed, movedToAlternate {
            return Text(
                "Those details didn't unlock the passport. The camera may have misread a character, so the next try uses another reading of the number."
            )
        }
        if model.passportReadFailed {
            return Text("Those details didn't unlock the passport. Check them against the photo page and try again.")
        }
        if activeCapturedKey != nil {
            return Text("Check these against the photo page, then hold the passport to the top of your iPhone again.")
        }
        if MRZCameraController.isAvailable {
            return Text("Scan the photo page or enter its details, then hold the passport to the top of your iPhone again.")
        }
        return Text("Enter the details printed on your passport's photo page, then hold it to the top of your iPhone again.")
    }

    /// The key the camera read, shown for checking. It never goes through the
    /// date pickers, so a date with an unknown day (`<<`), which they cannot
    /// show, reaches the passport exactly as printed.
    private func capturedKeyCard(_ key: PassportMRZ) -> some View {
        VStack(alignment: .leading, spacing: HexTokens.Spacing.m) {
            Label("Read from the photo page", systemImage: "checkmark.circle.fill")
                .font(HexTokens.Font.footnote)
                .foregroundStyle(HexTokens.Color.success)
            VStack(alignment: .leading, spacing: HexTokens.Spacing.s) {
                capturedRow("Passport number", key.documentNumber)
                capturedRow("Date of birth", PassportMRZDate.display(key.dateOfBirth, isExpiry: false))
                capturedRow("Date of expiry", PassportMRZDate.display(key.dateOfExpiry, isExpiry: true))
            }
            .accessibilityElement(children: .combine)
            // The app-switcher snapshot is taken while the app is inactive.
            .blur(radius: scenePhase == .active ? 0 : 12)
            HStack(spacing: HexTokens.Spacing.m) {
                HexButton("Scan again", systemImage: "camera.viewfinder", variant: .secondary) {
                    showsMRZScanner = true
                }
                .accessibilityIdentifier("passport.rescan")
                if canEditInFields(key) {
                    HexButton("Edit", systemImage: "pencil", variant: .ghost) {
                        editCapturedKey(key)
                    }
                    .accessibilityIdentifier("passport.editCaptured")
                }
            }
        }
        .padding(HexTokens.Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: HexTokens.Radius.m, style: .continuous)
                .fill(HexTokens.Color.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HexTokens.Radius.m, style: .continuous)
                .stroke(HexTokens.Stroke.cardInner, lineWidth: HexTokens.Stroke.cardInnerWidth)
        )
        .accessibilityIdentifier("passport.captured")
    }

    private func capturedRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(HexTokens.Font.footnote)
                .foregroundStyle(HexTokens.Color.textSecondary)
            Spacer(minLength: HexTokens.Spacing.m)
            Text(verbatim: value)
                .font(HexTokens.Font.mono)
                .foregroundStyle(HexTokens.Color.textPrimary)
                .textSelection(.enabled)
        }
    }

    /// The pickers can only hold whole dates.
    private func canEditInFields(_ key: PassportMRZ) -> Bool {
        PassportMRZDate.date(key.dateOfBirth, isExpiry: false) != nil
            && PassportMRZDate.date(key.dateOfExpiry, isExpiry: true) != nil
    }

    /// Hand the captured key to the typed fields and let the holder change it.
    private func editCapturedKey(_ key: PassportMRZ) {
        passportDocNumber = key.documentNumber
        if let birth = PassportMRZDate.date(key.dateOfBirth, isExpiry: false) { passportDOB = birth }
        if let expiry = PassportMRZDate.date(key.dateOfExpiry, isExpiry: true) { passportExpiry = expiry }
        capturedKeys = []
        capturedIndex = 0
        attemptedCapturedIndex = nil
        movedToAlternate = false
    }

    /// After the passport refuses a captured key, offer the next alternate.
    /// Check digits cannot tell some look-alike characters apart (see
    /// `MRZScanConsensus`), so once the chip has said no, a misread of one of
    /// those is the likeliest reason. After the last alternate it goes back to
    /// the first reading. Any other failure keeps the key as it is.
    private func followCapturedKeyRefusal(failed: Bool) {
        guard failed, let attempted = attemptedCapturedIndex, !capturedKeys.isEmpty else {
            movedToAlternate = false
            return
        }
        if model.passportFailureWasRefusal, attempted + 1 < capturedKeys.count {
            capturedIndex = attempted + 1
            movedToAlternate = true
        } else {
            capturedIndex = model.passportFailureWasRefusal ? 0 : attempted
            movedToAlternate = false
        }
    }

    /// Typed entry: the passport number and two date pickers.
    private var manualPassportFields: some View {
        VStack(alignment: .leading, spacing: HexTokens.Spacing.m) {
            // VoiceOver does not tie this Text to the field below it, so
            // the field was announced by its prompt, "e.g. PA1234567".
            // Name the field and hide the Text, which would otherwise be
            // read as a second, separate element saying the same thing.
            Text("Passport number")
                .font(HexTokens.Font.footnote)
                .foregroundStyle(HexTokens.Color.textSecondary)
                .accessibilityHidden(true)
            TextField("e.g. PA1234567", text: $passportDocNumber)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(HexTokens.Font.mono)
                .foregroundStyle(HexTokens.Color.textPrimary)
                .padding(.horizontal, HexTokens.Spacing.m)
                .padding(.vertical, HexTokens.Spacing.s)
                .background(
                    RoundedRectangle(cornerRadius: HexTokens.Radius.s, style: .continuous)
                        .fill(HexTokens.Color.surface1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: HexTokens.Radius.s, style: .continuous)
                        .stroke(HexTokens.Stroke.cardInner, lineWidth: HexTokens.Stroke.cardInnerWidth)
                )
                .accessibilityIdentifier("passport.number")
                .accessibilityLabel(Text("Passport number"))

            DatePicker("Date of birth", selection: $passportDOB, displayedComponents: .date)
                .foregroundStyle(HexTokens.Color.textPrimary)
            DatePicker("Date of expiry", selection: $passportExpiry, displayedComponents: .date)
                .foregroundStyle(HexTokens.Color.textPrimary)
        }
        .tint(HexTokens.Color.primaryLight)
    }

    /// Format a `Date` as the six-digit `YYMMDD` an MRZ uses.
    static func mrzDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyMMdd"
        return formatter.string(from: date)
    }

    /// Sensible starting point for the date-of-birth picker, rather than the Unix epoch.
    /// Falling back to "now" rather than force-unwrapping: a picker default is
    /// not worth a launch crash, and the gregorian calendar cannot fail to
    /// resolve these anyway.
    private static let defaultPassportDOB = DateComponents(
        calendar: Calendar(identifier: .gregorian), year: 1995, month: 1, day: 1
    ).date ?? Date()

    /// Sensible starting point for the date-of-expiry picker, rather than "now".
    private static let defaultPassportExpiry = DateComponents(
        calendar: Calendar(identifier: .gregorian), year: 2030, month: 1, day: 1
    ).date ?? Date()

    private var pollingView: some View {
        VStack(spacing: HexTokens.Spacing.xl) {
            // Same curve, same peak, same start frame as before for anyone who
            // has not asked for less motion. `hexPulse` owns the Reduce Motion
            // gate, which is why this screen still declares no environment
            // value for it: the previous version spelled the loop by hand and
            // ran it through the setting.
            HexTransition(state: .present, size: 120)
                .hexPulse(active: model.phase == .polling)
            Text("Hold tag against the top of your iPhone")
                .font(HexTokens.Font.title)
                .foregroundStyle(HexTokens.Color.textPrimary)
                .multilineTextAlignment(.center)
            HexButton("Cancel", variant: .ghost) {
                model.reset()
                dismiss()
            }
            .accessibilityIdentifier("scan.cancel")
        }
    }

    private var readingView: some View {
        VStack(spacing: HexTokens.Spacing.l) {
            HexTransition(state: .present, size: 96)
            Text("Reading…")
                .font(HexTokens.Font.heading)
                .foregroundStyle(HexTokens.Color.primaryLight)
            ProgressView()
                .progressViewStyle(.linear)
                .tint(HexTokens.Color.primary)
                .frame(maxWidth: 200)
        }
    }

    private var successView: some View {
        VStack(spacing: HexTokens.Spacing.l) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(HexTokens.Color.success)
            Text("Tag detected")
                .font(HexTokens.Font.title)
                .foregroundStyle(HexTokens.Color.textPrimary)
            if let chipName = model.detectedChipName {
                Text(verbatim: chipName)
                    .font(HexTokens.Font.heading)
                    .foregroundStyle(HexTokens.Color.primaryLight)
                    .hexCopyable(chipName)
            }
            if let maker = model.healthDevice?.maker {
                Text(verbatim: maker.name)
                    .font(HexTokens.Font.body)
                    .foregroundStyle(HexTokens.Color.textSecondary)
            } else if let card = model.transitCard {
                let balance = TransitFormat.currency(card.balanceYen)
                Text(verbatim: balance)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(HexTokens.Color.success)
                    .hexCopyable(balance)
            } else if model.formatState == .noCapabilityContainer {
                // Not the same as "empty", and the difference is the one the user
                // needs: this tag will accept a write and no reader will see it
                // until the Capability Container is written.
                VStack(spacing: HexTokens.Spacing.xs) {
                    Text("This tag isn't formatted yet")
                        .font(HexTokens.Font.body)
                        .foregroundStyle(HexTokens.Color.warning)
                    Text("Format it from Operations before writing, or nothing you write will be readable.")
                        .font(HexTokens.Font.footnote)
                        .foregroundStyle(HexTokens.Color.textSecondary)
                }
                .multilineTextAlignment(.center)
            } else if model.formatState == .noNDEFApplication {
                // A blank DESFire, read from its applications rather than
                // guessed from the refused read: a transit card never lands here.
                VStack(spacing: HexTokens.Spacing.xs) {
                    Text("This card isn't set up for NDEF yet")
                        .font(HexTokens.Font.body)
                        .foregroundStyle(HexTokens.Color.warning)
                    Text("Format it from Operations to give it an NDEF application, then write records to it.")
                        .font(HexTokens.Font.footnote)
                        .foregroundStyle(HexTokens.Color.textSecondary)
                }
                .multilineTextAlignment(.center)
            } else if model.formatState == .unreadableDataArea {
                // The other half of the same refusal, and the opposite repair.
                // Page 3 was read and holds a Capability Container, so a format
                // would find its work already done and write nothing, which is
                // exactly the dead end a real NTAG213 walked a user into on
                // 2026-09-09.
                VStack(spacing: HexTokens.Spacing.xs) {
                    Text("This tag's data won't read")
                        .font(HexTokens.Font.body)
                        .foregroundStyle(HexTokens.Color.warning)
                    Text(
                        "Erase it from Operations to rewrite the data area. Formatting won't help: it already has a Capability Container."
                    )
                    .font(HexTokens.Font.footnote)
                    .foregroundStyle(HexTokens.Color.textSecondary)
                }
                .multilineTextAlignment(.center)
            } else if model.records.isEmpty {
                Text("No NDEF records on this tag")
                    .font(HexTokens.Font.body)
                    .foregroundStyle(HexTokens.Color.textSecondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("^[\(model.records.count) record](inflect: true) found")
                    .font(HexTokens.Font.body)
                    .foregroundStyle(HexTokens.Color.textSecondary)
            }
            if let uid = model.detectedUIDHex {
                Text(verbatim: uid)
                    .font(HexTokens.Font.mono)
                    .foregroundStyle(HexTokens.Color.textSecondary)
                    .textSelection(.enabled)
                    .hexCopyable(uid)
            }
        }
        .accessibilityIdentifier("scan.success")
    }

    /// Shown when a read fails on a password-capable tag — most likely because
    /// it's read-protected. Collects the tag password and re-scans, authenticating
    /// first. Also offers a plain retry in case the tag was simply pulled away.
    private var lockedView: some View {
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
            // The field + credential adapt to the tag's family: a 4-byte password
            // for Type-2 / SLIX, a 16-byte AES key for an NTAG424, a 16-byte 3DES
            // key for an Ultralight C.
            HexHexField(label: unlockFieldLabel, hex: $unlockHex, expectedBytes: unlockExpectedBytes)
            HexButton("Unlock & scan again", systemImage: "lock.open", variant: .primary) {
                guard let credential = makeUnlockCredential() else { return }
                Task { await model.unlock(with: credential) }
            }
            .disabled(makeUnlockCredential() == nil)
            .accessibilityIdentifier("scan.unlock")
            HStack(spacing: HexTokens.Spacing.m) {
                HexButton("Cancel", variant: .ghost) {
                    model.reset()
                    dismiss()
                }
                HexButton("Try again", variant: .secondary) {
                    unlockHex = ""
                    model.reset()
                    Task { await model.begin() }
                }
            }
        }
        .accessibilityIdentifier("scan.locked")
    }

    /// The session timed out with nothing in the field, on a scan that has never
    /// had a tag. Not a failure, so none of the error pane's furniture: no red,
    /// no diagnostics, and no error haptic (`errorTriggerValue` is zero here).
    private var noTagFoundView: some View {
        VStack(alignment: .leading, spacing: HexTokens.Spacing.l) {
            NoTagFoundNotice()
            HStack(spacing: HexTokens.Spacing.m) {
                HexButton("Cancel", variant: .secondary) {
                    model.reset()
                    dismiss()
                }
                HexButton("Try again", variant: .primary) {
                    model.reset()
                    Task { await model.begin() }
                }
                .accessibilityIdentifier("scan.retry")
            }
        }
        .accessibilityIdentifier("scan.noTagFound")
    }

    private func errorView(message: String, diagnostics: String) -> some View {
        VStack(alignment: .leading, spacing: HexTokens.Spacing.l) {
            HStack(spacing: HexTokens.Spacing.s) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(HexTokens.Color.dangerText)
                Text("Scan failed")
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
                    .hexCopyable(diagnostics)
            }
            .tint(HexTokens.Color.primaryLight)
            HStack(spacing: HexTokens.Spacing.m) {
                HexButton("Cancel", variant: .secondary) {
                    model.reset()
                    dismiss()
                }
                HexButton("Try again", variant: .primary) {
                    model.reset()
                    Task { await model.begin() }
                }
                .accessibilityIdentifier("scan.retry")
            }
        }
    }

    private var errorTriggerValue: Int {
        if case .error = model.phase {
            return model.transitionCount
        }
        return 0
    }

    /// Fires the generic scan-success moment (sweep grid + haptic) only for
    /// NON-passport reads. A passport's success haptic and reveal are owned by
    /// `.hexPassportReveal` on this sheet, so it must not double up.
    private var genericSuccessTrigger: Int {
        (model.phase == .ready && model.passportData == nil) ? 1 : 0
    }

    /// The passport unlock reveal is live while a read is in flight (progress
    /// only moves off zero during an actual passport read) and through the
    /// completion burst/recede.
    private var passportRevealActive: Bool {
        model.passportReadProgress > 0
    }

    /// The read has landed: trigger the reveal's burst + recede + success haptic.
    private var passportRevealFinished: Bool {
        model.phase == .ready && model.passportData != nil
    }
}
#endif
