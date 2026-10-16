@testable import HexNFCApp
@testable import HexNFCDesign
@testable import HexNFCKit
@testable import HexNFCRecords
import HexNFCStorage
@testable import HexNFCTagSim
import XCTest

final class HexNFCAppTests: XCTestCase {
    func test_moduleMarker() {
        XCTAssertEqual(HexNFCApp.moduleName, "HexNFCApp")
    }

    // MARK: - ScanFlowModel driven by the NTAG215 simulator

    @MainActor
    func test_scanFlow_idle_through_ready() async throws {
        let recordsOnTag: [NDEFRecord] = [
            .uri(URIRecord(uri: "https://hex.pro")),
            .text(TextRecord(text: "Hello NTAG215")),
        ]
        let envelope = try NDEFEnvelope.wrap(message: NDEFCodec.encode(recordsOnTag))
        let factory = SimulatedSessionFactory(makeChip: { NTAG215Simulator(ndefMessage: nil).preloading(envelope) })
        let model = ScanFlowModel(factory: factory)
        XCTAssertEqual(model.phase, .idle)

        await model.begin()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.records.count, 2)
        guard case .uri(let uri) = model.records[0] else { return XCTFail("first should be URI") }
        XCTAssertEqual(uri.uri, "https://hex.pro")
    }

    @MainActor
    func test_scanFlow_blankTag_readsZeroRecords_notError() async {
        // A factory-fresh NTAG213 (the first real tag from the Italy batch)
        // carries no NDEF records. A real chip reports this to CoreNFC as a
        // zero-length-message error (NFCError 403); the simulator models the
        // same state by returning empty NDEF data. Either backend, a blank tag
        // is a *successful* scan of zero records — it must reach `.ready` with
        // the chip still identified, never surface an error.
        let factory = SimulatedSessionFactory(makeChip: { NTAG213Simulator() })
        let model = ScanFlowModel(factory: factory)

        await model.begin()

        XCTAssertEqual(model.phase, .ready)
        XCTAssertTrue(model.records.isEmpty)
        XCTAssertEqual(model.detectedChipName, "NTAG213")
    }

    @MainActor
    func test_scanFlow_tagLost_setsErrorPhase() async {
        // We need to override behaviour — wrap the factory.
        let session = SimulatedSession(chip: NTAG215Simulator(), behaviour: .tagLost)
        let model = ScanFlowModel(factory: SingletonFactory(session: session))
        await model.begin()
        if case .error = model.phase {} else {
            XCTFail("expected error phase, got \(model.phase)")
        }
    }

    // MARK: - EditFlowModel dirty tracking

    @MainActor
    func test_editFlow_dirtyTracking_basic() {
        let record = NDEFRecord.text(TextRecord(text: "First"))
        let model = EditFlowModel(records: [record], origin: .build)
        XCTAssertFalse(model.isDirty)
        model.append(.uri(URIRecord(uri: "https://hex.pro")))
        XCTAssertTrue(model.isDirty)
        model.markClean()
        XCTAssertFalse(model.isDirty)
    }

    @MainActor
    func test_editFlow_removeByID() {
        let target = NDEFRecord.uri(URIRecord(uri: "https://hex.pro"))
        let model = EditFlowModel(records: [target, .text(TextRecord(text: "Keep"))], origin: .build)
        model.remove(id: target.id)
        XCTAssertEqual(model.records.count, 1)
        guard case .text = model.records[0] else { return XCTFail("expected text record to remain") }
    }

    @MainActor
    func test_editFlow_revert_restoresOriginal() {
        let original = NDEFRecord.text(TextRecord(text: "Pristine"))
        let model = EditFlowModel(records: [original], origin: .build)
        model.records[0] = .text(TextRecord(text: "Mutated"))
        XCTAssertTrue(model.isDirty)
        model.revert()
        XCTAssertFalse(model.isDirty)
    }

    @MainActor
    func test_editFlow_move_reordersInPlace() {
        let a = NDEFRecord.text(TextRecord(text: "A"))
        let b = NDEFRecord.text(TextRecord(text: "B"))
        let c = NDEFRecord.text(TextRecord(text: "C"))
        let model = EditFlowModel(records: [a, b, c], origin: .build)
        // Move A (index 0) to position 3 (after C).
        model.move(from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(model.records.map(\.id), [b.id, c.id, a.id])
    }

    // MARK: - WriteFlowModel round-trip

    @MainActor
    func test_writeFlow_writesAndVerifies() async {
        let simulator = NTAG215Simulator()
        // Same simulator instance reused across factory calls so the write
        // and the verify-read see consistent state.
        let factory = SingletonChipFactory(chip: simulator)
        let records: [NDEFRecord] = [.uri(URIRecord(uri: "https://hex.pro"))]
        let model = WriteFlowModel(
            factory: factory,
            dataArea: .replace(records),
            credentials: InMemoryTagCredentialStore(),
            uidConfirmation: .required
        )
        await model.begin()
        XCTAssertEqual(model.phase, .done, "expected .done, got \(model.phase)")
    }

    @MainActor
    func test_writeFlow_emptyWriteClearsTagAndVerifies() async throws {
        // Deleting every record then writing clears the tag — the same path as
        // the Erase operation (writeNDEF([])). The write flow must round-trip an
        // empty record set to `.done`, not fall over on the verify.
        let simulator = NTAG215Simulator()
        let factory = SingletonChipFactory(chip: simulator)

        // Seed a record so the clear is a real removal, not a no-op on a blank.
        let seed = WriteFlowModel(
            factory: factory,
            dataArea: .replace([.uri(URIRecord(uri: "https://hex.pro"))]),
            credentials: InMemoryTagCredentialStore(),
            uidConfirmation: .required
        )
        await seed.begin()
        XCTAssertEqual(seed.phase, .done, "seed write should succeed, got \(seed.phase)")

        let clear = WriteFlowModel(
            factory: factory,
            dataArea: .replace([]),
            credentials: InMemoryTagCredentialStore(),
            uidConfirmation: .required
        )
        await clear.begin()
        XCTAssertEqual(clear.phase, .done, "empty write should clear and verify, got \(clear.phase)")

        // The tag reads back as a single Empty record (`D0 00 00`) — the same
        // wire form CoreNFC writes for an empty message — which still counts as
        // an empty message. (A naive `== encode([])` byte compare would fail
        // here, which is exactly the real-hardware bug this guards.)
        let tag = try await SimulatedSession(chip: simulator).start(alert: "")
        let readBack = try await tag.readNDEF()
        XCTAssertEqual(
            readBack,
            Data([0xD0, 0x00, 0x00]),
            "cleared tag should echo the Empty record, got \(readBack.hexString)"
        )
        XCTAssertTrue(NDEFCodec.isEmptyMessage(readBack), "Empty record must read as an empty message")
        XCTAssertFalse(try readBack == (NDEFCodec.encode([])), "guards that the fix isn't a byte-equality compare")
        // And the scan card must show ZERO records for that Empty read-back — not
        // a phantom empty "Raw" entry. This is the exact decode path ScanFlowModel
        // takes; a blank formatted tag must look as empty as an unformatted one.
        XCTAssertEqual(try NDEFCodec.decode(readBack).count, 0, "blank tag must decode to zero user records")
    }

    @MainActor
    func test_blankTag_decodesToZeroRecords_acrossFamilies() async throws {
        // The phantom empty "Raw" record fix lives at the single shared decode
        // chokepoint, so it must hold for EVERY NDEF family, not just the NTAG the
        // bug was first seen on. Clear each family's tag and drive the exact
        // production read→decode path: a blank Type-2 (NTAG / Ultralight), Type-4
        // (NTAG424 DNA) and Type-5 (ICODE / ISO 15693) must all show zero records.
        // Genuinely unformatted tags read as zero bytes upstream; formatted-but-
        // empty ones read back as the `D0 00 00` Empty record — both must vanish.
        let families: [(String, ChipSimulator)] = [
            ("NTAG213 (Type-2)", NTAG213Simulator()),
            ("Ultralight EV1 (Type-2)", MifareUltralightEV1_48Simulator()),
            ("NTAG424 DNA (Type-4)", NTAG424DNASimulator()),
            ("ICODE SLIX (Type-5)", Iso15693Simulator()),
        ]
        for (name, simulator) in families {
            let tag = try await SimulatedSession(chip: simulator).start(alert: "")
            try await tag.writeNDEF([]) // clear → empty message
            let readBack = try await tag.readNDEF()
            XCTAssertTrue(
                NDEFCodec.isEmptyMessage(readBack),
                "\(name): cleared tag must read as an empty message, got \(readBack.hexString)"
            )
            XCTAssertEqual(
                try NDEFCodec.decode(readBack).count, 0,
                "\(name): blank tag must decode to zero records (no phantom Raw entry), got \(readBack.hexString)"
            )
        }
    }

    @MainActor
    func test_writeFlow_writesRecordsThenAppliesProtection() async throws {
        let simulator = NTAG215Simulator()
        let factory = SingletonChipFactory(chip: simulator)
        let pw = Data([0x11, 0x22, 0x33, 0x44])
        let pack = Data([0xAA, 0xBB])
        let model = WriteFlowModel(
            factory: factory,
            dataArea: .replace([.uri(URIRecord(uri: "https://hex.pro"))]),
            credentials: InMemoryTagCredentialStore(),
            protection: PendingProtection(
                settings: TagProtection(passwordProtect: true, protectFromPage: 4, readProtect: false, authLimit: 0),
                credential: .type2(password: pw, pack: pack)
            ),
            uidConfirmation: .required
        )
        // The write arms protection, so it confirms the tag's UID between two
        // taps (bench finding 19). `WriteConfirmationGateTests` is where that
        // shape is the subject; here it is a step on the way.
        await beginConfirmingUID(model)
        XCTAssertEqual(model.phase, .done, "expected .done, got \(model.phase)")

        // Records were written AND protection took: an unauthenticated write to
        // a protected page is now rejected.
        let tag = try await SimulatedSession(chip: simulator).start(alert: "")
        do {
            try await tag.writeMemory(at: 5 * 4, bytes: Data([0x00, 0x00, 0x00, 0x00]))
            XCTFail("unauthenticated write should be rejected after protection")
        } catch let error as TagError {
            guard case .authFailed = error.kind else { return XCTFail("wrong kind: \(error.kind)") }
        }
        XCTAssertEqual(try? simulator.authenticate(password: pw), pack)
    }

    @MainActor
    func test_writeFlow_protectionOnUnsupportedChip_errorsWithoutStrandingRecords() async {
        // An Unknown Type-2 chip lacks `.passwordAuth`; protection must be
        // refused *before* writing so no records are stranded on a tag we
        // can't protect.
        let factory = SingletonChipFactory(chip: UnknownType2Simulator())
        let model = WriteFlowModel(
            factory: factory,
            dataArea: .replace([.text(TextRecord(text: "x"))]),
            credentials: InMemoryTagCredentialStore(),
            protection: PendingProtection(
                settings: TagProtection(passwordProtect: true),
                credential: .type2(password: Data([0x11, 0x22, 0x33, 0x44]), pack: Data([0xAA, 0xBB]))
            ),
            uidConfirmation: .required
        )
        await model.begin()
        if case .error = model.phase {} else {
            XCTFail("expected .error for an unprotectable chip, got \(model.phase)")
        }
    }

    // MARK: - Writing to an already-protected tag (unlock-before-write)

    @MainActor
    func test_writeFlow_protectedTag_withoutPassword_promptsThenUnlocksAndWrites() async throws {
        // A tag locked elsewhere: we hold no password, so the write must stop
        // and prompt rather than NAK silently.
        let simulator = NTAG215Simulator()
        let pw = Data([0xCA, 0xFE, 0xBA, 0xBE])
        try simulator.enablePasswordProtection(
            password: pw, pack: Data([0x12, 0x34]), protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let model = WriteFlowModel(
            factory: SingletonChipFactory(chip: simulator),
            dataArea: .replace([.uri(URIRecord(uri: "https://hex.pro"))]),
            credentials: InMemoryTagCredentialStore(),
            uidConfirmation: .required
        )

        await model.begin()
        XCTAssertEqual(model.phase, .needsUnlock, "expected .needsUnlock, got \(model.phase)")
        XCTAssertFalse(model.unlockFailed, "no password was tried yet")

        // Supplying the correct password authenticates on the re-tap and writes.
        await model.unlock(with: .type2(password: pw, pack: Data()))
        XCTAssertEqual(model.phase, .done, "expected .done after unlock, got \(model.phase)")
    }

    @MainActor
    func test_writeFlow_protectedTag_withKnownPassword_writesInOneTap() async throws {
        let simulator = NTAG215Simulator()
        let pw = Data([0x01, 0x02, 0x03, 0x04])
        try simulator.enablePasswordProtection(
            password: pw, pack: Data([0xAA, 0xBB]), protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let model = WriteFlowModel(
            factory: SingletonChipFactory(chip: simulator),
            dataArea: .replace([.uri(URIRecord(uri: "https://hex.pro"))]),
            credentials: InMemoryTagCredentialStore(),
            unlockCredential: .type2(password: pw, pack: Data()),
            uidConfirmation: .required
        )
        await model.begin()
        XCTAssertEqual(model.phase, .done, "a held password should write in one tap, got \(model.phase)")
    }

    @MainActor
    func test_writeFlow_protectedTag_wrongPassword_promptsWithFailure() async throws {
        let simulator = NTAG215Simulator()
        try simulator.enablePasswordProtection(
            password: Data([0x01, 0x02, 0x03, 0x04]), pack: Data([0xAA, 0xBB]),
            protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let model = WriteFlowModel(
            factory: SingletonChipFactory(chip: simulator),
            dataArea: .replace([.uri(URIRecord(uri: "https://hex.pro"))]),
            credentials: InMemoryTagCredentialStore(),
            unlockCredential: .type2(password: Data([0xDE, 0xAD, 0xBE, 0xEF]), pack: Data()),
            uidConfirmation: .required
        )
        await model.begin()
        XCTAssertEqual(model.phase, .needsUnlock, "a wrong password should re-prompt, got \(model.phase)")
        XCTAssertTrue(model.unlockFailed, "the prompt should flag the wrong password")
    }

    @MainActor
    func test_writeFlow_removeProtection_clearsLockAfterWriting() async throws {
        // Toggling protection off + Write must actually remove the lock, not just
        // skip re-applying it (the bug: write reported success but the tag stayed
        // protected).
        let simulator = NTAG215Simulator()
        let pw = Data([0xCA, 0xFE, 0xBA, 0xBE])
        try simulator.enablePasswordProtection(
            password: pw, pack: Data([0x12, 0x34]), protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let model = WriteFlowModel(
            factory: SingletonChipFactory(chip: simulator),
            dataArea: .replace([.uri(URIRecord(uri: "https://hex.pro"))]),
            credentials: InMemoryTagCredentialStore(),
            unlockCredential: .type2(password: pw, pack: Data()),
            removeProtection: true,
            uidConfirmation: .required
        )
        // A removal changes protection state, so it confirms the UID too.
        await beginConfirmingUID(model)
        XCTAssertEqual(model.phase, .done, "expected .done, got \(model.phase)")

        // Protection is gone: a previously-protected page now takes an
        // unauthenticated write, and the credential is back to factory default.
        let tag = try await SimulatedSession(chip: simulator).start(alert: "")
        try await tag.writeMemory(at: 5 * 4, bytes: Data([0x09, 0x09, 0x09, 0x09]))
        let pack = try await tag.authenticate(password: Data([0xFF, 0xFF, 0xFF, 0xFF]))
        XCTAssertEqual(pack, Data([0x00, 0x00]), "PWD/PACK should be reset to factory default")
    }

    @MainActor
    func test_writeFlow_removeProtection_withoutPassword_promptsThenClears() async throws {
        let simulator = NTAG215Simulator()
        let pw = Data([0x01, 0x02, 0x03, 0x04])
        try simulator.enablePasswordProtection(
            password: pw, pack: Data([0xAA, 0xBB]), protectFromPage: 4, readProtect: false, authLimit: 0
        )
        // No password held — the remove-protection write must still prompt first.
        let model = WriteFlowModel(
            factory: SingletonChipFactory(chip: simulator),
            dataArea: .replace([.uri(URIRecord(uri: "https://hex.pro"))]),
            credentials: InMemoryTagCredentialStore(),
            removeProtection: true,
            uidConfirmation: .required
        )
        await model.begin()
        XCTAssertEqual(model.phase, .needsUnlock, "removal still needs the password, got \(model.phase)")

        // The password and then the UID: the tag identified on the first tap is
        // not re-identified, so this is still two holds in total.
        await unlockConfirmingUID(model, with: .type2(password: pw, pack: Data()))
        XCTAssertEqual(model.phase, .done, "expected .done after unlock, got \(model.phase)")

        let tag = try await SimulatedSession(chip: simulator).start(alert: "")
        try await tag.writeMemory(at: 5 * 4, bytes: Data([0x01, 0x02, 0x03, 0x04])) // unprotected now
    }

    @MainActor
    func test_editFlow_wantsProtectionRemoved_intent() {
        // Toggling off a tag that was protected → removal intent.
        let wasProtected = EditFlowModel(
            records: [], protection: TagProtection(passwordProtect: true, protectFromPage: 4), origin: .liveScan
        )
        XCTAssertFalse(wasProtected.wantsProtectionRemoved, "an unchanged protected tag isn't a removal")
        wasProtected.protection.passwordProtect = false
        XCTAssertTrue(wasProtected.wantsProtectionRemoved)

        // A tag that was never protected → toggling stays a no-op for removal.
        let neverProtected = EditFlowModel(records: [], protection: .none, origin: .liveScan)
        neverProtected.protection.passwordProtect = false
        XCTAssertFalse(neverProtected.wantsProtectionRemoved)
    }

    @MainActor
    func test_editFlow_protectionOnlyChange_enablesWrite_onUneditedTag() {
        // Regression: scanning a blank tag and enabling password protection (no
        // record edits) must let the Write button fire. `isDirty` only tracks
        // records, so the toolbar's enable rule also consults `hasProtectionChange`.
        let model = EditFlowModel(records: [], protection: .none, origin: .liveScan)
        XCTAssertFalse(model.isDirty, "no record edits")
        XCTAssertFalse(model.hasProtectionChange, "nothing configured yet")

        // The Protection sheet sets settings + credential together on commit.
        model.protection.passwordProtect = true
        model.protectionCredential = .type2(password: Data([1, 2, 3, 4]), pack: Data([5, 6]))

        XCTAssertFalse(model.isDirty, "still no record edits")
        XCTAssertTrue(model.hasProtectionChange, "applying protection is a write-worthy change")
        // The toolbar asks the model, so this is the rule itself rather than a
        // copy of it that could drift.
        XCTAssertTrue(model.isWriteOffered, "Write must be tappable for a protection-only change")
    }

    @MainActor
    func test_editFlow_hasProtectionChange_falseWithoutCredential() {
        // Toggling protection on but not supplying a credential is not yet a
        // committable change — the write would have nothing to apply.
        let model = EditFlowModel(records: [], protection: .none, origin: .liveScan)
        model.protection.passwordProtect = true
        XCTAssertFalse(model.hasProtectionChange, "no credential ⇒ nothing to apply")

        // Removing existing protection counts even with no credential staged here
        // (the write collects it via the unlock prompt).
        let wasProtected = EditFlowModel(
            records: [], protection: TagProtection(passwordProtect: true, protectFromPage: 4), origin: .liveScan
        )
        wasProtected.protection.passwordProtect = false
        XCTAssertTrue(wasProtected.hasProtectionChange, "removal is a write-worthy change")
    }

    // MARK: - Family-aware unlock (Type-4 / Type-5)

    private static let aesKey = Data((0 ..< 16).map { UInt8(0xA0 &+ $0) })

    /// Pre-protect a fresh 424 sim and hand back the (shared) instance, with its
    /// session cleared so the next tap starts unauthenticated.
    @MainActor
    private func makeProtected424(readProtect: Bool = false) async throws -> NTAG424DNASimulator {
        let sim = NTAG424DNASimulator()
        let setup = try await SimulatedSession(chip: sim).start(alert: "")
        try await setup.enableProtection(.type4(aesKey: Self.aesKey, keySlot: 0, readProtect: readProtect))
        sim.endSession()
        return sim
    }

    /// The end-to-end #2b payoff: holding the 16-byte key, the write flow
    /// authenticates a protected 424 and rewrites it in one tap (the EV2 session
    /// carries through to the NDEF write).
    @MainActor
    func test_writeFlow_protected424_withKey_rewritesInOneTap() async throws {
        let sim = try await makeProtected424()
        let model = WriteFlowModel(
            factory: SingletonChipFactory(chip: sim),
            dataArea: .replace([.uri(URIRecord(uri: "https://hex.pro"))]),
            credentials: InMemoryTagCredentialStore(),
            unlockCredential: .type4(aesKey: Self.aesKey, keySlot: 0),
            uidConfirmation: .required
        )
        await model.begin()
        XCTAssertEqual(model.phase, .done, "a held 424 key should rewrite in one tap, got \(model.phase)")
    }

    /// Without the key, the flow stops at `.needsUnlock` and reports the family so
    /// the prompt can ask for a 16-byte AES key (not a 4-byte password).
    @MainActor
    func test_writeFlow_protected424_withoutKey_promptsWithType4Style() async throws {
        let sim = try await makeProtected424()
        let model = WriteFlowModel(
            factory: SingletonChipFactory(chip: sim),
            dataArea: .replace([.uri(URIRecord(uri: "https://hex.pro"))]),
            credentials: InMemoryTagCredentialStore(),
            uidConfirmation: .required
        )
        await model.begin()
        XCTAssertEqual(model.phase, .needsUnlock, "expected .needsUnlock, got \(model.phase)")
        guard case .type4? = model.unlockStyle else {
            return XCTFail("expected .type4 unlockStyle, got \(String(describing: model.unlockStyle))")
        }
    }

    /// A write-protected SLIX2 surfaces `.type5`, so the prompt routes a 4-byte
    /// SLIX password to the Type-5 backend rather than the Type-2 PWD path.
    ///
    /// A SLIX2 specifically, and it used to be a plain 28-block SLIX. That
    /// version passed on two fictions at once: the simulator answered `ABh` for
    /// every geometry, where a live plain SLIX answers nothing (2026-09-09), and
    /// it armed a password on the one Type-5 profile the catalogue deliberately
    /// gives no `.passwordAuth`, because 28 blocks could equally be an SLI with
    /// no password machinery at all. The prompt this test is about can only be
    /// reached on a chip the app offers protection for.
    @MainActor
    func test_writeFlow_protectedSlix_withoutPassword_promptsWithType5Style() async throws {
        let writePw = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let sim = Iso15693Simulator.slix2()
        let setup = try await SimulatedSession(chip: sim).start(alert: "")
        try await setup.enableProtection(.type5(write: writePw, read: nil, kind: .write))
        sim.endSession()

        let model = WriteFlowModel(
            factory: SingletonChipFactory(chip: sim),
            dataArea: .replace([.uri(URIRecord(uri: "https://hex.pro"))]),
            credentials: InMemoryTagCredentialStore(),
            uidConfirmation: .required
        )
        await model.begin()
        XCTAssertEqual(model.phase, .needsUnlock, "expected .needsUnlock, got \(model.phase)")
        guard case .type5? = model.unlockStyle else {
            return XCTFail("expected .type5 unlockStyle, got \(String(describing: model.unlockStyle))")
        }
    }

    // MARK: - Scanning a read-protected tag (unlock-before-read)

    @MainActor
    func test_scanFlow_readProtectedTag_locksThenUnlocksToRecords() async throws {
        let recordsOnTag: [NDEFRecord] = [.uri(URIRecord(uri: "https://hex.pro"))]
        let message = try NDEFCodec.encode(recordsOnTag)
        let pw = Data([0xCA, 0xFE, 0xBA, 0xBE])
        // Each session vends a fresh chip preloaded with the records and locked
        // read+write — modelling a real read-protected tag re-tapped twice.
        let factory = SimulatedSessionFactory(makeChip: {
            let sim = NTAG215Simulator(ndefMessage: message)
            try? sim.enablePasswordProtection(
                password: pw, pack: Data([0x12, 0x34]), protectFromPage: 4, readProtect: true, authLimit: 0
            )
            return sim
        })
        let model = ScanFlowModel(factory: factory)

        // First tap can't read the protected NDEF → routes to the unlock prompt.
        await model.begin()
        XCTAssertEqual(model.phase, .locked, "expected .locked, got \(model.phase)")
        XCTAssertFalse(model.unlockFailed)

        // Correct password authenticates on the re-tap and the records read back.
        await model.unlock(with: .type2(password: pw, pack: Data()))
        XCTAssertEqual(model.phase, .ready, "expected .ready after unlock, got \(model.phase)")
        XCTAssertEqual(model.records.count, 1)
        XCTAssertEqual(
            model.detectedProtection?.readProtect,
            true,
            "the unlocked read should report the live read-protect state"
        )
    }

    /// The config pages a protection read needs sit at or above AUTH0, so on a
    /// read-protected tag the read is itself refused — and a refusal halts a
    /// Type-2 tag for the rest of the activation. The scan flow used to spend
    /// the tag's one pre-auth command on exactly that read, before the NDEF read
    /// it actually came for, and hide the refusal behind `try?`. Everything after
    /// it was talking to a chip that had stopped listening.
    ///
    /// Live NTAG213, 2026-08-14: `30 29` → `00`, then silence for the rest of
    /// the session, and the user could not read the tag again at all.
    @MainActor
    func test_scanFlow_readProtectedTag_isNotHaltedByItsOwnProtectionProbe() async throws {
        let message = try NDEFCodec.encode([NDEFRecord.uri(URIRecord(uri: "https://hex.pro"))])
        let pw = Data([0xCA, 0xFE, 0xBA, 0xBE])
        let factory = SimulatedSessionFactory(makeChip: {
            let sim = NTAG213Simulator(ndefMessage: message)
            try? sim.enablePasswordProtection(
                password: pw, pack: Data([0x12, 0x34]),
                protectFromPage: 4, readProtect: true, authLimit: 0
            )
            return sim
        })
        let model = ScanFlowModel(factory: factory)

        await model.begin()
        XCTAssertEqual(model.phase, .locked, "a read-protected tag must offer the unlock prompt, got \(model.phase)")

        await model.unlock(with: .type2(password: pw, pack: Data()))
        XCTAssertEqual(
            model.phase,
            .ready,
            "the unlock re-tap authenticates first, so it must read, got \(model.phase)"
        )
        XCTAssertEqual(model.records.count, 1)
    }

    /// The other half of the reorder: moving the protection read after the NDEF
    /// read must not stop the editor reporting protection on the common case, a
    /// tag that is write-protected only. Those config pages read back fine.
    @MainActor
    func test_scanFlow_writeProtectedTag_stillReportsItsProtection() async throws {
        let message = try NDEFCodec.encode([NDEFRecord.uri(URIRecord(uri: "https://hex.pro"))])
        let factory = SimulatedSessionFactory(makeChip: {
            let sim = NTAG213Simulator(ndefMessage: message)
            try? sim.enablePasswordProtection(
                password: Data([0xCA, 0xFE, 0xBA, 0xBE]), pack: Data([0x12, 0x34]),
                protectFromPage: 4, readProtect: false, authLimit: 0
            )
            return sim
        })
        let model = ScanFlowModel(factory: factory)

        await model.begin()

        XCTAssertEqual(model.phase, .ready, "a write-protected tag still reads, got \(model.phase)")
        XCTAssertEqual(model.records.count, 1)
        XCTAssertEqual(model.detectedProtection?.passwordProtect, true)
        XCTAssertEqual(model.detectedProtection?.readProtect, false)
    }

    /// The write flow had the same probe in the same fatal position, with a
    /// worse failure: `try?` turned the refusal into `nil`, which reads as "this
    /// tag is not protected", so the flow wrote at a halted tag and dead-ended
    /// on a generic error. The refusal *is* the protection speaking, and it
    /// belongs at the unlock prompt.
    @MainActor
    func test_writeFlow_readProtectedTag_promptsToUnlockRatherThanDeadEnding() async {
        let factory = SimulatedSessionFactory(makeChip: {
            let sim = NTAG213Simulator()
            try? sim.enablePasswordProtection(
                password: Data([0xCA, 0xFE, 0xBA, 0xBE]), pack: Data([0x12, 0x34]),
                protectFromPage: 4, readProtect: true, authLimit: 0
            )
            return sim
        })
        let model = WriteFlowModel(
            factory: factory,
            dataArea: .replace([.uri(URIRecord(uri: "https://hex.pro"))]),
            credentials: InMemoryTagCredentialStore(),
            uidConfirmation: .required
        )

        await model.begin()

        XCTAssertEqual(
            model.phase, .needsUnlock,
            "a refused protection read means read-protected, not unprotected, got \(model.phase)"
        )
        XCTAssertFalse(model.unlockFailed, "nothing was tried yet, so this is not a failed attempt")
    }

    /// The whole protection lifecycle through the shipping flow models, on one
    /// chip that keeps its state across taps: protect read **and** write, then
    /// turn protection off, then scan and write as a stranger would.
    ///
    /// Everything before this tested a leg. The drivers had their own tests, the
    /// enforcement verifier had its own, and the scan and write flows had theirs,
    /// and every one of them passed while the answer to "can an unauthenticated
    /// reader use this tag again afterwards" went unasked. That is the only
    /// question a user asks after turning protection off.
    @MainActor
    func test_protectionLifecycle_removeLeavesTheTagFullyOpenToAStranger() async throws {
        let chip = NTAG213Simulator()
        let factory = SingletonChipFactory(chip: chip)
        let pw = Data([0xCA, 0xFE, 0xBA, 0xBE])
        let pack = Data([0x12, 0x34])
        let records: [NDEFRecord] = [.uri(URIRecord(uri: "https://hex.pro"))]

        // 1. Protect, read + write.
        let protectModel = WriteFlowModel(
            factory: factory,
            dataArea: .replace(records),
            credentials: InMemoryTagCredentialStore(),
            protection: PendingProtection(
                settings: TagProtection(
                    passwordProtect: true, protectFromPage: 4, readProtect: true, authLimit: 0
                ),
                credential: .type2(password: pw, pack: pack)
            ),
            uidConfirmation: .required
        )
        await beginConfirmingUID(protectModel)
        XCTAssertEqual(protectModel.phase, .done, "protect write failed: \(protectModel.phase)")

        // The gate is armed for reads, not only writes.
        XCTAssertEqual(try? chip.authenticate(password: pw), pack, "the credential should be the one we set")
        let armed = try XCTUnwrap(try chip.readProtectionState())
        XCTAssertTrue(armed.passwordProtect, "AUTH0 must be armed")
        XCTAssertTrue(armed.readProtect, "PROT must be set for read protection")

        // 2. Turn protection off, exactly as the editor's switch does.
        let removeModel = WriteFlowModel(
            factory: factory,
            dataArea: .replace(records),
            credentials: InMemoryTagCredentialStore(),
            unlockCredential: .type2(password: pw, pack: Data()),
            removeProtection: true,
            uidConfirmation: .required
        )
        await beginConfirmingUID(removeModel)
        XCTAssertEqual(removeModel.phase, .done, "removal write failed: \(removeModel.phase)")

        // 3. The assertion that matters: a reader holding nothing can read it.
        let strangerScan = ScanFlowModel(factory: factory)
        await strangerScan.begin()
        XCTAssertEqual(
            strangerScan.phase, .ready,
            "after removal an unauthenticated scan must just work, got \(strangerScan.phase)"
        )
        XCTAssertEqual(strangerScan.records.count, 1, "and it must read the records, not an empty tag")
        XCTAssertEqual(
            strangerScan.detectedProtection?.passwordProtect, false,
            "read protection has to come off with write protection, not survive it"
        )

        // 4. …and write it.
        let strangerWrite = WriteFlowModel(
            factory: factory, dataArea: .replace([.uri(URIRecord(uri: "https://hex.pro/two"))]),
            credentials: InMemoryTagCredentialStore(),
            uidConfirmation: .required
        )
        await strangerWrite.begin()
        XCTAssertEqual(strangerWrite.phase, .done, "an unauthenticated write must succeed, got \(strangerWrite.phase)")
    }

    /// A tag lifted out of the field must not be reported as password-protected.
    ///
    /// The unlock prompt was a guess: any read failure on a chip that *could*
    /// carry a password asked for one. On a tag whose protection had just been
    /// removed and verified removed, that guess was wrong and read as "the
    /// removal didn't work" (live NTAG213, 2026-08-14).
    @MainActor
    func test_scanFlow_aTagThatLeavesTheFieldIsNotCalledProtected() async {
        let factory = SimulatedSessionFactory(makeChip: { VanishingTag() })
        let model = ScanFlowModel(factory: factory)

        await model.begin()

        guard case .error = model.phase else {
            return XCTFail("a tag that never answered must not be blamed on a password, got \(model.phase)")
        }
    }

    /// A refused protection read and a chip that has no protection to report
    /// both leave `detectedProtection` nil, and `try?` made them the same thing.
    /// The editor seeded `protection ?? .none` from it and showed "Off" for a
    /// tag whose state was never established. Seen live 2026-08-14 when a tag
    /// slipped between the two config-page reads.
    @MainActor
    func test_scanFlow_aRefusedProtectionReadIsNotReportedAsUnprotected() async throws {
        let message = try NDEFCodec.encode([NDEFRecord.uri(URIRecord(uri: "https://hex.pro"))])
        let factory = SimulatedSessionFactory(makeChip: { FlakyProtectionTag(ndefMessage: message) })
        let model = ScanFlowModel(factory: factory)

        await model.begin()

        XCTAssertEqual(model.phase, .ready, "the records read fine; only the config read failed")
        XCTAssertEqual(model.records.count, 1)
        XCTAssertNil(model.detectedProtection)
        XCTAssertTrue(
            model.protectionReadFailed,
            "a thrown protection read is 'we don't know', which the editor must not render as Off"
        )
    }

    /// The other half: a chip with no protection backend answers nil *without*
    /// failing, and must not be dressed up as an unknown.
    @MainActor
    func test_scanFlow_aChipWithNoProtectionBackendIsNotReportedAsUnknown() async {
        let factory = SimulatedSessionFactory(makeChip: { UnknownType2Simulator() })
        let model = ScanFlowModel(factory: factory)

        await model.begin()

        XCTAssertNil(model.detectedProtection)
        XCTAssertFalse(
            model.protectionReadFailed,
            "nil from a chip that cannot be protected is an answer, not a failure"
        )
    }

    // MARK: - Command preset catalog

    func test_commandPresetCatalog_isPopulated_andFilters() {
        XCTAssertGreaterThan(CommandPresetCatalog.builtIn.count, 20,
                             "built-in catalog should ship a meaningful library, not just placeholders")
        let ntag215 = CommandPresetCatalog.presets(for: .type2(.ntag215))
        XCTAssertFalse(ntag215.isEmpty, "NTAG215-targeted presets should be present")
        XCTAssertTrue(ntag215.contains { $0.name.contains("Get product version") })
        let type5 = CommandPresetCatalog.presets(for: .type5(.icodeSlix))
        XCTAssertTrue(type5.contains { $0.name.contains("Get system info") })
    }

    func test_commandPresetCatalog_grouped_preservesInsertionOrder() {
        let grouped = CommandPresetCatalog.grouped()
        XCTAssertFalse(grouped.isEmpty)
        let firstFamily = grouped[0].family
        // Type 2 / common presets are emitted first per the catalog source.
        XCTAssertEqual(firstFamily, .type2(.unknown))
    }

    // MARK: - DestructiveConfirmation gate

    func test_destructiveConfirmation_matchesUidTail_caseInsensitive() {
        XCTAssertTrue(DestructiveConfirmation.matches("c3d4", uidTail: "C3D4"))
        XCTAssertTrue(DestructiveConfirmation.matches("C3D4", uidTail: "c3d4"))
        XCTAssertTrue(DestructiveConfirmation.matches(" C3D4 ", uidTail: "C3D4"))
        XCTAssertFalse(DestructiveConfirmation.matches("c3d", uidTail: "C3D4"))
        XCTAssertFalse(DestructiveConfirmation.matches("c3d5", uidTail: "C3D4"))
        XCTAssertFalse(DestructiveConfirmation.matches("", uidTail: "C3D4"))
        XCTAssertFalse(DestructiveConfirmation.matches("c3d4", uidTail: ""))
    }

    // MARK: - Production verification (page 3 is OTP; ACKs are not proof)

    /// Formatting a **virgin** Type-2 tag writes the CC and reads it back.
    @MainActor
    func test_operationsFlow_format_writesAndVerifiesAVirginCC() async throws {
        let simulator = try NTAG21xSimulator(
            variant: .ntag215,
            profile: XCTUnwrap(ChipCatalog.profile(for: .ntag215)),
            uid: NTAG215Simulator.defaultUID,
            virgin: true
        )
        let model = OperationsFlowModel(
            factory: SingletonChipFactory(chip: simulator),
            operation: .format,
            credentials: InMemoryTagCredentialStore()
        )
        let runTask = Task { await model.begin() }
        await waitFor {
            if case .awaitingConfirmation = model.phase {
                return true
            }
            return false
        }
        model.confirm()
        await runTask.value
        if case .done(.formatted(alreadyFormatted: false)) = model.phase {} else {
            return XCTFail("expected .done(.formatted(alreadyFormatted: false)), got \(model.phase)")
        }
        let page3 = try simulator.readMemory(range: 12 ..< 16)
        XCTAssertEqual(page3, ChipCatalog.profile(for: .ntag215)?.factoryCC)
    }

    /// An already-formatted tag whose CC **matches** is a no-op, not a second
    /// OTP write: most NTAG21x ship pre-formatted, and the tag gets one shot.
    @MainActor
    func test_operationsFlow_format_onMatchingCC_succeedsWithoutRewritingOTP() async throws {
        let simulator = NTAG215Simulator() // ships pre-formatted
        let before = try simulator.readMemory(range: 12 ..< 16)
        let model = OperationsFlowModel(
            factory: SingletonChipFactory(chip: simulator),
            operation: .format,
            credentials: InMemoryTagCredentialStore()
        )
        let runTask = Task { await model.begin() }
        await waitFor {
            if case .awaitingConfirmation = model.phase {
                return true
            }
            return false
        }
        model.confirm()
        await runTask.value
        // The summary has to say the OTP page was left alone, not claim a format.
        if case .done(.formatted(alreadyFormatted: true)) = model.phase {} else {
            return XCTFail("expected .done(.formatted(alreadyFormatted: true)), got \(model.phase)")
        }
        XCTAssertEqual(try simulator.readMemory(range: 12 ..< 16), before)
    }

    /// The guard that matters: a tag carrying a **different** CC must be
    /// refused, because page 3 is OTP and the write ORs bits in. Writing
    /// `E1 10 12 00` over `E1 10 06 00` yields `E1 10 16 00` — a size byte
    /// belonging to no chip, uncorrectable for the life of the tag.
    @MainActor
    func test_operationsFlow_format_refusesToORIntoADifferentCC() async throws {
        let simulator = try NTAG21xSimulator(
            variant: .ntag215,
            profile: XCTUnwrap(ChipCatalog.profile(for: .ntag215)),
            uid: NTAG215Simulator.defaultUID,
            virgin: true
        )
        let foreignCC = Data([0xE1, 0x10, 0x06, 0x00])
        try simulator.writeMemory(at: 12, bytes: foreignCC)
        let model = OperationsFlowModel(
            factory: SingletonChipFactory(chip: simulator),
            operation: .format,
            credentials: InMemoryTagCredentialStore()
        )
        let runTask = Task { await model.begin() }
        await waitFor {
            if case .awaitingConfirmation = model.phase {
                return true
            }
            return false
        }
        model.confirm()
        await runTask.value
        guard case .error = model.phase else {
            return XCTFail("formatting over a different CC must fail, got \(model.phase)")
        }
        XCTAssertEqual(
            try simulator.readMemory(range: 12 ..< 16), foreignCC,
            "the OTP page must be left exactly as it was"
        )
    }

    /// `.permanentLock` no longer trusts the ACKs: it probes behaviourally, so
    /// a tag that reports a successful lock while still accepting writes —
    /// clone silicon — fails instead of printing "Tag permanently locked."
    @MainActor
    func test_operationsFlow_permanentLock_failsOnATagThatStillAcceptsWrites() async {
        let simulator = NonEnforcingLockSimulator()
        let model = OperationsFlowModel(
            factory: SingletonChipFactory(chip: simulator),
            operation: .permanentLock,
            credentials: InMemoryTagCredentialStore()
        )
        let runTask = Task { await model.begin() }
        await waitFor {
            if case .awaitingConfirmation = model.phase {
                return true
            }
            return false
        }
        model.confirm()
        await runTask.value
        guard case .error = model.phase else {
            return XCTFail("a tag that still accepts writes after locking must not report success, got \(model.phase)")
        }
    }

    @MainActor
    func test_operationsFlow_memoryDump_returnsAllPages() async {
        let simulator = NTAG215Simulator()
        let factory = SingletonChipFactory(chip: simulator)
        let model = OperationsFlowModel(
            factory: factory,
            operation: .memoryDump,
            credentials: InMemoryTagCredentialStore()
        )
        await model.begin()
        guard case .done(.memoryDumped(let bytes)) = model.phase else {
            return XCTFail("expected .done(.memoryDumped), got \(model.phase)")
        }
        XCTAssertEqual(bytes.count, Type2Variant.ntag215.pageCount * 4)
    }

    // MARK: - AdvancedConsoleModel

    @MainActor
    func test_advancedConsole_runsGetVersionPreset() async {
        let simulator = NTAG215Simulator()
        let factory = SingletonChipFactory(chip: simulator)
        let model = AdvancedConsoleModel(factory: factory)
        // GET_VERSION (0x60) returns 8 bytes on NTAG21x.
        model.input = "60"
        await model.run()
        XCTAssertEqual(model.phase, .finished)
        let txRows = model.entries.filter { $0.kind == .tx }
        let rxRows = model.entries.filter { $0.kind == .rx }
        XCTAssertEqual(txRows.count, 1)
        XCTAssertEqual(rxRows.count, 1)
        XCTAssertTrue(rxRows[0].body.contains(":"), "RX should be hex-formatted with `:` separators")
    }

    @MainActor
    func test_advancedConsole_invalidInput_emitsErrorRow() async {
        let factory = SingletonChipFactory(chip: NTAG215Simulator())
        let model = AdvancedConsoleModel(factory: factory)
        model.input = "ZZ"
        await model.run()
        if case .error = model.phase {} else {
            XCTFail("expected error phase")
        }
        XCTAssertTrue(model.entries.contains { $0.kind == .error })
    }

    @MainActor
    func test_advancedConsole_loadPreset_populatesInput_andLogsNote() throws {
        let factory = SingletonChipFactory(chip: NTAG215Simulator())
        let model = AdvancedConsoleModel(factory: factory)
        let preset = try XCTUnwrap(CommandPresetCatalog.builtIn.first { $0.name == "Get product version" })
        model.loadPreset(preset)
        XCTAssertEqual(model.input, "60")
        XCTAssertTrue(model.entries.contains { $0.kind == .note && $0.body.contains("Get product version") })
    }

    @MainActor
    func test_advancedConsole_filteredPresets_searchAndFamily() {
        let factory = SingletonChipFactory(chip: NTAG215Simulator())
        let model = AdvancedConsoleModel(factory: factory)
        model.searchText = "signature"
        XCTAssertTrue(model.filteredPresets.allSatisfy {
            $0.name.lowercased().contains("signature")
                || $0.sequenceText.lowercased().contains("signature")
                || ($0.notes ?? "").lowercased().contains("signature")
        })
        model.searchText = ""
        model.selectedFamilyFilter = .type5(.icodeSlix)
        XCTAssertTrue(model.filteredPresets.allSatisfy { $0.family == .type5(.icodeSlix) })
    }

    @MainActor
    func test_advancedConsole_identify_capturesChip() async {
        let factory = SingletonChipFactory(chip: NTAG215Simulator())
        let model = AdvancedConsoleModel(factory: factory)
        XCTAssertNil(model.identifiedChip)
        await model.identify()
        XCTAssertEqual(model.identifiedChip?.id, .ntag215)
        XCTAssertFalse(model.isIdentifying)
        XCTAssertTrue(model.entries.contains { $0.kind == .note && $0.body.contains("Identified") })
    }

    @MainActor
    func test_advancedConsole_identify_scoresAndSinksOffFamilyPresets() async throws {
        let factory = SingletonChipFactory(chip: NTAG215Simulator())
        let model = AdvancedConsoleModel(factory: factory)
        await model.identify()

        // Exact-chip and generic Type-2 presets stay compatible; ISO 15693 does not.
        let ntag215 = try XCTUnwrap(model.presets.first { $0.family == .type2(.ntag215) })
        let genericType2 = try XCTUnwrap(model.presets.first { $0.family == .type2(.unknown) })
        let iso15693 = try XCTUnwrap(model.presets.first { $0.family == .type5(.icodeSlix) })
        XCTAssertEqual(model.compatibility(of: ntag215), .exact)
        XCTAssertEqual(model.compatibility(of: genericType2), .compatible)
        XCTAssertFalse(model.compatibility(of: iso15693).isCompatible)

        // Every compatible preset sorts above every incompatible one.
        let ordered = model.filteredPresets
        if let firstOff = ordered.firstIndex(where: { !model.compatibility(of: $0).isCompatible }) {
            let compatibleAfterFirstOff = ordered[firstOff...].contains {
                model.compatibility(of: $0).isCompatible
            }
            XCTAssertFalse(compatibleAfterFirstOff, "off-family presets must all sink to the bottom")
        }
    }

    @MainActor
    func test_advancedConsole_clearIdentification_restoresCatalogOrder() async {
        let factory = SingletonChipFactory(chip: NTAG215Simulator())
        let model = AdvancedConsoleModel(factory: factory)
        await model.identify()
        XCTAssertNotNil(model.identifiedChip)

        model.clearIdentification()
        XCTAssertNil(model.identifiedChip)
        XCTAssertEqual(model.filteredPresets.map(\.id), CommandPresetCatalog.builtIn.map(\.id))
        let anyPreset = model.presets[0]
        XCTAssertEqual(model.compatibility(of: anyPreset), .unscored)
    }
}

// MARK: - Polling helper

@MainActor
private func waitFor(timeout: Duration = .milliseconds(500), _ predicate: @MainActor () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if predicate() {
            return
        }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }
}

// MARK: - Helpers

/// A factory that always vends *the same* session — useful for tests where
/// the write and the verify-read must hit the same in-memory chip state.
private final class SingletonFactory: TagSessionFactory, @unchecked Sendable {
    let session: TagSession
    init(session: TagSession) {
        self.session = session
    }

    func makeSession() -> TagSession {
        session
    }
}

/// A factory that always vends a fresh session over the *same chip
/// simulator*, so write + verify-read see the same memory.
private final class SingletonChipFactory: TagSessionFactory, @unchecked Sendable {
    let chip: ChipSimulator
    init(chip: ChipSimulator) {
        self.chip = chip
    }

    func makeSession() -> TagSession {
        SimulatedSession(chip: chip)
    }
}

/// A Type-2 tag that ACKs the permanent-lock writes and then goes on accepting
/// writes anyway — the "clone silicon" case, and the reason `.permanentLock`
/// verifies behaviourally instead of trusting the ACKs.
///
/// This models the exact divergence real hardware produced twice on ICODE
/// SLIX2: the command is accepted, the state does not change. Without a probe,
/// the app tells the user "Tag permanently locked." about a tag anyone can
/// still rewrite.
private final class NonEnforcingLockSimulator: NTAG21xSimulator, @unchecked Sendable {
    init() {
        super.init(
            variant: .ntag215,
            profile: ChipCatalog.require(.ntag215),
            uid: NTAG215Simulator.defaultUID
        )
    }

    /// ACK every write to a lock page and apply none of it.
    ///
    /// Modelled at the frame level rather than by overriding `permanentLock()`,
    /// because the production lock runs through `Type2LockDriver` over
    /// `transceive` and never calls that method. An override there would leave
    /// the real lock-byte writes landing on the base simulator, which now
    /// derives `isLockedPermanent` from the bytes and would enforce them: the
    /// double would quietly stop being a non-enforcing tag, and the test would
    /// pass for the wrong reason.
    ///
    /// Answering the ACK while changing nothing is exactly what the clone
    /// silicon this test exists for does.
    override func handle(command: Data) -> Data {
        let lockPages = Set([profile?.memoryLayout.lockPages.first, profile?.memoryLayout.dynamicLockPage]
            .compactMap { $0 })
        if command.count >= 6, command[command.startIndex] == 0xA2,
           lockPages.contains(Int(command[command.startIndex + 1]))
        {
            return Data([0x0A])
        }
        return super.handle(command: command)
    }
}

private extension NTAG215Simulator {
    /// Preload a TLV-wrapped NDEF envelope into the chip's NDEF region.
    func preloading(_ envelope: Data) -> NTAG215Simulator {
        try? writeNDEF(envelope)
        return self
    }
}

/// Identifies like a real tag and then answers nothing: a tag lifted out of the
/// field the instant the session opened.
///
/// Modelled as its own chip rather than by halting an NTAG213, because a halted
/// simulator now wakes at the next activation exactly as real silicon does, and
/// that is the behaviour under test elsewhere.
private final class VanishingTag: ChipSimulator, @unchecked Sendable {
    private let inner = NTAG213Simulator()

    var uid: Data {
        inner.uid
    }

    var profile: ChipProfile? {
        inner.profile
    }

    private var gone: TagError {
        .tagLost(diagnostics: "tag left the field after identification")
    }

    func handle(command: Data) -> Data {
        Data([0x00])
    }

    func readMemory(range: Range<Int>) throws -> Data {
        throw gone
    }

    func writeMemory(at offset: Int, bytes: Data) throws {
        throw gone
    }

    func readNDEF() throws -> Data {
        throw gone
    }

    func writeNDEF(_ message: Data) throws {
        throw gone
    }

    func authenticate(password: Data) throws -> Data {
        throw gone
    }

    func setPassword(_ password: Data, pack: Data) throws {
        throw gone
    }

    func permanentLock() throws {
        throw gone
    }

    func readProtectionState() throws -> TagProtection? {
        throw gone
    }
}

/// Reads its records like any NTAG213 but never completes the protection read,
/// the way a tag that slips between the two config-page reads does.
///
/// The fault is on the **frame**: `30 <config0>` draws nothing, every other
/// frame is answered. That is where the loss actually happens, and it is the
/// only place it can be injected now that the protection read is
/// `Type2PasswordDriver` talking over `transceive` rather than a
/// `readProtectionState()` the simulator answers for itself.
private final class FlakyProtectionTag: ChipSimulator, @unchecked Sendable {
    private let inner: NTAG213Simulator

    init(ndefMessage: Data?) {
        inner = NTAG213Simulator(ndefMessage: ndefMessage)
    }

    var uid: Data {
        inner.uid
    }

    var profile: ChipProfile? {
        inner.profile
    }

    func handle(command: Data) -> Data {
        // Silence, not a NAK: this tag refuses nothing, so it never halts and
        // the records below still read. A NAK would end the activation and the
        // test would stop being about an unestablished protection state.
        guard command.count >= 2, command[command.startIndex] == 0x30,
              let page = inner.profile?.type2ConfigLayout?.config0Page,
              Int(command[command.startIndex + 1]) == page
        else { return inner.handle(command: command) }
        return Data()
    }

    func readMemory(range: Range<Int>) throws -> Data {
        try inner.readMemory(range: range)
    }

    func writeMemory(at offset: Int, bytes: Data) throws {
        try inner.writeMemory(at: offset, bytes: bytes)
    }

    func readNDEF() throws -> Data {
        try inner.readNDEF()
    }

    func writeNDEF(_ message: Data) throws {
        try inner.writeNDEF(message)
    }

    func authenticate(password: Data) throws -> Data {
        try inner.authenticate(password: password)
    }

    func setPassword(_ password: Data, pack: Data) throws {
        try inner.setPassword(password, pack: pack)
    }

    func permanentLock() throws {
        try inner.permanentLock()
    }

    func beginActivation() {
        inner.beginActivation()
    }

    func readProtectionState() throws -> TagProtection? {
        try inner.readProtectionState()
    }
}
