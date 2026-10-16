@testable import HexNFCApp
@testable import HexNFCKit
@testable import HexNFCTagSim
import XCTest

/// When a tag being taken away is allowed to look like a tag refusing.
///
/// Measured 2026-09-10 (`docs/internal/bench-traces/2026-09-10-t2-1-ntag213.log`,
/// 11:36:24). An **unprotected** NTAG213, `04:8F:DB:3A:D6:1F:90`, was lifted
/// twelve milliseconds into the NDEF read:
///
///     -> READ p3 30:03
///     <- E1:10:12:00:01:03:A0:0C:34:03:00:FE:00:00:00:00
///     .  NDEF read queryNDEFStatus
///     !  Tag connection lost
///
/// The app offered the unlock prompt, telling the owner of an unprotected tag it
/// needed a password. `AUTH0` read `FF` sixty seconds earlier and again after.
/// `ScanFlowModel.isLikelyProtectionFailure` treats `.tagLost` as evidence of
/// protection, and on a read-protected tag it usually is.
///
/// The disproof was already in hand: that `30 03` served a real Capability
/// Container and a complete TLV chain, so nothing above it was gated.
///
/// **The subtlety these tests exist for.** The roll-over check the probe already
/// performed only finds a wrap that starts at page 4. The chip wraps at whatever
/// page is first unreadable, so `AUTH0 = 5` serves pages 3, 4, 0, 1 and
/// `AUTH0 = 6` serves 3, 4, 5, 0, leaving page 0 at a different offset each time.
/// A disproof built on the single check would have called those tags ungated and
/// suppressed the prompt on tags that really were protected, which is worse than
/// the defect it set out to fix.
///
/// **What is not covered here.** The wiring from `ScanFlowModel`'s catch site
/// through to the prompt is not driven end to end, because the fault seam cannot
/// stage it: `FaultInjectingSessionFactory.tagLeavesTheField()` is deliberately
/// all-or-nothing across every entry point, so it cannot let the pre-read succeed
/// and then fail the NDEF read. The decision function and the evidence feeding it
/// are pinned separately below.
final class PrereadDisprovesGatingTests: XCTestCase {
    private func preread(of sim: NTAG21xSimulator) async throws -> TagPreread {
        let tag = try await SimulatedSession(chip: sim).start(alert: "")
        return await ProtectionProbe.preread(of: tag)
    }

    // MARK: - The evidence

    /// The captured tag itself: unprotected, never written, carrying the NTAG213
    /// delivery prologue. The simulator now holds that prologue, so the pre-read
    /// sees the frame from 11:36:24 byte for byte.
    func test_theCapturedDeliveredTagProvesItsChainWasServed() async throws {
        let result = try await preread(of: NTAG213Simulator())

        XCTAssertEqual(result.presence, .answered)
        XCTAssertEqual(
            result.pages3to6,
            Data([0xE1, 0x10, 0x12, 0x00, 0x01, 0x03, 0xA0, 0x0C, 0x34, 0x03, 0x00, 0xFE, 0x00, 0x00, 0x00, 0x00]),
            "the fixture has to be the capture, or this test is about some other tag"
        )
        XCTAssertTrue(result.dataAreaProvenContiguous, "nothing wrapped, so pages 4 to 6 are themselves")
        XCTAssertTrue(
            result.provesTheNDEFChainWasNotGated,
            "the Lock Control TLV, the empty message and the terminator were all served, so a later "
                + "tagLost is the tag leaving rather than the tag refusing"
        )
    }

    /// The same tag after this app's erase: the chain now completes inside page
    /// 4, and page 5 still holds the delivery prologue's second page behind the
    /// new terminator. Tag B read exactly this at 11:39:18, after the one-page
    /// erase frame `A2:04:03:00:FE:00`.
    func test_anUnprotectedErasedTagProvesItsChainWasServed() async throws {
        let sim = NTAG213Simulator()
        try sim.writeNDEF(Type2NDEF.wrap(message: Data()))
        let result = try await preread(of: sim)

        XCTAssertEqual(result.presence, .answered)
        XCTAssertEqual(
            result.pages3to6,
            Data([0xE1, 0x10, 0x12, 0x00, 0x03, 0x00, 0xFE, 0x00, 0x34, 0x03, 0x00, 0xFE, 0x00, 0x00, 0x00, 0x00])
        )
        XCTAssertTrue(result.dataAreaProvenContiguous, "nothing wrapped, so pages 4 to 6 are themselves")
        XCTAssertTrue(
            result.provesTheNDEFChainWasNotGated,
            "a blank tag's whole chain is `03 00 FE` and fits in page 4, so a later tagLost is the tag "
                + "leaving rather than the tag refusing"
        )
    }

    /// A gate at page 4 wraps immediately. The presence verdict already caught
    /// this one, and it must keep catching it.
    func test_aGateAtPageFourIsStillReadProtected() async throws {
        let sim = NTAG213Simulator()
        try sim.enablePasswordProtection(
            password: Data([0xA1, 0xB2, 0xC3, 0xD4]), pack: Data([0x00, 0x00]),
            protectFromPage: 4, readProtect: true, authLimit: 0
        )

        let result = try await preread(of: sim)

        XCTAssertEqual(result.presence, .readProtected)
        XCTAssertFalse(result.provesTheNDEFChainWasNotGated, "a gated tag disproves nothing")
    }

    /// **The objection this test exists for.** A gate at page 5 or 6 wraps later
    /// in the same frame, so the eight-byte check at page 4 does not see it. The
    /// contiguity check has to look at every offset, or a genuinely protected tag
    /// would have its unlock prompt suppressed.
    ///
    /// Each tag is erased first, so its whole chain sits in page 4 and completes
    /// in every frame whatever wrapped after it. That leaves the contiguity check
    /// as the only thing that can refuse the proof. On the delivery prologue the
    /// `AUTH0 = 5` frame breaks the chain on its own (page 0 lands where the rest
    /// of the Lock Control TLV should be), and that iteration would stay green
    /// with the offset-8 check deleted.
    func test_aGateAbovePageFourStillWrapsAndIsNotCalledContiguous() async throws {
        for gate in [5, 6] {
            let sim = NTAG213Simulator()
            try sim.writeNDEF(Type2NDEF.wrap(message: Data()))
            try sim.enablePasswordProtection(
                password: Data([0xA1, 0xB2, 0xC3, 0xD4]), pack: Data([0x00, 0x00]),
                protectFromPage: gate, readProtect: true, authLimit: 0
            )

            let result = try await preread(of: sim)
            let served = try XCTUnwrap(result.pages3to6)

            XCTAssertTrue(
                Type2NDEF.chainCompletes(within: Data(served[4 ..< 16])),
                "AUTH0 = \(gate): the fixture must complete its chain, or contiguity is not what this tests"
            )
            XCTAssertFalse(result.dataAreaProvenContiguous, "AUTH0 = \(gate) wrapped inside the frame")
            XCTAssertFalse(
                result.provesTheNDEFChainWasNotGated,
                "AUTH0 = \(gate) wraps at page \(gate), which the page-4 check cannot see. Calling this "
                    + "tag ungated would suppress the unlock prompt on a tag that is gated."
            )
        }
    }

    // MARK: - The chain predicate

    /// A terminator inside the window is what completes a chain. Reaching the end
    /// of a message is not the same thing.
    func test_chainCompletesOnlyWhenTheTerminatorWasActuallyServed() {
        XCTAssertTrue(
            Type2NDEF.chainCompletes(within: Data([0x03, 0x00, 0xFE, 0x00])),
            "an empty message and its terminator, which is what an erased tag holds"
        )
        XCTAssertTrue(
            Type2NDEF.chainCompletes(within: Data([0x01, 0x03, 0xA0, 0x0C, 0x34, 0x03, 0x00, 0xFE])),
            "a Lock Control TLV then an empty message, which is what a factory NTAG213 holds"
        )
        XCTAssertFalse(
            Type2NDEF.chainCompletes(within: Data([
                0x03,
                0x0A,
                0xD1,
                0x01,
                0x06,
                0x55,
                0x01,
                0x68,
                0x65,
                0x78,
                0x2E,
                0x70,
            ])),
            "a message flush to the window edge with its terminator on the next, unserved page. This is "
                + "the case a first draft got wrong by treating a parsed message as a served chain."
        )
        XCTAssertFalse(
            Type2NDEF.chainCompletes(within: Data([0x03, 0xFF])),
            "a truncated length field establishes nothing"
        )
        XCTAssertFalse(Type2NDEF.chainCompletes(within: Data()), "and neither do no bytes at all")
    }

    // MARK: - The decision

    /// A **stated** refusal is never narrowed. `.authFailed` is the chip saying
    /// no, and it is also the kind `TagError.readProtected` carries, which is a
    /// read-protected tag's only route back to the prompt.
    @MainActor
    func test_aStatedRefusalIsNeverNarrowed() {
        let blank = TagPreread(
            presence: .answered,
            pages3to6: Data([0xE1, 0x10, 0x12, 0x00] + [0x03, 0x00, 0xFE, 0x00] + [UInt8](repeating: 0, count: 8)),
            dataAreaProvenContiguous: true
        )
        XCTAssertTrue(blank.provesTheNDEFChainWasNotGated, "the fixture must be a disproving one")

        XCTAssertFalse(
            ScanFlowModel.prereadDisprovesGating(blank, for: TagError.authFailed()),
            "the chip stated this refusal, so the prompt is the right answer whatever the pre-read saw"
        )
        XCTAssertFalse(
            ScanFlowModel.prereadDisprovesGating(blank, for: TagError.readProtected()),
            "and readProtected carries authFailed's kind for exactly that reason"
        )
        XCTAssertTrue(
            ScanFlowModel.prereadDisprovesGating(blank, for: TagError.tagLost()),
            "a lost tag on a chain that was fully served is a lost tag"
        )
    }

    /// With no proof, nothing changes. Every tag without a 7-byte UID lands here,
    /// because a roll-over cannot be recognised without one.
    @MainActor
    func test_withoutProofTheOldBehaviourStands() {
        let unproven = TagPreread(presence: .answered, pages3to6: nil)

        XCTAssertFalse(
            ScanFlowModel.prereadDisprovesGating(unproven, for: TagError.tagLost()),
            "no evidence is not evidence of absence, and the prompt is the safer default"
        )
    }
}
