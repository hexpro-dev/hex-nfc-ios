import HexNFCKit
import HexNFCRecords
import HexNFCTagSim
import XCTest

/// What an erase leaves behind, and why the screen says so.
///
/// `CoreNFCSession.writeNDEFViaPages` writes `padded.count / 4` pages from the
/// start of the NDEF region and touches nothing else. An erase is
/// `writeNDEF([])`, which encodes to `03 00 FE` padded to `03 00 FE 00`: one
/// page. On an NTAG216 whose region is pages 4 to 225 that rewrites page 4 and
/// leaves 5 to 225 exactly as they were.
///
/// This is scoped to the Type-2 page path on purpose. That is where the
/// 2026-09-09 HG-1 sweep read the old message back out of the pages behind the
/// terminator, on the tags it looked at: three NTAG213s, an NTAG216, a UL EV1
/// 128 and three Ultralight Cs. What the Type-4 and Type-5 write paths leave is
/// a different question, it goes through nfcd rather than through page writes,
/// and no sitting in this repo has traced it. Nothing here claims anything
/// about them.
final class EraseResidueTests: XCTestCase {
    private func region(of sim: NTAG21xSimulator) throws -> [Data] {
        let range = try XCTUnwrap(sim.profile?.memoryLayout.ndefRange)
        return range.map { sim.pages[$0] }
    }

    /// The simulator used to zero the rest of the region after the new envelope,
    /// which is the opposite of what production does. A simulator tidier than the
    /// chip hides exactly the residue a user meets.
    func test_erase_rewritesOnePageAndLeavesTheRestOfTheRegionAlone() throws {
        let message = try NDEFCodec.encode([NDEFRecord.uri(URIRecord(uri: "https://hex.pro/a-long-enough-url"))])
        let sim = NTAG216Simulator(ndefMessage: message)
        let before = try region(of: sim)
        XCTAssertGreaterThan(before.count, 4, "the fixture needs a region longer than one page")

        try sim.writeNDEF(Type2NDEF.wrap(message: NDEFCodec.encode([])))

        let after = try region(of: sim)
        XCTAssertEqual(
            after[0], Data([0x03, 0x00, 0xFE, 0x00]),
            "the empty envelope is one page: length 0, terminator, one byte of padding"
        )
        XCTAssertEqual(
            Array(after.dropFirst()), Array(before.dropFirst()),
            "every page past the new envelope holds exactly what it held before. This is the residue "
                + "the Erase screen's copy describes, and the reason it stopped saying the records are "
                + "permanently removed."
        )
        XCTAssertTrue(
            after.dropFirst().contains { $0.contains(0x68) },
            "and the old message is still legible in those pages, not merely unchanged"
        )
    }

    /// A reader is unaffected, which is the half the old comment was right about:
    /// a TLV reader stops at the message length, so the tag presents the new
    /// message and nothing else. Both halves are true at once, and the screen now
    /// says both.
    func test_erase_leavesTheTagReadingAsBlankDespiteTheResidue() throws {
        let message = try NDEFCodec.encode([NDEFRecord.uri(URIRecord(uri: "https://hex.pro/a-long-enough-url"))])
        let sim = NTAG216Simulator(ndefMessage: message)

        try sim.writeNDEF(Type2NDEF.wrap(message: NDEFCodec.encode([])))

        // `readNDEF()` unwraps the TLV itself and answers empty for a region with
        // no message, which is what the reader path does.
        XCTAssertEqual(try sim.readNDEF(), Data(), "readers see a blank tag, residue behind it or not")
    }

    // MARK: - Replayed from silicon

    /// The erase frame production sent to a delivered NTAG213, and what the tag
    /// read back after it.
    ///
    /// Tag B `04:8F:DB:3A:D6:1F:90`, unprotected (`AUTH0 = FF`), 2026-09-10
    /// 11:39:18, `docs/internal/bench-traces/2026-09-10-t2-1-ntag213.log`:
    ///
    ///     <- READ p3  E1:10:12:00:01:03:A0:0C:34:03:00:FE:00:00:00:00
    ///     -> NDEF WRITE p4  A2:04:03:00:FE:00
    ///     <- 0A
    ///     <- READ p3  E1:10:12:00:03:00:FE:00:34:03:00:FE:00:00:00:00
    ///
    /// Tag A `04:A9:DB:3A:D6:1F:90` gave the same image at 11:10:06 through the
    /// same frame. Page 5 keeps the delivery prologue's second page, `34 03 00 FE`
    /// (the last byte of the Lock Control TLV, then the old empty message and its
    /// terminator), behind the new one. Before the simulator held the delivery
    /// prologue there was nothing in page 5 for a replay to keep.
    func test_theCapturedEraseFrame_onADeliveredNTAG213_leavesTheMeasuredImage() {
        let sim = NTAG213Simulator()

        XCTAssertEqual(sim.handle(command: Data([0xA2, 0x04, 0x03, 0x00, 0xFE, 0x00])), Data([0x0A]))
        XCTAssertEqual(
            sim.handle(command: Data([0x30, 0x03])),
            Data([0xE1, 0x10, 0x12, 0x00, 0x03, 0x00, 0xFE, 0x00, 0x34, 0x03, 0x00, 0xFE, 0x00, 0x00, 0x00, 0x00])
        )
    }

    /// **This pins a known divergence, not a correct image.**
    ///
    /// `SimulatedConnectedTag.writeNDEF([])` substitutes an Empty record
    /// `D0 00 00` for an empty message, so the simulated erase is two pages where
    /// production's is the one frame above. On a delivered NTAG213 that overwrites
    /// page 5 as well, which silicon keeps. `bench-fixes-2026-09.md` section 4.6
    /// records why it has not been removed: taking it out makes `NDEFCodec.decode`
    /// throw on the zero-length message an erased tag holds, and that is a codec
    /// decision with its own spec. When it lands, this test should fail and be
    /// rewritten to expect the image above.
    func test_theSimulatedSessionErase_stillDivergesFromThatCapture() async throws {
        let sim = NTAG213Simulator()
        let tag = try await SimulatedSession(chip: sim).start(alert: "")

        try await tag.writeNDEF([])

        let after = try region(of: sim)
        XCTAssertEqual(
            after[0] + after[1],
            Data([0x03, 0x03, 0xD0, 0x00, 0x00, 0xFE, 0x00, 0x00]),
            "If pages 4 and 5 now read 03 00 FE 00 | 34 03 00 FE, bench-fixes-2026-09.md section 4.6 has "
                + "landed and the simulated erase matches silicon. Rewrite this test to expect that image, as "
                + "test_theCapturedEraseFrame_onADeliveredNTAG213_leavesTheMeasuredImage does."
        )
    }
}
