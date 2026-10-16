@testable import HexNFCKit
@testable import HexNFCRecords
import XCTest

/// The MIFARE Ultralight C key byte order and 3DES handshake, pinned against
/// **the datasheet's own numerical example** (NXP MF0ICU2 rev 3.3 §7.5.6
/// Table 9) rather than a vector of our own construction.
///
/// That distinction matters. A self-made vector only proves our encrypt and our
/// decrypt agree with each other, which they would even if the whole scheme
/// were backwards. The datasheet vector pins every value an outside party can
/// observe: the cipher direction, the IV chaining, the rotate, and which of the
/// two key byte orders feeds the cipher.
final class UltralightCCryptoTests: XCTestCase {
    // MARK: - Datasheet vector (rev 3.3 §7.5.6, Table 9)

    private let vectorKeyCipherOrder = Data([
        0x49, 0x45, 0x4D, 0x4B, 0x41, 0x45, 0x52, 0x42,
        0x21, 0x4E, 0x41, 0x43, 0x55, 0x4F, 0x59, 0x46,
    ])
    private let rndB = Data([0x51, 0xE7, 0x64, 0x60, 0x26, 0x78, 0xDF, 0x2B])
    private let ekRndB = Data([0x57, 0x72, 0x93, 0xFD, 0x2F, 0x34, 0xCA, 0x51])
    private let rndA = Data([0xA8, 0xAF, 0x3B, 0x25, 0x6C, 0x75, 0xED, 0x40])
    private let token = Data([
        0x0A, 0x63, 0x85, 0x59, 0xFC, 0x77, 0x37, 0xF9,
        0xF1, 0x5D, 0x78, 0x62, 0xEB, 0xBE, 0x96, 0x7A,
    ])
    private let ekRndAPrime = Data([0x3B, 0x88, 0x4F, 0xA0, 0x7C, 0x13, 0x7C, 0xE1])

    // MARK: - Key byte order

    /// The single most dangerous value on this chip. Writing the key in the
    /// wrong order with a lowered AUTH0 locks a tag out permanently.
    func test_factoryKey_memoryOrderIsAscii_cipherOrderIsHalfReversed() {
        let key = UltralightCKey.factoryDefault

        XCTAssertEqual(
            String(data: key.memoryOrder, encoding: .ascii), "BREAKMEIFYOUCAN!",
            "pages 2Ch–2Fh hold the key in readable ASCII order (rev 3.3 Table 13)"
        )
        XCTAssertEqual(
            key.cipherOrder, vectorKeyCipherOrder,
            "the cipher takes each 8-byte half reversed — this is the value in §7.5.6"
        )
        XCTAssertEqual(
            String(data: key.cipherOrder, encoding: .ascii), "IEMKAERB!NACUOYF"
        )
    }

    /// The transform is an involution, which is why one function converts both
    /// ways. If this ever fails, the two initialisers disagree and one of them
    /// is silently corrupting keys.
    func test_halfSwap_isAnInvolution() {
        let arbitrary = Data((0 ..< 16).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) })
        let once = UltralightCKey.swappingHalves(arbitrary)
        XCTAssertNotEqual(once, arbitrary, "precondition: the transform actually moves bytes")
        XCTAssertEqual(UltralightCKey.swappingHalves(once), arbitrary)
    }

    /// Constructing from either order must describe the same key.
    func test_bothInitialisers_agree() throws {
        let key = UltralightCKey.factoryDefault
        XCTAssertEqual(try UltralightCKey(cipherOrder: key.cipherOrder), key)
        XCTAssertEqual(try UltralightCKey(memoryOrder: key.memoryOrder), key)
    }

    /// Datasheet Table 11: `Key1 = 0001020304050607h`, `Key2 = 08090A0B0C0D0E0Fh`
    /// is programmed with `A2 2C 07 06 05 04` / `A2 2D 03 02 01 00` /
    /// `A2 2E 0F 0E 0D 0C` / `A2 2F 0B 0A 09 08`.
    ///
    /// This is the worked example that **contradicts Table 10** in the same
    /// section. Table 10 labels page 2Ch byte 0 as "Key1 / K0"; the example
    /// puts K7 there. We follow the example, so this test is the guard on that
    /// decision.
    func test_datasheetTable11_keyProgrammingExample() throws {
        let key = try UltralightCKey(cipherOrder: Data((0 ..< 16).map { UInt8($0) }))
        XCTAssertEqual(
            [UInt8](key.memoryOrder),
            [0x07, 0x06, 0x05, 0x04,
             0x03, 0x02, 0x01, 0x00,
             0x0F, 0x0E, 0x0D, 0x0C,
             0x0B, 0x0A, 0x09, 0x08]
        )
    }

    func test_wrongLengthKey_isRejected() {
        XCTAssertThrowsError(try UltralightCKey(cipherOrder: Data(repeating: 0, count: 8)))
        XCTAssertThrowsError(try UltralightCKey(cipherOrder: Data()))
    }

    /// A key must never print its bytes: it flows through error paths and trace
    /// notes that end up in bug reports.
    func test_keyDescription_neverLeaksBytes() throws {
        let secret = try UltralightCKey(cipherOrder: Data(repeating: 0xAB, count: 16))
        XCTAssertFalse("\(secret)".lowercased().contains("ab"))
        XCTAssertTrue("\(secret)".contains("redacted"))
    }

    // MARK: - Cipher direction

    /// `ek()` is genuine **encrypt**. Ultralight C does not use the DESFire
    /// legacy convention where the reader deciphers to send, and having that
    /// backwards makes every authentication fail with no useful diagnostic.
    func test_ek_isEncryptNotDecrypt() throws {
        let zeroIV = Data(repeating: 0, count: 8)
        XCTAssertEqual(
            try EMRTDCrypto.tripleDESCBCEncrypt(key: vectorKeyCipherOrder, iv: zeroIV, data: rndB),
            ekRndB
        )
        XCTAssertEqual(
            try EMRTDCrypto.tripleDESCBCDecrypt(key: vectorKeyCipherOrder, iv: zeroIV, data: ekRndB),
            rndB
        )
    }

    /// IV chains from the previous ciphertext block (ISO/IEC 10116), not from
    /// zero each time.
    func test_tokenEncryption_chainsIVFromTheChallenge() throws {
        let rndBPrime = NTAG424Crypto.rotateLeftByOne(rndB)
        XCTAssertEqual(rndBPrime, Data([0xE7, 0x64, 0x60, 0x26, 0x78, 0xDF, 0x2B, 0x51]))
        XCTAssertEqual(
            try EMRTDCrypto.tripleDESCBCEncrypt(
                key: vectorKeyCipherOrder, iv: ekRndB, data: rndA + rndBPrime
            ),
            token
        )
    }

    // MARK: - Full handshake through the driver

    /// Replay the datasheet exchange through the real driver, with `RndA`
    /// pinned to the datasheet's value. Asserts the exact bytes the driver puts
    /// on the wire, so a change to framing or IV handling fails here rather
    /// than on a tag.
    func test_authenticate_reproducesTheDatasheetExchange() async throws {
        let sent = Recorder()
        let driver = UltralightCProtectionDriver(
            transceive: { [ekRndB, ekRndAPrime] command in
                await sent.record(command.bytes)
                if command.bytes.first == 0x1A {
                    return Data([0xAF]) + ekRndB
                }
                return Data([0x00]) + ekRndAPrime
            },
            makeRandom: { [rndA] _ in rndA }
        )

        let key = try UltralightCKey(cipherOrder: vectorKeyCipherOrder)
        let returned = try await driver.authenticate(key: key)

        XCTAssertEqual(returned, rndA, "authenticate returns RndA as session material")
        let frames = await sent.frames
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0], Data([0x1A, 0x00]))
        XCTAssertEqual(frames[1], Data([0xAF]) + token, "leg 2 must be AF ‖ ek(RndA‖RndB′)")
    }

    /// The card's half of the "mutual" must actually be checked. A card that
    /// answers with a well-formed but wrong cryptogram holds a different key,
    /// and accepting it means trusting an unauthenticated tag.
    func test_authenticate_rejectsAWrongFinalCryptogram() async throws {
        let driver = UltralightCProtectionDriver(
            transceive: { [ekRndB] command in
                if command.bytes.first == 0x1A {
                    return Data([0xAF]) + ekRndB
                }
                // Well-formed, right length, right status byte, wrong content.
                return Data([0x00]) + Data(repeating: 0x5A, count: 8)
            },
            makeRandom: { [rndA] _ in rndA }
        )
        await assertAuthFails(
            try await driver.authenticate(key: UltralightCKey(cipherOrder: vectorKeyCipherOrder))
        )
    }

    /// A chip with no 3DES authentication NAKs `1A 00`. That is how we tell an
    /// Ultralight C from every other Type-2 chip, so the failure must be clean.
    func test_authenticate_reportsANakAsNotAnUltralightC() async throws {
        let driver = UltralightCProtectionDriver(
            transceive: { _ in Data([0x00]) },
            makeRandom: { count in Data(repeating: 0, count: count) }
        )
        await assertAuthFails(
            try await driver.authenticate(key: .factoryDefault)
        )
    }

    private func assertAuthFails(
        _ expression: @autoclosure () async throws -> Data,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("expected authentication to fail", file: file, line: line)
        } catch let error as TagError {
            guard case .authFailed = error.kind else {
                return XCTFail("expected .authFailed, got \(error.kind)", file: file, line: line)
            }
        } catch {
            XCTFail("expected TagError, got \(error)", file: file, line: line)
        }
    }

    // MARK: - AUTH1 polarity

    /// AUTH1 is **inverted** relative to the NTAG21x `PROT` bit: bit 0 set means
    /// write-only, clear means read+write restricted (rev 3.3 Table 12). A blind
    /// port of the Type-2 code applies the opposite protection level to the one
    /// the user asked for.
    func test_auth1_polarityIsInvertedVersusNTAG21xPROT() {
        XCTAssertEqual(UltralightCConfiguration.auth1(readProtect: false), 0x01,
                       "write-only is bit 0 SET")
        XCTAssertEqual(UltralightCConfiguration.auth1(readProtect: true), 0x00,
                       "read+write restricted is bit 0 CLEAR")

        let writeOnly = UltralightCConfiguration(auth0: 0x10, auth1: 0x01)
        XCTAssertTrue(writeOnly.isProtected)
        XCTAssertFalse(writeOnly.readProtect)

        let readWrite = UltralightCConfiguration(auth0: 0x10, auth1: 0x00)
        XCTAssertTrue(readWrite.isProtected)
        XCTAssertTrue(readWrite.readProtect)
    }

    /// The delivery state (`AUTH0 = 30h`) means nothing is protected, and AUTH1
    /// is then irrelevant — a factory tag reads `AUTH1 = 00h`, which in isolation
    /// would decode as "read+write restricted".
    func test_factoryConfiguration_reportsUnprotected() {
        let factory = UltralightCConfiguration(auth0: 0x30, auth1: 0x00)
        XCTAssertFalse(factory.isProtected)
        XCTAssertFalse(factory.readProtect, "AUTH1 must not be read as protection when AUTH0 is off")
        XCTAssertNil(factory.protectFromPage)
        XCTAssertEqual(factory.protection.passwordProtect, false)
    }

    /// An out-of-range AUTH0 above 0x30 still means "off".
    func test_auth0AboveRange_isTreatedAsUnprotected() {
        XCTAssertFalse(UltralightCConfiguration(auth0: 0xFF, auth1: 0x00).isProtected)
    }

    /// AUTH0 bounds are enforced before anything is written, so a caller cannot
    /// arm protection over the key pages themselves or write a value the chip
    /// would reject halfway through the sequence.
    func test_enable_rejectsAnOutOfRangeProtectFromPage() async {
        let driver = UltralightCProtectionDriver(
            transceive: { _ in XCTFail("must not transceive on a rejected request")
                return Data()
            },
            makeRandom: { count in Data(repeating: 0, count: count) }
        )
        for page in [0, 2, 0x30, 0x40] {
            do {
                try await driver.enable(key: .factoryDefault, protectFromPage: page,
                                        readProtect: false, currentKey: .factoryDefault)
                XCTFail("page \(page) should be rejected")
            } catch {
                // expected
            }
        }
    }
}

/// Collects the frames a driver puts on the wire.
private actor Recorder {
    private(set) var frames: [Data] = []
    func record(_ frame: Data) {
        frames.append(frame)
    }
}
