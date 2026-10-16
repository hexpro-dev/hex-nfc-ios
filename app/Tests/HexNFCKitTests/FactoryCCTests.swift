@testable import HexNFCKit
import HexNFCTagSim
import XCTest

/// Guards `ChipProfile.factoryCC` — the Type-2 Capability Container bytes the
/// app's `format` operation writes to page 3.
///
/// **Page 3 is OTP**: a write ORs bits and can never be cleared, so a wrong size
/// byte permanently mis-declares a real tag's NDEF area. Before these tests
/// existed, `factoryCC` had zero coverage and carried three separate defects —
/// NTAG213 declared 48 B instead of 144 B, NTAG215 declared 144 B instead of
/// 496 B, and Ultralight EV1 128 B declared NTAG216's 872 B on a 128 B chip.
///
/// The datasheet values are asserted literally (a derivation would be wrong —
/// see the note on `factoryCC`), and then cross-checked against the two other
/// places the same bytes appear: the chip simulators' seeded page 3, and the
/// console's "format NDEF" presets.
final class FactoryCCTests: XCTestCase {
    /// Datasheet-verified size bytes. Sources: NXP NTAG213/215/216 data sheet
    /// §8.5.6 "Capability container"; NXP MF0ULX1 (MIFARE Ultralight EV1) data
    /// sheet §8.5 / AN11340 "NDEF configuration".
    private static let expected: [ChipID: UInt8] = [
        // NT2L1001_NT2H1001 rev 3.0 Table 4 "Memory content at delivery":
        // page 03h ships as E1 10 06 00. Unlike UL EV1, this chip is NDEF
        // preformatted from the factory, so the CC is a read-back assertion
        // rather than something the app ever needs to write.
        .ntag210Micro: 0x06, // 48 B
        .ntag213: 0x12, // 144 B
        .ntag213TT: 0x12, // 144 B
        .ntag215: 0x3E, // 496 B of 504 B usable
        .ntag216: 0x6D, // 872 B of 888 B usable
        .mifareUltralightEV1_48: 0x06, // 48 B
        .mifareUltralightEV1_128: 0x10, // 128 B
        .emV10: 0x06, // 48 B — layout-derived, no datasheet
        .emV11: 0x06,
        .emV16: 0x06,
    ]

    func test_factoryCC_matchesDatasheet() throws {
        for (id, sizeByte) in Self.expected {
            let profile = try XCTUnwrap(ChipCatalog.profile(for: id), "\(id): no profile")
            let cc = try XCTUnwrap(profile.factoryCC, "\(id): no factoryCC")
            XCTAssertEqual(
                cc, Data([0xE1, 0x10, sizeByte, 0x00]),
                "\(id): factoryCC is \(cc.hexString), datasheet says E1:10:\(String(format: "%02X", sizeByte)):00"
            )
        }
    }

    /// The declared NDEF size must never exceed what the chip's page layout can
    /// actually hold — that is the failure mode that corrupts a tag.
    func test_factoryCC_declaresNoMoreThanTheChipHolds() throws {
        for id in Self.expected.keys {
            let profile = try XCTUnwrap(ChipCatalog.profile(for: id))
            let cc = try XCTUnwrap(profile.factoryCC)
            let declared = Int(cc[cc.startIndex + 2]) * 8
            XCTAssertLessThanOrEqual(
                declared, profile.ndefByteCapacity,
                "\(id): CC declares \(declared) B but the NDEF area holds only \(profile.ndefByteCapacity) B"
            )
        }
    }

    /// Every Type-2 chip that can be formatted must have a CC to write.
    func test_everyFormattableType2ProfileHasAFactoryCC() {
        for profile in ChipCatalog.all where profile.capabilities.contains(.formatCC) {
            guard case .type2 = profile.family else { continue }
            XCTAssertNotNil(profile.factoryCC, "\(profile.id) advertises .formatCC but has no factoryCC")
        }
    }

    /// The simulators seed page 3 from `factoryCC`. This asserts the wiring holds
    /// for every simulated Type-2 chip, so a future edit to one can't drift the
    /// other — the simulator is what `TestKitPlanTests` verifies the plans against.
    func test_simulatorPage3_matchesFactoryCC() async throws {
        let simulators: [ChipSimulator] = [
            NTAG210MicroSimulator(),
            NTAG213Simulator(), NTAG213TTSimulator(), NTAG215Simulator(), NTAG216Simulator(),
            MifareUltralightEV1_48Simulator(), MifareUltralightEV1_128Simulator(),
        ]
        for simulator in simulators {
            let profile = try XCTUnwrap(simulator.profile)
            let expected = try XCTUnwrap(profile.factoryCC)
            let tag = try await SimulatedSession(chip: simulator).start(alert: "")
            let page3 = try await tag.readMemory(range: 12 ..< 16)
            XCTAssertEqual(
                page3,
                expected,
                "\(profile.id): simulator page 3 is \(page3.hexString), factoryCC is \(expected.hexString)"
            )
        }
    }

    /// The console's "format NDEF" presets write the same CC the app would.
    /// A user firing the preset and a user tapping Format must not produce
    /// different — and permanent — results.
    func test_formatPresets_matchFactoryCC() throws {
        let formatPresets = CommandPresetCatalog.builtIn.filter {
            $0.sequenceText.hasPrefix("A2:03:")
        }
        XCTAssertFalse(formatPresets.isEmpty, "expected at least one page-3 format preset")

        for preset in formatPresets {
            guard case .type2(let variant) = preset.family else {
                XCTFail("\(preset.name): a page-3 CC write on a non-Type-2 family")
                continue
            }
            let profile = try XCTUnwrap(
                ChipCatalog.all.first { $0.family == .type2(variant) },
                "\(preset.name): no profile for \(variant)"
            )
            let expected = try XCTUnwrap(profile.factoryCC, "\(preset.name): profile has no factoryCC")
            // First step is "A2:03:<cc bytes>".
            let firstStep = preset.sequenceText.split(separator: ",")[0].trimmingCharacters(in: .whitespaces)
            let written = Data(firstStep.split(separator: ":").dropFirst(2).compactMap { UInt8($0, radix: 16) })
            XCTAssertEqual(
                written, expected,
                "\(preset.name): preset writes \(written.hexString), factoryCC is \(expected.hexString)"
            )
        }
    }
}
