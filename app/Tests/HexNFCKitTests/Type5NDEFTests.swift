@testable import HexNFCKit
import HexNFCRecords
import HexNFCTagSim
import XCTest

/// Covers the Type-5 Capability Container helper and the formatter that writes
/// it — the path a factory ICODE SLIX2 needs before it can hold an NDEF message.
///
/// Before this existed the app could read and erase a virgin SLIX2 but never
/// write one: `formatCC` refused every non-Type-2 family, and no Type-5 CC
/// writer existed. The simulator hid it by being born formatted, so the whole
/// gap was invisible to CI.
final class Type5NDEFTests: XCTestCase {
    // MARK: - CC layout

    /// A 28-block × 4-byte ICODE SLIX: 112 B total, 108 B after the CC,
    /// MLEN = floor(108/8) = 13.
    func test_ccBytes_slixGeometry() throws {
        let cc = try XCTUnwrap(Type5CC.bytes(blockCount: 28, blockSize: 4))
        XCTAssertEqual(cc, Data([0xE1, 0x40, 0x0D, 0x09]))
    }

    /// A real SLIX2 self-reports 80 blocks: 320 B total, 316 B after the CC,
    /// MLEN = floor(316/8) = 39 (0x27).
    func test_ccBytes_slix2Geometry() throws {
        let cc = try XCTUnwrap(Type5CC.bytes(blockCount: 80, blockSize: 4))
        XCTAssertEqual(cc, Data([0xE1, 0x40, 0x27, 0x09]))
    }

    /// Unknown geometry (a generic profile the tag hasn't described yet) must
    /// produce no CC rather than a wrong one.
    func test_ccBytes_refusesUnknownOrOversizedGeometry() {
        XCTAssertNil(Type5CC.bytes(blockCount: 0, blockSize: 4), "unknown geometry")
        XCTAssertNil(Type5CC.bytes(blockCount: 1, blockSize: 4), "no room after the CC block")
        XCTAssertNil(Type5CC.bytes(blockCount: 4, blockSize: 0), "zero block size")
        // >2040 B needs the 8-byte 0xE2 form, which no supported chip uses.
        XCTAssertNil(Type5CC.bytes(blockCount: 1024, blockSize: 4), "beyond the 4-byte CC form")
    }

    func test_isFormatted_detectsBothMagicBytesAndVirginBlocks() {
        XCTAssertTrue(Type5CC.isFormatted(Data([0xE1, 0x40, 0x0D, 0x09])))
        XCTAssertTrue(Type5CC.isFormatted(Data([0xE2, 0x40, 0x00, 0x09])), "8-byte CC form")
        XCTAssertFalse(Type5CC.isFormatted(Data([0x00, 0x00, 0x00, 0x00])), "virgin block 0")
        XCTAssertFalse(Type5CC.isFormatted(Data()), "empty read")
    }

    /// The profile-level accessor must agree with the raw helper, and stay nil
    /// for families that keep their CC elsewhere.
    func test_factoryType5CC_onlyForType5WithKnownGeometry() throws {
        let slix = try XCTUnwrap(ChipCatalog.profile(for: .icodeSlix))
        XCTAssertEqual(slix.factoryType5CC, Data([0xE1, 0x40, 0x0D, 0x09]))

        let ntag = try XCTUnwrap(ChipCatalog.profile(for: .ntag213))
        XCTAssertNil(ntag.factoryType5CC, "Type-2 keeps its CC in a page, not a block")

        let generic = try XCTUnwrap(ChipCatalog.profile(for: .genericIso15693))
        XCTAssertNil(generic.factoryType5CC, "geometry unknown until the tag self-reports")
    }

    // MARK: - Virgin-tag behaviour

    /// The divergence this whole phase exists to close: a factory SLIX2 has no
    /// CC, and a content NDEF write against it fails on real silicon.
    func test_virginTag_refusesContentWrite_butForgivesErase() async throws {
        let tag = try await SimulatedSession(chip: Iso15693Simulator(virgin: true)).start(alert: "")

        // Reads are a clean zero-record result, not an error.
        let read = try await tag.readNDEF()
        XCTAssertTrue(NDEFCodec.isEmptyMessage(read), "virgin tag should read as an empty message")

        // An erase is a forgiven no-op.
        try await tag.writeNDEF([])

        // A content write must fail — this is what CoreNFC does on hardware.
        do {
            try await tag.writeNDEF([.text(TextRecord(text: "HEXNFC", languageCode: "en"))])
            XCTFail("a content write to an unformatted Type-5 tag should fail")
        } catch let error as TagError {
            XCTAssertEqual(error.kind, .tagLost, "expected the 'not NDEF formatted' failure")
        }
    }

    /// Format, then the same write succeeds — proving the formatter produces a
    /// CC the NDEF path actually accepts.
    func test_formatThenWrite_roundTrips() async throws {
        let simulator = Iso15693Simulator(virgin: true)
        let tag = try await SimulatedSession(chip: simulator).start(alert: "")
        let profile = try XCTUnwrap(simulator.profile)
        let cc = try XCTUnwrap(profile.factoryType5CC)

        let formatter = Type5Formatter(transceive: { try await tag.transceive($0) })
        let beforeFormat = try await formatter.readCapabilityContainer()
        XCTAssertEqual(beforeFormat, Data(repeating: 0x00, count: 4))

        try await formatter.format(cc: cc)
        let afterFormat = try await formatter.readCapabilityContainer()
        XCTAssertEqual(afterFormat, cc)

        try await tag.writeNDEF([.text(TextRecord(text: "HEXNFC", languageCode: "en"))])
        let records = try await NDEFCodec.decode(tag.readNDEF())
        guard case .text(let record)? = records.first else {
            return XCTFail("expected a text record, got \(records)")
        }
        XCTAssertEqual(record.text, "HEXNFC")
    }

    /// Block 0 is rewritable on Type-5 (unlike the Type-2 OTP page), so a format
    /// is reversible. The harness plan depends on this to restore a tag it found
    /// virgin.
    func test_format_isReversible() async throws {
        let simulator = Iso15693Simulator(virgin: true)
        let tag = try await SimulatedSession(chip: simulator).start(alert: "")
        let formatter = Type5Formatter(transceive: { try await tag.transceive($0) })

        let original = try await formatter.readCapabilityContainer()
        try await formatter.format(cc: XCTUnwrap(simulator.profile?.factoryType5CC))
        let formatted = try await formatter.readCapabilityContainer()
        XCTAssertTrue(Type5CC.isFormatted(formatted))

        // Restore, and the tag is virgin again.
        _ = try await tag.transceive(RawCommand(
            bytes: Data([0x02, Iso15693Opcode.writeSingleBlock, 0x00]) + original,
            name: "restore b0"
        ))
        let restored = try await formatter.readCapabilityContainer()
        XCTAssertFalse(Type5CC.isFormatted(restored))
    }

    // MARK: - The data area

    /// The Format screen says the tag's records are left alone, and until
    /// 2026-09-22 the Type-5 path made that a lie: it wrote `03 00 FE 00` over
    /// block 1 every time, which is the header of whatever message was there.
    /// A SLIX2 owner who formatted a tag lost its records, with no warning and
    /// no undo, while the Type-2 path next to it touched the CC page only.
    func test_format_leavesAnExistingMessageAlone() async throws {
        let simulator = Iso15693Simulator.slix2()
        let tag = try await SimulatedSession(chip: simulator).start(alert: "")
        try await tag.writeNDEF([.text(TextRecord(text: "HEXNFC", languageCode: "en"))])
        let messageArea = simulator.blocks[1]
        XCTAssertNotEqual(messageArea, Type5CC.emptyNDEFTLV, "the record has to reach block 1 to be at risk")

        let formatter = Type5Formatter(transceive: { try await tag.transceive($0) })
        try await formatter.format(cc: XCTUnwrap(simulator.profile?.factoryType5CC))

        XCTAssertEqual(simulator.blocks[1], messageArea, "format overwrote the first TLV block")
        let records = try await NDEFCodec.decode(tag.readNDEF())
        guard case .text(let record)? = records.first else {
            return XCTFail("expected the record to survive a format, got \(records)")
        }
        XCTAssertEqual(record.text, "HEXNFC")
    }

    /// The other half, and the reason the seed exists: a tag carrying no message
    /// at all still gets the empty TLV, so a reader meets "NDEF, no message"
    /// rather than walking a field of NULLs to the end of memory.
    func test_format_seedsAnEmptyMessageWhenTheAreaIsBlank() async throws {
        let simulator = Iso15693Simulator(virgin: true)
        let tag = try await SimulatedSession(chip: simulator).start(alert: "")
        XCTAssertEqual(simulator.blocks[1], Data(repeating: 0x00, count: 4), "a factory tag is all zero")

        let formatter = Type5Formatter(transceive: { try await tag.transceive($0) })
        try await formatter.format(cc: XCTUnwrap(simulator.profile?.factoryType5CC))

        XCTAssertEqual(simulator.blocks[1], Type5CC.emptyNDEFTLV)
        let message = try await tag.readNDEF()
        XCTAssertTrue(NDEFCodec.isEmptyMessage(message), "a formatted tag reads as an empty message")
    }

    /// Only an all-zero block is fair game. Every defined TLV tag was written by
    /// somebody, and a short read says nothing about the tag at all.
    func test_isBlankMessageArea_onlyAnAllZeroBlock() {
        XCTAssertTrue(Type5CC.isBlankMessageArea(Data([0x00, 0x00, 0x00, 0x00])))
        XCTAssertFalse(Type5CC.isBlankMessageArea(Type5CC.emptyNDEFTLV), "an empty message is still a message")
        XCTAssertFalse(Type5CC.isBlankMessageArea(Data([0x03, 0x05, 0xD1, 0x01])), "an NDEF TLV")
        XCTAssertFalse(Type5CC.isBlankMessageArea(Data([0x01, 0x03, 0xA0, 0x0C])), "a Lock Control TLV")
        XCTAssertFalse(Type5CC.isBlankMessageArea(Data()), "a read that did not happen is not a blank tag")
    }

    /// A CC written by the formatter must match the one the simulator seeds
    /// itself with — one layout, one source.
    func test_formatterOutput_matchesSimulatorSeed() throws {
        for blockCount in [28, 80] {
            let seeded = Iso15693Simulator(blockCount: blockCount)
            let seededCC = try seeded.readMemory(range: 0 ..< 4)
            let computed = try XCTUnwrap(Type5CC.bytes(blockCount: blockCount, blockSize: 4))
            XCTAssertEqual(seededCC, computed, "blockCount=\(blockCount)")
        }
    }
}
