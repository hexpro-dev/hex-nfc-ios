@testable import HexNFCKit
import XCTest

/// The DESFire NDEF setup's bytes, pinned to NXP AN11004 Rev 2.4 §8.1 where it
/// gives them, and its sizing rule.
///
/// The sequence a card actually receives is covered against the frame-level
/// simulator in `DESFireNDEFSetupTests`; these are the pieces that can be
/// checked without one.
final class DESFireNDEFDriverTests: XCTestCase {
    // MARK: - Framing

    /// AN11004 §8.1 step 1, byte for byte.
    func test_wrap_matchesTheApplicationNote() {
        XCTAssertEqual(
            DESFireAPDU.wrap(0x5A, Data([0x00, 0x00, 0x00])),
            Data([0x90, 0x5A, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00])
        )
        XCTAssertEqual(DESFireAPDU.wrap(0x6A), Data([0x90, 0x6A, 0x00, 0x00, 0x00]), "no Lc without data")
    }

    func test_split_separatesTheStatusWord() throws {
        let response = try XCTUnwrap(DESFireAPDU.split(Data([0x00, 0x14, 0x00, 0x91, 0x00])))
        XCTAssertEqual(response.body, Data([0x00, 0x14, 0x00]))
        XCTAssertTrue(response.isOK)
        XCTAssertTrue(try XCTUnwrap(DESFireAPDU.split(Data([0x91, 0xAF]))).hasMore)
        XCTAssertTrue(try XCTUnwrap(DESFireAPDU.split(Data([0x90, 0x00]))).isISOSuccess)
        XCTAssertNil(DESFireAPDU.split(Data([0x00])), "too short to carry a status word")
    }

    // MARK: - Capability Container

    /// AN11004 §8.1 step 5's CC contents for a 2048-byte NDEF file.
    func test_capabilityContainer_matchesTheApplicationNoteAt2KB() {
        XCTAssertEqual(
            DESFireNDEFDriver.capabilityContainer(ndefFileSize: 0x0800),
            Data([0x00, 0x0F, 0x20, 0x00, 0x3A, 0x00, 0x34, 0x04, 0x06, 0xE1, 0x04, 0x08, 0x00, 0x00, 0x00])
        )
    }

    /// The size is big-endian in the CC, where every DESFire command field is
    /// least significant byte first. Getting one of them backwards declares a
    /// file the card does not have.
    func test_capabilityContainer_writesTheSizeBigEndian() {
        let cc = DESFireNDEFDriver.capabilityContainer(ndefFileSize: 0x1000)
        XCTAssertEqual(cc.count, DESFireNDEFDriver.ccLength)
        XCTAssertEqual(Array(cc[11 ... 12]), [0x10, 0x00])
        XCTAssertEqual(DESFireNDEFDriver.littleEndian3(0x1000), Data([0x00, 0x10, 0x00]))
    }

    // MARK: - Sizing

    /// The owner's choice (2026-10-30): up to 4 KB, from what the card says it
    /// has free, keeping one 256-byte allocation page back.
    func test_ndefFileSize_isTheLargestThatFits() {
        XCTAssertEqual(DESFireNDEFDriver.ndefFileSize(forFreeMemory: 5120), 0x1000, "a blank EV3 4K")
        XCTAssertEqual(DESFireNDEFDriver.ndefFileSize(forFreeMemory: 0x1000 + 256), 0x1000)
        XCTAssertEqual(DESFireNDEFDriver.ndefFileSize(forFreeMemory: 0x1000 + 255), 0x0800)
        XCTAssertEqual(DESFireNDEFDriver.ndefFileSize(forFreeMemory: 3200), 0x0800, "the transit card's free memory")
        XCTAssertEqual(DESFireNDEFDriver.ndefFileSize(forFreeMemory: 0x0400 + 256), 0x0400)
        XCTAssertNil(DESFireNDEFDriver.ndefFileSize(forFreeMemory: 0x0400 + 255))
        XCTAssertNil(DESFireNDEFDriver.ndefFileSize(forFreeMemory: 0))
    }

    func test_littleEndianValue_readsThreeBytes() {
        XCTAssertEqual(DESFireNDEFDriver.littleEndianValue([0x00, 0x14, 0x00][...]), 5120)
        XCTAssertEqual(DESFireNDEFDriver.littleEndianValue([0x80, 0x0C, 0x00][...]), 3200)
    }

    // MARK: - Shared handshake

    /// The DESFire and Ultralight C drivers share `ISO3DESHandshake`, and the
    /// Ultralight C datasheet vector (MF0ICU2 rev 3.3 §7.5.6, Table 9) pins it
    /// directly as well as through that driver.
    func test_handshake_reproducesTheDatasheetVector() throws {
        let key = Data([
            0x49, 0x45, 0x4D, 0x4B, 0x41, 0x45, 0x52, 0x42,
            0x21, 0x4E, 0x41, 0x43, 0x55, 0x4F, 0x59, 0x46,
        ])
        let handshake = try ISO3DESHandshake(
            key: key,
            challenge: Data([0x57, 0x72, 0x93, 0xFD, 0x2F, 0x34, 0xCA, 0x51]),
            rndA: Data([0xA8, 0xAF, 0x3B, 0x25, 0x6C, 0x75, 0xED, 0x40])
        )
        XCTAssertEqual(handshake.token, Data([
            0x0A, 0x63, 0x85, 0x59, 0xFC, 0x77, 0x37, 0xF9,
            0xF1, 0x5D, 0x78, 0x62, 0xEB, 0xBE, 0x96, 0x7A,
        ]))
        XCTAssertTrue(try handshake.cardProvesKey(Data([0x3B, 0x88, 0x4F, 0xA0, 0x7C, 0x13, 0x7C, 0xE1])))
        XCTAssertFalse(try handshake.cardProvesKey(Data(repeating: 0x5A, count: 8)))
    }
}
