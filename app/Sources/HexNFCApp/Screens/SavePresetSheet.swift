#if os(iOS)
import HexNFCDesign
import HexNFCKit
import HexNFCRecords
import HexNFCShaders
import HexNFCStorage
import SwiftUI

/// "Save as preset" sheet. Captures a name, optional notes, and an icon
/// hex-slice (0/1/2 → outer frame / caret / inverted caret). Calls
/// `LibraryRepository.insertPreset(...)` on submit, persisting protection
/// *settings* with the preset and the secret (PWD/PACK) into the Keychain.
struct SavePresetSheet: View {
    let records: [NDEFRecord]
    /// Protection settings carried from the editor (password-only; never lock).
    var protection: TagProtection = .none
    /// In-memory secret to stash in the Keychain, if protection is configured.
    /// Family-tagged (Type-2 PWD+PACK / Type-4 AES key / Type-5 password).
    var credential: TagCredential?
    let library: LibraryRepository
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var notes: String = ""
    @State private var iconSlice: Int = 0
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                // Both fields are named only by their section header, which is a
                // separate element, so VoiceOver fell back to the prompt and
                // announced this one as "Office Wi-Fi, Front-desk vCard" (a sample
                // value, not the field's name). Label the fields; the headers stay
                // audible as headers.
                Section("Name") {
                    TextField("Office Wi-Fi, Front-desk vCard, …", text: $name)
                        .accessibilityLabel(Text("Name"))
                }
                Section("Notes") {
                    TextField("Optional", text: $notes, axis: .vertical)
                        .lineLimit(1 ... 4)
                        .accessibilityLabel(Text("Notes"))
                }
                Section("Icon") {
                    Picker("Slice", selection: $iconSlice) {
                        Text("Outer frame").tag(0)
                        Text("Caret up").tag(1)
                        Text("Caret down").tag(2)
                    }
                    .pickerStyle(.segmented)
                }
                Section("Records") {
                    if records.isEmpty, protection.passwordProtect {
                        Text("No records. This preset only applies protection.")
                            .font(HexTokens.Font.footnote)
                            .foregroundStyle(HexTokens.Color.textSecondary)
                    } else {
                        Text("^[\(records.count) record](inflect: true) will be stored.")
                            .font(HexTokens.Font.footnote)
                            .foregroundStyle(HexTokens.Color.textSecondary)
                    }
                    if holdsLocationWithNowhereToPoint {
                        Label {
                            Text(
                                "A location record has no coordinates or map URL, so this preset could never be written to a tag. Fill it in or delete it on the Tag screen, then save."
                            )
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(HexTokens.Color.warning)
                        }
                        .font(HexTokens.Font.footnote)
                        .foregroundStyle(HexTokens.Color.textSecondary)
                    }
                }
                if protection.passwordProtect {
                    Section("Protection") {
                        Label(protectionSummary, systemImage: "lock.fill")
                            .font(HexTokens.Font.footnote)
                            .foregroundStyle(HexTokens.Color.textSecondary)
                        Text(
                            "The secret is stored only on this device (Keychain). It never syncs or travels in an export."
                        )
                        .font(HexTokens.Font.footnote)
                        .foregroundStyle(HexTokens.Color.textSecondary)
                    }
                }
                if let error {
                    Section {
                        Text(error)
                            .font(HexTokens.Font.footnote)
                            .foregroundStyle(HexTokens.Color.dangerText)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(HexTokens.Color.surface0.ignoresSafeArea())
            .navigationTitle(Text("Save as preset"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(HexTokens.Color.textSecondary)
                        .hexPressHaptic()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        // A tint so `.disabled` can grey it; see the editor's
                        // Write button for why a fixed colour cannot.
                        .tint(HexTokens.Color.primaryLight)
                        .hexPressHaptic()
                        .disabled(!canSave)
                        .accessibilityIdentifier("savePreset.save")
                }
            }
            .toolbarBackground(HexTokens.Color.surface0, for: .navigationBar)
            .preferredColorScheme(.dark)
        }
    }

    private var canSave: Bool {
        // A preset is worth saving when it carries records *or* a protection
        // configuration — a protection-only preset (e.g. "lock a stack of blank
        // tags") writes empty NDEF then applies protection, which the write flow
        // already supports.
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard !holdsLocationWithNowhereToPoint else { return false }
        return !records.isEmpty || protection.passwordProtect
    }

    /// Whether the list holds a location the write flow refuses to put on a
    /// tag. A saved preset cannot be changed, so saving one would keep a
    /// preset that every write refuses; the Tag screen, where the record can
    /// still be filled in, is the place to deal with it. By the same rule as
    /// the refusal, so the two cannot disagree.
    private var holdsLocationWithNowhereToPoint: Bool {
        WriteFlowModel.locationsWithNowhereToPoint(in: .replace(records)) != nil
    }

    private var protectionSummary: String {
        let mode = protection.effectiveReadProtect
            ? String(localized: "read + write")
            : String(localized: "write-only")
        // Per-style, for the same reason the editor's Protection card is: two
        // families protect with a 16-byte key and they are different ciphers, so
        // a preset the user will reuse across a stack of tags has to say which
        // secret it holds. "Password protection" on an Ultralight C preset was
        // simply wrong — it holds a 3DES key.
        switch protection.effectiveStyle {
        case .type4: return String(localized: "AES key protection (\(mode))")
        case .ultralightC: return String(localized: "3DES key protection (\(mode))")
        case .type2, .type5: return String(localized: "Password protection (\(mode))")
        }
    }

    private func save() {
        do {
            // Only persist a credential when protection is on AND we hold a
            // valid secret; the repo flips `hasStoredCredential` accordingly.
            let storedCredential: ProtectionCredential? = if protection.passwordProtect, let credential {
                Self.storageCredential(from: credential)
            } else {
                nil
            }
            // Record the capability the tag will actually need. An Ultralight C
            // preset requires `.tripleDESAuth`; stamping `.passwordAuth` on it
            // would describe a chip that cannot apply this preset at all. Inert
            // today (nothing reads the field yet), but it is persisted, so a
            // wrong value outlives the release that wrote it.
            var requiredCaps: UInt32 = 0
            if protection.passwordProtect {
                switch protection.effectiveStyle {
                case .ultralightC: requiredCaps |= TagCapability.tripleDESAuth.rawValue
                case .type2, .type4, .type5: requiredCaps |= TagCapability.passwordAuth.rawValue
                }
            }

            _ = try library.insertPreset(
                name: name.trimmingCharacters(in: .whitespaces),
                records: records,
                notes: notes.trimmingCharacters(in: .whitespaces),
                requiredCapabilitiesRaw: requiredCaps,
                iconHexSlice: iconSlice,
                protection: protection.passwordProtect ? protection : nil,
                credential: storedCredential
            )
            HexHeroMoment.commit.play()
            onSaved()
            dismiss()
        } catch {
            self.error = "Could not save: \(error.localizedDescription)"
        }
    }

    /// Map the kit's family-tagged `TagCredential` onto the Keychain storage
    /// shape. (The App layer is the only place that sees both modules.)
    private static func storageCredential(from credential: TagCredential) -> ProtectionCredential {
        switch credential {
        case .type2(let password, let pack):
            return ProtectionCredential(password: password, pack: pack)

        case .type4(let aesKey, let keySlot):
            return ProtectionCredential(aesKey: aesKey, keySlot: UInt8(keySlot & 0xFF))

        case .type5(let password, let kind):
            let write: Data? = (kind == .write || kind == .readWrite) ? password : nil
            let read: Data? = (kind == .read || kind == .readWrite) ? password : nil
            return ProtectionCredential(slixWrite: write, slixRead: read)

        case .ultralightC(let key):
            // Cipher order, matching what the user typed and what the datasheet
            // quotes. `UltralightCKey` derives the memory order at write time.
            return ProtectionCredential(ultralightCKey: key.cipherOrder)
        }
    }
}
#endif
