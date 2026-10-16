@testable import HexNFCKit
@testable import HexNFCRecords
@testable import HexNFCTagSim
import XCTest

/// Crypto-primitive and protocol tests for `NTAG424Crypto`,
/// `NTAG424SUNMessage`, and the auth chain on `NTAG424DNASimulator`.
///
/// AES-CMAC is verified bit-for-bit against RFC 4493 §4 test vectors;
/// AES-CBC against a self-derived round-trip. The session-key derivation
/// and SUN message authoring are exercised through the simulator's
/// AuthenticateEV2First flow.
final class NTAG424CryptoTests: XCTestCase {
    // MARK: - RFC 4493 §4 AES-CMAC test vectors

    private let rfc4493Key = Data([
        0x2B, 0x7E, 0x15, 0x16, 0x28, 0xAE, 0xD2, 0xA6,
        0xAB, 0xF7, 0x15, 0x88, 0x09, 0xCF, 0x4F, 0x3C,
    ])

    private let rfc4493Message: Data = .init([
        0x6B, 0xC1, 0xBE, 0xE2, 0x2E, 0x40, 0x9F, 0x96,
        0xE9, 0x3D, 0x7E, 0x11, 0x73, 0x93, 0x17, 0x2A,
        0xAE, 0x2D, 0x8A, 0x57, 0x1E, 0x03, 0xAC, 0x9C,
        0x9E, 0xB7, 0x6F, 0xAC, 0x45, 0xAF, 0x8E, 0x51,
        0x30, 0xC8, 0x1C, 0x46, 0xA3, 0x5C, 0xE4, 0x11,
        0xE5, 0xFB, 0xC1, 0x19, 0x1A, 0x0A, 0x52, 0xEF,
        0xF6, 0x9F, 0x24, 0x45, 0xDF, 0x4F, 0x9B, 0x17,
        0xAD, 0x2B, 0x41, 0x7B, 0xE6, 0x6C, 0x37, 0x10,
    ])

    func test_cmac_emptyMessage_matchesRFC4493Vector1() {
        let expected = Data([
            0xBB, 0x1D, 0x69, 0x29, 0xE9, 0x59, 0x37, 0x28,
            0x7F, 0xA3, 0x7D, 0x12, 0x9B, 0x75, 0x67, 0x46,
        ])
        let actual = NTAG424Crypto.aesCMAC(key: rfc4493Key, data: Data())
        XCTAssertEqual(actual, expected)
    }

    func test_cmac_singleBlock_matchesRFC4493Vector2() {
        let expected = Data([
            0x07, 0x0A, 0x16, 0xB4, 0x6B, 0x4D, 0x41, 0x44,
            0xF7, 0x9B, 0xDD, 0x9D, 0xD0, 0x4A, 0x28, 0x7C,
        ])
        let actual = NTAG424Crypto.aesCMAC(key: rfc4493Key, data: rfc4493Message.prefix(16))
        XCTAssertEqual(actual, expected)
    }

    func test_cmac_partialBlocks_matchesRFC4493Vector3() {
        let expected = Data([
            0xDF, 0xA6, 0x67, 0x47, 0xDE, 0x9A, 0xE6, 0x30,
            0x30, 0xCA, 0x32, 0x61, 0x14, 0x97, 0xC8, 0x27,
        ])
        let actual = NTAG424Crypto.aesCMAC(key: rfc4493Key, data: rfc4493Message.prefix(40))
        XCTAssertEqual(actual, expected)
    }

    func test_cmac_fullFourBlocks_matchesRFC4493Vector4() {
        let expected = Data([
            0x51, 0xF0, 0xBE, 0xBF, 0x7E, 0x3B, 0x9D, 0x92,
            0xFC, 0x49, 0x74, 0x17, 0x79, 0x36, 0x3C, 0xFE,
        ])
        let actual = NTAG424Crypto.aesCMAC(key: rfc4493Key, data: rfc4493Message.prefix(64))
        XCTAssertEqual(actual, expected)
    }

    // MARK: - AES-CBC self round-trip

    func test_aesCBC_encryptThenDecrypt_recoversPlaintext() {
        let key = Data(repeating: 0x42, count: 16)
        let iv = Data((0 ..< 16).map { UInt8($0) })
        let plaintext = Data(repeating: 0xAB, count: 64)
        let ct = NTAG424Crypto.aesCBCEncrypt(key: key, iv: iv, data: plaintext)
        XCTAssertEqual(ct.count, 64)
        XCTAssertNotEqual(ct, plaintext)
        let pt = NTAG424Crypto.aesCBCDecrypt(key: key, iv: iv, data: ct)
        XCTAssertEqual(pt, plaintext)
    }

    // MARK: - Session-key derivation

    func test_sessionVectors_lengthIsExactly32Bytes() {
        let randA = Data((0 ..< 16).map { UInt8($0) })
        let randB = Data((0 ..< 16).map { UInt8($0 ^ 0xFF) })
        let sv1 = NTAG424Crypto.sessionVector(prefix: 0xA5, alt: 0x5A, randA: randA, randB: randB)
        let sv2 = NTAG424Crypto.sessionVector(prefix: 0x5A, alt: 0xA5, randA: randA, randB: randB)
        XCTAssertEqual(sv1.count, 32)
        XCTAssertEqual(sv2.count, 32)
        XCTAssertNotEqual(sv1, sv2)
        XCTAssertEqual(sv1[0], 0xA5)
        XCTAssertEqual(sv2[0], 0x5A)
    }

    func test_deriveENCKey_andDeriveMACKey_diverge() {
        let appKey = Data(repeating: 0x00, count: 16)
        let randA = Data((0 ..< 16).map { UInt8($0) })
        let randB = Data((0 ..< 16).map { UInt8($0 ^ 0xCC) })
        let enc = NTAG424Crypto.deriveENCKey(appKey: appKey, randA: randA, randB: randB)
        let mac = NTAG424Crypto.deriveMACKey(appKey: appKey, randA: randA, randB: randB)
        XCTAssertEqual(enc.count, 16)
        XCTAssertEqual(mac.count, 16)
        XCTAssertNotEqual(enc, mac, "ENC and MAC keys must differ")
    }

    // MARK: - Rotation

    func test_rotateLeftByOne_movesFirstByteToEnd() {
        let input = Data([0xAA, 0xBB, 0xCC, 0xDD])
        let rotated = NTAG424Crypto.rotateLeftByOne(input)
        XCTAssertEqual(rotated, Data([0xBB, 0xCC, 0xDD, 0xAA]))
    }

    // MARK: - SUN message round-trip

    func test_sunMessage_encodeThenDecodeAndVerify_returnsOriginalFields() {
        let encKey = Data(repeating: 0x11, count: 16)
        let macKey = Data(repeating: 0x22, count: 16)
        let uid = Data([0x04, 0x99, 0x88, 0x77, 0x66, 0x55, 0x44])
        let url = NTAG424SUNMessage.makeURL(
            uid: uid,
            readCounter: 0x1234,
            encKey: encKey,
            macKey: macKey
        )
        XCTAssertTrue(url.hasPrefix("https://hex.pro/v?p="), "default template")
        XCTAssertTrue(url.contains("&c="))

        guard let decoded = NTAG424SUNMessage.decodeAndVerify(
            url: url, encKey: encKey, macKey: macKey
        ) else {
            return XCTFail("SUN URL failed to decode and verify")
        }
        XCTAssertEqual(decoded.uid, uid)
        XCTAssertEqual(decoded.readCounter, 0x1234)
        XCTAssertEqual(decoded.tagByte, 0xC7)
    }

    func test_sunMessage_wrongMACKey_failsVerification() {
        let uid = Data([0x04] + (0 ..< 6).map { UInt8($0) })
        let encKey = Data(repeating: 0x11, count: 16)
        let goodMAC = Data(repeating: 0x22, count: 16)
        let badMAC = Data(repeating: 0x99, count: 16)
        let url = NTAG424SUNMessage.makeURL(uid: uid, readCounter: 1, encKey: encKey, macKey: goodMAC)
        XCTAssertNil(NTAG424SUNMessage.decodeAndVerify(url: url, encKey: encKey, macKey: badMAC))
    }

    func test_sunMessage_truncatedCMAC_is8Bytes() {
        let key = Data(repeating: 0x00, count: 16)
        let mac = NTAG424Crypto.aesCMAC(key: key, data: Data("hex.pro".utf8))
        let truncated = NTAG424Crypto.truncateCMAC(mac)
        XCTAssertEqual(truncated.count, 8)
    }

    // MARK: - NTAG424DNASimulator full auth chain

    func test_ntag424_authenticateEV2First_completesAndDerivesSession() async throws {
        let simulator = NTAG424DNASimulator()
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")

        // Frame 1: 90 71 00 00 02 00 00 00
        let frame1 = Data([0x90, 0x71, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00])
        let response1 = try await tag.transceive(RawCommand(bytes: frame1))
        XCTAssertEqual(response1.suffix(2), Data([0x91, 0xAF]),
                       "first frame should ask for additional frame")
        let encRandB = response1.prefix(response1.count - 2)
        XCTAssertEqual(encRandB.count, 16)

        // Decrypt RndB using app master key (all zeros by default).
        let appKey = Data(repeating: 0x00, count: 16)
        let randB = NTAG424Crypto.aesCBCDecrypt(
            key: appKey, iv: Data(repeating: 0x00, count: 16), data: encRandB
        )

        // Build RndA, rotate RndB, encrypt the concatenation.
        let randA = Data((0 ..< 16).map { UInt8($0 ^ 0xAA) })
        let randBPrime = NTAG424Crypto.rotateLeftByOne(randB)
        let plain = randA + randBPrime
        let cipher = NTAG424Crypto.aesCBCEncrypt(
            key: appKey, iv: Data(repeating: 0x00, count: 16), data: plain
        )

        // Frame 2: 90 AF 00 00 20 <32 bytes> 00
        var frame2 = Data([0x90, 0xAF, 0x00, 0x00, 0x20])
        frame2.append(cipher)
        frame2.append(0x00)
        let response2 = try await tag.transceive(RawCommand(bytes: frame2))
        XCTAssertEqual(response2.suffix(2), Data([0x91, 0x00]),
                       "second frame should complete with 91 00")

        let active = try XCTUnwrap(simulator.session)
        XCTAssertEqual(active.keyNumber, 0)
        XCTAssertEqual(active.encKey.count, 16)
        XCTAssertEqual(active.macKey.count, 16)
        XCTAssertEqual(active.randA, randA)
        XCTAssertEqual(active.randB, randB)
    }

    func test_ntag424_authenticateEV2First_failsWithWrongRandBPrime() async throws {
        let simulator = NTAG424DNASimulator()
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")

        let frame1 = Data([0x90, 0x71, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00])
        _ = try await tag.transceive(RawCommand(bytes: frame1))

        // Intentionally send a malformed second frame — random ciphertext.
        let bogusCipher = Data(repeating: 0xFF, count: 32)
        var frame2 = Data([0x90, 0xAF, 0x00, 0x00, 0x20])
        frame2.append(bogusCipher)
        frame2.append(0x00)
        let response2 = try await tag.transceive(RawCommand(bytes: frame2))
        XCTAssertEqual(response2, Data([0x91, 0x9D]),
                       "wrong RndB' should yield permission-denied")
        XCTAssertNil(simulator.session, "no session should be established on failure")
    }

    func test_ntag424_getCardUID_requiresAuth() async throws {
        let simulator = NTAG424DNASimulator()
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")

        let response = try await tag.transceive(RawCommand(bytes: Data([0x90, 0x51, 0x00, 0x00, 0x00])))
        XCTAssertEqual(response, Data([0x91, 0xAE]), "no auth → auth-required")
    }

    func test_ntag424_changeKey_endToEnd_caseDifferentKey_roundTrips() async throws {
        // Drive the full AN12196-shaped wire format: derive session keys
        // via auth, then build EncCryptogram + MAC from the new key the
        // *test* picks (rather than hard-coding the AN12196 vector). This
        // exercises everything end-to-end through the live session.
        let simulator = NTAG424DNASimulator()
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")
        try await Self.completeAuth(tag: tag, simulator: simulator)
        let active = try XCTUnwrap(simulator.session)

        let keyNo: UInt8 = 1
        let newKey = Data(repeating: 0xAA, count: 16)
        let oldKey = simulator.keys[Int(keyNo)]
        let xored = NTAG424Crypto.xor(newKey, oldKey)
        let crc = NTAG424Crypto.crc32Jam(newKey)
        var plain = Data()
        plain.append(xored) // 16 bytes
        plain.append(0x01) // NewKeyVer
        plain.append(crc) // CRC32 LE = 4 bytes
        plain.append(0x80) // padding marker
        plain.append(Data(repeating: 0x00, count: 10))
        XCTAssertEqual(plain.count, 32)

        let iv = NTAG424Crypto.commandIV(
            sesAuthENCKey: active.encKey, ti: active.ti, cmdCtr: active.cmdCtr
        )
        let encKeyData = NTAG424Crypto.aesCBCEncrypt(
            key: active.encKey, iv: iv, data: plain
        )
        let mac = NTAG424Crypto.commandMAC(
            sesAuthMACKey: active.macKey,
            cmdINS: 0xC4,
            cmdCtr: active.cmdCtr,
            ti: active.ti,
            cmdHeader: Data([keyNo]),
            encCmdData: encKeyData
        )
        var apdu = Data([0x90, 0xC4, 0x00, 0x00, 0x29, keyNo])
        apdu.append(encKeyData)
        apdu.append(mac)
        apdu.append(0x00)
        let response = try await tag.transceive(RawCommand(bytes: apdu))
        XCTAssertEqual(response, Data([0x91, 0x00]))
        XCTAssertEqual(simulator.keys[Int(keyNo)], newKey)
    }

    func test_ntag424_generateSUNURL_andVerify_roundTrips() async throws {
        let simulator = NTAG424DNASimulator()
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")
        try await Self.completeAuth(tag: tag, simulator: simulator)
        let liveSession = try XCTUnwrap(simulator.session)

        let url = try simulator.generateSUNURL(readCounter: 5)
        guard let decoded = NTAG424SUNMessage.decodeAndVerify(
            url: url, encKey: liveSession.encKey, macKey: liveSession.macKey
        ) else {
            return XCTFail("SUN URL emitted by simulator failed to verify")
        }
        XCTAssertEqual(decoded.uid, simulator.uid)
        XCTAssertEqual(decoded.readCounter, 5)
    }

    func test_ntag424_writeAndReadNDEF_stillRoundTrips() async throws {
        let simulator = NTAG424DNASimulator()
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")
        try await tag.writeNDEF([.uri(URIRecord(uri: "https://hex.pro"))])
        let read = try await tag.readNDEF()
        let decoded = try NDEFCodec.decode(read)
        guard case .uri(let uri) = decoded[0] else { return XCTFail("expected uri") }
        XCTAssertEqual(uri.uri, "https://hex.pro")
    }

    func test_ntag424_getKeyVersion_returnsZeroForFactoryKey() async throws {
        let simulator = NTAG424DNASimulator()
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")
        let response = try await tag.transceive(RawCommand(bytes: Data([0x90, 0x64, 0x00, 0x00, 0x01, 0x00, 0x00])))
        XCTAssertEqual(response, Data([0x00, 0x91, 0x00]))
    }

    func test_ntag424_getFileSettings_returnsPlainCommModeByDefault() async throws {
        let simulator = NTAG424DNASimulator()
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")
        // The NDEF app must be selected before any native file command — see
        // the PICC-gate test below. Production always does this first.
        _ = try await tag.transceive(RawCommand(bytes: Data(
            [0x00, 0xA4, 0x04, 0x00, 0x07, 0xD2, 0x76, 0x00, 0x00, 0x85, 0x01, 0x01, 0x00]
        )))
        let response = try await tag.transceive(RawCommand(bytes: Data([0x90, 0xF5, 0x00, 0x00, 0x01, 0x02, 0x00])))
        XCTAssertEqual(response.suffix(2), Data([0x91, 0x00]))
        // Byte 1 of the response is the commMode|sun byte; plain = 0x00.
        XCTAssertEqual(response[response.startIndex + 1], 0x00)
    }

    /// Native **file** commands are refused at PICC level with `91 9D` until
    /// the NDEF application has been ISO-SELECTed — live-observed 2026-07-01,
    /// when the harness's `t4.fileSettings` step passed in CI and failed on
    /// silicon for exactly this reason.
    ///
    /// The harness was fixed at the time; the simulator was not, so it went on
    /// answering these in any state. That left a one-line reordering in
    /// `NTAG424ProtectionDriver` able to ship green while making
    /// `readProtectionState` throw on real tags — and its `try?` callers turn a
    /// throw into "unprotected", the same misreading the SLIX2 `0F` bug caused.
    func test_ntag424_nativeFileCommands_areRefusedBeforeSelectingTheApp() async throws {
        let simulator = NTAG424DNASimulator()
        let tag = try await SimulatedSession(chip: simulator).start(alert: "")
        for (ins, name) in [(UInt8(0xF5), "GetFileSettings"), (0x5F, "ChangeFileSettings"),
                            (0xAD, "ReadData"), (0x8D, "WriteData")]
        {
            let response = try await tag.transceive(
                RawCommand(bytes: Data([0x90, ins, 0x00, 0x00, 0x01, 0x02, 0x00]))
            )
            XCTAssertEqual(
                Data(response.suffix(2)), Data([0x91, 0x9D]),
                "\(name) must answer PERMISSION_DENIED before the NDEF app is selected"
            )
        }
        // After selecting, the same command is served.
        _ = try await tag.transceive(RawCommand(bytes: Data(
            [0x00, 0xA4, 0x04, 0x00, 0x07, 0xD2, 0x76, 0x00, 0x00, 0x85, 0x01, 0x01, 0x00]
        )))
        let afterSelect = try await tag.transceive(
            RawCommand(bytes: Data([0x90, 0xF5, 0x00, 0x00, 0x01, 0x02, 0x00]))
        )
        XCTAssertEqual(Data(afterSelect.suffix(2)), Data([0x91, 0x00]))
    }

    func test_ntag424_changeFileSettings_persistsAndIsReadable() async throws {
        let simulator = NTAG424DNASimulator()
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")
        try await Self.completeAuth(tag: tag, simulator: simulator)

        // Set NDEF file to commMode=Full (0x03), SUN enabled (bit 0x40), AR=0xEEEE,
        // via the full secure-messaging form the chip now requires.
        let s = try XCTUnwrap(simulator.session)
        let change = Self.fullChangeFileSettings(fileNo: 0x02, fileOption: 0x43, accessRights: 0xEEEE, session: s)
        _ = try await tag.transceive(RawCommand(bytes: change))
        // Read it back the way production does, from outside the session. A
        // plain GetFileSettings is refused (`91 7E`) while an EV2 session is
        // live, which is why `NTAG424ProtectionDriver` ends the session before
        // every read-back rather than asking in-session.
        simulator.endSession()
        let read = try await tag.transceive(RawCommand(bytes: Data([0x90, 0xF5, 0x00, 0x00, 0x01, 0x02, 0x00])))
        XCTAssertEqual(read[read.startIndex + 1] & 0x03, 0x03, "commMode should be Full")
        XCTAssertEqual(read[read.startIndex + 1] & 0x40, 0x40, "SUN bit should be set")
    }

    func test_ntag424_getVersion_returnsHardwareAndSoftwareInfo() async throws {
        let simulator = NTAG424DNASimulator()
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")
        let response = try await tag.transceive(RawCommand(bytes: Data([0x90, 0x60, 0x00, 0x00, 0x00])))
        XCTAssertEqual(response.suffix(2), Data([0x91, 0x00]))
        // Total payload should be 28 bytes (7 HW + 7 SW + 14 UID/batch/date).
        XCTAssertEqual(response.count - 2, 28)
    }

    func test_ntag424_unknownDESFireINS_returnsDESFireError() async throws {
        let simulator = NTAG424DNASimulator()
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")
        let response = try await tag.transceive(RawCommand(bytes: Data([0x90, 0xEF, 0x00, 0x00, 0x00])))
        XCTAssertEqual(response, Data([0x91, 0x1C]))
    }

    func test_ntag424_unknownCLA_returnsISOError() async throws {
        let simulator = NTAG424DNASimulator()
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")
        let response = try await tag.transceive(RawCommand(bytes: Data([0x80, 0x01, 0x00, 0x00, 0x00])))
        XCTAssertEqual(response, Data([0x6F, 0x00]))
    }

    func test_ntag424_authenticateEV2First_invalidKeySlot_rejected() async throws {
        let simulator = NTAG424DNASimulator()
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")
        // KeyNo = 0x07 — out of range (only 5 slots).
        let frame1 = Data([0x90, 0x71, 0x00, 0x00, 0x02, 0x07, 0x00, 0x00])
        let response = try await tag.transceive(RawCommand(bytes: frame1))
        XCTAssertEqual(response, Data([0x91, 0x9D]))
    }

    // MARK: - AN12196 secure-messaging primitives

    func test_crc32Jam_matchesAN12196_changeKeyExample() {
        // AN12196 Table 26: NewKey F3847D627727ED3BC9C4CC050489B966 → CRC32 (LE) 789DFADC.
        let newKey = Data([
            0xF3, 0x84, 0x7D, 0x62, 0x77, 0x27, 0xED, 0x3B,
            0xC9, 0xC4, 0xCC, 0x05, 0x04, 0x89, 0xB9, 0x66,
        ])
        let crc = NTAG424Crypto.crc32Jam(newKey)
        XCTAssertEqual(crc, Data([0x78, 0x9D, 0xFA, 0xDC]))
    }

    func test_commandIV_matchesAN12196_changeKeyTable26() {
        // KSesAuthENC + TI + CmdCtr → IVc per §5.4.
        let sesEnc = Data([
            0x4C, 0xF3, 0xCB, 0x41, 0xA2, 0x25, 0x83, 0xA6,
            0x1E, 0x89, 0xB1, 0x58, 0xD2, 0x52, 0xFC, 0x53,
        ])
        let ti = Data([0x76, 0x14, 0x28, 0x1A])
        let iv = NTAG424Crypto.commandIV(sesAuthENCKey: sesEnc, ti: ti, cmdCtr: 2)
        XCTAssertEqual(iv, Data([
            0x30, 0x7E, 0xDE, 0x18, 0x14, 0x70, 0x7F, 0x30,
            0xCF, 0xE6, 0x03, 0xDD, 0x6C, 0xA6, 0x23, 0x53,
        ]))
    }

    func test_iso9797Pad_appendsFullBlockWhenAlreadyBlockAligned() {
        let exactly16 = Data(repeating: 0xAB, count: 16)
        let padded = NTAG424Crypto.iso9797Pad(exactly16)
        XCTAssertEqual(padded.count, 32)
        XCTAssertEqual(padded[16], 0x80)
        XCTAssertEqual(padded.suffix(15), Data(repeating: 0x00, count: 15))
    }

    func test_iso9797Pad_shortInputPadsToOneBlock() {
        let padded = NTAG424Crypto.iso9797Pad(Data([0x01, 0x02, 0x03]))
        XCTAssertEqual(padded.count, 16)
        XCTAssertEqual(padded[3], 0x80)
        XCTAssertEqual(padded.suffix(12), Data(repeating: 0x00, count: 12))
    }

    // MARK: - AN12196 ChangeKey Table 26 (KeyNo ≠ AuthKey)

    func test_changeKey_table26_caseDifferentKey_acceptsAndInstallsNewKey() async throws {
        let simulator = NTAG424DNASimulator()
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")

        // Inject the AN12196 worked-example session state.
        let sesEnc = Data([
            0x4C, 0xF3, 0xCB, 0x41, 0xA2, 0x25, 0x83, 0xA6,
            0x1E, 0x89, 0xB1, 0x58, 0xD2, 0x52, 0xFC, 0x53,
        ])
        let sesMac = Data([
            0x55, 0x29, 0x86, 0x0B, 0x2F, 0xC5, 0xFB, 0x61,
            0x54, 0xB7, 0xF2, 0x83, 0x61, 0xD3, 0x0B, 0xF9,
        ])
        let ti = Data([0x76, 0x14, 0x28, 0x1A])
        simulator.injectTestSession(
            keyNumber: 0, encKey: sesEnc, macKey: sesMac, ti: ti, cmdCtr: 2
        )

        // Build the worked-example C-APDU verbatim.
        let encKeyData = Data([
            0x2C, 0xF3, 0x62, 0xB7, 0xBF, 0x43, 0x11, 0xFF,
            0x3B, 0xE1, 0xDA, 0xA2, 0x95, 0xE8, 0xC6, 0x8D,
            0xE0, 0x90, 0x50, 0x56, 0x0D, 0x19, 0xB9, 0xE1,
            0x6C, 0x23, 0x93, 0xAE, 0x9C, 0xD1, 0xFA, 0xC7,
        ])
        let macT = Data([
            0x5D, 0x0C, 0xE2, 0x0B, 0xCD, 0x1D, 0x06, 0xE6,
        ])
        var apdu = Data([0x90, 0xC4, 0x00, 0x00, 0x29, 0x02])
        apdu.append(encKeyData)
        apdu.append(macT)
        apdu.append(0x00)

        let response = try await tag.transceive(RawCommand(bytes: apdu))
        XCTAssertEqual(response, Data([0x91, 0x00]))
        // Verify the new key landed in slot 2.
        XCTAssertEqual(simulator.keys[2], Data([
            0xF3, 0x84, 0x7D, 0x62, 0x77, 0x27, 0xED, 0x3B,
            0xC9, 0xC4, 0xCC, 0x05, 0x04, 0x89, 0xB9, 0x66,
        ]))
        // CmdCtr advanced.
        XCTAssertEqual(simulator.session?.cmdCtr, 3)
    }

    func test_changeKey_withInvalidMAC_isRejected_andKeyIsUntouched() async throws {
        let simulator = NTAG424DNASimulator()
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")

        // Reuse the Table 26 setup but corrupt the MAC.
        let sesEnc = Data(repeating: 0x4C, count: 16)
        let sesMac = Data(repeating: 0x55, count: 16)
        simulator.injectTestSession(
            keyNumber: 0, encKey: sesEnc, macKey: sesMac,
            ti: Data([0x00, 0x00, 0x00, 0x00]), cmdCtr: 2
        )
        let originalKey = simulator.keys[2]
        var apdu = Data([0x90, 0xC4, 0x00, 0x00, 0x29, 0x02])
        apdu.append(Data(repeating: 0x00, count: 32)) // encKeyData garbage
        apdu.append(Data(repeating: 0xFF, count: 8)) // wrong MAC
        apdu.append(0x00)

        let response = try await tag.transceive(RawCommand(bytes: apdu))
        XCTAssertEqual(response, Data([0x91, 0x1C]))
        XCTAssertEqual(simulator.keys[2], originalKey, "key slot must not change on MAC failure")
        XCTAssertEqual(simulator.session?.cmdCtr, 2, "CmdCtr must not advance on MAC failure")
    }

    // MARK: - Full-mode WriteData + ReadData round-trip

    //
    // The plan calls for "ReadData in Full mode returns decrypted
    // plaintext". With the AN12196 wire format wired up, a written-then-
    // read round-trip through CommMode.full should recover the original
    // bytes — without ever sending plaintext over the wire.

    func test_full_mode_writeData_thenReadData_recoversPlaintext() async throws {
        let simulator = NTAG424DNASimulator()
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")
        try await NTAG424CryptoTests.completeAuth(tag: tag, simulator: simulator)

        // Promote the NDEF file to CommMode.full so subsequent ReadData /
        // WriteData on file 0x02 use the wrapped form. ChangeFileSettings now
        // requires the full secure-messaging form and advances CmdCtr, so we
        // re-read the live session afterward for the subsequent commands.
        let preChange = try XCTUnwrap(simulator.session)
        let change = Self.fullChangeFileSettings(
            fileNo: 0x02,
            fileOption: 0x03,
            accessRights: 0xEEEE,
            session: preChange
        )
        _ = try await tag.transceive(RawCommand(bytes: change))
        let activeSession = try XCTUnwrap(simulator.session)

        // Build a WriteData (full) request for a known 5-byte payload.
        let plaintext = Data([0xCA, 0xFE, 0xBA, 0xBE, 0x99])
        let writeCmdHeader = Data([
            0x02, // file 02 (NDEF)
            0x00, 0x00, 0x00, // offset 0
            UInt8(plaintext.count), 0x00, 0x00, // length 3-byte LE
        ])
        let padded = NTAG424Crypto.iso9797Pad(plaintext)
        let ivWrite = NTAG424Crypto.commandIV(
            sesAuthENCKey: activeSession.encKey,
            ti: activeSession.ti,
            cmdCtr: activeSession.cmdCtr
        )
        let encWriteData = NTAG424Crypto.aesCBCEncrypt(
            key: activeSession.encKey, iv: ivWrite, data: padded
        )
        let writeMAC = NTAG424Crypto.commandMAC(
            sesAuthMACKey: activeSession.macKey,
            cmdINS: 0x8D,
            cmdCtr: activeSession.cmdCtr,
            ti: activeSession.ti,
            cmdHeader: writeCmdHeader,
            encCmdData: encWriteData
        )
        var writeAPDU = Data([0x90, 0x8D, 0x00, 0x00])
        writeAPDU.append(UInt8(writeCmdHeader.count + encWriteData.count + writeMAC.count))
        writeAPDU.append(writeCmdHeader)
        writeAPDU.append(encWriteData)
        writeAPDU.append(writeMAC)
        writeAPDU.append(0x00)

        let writeResponse = try await tag.transceive(RawCommand(bytes: writeAPDU))
        XCTAssertEqual(writeResponse.suffix(2), Data([0x91, 0x00]))
        let writeRespMAC = writeResponse.prefix(8)
        XCTAssertEqual(writeRespMAC.count, 8)

        // CmdCtr is now 1 (assuming auth + ChangeFileSettings used 0 each;
        // ChangeFileSettings doesn't increment in our impl, so writes
        // started at 0 and we just advanced to 1).
        let advancedSession = try XCTUnwrap(simulator.session)
        let nextCmdCtr = advancedSession.cmdCtr

        // Build the matching ReadData (full) request.
        let readCmdHeader = Data([
            0x02,
            0x00, 0x00, 0x00,
            UInt8(plaintext.count), 0x00, 0x00,
        ])
        let readMAC = NTAG424Crypto.commandMAC(
            sesAuthMACKey: advancedSession.macKey,
            cmdINS: 0xAD,
            cmdCtr: nextCmdCtr,
            ti: advancedSession.ti,
            cmdHeader: readCmdHeader,
            encCmdData: Data()
        )
        var readAPDU = Data([0x90, 0xAD, 0x00, 0x00, 0x0F])
        readAPDU.append(readCmdHeader)
        readAPDU.append(readMAC)
        readAPDU.append(0x00)
        let readResponse = try await tag.transceive(RawCommand(bytes: readAPDU))
        XCTAssertEqual(readResponse.suffix(2), Data([0x91, 0x00]))

        // Strip the SW, the trailing MAC, and decrypt under IVr.
        let body = readResponse.prefix(readResponse.count - 2 - 8)
        XCTAssertTrue(!body.isEmpty && body.count % 16 == 0)
        let ivRead = NTAG424Crypto.responseIV(
            sesAuthENCKey: advancedSession.encKey,
            ti: advancedSession.ti,
            cmdCtr: nextCmdCtr
        )
        let decryptedPadded = NTAG424Crypto.aesCBCDecrypt(
            key: advancedSession.encKey, iv: ivRead, data: Data(body)
        )
        let recovered = NTAG424Crypto.stripIso9797(decryptedPadded, plaintextLength: plaintext.count)
        XCTAssertEqual(recovered, plaintext)
    }

    // MARK: - Helpers

    /// Build a full secure-messaging ChangeFileSettings APDU (`0x5F`) from a live
    /// session — `CmdData = FileOption(1) || AccessRights(2)` with the AccessRights
    /// bytes (ReadWrite|Change) then (Read|Write) (big-endian), ISO-9797 padded,
    /// AES-CBC encrypted under IVc, with a command MAC. Matches what the chip now
    /// requires (plain ChangeFileSettings is no longer accepted).
    static func fullChangeFileSettings(
        fileNo: UInt8,
        fileOption: UInt8,
        accessRights: UInt16,
        session: NTAG424DNASimulator.SessionState
    ) -> Data {
        let plain = Data([fileOption, UInt8((accessRights >> 8) & 0xFF), UInt8(accessRights & 0xFF)])
        let padded = NTAG424Crypto.iso9797Pad(plain)
        let iv = NTAG424Crypto.commandIV(sesAuthENCKey: session.encKey, ti: session.ti, cmdCtr: session.cmdCtr)
        let enc = NTAG424Crypto.aesCBCEncrypt(key: session.encKey, iv: iv, data: padded)
        let mac = NTAG424Crypto.commandMAC(
            sesAuthMACKey: session.macKey, cmdINS: 0x5F, cmdCtr: session.cmdCtr,
            ti: session.ti, cmdHeader: Data([fileNo]), encCmdData: enc
        )
        let data = Data([fileNo]) + enc + mac
        var apdu = Data([0x90, 0x5F, 0x00, 0x00, UInt8(data.count)])
        apdu.append(data)
        apdu.append(0x00)
        return apdu
    }

    static func completeAuth(
        tag: ConnectedTag,
        simulator: NTAG424DNASimulator,
        appKey: Data = Data(repeating: 0x00, count: 16)
    ) async throws {
        // Select the NDEF application first, exactly as production does
        // (`NTAG424ProtectionDriver.selectNDEFApp` precedes every authenticate).
        // Real silicon refuses native *file* commands with `91 9D` until this
        // has run — live-observed 2026-07-01 — and the simulator now models
        // that, so a test that skips it is no longer testing a reachable state.
        _ = try await tag.transceive(RawCommand(bytes: Data(
            [0x00, 0xA4, 0x04, 0x00, 0x07, 0xD2, 0x76, 0x00, 0x00, 0x85, 0x01, 0x01, 0x00]
        )))
        let frame1 = Data([0x90, 0x71, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00])
        let response1 = try await tag.transceive(RawCommand(bytes: frame1))
        let encRandB = response1.prefix(response1.count - 2)
        let randB = NTAG424Crypto.aesCBCDecrypt(
            key: appKey, iv: Data(repeating: 0x00, count: 16), data: encRandB
        )
        let randA = Data((0 ..< 16).map { UInt8($0 ^ 0xAA) })
        let randBPrime = NTAG424Crypto.rotateLeftByOne(randB)
        let cipher = NTAG424Crypto.aesCBCEncrypt(
            key: appKey,
            iv: Data(repeating: 0x00, count: 16),
            data: randA + randBPrime
        )
        var frame2 = Data([0x90, 0xAF, 0x00, 0x00, 0x20])
        frame2.append(cipher)
        frame2.append(0x00)
        _ = try await tag.transceive(RawCommand(bytes: frame2))
    }
}
