@testable import HexNFCKit
import XCTest

/// Pins the DESFire `GET_VERSION` decoder against known hardware vectors,
/// including a real card (Myki = NXP DESFire EV3 4K). The decoder is pure, so
/// no CoreNFC / simulator is needed — `MiFareTagIdentifier` just forwards the
/// first GET_VERSION frame to it on device.
final class DESFireIdentificationTests: XCTestCase {
    /// Real Myki card: GET_VERSION first frame `AF 04 01 01 33 00 18 05`.
    func test_decodesRealMyki_asEV3_4K() {
        let frame = Data([0xAF, 0x04, 0x01, 0x01, 0x33, 0x00, 0x18, 0x05])
        let profile = ChipCatalog.identify(desFireVersion: frame)
        XCTAssertEqual(profile?.id, .mifareDESFireEV3)
        XCTAssertEqual(profile?.displayName, "MIFARE DESFire EV3")
        XCTAssertEqual(profile?.family.shortName, "MIFARE DESFire EV3")
        XCTAssertEqual(profile?.memoryLayout.byteCount, 4096)
        XCTAssertEqual(profile?.capabilities, [.rawTransceive])
    }

    func test_decodesEV1() {
        // hw-major 0x01, storage 0x16 → EV1, 2K.
        let frame = Data([0xAF, 0x04, 0x01, 0x01, 0x01, 0x00, 0x16, 0x05])
        let profile = ChipCatalog.identify(desFireVersion: frame)
        XCTAssertEqual(profile?.id, .mifareDESFireEV1)
        XCTAssertEqual(profile?.displayName, "MIFARE DESFire EV1")
        XCTAssertEqual(profile?.memoryLayout.byteCount, 2048)
    }

    func test_decodesEV2_8K() {
        // hw-major 0x12, storage 0x1A → EV2, 8K.
        let frame = Data([0xAF, 0x04, 0x01, 0x01, 0x12, 0x00, 0x1A, 0x05])
        let profile = ChipCatalog.identify(desFireVersion: frame)
        XCTAssertEqual(profile?.id, .mifareDESFireEV2)
        XCTAssertEqual(profile?.memoryLayout.byteCount, 8192)
    }

    /// Unknown generation byte → generic DESFire (still better than Unknown).
    func test_unknownGeneration_fallsBackToGeneric() {
        let frame = Data([0xAF, 0x04, 0x01, 0x01, 0x00, 0x00, 0x18, 0x05])
        let profile = ChipCatalog.identify(desFireVersion: frame)
        XCTAssertEqual(profile?.id, .genericMifareDESFire)
        XCTAssertEqual(profile?.family.shortName, "MIFARE DESFire")
    }

    /// Accepts the frame with the status byte already stripped (7 bytes).
    func test_acceptsFrameWithoutStatusByte() {
        let frame = Data([0x04, 0x01, 0x01, 0x33, 0x00, 0x18, 0x05])
        XCTAssertEqual(ChipCatalog.identify(desFireVersion: frame)?.id, .mifareDESFireEV3)
    }

    func test_rejectsNonNXPVendor() {
        let frame = Data([0xAF, 0x05, 0x01, 0x01, 0x33, 0x00, 0x18, 0x05])
        XCTAssertNil(ChipCatalog.identify(desFireVersion: frame))
    }

    func test_rejectsNonDESFireHardwareType() {
        // vendor NXP but hw type 0x03 (Ultralight family), not DESFire.
        let frame = Data([0xAF, 0x04, 0x03, 0x01, 0x01, 0x00, 0x0E, 0x05])
        XCTAssertNil(ChipCatalog.identify(desFireVersion: frame))
    }

    func test_rejectsShortFrame() {
        XCTAssertNil(ChipCatalog.identify(desFireVersion: Data([0xAF, 0x04, 0x01])))
    }

    func test_storageDecode() {
        XCTAssertEqual(ChipCatalog.desFireStorageBytes(0x16), 2048) // 2K
        XCTAssertEqual(ChipCatalog.desFireStorageBytes(0x18), 4096) // 4K
        XCTAssertEqual(ChipCatalog.desFireStorageBytes(0x1A), 8192) // 8K
        XCTAssertEqual(ChipCatalog.desFireStorageBytes(0x1C), 16384) // 16K
        XCTAssertNil(ChipCatalog.desFireStorageBytes(0x00))
    }
}
