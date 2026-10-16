@testable import HexNFCApp
@testable import HexNFCKit
@testable import HexNFCRecords
import HexNFCStorage
@testable import HexNFCTagSim
import XCTest

/// Guards the gate that decides whether the app offers protection at all, and
/// the copy that tells the user which secret to bring back.
///
/// Every one of these covers a path that shipped broken because the gate was
/// spelled `capabilities.contains(.passwordAuth) && protectionStyle != nil`
/// instead of `protectionStyle != nil`. The two read as equivalent, and are,
/// for every chip except the one the exception exists for. MIFARE Ultralight C
/// authenticates with a 16-byte 3DES key and therefore declares
/// `.tripleDESAuth`, deliberately *not* `.passwordAuth` (the credential shapes
/// are not interchangeable), so anding the capability in re-excluded it and
/// made the entire Ultralight C protection feature unreachable from the UI.
final class ProtectionAffordanceTests: XCTestCase {
    // MARK: - The gate itself

    /// A scanned Ultralight C must report that it takes protection, and report
    /// the *3DES* backend. This is what makes the editor show its Protection
    /// card and open the key sheet rather than a 4-byte password field.
    @MainActor
    func test_scannedUltralightC_offersProtection_withThe3DESBackend() async throws {
        let model = ScanFlowModel(factory: SimulatedSessionFactory(makeChip: { MifareUltralightCSimulator() }))

        await model.begin()

        XCTAssertEqual(model.phase, .ready)
        let info = try XCTUnwrap(model.scannedTagInfo)
        XCTAssertEqual(info.chipName, "MIFARE Ultralight C")
        XCTAssertTrue(
            info.supportsPasswordProtection,
            "an Ultralight C takes a 3DES key; hiding the Protection card makes the feature unreachable"
        )
        guard case .ultralightC? = info.protectionStyle else {
            return XCTFail("expected the Ultralight C backend, got \(String(describing: info.protectionStyle))")
        }
    }

    /// The chips that were never broken must stay exactly as they were: the
    /// widened gate must not start offering protection where no backend exists.
    @MainActor
    func test_protectionGate_unchangedForEveryOtherFamily() async {
        // NTAG213: Type-2 PWD/PACK backend.
        let ntag = ScanFlowModel(factory: SimulatedSessionFactory(makeChip: { NTAG213Simulator() }))
        await ntag.begin()
        XCTAssertEqual(ntag.scannedTagInfo?.supportsPasswordProtection, true)
        guard case .type2? = ntag.scannedTagInfo?.protectionStyle else {
            return XCTFail("NTAG213 should resolve the Type-2 backend")
        }

        // A DESFire has no protection backend in this app; the affordance must
        // stay hidden rather than offering a sheet that can't apply anything.
        let desfire = ScanFlowModel(factory: SimulatedSessionFactory(makeChip: { DESFireEV3Simulator() }))
        await desfire.begin()
        XCTAssertEqual(desfire.scannedTagInfo?.supportsPasswordProtection, false)
        XCTAssertNil(desfire.scannedTagInfo?.protectionStyle)
    }

    // MARK: - The write path

    /// The end-to-end proof: configure a 3DES key in the editor, write, and the
    /// tag comes back actually protected. The pre-write guard in `WriteFlowModel`
    /// carried the same `.passwordAuth` mistake, so this used to throw
    /// `capabilityUnsupported`, *after* the records were written, which is the
    /// exact strand that guard exists to prevent.
    @MainActor
    func test_writeFlow_appliesUltralightC3DESProtection() async throws {
        // Seeded with a message so the fixture is a *formatted* Ultralight C. A
        // factory one ships with page 3 blank (rev 3.3 Table 13) and can't carry
        // a readable NDEF message at all. That state is covered separately by
        // `UnformattedTagTests`.
        let simulator = try MifareUltralightCSimulator(
            ndefMessage: NDEFCodec.encode([.text(TextRecord(text: "seed"))])
        )
        let key = try UltralightCKey(cipherOrder: Data((0 ..< 16).map { UInt8(0xA0 + $0) }))
        var settings = TagProtection()
        settings.passwordProtect = true
        settings.style = .ultralightC(.init(protectFromPage: nil, readProtect: false))
        settings.hasStoredCredential = true

        let model = WriteFlowModel(
            factory: SingleChipFactory(chip: simulator),
            dataArea: .replace([.text(TextRecord(text: "ulc"))]),
            credentials: InMemoryTagCredentialStore(),
            protection: PendingProtection(settings: settings, credential: .ultralightC(key: key)),
            uidConfirmation: .required
        )
        await beginConfirmingUID(model)

        guard case .done = model.phase else {
            return XCTFail("expected the write to complete, got \(model.phase)")
        }
        let state = try XCTUnwrap(try simulator.readProtectionState())
        XCTAssertTrue(state.passwordProtect, "the tag should be gated after the write")
    }

    /// **The editor's own wiring, which neither family had ever survived.**
    ///
    /// `TagEditorSheet` hands the write flow `editModel.protectionCredential`,
    /// which on a first protect is the credential about to be WRITTEN. Type-2
    /// is safe from it because its driver reads state before presenting
    /// anything. Type-5 and Ultralight C presented it blind: a SLIX2 stops
    /// answering until an RF reset after a refused SET_PASSWORD (SL2S2602
    /// §9.5.3.2) and an Ultralight C halts on the NAK, so the arm dead-ended at
    /// "didn't unlock" on a tag that had nothing to unlock, every time. The
    /// drivers themselves were fine, which is why the harness passed on silicon
    /// on 2026-09-20 while this route could not arm a tag at all.
    ///
    /// The second half is `replacing:`. It means "the credential this tag is
    /// answering to now", and passing the new one made `enable` present it as
    /// the current password.
    @MainActor
    func test_writeFlow_protectingAFreshUltralightC_withTheNewKeyAlsoSeededAsTheUnlockCredential() async throws {
        let simulator = try MifareUltralightCSimulator(
            ndefMessage: NDEFCodec.encode([.text(TextRecord(text: "seed"))])
        )
        let key = try UltralightCKey(cipherOrder: Data((0 ..< 16).map { UInt8(0xA0 + $0) }))
        var settings = TagProtection()
        settings.passwordProtect = true
        settings.style = .ultralightC(.init(protectFromPage: nil, readProtect: false))
        settings.hasStoredCredential = true
        let model = WriteFlowModel(
            factory: SingleChipFactory(chip: simulator),
            dataArea: .replace([.text(TextRecord(text: "ulc"))]),
            credentials: InMemoryTagCredentialStore(),
            protection: PendingProtection(settings: settings, credential: .ultralightC(key: key)),
            // What the editor passes.
            unlockCredential: .ultralightC(key: key),
            uidConfirmation: .required
        )

        await beginConfirmingUID(model)

        guard case .done = model.phase else {
            return XCTFail("a fresh tag has nothing to unlock, got \(model.phase)")
        }
        XCTAssertFalse(model.unlockFailed, "nothing here refused a credential")
        let state = try XCTUnwrap(try simulator.readProtectionState())
        XCTAssertTrue(state.passwordProtect, "the tag must end up gated")
    }

    @MainActor
    func test_writeFlow_protectingAFreshSlix2_withTheNewPasswordAlsoSeededAsTheUnlockCredential() async {
        let chip = Iso15693Simulator(blockCount: 80)
        let password = Data([0x11, 0x22, 0x33, 0x44])
        var settings = TagProtection()
        settings.passwordProtect = true
        settings.style = .type5(.init(kind: .write))
        settings.hasStoredCredential = true
        let model = WriteFlowModel(
            factory: SingleChipFactory(chip: chip),
            dataArea: .replace([.text(TextRecord(text: "slix"))]),
            credentials: InMemoryTagCredentialStore(),
            protection: PendingProtection(
                settings: settings, credential: .type5(password: password, kind: .write)
            ),
            unlockCredential: .type5(password: password, kind: .write),
            uidConfirmation: .required
        )

        await beginConfirmingUID(model)

        guard case .done = model.phase else {
            return XCTFail("a fresh SLIX2 has nothing to unlock, got \(model.phase)")
        }
        XCTAssertFalse(model.unlockFailed)
    }

    // MARK: - Rebuilding from history

    /// Re-opening a history row must recover the same backend the live scan
    /// resolved. Without it the row showed a tag marked protected with no
    /// Protection card to manage it, because `ScannedTagInfo` defaulted the two
    /// protection fields to `false`/`nil`.
    func test_historyRebuild_recoversTheProtectionBackend() throws {
        let ulc = try XCTUnwrap(ChipCatalog.profile(for: .mifareUltralightC))
        guard case .ultralightC? = ScannedTagInfo.protectionStyle(
            forChipNamed: ulc.displayName, capabilitiesRaw: ulc.capabilities.rawValue
        ) else {
            return XCTFail("an Ultralight C history row should recover the 3DES backend")
        }

        let ntag = try XCTUnwrap(ChipCatalog.profile(for: .ntag216))
        guard case .type2? = ScannedTagInfo.protectionStyle(
            forChipNamed: ntag.displayName, capabilitiesRaw: ntag.capabilities.rawValue
        ) else {
            return XCTFail("an NTAG216 history row should recover the Type-2 backend")
        }

        // A row whose chip we can never name resolves nothing. Hiding the
        // affordance is right; guessing Type-2 at an unknown chip is not.
        XCTAssertNil(ScannedTagInfo.protectionStyle(forChipNamed: nil, capabilitiesRaw: 0xFFFF))
        XCTAssertNil(ScannedTagInfo.protectionStyle(forChipNamed: "Not A Chip", capabilitiesRaw: 0xFFFF))
    }

    // MARK: - Unlock vocabulary

    /// Two families use a 16-byte key and they are different ciphers. Every
    /// user-facing string that names one has to name the right one, or a user
    /// holding both an NTAG424 and an Ultralight C is told to paste the wrong
    /// secret.
    func test_unlockVocabulary_namesTheCipherPerFamily() {
        XCTAssertEqual(ProtectionStyle.type4(.init()).unlockSecretByteCount, 16)
        XCTAssertEqual(ProtectionStyle.ultralightC(.init()).unlockSecretByteCount, 16)
        XCTAssertTrue(ProtectionStyle.ultralightC(.init()).unlockSecretIsKey)
        XCTAssertEqual(ProtectionStyle.type2(.init()).unlockSecretByteCount, 4)
        XCTAssertEqual(ProtectionStyle.type5(.init()).unlockSecretByteCount, 4)

        // The bytes a user pastes are cipher-order, and must build the matching
        // family's credential, not a Type-2 password.
        let bytes = Data((0 ..< 16).map { UInt8($0) })
        guard case .ultralightC? = ProtectionStyle.ultralightC(.init()).unlockCredential(from: bytes) else {
            return XCTFail("Ultralight C should build a 3DES credential")
        }
        guard case .type4? = ProtectionStyle.type4(.init()).unlockCredential(from: bytes) else {
            return XCTFail("NTAG424 should build an AES credential")
        }
        XCTAssertNil(
            ProtectionStyle.ultralightC(.init()).unlockCredential(from: Data([0x01, 0x02, 0x03, 0x04])),
            "a 4-byte entry is not a 3DES key and must not be accepted"
        )
    }

    // MARK: - What a scan already knew and never showed

    /// `capabilitySummary` never mentioned 3DES, so an Ultralight C's card said
    /// nothing at all about how the chip authenticates.
    func test_capabilitySummary_namesTheCipherForA3DESChip() throws {
        let ulc = try XCTUnwrap(ChipCatalog.profile(for: .mifareUltralightC))
        let summary = ScannedTagInfo.capabilitySummary(fromRaw: ulc.capabilities.rawValue)
        XCTAssertEqual(summary?.contains("3DES key"), true, "got \(summary ?? "nil")")
        XCTAssertEqual(summary?.contains("Password"), false, "a 3DES key is not a password")
    }

    /// The values, not just the capability: a real scan must come back with the
    /// signature, the counter reading and the tamper state, and carry them into
    /// the snapshot the card renders from.
    @MainActor
    func test_scanCollectsDiagnosticValues_andCarriesThemToTheCard() async throws {
        let model = ScanFlowModel(factory: SimulatedSessionFactory(makeChip: { NTAG213TTSimulator() }))

        await model.begin()

        XCTAssertEqual(model.phase, .ready)
        let info = try XCTUnwrap(model.scannedTagInfo)
        XCTAssertEqual(info.diagnostics.originalitySignature?.count, 32)
        XCTAssertEqual(info.diagnostics.tamper, .intact)
        XCTAssertNotNil(info.diagnostics.tapCount)
    }

    /// A chip with nothing to report leaves the section empty rather than
    /// rendering blank rows.
    @MainActor
    func test_chipWithNoDiagnostics_reportsNothing() async throws {
        let model = ScanFlowModel(factory: SimulatedSessionFactory(makeChip: {
            MifareUltralightCSimulator(ndefMessage: try? NDEFCodec.encode([.text(TextRecord(text: "x"))]))
        }))

        await model.begin()

        XCTAssertTrue(try XCTUnwrap(model.scannedTagInfo).diagnostics.isEmpty)
    }

    /// Diagnostics describe the tag in the field right now, so they must not
    /// leak from one scan into the next.
    @MainActor
    func test_diagnosticsClearOnReset() async {
        let model = ScanFlowModel(factory: SimulatedSessionFactory(makeChip: { NTAG213TTSimulator() }))
        await model.begin()
        XCTAssertFalse(model.diagnostics.isEmpty)

        model.reset()

        XCTAssertTrue(model.diagnostics.isEmpty)
    }

    /// The silicon features identification establishes and the card used to drop
    /// on the floor. These are what tell otherwise-similar chips apart.
    func test_featureSummary_surfacesSignatureCounterAndTamper() throws {
        let tt = try ScannedTagInfo.featureSummary(
            fromRaw: XCTUnwrap(ChipCatalog.profile(for: .ntag213TT)?.capabilities.rawValue)
        )
        XCTAssertEqual(tt?.contains("Tamper loop"), true, "got \(tt ?? "nil")")
        XCTAssertEqual(tt?.contains("Originality signature"), true)
        XCTAssertEqual(tt?.contains("Tap counter"), true)

        // A plain NTAG213 has the signature and counter but no tamper loop,
        // the difference is the whole point of showing the row.
        let plain = try ScannedTagInfo.featureSummary(
            fromRaw: XCTUnwrap(ChipCatalog.profile(for: .ntag213)?.capabilities.rawValue)
        )
        XCTAssertEqual(plain?.contains("Tamper loop"), false, "got \(plain ?? "nil")")

        // An Ultralight C has none of them (rev 3.3 Table 14 is exhaustive), so
        // the row must not render at all rather than showing an empty label.
        XCTAssertNil(try ScannedTagInfo.featureSummary(
            fromRaw: XCTUnwrap(ChipCatalog.profile(for: .mifareUltralightC)?.capabilities.rawValue)
        ))
    }

    // MARK: A records-free preset arms without clearing

    /// The editor's Save menu offers "a preset that just locks tags", and the
    /// Library route wrote its empty message over the tag on the way to arming
    /// it. `records: []` and "leave the data area alone" were the same value
    /// meaning opposite things; `DataAreaChange` gave them different names and
    /// this is the one call site where the distinction reaches a tag.
    func test_aRecordFreePresetArmsTheTagWithoutClearingIt() {
        XCTAssertEqual(
            DataAreaChange.forPreset(records: [], arming: true), .untouched,
            "a preset with nothing to write and a gate to arm was never about the data area"
        )
    }

    /// The boundary the rule must not cross. Clearing a tag is an ordinary
    /// thing to keep a preset for, and answering `.untouched` for every
    /// records-free preset would turn a deliberate clear into a no-op.
    func test_anEmptyPresetWithNoProtectionStillClearsTheTag() {
        XCTAssertEqual(DataAreaChange.forPreset(records: [], arming: false), .replace([]))
    }

    /// A preset that carries records writes them, gate or no gate.
    func test_aPresetWithRecordsAlwaysWritesThem() {
        let records: [NDEFRecord] = [.uri(URIRecord(uri: "https://hex.pro"))]
        for arming in [true, false] {
            XCTAssertEqual(
                DataAreaChange.forPreset(records: records, arming: arming), .replace(records),
                "arming a tag is not a reason to skip the records the preset carries"
            )
        }
    }

    /// The rule is reached from the Library route, which lives in an
    /// `#if os(iOS)` file no test compiles. This is the line that joins them.
    func test_theLibraryRouteUsesThisRule() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/HexNFCApp/Screens/RootView.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(
            text.contains("dataArea: .forPreset(records: preset.decodedRecords(), arming: pending != nil),"),
            "the preset write must take its data-area decision from the rule above, not from a literal"
        )
        XCTAssertFalse(
            text.contains(".replace(preset.decodedRecords())"),
            "the unconditional replace is what cleared a tag nobody asked to clear"
        )
    }
}

/// Vends fresh sessions over one chip simulator, so a write and its verify-read
/// see the same memory.
private final class SingleChipFactory: TagSessionFactory, @unchecked Sendable {
    let chip: ChipSimulator
    init(chip: ChipSimulator) {
        self.chip = chip
    }

    func makeSession() -> TagSession {
        SimulatedSession(chip: chip)
    }
}
