@testable import HexNFCKit
import HexNFCRecords
import HexNFCTagSim
import XCTest

/// MIFARE Ultralight EV1 specifics that separate it from NTAG21x, and the
/// factory state a real EV1 actually arrives in.
///
/// EV1 is not "NTAG with a different version block": it has three independent
/// one-way counters instead of one auto-ticking NFC counter, a
/// `CHECK_TEARING_EVENT` opcode NTAG lacks, and — most consequentially — it
/// ships with a **blank OTP Capability Container** where NTAG ships
/// NDEF-preformatted.
final class UltralightEV1Tests: XCTestCase {
    // MARK: - Capabilities

    /// MF0ULx1 §8.5 / AN11340: EV1 carries an NXP originality signature.
    /// `.signatureRead` was omitted, which silently skipped the harness's
    /// signature step on both variants.
    func test_bothVariants_advertiseSignatureAndCounterRead() throws {
        for id in [ChipID.mifareUltralightEV1_48, .mifareUltralightEV1_128] {
            let profile = try XCTUnwrap(ChipCatalog.profile(for: id))
            XCTAssertTrue(profile.capabilities.contains(.signatureRead), "\(id): READ_SIG is supported silicon-side")
            XCTAssertTrue(profile.capabilities.contains(.counterRead), "\(id)")
        }
    }

    func test_readSignature_returns32Bytes() {
        let response = MifareUltralightEV1_128Simulator().handle(command: Data([0x3C, 0x00]))
        XCTAssertEqual(response.count, 32)
    }

    // MARK: - Counters

    /// Three independent 24-bit counters, all readable, none ticking on a read —
    /// the opposite of NTAG, whose single counter advances on every read.
    func test_threeIndependentCounters_doNotTickOnRead() throws {
        let simulator = MifareUltralightEV1_128Simulator()
        for index: UInt8 in 0 ... 2 {
            let frame = simulator.handle(command: Data([0x39, index]))
            XCTAssertEqual(frame.count, 3, "counter \(index) should answer with 3 bytes")
            XCTAssertEqual(frame, Data([0x00, 0x00, 0x00]), "counter \(index) ships at zero")
        }
        _ = try simulator.readNDEF()
        let afterRead = simulator.handle(command: Data([0x39, 0x00]))
        XCTAssertEqual(afterRead, Data([0x00, 0x00, 0x00]), "EV1 counters must not tick on a read")
    }

    /// A fourth counter does not exist.
    func test_counterIndexOutOfRange_naks() {
        let frame = MifareUltralightEV1_128Simulator().handle(command: Data([0x39, 0x03]))
        XCTAssertNotEqual(frame.count, 3, "index 3 is out of range and must NAK")
    }

    func test_incrementCounter_isOneWayAndObservable() {
        let simulator = MifareUltralightEV1_128Simulator()
        _ = simulator.handle(command: Data([0xA5, 0x01, 0x05, 0x00, 0x00]))
        XCTAssertEqual(simulator.handle(command: Data([0x39, 0x01])), Data([0x05, 0x00, 0x00]))
        // Counter 1 moved; 0 and 2 are independent and untouched.
        XCTAssertEqual(simulator.handle(command: Data([0x39, 0x00])), Data([0x00, 0x00, 0x00]))
        XCTAssertEqual(simulator.handle(command: Data([0x39, 0x02])), Data([0x00, 0x00, 0x00]))
    }

    // MARK: - Tearing events

    /// MF0ULx1 §10.7: `0xBD` means no tearing event occurred on that counter.
    func test_checkTearingEvent_reportsCleanCounters() {
        let simulator = MifareUltralightEV1_128Simulator()
        for index: UInt8 in 0 ... 2 {
            XCTAssertEqual(simulator.handle(command: Data([0x3E, index])), Data([0xBD]), "counter \(index)")
        }
    }

    /// NTAG21x has no such opcode and must NAK it — otherwise the harness step
    /// would appear to pass on a chip that cannot support it.
    func test_checkTearingEvent_naksOnNTAG() {
        let response = NTAG216Simulator().handle(command: Data([0x3E, 0x00]))
        XCTAssertNotEqual(response, Data([0xBD]))
    }

    // MARK: - Factory (virgin) state

    /// The divergence that mattered most: a real EV1 ships with page 3 blank.
    func test_virginTag_hasBlankOTPCapabilityContainer() throws {
        let virgin = try MifareUltralightEV1_128Simulator(virgin: true).readMemory(range: 12 ..< 16)
        XCTAssertEqual(virgin, Data([0x00, 0x00, 0x00, 0x00]))

        let formatted = try MifareUltralightEV1_128Simulator().readMemory(range: 12 ..< 16)
        XCTAssertEqual(formatted, Data([0xE1, 0x10, 0x10, 0x00]), "128 B declared, per MF0UL21")
    }

    /// Without a CC the reader path refuses — CoreNFC's `queryNDEFStatus`
    /// reports `.notSupported`, which surfaces as `capabilityUnsupported`.
    func test_virginTag_refusesNDEFRead() async throws {
        let tag = try await SimulatedSession(chip: MifareUltralightEV1_128Simulator(virgin: true)).start(alert: "")
        do {
            _ = try await tag.readNDEF()
            XCTFail("an unformatted Type-2 tag should refuse an NDEF read")
        } catch let error as TagError {
            XCTAssertEqual(error.kind, .capabilityUnsupported(.ndefRead))
        }
    }

    /// Page 3 is OTP: writes OR bits in and can never clear them. This is why
    /// the CC write is a gated one-shot rather than a batch step.
    func test_capabilityContainerPage_isOneTimeProgrammable() throws {
        let simulator = MifareUltralightEV1_128Simulator(virgin: true)
        try simulator.writeMemory(at: 12, bytes: Data([0xE1, 0x10, 0x10, 0x00]))
        XCTAssertEqual(try simulator.readMemory(range: 12 ..< 16), Data([0xE1, 0x10, 0x10, 0x00]))

        // Trying to clear it back to blank ORs, so nothing is lost.
        try? simulator.writeMemory(at: 12, bytes: Data([0x00, 0x00, 0x00, 0x00]))
        XCTAssertEqual(
            try simulator.readMemory(range: 12 ..< 16), Data([0xE1, 0x10, 0x10, 0x00]),
            "OTP bits must survive an attempted clear"
        )
    }

    /// Once formatted, the ordinary NDEF round-trip works — proving the virgin
    /// refusal is about the CC and nothing else.
    func test_formattedTag_roundTripsNDEF() async throws {
        let tag = try await SimulatedSession(chip: MifareUltralightEV1_128Simulator()).start(alert: "")
        try await tag.writeNDEF([.text(TextRecord(text: "HEXNFC", languageCode: "en"))])
        let records = try await NDEFCodec.decode(tag.readNDEF())
        guard case .text(let record)? = records.first else {
            return XCTFail("expected a text record, got \(records)")
        }
        XCTAssertEqual(record.text, "HEXNFC")
    }
}
