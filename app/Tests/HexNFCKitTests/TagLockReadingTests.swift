@testable import HexNFCKit
import XCTest

/// The verdict table for `TagLockReading.state`, one test per reachable shape.
///
/// A pure value type with no I/O, and the place the "half the evidence is not a
/// whole-tag verdict" rule is actually enforced. Every row here is a state a
/// real tag can be in; the two that this repo has produced on silicon (the
/// 2026-09-04 half-burn and the Ultralight C write that cannot be witnessed in
/// its own activation) are called out by name.
final class TagLockReadingTests: XCTestCase {
    private func reading(_ pairs: [(TagLockRegion, TagLockFinding)]) -> TagLockReading {
        var value = TagLockReading()
        for (region, finding) in pairs {
            value.record(region, finding)
        }
        return value
    }

    func test_nothingRecorded_isUnknown() {
        XCTAssertEqual(TagLockReading.notRead.state, .unknown)
    }

    func test_factoryChip_isOpen() {
        XCTAssertEqual(
            reading([(.dynamicLock, .noneSet), (.staticLock, .noneSet)]).state, .open
        )
    }

    func test_bothRegionsReadBackSet_isLocked() {
        XCTAssertEqual(
            reading([(.dynamicLock, .allSet), (.staticLock, .allSet)]).state, .locked
        )
    }

    /// The 2026-09-04 incident: page 2 sits below AUTH0 so the static bytes
    /// burned, page 0x28 sits above it so the dynamic write was NAKed.
    func test_staticBurnedDynamicClear_isPartlyLocked() {
        XCTAssertEqual(
            reading([(.dynamicLock, .noneSet), (.staticLock, .allSet)]).state, .partlyLocked
        )
    }

    func test_dynamicBurnedStaticRefused_isPartlyLocked() {
        XCTAssertEqual(
            reading([(.dynamicLock, .allSet), (.staticLock, .noneSet)]).state, .partlyLocked
        )
    }

    /// NTAG 210u has no dynamic lock page, so its static bytes are the whole
    /// story and a completed lock is a complete verdict.
    func test_chipWithNoDynamicPage_isLockedFromTheStaticBytesAlone() {
        XCTAssertEqual(
            reading([(.dynamicLock, .notPresent), (.staticLock, .allSet)]).state, .locked
        )
    }

    func test_chipWithNoDynamicPage_isOpenFromTheStaticBytesAlone() {
        XCTAssertEqual(
            reading([(.dynamicLock, .notPresent), (.staticLock, .noneSet)]).state, .open
        )
    }

    /// Half the evidence is not a whole-tag verdict. A read-gated tag whose
    /// static bytes are clear must not read as "not locked", because the region
    /// that was not read is the larger one.
    func test_oneRegionUnread_andNothingBurned_isUnknown() {
        XCTAssertEqual(
            reading([
                (.dynamicLock, .notRead(reason: "gated")),
                (.staticLock, .noneSet),
            ]).state,
            .unknown
        )
    }

    /// The one exception: an irreversible burn is still reported when the other
    /// region is unknown, because "not locked" is certainly wrong about a tag
    /// that has already burned half its lock bits.
    func test_oneRegionUnread_withTheOtherBurned_isPartlyLocked() {
        XCTAssertEqual(
            reading([
                (.dynamicLock, .notRead(reason: "gated")),
                (.staticLock, .allSet),
            ]).state,
            .partlyLocked
        )
    }

    func test_acknowledgedButUnwitnessed_isNeverLocked() {
        XCTAssertEqual(
            reading([
                (.dynamicLock, .setNotWitnessed),
                (.staticLock, .setNotWitnessed),
            ]).state,
            .writtenNotWitnessed
        )
    }

    func test_oneRegionProvenTheOtherAcknowledged_isStillNotLocked() {
        XCTAssertEqual(
            reading([(.dynamicLock, .allSet), (.staticLock, .setNotWitnessed)]).state,
            .writtenNotWitnessed
        )
    }

    func test_someBitsSet_isPartlyLocked() {
        XCTAssertEqual(
            reading([(.dynamicLock, .someSet), (.staticLock, .allSet)]).state, .partlyLocked
        )
    }

    func test_everyRegionAbsent_isUnknownRatherThanOpen() {
        XCTAssertEqual(
            reading([(.dynamicLock, .notPresent), (.staticLock, .notPresent)]).state, .unknown
        )
    }

    // MARK: - Mapping a permanent lock's own outcome

    private func outcome(_ pairs: [(PermanentLockOutcome.Stage, PermanentLockOutcome.StageResult)])
        -> PermanentLockOutcome
    {
        var value = PermanentLockOutcome()
        for (stage, result) in pairs {
            value.record(stage, result)
        }
        return value
    }

    func test_outcome_completeLockWithAWitnessedStaticRegion_isLocked() {
        let reading = TagLockReading(
            outcome([
                (.dynamicLock, .committedVerified),
                (.staticLock, .committedUnverified(reason: "no bench capture yet")),
            ]),
            staticRegionWitnessed: true
        )
        XCTAssertEqual(reading.state, .locked)
    }

    /// The Ultralight C shape. Its lock bits are valid at the next REQA, so the
    /// behavioural probe cannot witness them and the verdict must stop short of
    /// `.locked` rather than claim a proof it does not have.
    func test_outcome_completeLockWithNoWitness_isWrittenNotWitnessed() {
        let reading = TagLockReading(
            outcome([
                (.dynamicLock, .committedVerified),
                (.staticLock, .committedUnverified(reason: "no bench capture yet")),
            ]),
            staticRegionWitnessed: false
        )
        XCTAssertEqual(reading.state, .writtenNotWitnessed)
    }

    /// A witnessed page-4 write refusal proves the **static** region only. It
    /// must never promote a dynamic stage the app's own read-back found clear.
    func test_outcome_witnessDoesNotReachTheDynamicRegion() {
        let reading = TagLockReading(
            outcome([
                (.dynamicLock, .refused(diagnostics: "NAK")),
                (.staticLock, .committedUnverified(reason: "no bench capture yet")),
            ]),
            staticRegionWitnessed: true
        )
        XCTAssertTrue(reading.regions[.dynamicLock]?.isUnread == true)
        XCTAssertEqual(reading.regions[.staticLock], .allSet)
        XCTAssertEqual(reading.state, .partlyLocked)
    }

    /// A refusal says this *stage* burned nothing. It does not say the region was
    /// clear before the tap, and a lock write is refused precisely when the chip
    /// will not discuss the page. Reporting `.noneSet` would turn "we were told
    /// no" into "we read it and no bit is set", which is the defect class this
    /// whole branch exists to remove: on a tag whose static bytes an earlier
    /// partial lock had already burned, a later refusal would flip the card back
    /// to Off.
    func test_outcome_aRefusalIsNotAReading() {
        let reading = TagLockReading(
            outcome([
                (.dynamicLock, .refused(diagnostics: "NAK")),
                (.staticLock, .refused(diagnostics: "NAK")),
            ]),
            staticRegionWitnessed: false
        )
        XCTAssertTrue(reading.regions[.dynamicLock]?.isUnread == true)
        XCTAssertNotEqual(reading.state, .open, "a refusal never earns 'not locked'")
        XCTAssertEqual(reading.state, .unknown)
    }

    /// The pre-flight refusal: the dynamic write was NAKed and the static write
    /// never went out. Nothing burned, and nothing was read, so the tag's lock
    /// state is exactly as unknown as it was before the tap.
    func test_outcome_refusedBeforeAnythingBurned_isUnknown() {
        let reading = TagLockReading(
            outcome([
                (.dynamicLock, .refused(diagnostics: "gated")),
                (.staticLock, .notAttempted),
            ]),
            staticRegionWitnessed: false
        )
        XCTAssertEqual(reading.state, .unknown)
    }

    /// `isPartial` is false for this outcome, because it folds
    /// `.committedUnverified` into `committed` and the static stage here is
    /// `.inconclusive`. Region-by-region mapping still reports the burn.
    func test_outcome_isPartialWouldMissThis_butTheRegionsDoNot() {
        let source = outcome([
            (.dynamicLock, .committedVerified),
            (.staticLock, .inconclusive(diagnostics: "no answer")),
        ])
        XCTAssertFalse(source.isPartial, "guards the reason this mapping does not use isPartial")
        XCTAssertEqual(TagLockReading(source, staticRegionWitnessed: false).state, .partlyLocked)
    }

    func test_outcome_type5PartialBlockLock_isPartlyLocked() {
        let reading = TagLockReading(
            outcome([(.blocks, .partiallyCommitted(locked: 40, of: 80, diagnostics: "refused at 40"))]),
            staticRegionWitnessed: false
        )
        XCTAssertEqual(reading.state, .partlyLocked)
    }

    func test_outcome_carriesDiagnosticsForTheBugReport() {
        let source = outcome([(.dynamicLock, .committedVerified)])
        XCTAssertEqual(TagLockReading(source, staticRegionWitnessed: false).diagnostics, source.diagnostics)
    }
}
