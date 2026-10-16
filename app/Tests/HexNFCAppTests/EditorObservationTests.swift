@testable import HexNFCApp
@testable import HexNFCKit
@testable import HexNFCRecords
@testable import HexNFCTagSim
import XCTest

/// The identity guard and the merge rules on `EditFlowModel.apply`.
///
/// Operations is a general tool: it is launched from the editor, but every
/// operation runs against whatever tag the user then presents, and a stack of
/// blanks is easy to mix up. Landing another tag's reading on this editor's card
/// would be the same defect as trusting an ACK, one layer up, so the guard is
/// what most of this file is about.
final class EditorObservationTests: XCTestCase {
    private let uid = Data([0x04, 0x37, 0x2E, 0x12, 0x6B, 0x67, 0x81])
    private let otherUID = Data([0x04, 0xBA, 0x4A, 0x92, 0x1B, 0x21, 0x90])

    @MainActor
    private func editor(
        protection: TagProtection = .none,
        protectionIsUnknown: Bool = false,
        uidHex: String? = nil
    ) -> EditFlowModel {
        EditFlowModel(
            tag: ScannedTagInfo(
                chipName: "NTAG213",
                uidHex: uidHex ?? uid.hexString,
                supportsPasswordProtection: true
            ),
            protection: protection,
            protectionIsUnknown: protectionIsUnknown,
            origin: .liveScan
        )
    }

    private func lockedReading() -> TagLockReading {
        var reading = TagLockReading()
        reading.record(.dynamicLock, .allSet)
        reading.record(.staticLock, .allSet)
        return reading
    }

    // MARK: - The identity guard

    @MainActor
    func test_aReadingFromAnotherTagIsDiscarded() {
        let model = editor()
        let changed = model.apply(TagObservation(uid: otherUID, lock: lockedReading()))
        XCTAssertFalse(changed)
        XCTAssertEqual(model.lockState, .unknown, "another tag's lock must not land here")
        XCTAssertFalse(model.isWriteBlocked)
    }

    @MainActor
    func test_anEditorWithNoTagTakesNothing() {
        let model = EditFlowModel(origin: .build)
        XCTAssertFalse(model.apply(TagObservation(uid: uid, lock: lockedReading())))
        XCTAssertEqual(model.lockState, .unknown)
    }

    @MainActor
    func test_anEditorWithAnEmptyUIDTakesNothing() {
        let model = editor(uidHex: "")
        XCTAssertFalse(model.apply(TagObservation(uid: uid, lock: lockedReading())))
    }

    /// A live scan formats the UID with `Data.hexString` and a rebuilt history
    /// row with `HistoryEntry.displayUID`. They are documented to agree;
    /// normalising means the guard does not depend on that holding.
    @MainActor
    func test_uidComparisonIgnoresColonsAndCase() {
        for variant in ["04372e126b6781", "04:37:2e:12:6b:67:81", "04372E126B6781"] {
            let model = editor(uidHex: variant)
            XCTAssertTrue(
                model.apply(TagObservation(uid: uid, lock: lockedReading())),
                "failed for \(variant)"
            )
        }
    }

    // MARK: - The lock

    @MainActor
    func test_aLockReadingSetsTheStateAndFiresTheMomentOnce() {
        let model = editor()
        XCTAssertEqual(model.lockMomentCount, 0)
        XCTAssertTrue(model.apply(TagObservation(uid: uid, lock: lockedReading())))
        XCTAssertEqual(model.lockState, .locked)
        XCTAssertTrue(model.isWriteBlocked)
        XCTAssertEqual(model.lockMomentCount, 1)
    }

    /// `.unknown` is an absence of evidence. Delivering it must not overwrite a
    /// verdict the scan already established.
    @MainActor
    func test_anUnknownReadingDoesNotOverwriteAKnownOne() {
        let model = editor()
        model.apply(TagObservation(uid: uid, lock: lockedReading()))
        XCTAssertFalse(model.apply(TagObservation(uid: uid, lock: .notRead)))
        XCTAssertEqual(model.lockState, .locked)
        XCTAssertEqual(model.lockMomentCount, 1, "nothing changed, so nothing to announce")
    }

    /// Neither of the two states short of proof takes the Write button away.
    /// `.partlyLocked` leaves a writable half, and `.writtenNotWitnessed` is an
    /// absence of proof: acting on it would be making the claim we declined to.
    @MainActor
    func test_onlyAProvenLockBlocksWriting() {
        for (finding, expected) in [
            (TagLockFinding.someSet, false),
            (TagLockFinding.setNotWitnessed, false),
            (TagLockFinding.allSet, true),
        ] {
            let model = editor()
            var reading = TagLockReading()
            reading.record(.dynamicLock, finding)
            reading.record(.staticLock, finding)
            model.apply(TagObservation(uid: uid, lock: reading))
            XCTAssertEqual(model.isWriteBlocked, expected, "for \(finding)")
        }
    }

    // MARK: - Protection, and the intent it must not cancel

    @MainActor
    func test_aProtectionReadingRebasesTheBaselineAndTheIntent() {
        let model = editor()
        let armed = TagProtection(passwordProtect: true, protectFromPage: 4, readProtect: false)
        XCTAssertTrue(model.apply(TagObservation(uid: uid, protection: armed)))
        XCTAssertTrue(model.protection.passwordProtect, "the card now shows the state the tag is in")
        XCTAssertTrue(model.originalProtection.passwordProtect)
        XCTAssertFalse(model.wantsProtectionRemoved)
        XCTAssertEqual(model.protectionMomentCount, 1)
    }

    /// The bug this guard exists for. A user who has toggled protection off in
    /// the Protection card and not written yet has a pending removal; a reading
    /// that says "the tag is protected" must rebase the baseline and leave that
    /// intent alone, or the next write silently skips the removal.
    @MainActor
    func test_aReadingDoesNotCancelAStagedChange() {
        let armed = TagProtection(passwordProtect: true, protectFromPage: 4)
        let model = editor(protection: armed)
        model.protection = .none
        XCTAssertTrue(model.wantsProtectionRemoved)

        model.apply(TagObservation(uid: uid, protection: armed))

        XCTAssertFalse(model.protection.passwordProtect, "the user's staged removal survives")
        XCTAssertTrue(model.originalProtection.passwordProtect)
        XCTAssertTrue(model.wantsProtectionRemoved, "and the write still knows to remove it")
    }

    /// The bench defect of 2026-09-22, on an NTAG213.
    ///
    /// An arm staged in the Protection card and the same arm read back off the
    /// tag describe one state in two vocabularies: the card stages "derive the
    /// start page" and "I hold a credential", while the read-back reports page 4
    /// and can report no credential at all, because a PWD is not readable.
    /// Compared whole they are unequal forever, so the removal the owner then
    /// ran from the Operations sheet could not reach the card. The card went on
    /// saying "Password, write-only" about an open tag, and the next write would
    /// have armed it again with the password that had just been removed.
    @MainActor
    func test_anIntentTheTagHasReachedDoesNotOutliveIt() {
        let model = editor()
        model.protection = TagProtection(passwordProtect: true, hasStoredCredential: true)
        model.protectionCredential = .type2(
            password: Data([0xC0, 0xC1, 0xC2, 0xC3]), pack: Data([0xD0, 0xD1])
        )

        // The editor's own arm, read back off the tag.
        model.apply(TagObservation(
            uid: uid, protection: TagProtection(passwordProtect: true, protectFromPage: 4)
        ))
        XCTAssertTrue(model.protection.passwordProtect, "still armed, and the card agrees")

        // Operations removes it on the next tap.
        model.apply(TagObservation(uid: uid, protection: TagProtection.none))

        XCTAssertFalse(model.protection.passwordProtect, "the card follows the tag")
        XCTAssertFalse(model.originalProtection.passwordProtect)
        XCTAssertNil(model.pendingProtection(), "and the next write does not arm it again")
        XCTAssertNotNil(model.protectionCredential, "the secret still survives a reading")
    }

    /// The narrower half of the same guard. Staging a read gate on a tag that is
    /// already write-protected changes no `passwordProtect`, so the intent has to
    /// be recognised as unreached on a field the reading *can* speak about, or
    /// the next reading silently cancels it.
    @MainActor
    func test_aStagedReadGateSurvivesAReadingThatHasNotReachedIt() {
        let armed = TagProtection(passwordProtect: true, protectFromPage: 4, readProtect: false)
        let model = editor(protection: armed)
        model.protection.readProtect = true

        model.apply(TagObservation(uid: uid, protection: armed))

        XCTAssertTrue(model.protection.readProtect, "the staged read gate survives")
        XCTAssertFalse(model.originalProtection.readProtect, "and the baseline still says what the tag said")
    }

    /// The second half of the 2026-09-22 bench sitting. An erase run from the
    /// Operations sheet cleared the tag and the editor went on listing the
    /// record it had cleared, because `TagObservation` had no field for the data
    /// area and the erase could only say `ndefReadable: true`, which answers a
    /// different question.
    ///
    /// The list is not only displayed. `dataAreaChange` is built from it, so the
    /// next write put the record back on a tag the owner had just erased.
    @MainActor
    func test_anEraseElsewhereClearsTheEditorsRecords() {
        let model = editor()
        model.records = [.uri(URIRecord(uri: "https://hex.pro"))]
        model.markClean()
        XCTAssertFalse(model.isDirty)

        model.apply(TagObservation(uid: uid, records: []))

        XCTAssertTrue(model.records.isEmpty, "the editor follows the tag")
        XCTAssertFalse(model.isDirty, "and an unedited editor stays unedited")
        XCTAssertEqual(model.dataAreaChange, .replace([]), "the next write does not put it back")
    }

    /// The mirror, and the reason the branch is guarded at all. A reading must
    /// not throw away records the owner is part way through editing.
    @MainActor
    func test_aReadingDoesNotDiscardRecordsBeingEdited() {
        let model = editor()
        model.records = [.uri(URIRecord(uri: "https://hex.pro"))]
        model.markClean()
        model.records.append(.uri(URIRecord(uri: "https://apps.hex.pro")))
        XCTAssertTrue(model.isDirty)

        model.apply(TagObservation(uid: uid, records: []))

        XCTAssertEqual(model.records.count, 2, "the edit in progress survives")
        XCTAssertTrue(model.isDirty, "and the write still knows there is something to write")
    }

    @MainActor
    func test_aProtectionReadingClearsTheUnknownFlag() {
        let model = editor(protectionIsUnknown: true)
        model.apply(TagObservation(uid: uid, protection: TagProtection.none))
        XCTAssertFalse(model.protectionIsUnknown)
    }

    /// A read-back is a projection and it loses fields. Merging is what stops it
    /// erasing something the editor already knew.
    @MainActor
    func test_theMergePreservesWhatAReadBackCannotSee() {
        let known = TagProtection(
            passwordProtect: true, protectFromPage: 16, readProtect: true, hasStoredCredential: true
        )
        let model = editor(protection: known)
        // What a read-gated Type-2 projection looks like: protected, no page.
        let projection = TagProtection(passwordProtect: true, protectFromPage: nil, readProtect: true)
        model.apply(TagObservation(uid: uid, protection: projection))

        XCTAssertEqual(model.originalProtection.protectFromPage, 16)
        XCTAssertTrue(model.originalProtection.hasStoredCredential)
    }

    /// A credential the app holds for a tag that does not have it is harmless
    /// clutter. A credential the tag holds and the app does not is a dead tag.
    /// That asymmetry is why a reading may never discard one.
    @MainActor
    func test_aReadingNeverClearsTheCredential() {
        let model = editor(protection: TagProtection(passwordProtect: true, protectFromPage: 4))
        model.protectionCredential = .type2(password: Data([1, 2, 3, 4]), pack: Data([5, 6]))
        model.apply(TagObservation(uid: uid, protection: TagProtection.none))
        XCTAssertNotNil(model.protectionCredential)
    }

    // MARK: - Formatting

    @MainActor
    func test_aFormatReadingClearsTheUnformattedNotice() {
        let model = EditFlowModel(
            tag: ScannedTagInfo(
                uidHex: uid.hexString, supportsPasswordProtection: true,
                formatState: .noCapabilityContainer
            ),
            origin: .liveScan
        )
        XCTAssertTrue(model.apply(TagObservation(uid: uid, formatted: true)))
        XCTAssertEqual(
            model.tag?.formatState, .unknown,
            "a Capability Container read back refutes 'no Capability Container' and nothing else"
        )
    }

    /// The other half, and the one that matters for a tag whose Capability
    /// Container was never the problem. A format reads page 3 and writes
    /// nothing; it establishes nothing whatever about the data area, so it may
    /// not clear a notice that is about the data area.
    @MainActor
    func test_aFormatReadingDoesNotClearAnUnreadableDataArea() {
        let model = EditFlowModel(
            tag: ScannedTagInfo(
                uidHex: uid.hexString, supportsPasswordProtection: true,
                formatState: .unreadableDataArea
            ),
            origin: .liveScan
        )
        XCTAssertFalse(model.apply(TagObservation(uid: uid, formatted: true)))
        XCTAssertEqual(model.tag?.formatState, .unreadableDataArea)
    }

    /// What does clear it: a message read back off the tag. That walks the whole
    /// structure, so it is the one observation strong enough to say so.
    @MainActor
    func test_anNDEFReadBackClearsAnUnreadableDataArea() {
        let model = EditFlowModel(
            tag: ScannedTagInfo(
                uidHex: uid.hexString, supportsPasswordProtection: true,
                formatState: .unreadableDataArea
            ),
            origin: .liveScan
        )
        XCTAssertTrue(model.apply(TagObservation(uid: uid, ndefReadable: true)))
        XCTAssertEqual(model.tag?.formatState, .readable)
    }

    // MARK: - Merging, and the sequence that used to lose a lock

    /// One tap establishes one kind of fact, so a later reading's `nil` means
    /// "this run did not look", never "and it is not so". Operations is a stack
    /// of tiles and running two operations in one visit is ordinary; replacing
    /// rather than folding is how a permanent lock followed by a password
    /// removal arrived carrying no lock at all.
    func test_mergingKeepsAnEarlierRunsFactsAlongsideALaterRuns() {
        var lock = TagLockReading()
        lock.record(.dynamicLock, .allSet)
        lock.record(.staticLock, .allSet)
        let locked = TagObservation(uid: uid, lock: lock)
        let unprotected = TagObservation(uid: uid, protection: TagProtection.none)

        let merged = locked.merging(unprotected)
        XCTAssertEqual(merged.lock?.state, .locked, "the lock survives the later reading")
        XCTAssertEqual(merged.protection?.passwordProtect, false)
    }

    /// Every field, including the newest one. An erase establishes that the tag
    /// reads; a password removal after it in the same visit establishes nothing
    /// about that, and must not erase the knowledge by arriving with `nil`.
    func test_mergingCarriesEveryField() {
        let erased = TagObservation(uid: uid, formatted: true, ndefReadable: true)
        let removed = TagObservation(uid: uid, protection: TagProtection.none)

        let merged = erased.merging(removed)
        XCTAssertEqual(merged.ndefReadable, true, "a later reading's nil means 'did not look'")
        XCTAssertEqual(merged.formatted, true)
        XCTAssertEqual(merged.protection?.passwordProtect, false)
        XCTAssertFalse(merged.isEmpty)
    }

    func test_mergingAReadingAboutAnotherTagReplacesRatherThanFolds() {
        var lock = TagLockReading()
        lock.record(.staticLock, .allSet)
        let mine = TagObservation(uid: uid, lock: lock)
        let theirs = TagObservation(uid: otherUID, protection: TagProtection.none)

        let merged = mine.merging(theirs)
        XCTAssertEqual(merged.uid, otherUID)
        XCTAssertNil(merged.lock, "two different tags' facts are not folded together")
    }

    /// The end-to-end shape of the same bug, through `apply`.
    @MainActor
    func test_aLockThenAPasswordRemovalLeavesTheTagLocked() {
        let model = editor(protection: TagProtection(passwordProtect: true, protectFromPage: 4))
        let locked = TagObservation(uid: uid, lock: lockedReading())
        let removed = TagObservation(uid: uid, protection: TagProtection.none)

        model.apply(locked.merging(removed))

        XCTAssertEqual(model.lockState, .locked)
        XCTAssertTrue(model.isWriteBlocked)
        XCTAssertFalse(model.originalProtection.passwordProtect)
    }

    /// The moment counters drive a haptic. Re-delivering the same reading, which
    /// a retry or a twice-drained latch can do, must not fire it at a card that
    /// did not move.
    @MainActor
    func test_anIdenticalReadingFiresNoMoment() {
        let model = editor()
        let observation = TagObservation(
            uid: uid, protection: TagProtection(passwordProtect: true, protectFromPage: 4), lock: lockedReading()
        )
        XCTAssertTrue(model.apply(observation))
        XCTAssertEqual(model.lockMomentCount, 1)
        XCTAssertEqual(model.protectionMomentCount, 1)

        XCTAssertFalse(model.apply(observation), "nothing changed the second time")
        XCTAssertEqual(model.lockMomentCount, 1)
        XCTAssertEqual(model.protectionMomentCount, 1)
    }

    @MainActor
    func test_anEmptyObservationChangesNothing() {
        let model = editor()
        XCTAssertFalse(model.apply(TagObservation(uid: uid)))
        XCTAssertEqual(model.lockMomentCount, 0)
        XCTAssertEqual(model.protectionMomentCount, 0)
    }
}
