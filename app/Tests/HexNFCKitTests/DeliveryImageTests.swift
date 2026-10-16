import HexNFCKit
import HexNFCTagSim
import XCTest

/// The simulator holds what a real tag holds, on the bytes a real tag has been
/// read on.
///
/// Every value here was measured on silicon and written down in
/// `docs/internal/chip-config-pages.md`: the 2026-09-09 delivery-state survey
/// read the unlocked dies and the HG-1 sweep the locked ones, and the 2026-09-10
/// T2-1 sitting (`docs/internal/bench-traces/2026-09-10-t2-1-ntag213.log`) read
/// two more NTAG213 on first contact. The NTAG 210µ data area also rests on its
/// datasheet's delivery table. Nothing is seeded for a variant no tag was read
/// on, and the negative tests say which those are, so a later tidy-up that makes
/// them all consistent has to argue with a test first.
///
/// The bytes are bytes, not meanings. This file asserts what the pages hold and
/// nothing about why, and nothing in the repo may branch on them. The config and
/// lock bytes are here so the read-modify-write rule has something to preserve;
/// the data-area prologue is here so a scan meets a factory-shaped data area and
/// an erase has something to leave behind. What the prologue *parses* to is
/// pinned where parsing is the subject, in `Type2NDEFTests` and
/// `UnformattedTagTests`.
final class DeliveryImageTests: XCTestCase {
    private func dynamicLockPage(of sim: NTAG21xSimulator) throws -> Data {
        let page = try XCTUnwrap(sim.profile?.memoryLayout.dynamicLockPage)
        return sim.pages[page]
    }

    private func configPages(
        of sim: NTAG21xSimulator, _ variant: Type2Variant
    ) throws -> (config0: Data, config1: Data) {
        let layout = try XCTUnwrap(Type2ConfigLayout.for(variant))
        return (sim.pages[layout.config0Page], sim.pages[layout.config1Page])
    }

    // MARK: - The dynamic lock page on delivery

    /// Byte 3 is RFUI and reads back as the die's own `BD` whatever is written to
    /// it, so an unlocked tag carries it too. The simulator answered
    /// `00 00 00 00` until 2026-09-09, which is a state no NTAG21x has ever been
    /// in, and it is the half of finding 8 that bites a fixture taken from the
    /// simulator rather than from a tag.
    func test_deliveredDynamicLockPage_carriesTheChipsOwnByteThree() throws {
        XCTAssertEqual(try dynamicLockPage(of: NTAG213Simulator()), Data([0x00, 0x00, 0x00, 0xBD]))
        XCTAssertEqual(try dynamicLockPage(of: NTAG216Simulator()), Data([0x00, 0x00, 0x00, 0xBD]))
        XCTAssertEqual(
            try dynamicLockPage(of: MifareUltralightEV1_128Simulator()),
            Data([0x00, 0x00, 0x00, 0xBD])
        )
    }

    /// Unsurveyed. Zeros are a fixture choice here, not a reading, and seeding
    /// `BD` on the strength of the family resemblance would be inventing a byte.
    func test_unsurveyedVariants_keepZerosInTheDynamicLockPage() throws {
        XCTAssertEqual(try dynamicLockPage(of: NTAG215Simulator()), Data([0x00, 0x00, 0x00, 0x00]))
        XCTAssertEqual(try dynamicLockPage(of: NTAG213TTSimulator()), Data([0x00, 0x00, 0x00, 0x00]))
    }

    // MARK: - The dynamic lock page after a permanent lock

    /// The three images HG-1 read off locked silicon.
    ///
    /// Bytes 0-2 are `Type2LockWrite.lockBitMask(for:)`, which is what production
    /// writes, and byte 3 is the same `BD` the delivered tag already had: the
    /// page is one-way, so the lock ORs into it. The simulator used to assign
    /// `FF FF FF 00` for every chip, which sets RFUI bits no die holds and clears
    /// the one byte that survives everything.
    func test_permanentLock_reproducesTheMeasuredLockedImages() throws {
        let ntag213 = NTAG213Simulator()
        try ntag213.permanentLock()
        XCTAssertEqual(
            try dynamicLockPage(of: ntag213), Data([0xFF, 0x0F, 0x3F, 0xBD]),
            "NTAG213, three dies in the 2026-09-09 HG-1 sweep"
        )

        let ntag216 = NTAG216Simulator()
        try ntag216.permanentLock()
        XCTAssertEqual(
            try dynamicLockPage(of: ntag216), Data([0xFF, 0x3F, 0x7F, 0xBD]),
            "NTAG216 04:47:39:92:B9:10:90, 2026-09-09"
        )

        let ev1 = MifareUltralightEV1_128Simulator()
        try ev1.permanentLock()
        XCTAssertEqual(
            try dynamicLockPage(of: ev1), Data([0xFF, 0x03, 0x1F, 0xBD]),
            "UL EV1 128 04:52:5C:5A:60:17:91, 2026-09-09"
        )
    }

    /// Ultralight C is the one die measured to hold `00` in byte 3, in both
    /// states, and it has its own simulator that already produces the measured
    /// answer. Nothing in this cluster may change it, and this test is here so
    /// that a later pass at consistency has to notice.
    func test_ultralightC_isUnaffectedAndStillMatchesItsOwnCapture() throws {
        let sim = MifareUltralightCSimulator()
        XCTAssertEqual(sim.pages[40], Data([0x00, 0x00, 0x00, 0x00]))
        try sim.permanentLock()
        XCTAssertEqual(sim.pages[40], Data([0xFF, 0xFF, 0x00, 0x00]), "measured 2026-09-09")
    }

    // MARK: - Configuration pages on delivery

    /// CFG0 byte 0 and CFG1 byte 1 as three delivered tags read them back.
    ///
    /// They are here so the read-modify-write in
    /// `Type2Credential.config0(settingAuth0:)` and
    /// `config1(readProtect:authLimit:)` has something to preserve, and so a
    /// constructed page fails a test instead of passing one.
    func test_deliveredConfigPages_carryTheSurveyedBytes() throws {
        let ntag213 = try configPages(of: NTAG213Simulator(), .ntag213)
        XCTAssertEqual(ntag213.config0, Data([0x04, 0x00, 0x00, 0xFF]))
        XCTAssertEqual(ntag213.config1, Data([0x00, 0x05, 0x00, 0x00]))

        let ntag216 = try configPages(of: NTAG216Simulator(), .ntag216)
        XCTAssertEqual(ntag216.config0, Data([0x04, 0x00, 0x00, 0xFF]))
        XCTAssertEqual(ntag216.config1, Data([0x00, 0x05, 0x00, 0x00]))

        let ev1 = try configPages(of: MifareUltralightEV1_128Simulator(), .mifareUltralightEV1_128)
        XCTAssertEqual(ev1.config0, Data([0x00, 0x00, 0x00, 0xFF]), "CFG0 byte 0 is 00 on EV1, not 04")
        XCTAssertEqual(ev1.config1, Data([0x00, 0x05, 0x00, 0x00]))
    }

    /// Unsurveyed. AUTH0 still defaults to `FF` so the tag is unprotected, and
    /// every other byte stays zero rather than borrowing a sibling's.
    func test_unsurveyedVariants_keepZeroConfigPages() throws {
        let ntag215 = try configPages(of: NTAG215Simulator(), .ntag215)
        XCTAssertEqual(ntag215.config0, Data([0x00, 0x00, 0x00, 0xFF]))
        XCTAssertEqual(ntag215.config1, Data([0x00, 0x00, 0x00, 0x00]))

        let ev148 = try configPages(of: MifareUltralightEV1_48Simulator(), .mifareUltralightEV1_48)
        XCTAssertEqual(ev148.config0, Data([0x00, 0x00, 0x00, 0xFF]))
        XCTAssertEqual(ev148.config1, Data([0x00, 0x00, 0x00, 0x00]))
    }

    // MARK: - The data area on delivery

    private func dataAreaPrologue(of sim: NTAG21xSimulator) throws -> Data {
        let start = try XCTUnwrap(sim.profile?.memoryLayout.ndefRange?.lowerBound)
        return sim.pages[start ..< start + 3].reduce(Data(), +)
    }

    /// The frame a delivered NTAG213 answers to `30 03`, byte for byte.
    ///
    /// Tag A `04:A9:DB:3A:D6:1F:90` at 10:49:47 and tag B `04:8F:DB:3A:D6:1F:90`
    /// at 11:35:22 on 2026-09-10, each on its first scan and before anything was
    /// written to it. A fresh simulator used to answer the same Capability
    /// Container over twelve zero bytes: NULL TLVs, no message, no terminator.
    func test_deliveredNTAG213_answersTheCapturedFrame() {
        let sim = NTAG213Simulator()

        XCTAssertEqual(
            sim.handle(command: Data([0x30, 0x03])),
            Data([0xE1, 0x10, 0x12, 0x00, 0x01, 0x03, 0xA0, 0x0C, 0x34, 0x03, 0x00, 0xFE, 0x00, 0x00, 0x00, 0x00])
        )
    }

    /// NTAG 210µ carries no Lock Control TLV. Rev 3.0 Table 4 gives page 04h as
    /// `03 00 FE 00` and three surveyed tags read it. The simulator's class doc
    /// has said so all along while its pages held zeros.
    func test_deliveredNTAG210Micro_holdsTheDatasheetsEmptyMessage() throws {
        let sim = NTAG210MicroSimulator()

        XCTAssertEqual(
            try dataAreaPrologue(of: sim),
            Data([0x03, 0x00, 0xFE, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        )
    }

    /// No delivery reading exists for these, and each has its own reason. Zeros
    /// are the fixture choice that says so, not a reading.
    func test_variantsWithNoDeliveryReading_keepAZeroDataArea() throws {
        let zeros = Data(repeating: 0x00, count: 12)

        XCTAssertEqual(
            try dataAreaPrologue(of: NTAG216Simulator()), zeros,
            "NTAG216 reads 03 00 FE 00, which is byte for byte this app's erase, and no datasheet table in "
                + "the repo settles which it was"
        )
        XCTAssertEqual(
            try dataAreaPrologue(of: MifareUltralightEV1_128Simulator()), zeros,
            "the surveyed UL EV1 128 had been erased while virgin, so it is not a delivery reading at all"
        )
        XCTAssertEqual(try dataAreaPrologue(of: NTAG215Simulator()), zeros, "unsurveyed")
        XCTAssertEqual(try dataAreaPrologue(of: NTAG213TTSimulator()), zeros, "unsurveyed")
        XCTAssertEqual(try dataAreaPrologue(of: MifareUltralightEV1_48Simulator()), zeros, "unsurveyed")
    }
}
