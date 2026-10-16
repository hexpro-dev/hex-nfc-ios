@testable import HexNFCKit
import XCTest

/// Locks the advisory preset-compatibility relation the Advanced Console uses to
/// prioritise and grey presets after an Identify scan. The load-bearing case is
/// the NTAG21x cross-over (NTAG213 ⇄ NTAG213 TT ⇄ 215 ⇄ 216 share a command
/// set), plus the hard transport boundaries that must never be treated as
/// compatible.
final class CommandPresetCompatibilityTests: XCTestCase {
    func test_exactFamily_ranksExact() {
        XCTAssertEqual(TagFamily.type2(.ntag215).matches(identifiedChip: .type2(.ntag215)), .exact)
        XCTAssertEqual(TagFamily.type5(.icodeSlix).matches(identifiedChip: .type5(.icodeSlix)), .exact)
        XCTAssertEqual(TagFamily.type4(.ntag424DNA).matches(identifiedChip: .type4(.ntag424DNA)), .exact)
    }

    func test_ntag21xLine_crossesOver_asCompatible() {
        // The user's called-out case: NTAG213 vs NTAG213 TT, and the wider line.
        XCTAssertEqual(TagFamily.type2(.ntag213).matches(identifiedChip: .type2(.ntag213TT)), .compatible)
        XCTAssertEqual(TagFamily.type2(.ntag213TT).matches(identifiedChip: .type2(.ntag213)), .compatible)
        XCTAssertEqual(TagFamily.type2(.ntag215).matches(identifiedChip: .type2(.ntag213)), .compatible)
        XCTAssertEqual(TagFamily.type2(.ntag216).matches(identifiedChip: .type2(.ntag215)), .compatible)
    }

    func test_genericType2Preset_matchesAnyType2Chip() {
        XCTAssertEqual(TagFamily.type2(.unknown).matches(identifiedChip: .type2(.ntag215)), .compatible)
        XCTAssertEqual(TagFamily.type2(.unknown).matches(identifiedChip: .type2(.emV11)), .compatible)
        XCTAssertEqual(TagFamily.type2(.unknown).matches(identifiedChip: .type2(.mifareUltralightEV1_48)), .compatible)
    }

    func test_differentLine_sameTransport_isIncompatible() {
        // NTAG21x, Ultralight EV1, and EM Micro are distinct Type-2 chip lines.
        XCTAssertEqual(
            TagFamily.type2(.ntag215).matches(identifiedChip: .type2(.mifareUltralightEV1_48)),
            .incompatible
        )
        XCTAssertEqual(TagFamily.type2(.emV10).matches(identifiedChip: .type2(.ntag213)), .incompatible)
        XCTAssertEqual(TagFamily.type2(.mifareUltralightEV1_128).matches(identifiedChip: .type2(.emV16)), .incompatible)
    }

    func test_ultralightEV1_andEM_linesCrossOverWithinThemselves() {
        XCTAssertEqual(
            TagFamily.type2(.mifareUltralightEV1_48).matches(identifiedChip: .type2(.mifareUltralightEV1_128)),
            .compatible
        )
        XCTAssertEqual(TagFamily.type2(.emV10).matches(identifiedChip: .type2(.emV16)), .compatible)
    }

    func test_differentTransport_isAlwaysIncompatible() {
        XCTAssertEqual(TagFamily.type5(.icodeSlix).matches(identifiedChip: .type2(.ntag215)), .incompatible)
        XCTAssertEqual(TagFamily.type2(.ntag215).matches(identifiedChip: .type5(.icodeSlix)), .incompatible)
        XCTAssertEqual(TagFamily.type4(.ntag424DNA).matches(identifiedChip: .type2(.ntag215)), .incompatible)
        XCTAssertEqual(TagFamily.type2(.ntag215).matches(identifiedChip: .felica), .incompatible)
    }

    func test_type4DesfireLine_crossesOver() {
        XCTAssertEqual(TagFamily.type4(.ntag424DNA).matches(identifiedChip: .type4(.desfireEV2)), .compatible)
        XCTAssertEqual(TagFamily.type4(.desfireEV1).matches(identifiedChip: .type4(.ntag424DNA)), .compatible)
    }

    func test_type5Iso15693Line_crossesOver() {
        XCTAssertEqual(TagFamily.type5(.icodeSlix).matches(identifiedChip: .type5(.icodeSlix2)), .compatible)
        XCTAssertEqual(TagFamily.type5(.generic).matches(identifiedChip: .type5(.icodeSlixL)), .compatible)
    }

    func test_unknownChip_neverGreysAnything() {
        XCTAssertEqual(TagFamily.type5(.icodeSlix).matches(identifiedChip: .unknown), .compatible)
        XCTAssertEqual(TagFamily.type2(.ntag215).matches(identifiedChip: .unknown), .compatible)
        XCTAssertEqual(TagFamily.felica.matches(identifiedChip: .unknown), .compatible)
    }

    func test_underIdentifiedType2Chip_keepsAllType2Compatible() {
        // Chip pinned only to "some Type-2" (e.g. an EM tag that NAKs GET_VERSION).
        XCTAssertEqual(TagFamily.type2(.ntag215).matches(identifiedChip: .type2(.unknown)), .compatible)
        XCTAssertEqual(TagFamily.type2(.emV10).matches(identifiedChip: .type2(.unknown)), .compatible)
        // ...but a Type-5 preset is still off-transport for a Type-2 chip.
        XCTAssertEqual(TagFamily.type5(.icodeSlix).matches(identifiedChip: .type2(.unknown)), .incompatible)
    }

    func test_matchRanks_sortExactAboveCompatibleAboveIncompatible() {
        XCTAssertGreaterThan(PresetMatch.exact.sortRank, PresetMatch.compatible.sortRank)
        XCTAssertGreaterThan(PresetMatch.compatible.sortRank, PresetMatch.incompatible.sortRank)
        XCTAssertEqual(PresetMatch.unscored.sortRank, PresetMatch.compatible.sortRank)
    }

    func test_isCompatibleFlag() {
        XCTAssertTrue(PresetMatch.exact.isCompatible)
        XCTAssertTrue(PresetMatch.compatible.isCompatible)
        XCTAssertTrue(PresetMatch.unscored.isCompatible)
        XCTAssertFalse(PresetMatch.incompatible.isCompatible)
    }
}
