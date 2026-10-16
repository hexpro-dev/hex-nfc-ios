@testable import HexNFCApp
import HexNFCKit
import HexNFCRecords
import HexNFCStorage
import HexNFCTagSim
import XCTest

/// When the editor offers Write, and what a press would send.
///
/// Found on 2026-09-25, once disabled toolbar buttons stopped drawing full blue:
/// Write was enabled for any non-empty record list, so an unedited scan wrote
/// the tag's own state back onto it. And after an arm from the Protection card
/// the retained credential kept `pendingProtection()` non-nil for the rest of
/// the session, so a press re-sent the identical arm behind a second typed UID.
///
/// The half of this that can hurt is the opposite mistake. A new password or
/// PACK typed with otherwise identical settings looks exactly like the arm that
/// is already on the tag to anything that reads the tag, because no family's
/// read-back reports a credential. Treating it as "already there" leaves the
/// tag on the old password while the app believes the new one. So every
/// never-suppress case below asserts what the next write would *carry*, not
/// only whether the button is live: on a history row Write is live either way,
/// and a gate-only assertion there cannot see the desync at all.
@MainActor
final class WriteOfferTests: XCTestCase {
    private let passwordA = Data([0x2A, 0x3B, 0x4C, 0x5D])
    private let passwordB = Data([0x11, 0x22, 0x33, 0x44])
    private let packP = Data([0x6E, 0x7F])
    private let packQ = Data([0x01, 0x02])
    private let records: [NDEFRecord] = [.uri(URIRecord(uri: "https://hex.pro"))]
    private let uid = Data([0x04, 0x37, 0x2E, 0x12, 0x6B, 0x67, 0x81])

    // MARK: - Fixtures

    /// What `ProtectionConfigSheet.commit` stages for Type-2: no start page
    /// unless "Custom start page" is on, `hasStoredCredential` true, no limit.
    /// Deliberately not a `protectFromPage: 4` shortcut, because the nil is what
    /// a read-back rewrites and what a naive comparison trips over.
    private func stageType2(
        _ editor: EditFlowModel,
        password: Data,
        pack: Data,
        readProtect: Bool = false,
        startPage: Int? = nil
    ) {
        editor.protection = TagProtection(
            passwordProtect: true,
            protectFromPage: readProtect ? nil : startPage,
            readProtect: readProtect,
            authLimit: 0,
            hasStoredCredential: true
        )
        editor.protectionCredential = .type2(password: password, pack: pack)
    }

    /// A tag-backed editor built the way `RootView` builds one, without a
    /// simulator behind it.
    private func makeEditor(
        origin: EditFlowModel.Origin,
        records: [NDEFRecord] = [],
        protection: TagProtection = .none
    ) -> EditFlowModel {
        EditFlowModel(
            records: records,
            tag: ScannedTagInfo(chipName: "NTAG213", uidHex: uid.hexString, supportsPasswordProtection: true),
            protection: protection,
            origin: origin
        )
    }

    /// The live-scan route, built the way `RootView` builds it from a real scan.
    private func scanned(_ chip: NTAG213Simulator) async -> (EditFlowModel, SimulatedSessionFactory) {
        let factory = SimulatedSessionFactory(chip: chip)
        let scan = ScanFlowModel(factory: factory)
        await scan.begin()
        XCTAssertEqual(scan.phase, .ready, "the fixture scan should complete")
        let editor = EditFlowModel(
            records: scan.records,
            tag: scan.scannedTagInfo,
            protection: scan.detectedProtection ?? .none,
            protectionIsUnknown: scan.protectionReadFailed,
            origin: .liveScan
        )
        return (editor, factory)
    }

    /// Press Write the way `TagEditorSheet` does, then hand back the way it
    /// does: what the write carried first, its reading and proof together after.
    @discardableResult
    private func pressWrite(
        _ editor: EditFlowModel,
        via factory: TagSessionFactory,
        expectingDone: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> WriteFlowModel {
        let request = editor.prepareWrite()
        let write = WriteFlowModel(
            factory: factory,
            dataArea: request.dataArea,
            credentials: InMemoryTagCredentialStore(),
            protection: request.protection,
            unlockCredential: editor.protectionCredential,
            removeProtection: request.removeProtection,
            uidConfirmation: .required,
            targetUID: editor.targetUID,
            pinnedUID: request.pinnedUID
        )
        await beginConfirmingUID(write, file: file, line: line)
        guard case .done = write.phase else {
            if expectingDone {
                XCTFail("the write should complete, got \(write.phase)", file: file, line: line)
            }
            return write
        }
        editor.noteWritten(write.dataArea, to: write.writtenUID)
        if let reading = write.observation {
            editor.apply(reading, provenArm: write.provenArm)
        }
        return write
    }

    /// What `WriteFlowModel` hands back after a proven arm on this editor's tag,
    /// built directly so the families with no simulator arm can be pinned too.
    /// The reading reports no credential, as every real read-back does.
    private func proveStagedArm(on editor: EditFlowModel, firstDataPage: Int = 4) throws {
        let staged = try XCTUnwrap(editor.pendingProtection(), "nothing staged to prove")
        let spec = try XCTUnwrap(ProtectionSpec.make(
            settings: staged.settings, credential: staged.credential, defaultFirstDataPage: firstDataPage
        ))
        let target = try XCTUnwrap(editor.targetUID)
        var read = staged.settings
        read.hasStoredCredential = false
        if read.style == nil {
            read.protectFromPage = read.readProtect ? firstDataPage : (read.protectFromPage ?? firstDataPage)
        }
        if case .ultralightC(var settings) = read.style {
            settings.protectFromPage = settings.protectFromPage ?? firstDataPage
            read.style = .ultralightC(settings)
        }
        editor.apply(
            TagObservation(uid: target, protection: read),
            provenArm: ProvenArm(uid: target, spec: spec, firstDataPage: firstDataPage)
        )
    }

    // MARK: - Live scan

    func test_anUneditedScanIsNotOfferedWrite() async throws {
        let chip = try NTAG213Simulator(ndefMessage: NDEFCodec.encode(records))
        let (editor, _) = await scanned(chip)
        XCTAssertFalse(editor.records.isEmpty, "the fixture must hold records, or this proves nothing")
        XCTAssertFalse(editor.isWriteOffered, "a press would put the tag's own state back on it")
    }

    func test_anUneditedScanOfAProtectedTagIsNotOfferedWrite() {
        let editor = makeEditor(
            origin: .liveScan,
            records: records,
            protection: TagProtection(passwordProtect: true, protectFromPage: 4)
        )
        XCTAssertNil(editor.pendingProtection(), "a scan carries no credential")
        XCTAssertFalse(editor.isWriteOffered, "nothing is staged and nothing is edited")
    }

    func test_anEditToAScanIsOfferedAndRevertingItWithdrawsIt() {
        let editor = makeEditor(origin: .liveScan, records: records)
        editor.append(.text(TextRecord(text: "added")))
        XCTAssertTrue(editor.isWriteOffered, "an edit is something to write")
        editor.revert()
        XCTAssertFalse(editor.isWriteOffered, "and reverting it leaves nothing")
    }

    func test_emptyingAScanOffersTheWriteThatClearsIt() {
        let editor = makeEditor(origin: .liveScan, records: records)
        editor.records.removeAll()
        XCTAssertTrue(
            editor.isWriteOffered,
            "an empty list differs from what the tag holds, so writing it clears the tag"
        )
    }

    func test_aScanThatHasWrittenIsNotOfferedAgainUntilTheNextEdit() async throws {
        let chip = try NTAG213Simulator(ndefMessage: NDEFCodec.encode(records))
        let (editor, factory) = await scanned(chip)
        editor.append(.text(TextRecord(text: "added")))
        XCTAssertTrue(editor.isWriteOffered)
        await pressWrite(editor, via: factory)
        XCTAssertFalse(editor.isWriteOffered, "the tag now holds exactly this, so a second press would rewrite it")
        editor.append(.text(TextRecord(text: "and another")))
        XCTAssertTrue(editor.isWriteOffered, "a new edit is something to write again")
    }

    func test_aWriteRecordsWhatItCarriedNotWhatTheEditorHoldsWhenItReports() {
        let editor = makeEditor(origin: .liveScan, records: records)
        editor.append(.text(TextRecord(text: "written")))
        let carried = editor.dataAreaChange
        // The hand-back comes from a task that outlives a swipe dismissal, and
        // the user edited in the meantime.
        editor.append(.text(TextRecord(text: "typed during the hand-back")))
        editor.noteWritten(carried, to: uid)
        XCTAssertTrue(editor.isDirty, "the late edit was never written")
        XCTAssertTrue(editor.isWriteOffered, "so Write must stay offered for it")
    }

    // MARK: - Build and history

    func test_aBuildIsOfferedOnceItHoldsSomethingAndNotAfterWritingIt() {
        let editor = EditFlowModel(records: [], origin: .build)
        XCTAssertFalse(editor.isWriteOffered, "an empty build has nothing to write")
        editor.append(.text(TextRecord(text: "built")))
        XCTAssertTrue(editor.isWriteOffered)
        editor.noteWritten(editor.dataAreaChange, to: uid)
        XCTAssertFalse(editor.isWriteOffered, "written, and nothing has changed since")
        editor.append(.text(TextRecord(text: "more")))
        XCTAssertTrue(editor.isWriteOffered)
    }

    func test_aHistoryRowIsOfferedBeforeAndAfterAWrite() {
        let editor = makeEditor(origin: .history, records: records)
        XCTAssertTrue(editor.isWriteOffered, "a history row exists to be put onto a tag")
        editor.noteWritten(editor.dataAreaChange, to: uid)
        XCTAssertTrue(editor.isWriteOffered, "including a second tag after the first")
        XCTAssertEqual(editor.dataAreaChange, .replace(records), "and the press still writes the records")
    }

    func test_anEmptyHistoryRowWithNothingStagedIsNotOffered() {
        XCTAssertFalse(makeEditor(origin: .history).isWriteOffered)
    }

    func test_aProvenLockIsNeverOfferedFromAnyOrigin() {
        var lock = TagLockReading()
        lock.record(.dynamicLock, .allSet)
        lock.record(.staticLock, .allSet)
        for origin in [EditFlowModel.Origin.liveScan, .history] {
            let editor = makeEditor(origin: origin, records: records)
            editor.apply(TagObservation(uid: uid, lock: lock))
            editor.append(.text(TextRecord(text: "edit")))
            XCTAssertTrue(editor.isWriteBlocked)
            XCTAssertFalse(editor.isWriteOffered, "a locked tag refuses every write, from \(origin)")
        }
    }

    // MARK: - An arm this editor proved

    func test_anArmTheEditorProvedIsNotOfferedOrSentAgain() async {
        let (editor, factory) = await scanned(NTAG213Simulator())
        stageType2(editor, password: passwordA, pack: packP)
        let staged = editor.protection
        XCTAssertTrue(editor.isWriteOffered, "a first arm is a real change")

        let write = await pressWrite(editor, via: factory)

        XCTAssertNotNil(write.provenArm, "a clean Type-2 arm proves its credential with PWD_AUTH")
        XCTAssertNotEqual(
            editor.protection,
            staged,
            "the read-back rebased the vocabulary, which a naive comparison trips over"
        )
        XCTAssertNotNil(editor.protectionCredential, "the secret survives, which a removal still needs")
        XCTAssertFalse(editor.hasProtectionChange, "the tag holds exactly what is staged")
        XCTAssertFalse(editor.isWriteOffered, "so a press would re-send an identical arm")
        XCTAssertNil(editor.protectionToSend(), "and no write from here may carry it either")
    }

    func test_reopeningTheCardAndPressingDoneChangesNothing() async {
        let (editor, factory) = await scanned(NTAG213Simulator())
        stageType2(editor, password: passwordA, pack: packP)
        await pressWrite(editor, via: factory)
        // The card re-seeds from the concrete page the arm resolved to.
        stageType2(editor, password: passwordA, pack: packP, startPage: 4)
        XCTAssertFalse(editor.isWriteOffered, "the same frames would go on the air")
    }

    func test_aNewPasswordOrPACKAfterAnArmIsOfferedAndCarried() async {
        let cases: [(Data, Data, String)] = [
            (passwordB, packP, "a new password"),
            (passwordA, packQ, "a new PACK"),
        ]
        for (password, pack, what) in cases {
            let (editor, factory) = await scanned(NTAG213Simulator())
            stageType2(editor, password: passwordA, pack: packP)
            await pressWrite(editor, via: factory)
            XCTAssertFalse(editor.isWriteOffered)

            stageType2(editor, password: password, pack: pack)

            XCTAssertTrue(editor.isWriteOffered, "\(what): suppressing this leaves the tag on the old credential")
            XCTAssertEqual(
                editor.protectionToSend()?.credential, .type2(password: password, pack: pack),
                "\(what) must ride in the next write"
            )
        }
    }

    func test_revertingToTheProvenCredentialSettlesAgain() async {
        let (editor, factory) = await scanned(NTAG213Simulator())
        stageType2(editor, password: passwordA, pack: packP)
        await pressWrite(editor, via: factory)
        stageType2(editor, password: passwordB, pack: packP)
        XCTAssertTrue(editor.isWriteOffered)
        stageType2(editor, password: passwordA, pack: packP)
        XCTAssertFalse(editor.isWriteOffered, "back to exactly what was proven, with no write in between")
    }

    func test_aReadGateOrStartPageChangeAfterAnArmIsOffered() async {
        let (editor, factory) = await scanned(NTAG213Simulator())
        stageType2(editor, password: passwordA, pack: packP)
        await pressWrite(editor, via: factory)

        stageType2(editor, password: passwordA, pack: packP, readProtect: true)
        XCTAssertTrue(editor.isWriteOffered, "a read gate is a change the tag does not hold")
        XCTAssertEqual(editor.protectionToSend()?.settings.readProtect, true)

        stageType2(editor, password: passwordA, pack: packP, startPage: 8)
        XCTAssertTrue(editor.isWriteOffered, "so is a different start page")
        XCTAssertEqual(editor.protectionToSend()?.settings.protectFromPage, 8)
    }

    func test_aNewKeyOrGateOnTheOtherFamiliesIsNeverTakenAsProven() throws {
        let key16A = Data(repeating: 0x5A, count: 16)
        let key16B = Data(repeating: 0xA5, count: 16)
        let ulcA = try UltralightCKey(cipherOrder: Data((0 ..< 16).map { UInt8(0xA0 + $0) }))
        let ulcB = try UltralightCKey(cipherOrder: Data((0 ..< 16).map { UInt8(0x10 + $0) }))

        struct Family {
            let name: String
            let stage: (EditFlowModel) -> Void
            let changes: [(String, (EditFlowModel) -> Void)]
        }
        let families: [Family] = [
            Family(
                name: "NTAG424",
                stage: {
                    $0.protection = TagProtection(
                        passwordProtect: true,
                        style: .type4(.init()),
                        hasStoredCredential: true
                    )
                    $0.protectionCredential = .type4(aesKey: key16A, keySlot: 0)
                },
                changes: [
                    ("a new key", { $0.protectionCredential = .type4(aesKey: key16B, keySlot: 0) }),
                    ("a read gate", { $0.protection.style = .type4(.init(readProtect: true)) }),
                ]
            ),
            Family(
                name: "SLIX2",
                stage: {
                    $0.protection = TagProtection(
                        passwordProtect: true,
                        style: .type5(.init()),
                        hasStoredCredential: true
                    )
                    $0.protectionCredential = .type5(password: self.passwordA, kind: .write)
                },
                changes: [
                    ("a new password", { $0.protectionCredential = .type5(password: self.passwordB, kind: .write) }),
                ]
            ),
            Family(
                name: "Ultralight C",
                stage: {
                    $0.protection = TagProtection(
                        passwordProtect: true, style: .ultralightC(.init()), hasStoredCredential: true
                    )
                    $0.protectionCredential = .ultralightC(key: ulcA)
                },
                changes: [
                    ("a new key", { $0.protectionCredential = .ultralightC(key: ulcB) }),
                    ("a start page", { $0.protection.style = .ultralightC(.init(protectFromPage: 8)) }),
                ]
            ),
        ]

        for family in families {
            for (what, change) in family.changes {
                let editor = makeEditor(origin: .liveScan)
                family.stage(editor)
                try proveStagedArm(on: editor)
                XCTAssertFalse(editor.isWriteOffered, "\(family.name): the proven arm itself is settled")

                change(editor)

                XCTAssertTrue(editor.isWriteOffered, "\(family.name), \(what): not on the tag, so it must be offered")
                XCTAssertNotNil(editor.protectionToSend(), "\(family.name), \(what): and carried")
            }
        }
    }

    // MARK: - When the proof goes

    func test_anOperationsReadingClearsTheProof() throws {
        let editor = makeEditor(origin: .liveScan)
        stageType2(editor, password: passwordA, pack: packP)
        try proveStagedArm(on: editor)
        XCTAssertFalse(editor.isWriteOffered)

        // Operations re-reads the same armed tag and reports it, with no proof
        // of its own. It may have re-keyed the tag to get there.
        var armed = editor.originalProtection
        armed.hasStoredCredential = false
        editor.apply(TagObservation(uid: uid, protection: armed))

        XCTAssertNil(editor.provenArm, "only this editor's own write can carry a proof")
        XCTAssertTrue(editor.isWriteOffered, "so the arm is offered again, which is the safe direction")
    }

    func test_anOperationsRemovalAfterAnArmOffersNothing() throws {
        let editor = makeEditor(origin: .liveScan)
        stageType2(editor, password: passwordA, pack: packP)
        try proveStagedArm(on: editor)

        editor.apply(TagObservation(uid: uid, protection: TagProtection.none))

        XCTAssertNil(editor.pendingProtection(), "the card follows the tag to open")
        XCTAssertNotNil(editor.protectionCredential, "and keeps the secret, as EditorObservationTests requires")
        XCTAssertFalse(editor.isWriteOffered, "there is nothing left to write to an open, unedited tag")
    }

    func test_openingOperationsForgetsTheProof() throws {
        let editor = makeEditor(origin: .liveScan)
        stageType2(editor, password: passwordA, pack: packP)
        try proveStagedArm(on: editor)

        editor.forgetProvenArm()

        XCTAssertTrue(editor.isWriteOffered, "Operations can re-key without reporting back")
        XCTAssertNotNil(editor.protectionToSend())
    }

    func test_aProtectionWriteThatNeverReportsBackLeavesTheArmOffered() throws {
        let editor = makeEditor(origin: .liveScan)
        stageType2(editor, password: passwordA, pack: packP)
        try proveStagedArm(on: editor)
        stageType2(editor, password: passwordB, pack: packP)

        // The write starts, tears after the PWD page, and never hands back.
        let started = editor.prepareWrite()
        XCTAssertNotNil(started.protection, "fixture: the write carries the new password")
        stageType2(editor, password: passwordA, pack: packP)

        XCTAssertTrue(editor.isWriteOffered, "the tag may now answer to either password")
        XCTAssertEqual(editor.protectionToSend()?.credential, .type2(password: passwordA, pack: packP))
    }

    func test_aProofIsTakenOnlyWithAReadingThatSaysTheTagIsArmed() throws {
        let editor = makeEditor(origin: .liveScan)
        stageType2(editor, password: passwordA, pack: packP)
        let staged = try XCTUnwrap(editor.pendingProtection())
        let spec = try XCTUnwrap(ProtectionSpec.make(
            settings: staged.settings, credential: staged.credential, defaultFirstDataPage: 4
        ))

        editor.apply(
            TagObservation(uid: uid, protection: TagProtection.none),
            provenArm: ProvenArm(uid: uid, spec: spec, firstDataPage: 4)
        )

        XCTAssertNil(editor.provenArm, "a proof that arrives with an open reading is not believed")
    }

    func test_aReadingFromAnotherTagLeavesTheProofAlone() throws {
        let editor = makeEditor(origin: .liveScan)
        stageType2(editor, password: passwordA, pack: packP)
        try proveStagedArm(on: editor)
        let proof = editor.provenArm

        editor.apply(TagObservation(
            uid: Data([0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01]),
            protection: TagProtection.none
        ))

        XCTAssertEqual(editor.provenArm, proof, "a reading about another tag is discarded whole")
        XCTAssertFalse(editor.isWriteOffered)
    }

    // MARK: - Editors with no tag of their own

    func test_aBuildStopsOfferingItsArmButKeepsSendingIt() async {
        let chip = NTAG213Simulator()
        let factory = SimulatedSessionFactory(chip: chip)
        let editor = EditFlowModel(records: [], origin: .build)
        stageType2(editor, password: passwordA, pack: packP)
        XCTAssertTrue(editor.isWriteOffered)

        let write = await pressWrite(editor, via: factory)

        XCTAssertNotNil(write.provenArm)
        XCTAssertEqual(editor.provenArm, write.provenArm, "a build takes no reading, but it takes its own proof")
        XCTAssertFalse(editor.isWriteOffered, "written, and nothing has changed since")
        XCTAssertNotNil(
            editor.protectionToSend(),
            "a build's next write may be to another tag, which must not get records and no password"
        )

        editor.append(.text(TextRecord(text: "for the next tag")))
        XCTAssertTrue(editor.isWriteOffered)
        XCTAssertEqual(editor.dataAreaChange, .replace(editor.records), "the records go down with the arm")
    }

    func test_aHistoryRowDoesNotReArmItsOwnTag() async throws {
        let chip = try NTAG213Simulator(ndefMessage: NDEFCodec.encode(records))
        let factory = SimulatedSessionFactory(chip: chip)
        let editor = EditFlowModel(
            records: records,
            tag: ScannedTagInfo(chipName: "NTAG213", uidHex: chip.uid.hexString, supportsPasswordProtection: true),
            origin: .history
        )
        stageType2(editor, password: passwordA, pack: packP)

        await pressWrite(editor, via: factory)

        XCTAssertTrue(editor.isWriteOffered, "a history row stays offered")
        XCTAssertNil(editor.protectionToSend(), "but its arm is pinned to this tag, which already holds it")
        XCTAssertEqual(editor.dataAreaChange, .replace(records), "so a press writes the records alone")

        stageType2(editor, password: passwordB, pack: packP)
        XCTAssertEqual(
            editor.protectionToSend()?.credential, .type2(password: passwordB, pack: packP),
            "the button cannot show this on a history row, so the payload has to"
        )
    }

    // MARK: - The proof itself

    func test_aRecordsOnlyWriteProvesNoArm() async throws {
        let chip = try NTAG213Simulator(ndefMessage: NDEFCodec.encode(records))
        let (editor, factory) = await scanned(chip)
        editor.append(.text(TextRecord(text: "added")))
        let write = await pressWrite(editor, via: factory)
        XCTAssertNil(write.provenArm)
        XCTAssertNil(editor.provenArm)
    }

    /// An Ultralight C arm acknowledges its key write and cannot authenticate
    /// with it in the same activation, so it never proves the credential. Its
    /// Write stays offered, because the next tap is the only proof that family
    /// gets.
    func test_anUltralightCArmIsNeverTakenAsProven() async throws {
        let chip = try MifareUltralightCSimulator(ndefMessage: NDEFCodec.encode([.text(TextRecord(text: "seed"))]))
        let factory = SimulatedSessionFactory(chip: chip)
        let scan = ScanFlowModel(factory: factory)
        await scan.begin()
        let editor = EditFlowModel(
            records: scan.records,
            tag: scan.scannedTagInfo,
            protection: scan.detectedProtection ?? .none,
            protectionIsUnknown: scan.protectionReadFailed,
            origin: .liveScan
        )
        let key = try UltralightCKey(cipherOrder: Data((0 ..< 16).map { UInt8(0xA0 + $0) }))
        editor.protection = TagProtection(
            passwordProtect: true,
            style: .ultralightC(.init()),
            hasStoredCredential: true
        )
        editor.protectionCredential = .ultralightC(key: key)

        let write = await pressWrite(editor, via: factory)

        XCTAssertEqual(try chip.readProtectionState()?.passwordProtect, true, "fixture: the tag is armed")
        XCTAssertNil(write.provenArm, "an acknowledged key write is not a proven credential")
        XCTAssertTrue(editor.isWriteOffered, "so the tap that proves the key stays offered")
        XCTAssertNotNil(editor.protectionToSend())
    }

    /// Reaching `.done` is not a proof. A Type-2 arm whose `PWD_AUTH` never
    /// comes back still finishes, with its credential unproven, and must not
    /// withdraw the arm it failed to prove.
    func test_anArmWhosePACKRoundTripFailsProvesNothing() async {
        let faults = FaultInjectingSessionFactory(chip: NTAG213Simulator())
        let scan = ScanFlowModel(factory: faults)
        await scan.begin()
        let editor = EditFlowModel(
            records: scan.records,
            tag: scan.scannedTagInfo,
            protection: scan.detectedProtection ?? .none,
            origin: .liveScan
        )
        stageType2(editor, password: passwordA, pack: packP)
        faults.arm(TagFault(.opcode(0x1B), .dropped, on: .every))

        let write = await pressWrite(editor, via: faults, expectingDone: false)

        XCTAssertNil(write.provenArm, "phase \(write.phase): finishing is not proving")
        XCTAssertNil(editor.provenArm)
        XCTAssertNotNil(editor.protectionToSend(), "the unproven arm is still sent")
    }

    /// A swipe dismissal runs `reset()` before the late hand-back reads the
    /// proof, so `reset()` must not be what loses it.
    func test_resettingTheWriteKeepsItsProofForTheLateHandBack() async {
        let (editor, factory) = await scanned(NTAG213Simulator())
        stageType2(editor, password: passwordA, pack: packP)
        let write = await pressWrite(editor, via: factory)
        XCTAssertNotNil(write.provenArm)
        write.reset()
        XCTAssertNotNil(write.provenArm, "WriteSheet resets on disappear, before the hand-back task runs")
    }

    func test_aProofIsTakenOnlyForThisTagAndOnlyWithAnArmedReading() throws {
        let other = Data([0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01])
        let spec = try XCTUnwrap(ProtectionSpec.make(
            settings: TagProtection(passwordProtect: true, hasStoredCredential: true),
            credential: .type2(password: passwordA, pack: packP),
            defaultFirstDataPage: 4
        ))
        let armed = TagProtection(passwordProtect: true, protectFromPage: 4)

        let openBuild = EditFlowModel(records: [], origin: .build)
        stageType2(openBuild, password: passwordA, pack: packP)
        openBuild.apply(
            TagObservation(uid: uid, protection: TagProtection.none),
            provenArm: ProvenArm(uid: uid, spec: spec, firstDataPage: 4)
        )
        XCTAssertNil(openBuild.provenArm, "a build takes a proof only with a reading that says the tag is armed")

        let strayBuild = EditFlowModel(records: [], origin: .build)
        stageType2(strayBuild, password: passwordA, pack: packP)
        strayBuild.apply(
            TagObservation(uid: uid, protection: armed),
            provenArm: ProvenArm(uid: other, spec: spec, firstDataPage: 4)
        )
        XCTAssertNil(strayBuild.provenArm, "nor a proof about a different tag from the reading")

        let strayScan = makeEditor(origin: .liveScan)
        stageType2(strayScan, password: passwordA, pack: packP)
        strayScan.apply(
            TagObservation(uid: uid, protection: armed),
            provenArm: ProvenArm(uid: other, spec: spec, firstDataPage: 4)
        )
        XCTAssertNil(strayScan.provenArm, "and a tag-backed editor takes none about another tag either")
        XCTAssertTrue(strayScan.isWriteOffered)
    }

    // MARK: - What a press sends

    /// Holding a settled arm back also takes away the identify tap that used to
    /// refuse a different tag, so the write is pinned to the tag the arm is on.
    /// Without the pin a history row, which stays offered, puts its records on
    /// whatever tag is held with no password while the card says "Password".
    func test_aWriteWhoseArmWasHeldBackRefusesADifferentTag() async throws {
        let armedChip = try NTAG213Simulator(ndefMessage: NDEFCodec.encode(records))
        let editor = EditFlowModel(
            records: records,
            tag: ScannedTagInfo(chipName: "NTAG213", uidHex: armedChip.uid.hexString, supportsPasswordProtection: true),
            origin: .history
        )
        stageType2(editor, password: passwordA, pack: packP)
        await pressWrite(editor, via: SimulatedSessionFactory(chip: armedChip))
        XCTAssertTrue(editor.isWriteOffered, "a history row stays offered")
        XCTAssertNil(editor.protectionToSend(), "fixture: the arm is settled and held back")

        let blank = NTAG213Simulator(uid: Data([0x04, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66]))
        let write = await pressWrite(editor, via: SimulatedSessionFactory(chip: blank), expectingDone: false)

        guard case .error = write.phase else {
            return XCTFail("a different tag must be refused, got \(write.phase)")
        }
        XCTAssertEqual(
            try blank.readProtectionState()?.passwordProtect, false,
            "the other tag was not armed"
        )
        let other = ScanFlowModel(factory: SimulatedSessionFactory(chip: blank))
        await other.begin()
        XCTAssertTrue(other.records.isEmpty, "and it did not receive the records either")
    }

    func test_whatAPressSendsAfterASettledArm() throws {
        let scan = makeEditor(origin: .liveScan, records: records)
        stageType2(scan, password: passwordA, pack: packP)
        try proveStagedArm(on: scan)
        scan.append(.text(TextRecord(text: "edit")))
        let scanPress = scan.prepareWrite()
        XCTAssertEqual(scanPress.dataArea, .replace(scan.records))
        XCTAssertNil(scanPress.protection, "the scanned tag already holds the arm")
        XCTAssertEqual(scanPress.pinnedUID, uid, "so the write is pinned to it")

        let build = EditFlowModel(records: [], origin: .build)
        stageType2(build, password: passwordA, pack: packP)
        try build.apply(
            TagObservation(uid: uid, protection: TagProtection(passwordProtect: true, protectFromPage: 4)),
            provenArm: ProvenArm(
                uid: uid,
                spec: XCTUnwrap(ProtectionSpec.make(
                    settings: build.protection,
                    credential: .type2(password: passwordA, pack: packP),
                    defaultFirstDataPage: 4
                )),
                firstDataPage: 4
            )
        )
        XCTAssertFalse(build.isWriteOffered, "fixture: the build's arm is settled")
        build.append(.text(TextRecord(text: "for the next tag")))
        let buildPress = build.prepareWrite()
        XCTAssertEqual(buildPress.dataArea, .replace(build.records), "read before the proof is dropped")
        XCTAssertNotNil(buildPress.protection, "a build's next tag may not be the one armed")
        XCTAssertNil(buildPress.pinnedUID)
    }

    func test_aRemovalDropsTheProofAsWellAsAnArm() throws {
        let editor = makeEditor(origin: .liveScan)
        stageType2(editor, password: passwordA, pack: packP)
        try proveStagedArm(on: editor)
        editor.protection.passwordProtect = false

        let press = editor.prepareWrite()

        XCTAssertTrue(press.removeProtection)
        XCTAssertNil(editor.provenArm, "a removal that tears may leave the tag open")
        editor.protection.passwordProtect = true
        XCTAssertTrue(editor.isWriteOffered, "so switching it back on is not taken as already done")
    }

    // MARK: - A staged gate survives a reading of the same tag

    /// `apply` compared only the flat Type-2 fields, and the other families keep
    /// their knobs in `style`, so any same-tag reading called a staged NTAG424
    /// read gate or Ultralight C start page "reached" and discarded it.
    func test_aStagedGateOnTheOtherFamiliesSurvivesAReadingOfTheSameTag() throws {
        let key = try UltralightCKey(cipherOrder: Data((0 ..< 16).map { UInt8(0xA0 + $0) }))
        let cases: [(String, TagProtection, TagProtection, TagCredential)] = [
            (
                "an NTAG424 read gate",
                TagProtection(
                    passwordProtect: true,
                    style: .type4(.init(readProtect: true)),
                    hasStoredCredential: true
                ),
                TagProtection(passwordProtect: true, style: .type4(.init(readProtect: false))),
                .type4(aesKey: Data(repeating: 0x5A, count: 16), keySlot: 0)
            ),
            (
                "an Ultralight C start page",
                TagProtection(
                    passwordProtect: true,
                    style: .ultralightC(.init(protectFromPage: 8)),
                    hasStoredCredential: true
                ),
                TagProtection(passwordProtect: true, style: .ultralightC(.init(protectFromPage: 4))),
                .ultralightC(key: key)
            ),
            (
                "a SLIX2 kind",
                TagProtection(passwordProtect: true, style: .type5(.init(kind: .readWrite)), hasStoredCredential: true),
                TagProtection(passwordProtect: true, style: .type5(.init(kind: .write))),
                .type5(password: passwordA, kind: .readWrite)
            ),
        ]
        for (what, staged, reading, credential) in cases {
            let editor = makeEditor(origin: .liveScan, protection: reading)
            editor.protection = staged
            editor.protectionCredential = credential

            editor.apply(TagObservation(uid: uid, protection: reading))

            XCTAssertEqual(editor.protection, staged, "\(what) was discarded by a reading that has not reached it")
            XCTAssertEqual(editor.protectionToSend()?.settings, staged, "\(what) must still ride in the next write")
        }
    }

    // MARK: - Which tag a write or a reading is about

    /// A plain record write is not pinned, so an edit can go onto the wrong tag
    /// from a stack of blanks. Counting that as this tag's content withdrew
    /// Write from the tag that never got it (review of b0aa17b, 2026-09-25).
    func test_aWriteThatLandedOnAnotherTagIsNotRecordedAsThisTagsContent() async throws {
        let chip = try NTAG213Simulator(ndefMessage: NDEFCodec.encode(records))
        let (editor, _) = await scanned(chip)
        editor.append(.text(TextRecord(text: "meant for this tag")))
        let other = NTAG213Simulator(uid: Data([0x04, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66]))

        let write = await pressWrite(editor, via: SimulatedSessionFactory(chip: other))

        XCTAssertEqual(write.writtenUID, other.uid, "fixture: the write went to the other tag")
        XCTAssertTrue(editor.isDirty, "this tag still holds what it held")
        XCTAssertTrue(editor.isWriteOffered, "so Write stays offered for it")
    }

    func test_aBuildRecordsAWriteToWhicheverTagItWentTo() {
        let editor = EditFlowModel(records: [], origin: .build)
        editor.append(.text(TextRecord(text: "built")))
        editor.noteWritten(editor.dataAreaChange, to: Data([0x04, 0x99, 0x88, 0x77, 0x66, 0x55, 0x44]))
        XCTAssertFalse(editor.isWriteOffered, "a build has no tag of its own to compare against")
    }

    func test_onlyReadingsAboutThisTagAreHeld() {
        let other = Data([0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01])
        let scan = makeEditor(origin: .liveScan)
        XCTAssertTrue(scan.isAboutThisTag(uid))
        XCTAssertFalse(scan.isAboutThisTag(other), "a merge across tags would drop this tag's pending reading")
        XCTAssertTrue(EditFlowModel(records: [], origin: .build).isAboutThisTag(other), "a build takes every reading")
    }
}
