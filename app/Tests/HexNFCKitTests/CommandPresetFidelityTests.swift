@testable import HexNFCKit
@testable import HexNFCRecords
@testable import HexNFCTagSim
import XCTest

/// **Slice 7: datasheet-fidelity audit.**
///
/// Every preset in `CommandPresetCatalog.builtIn` is parsed via
/// `RawCommandSequence`, dispatched against the simulator that matches its
/// `family`, and:
///
///   1. Asserted to parse without throwing.
///   2. Asserted to bind UID placeholders against the simulator's UID.
///   3. Asserted to produce a non-empty response (real chips never return
///      zero-byte responses to well-formed commands — they either ACK,
///      NAK, or return data).
///   4. If `expectedResponseHex` is set on the preset, asserted to match
///      it bit-for-bit.
///
/// This converts `CommandPresetCatalog` from "a list of strings" into "a
/// contract validated against simulator behaviour against the datasheet" —
/// the load-bearing claim that makes the emulation suite a *spec test*.
final class CommandPresetFidelityTests: XCTestCase {
    // MARK: - What a preset's name has to say

    /// The pages this catalogue writes as whole-page constants.
    ///
    /// Built by hand rather than from `Type2ConfigLayout`, and the difference
    /// matters: NTAG213 TT's `TT_CONFIG` at 0x25 is not a configuration page any
    /// layout type in this repo owns, so a set derived from `Type2ConfigLayout`
    /// would have shipped green over it. That is the shape of defect finding 5
    /// exists to stop, so the list is explicit and this comment is why.
    private static let wholePageConfigWrites: Set<UInt8> = [
        0x2A, // NTAG213 CFG1
        0x84, // NTAG215 CFG1
        0xE4, // NTAG216 CFG1
        0x25, // NTAG213 TT TT_CONFIG
    ]

    /// A Type-2 WRITE replaces all four bytes of the page. Where a preset does
    /// that to a configuration page, the name has to say so.
    ///
    /// `notes` cannot carry this: `AdvancedConsoleModel` searches them and
    /// nothing renders them, so the only string a user of the console reads is
    /// the name. On CFG1 the cost is concrete: byte 0 is the live ACCESS byte, so
    /// a constant write clears PROT and AUTH_LIM on a tag that had them set, and
    /// byte 1 ships as 05 on every NTAG213 and NTAG216 surveyed.
    ///
    /// This checks the four pages listed above and claims nothing about any
    /// other. A preset that writes a configuration page not in that set passes
    /// this test while carrying the same defect, which is why the set is a
    /// literal a reader can audit rather than a derivation that looks complete.
    func test_wholePageConfigWrites_sayInTheirNameThatTheyReplaceThePage() throws {
        for preset in CommandPresetCatalog.builtIn {
            let sequence = try RawCommandSequence.parse(preset.sequenceText, family: preset.family)
            for token in sequence.commands {
                guard token.elements.count > 2,
                      case .byte(let opcode) = token.elements[0], opcode == 0xA2,
                      case .byte(let page) = token.elements[1],
                      Self.wholePageConfigWrites.contains(page)
                else { continue }

                XCTAssertTrue(
                    preset.name.contains("replaces all of"),
                    "\"\(preset.name)\" writes page 0x\(String(format: "%02X", page)) as a whole-page "
                        + "constant. A Type-2 WRITE replaces all four bytes, and on a configuration page "
                        + "that destroys live settings. Say so in the name: `notes` are searched, never "
                        + "shown."
                )
            }
        }
    }

    /// No Ultralight C preset reads into the 3DES key range except the one whose
    /// name says what that costs.
    ///
    /// `UltralightCLayout` tells the drivers never to read into 2Ch-2Fh: the chip
    /// answers a NAK, and a NAK returns a Type-2 tag to HALT for the rest of the
    /// activation. A `30:2A` preset used to read 2Ah-2Dh, which is exactly that
    /// frame, while presenting itself as an ordinary configuration read.
    func test_ultralightCPresets_doNotReadIntoTheKeyRangeUnannounced() throws {
        let keyPages: ClosedRange<UInt8> = 0x2C ... 0x2F
        for preset in CommandPresetCatalog.presets(for: .type2(.mifareUltralightC)) {
            let sequence = try RawCommandSequence.parse(preset.sequenceText, family: preset.family)
            for token in sequence.commands {
                guard token.elements.count >= 2,
                      case .byte(let opcode) = token.elements[0], opcode == 0x30,
                      case .byte(let start) = token.elements[1]
                else { continue }

                // A Type-2 READ returns four pages from the addressed one.
                let touchesKey = (start ... start.addingReportingOverflow(3).partialValue)
                    .contains { keyPages.contains($0) }
                guard touchesKey else { continue }

                XCTAssertTrue(
                    preset.name.contains("ends the tap"),
                    "\"\(preset.name)\" reads pages 0x\(String(format: "%02X", start)) onwards, which "
                        + "runs into the write-only key at 2Ch-2Fh. The chip NAKs, and the NAK halts it "
                        + "for the rest of the activation. Either address a lower page or say in the "
                        + "name that the tap ends here."
                )
            }
        }
    }

    // MARK: - Smoke: every preset parses and binds

    func test_everyPreset_parsesSuccessfully() throws {
        for preset in CommandPresetCatalog.builtIn {
            do {
                _ = try RawCommandSequence.parse(preset.sequenceText, family: preset.family)
            } catch {
                XCTFail("preset \"\(preset.name)\" failed to parse: \(error)")
            }
        }
    }

    func test_everyPreset_hasMatchingSimulator() {
        for preset in CommandPresetCatalog.builtIn {
            XCTAssertNotNil(makeSimulator(for: preset.family),
                            "no simulator wired for family \(preset.family.shortName) (preset: \(preset.name))")
        }
    }

    // MARK: - Per-family execution audits

    func test_type2Common_presets_executeWithoutThrowing() throws {
        try runFidelity(family: .type2(.unknown))
    }

    func test_ntag21xCommon_presets_executeWithoutThrowing() throws {
        // ntag21xCommon entries are family-tagged as .ntag215 in the catalog.
        try runFidelity(family: .type2(.ntag215))
    }

    func test_ntag213_presets_executeWithoutThrowing() throws {
        try runFidelity(family: .type2(.ntag213))
    }

    func test_ntag216_presets_executeWithoutThrowing() throws {
        try runFidelity(family: .type2(.ntag216))
    }

    func test_ntag213TT_presets_executeWithoutThrowing() throws {
        try runFidelity(family: .type2(.ntag213TT))
    }

    func test_ntag424DNA_presets_executeWithoutThrowing() throws {
        try runFidelity(family: .type4(.ntag424DNA))
    }

    func test_mifareUltralightEV1_48_presets_executeWithoutThrowing() throws {
        try runFidelity(family: .type2(.mifareUltralightEV1_48))
    }

    func test_mifareUltralightEV1_128_presets_executeWithoutThrowing() throws {
        try runFidelity(family: .type2(.mifareUltralightEV1_128))
    }

    func test_iso15693_presets_executeWithoutThrowing() throws {
        try runFidelity(family: .type5(.icodeSlix))
    }

    func test_emV10_presets_executeWithoutThrowing() throws {
        try runFidelity(family: .type2(.emV10))
    }

    func test_emV11_presets_executeWithoutThrowing() throws {
        try runFidelity(family: .type2(.emV11))
    }

    func test_emV16_presets_executeWithoutThrowing() throws {
        try runFidelity(family: .type2(.emV16))
    }

    // MARK: - Specific bit-perfect assertions for catalog entries with

    // an explicit `expectedResponseHex` field.

    func test_ntag215_getVersion_preset_matchesExpectedHex() throws {
        let preset = CommandPresetCatalog.builtIn.first { $0.name == "Get product version" }
        let expected = try XCTUnwrap(preset?.expectedResponseHex)
        let parsed = try RawCommandSequence.parse(
            XCTUnwrap(preset?.sequenceText),
            family: XCTUnwrap(preset?.family)
        )
        let sim = NTAG215Simulator()
        let response = parsed.commands.reduce(Data()) { acc, token in
            var bytes = Data()
            for el in token.elements {
                if case .byte(let b) = el {
                    bytes.append(b)
                }
            }
            return acc + sim.handle(command: bytes)
        }
        XCTAssertEqual(response.hexString.replacingOccurrences(of: " ", with: ""),
                       expected.uppercased())
    }

    func test_ntag424_selectAID_preset_matchesExpectedHex() throws {
        let preset = CommandPresetCatalog.builtIn.first { $0.name == "Select NDEF application" }
        let expected = try XCTUnwrap(preset?.expectedResponseHex)
        let parsed = try RawCommandSequence.parse(
            XCTUnwrap(preset?.sequenceText),
            family: XCTUnwrap(preset?.family)
        )
        let sim = NTAG424DNASimulator()
        var bytes = Data()
        for el in parsed.commands[0].elements {
            if case .byte(let b) = el {
                bytes.append(b)
            }
        }
        let response = sim.handle(command: bytes)
        XCTAssertEqual(response.hexString.replacingOccurrences(of: " ", with: ""),
                       expected.uppercased())
    }

    // MARK: - Helpers

    /// Iterate every preset whose `family` matches the supplied family and
    /// run it through a fresh simulator. Reports per-preset failures with
    /// the preset's name so the failing message is actionable.
    func runFidelity(family: TagFamily) throws {
        let presets = CommandPresetCatalog.builtIn.filter { $0.family == family }
        guard !presets.isEmpty else {
            XCTFail("no presets registered for family \(family.shortName)")
            return
        }
        guard let simulator = makeSimulator(for: family) else {
            XCTFail("no simulator available for family \(family.shortName)")
            return
        }
        for preset in presets {
            do {
                let sequence = try RawCommandSequence.parse(preset.sequenceText, family: preset.family)
                let context = RawCommandSequence.BindingContext(uid: simulator.uid)
                let bound = try sequence.bind(to: context)
                for command in bound {
                    let response = simulator.handle(command: command.bytes)
                    XCTAssertFalse(response.isEmpty,
                                   "preset \"\(preset.name)\" command \(command.bytes.hexString) returned an empty response")
                }
                if let hex = preset.expectedResponseHex {
                    // Concatenate all responses and compare against expected.
                    let combined = bound.reduce(Data()) { acc, cmd in
                        acc + simulator.handle(command: cmd.bytes)
                    }
                    let normalisedExpected = hex
                        .replacingOccurrences(of: ":", with: "")
                        .replacingOccurrences(of: " ", with: "")
                        .uppercased()
                    let normalisedActual = combined.hexString.replacingOccurrences(of: ":", with: "")
                    XCTAssertEqual(normalisedActual, normalisedExpected,
                                   "preset \"\(preset.name)\" response mismatch")
                }
            } catch {
                XCTFail("preset \"\(preset.name)\" failed: \(error)")
            }
        }
    }

    /// Map a `TagFamily` to a fresh simulator. Returns `nil` for families
    /// the suite doesn't (yet) cover.
    func makeSimulator(for family: TagFamily) -> ChipSimulator? {
        switch family {
        case .type2(let v):
            switch v {
            case .unknown: UnknownType2Simulator()
            case .ntag210Micro: NTAG210MicroSimulator()
            case .ntag213: NTAG213Simulator()
            case .ntag213TT: NTAG213TTSimulator()
            case .ntag215: NTAG215Simulator()
            case .ntag216: NTAG216Simulator()
            case .mifareUltralightEV1_48: MifareUltralightEV1_48Simulator()
            case .mifareUltralightEV1_128: MifareUltralightEV1_128Simulator()
            case .mifareUltralightC: MifareUltralightCSimulator()
            case .emV10: EmV10Simulator()
            case .emV11: EmV11Simulator()
            case .emV16: EmV16Simulator()
            case .ntag424DNA: nil
            }

        case .type4(let v):
            switch v {
            case .ntag424DNA: NTAG424DNASimulator()
            default: nil
            }

        case .type5(let v):
            switch v {
            case .icodeSlix, .icodeSlix2, .icodeSlixS, .icodeSlixL, .generic, .unknown:
                Iso15693Simulator()
            }

        case .felica, .unknown:
            nil
        }
    }
}
