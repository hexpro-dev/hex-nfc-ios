@testable import HexNFCKit
import XCTest

/// Coverage for the Type-2 TLV envelope used by `CoreNFCConnectedTag`'s raw
/// page-write path (the route taken once a protected tag is authenticated,
/// where the high-level CoreNFC NDEF write can't be used). The page I/O itself
/// is iOS-only, but the envelope encode/decode is pure and verified here.
final class Type2NDEFTests: XCTestCase {
    func test_wrapUnwrap_roundTrips() throws {
        let message = Data([0xD1, 0x01, 0x05, 0x55, 0x01, 0x68, 0x65, 0x78])
        let envelope = Type2NDEF.wrap(message: message)
        XCTAssertEqual(envelope.first, 0x03, "envelope starts with the NDEF TLV tag")
        XCTAssertEqual(envelope.last, 0xFE, "envelope ends with the terminator")
        XCTAssertEqual(try Type2NDEF.unwrap(envelope), message)
    }

    func test_unwrap_ignoresStaleBytesAfterTerminator() throws {
        // A shorter rewrite over a longer old message leaves stale bytes after
        // the new terminator. A TLV reader must stop at the declared length.
        let message = Data([0x01, 0x02, 0x03])
        var memory = Type2NDEF.wrap(message: message)
        memory.append(contentsOf: [0xDE, 0xAD, 0xBE, 0xEF, 0xFF])
        XCTAssertEqual(try Type2NDEF.unwrap(memory), message)
    }

    func test_wrapUnwrap_threeByteLengthForm() throws {
        // 255+ bytes triggers the `0x03 0xFF <hi> <lo>` length form.
        let message = Data((0 ..< 300).map { UInt8($0 & 0xFF) })
        let envelope = Type2NDEF.wrap(message: message)
        XCTAssertEqual(envelope[envelope.startIndex + 1], 0xFF, "long messages use the 3-byte length")
        XCTAssertEqual(try Type2NDEF.unwrap(envelope), message)
    }

    func test_unwrap_skipsLockAndMemoryControlTLVs() throws {
        let message = Data([0xAA, 0xBB])
        // Lock-control TLV (0x01, len 3), memory-control TLV (0x02, len 3), then NDEF.
        var memory = Data([0x01, 0x03, 0x00, 0x00, 0x00, 0x02, 0x03, 0x00, 0x00, 0x00])
        memory.append(Type2NDEF.wrap(message: message))
        XCTAssertEqual(try Type2NDEF.unwrap(memory), message)
    }

    func test_unwrap_blankRegion_throwsNoNDEFTLV() {
        // A freshly-formatted region: terminator with no NDEF message.
        XCTAssertThrowsError(try Type2NDEF.unwrap(Data([0xFE, 0x00, 0x00, 0x00]))) { error in
            XCTAssertEqual(error as? Type2NDEF.ParseError, .noNDEFTLV)
        }
    }

    /// The envelope this produces must match what the simulator writes, so the
    /// production raw path and the simulator agree byte-for-byte.
    func test_wrap_matchesSimulatorEnvelopeShape() {
        let message = Data([0x10, 0x20, 0x30])
        let envelope = Type2NDEF.wrap(message: message)
        XCTAssertEqual(envelope, Data([0x03, 0x03, 0x10, 0x20, 0x30, 0xFE]))
    }

    // MARK: - The factory prologue, and one byte of it going wrong

    /// The delivery content of an NTAG213's data area, pinned here because
    /// nothing in the repo held it before: a Lock Control TLV declaring the
    /// dynamic lock bytes, then an empty NDEF message, then the terminator.
    /// Captured from two tags on 2026-09-09 (`04:63:E5:FA:2A:14:90` and
    /// `04:46:93:42:FE:0F:90`), both of which scanned cleanly.
    func test_unwrap_factoryNTAG213Prologue_readsAsAnEmptyMessage() throws {
        var image = Data([0x01, 0x03, 0xA0, 0x0C, 0x34, 0x03, 0x00, 0xFE])
        image.append(Data(repeating: 0x00, count: 144 - image.count))

        XCTAssertEqual(try Type2NDEF.unwrap(image), Data())
    }

    /// The same image with the one byte that made a real tag unreadable to iOS:
    /// `04` where the Lock Control TLV tag belongs (NTAG213
    /// `04:5D:E5:FA:2A:14:90`). `04` is reserved, and a reserved block still
    /// carries a length, so skipping it by that length reaches the `03 00` two
    /// bytes on and reports the truth.
    func test_unwrap_reservedTLVTag_isSkippedByItsLength() throws {
        var image = Data([0x04, 0x03, 0xA0, 0x0C, 0x34, 0x03, 0x00, 0xFE])
        image.append(Data(repeating: 0x00, count: 144 - image.count))

        XCTAssertEqual(try Type2NDEF.unwrap(image), Data())
    }

    /// The reason the old one-byte skip was worse than merely lenient: it does
    /// not step over the reserved block, it steps *into* it and reads the
    /// block's own length byte as the next tag. Here that took `A0` for a
    /// 160-byte NDEF message and returned 160 bytes nobody wrote as records. A
    /// parser may fail to find a message; it may not invent one.
    func test_unwrap_reservedTLVTag_doesNotFabricateAMessage() throws {
        var image = Data([0x04, 0x03, 0xA0, 0x0C, 0x34, 0x03, 0x00, 0xFE])
        image.append(Data(repeating: 0xAB, count: 888 - image.count))

        XCTAssertEqual(try Type2NDEF.unwrap(image), Data())
    }

    /// The skip stays bounded. A reserved block whose declared length runs off
    /// the end of the region ends the walk, so the `03 01 41` sitting inside it
    /// is never mistaken for a message: the block said those bytes were its own.
    func test_unwrap_reservedTLVRunningPastTheEnd_findsNoMessage() {
        let image = Data([0x04, 0xFF, 0x00, 0x00, 0x03, 0x01, 0x41, 0xFE])

        XCTAssertThrowsError(try Type2NDEF.unwrap(image)) { error in
            XCTAssertEqual(error as? Type2NDEF.ParseError, .noNDEFTLV)
        }
    }
}

/// The rule the 2026-09-09 NTAG213 forced: which repair a refused NDEF read
/// calls for is a fact about the Capability Container, and the only way to know
/// it is to have read the Capability Container.
final class TagFormatStateTests: XCTestCase {
    private let goodCC = Data([0xE1, 0x10, 0x12, 0x00])

    /// The whole thesis. No bytes means no verdict, not the likelier of the two
    /// guesses. This is what the shipping scan used to get wrong: it answered
    /// from the chip's catalogue entry, which is always available and never a
    /// reading.
    func test_withoutTheCapabilityContainer_thereIsNoVerdict() {
        XCTAssertEqual(TagFormatState.afterRefusedNDEFRead(capabilityContainer: nil), .unknown)
    }

    /// A short read is not a read. Three bytes cannot say what page 3 holds.
    func test_aShortReadIsNotAReading() {
        XCTAssertEqual(
            TagFormatState.afterRefusedNDEFRead(capabilityContainer: Data([0xE1, 0x10, 0x12])),
            .unknown
        )
    }

    func test_aBlankPage3MeansFormatIt() {
        XCTAssertEqual(
            TagFormatState.afterRefusedNDEFRead(capabilityContainer: Data([0x00, 0x00, 0x00, 0x00])),
            .noCapabilityContainer
        )
    }

    /// The tag that started this: a Capability Container that is present, and a
    /// reader that refused the tag anyway.
    func test_aCapabilityContainerPlusARefusalMeansTheDataArea() {
        XCTAssertEqual(
            TagFormatState.afterRefusedNDEFRead(capabilityContainer: goodCC),
            .unreadableDataArea
        )
    }

    func test_onlyTheTwoFaultsAskForTheUsersAttention() {
        XCTAssertTrue(TagFormatState.noCapabilityContainer.needsAttention)
        XCTAssertTrue(TagFormatState.unreadableDataArea.needsAttention)
        XCTAssertFalse(TagFormatState.unknown.needsAttention, "silence is the honest answer, not a warning")
        XCTAssertFalse(TagFormatState.readable.needsAttention)
    }

    /// A completed read proves the structure walks only where a tag with no
    /// Capability Container would have been refused. The other families report
    /// one as a clean read of zero records, so there the same success says
    /// nothing at all.
    func test_onlyThePageTransportProvesAReadWalkedTheStructure() {
        XCTAssertTrue(TagFormatState.readProvesStructure(.type2(.ntag213)))
        XCTAssertTrue(TagFormatState.readProvesStructure(.type2(.mifareUltralightC)))
        XCTAssertFalse(TagFormatState.readProvesStructure(.type5(.icodeSlix2)))
        XCTAssertFalse(TagFormatState.readProvesStructure(.type4(.ntag424DNA)))
        XCTAssertFalse(TagFormatState.readProvesStructure(nil))
    }
}
