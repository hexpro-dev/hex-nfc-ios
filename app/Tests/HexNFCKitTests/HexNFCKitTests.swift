@testable import HexNFCKit
@testable import HexNFCRecords
@testable import HexNFCTagSim
import XCTest

final class HexNFCKitTests: XCTestCase {
    func test_moduleMarker() {
        XCTAssertEqual(HexNFCKit.moduleName, "HexNFCKit")
    }

    // MARK: - Chip catalog

    func test_catalog_identifiesNTAG215_fromGetVersion() {
        // NXP NTAG215 GET_VERSION response: 00 04 04 02 01 00 11 03
        let response = Data([0x00, 0x04, 0x04, 0x02, 0x01, 0x00, 0x11, 0x03])
        let profile = ChipCatalog.identify(getVersion: response)
        XCTAssertEqual(profile?.id, .ntag215)
    }

    func test_catalog_identifiesNTAG213_fromGetVersion() {
        let response = Data([0x00, 0x04, 0x04, 0x02, 0x01, 0x00, 0x0F, 0x03])
        XCTAssertEqual(ChipCatalog.identify(getVersion: response)?.id, .ntag213)
    }

    func test_catalog_identifiesNTAG216_fromGetVersion() {
        let response = Data([0x00, 0x04, 0x04, 0x02, 0x01, 0x00, 0x13, 0x03])
        XCTAssertEqual(ChipCatalog.identify(getVersion: response)?.id, .ntag216)
    }

    func test_catalog_unknownChipReturnsNil() {
        let response = Data([0x00, 0x04, 0x04, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertNil(ChipCatalog.identify(getVersion: response))
    }

    // MARK: - RawCommandSequence parsing

    func test_rawCommandSequence_parsesSimple() throws {
        let sequence = try RawCommandSequence.parse("21:60:00")
        XCTAssertEqual(sequence.commands.count, 1)
        XCTAssertEqual(sequence.commands[0].elements.count, 3)
    }

    func test_rawCommandSequence_chainCommas() throws {
        let sequence = try RawCommandSequence.parse("21:60:00, 21:00:E1:40")
        XCTAssertEqual(sequence.commands.count, 2)
    }

    func test_rawCommandSequence_placeholderBindsFromUID() throws {
        let sequence = try RawCommandSequence.parse("A2:??:??:??:??")
        let bound = try sequence.bind(to: .init(uid: Data([0xDE, 0xAD, 0xBE, 0xEF])))
        XCTAssertEqual(bound.count, 1)
        XCTAssertEqual(bound[0].bytes, Data([0xA2, 0xDE, 0xAD, 0xBE, 0xEF]))
    }

    func test_rawCommandSequence_invalidByteThrows() {
        XCTAssertThrowsError(try RawCommandSequence.parse("GG:21"))
    }

    func test_rawCommandSequence_emptyThrows() {
        XCTAssertThrowsError(try RawCommandSequence.parse("   "))
    }

    // MARK: - NTAG21x parameterised suite

    //
    // Each public NTAG21x behaviour (NDEF round-trip, password auth,
    // permanent lock, GET_VERSION, READ_SIG, counter tick) runs once per
    // variant — NTAG213 / 215 / 216 — through these helpers. The
    // per-variant `test_…` methods are thin entry points so XCTest counts
    // each chip-behaviour pair separately.

    private func assertNDEFRoundTrips(
        _ simulator: NTAG21xSimulator,
        expectedID: ChipID
    ) async throws {
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "Hold tag steady")

        XCTAssertEqual(tag.uid, simulator.uid)
        XCTAssertEqual(tag.chip?.id, expectedID)
        XCTAssertTrue(tag.capabilities.contains(.ndefRead))
        XCTAssertTrue(tag.capabilities.contains(.ndefWrite))

        // Use minimal payloads so the same assertion fits inside the
        // smallest tag we test (MIFARE Ultralight EV1 48b = 48 NDEF bytes).
        try await tag.writeNDEF([
            .uri(URIRecord(uri: "https://hex.pro")),
            .text(TextRecord(text: "hi")),
        ])

        let read = try await tag.readNDEF()
        let decoded = try NDEFCodec.decode(read)
        XCTAssertEqual(decoded.count, 2)
        guard case .uri(let uri) = decoded[0] else { return XCTFail("first record should be uri") }
        XCTAssertEqual(uri.uri, "https://hex.pro")
        guard case .text(let text) = decoded[1] else { return XCTFail("second should be text") }
        XCTAssertEqual(text.text, "hi")
    }

    private func assertPasswordAuthSucceeds(_ simulator: NTAG21xSimulator) async throws {
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")

        let pwd = Data([0xCA, 0xFE, 0xBA, 0xBE])
        let pack = Data([0xFE, 0xED])
        try await tag.setPassword(pwd, pack: pack)
        let returnedPack = try await tag.authenticate(password: pwd)
        XCTAssertEqual(returnedPack, pack)
    }

    private func assertPasswordAuthFails(_ simulator: NTAG21xSimulator) async throws {
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")

        try await tag.setPassword(Data([0x11, 0x22, 0x33, 0x44]), pack: Data([0xAA, 0xBB]))
        do {
            _ = try await tag.authenticate(password: Data([0xDE, 0xAD, 0xBE, 0xEF]))
            XCTFail("should have thrown")
        } catch let error as TagError {
            guard case .authFailed = error.kind else { return XCTFail("wrong kind") }
        }
    }

    private func assertPermanentLockBlocksWrites(_ simulator: NTAG21xSimulator) async throws {
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")

        try await tag.writeNDEF([.uri(URIRecord(uri: "https://hex.pro"))])
        try await tag.permanentLock()

        do {
            try await tag.writeNDEF([.uri(URIRecord(uri: "https://example.com"))])
            XCTFail("write should have been blocked by permanent lock")
        } catch let error as TagError {
            guard case .lockedPermanent = error.kind else { return XCTFail("wrong kind: \(error.kind)") }
        }
    }

    private func assertGetVersionRoundTrips(
        _ simulator: NTAG21xSimulator,
        expectedID: ChipID
    ) async throws {
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")
        let response = try await tag.transceive(RawCommand(bytes: Data([0x60])))
        XCTAssertEqual(ChipCatalog.identify(getVersion: response)?.id, expectedID)
    }

    private func assertReadSignatureReturnsStableBytes(_ simulator: NTAG21xSimulator) async throws {
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")
        let signature = try await tag.transceive(RawCommand(bytes: Data([0x3C, 0x00])))
        XCTAssertEqual(signature.count, 32)
        XCTAssertEqual(signature, simulator.signature)
    }

    private func assertNfcCounterTicks(_ simulator: NTAG21xSimulator) async throws {
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")
        _ = try await tag.readNDEF()
        let counterBytes = try await tag.transceive(RawCommand(bytes: Data([0x39, 0x02])))
        // Datasheet: READ_CNT response is LSB-first 3 bytes.
        let value = Int(counterBytes[0]) | (Int(counterBytes[1]) << 8) | (Int(counterBytes[2]) << 16)
        XCTAssertEqual(value, 1)
    }

    // MARK: NTAG213 entry points

    func test_ntag213_writeAndReadNDEF_roundTrips() async throws {
        try await assertNDEFRoundTrips(NTAG213Simulator(), expectedID: .ntag213)
    }

    func test_ntag213_passwordAuth_succeedsWithRightPassword() async throws {
        try await assertPasswordAuthSucceeds(NTAG213Simulator())
    }

    func test_ntag213_passwordAuth_failsWithWrongPassword() async throws {
        try await assertPasswordAuthFails(NTAG213Simulator())
    }

    func test_ntag213_permanentLock_blocksFurtherWrites() async throws {
        try await assertPermanentLockBlocksWrites(NTAG213Simulator())
    }

    func test_ntag213_getVersion_viaTransceive() async throws {
        try await assertGetVersionRoundTrips(NTAG213Simulator(), expectedID: .ntag213)
    }

    func test_ntag213_readSignature_returnsStableBytes() async throws {
        try await assertReadSignatureReturnsStableBytes(NTAG213Simulator())
    }

    func test_ntag213_nfcCounter_tickIncrements() async throws {
        try await assertNfcCounterTicks(NTAG213Simulator())
    }

    // MARK: NTAG215 entry points

    func test_ntag215_writeAndReadNDEF_roundTrips() async throws {
        try await assertNDEFRoundTrips(NTAG215Simulator(), expectedID: .ntag215)
    }

    func test_ntag215_passwordAuth_succeedsWithRightPassword() async throws {
        try await assertPasswordAuthSucceeds(NTAG215Simulator())
    }

    func test_ntag215_passwordAuth_failsWithWrongPassword() async throws {
        try await assertPasswordAuthFails(NTAG215Simulator())
    }

    func test_ntag215_permanentLock_blocksFurtherWrites() async throws {
        try await assertPermanentLockBlocksWrites(NTAG215Simulator())
    }

    func test_ntag215_getVersion_viaTransceive() async throws {
        try await assertGetVersionRoundTrips(NTAG215Simulator(), expectedID: .ntag215)
    }

    func test_ntag215_readSignature_returnsStableBytes() async throws {
        try await assertReadSignatureReturnsStableBytes(NTAG215Simulator())
    }

    func test_ntag215_nfcCounter_tickIncrements() async throws {
        try await assertNfcCounterTicks(NTAG215Simulator())
    }

    // MARK: NTAG216 entry points

    func test_ntag216_writeAndReadNDEF_roundTrips() async throws {
        try await assertNDEFRoundTrips(NTAG216Simulator(), expectedID: .ntag216)
    }

    func test_ntag216_passwordAuth_succeedsWithRightPassword() async throws {
        try await assertPasswordAuthSucceeds(NTAG216Simulator())
    }

    func test_ntag216_passwordAuth_failsWithWrongPassword() async throws {
        try await assertPasswordAuthFails(NTAG216Simulator())
    }

    func test_ntag216_permanentLock_blocksFurtherWrites() async throws {
        try await assertPermanentLockBlocksWrites(NTAG216Simulator())
    }

    func test_ntag216_getVersion_viaTransceive() async throws {
        try await assertGetVersionRoundTrips(NTAG216Simulator(), expectedID: .ntag216)
    }

    func test_ntag216_readSignature_returnsStableBytes() async throws {
        try await assertReadSignatureReturnsStableBytes(NTAG216Simulator())
    }

    func test_ntag216_nfcCounter_tickIncrements() async throws {
        try await assertNfcCounterTicks(NTAG216Simulator())
    }

    // MARK: - MIFARE Ultralight EV1 entry points

    //
    // The parameterised Type-2 suite runs for both EV1 variants — minus
    // the counter-tick assertion, since EV1 counters change only via
    // INCR_CNT (not auto-increment on read). EV1-specific opcodes get
    // their own block below.

    func test_eV1_48_writeAndReadNDEF_roundTrips() async throws {
        try await assertNDEFRoundTrips(MifareUltralightEV1_48Simulator(), expectedID: .mifareUltralightEV1_48)
    }

    func test_eV1_48_passwordAuth_succeedsWithRightPassword() async throws {
        try await assertPasswordAuthSucceeds(MifareUltralightEV1_48Simulator())
    }

    func test_eV1_48_passwordAuth_failsWithWrongPassword() async throws {
        try await assertPasswordAuthFails(MifareUltralightEV1_48Simulator())
    }

    func test_eV1_48_permanentLock_blocksFurtherWrites() async throws {
        try await assertPermanentLockBlocksWrites(MifareUltralightEV1_48Simulator())
    }

    func test_eV1_48_getVersion_viaTransceive() async throws {
        try await assertGetVersionRoundTrips(MifareUltralightEV1_48Simulator(), expectedID: .mifareUltralightEV1_48)
    }

    func test_eV1_48_readSignature_returnsStableBytes() async throws {
        try await assertReadSignatureReturnsStableBytes(MifareUltralightEV1_48Simulator())
    }

    func test_eV1_128_writeAndReadNDEF_roundTrips() async throws {
        try await assertNDEFRoundTrips(MifareUltralightEV1_128Simulator(), expectedID: .mifareUltralightEV1_128)
    }

    func test_eV1_128_passwordAuth_succeedsWithRightPassword() async throws {
        try await assertPasswordAuthSucceeds(MifareUltralightEV1_128Simulator())
    }

    func test_eV1_128_getVersion_viaTransceive() async throws {
        try await assertGetVersionRoundTrips(MifareUltralightEV1_128Simulator(), expectedID: .mifareUltralightEV1_128)
    }

    func test_eV1_128_readSignature_returnsStableBytes() async throws {
        try await assertReadSignatureReturnsStableBytes(MifareUltralightEV1_128Simulator())
    }

    // MARK: - EV1-specific opcodes

    func test_eV1_threeCounters_incrementIndependently() async throws {
        let simulator = MifareUltralightEV1_48Simulator()
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")

        // INCR_CNT 0 by 5.
        let ack0 = try await tag.transceive(RawCommand(bytes: Data([0xA5, 0x00, 0x05, 0x00, 0x00])))
        XCTAssertEqual(ack0, Data([0x0A]))
        // INCR_CNT 1 by 10.
        _ = try await tag.transceive(RawCommand(bytes: Data([0xA5, 0x01, 0x0A, 0x00, 0x00])))
        // INCR_CNT 2 by 256 (0x100).
        _ = try await tag.transceive(RawCommand(bytes: Data([0xA5, 0x02, 0x00, 0x01, 0x00])))

        let c0 = try await tag.transceive(RawCommand(bytes: Data([0x39, 0x00])))
        XCTAssertEqual(c0, Data([0x05, 0x00, 0x00]))
        let c1 = try await tag.transceive(RawCommand(bytes: Data([0x39, 0x01])))
        XCTAssertEqual(c1, Data([0x0A, 0x00, 0x00]))
        let c2 = try await tag.transceive(RawCommand(bytes: Data([0x39, 0x02])))
        XCTAssertEqual(c2, Data([0x00, 0x01, 0x00]))
    }

    func test_eV1_counterOverflow_returnsNAK() async throws {
        let simulator = MifareUltralightEV1_48Simulator()
        simulator.nfcCounters[0] = 0x00FF_FFFE
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")

        // Add 2 to a counter holding 0xFFFFFE ⇒ would overflow 24 bits ⇒ NAK.
        let response = try await tag.transceive(RawCommand(bytes: Data([0xA5, 0x00, 0x02, 0x00, 0x00])))
        XCTAssertEqual(response, Data([0x00]))
        // Counter unchanged.
        XCTAssertEqual(simulator.nfcCounters[0], 0x00FF_FFFE)
    }

    func test_eV1_3desAuth_returnsCannedNAK() async throws {
        // The simulator does not implement the legacy 3DES cipher used by
        // EV1's 0x1A AUTHENTICATE — document the limitation explicitly.
        let simulator = MifareUltralightEV1_48Simulator()
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")
        let response = try await tag.transceive(RawCommand(bytes: Data([0x1A, 0x00])))
        XCTAssertEqual(response, Data([0x00]))
    }

    func test_eV1_getVersion_distinguishes48from128() async throws {
        let v48 = MifareUltralightEV1_48Simulator()
        let v128 = MifareUltralightEV1_128Simulator()
        let session48 = SimulatedSession(chip: v48)
        let session128 = SimulatedSession(chip: v128)
        let tag48 = try await session48.start(alert: "")
        let tag128 = try await session128.start(alert: "")
        let r48 = try await tag48.transceive(RawCommand(bytes: Data([0x60])))
        let r128 = try await tag128.transceive(RawCommand(bytes: Data([0x60])))
        XCTAssertEqual(r48[6], 0x0B, "48b variant storage byte")
        XCTAssertEqual(r128[6], 0x0E, "128b variant storage byte")
    }

    // MARK: - Unknown-chip fallback

    func test_unknownType2_getVersion_returnsZeros_andCatalogReturnsNil() async throws {
        let simulator = UnknownType2Simulator()
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")
        let response = try await tag.transceive(RawCommand(bytes: Data([0x60])))
        XCTAssertEqual(response, Data(repeating: 0x00, count: 8))
        XCTAssertNil(ChipCatalog.identify(getVersion: response),
                     "catalog should refuse to identify a zero version block")
        XCTAssertNil(tag.chip, "tag should expose no profile for an unknown chip")
    }

    func test_unknownType2_supportsBasicReadWrite() async throws {
        let simulator = UnknownType2Simulator()
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")
        try await tag.writeMemory(at: 4 * 4, bytes: Data([0x11, 0x22, 0x33, 0x44]))
        let read = try await tag.transceive(RawCommand(bytes: Data([0x30, 0x04])))
        // READ returns 16 bytes; we wrote page 4, so first 4 = our payload.
        XCTAssertEqual(read.prefix(4), Data([0x11, 0x22, 0x33, 0x44]))
    }

    // MARK: - EM Microelectronic V10 / V11 / V16

    func test_em_v10_pvm_atPageZero_identifiesViaEmSignature() async throws {
        let simulator = EmV10Simulator()
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")
        let pvm = try await tag.readMemory(range: 0 ..< 2)
        let profile = ChipCatalog.identify(emSignature: pvm)
        XCTAssertEqual(profile?.id, .emV10)
    }

    func test_em_v11_pvm_atPageZero_identifiesViaEmSignature() async throws {
        let simulator = EmV11Simulator()
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")
        let pvm = try await tag.readMemory(range: 0 ..< 2)
        XCTAssertEqual(ChipCatalog.identify(emSignature: pvm)?.id, .emV11)
    }

    func test_em_v16_pvm_atPageZero_identifiesViaEmSignature() async throws {
        let simulator = EmV16Simulator()
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")
        let pvm = try await tag.readMemory(range: 0 ..< 2)
        XCTAssertEqual(ChipCatalog.identify(emSignature: pvm)?.id, .emV16)
    }

    func test_em_writeAndReadNDEF_roundTrips() async throws {
        let simulator = EmV10Simulator()
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")
        try await tag.writeNDEF([.uri(URIRecord(uri: "https://hex.pro"))])
        let read = try await tag.readNDEF()
        let decoded = try NDEFCodec.decode(read)
        guard case .uri(let uri) = decoded[0] else { return XCTFail("expected uri") }
        XCTAssertEqual(uri.uri, "https://hex.pro")
    }

    func test_em_v10_tamperPageRead_returnsClosedLoopByDefault() async throws {
        let simulator = EmV10Simulator()
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")
        let page = try await tag.transceive(RawCommand(bytes: Data([0x30, 0x08])))
        XCTAssertEqual(page[page.startIndex], 0x55, "V10 tamper page (0x08) should default closed")
    }

    func test_em_v11_tamperPageRead_returnsClosedLoopByDefault() async throws {
        let simulator = EmV11Simulator()
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")
        let page = try await tag.transceive(RawCommand(bytes: Data([0x30, 0x09])))
        XCTAssertEqual(page[page.startIndex], 0x55)
    }

    func test_em_v16_tamperPageRead_returnsClosedLoopByDefault() async throws {
        let simulator = EmV16Simulator()
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")
        let page = try await tag.transceive(RawCommand(bytes: Data([0x30, 0x0A])))
        XCTAssertEqual(page[page.startIndex], 0x55)
    }

    func test_em_v10_tamperByteFlips_whenWritten() async throws {
        let simulator = EmV10Simulator()
        simulator.writeTamperStatus(0xAA)
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")
        let page = try await tag.transceive(RawCommand(bytes: Data([0x30, 0x08])))
        XCTAssertEqual(page[page.startIndex], 0xAA)
    }

    func test_em_v10_activateHFCryptoMode_returnsCannedACK() async throws {
        let simulator = EmV10Simulator()
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")
        let response = try await tag.transceive(RawCommand(bytes: Data([0x1A, 0x00, 0x00, 0x00, 0x00])))
        XCTAssertEqual(response, Data([0x0A]))
    }

    func test_em_passwordAuth_throwsCapabilityUnsupported() async throws {
        let simulator = EmV10Simulator()
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")
        do {
            _ = try await tag.authenticate(password: Data([0x00, 0x00, 0x00, 0x00]))
            XCTFail("EM chips lack password auth — should reject")
        } catch let error as TagError {
            guard case .capabilityUnsupported = error.kind else { return XCTFail("wrong kind") }
        }
    }

    func test_em_permanentLock_throwsCapabilityUnsupported() async throws {
        let simulator = EmV10Simulator()
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")
        do {
            try await tag.permanentLock()
            XCTFail("EM chips lack permanent lock — should reject")
        } catch let error as TagError {
            guard case .capabilityUnsupported = error.kind else { return XCTFail("wrong kind") }
        }
    }

    func test_em_personalisationChain_runsThroughSimulator() async throws {
        // Mirrors `CommandPresetCatalog.emV10` V10 personalisation chain:
        //   A2:03:E1:10:06:00, A2:04:03:00:FE:00
        let simulator = EmV10Simulator()
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")
        let r1 = try await tag.transceive(RawCommand(bytes: Data([0xA2, 0x03, 0xE1, 0x10, 0x06, 0x00])))
        XCTAssertEqual(r1, Data([0x0A]))
        let r2 = try await tag.transceive(RawCommand(bytes: Data([0xA2, 0x04, 0x03, 0x00, 0xFE, 0x00])))
        XCTAssertEqual(r2, Data([0x0A]))
    }

    // MARK: - NTAG213 TT tamper-loop opcode

    func test_ntag213TT_readTTStatus_returnsZeroMaskWhenIntact() async throws {
        // Per NT2H1311TT Rev 1.1: 0xA4 (not 0xA5) is READ_TT_STATUS, and
        // the response is 4 bytes. Intact = `00 00 00 00`; broken = the
        // customer's TT_MESSAGE page.
        let simulator = NTAG213TTSimulator()
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")
        let response = try await tag.transceive(RawCommand(bytes: Data([0xA4])))
        XCTAssertEqual(response, Data([0x00, 0x00, 0x00, 0x00]))
    }

    func test_ntag213TT_readTTStatus_returnsTamperMessageWhenBroken() async throws {
        let simulator = NTAG213TTSimulator()
        simulator.tamperStatus = 0xAA
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")
        let response = try await tag.transceive(RawCommand(bytes: Data([0xA4])))
        XCTAssertEqual(response, simulator.tamperMessage)
        XCTAssertEqual(response.count, 4)
    }

    func test_nonTT_ntag215_rejects_readTTStatus() async throws {
        let simulator = NTAG215Simulator()
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")
        let response = try await tag.transceive(RawCommand(bytes: Data([0xA4])))
        XCTAssertEqual(response, Data([0x00]), "NTAG215 lacks .tamperStatus capability — should NAK")
    }

    // MARK: - Lock-state machine tests

    //
    // Each test sets up the relevant config / lock byte state on a fresh
    // simulator, then asserts the kit's `ConnectedTag` surface raises the
    // right error kind. These are the load-bearing assertions for the
    // physical-tag QA pass.

    func test_lockState_authLimExhaustion_disablesAuthWithoutBricking() async throws {
        let simulator = NTAG215Simulator()
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")

        // Set ACCESS = AUTH_LIM(3), PROT=0 (write-only protect) in config1 (page 132).
        try await tag.writeMemory(at: 132 * 4, bytes: Data([0x03, 0x00, 0x00, 0x00]))
        // Set a known PWD/PACK and AUTH0=4 so anything ≥ page 4 is write-protected.
        let pwd = Data([0xC0, 0xDE, 0xC0, 0xDE])
        try await tag.setPassword(pwd, pack: Data([0xC0, 0xDE]))
        try await tag.writeMemory(at: 131 * 4, bytes: Data([0x00, 0x00, 0x00, 0x04]))

        // Four failed auths in a row: AUTH_LIM=3 disables authentication one
        // past the limit, as NTAG213 silicon showed on 2026-09-14, and it is NOT
        // a lock-byte brick.
        //
        // One attempt per tap. A refused PWD_AUTH NAKs, and a NAK returns a
        // Type-2 chip to HALT for the rest of the activation, so a second
        // attempt in the same tap reaches nothing and costs the chip nothing.
        // AUTH_LIM counts in the chip's non-volatile attempt counter, which
        // survives the tap boundary, so exhausting it takes four activations
        // under the rule measured on NTAG213. This is an NTAG215, which was not
        // measured.
        for _ in 0 ..< 4 {
            simulator.beginActivation()
            do {
                _ = try await tag.authenticate(password: Data([0x11, 0x22, 0x33, 0x44]))
                XCTFail("auth should have failed")
            } catch let error as TagError {
                guard case .authFailed = error.kind else { return XCTFail("wrong kind: \(error.kind)") }
            }
        }
        XCTAssertTrue(simulator.isAuthLocked, "AUTH_LIM exhaustion should disable authentication")
        XCTAssertFalse(simulator.isLockedPermanent, "AUTH_LIM exhaustion is not a permanent lock-byte brick")

        // Even the CORRECT password now fails — auth is permanently disabled.
        simulator.beginActivation()
        do {
            _ = try await tag.authenticate(password: pwd)
            XCTFail("auth should stay disabled after AUTH_LIM lockout")
        } catch let error as TagError {
            guard case .authFailed = error.kind else { return XCTFail("wrong kind: \(error.kind)") }
        }

        // The tag is not bricked: PROT=0 means reads were never auth-gated, so the
        // NDEF area is still readable after lockout, on the next tap, since the
        // refusal above halted the chip for the rest of that one.
        simulator.beginActivation()
        _ = try await tag.readMemory(range: (4 * 4) ..< (5 * 4))
    }

    func test_lockState_staticLockBit_blocksOnlyAffectedPage() async throws {
        let simulator = NTAG215Simulator()
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")

        // Page 2 layout: [BCC1, internal, lockHigh, lockLow].
        // Lock bit position == page index. Set bit 4 in lockHigh → page 4 locked.
        let page2 = try await tag.transceive(RawCommand(bytes: Data([0x30, 0x02]))).prefix(4)
        var newPage2 = Data(page2)
        newPage2[2] = 0x10 // bit 4 set
        try await tag.writeMemory(at: 2 * 4, bytes: newPage2)

        do {
            try await tag.writeMemory(at: 4 * 4, bytes: Data([0xAA, 0xBB, 0xCC, 0xDD]))
            XCTFail("page 4 write should have been blocked")
        } catch let error as TagError {
            guard case .lockedPermanent = error.kind else { return XCTFail("wrong kind: \(error.kind)") }
        }
        // Page 5 is still writable.
        try await tag.writeMemory(at: 5 * 4, bytes: Data([0xAA, 0xBB, 0xCC, 0xDD]))
    }

    func test_lockState_dynamicLockBit_blocksPagesAbove16() async throws {
        let simulator = NTAG215Simulator()
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")

        // Set dynamic lock byte at NTAG215 page 130 to a non-zero pattern.
        try await tag.writeMemory(at: 130 * 4, bytes: Data([0xFF, 0xFF, 0xFF, 0x00]))

        do {
            try await tag.writeMemory(at: 20 * 4, bytes: Data([0x01, 0x02, 0x03, 0x04]))
            XCTFail("page 20 write should have been blocked by dynamic lock")
        } catch let error as TagError {
            guard case .lockedPermanent = error.kind else { return XCTFail("wrong kind: \(error.kind)") }
        }
    }

    func test_lockState_readProtect_blocksReadsUntilAuth() async throws {
        let simulator = NTAG215Simulator()
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")

        try await tag.setPassword(Data([0x01, 0x02, 0x03, 0x04]), pack: Data([0xAA, 0xBB]))
        // PROT=1 + AUTH0=4 ⇒ reads of any page >= 4 require auth.
        try await tag.writeMemory(at: 132 * 4, bytes: Data([0x80, 0x00, 0x00, 0x00]))
        try await tag.writeMemory(at: 131 * 4, bytes: Data([0x00, 0x00, 0x00, 0x04]))

        do {
            _ = try await tag.readMemory(range: (4 * 4) ..< (5 * 4))
            XCTFail("page 4 read should have been blocked by PROT/AUTH0")
        } catch let error as TagError {
            guard case .authFailed = error.kind else { return XCTFail("wrong kind: \(error.kind)") }
        }

        _ = try await tag.authenticate(password: Data([0x01, 0x02, 0x03, 0x04]))
        let bytes = try await tag.readMemory(range: (4 * 4) ..< (5 * 4))
        XCTAssertEqual(bytes.count, 4, "page 4 should be readable after auth")
    }

    func test_lockState_nfcCounter_saturatesAtMaximum() async throws {
        let simulator = NTAG215Simulator()
        // Seed at the saturation point.
        simulator.seedNfcCounter(0x00FF_FFFF)
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")
        _ = try await tag.readNDEF() // tick attempt → no change
        let bytes = try await tag.transceive(RawCommand(bytes: Data([0x39, 0x02])))
        // Per NXP NT2H1311 §8.6: counter holds at FF FF FF, does not wrap.
        XCTAssertEqual(bytes, Data([0xFF, 0xFF, 0xFF]),
                       "24-bit NFC counter must saturate at FF FF FF, not wrap to zero")
    }

    func test_sectorSelect_isNotInCommandSet_forNtagFamily() async throws {
        // Per NT2H1311 §9.1 Table 22: SECTOR_SELECT (0xC2) is **not** in
        // the NTAG213/215/216 command set. It's an NTAG I²C / Ultralight
        // EV1 feature for chips with >256 addressable pages, and none of
        // the chips we model exceed that. Real silicon returns NAK 0h
        // (invalid argument / unknown command) — match that.
        let simulator = NTAG216Simulator()
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")
        let response = try await tag.transceive(RawCommand(bytes: Data([0xC2, 0xFF])))
        XCTAssertEqual(response, Data([0x00]), "NTAG216 should NAK SECTOR_SELECT")
    }

    // MARK: - NTAG424 DNA quick smoke

    //
    // Deeper NTAG424 protocol coverage lives in `NTAG424CryptoTests` —
    // these two here are the cross-suite hooks so the file still mentions
    // the chip explicitly.

    func test_ntag424_selectAID_succeeds() async throws {
        let simulator = NTAG424DNASimulator()
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")
        XCTAssertEqual(tag.chip?.id, .ntag424DNA)
        let select = Data([0x00, 0xA4, 0x04, 0x00, 0x07, 0xD2, 0x76, 0x00, 0x00, 0x85, 0x01, 0x01, 0x00])
        let response = try await tag.transceive(RawCommand(bytes: select))
        XCTAssertEqual(response.suffix(2), Data([0x90, 0x00]))
    }

    func test_ntag424_passwordAuth_throwsCapabilityUnsupported() async {
        let simulator = NTAG424DNASimulator()
        let session = SimulatedSession(chip: simulator)
        do {
            let tag = try await session.start(alert: "")
            _ = try await tag.authenticate(password: Data([0x00, 0x00, 0x00, 0x00]))
            XCTFail("NTAG424 should reject password-style auth")
        } catch let error as TagError {
            guard case .capabilityUnsupported = error.kind else {
                return XCTFail("expected capabilityUnsupported, got \(error.kind)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - SimulatedSession behaviours

    func test_session_behaviourTagLost_throws() async {
        let session = SimulatedSession(chip: NTAG215Simulator(), behaviour: .tagLost)
        do {
            _ = try await session.start(alert: "")
            XCTFail("should have thrown")
        } catch let error as TagError {
            guard case .tagLost = error.kind else { return XCTFail("wrong kind") }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_session_invalidate_recordsError() async {
        let session = SimulatedSession(chip: NTAG215Simulator())
        await session.invalidate(error: "user cancelled")
        XCTAssertTrue(session.didInvalidate)
        XCTAssertEqual(session.invalidationError, "user cancelled")
    }
}
