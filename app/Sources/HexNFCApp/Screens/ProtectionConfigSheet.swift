#if os(iOS)
import HexNFCDesign
import HexNFCKit
import HexNFCRecords
import HexNFCShaders
import Security
import SwiftUI

/// Configures the password-protection *settings* on an `EditFlowModel`, adapting
/// its fields to the target chip's family:
///   - **Type-2** (NTAG21x / UL-EV1): a 4-byte password, with an Advanced
///     disclosure for read-protection (PROT), AUTH0 start page and the raw PACK.
///   - **Type-4** (NTAG424 DNA): a 16-byte AES-128 key (with a generate helper)
///     and an optional "also require key to read" toggle. No PACK/AUTH0/AUTH_LIM.
///   - **Type-5** (ICODE SLIX2): a 4-byte write password. Write protection only,
///     because a read gate on this family means privacy mode, and iOS cannot
///     discover a privacy-mode tag to undo it. See `type5Fields`.
///
/// Permanent lock is deliberately not here — it lives behind Dangerous Actions,
/// never as a batchable setting. The chip's failed-attempt limit (AUTH_LIM) is
/// gone from here for the same reason and now sits beside it: it arms an outcome
/// no later tap can undo, deferred until somebody mistypes, and this sheet's
/// output is a preset that is not pinned to one tag, is replayed across a stack
/// of them from the Library, and travels in `.hexnfc` exports.
///
/// On dismiss the choices are committed back into the edit model; the write flow
/// and "Save as preset" read them from there.
struct ProtectionConfigSheet: View {
    /// The chip family whose fields the card shows. `ProtectionStyle`'s own
    /// enum, so the card, `ProtectionCardSeed` and the records layer all name
    /// the same four families once.
    typealias Family = ProtectionStyle.Family

    /// How the user supplies an Ultralight C key. Generate is the default
    /// because a random 16-byte key is the only option whose strength does not
    /// depend on the user, and the key can be saved with a preset either way.
    enum KeyEntry: String, CaseIterable, Identifiable {
        case generate
        case paste
        case passphrase
        var id: String {
            rawValue
        }

        var label: LocalizedStringKey {
            switch self {
            case .generate: "Generate"
            case .paste: "Paste"
            case .passphrase: "Passphrase"
            }
        }
    }

    @Bindable var editModel: EditFlowModel
    @Environment(\.dismiss) private var dismiss

    let family: Family

    @State private var passwordProtect: Bool
    // Type-2 / Type-5 password (4 bytes); Type-4 uses `keyHex`.
    @State private var passwordHex: String
    @State private var packHex: String
    @State private var keyHex: String
    @State private var readProtect: Bool
    @State private var customStartPage: Bool
    @State private var startPage: Int
    @State private var showAdvanced = false
    @State private var keyEntry: KeyEntry = .generate
    @State private var passphrase: String = ""

    init(editModel: EditFlowModel) {
        self.editModel = editModel
        let resolved = Self.family(for: editModel)
        family = resolved
        let p = editModel.protection
        _passwordProtect = State(initialValue: p.passwordProtect)
        _readProtect = State(initialValue: p.effectiveReadProtect)
        // AUTH0 comes from whichever family actually stores it. Reading only the
        // flat `protectFromPage` was right for Type-2 (where it *is* the storage)
        // and silently wrong for Ultralight C, whose start page lives inside
        // `style` — so a tag detected as protected from, say, page 3 came back as
        // "no custom start page" and re-protecting it would quietly move the
        // boundary to the chip's default.
        let detectedStartPage = Self.startPage(in: p)
        _customStartPage = State(initialValue: detectedStartPage != nil)
        _startPage = State(initialValue: detectedStartPage ?? 4)

        // Seed the secret fields.
        //
        // The rule lives in `ProtectionCardSeed`, not here, because this file is
        // `#if os(iOS)` and nothing in `swift test` compiles it. What it decides
        // has twice been able to reprogram a live credential (the Type-2
        // password in August, the Ultralight C key found on 2026-09-19), so it
        // is tested rather than merely reviewed. See `ProtectionCardSeedTests`.
        //
        // The reading, not the intent. `editModel.protection` is what the user
        // has staged and `originalProtection` is what the tag said, and taking
        // the first reopens the hole: stage a removal on a protected tag, press
        // Done, reopen this card, and `protection.passwordProtect` is now false
        // although the tag is still holding its credential. The card would seed
        // a fresh key for it, or the delivery password. Either is a credential
        // the user did not choose, on a tag that already has one.
        //
        // `protectionIsUnknown` counts as "may hold one" for the same reason:
        // a protection state that could not be read is not a tag proven bare.
        let seed = ProtectionCardSeed.seed(
            family: resolved,
            credential: editModel.protectionCredential,
            tagReportsProtection: editModel.originalProtection.passwordProtect
                || editModel.protectionIsUnknown
                || p.passwordProtect
        )
        if seed.generatesUltralightCKey {
            _keyEntry = State(initialValue: .generate)
        } else if resolved == .ultralightC {
            _keyEntry = State(initialValue: .paste)
        }
        _passwordHex = State(initialValue: seed.passwordHex)
        _packHex = State(initialValue: seed.packHex)
        _keyHex = State(initialValue: seed.generatesUltralightCKey ? Self.randomHex(16) : seed.keyHex)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(toggleTitle, isOn: $passwordProtect.animation())
                        .tint(HexTokens.Color.primary)
                } footer: {
                    VStack(alignment: .leading, spacing: HexTokens.Spacing.xs) {
                        Text(toggleFooter)
                        // Said once, here, rather than folded into seven footers:
                        // a write that changes protection confirms the tag in
                        // between, and the user should know that before they
                        // press Write rather than when the card appears.
                        if confirmsTagBeforeWriting {
                            Text(
                                "The next write takes two taps: one to read the tag's ID, which you type to confirm, then one to make the change."
                            )
                        }
                    }
                }

                if passwordProtect {
                    switch family {
                    case .type2: type2Fields
                    case .type4: type4Fields
                    case .type5: type5Fields
                    case .ultralightC: ultralightCFields
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(HexTokens.Color.surface0.ignoresSafeArea())
            .navigationTitle(Text("Protection"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(HexTokens.Color.textSecondary)
                        .hexPressHaptic()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { commit()
                        dismiss()
                    }
                    // A tint so `.disabled` can grey it; see the editor's Write
                    // button for why a fixed colour cannot. A half-typed
                    // password is exactly when this one is disabled.
                    .tint(HexTokens.Color.primaryLight)
                    .hexPressHaptic()
                    .disabled(!canSave)
                    .accessibilityIdentifier("protection.done")
                }
            }
            .toolbarBackground(HexTokens.Color.surface0, for: .navigationBar)
            .preferredColorScheme(.dark)
        }
    }

    // MARK: - Per-family fields

    @ViewBuilder private var type2Fields: some View {
        Section("Password") {
            HexHexField(label: "Password (4 bytes)", hex: $passwordHex, expectedBytes: 4)
        }
        Section {
            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                Toggle("Also require password to read", isOn: $readProtect)
                    .tint(HexTokens.Color.primary)
                if readProtect {
                    Text("Read-protected tags can't be read back, including verification, without the password.")
                        .font(HexTokens.Font.footnote)
                        .foregroundStyle(HexTokens.Color.textSecondary)
                }
                // The two are not offered together, and the reason is not
                // taste. Hex NFC recognises a read-gated Type-2 tag by the
                // roll-over in a single `30 03`, which only shows up when the
                // gate starts at the first data page. Started anywhere else,
                // the tag NAKs that read, the driver stops before it can
                // present a password, and this app can no longer unlock,
                // rewrite, re-key or unprotect the tag: every attempt says the
                // right password was wrong. See `ProtectionSpec.make`, which
                // pins the same rule for presets and imports.
                if !readProtect {
                    Toggle("Custom start page", isOn: $customStartPage)
                        .tint(HexTokens.Color.primary)
                    if customStartPage {
                        Stepper(value: $startPage, in: 3 ... 0xFE) {
                            Text("Protect from page \(startPage)").font(HexTokens.Font.body)
                        }
                    } else {
                        Text("Protects the whole data area (the chip's first data page onward).")
                            .font(HexTokens.Font.footnote)
                            .foregroundStyle(HexTokens.Color.textSecondary)
                    }
                } else {
                    Text("A read gate always covers the whole data area, from the chip's first data page.")
                        .font(HexTokens.Font.footnote)
                        .foregroundStyle(HexTokens.Color.textSecondary)
                }
                HexHexField(label: "PACK (2 bytes)", hex: $packHex, expectedBytes: 2)
                Text(
                    "The chip's attempt limit is not set from here. It lives in Operations, under Dangerous Actions, because it is armed against one tag at a time and cannot be undone."
                )
                .font(HexTokens.Font.footnote)
                .foregroundStyle(HexTokens.Color.textSecondary)
            }
            .tint(HexTokens.Color.primaryLight)
        } footer: {
            Text("Lose the password and the protected memory is gone. There is no recovery.")
        }
    }

    private var type4Fields: some View {
        Section {
            HexHexField(label: "Key (16 bytes)", hex: $keyHex, expectedBytes: 16)
            Button("Generate random key") { keyHex = Self.randomHex(16) }
                .foregroundStyle(HexTokens.Color.primaryLight)
                .accessibilityIdentifier("protection.generateKey")
            Toggle("Also require key to read", isOn: $readProtect)
                .tint(HexTokens.Color.primary)
        } header: {
            Text("AES key")
        } footer: {
            Label(
                "Lose this key and you can never rewrite this tag. There is no factory reset for an NTAG424. Store it safely.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(HexTokens.Font.footnote)
            .foregroundStyle(HexTokens.Color.dangerText)
        }
    }

    /// Write protection only.
    ///
    /// "Read + write" used to be offered here as an ordinary segmented choice.
    /// On a SLIX2 it arms **privacy mode**, and a tag in privacy mode answers no
    /// inventory at all (SL2S2602 section 9.5.3.9). CoreNFC only ever hands this
    /// app tags it has inventoried, so the tag stops existing as far as iPhone
    /// is concerned: not locked, not readable, not discoverable, with no frame
    /// this app can send to undo it. The repo's own 2026-08-07 findings close
    /// the other two routes as well, since Addressed mode is refused by nfcd on
    /// both APIs and non-addressed mode is ignored by the silicon
    /// (`docs/internal/chip-config-pages.md`).
    ///
    /// So the option is gone from this card rather than left to fail at the
    /// frame. Arming a gate the app cannot open is precisely what the
    /// typed-UID Dangerous Action flow exists for, and that is where it belongs
    /// when it returns, with copy that says the tag will stop being discoverable.
    private var type5Fields: some View {
        Section {
            HexHexField(label: "Password (4 bytes)", hex: $passwordHex, expectedBytes: 4)
        } header: {
            Text("Password")
        } footer: {
            Text(
                "Sets the SLIX2 write password. Reads stay open. Lose the password and the protected memory can't be rewritten: there is no recovery, because a SLIX2 password can only be reset by presenting the current one."
            )
        }
    }

    private var ultralightCFields: some View {
        Section {
            Picker("Key", selection: $keyEntry.animation()) {
                ForEach(KeyEntry.allCases) { entry in
                    Text(entry.label).tag(entry)
                }
            }
            .pickerStyle(.segmented)

            switch keyEntry {
            case .generate:
                HexHexField(label: "Key (16 bytes)", hex: $keyHex, expectedBytes: 16)
                    .disabled(true)
                Button("Generate a new key") { keyHex = Self.randomHex(16) }
                    .foregroundStyle(HexTokens.Color.primaryLight)
                    .accessibilityIdentifier("protection.generateKey")

            case .paste:
                HexHexField(label: "Key (16 bytes)", hex: $keyHex, expectedBytes: 16)

            case .passphrase:
                SecureField("Passphrase", text: $passphrase)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text(
                    "The same passphrase always produces the same key, so you can protect a whole stack of tags without storing anything. Anyone who guesses the passphrase gets the key, so make it long."
                )
                .font(HexTokens.Font.footnote)
                .foregroundStyle(HexTokens.Color.textSecondary)
            }

            // "Read + write" used to sit here as an ordinary segmented choice.
            // On an Ultralight C a read gate covers pages 28h-2Bh, which are the
            // pages `ChipCatalog.identify` reads to recognise the chip, so a tag
            // armed that way stops being identifiable and the app can never offer
            // to unlock it. The gate is reversible on the silicon and not by us,
            // which is the worst of both. Same decision, and the same reasoning,
            // as SLIX2 privacy mode: `UltralightCProtectionDriver.enable` now
            // refuses a read gate without an explicit opt-in, and this card no
            // longer offers one.
            Text(
                "Write protection only. Hex NFC does not offer a read gate on these tags: a read-protected Ultralight C hides the pages Hex NFC identifies the chip from, so the app could no longer recognise the tag or offer to unlock it, even with the right key."
            )
            .font(HexTokens.Font.footnote)
            .foregroundStyle(HexTokens.Color.textSecondary)
        } header: {
            Text("3DES key")
        } footer: {
            Label(
                "Lose this key and the protected memory can never be rewritten. Ultralight C has no factory reset. Store it safely.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(HexTokens.Font.footnote)
            .foregroundStyle(HexTokens.Color.dangerText)
        }
    }

    // MARK: - Copy

    private var toggleTitle: LocalizedStringKey {
        family == .type4 || family == .ultralightC
            ? "Protect this tag with a key"
            : "Password-protect this tag"
    }

    private var toggleFooter: LocalizedStringKey {
        // Switching this off on a tag that arrived protected is a *removal*, and
        // the sheet used to describe it with the same copy it uses to offer
        // protection in the first place. Worse, turning it off hides the
        // read-protect switch, which reads as "the read lock is still there and
        // you just lost the control for it". One bit governs both, so say so.
        if !passwordProtect, editModel.originalProtection.passwordProtect {
            return removalFooter
        }
        switch family {
        case .type2: return "Require a 4-byte password to write to this tag. Apply it as part of the next write: and reuse it across many tags by saving it with a preset."
        case .type4: return "Gate this tag behind a 16-byte AES key. Applied as part of the next write; reuse it across tags by saving it with a preset."
        case .type5: return "Require a 4-byte password to write to this tag (ICODE SLIX). Applied as part of the next write."
        case .ultralightC: return "Gate this tag behind a 16-byte 3DES key (MIFARE Ultralight C). Applied as part of the next write; reuse it across tags by saving it with a preset."
        }
    }

    /// What turning the switch off actually does, named in full.
    private var removalFooter: LocalizedStringKey {
        switch family {
        case .type2, .type5:
            "Removes this tag's protection on the next write. Both locks go: the tag can be read and written by anyone afterwards, and the password returns to its factory default. You'll need the current password to do it."

        case .type4:
            "Removes this tag's protection on the next write. Both locks go: the tag can be read and written by anyone afterwards, and the key returns to its factory default. You'll need the current key to do it."

        case .ultralightC:
            "Removes this tag's protection on the next write. Both locks go: the tag can be read and written by anyone afterwards, and the key returns to its factory default. You'll need the current key to do it. If some other app has read-protected this tag, Hex NFC cannot remove it: a read-protected Ultralight C hides the pages the chip is identified from."
        }
    }

    // MARK: - Validation + commit

    /// Whether pressing Done now would make the next write ask for the tag's ID.
    ///
    /// Mirrors what `TagEditorSheet` builds and `WriteFlowModel` then decides:
    /// a write is gated when it arms protection (a credential in hand, which is
    /// what `pendingProtection()` requires) or removes it.
    ///
    /// Two things it deliberately is not. It is not the toggle, which is already
    /// on for a tag that merely arrived protected: leave it on with no password
    /// typed and the next write changes no protection state, so the sentence
    /// would be a false statement about the most ordinary protected tag there
    /// is. And it is not `editModel.hasProtectionChange`, which cannot see the
    /// protection being configured here until `commit()` runs, so it would hide
    /// the sentence on every first arm.
    private var confirmsTagBeforeWriting: Bool {
        if !passwordProtect, editModel.originalProtection.passwordProtect {
            return true
        }
        return passwordProtect && canSave
    }

    private var canSave: Bool {
        guard passwordProtect else { return true }
        switch family {
        case .type2: return Data.parseHex(passwordHex)?.count == 4 && Data.parseHex(packHex)?.count == 2
        case .type4: return Data.parseHex(keyHex)?.count == 16
        case .type5: return Data.parseHex(passwordHex)?.count == 4
        case .ultralightC: return resolvedUltralightCKey() != nil
        }
    }

    /// The key the sheet would commit, or `nil` if the current entry is not yet
    /// usable. One function so validation and commit can never disagree about
    /// what counts as ready.
    private func resolvedUltralightCKey() -> UltralightCKey? {
        switch keyEntry {
        case .generate, .paste:
            guard let bytes = Data.parseHex(keyHex) else { return nil }
            return try? UltralightCKey(cipherOrder: bytes)

        case .passphrase:
            return try? UltralightCKeyDerivation.key(from: passphrase)
        }
    }

    private func commit() {
        var settings = TagProtection()
        settings.passwordProtect = passwordProtect

        switch family {
        case .type2:
            // Keep flat fields + style == nil so Type-2 JSON stays byte-identical.
            settings.readProtect = readProtect
            // A read gate covers the whole data area or nothing. The app can
            // only recognise a read-gated Type-2 tag when AUTH0 is the first
            // data page, because recognition is the roll-over in one `30 03`;
            // from any other start page the driver reads a NAK, throws before
            // presenting a password, and this app can never unlock, rewrite or
            // unprotect that tag again. The fields above do not offer the
            // combination, and `ProtectionSpec.make` pins it for every row that
            // never came through this card. Writing `nil` here keeps the
            // settings object honest about what the write will actually do.
            settings.protectFromPage = customStartPage && !readProtect ? startPage : nil
            // Normalised, not merely left at its default.
            //
            // A preset row written before the attempt limit became a standalone
            // Dangerous Action can still hold a non-zero value. It cannot reach
            // the ACCESS byte from here: `ProtectionSpec.make` passes
            // `authLimit: 0` unconditionally and ignores `TagProtection.authLimit`,
            // and that funnel, not this line, is where the rule is structural.
            // What writing 0 here adds is that the settings object this sheet
            // produces stops carrying a value the app will never honour, so a
            // legacy limit no longer rides along in the preset row, in a `.hexnfc`
            // export, or through iCloud sync. Opening the card on such a preset
            // and pressing Done clears it; a row that reaches a tag without the
            // card ever being opened is laundered by `ProtectionSpec.make`.
            settings.authLimit = 0
            var credential: TagCredential?
            if passwordProtect,
               let password = Data.parseHex(passwordHex), password.count == 4,
               let pack = Data.parseHex(packHex), pack.count == 2
            {
                credential = .type2(password: password, pack: pack)
            }
            settings.hasStoredCredential = credential != nil
            editModel.protection = settings
            // Only ever *set* a credential here, never clear one.
            //
            // `credential` is nil whenever the protection toggle is off, and
            // switching the toggle off is precisely the moment the removal that
            // needs the credential is being requested. Assigning nil destroyed
            // the only in-memory copy on the way to asking for it, which is why
            // turning protection off in the same session that turned it on was
            // a silent no-op.
            if let credential {
                editModel.protectionCredential = credential
            }

        case .type4:
            settings.style = .type4(.init(keySlot: 0, readProtect: readProtect))
            var credential: TagCredential?
            if passwordProtect, let key = Data.parseHex(keyHex), key.count == 16 {
                credential = .type4(aesKey: key, keySlot: 0)
            }
            settings.hasStoredCredential = credential != nil
            editModel.protection = settings
            // Only ever *set* a credential here, never clear one.
            //
            // `credential` is nil whenever the protection toggle is off, and
            // switching the toggle off is precisely the moment the removal that
            // needs the credential is being requested. Assigning nil destroyed
            // the only in-memory copy on the way to asking for it, which is why
            // turning protection off in the same session that turned it on was
            // a silent no-op.
            if let credential {
                editModel.protectionCredential = credential
            }

        case .type5:
            // Always `.write`: the card no longer offers a read gate, because
            // arming one on a SLIX2 arms privacy mode and iOS cannot discover a
            // privacy-mode tag afterwards. See `type5Fields`.
            let kind: ProtectionStyle.Type5Settings.Kind = .write
            settings.style = .type5(.init(kind: kind))
            var credential: TagCredential?
            if passwordProtect, let password = Data.parseHex(passwordHex), password.count == 4 {
                credential = .type5(password: password, kind: kind)
            }
            settings.hasStoredCredential = credential != nil
            editModel.protection = settings
            // Only ever *set* a credential here, never clear one.
            //
            // `credential` is nil whenever the protection toggle is off, and
            // switching the toggle off is precisely the moment the removal that
            // needs the credential is being requested. Assigning nil destroyed
            // the only in-memory copy on the way to asking for it, which is why
            // turning protection off in the same session that turned it on was
            // a silent no-op.
            if let credential {
                editModel.protectionCredential = credential
            }

        case .ultralightC:
            // Normalised, not merely left at its default. The card no longer
            // offers a read gate, but a preset row written before that, or one
            // arriving in a `.hexnfc` import, can still carry `readProtect: true`.
            // Left alone it would reach `UltralightCProtectionDriver.enable`,
            // which now refuses it, and the user would meet an error with no
            // control on screen to clear. Writing false here corrects the row on
            // the way past instead. The driver guard stays as the backstop for
            // every path that does not come through this sheet.
            settings.style = .ultralightC(.init(
                protectFromPage: customStartPage ? startPage : nil,
                readProtect: false
            ))
            var credential: TagCredential?
            if passwordProtect, let key = resolvedUltralightCKey() {
                credential = .ultralightC(key: key)
            }
            settings.hasStoredCredential = credential != nil
            editModel.protection = settings
            // Only ever *set* a credential here, never clear one.
            //
            // `credential` is nil whenever the protection toggle is off, and
            // switching the toggle off is precisely the moment the removal that
            // needs the credential is being requested. Assigning nil destroyed
            // the only in-memory copy on the way to asking for it, which is why
            // turning protection off in the same session that turned it on was
            // a silent no-op.
            if let credential {
                editModel.protectionCredential = credential
            }
        }
    }

    // MARK: - Helpers

    /// The configured AUTH0, from whichever family stores it. `nil` for the
    /// families that have no such knob (Type-4 gates a whole file; Type-5 gates
    /// by password kind).
    private static func startPage(in protection: TagProtection) -> Int? {
        switch protection.effectiveStyle {
        case .type2(let s): s.protectFromPage
        case .ultralightC(let s): s.protectFromPage
        case .type4, .type5: nil
        }
    }

    private static func family(for editModel: EditFlowModel) -> Family {
        (editModel.tag?.protectionStyle ?? .type2(.init())).family
    }

    private static func randomHex(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).hexString
    }
}
#endif
