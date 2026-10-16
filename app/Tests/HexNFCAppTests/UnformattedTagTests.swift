@testable import HexNFCApp
@testable import HexNFCKit
@testable import HexNFCRecords
@testable import HexNFCTagSim
import XCTest

/// "Blank" and "unformatted" are different tags, and the app used to render them
/// identically.
///
/// A factory MIFARE Ultralight C ships with page 3 blank (MF0ICU2 rev 3.3
/// Table 13), so it has no Capability Container and no reader can see an NDEF
/// message on it. Scanning one looked exactly like scanning an empty NTAG213:
/// "No NDEF records on this tag". The user then added a record, tapped Write,
/// and the write's verify read failed with "This tag does not support that
/// operation", about a tag that supports it fine and simply needed formatting.
///
/// The signal was always there and was being discarded: an unformatted Type-2
/// chip answers `queryNDEFStatus` with `.notSupported`, which arrives as
/// `capabilityUnsupported(.ndefRead)`, whereas a formatted-but-empty one returns
/// zero bytes without throwing. No extra NFC traffic is needed to tell them
/// apart.
final class UnformattedTagTests: XCTestCase {
    /// The case that motivated this: a factory Ultralight C.
    @MainActor
    func test_factoryUltralightC_isReportedAsUnformatted() async throws {
        let model = ScanFlowModel(factory: SimulatedSessionFactory(makeChip: { MifareUltralightCSimulator() }))

        await model.begin()

        XCTAssertEqual(model.phase, .ready, "an unformatted tag is a successful scan, not an error")
        XCTAssertTrue(model.records.isEmpty)
        XCTAssertEqual(model.formatState, .noCapabilityContainer, "a factory Ultralight C has a blank page 3")
        XCTAssertEqual(try XCTUnwrap(model.scannedTagInfo).formatState, .noCapabilityContainer)
    }

    /// The control: formatted, just empty. This must keep reading as an ordinary
    /// blank tag, or every fresh NTAG21x would grow a spurious warning, since they
    /// ship pre-formatted.
    @MainActor
    func test_blankButFormattedTag_isNotReportedAsUnformatted() async throws {
        let model = ScanFlowModel(factory: SimulatedSessionFactory(makeChip: { NTAG213Simulator() }))

        await model.begin()

        XCTAssertEqual(model.phase, .ready)
        XCTAssertTrue(model.records.isEmpty)
        XCTAssertEqual(model.formatState, .readable, "a pre-formatted NTAG213 read back fine")
        XCTAssertEqual(try XCTUnwrap(model.scannedTagInfo).formatState, .readable)
    }

    /// Once formatted, the same chip stops being flagged. The state is about the
    /// tag in hand, not the chip model.
    @MainActor
    func test_formattedUltralightC_isNotFlagged() async throws {
        let chip = try MifareUltralightCSimulator(
            ndefMessage: NDEFCodec.encode([.text(TextRecord(text: "hi"))])
        )
        let model = ScanFlowModel(factory: SimulatedSessionFactory(makeChip: { chip }))

        await model.begin()

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.formatState, .readable)
    }

    /// A chip with no NDEF area at all reaches the same "zero records" branch and
    /// must *not* be labelled unformatted: no format exists that would give a
    /// DESFire an NDEF area, so offering one would be a dead end dressed as a fix.
    @MainActor
    func test_chipWithNoNDEFArea_isNotCalledUnformatted() async {
        let model = ScanFlowModel(factory: SimulatedSessionFactory(makeChip: { DESFireEV3Simulator() }))

        await model.begin()

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(
            model.formatState, .unknown,
            "DESFire has no blind-readable NDEF area, which is not an unformatted tag"
        )
    }

    /// The flag describes the tag currently in the field, so it must not survive
    /// into the next scan.
    @MainActor
    func test_flagClearsOnReset() async {
        let model = ScanFlowModel(factory: SimulatedSessionFactory(makeChip: { MifareUltralightCSimulator() }))
        await model.begin()
        XCTAssertEqual(model.formatState, .noCapabilityContainer)

        model.reset()

        XCTAssertEqual(model.formatState, .unknown)
    }

    // MARK: - A Capability Container is not the only thing a reader needs

    /// NTAG213 `04:5D:E5:FA:2A:14:90`, 2026-09-09. Page 3 reads `E1 10 12 00`,
    /// byte for byte the Capability Container this app writes for the chip. Page
    /// 4 reads `04 03 A0 0C` where its peel-sheet sibling reads `01 03 A0 0C`,
    /// so the leading TLV tag is a reserved value and iOS refuses the read.
    ///
    /// The app called it unformatted and pointed at Format. Format read page 3,
    /// found its work already done, wrote nothing, and said so. Two defensible
    /// statements and no way forward: the scan was naming a fault the format
    /// could not touch, because the scan had never read page 3.
    @MainActor
    func test_validCCWithACorruptLeadingTLVTag_isNotCalledUnformatted() async throws {
        let chip = NTAG213Simulator(uid: Data([0x04, 0x5D, 0xE5, 0xFA, 0x2A, 0x14, 0x90]))
        chip.pages[4] = Data([0x04, 0x03, 0xA0, 0x0C])
        chip.pages[5] = Data([0x34, 0x03, 0x00, 0xFE])
        let model = ScanFlowModel(factory: SimulatedSessionFactory(makeChip: { chip }))

        await model.begin()

        XCTAssertEqual(model.phase, .ready, "a tag that answers every read is a successful scan")
        XCTAssertEqual(
            model.formatState, .unreadableDataArea,
            "page 3 holds a Capability Container, so the repair is not a format"
        )
        XCTAssertEqual(try XCTUnwrap(model.scannedTagInfo).formatState, .unreadableDataArea)
        // The bytes ride along so a bug report can carry them. The app reports
        // what it read and stops there: the chip answered every one of these
        // reads, so nothing here calls it faulty.
        XCTAssertEqual(
            model.diagnostics.dataAreaPrologue,
            Data([0x04, 0x03, 0xA0, 0x0C, 0x34, 0x03, 0x00, 0xFE])
        )
    }

    /// The row is absent from every ordinary scan, which is the whole reason it
    /// is safe to show at all.
    @MainActor
    func test_theDataAreaRowIsAbsentFromATagThatReads() async {
        let model = ScanFlowModel(factory: SimulatedSessionFactory(makeChip: { NTAG213Simulator() }))

        await model.begin()

        XCTAssertEqual(model.formatState, .readable)
        XCTAssertNil(model.diagnostics.dataAreaPrologue)
    }

    /// And absent for the other fault too. A blank page 3 is a fault of page 3;
    /// the data area is beside the point and the bytes would only mislead.
    @MainActor
    func test_theDataAreaRowIsAbsentWhenTheCapabilityContainerIsTheFault() async {
        let model = ScanFlowModel(factory: SimulatedSessionFactory(makeChip: { MifareUltralightCSimulator() }))

        await model.begin()

        XCTAssertEqual(model.formatState, .noCapabilityContainer)
        XCTAssertNil(model.diagnostics.dataAreaPrologue)
    }

    /// The control, and the sibling: the same chip with the byte the factory
    /// meant to write. `01 03 A0 0C 34` is the Lock Control TLV an NTAG213 ships
    /// with, and nothing in the repo pinned those bytes until this test. A fresh
    /// `NTAG213Simulator` now holds them too (`DeliveryImageTests`), so the two
    /// pages staged here repeat the seed. They stay because they are the literal
    /// capture, and they keep this test independent of the seed.
    @MainActor
    func test_theFactoryLockControlTLVReadsAsABlankTag() async {
        let chip = NTAG213Simulator(uid: Data([0x04, 0x63, 0xE5, 0xFA, 0x2A, 0x14, 0x90]))
        chip.pages[4] = Data([0x01, 0x03, 0xA0, 0x0C])
        chip.pages[5] = Data([0x34, 0x03, 0x00, 0xFE])
        let model = ScanFlowModel(factory: SimulatedSessionFactory(makeChip: { chip }))

        await model.begin()

        XCTAssertEqual(model.phase, .ready)
        XCTAssertTrue(model.records.isEmpty)
        XCTAssertEqual(model.formatState, .readable, "one byte apart, and this one reads")
    }

    /// A read-protected tag reaches no verdict about its Capability Container,
    /// because nothing read one.
    @MainActor
    func test_aReadProtectedTagReachesNoFormatVerdict() async throws {
        let chip = NTAG213Simulator()
        try chip.enablePasswordProtection(
            password: Data([0xCA, 0xFE, 0xBA, 0xBE]), pack: Data([0x12, 0x34]),
            protectFromPage: 4, readProtect: true, authLimit: 0
        )
        let model = ScanFlowModel(factory: SimulatedSessionFactory(makeChip: { chip }))

        await model.begin()

        XCTAssertEqual(model.formatState, .unknown)
        XCTAssertNil(model.diagnostics.dataAreaPrologue)
    }

    // MARK: - What may be believed to be page 3

    /// A roll-over serves pages 0 and 1 at page 3's address, so the bytes are
    /// not a Capability Container however addressable they look. The pre-read
    /// must withhold them, or the scan reports "no Capability Container" about a
    /// tag that has one and points the user at an OTP write.
    ///
    /// Driven through `TagPreread` directly: the simulators NAK a protected READ
    /// rather than rolling it over, so no simulated scan can reach this.
    func test_aRolledOverPrereadCarriesNoCapabilityContainer() {
        let rolled = TagPreread(presence: .readProtected)

        XCTAssertNil(rolled.capabilityContainer)
        XCTAssertNil(rolled.dataAreaPrologue)
        XCTAssertEqual(TagFormatState.afterRefusedNDEFRead(capabilityContainer: nil), .unknown)
    }

    /// The condition under which the pre-read must withhold the bytes even
    /// though the tag answered: the roll-over check needs a 7-byte UID to derive
    /// what a rolled-over read would look like, and answers nothing for any
    /// other length. A cloned NTAG21x need not have one, and it would still be
    /// identified as an NTAG213 by GET_VERSION, so it reaches the verdict.
    ///
    /// Pinned at the rule rather than end to end: `NTAG21xSimulator` has a
    /// `precondition` that its UID is 7 bytes, so no simulated tag can be in
    /// this state, and inventing one would mean loosening the simulator to make
    /// a test possible.
    func test_theRolloverCheckAnswersNothingForANonSevenByteUID() {
        XCTAssertNil(TagPreread(presence: .answered).capabilityContainer)
        XCTAssertNil(
            ProtectionProbe.rolloverSignature(forUID: Data([0x04, 0x11, 0x22, 0x33])),
            "no signature to compare against means nothing can prove these bytes are page 3"
        )
        XCTAssertNotNil(
            ProtectionProbe.rolloverSignature(forUID: Data([0x04, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66]))
        )
    }

    /// The chip gate, which decides whether a refusal is labelled at all. A
    /// DESFire has no NDEF area for a format to create, so a perfect-looking
    /// Capability Container in hand still earns no verdict.
    @MainActor
    func test_theVerdictIsGatedOnTheChipAsWellAsTheBytes() async throws {
        let type2 = try await SimulatedSession(chip: NTAG213Simulator()).start(alert: "")
        let desfire = try await SimulatedSession(chip: DESFireEV3Simulator()).start(alert: "")
        let cc = Data([0xE1, 0x10, 0x12, 0x00])

        XCTAssertEqual(
            ScanFlowModel.formatState(for: type2, capabilityContainer: cc), .unreadableDataArea
        )
        XCTAssertEqual(
            ScanFlowModel.formatState(for: desfire, capabilityContainer: cc), .unknown,
            "no format gives a DESFire an NDEF area, so there is nothing to say"
        )
        XCTAssertEqual(
            ScanFlowModel.formatState(for: type2, capabilityContainer: nil), .unknown,
            "and never a guess when the bytes are absent"
        )
    }
}
