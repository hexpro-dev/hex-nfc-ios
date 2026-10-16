@testable import HexNFCKit
import XCTest

/// Guards the bytes a **permanent lock** writes to the dynamic-lock page.
///
/// This is the least-covered irreversible write in the app. `SimulatedSession`
/// implements `permanentLock()` by calling the simulator's own lock model, so
/// the frame `CoreNFCSession` builds never reaches a simulator and no test
/// before this one looked at it. The first live run (2026-08-07, MIFARE
/// Ultralight C) wrote `FF` into a reserved byte and the chip ACKed it.
///
/// Every expectation below is transcribed from a datasheet figure, not from
/// what the code happens to emit. Sources:
/// - NTAG213/215/216 rev 3.2 (doc 265332) §8.5.3, Figures 10, 11, 12
/// - MF0ICU2 rev 3.3 (doc 137633) §7.5.3
final class Type2LockWriteTests: XCTestCase {
    // MARK: - Per-chip masks, straight from the datasheet figures

    /// Fig 10. byte 0 = lock 16–31 (all 8 bits); byte 1 = lock 32–39 in bits
    /// 0–3 with RFUI in 4–7; byte 2 = BL 16–39 in bits 0–5 with RFUI in 6–7.
    func test_ntag213_masksMatchFigure10() {
        for variant in [Type2Variant.ntag213, .ntag213TT] {
            XCTAssertEqual(
                Type2LockWrite.dynamicLockPayload(for: .type2(variant), pageSize: 4),
                Data([0xFF, 0x0F, 0x3F, 0x00]),
                "\(variant): writing FF would set 6 RFUI bits, permanently"
            )
        }
    }

    /// Fig 11. byte 0 = lock 16–129 (all 8 bits); byte 1 is **entirely RFUI**;
    /// byte 2 = BL in bits 0–3 with RFUI in 4–7.
    func test_ntag215_masksMatchFigure11() {
        XCTAssertEqual(
            Type2LockWrite.dynamicLockPayload(for: .type2(.ntag215), pageSize: 4),
            Data([0xFF, 0x00, 0x0F, 0x00]),
            "NTAG215 byte 1 is wholly reserved — writing FF sets 8 RFUI bits"
        )
    }

    /// Fig 12. byte 0 = lock 16–143 (all 8 bits); byte 1 = lock 144–225 in bits
    /// 0–5 with RFUI in 6–7; byte 2 = BL in bits 0–6 with RFUI in 7.
    func test_ntag216_masksMatchFigure12() {
        XCTAssertEqual(
            Type2LockWrite.dynamicLockPayload(for: .type2(.ntag216), pageSize: 4),
            Data([0xFF, 0x3F, 0x7F, 0x00])
        )
    }

    /// MF0ICU2 §7.5.3: page 28h bytes 0–1 are lock bytes 2–3; bytes 2–3 are RFU.
    /// Live read-back on 2026-08-07 confirmed the tag settles at `FF FF 00 00`.
    func test_ultralightC_masksMatchDatasheetAndLiveReadBack() {
        XCTAssertEqual(
            Type2LockWrite.dynamicLockPayload(for: .type2(.mifareUltralightC), pageSize: 4),
            Data([0xFF, 0xFF, 0x00, 0x00])
        )
    }

    // MARK: - Structural guarantees

    /// Byte 3 is RFUI on every chip with a dynamic lock page. NTAG21x reads it
    /// back as `BDh`, which is a read artefact and never something to write.
    func test_byte3_isNeverWritten() {
        for profile in ChipCatalog.all where profile.memoryLayout.dynamicLockPage != nil {
            let payload = Type2LockWrite.dynamicLockPayload(
                for: profile.family, pageSize: profile.memoryLayout.pageSize
            )
            XCTAssertEqual(
                payload.last, 0x00,
                "\(profile.id) must leave byte 3 of the dynamic lock page at 00"
            )
        }
    }

    func test_everyChipWithADynamicLockPage_producesAWellFormedPayload() {
        for profile in ChipCatalog.all where profile.memoryLayout.dynamicLockPage != nil {
            let pageSize = profile.memoryLayout.pageSize
            let payload = Type2LockWrite.dynamicLockPayload(for: profile.family, pageSize: pageSize)
            XCTAssertEqual(payload.count, pageSize, "\(profile.id) payload must be exactly one page")
        }
    }

    /// MF0ULX1 rev 3.3 §8.5.3 Fig 9. byte 0 = lock 16–31 (all 8 bits); byte 1 =
    /// lock 32–35 in bits 0–1 with RFUI in 2–7; byte 2 = BL 16–35 in bits 0–4
    /// with RFUI in 5–7. Ten lock bits for the 80 data bytes it covers.
    func test_ultralightEV1_128_masksMatchFigure9() {
        XCTAssertEqual(
            Type2LockWrite.dynamicLockPayload(for: .type2(.mifareUltralightEV1_128), pageSize: 4),
            Data([0xFF, 0x03, 0x1F, 0x00]),
            "MF0UL21: writing FF would set 9 RFUI bits, permanently"
        )
    }

    /// No chip in the catalog may fall through to the all-bits default. That
    /// value is the historical bug, and reaching it means a chip was added
    /// without its dynamic-lock figure being read.
    func test_noCatalogChipFallsThroughToTheAllBitsDefault() {
        var setsEveryBit: [ChipID] = []
        for profile in ChipCatalog.all where profile.memoryLayout.dynamicLockPage != nil {
            let payload = Type2LockWrite.dynamicLockPayload(
                for: profile.family, pageSize: profile.memoryLayout.pageSize
            )
            if payload.prefix(3).allSatisfy({ $0 == 0xFF }) {
                setsEveryBit.append(profile.id)
            }
        }
        XCTAssertEqual(
            setsEveryBit, [],
            "these chips would set reserved bits on an irreversible write — "
                + "read the dynamic-lock figure from the datasheet and add the mask"
        )
    }

    func test_payloadNeverOverrunsAShortPage() {
        let payload = Type2LockWrite.dynamicLockPayload(for: .type2(.ntag213), pageSize: 2)
        XCTAssertEqual(payload, Data([0xFF, 0x0F]))
    }
}
