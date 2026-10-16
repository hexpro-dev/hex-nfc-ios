@testable import HexNFCKit
import HexNFCTagSim
import XCTest

/// Guards the Type-5 transport contract.
///
/// CoreNFC exposes no generic byte-level send for ISO 15693 — every opcode must
/// be mapped onto a typed API in `CoreNFCSession.transceiveISO15693`. An unmapped
/// opcode throws `capabilityUnsupported` on real silicon but works fine against
/// `Iso15693Simulator`, which parses raw bytes. That asymmetry is invisible to
/// every simulator-backed test, and it once left 7 of the 10 built-in Type-5
/// console presets (`0x23`, `0x27`–`0x2A`, `0x2B`, `0x2C`) dead on hardware.
///
/// These tests make that class of bug fail in CI instead of on a tag.
final class Iso15693OpcodeCoverageTests: XCTestCase {
    /// Extract the opcode (second byte) from each step of a preset sequence.
    private func opcodes(of preset: CommandPreset) -> [UInt8] {
        preset.sequenceText.split(separator: ",").compactMap { step in
            let bytes = step.trimmingCharacters(in: .whitespaces)
                .split(separator: ":")
                .compactMap { UInt8($0, radix: 16) }
            return bytes.count >= 2 ? bytes[1] : nil
        }
    }

    /// Every built-in Type-5 preset must be sendable by the production transport.
    func test_everyType5Preset_opcodeIsSupportedByTheTransport() {
        let type5Presets = CommandPresetCatalog.builtIn.filter {
            if case .type5 = $0.family {
                return true
            }
            return false
        }
        XCTAssertFalse(type5Presets.isEmpty, "expected built-in Type-5 presets")

        for preset in type5Presets {
            let codes = opcodes(of: preset)
            XCTAssertFalse(codes.isEmpty, "\(preset.name): could not parse an opcode from '\(preset.sequenceText)'")
            for code in codes {
                XCTAssertTrue(
                    Iso15693Opcode.supported.contains(code),
                    """
                    \(preset.name): opcode 0x\(String(format: "%02X", code)) has no mapping in \
                    CoreNFCSession.transceiveISO15693, so this preset throws capabilityUnsupported \
                    on a real tag while passing against the simulator.
                    """
                )
            }
        }
    }

    /// The simulator must answer everything the transport can send — otherwise a
    /// harness step green on hardware would be untestable in CI, which is the
    /// same drift in the opposite direction.
    func test_simulatorHandles_everySupportedOpcode() {
        let simulator = Iso15693Simulator()
        // Well-formed minimal frames per opcode, flag 0x02 (high data rate).
        let frames: [UInt8: [UInt8]] = [
            Iso15693Opcode.readSingleBlock: [0x02, 0x20, 0x01],
            Iso15693Opcode.writeSingleBlock: [0x02, 0x21, 0x01, 0x00, 0x00, 0x00, 0x00],
            Iso15693Opcode.readMultipleBlocks: [0x02, 0x23, 0x00, 0x01],
            Iso15693Opcode.writeAFI: [0x02, 0x27, 0x00],
            Iso15693Opcode.writeDSFID: [0x02, 0x29, 0x00],
            Iso15693Opcode.getSystemInformation: [0x02, 0x2B],
            Iso15693Opcode.getMultipleBlockSecurityStatus: [0x02, 0x2C, 0x00, 0x01],
            Iso15693Opcode.getRandomNumber: [0x02, 0xB2],
        ]
        for (code, frame) in frames {
            let response = simulator.handle(command: Data(frame))
            XCTAssertEqual(
                response.first, 0x00,
                "simulator refused opcode 0x\(String(format: "%02X", code)): \(response.hexString)"
            )
        }
    }

    /// `GET_SYSTEM_INFORMATION` is the one command whose response the production
    /// transport has to *re-encode* (CoreNFC hands back a decoded struct, not the
    /// wire frame). Pin the simulator's layout so the re-encoding in
    /// `CoreNFCSession.encodeSystemInfo` stays aligned with what parsers expect:
    /// `00 ‖ infoFlags ‖ UID(8) ‖ DSFID ‖ AFI ‖ (blocks-1) ‖ (blockSize-1) ‖ ICRef`.
    func test_getSystemInformation_wireLayout() {
        let simulator = Iso15693Simulator(blockCount: 28)
        let response = simulator.handle(command: Data([0x02, 0x2B]))
        XCTAssertEqual(response.count, 15, "unexpected frame length: \(response.hexString)")
        XCTAssertEqual(response[0], 0x00, "status byte")
        XCTAssertEqual(response[1], 0x0F, "infoFlags: DSFID + AFI + memSize + ICRef present")
        XCTAssertEqual(response[12], 27, "blockCount-1 for a 28-block tag")
        XCTAssertEqual(response[13], 3, "blockSize-1 for 4-byte blocks")
    }

    // MARK: - Manufacturer-code normalisation

    //
    // CoreNFC's `customCommand` injects the NXP manufacturer code itself, so
    // everything the transport passes is a *parameter*. The simulator used to
    // strip an `E0 04` pair locally while the transport forwarded it verbatim,
    // so a console frame that worked in CI was malformed on a tag. Live-
    // confirmed 2026-08-07 on an ICODE SLIX: `02 B2 04` went out as
    // `02 B2 04 04` and drew silence (~324 ms timeout → a generic `01 0F`),
    // which is indistinguishable from a chip that refuses the command.

    func test_normalisation_stripsTheManufacturerPairForCustomCommands() {
        XCTAssertEqual(
            Iso15693Opcode.normalisedCustomParameters(opcode: 0xB2, params: [0xE0, 0x04]), []
        )
        XCTAssertEqual(
            Iso15693Opcode.normalisedCustomParameters(opcode: 0xB3, params: [0xE0, 0x04, 0x02, 1, 2, 3, 4]),
            [0x02, 1, 2, 3, 4]
        )
    }

    /// The trap: `SET_PASSWORD`'s **privacy** identifier is itself `0x04`, so
    /// `02 B3 04 …` is a legitimate frame whose first parameter is `04`.
    /// Stripping a bare `0x04` would silently retarget the command.
    func test_normalisation_neverStripsABareManufacturerByte() {
        let privacySetPassword: [UInt8] = [0x04, 0xAA, 0xBB, 0xCC, 0xDD]
        XCTAssertEqual(
            Iso15693Opcode.normalisedCustomParameters(opcode: 0xB3, params: privacySetPassword),
            privacySetPassword
        )
    }

    /// ISO core commands take their operands positionally through typed CoreNFC
    /// calls — nothing may be removed from them.
    func test_normalisation_leavesCoreCommandsAlone() {
        XCTAssertEqual(
            Iso15693Opcode.normalisedCustomParameters(opcode: 0x21, params: [0xE0, 0x04, 0x01]),
            [0xE0, 0x04, 0x01]
        )
    }

    /// Declared parameter counts must match what the production client actually
    /// sends, or the transport's new pre-flight check rejects real commands.
    func test_customParameterCounts_matchTheProductionClientsFrames() {
        XCTAssertEqual(Iso15693Opcode.customParameterCount(for: 0xB2), 0) // getRandom: [flag, B2]
        XCTAssertEqual(Iso15693Opcode.customParameterCount(for: 0xB3), 5) // setPassword: id + 4
        XCTAssertEqual(Iso15693Opcode.customParameterCount(for: 0xB4), 5) // writePassword: id + 4
        XCTAssertEqual(Iso15693Opcode.customParameterCount(for: 0xBA), 4) // enablePrivacy: 4
        XCTAssertNil(Iso15693Opcode.customParameterCount(for: 0x20))
    }

    /// Both spellings must reach the same command on the simulator, which is
    /// the property that makes the transport's normalisation testable at all.
    func test_simulator_acceptsBothSpellingsIdentically() {
        let plain = Iso15693Simulator(blockCount: 28).handle(command: Data([0x02, 0xB2]))
        let withMfg = Iso15693Simulator(blockCount: 28).handle(command: Data([0x02, 0xB2, 0xE0, 0x04]))
        XCTAssertEqual(plain.first, 0x00, "GET_RANDOM_NUMBER should succeed: \(plain.hexString)")
        XCTAssertEqual(plain, withMfg)
    }

    /// The divergence itself: the simulator must now refuse a frame the silicon
    /// refuses. `GET_RANDOM_NUMBER` takes no parameters.
    func test_simulator_refusesAWrongParameterCount() {
        let response = Iso15693Simulator(blockCount: 28).handle(command: Data([0x02, 0xB2, 0x04]))
        XCTAssertEqual(response.first, 0x01, "expected an error frame, got \(response.hexString)")
    }
}
