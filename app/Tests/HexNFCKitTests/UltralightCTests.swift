@testable import HexNFCKit
@testable import HexNFCRecords
@testable import HexNFCTagSim
import HexNFCTestKit
import XCTest

/// MIFARE Ultralight C (MF0ICU2): profile shape, factory state, the commands it
/// does *not* have, and the 3DES protection lifecycle driven end to end through
/// the production driver against the simulator.
///
/// Modelled on `NTAG210MicroTests`. The absent capabilities carry their
/// datasheet reasons inline, because on this chip "we didn't implement it" and
/// "the silicon does not have it" produce identical-looking code and only the
/// second one is correct.
final class UltralightCTests: XCTestCase {
    private var profile: ChipProfile {
        get throws { try XCTUnwrap(ChipCatalog.profile(for: .mifareUltralightC)) }
    }

    private func makeDriver(_ sim: MifareUltralightCSimulator) -> UltralightCProtectionDriver {
        UltralightCProtectionDriver(transceive: { command in sim.handle(command: command.bytes) })
    }

    // MARK: - Profile

    func test_profile_shape() throws {
        let p = try profile
        XCTAssertEqual(p.family, .type2(.mifareUltralightC))
        XCTAssertEqual(p.displayName, "MIFARE Ultralight C")
        XCTAssertEqual(p.memoryLayout.pageCount, 48)
        XCTAssertEqual(p.memoryLayout.byteCount, 192)
        XCTAssertEqual(p.ndefByteCapacity, 144)
        XCTAssertEqual(p.memoryLayout.ndefRange, 4 ... 39)
        XCTAssertEqual(p.memoryLayout.ccPage, 3)
    }

    /// Each absent capability is a datasheet fact (rev 3.3 Table 14 is an
    /// exhaustive command list), not an unimplemented feature.
    func test_profile_absentCapabilities() throws {
        let c = try profile.capabilities
        XCTAssertFalse(c.contains(.passwordAuth), "no PWD_AUTH (1Bh) — it uses 3DES instead")
        XCTAssertFalse(c.contains(.fastRead), "no FAST_READ (3Ah)")
        XCTAssertFalse(c.contains(.signatureRead), "no READ_SIG (3Ch)")
        XCTAssertFalse(c.contains(.counterRead), "no READ_CNT (39h); the counter is page 29h")
        XCTAssertTrue(c.contains(.tripleDESAuth))
        XCTAssertTrue(c.contains(.formatCC), "page 3 ships blank, so format is real work here")
        XCTAssertTrue(c.contains(.permanentLock))
    }

    /// `Type2ConfigLayout` must refuse this chip. Returning a layout would route
    /// it to the NTAG21x PWD/PACK backend via `ProtectionStyle.backendStyle`,
    /// which cannot drive a 3DES handshake.
    func test_type2ConfigLayout_refusesUltralightC() throws {
        XCTAssertNil(Type2ConfigLayout.for(.mifareUltralightC))
        XCTAssertNil(try profile.type2ConfigLayout)
    }

    /// The two sources of page numbers must agree, the same guard
    /// `TagProtectionTests` applies to the Type-2 family. A disagreement here
    /// means a write lands on the wrong page, which bricks real tags.
    func test_layoutConstants_agreeWithChipCatalog() throws {
        let layout = try profile.memoryLayout
        XCTAssertEqual(layout.configPages, [UltralightCLayout.auth0Page, UltralightCLayout.auth1Page])
        XCTAssertEqual(UltralightCLayout.auth0Page, 42)
        XCTAssertEqual(UltralightCLayout.auth1Page, 43)
        XCTAssertEqual(UltralightCLayout.keyPages, 44 ... 47)
        XCTAssertEqual(UltralightCLayout.keyPages.upperBound, layout.pageCount - 1,
                       "the key occupies the last four pages")
        XCTAssertEqual(layout.dynamicLockPage, 40)
        XCTAssertEqual(layout.lockPages, [2])
        XCTAssertNil(layout.pwdPage)
        XCTAssertNil(layout.packPage)
    }

    /// 144 B declared, matching the usable area exactly.
    func test_factoryCC() throws {
        XCTAssertEqual(try profile.factoryCC, Data([0xE1, 0x10, 0x12, 0x00]))
        XCTAssertEqual(try Int(XCTUnwrap(try profile.factoryCC)[2]) * 8, try profile.ndefByteCapacity)
    }

    // MARK: - Delivery state (rev 3.3 Table 13)

    func test_deliveryState_matchesTable13() {
        let sim = MifareUltralightCSimulator()

        XCTAssertEqual(sim.pages[3], Data([0x00, 0x00, 0x00, 0x00]),
                       "page 3 (OTP/CC) ships blank — unlike NTAG21x")
        XCTAssertEqual(sim.pages[40], Data([0x00, 0x00, 0x00, 0x00]), "lock bytes 2–3 clear")
        XCTAssertEqual(sim.pages[41], Data([0x00, 0x00, 0x00, 0x00]), "counter at zero")
        XCTAssertEqual(sim.pages[42].first, 0x30, "AUTH0 = 30h, protection off")
        XCTAssertEqual(sim.pages[43].first, 0x00, "AUTH1 = 00h")
        XCTAssertEqual(sim.pages[2][sim.pages[2].startIndex + 1], 0x48, "internal byte")
        XCTAssertFalse(sim.configuration.isProtected)
    }

    /// §7.5.3 claims byte 3 of page 28h "is always BDh when read". Table 13
    /// calls it rfu, our live tags read 00, and the section's opening sentence
    /// refers to the MF0UL21, so the paragraph is inherited from the Ultralight
    /// EV1 datasheet. We deliberately do not model BDh.
    func test_page28ByteThree_isZeroNotBD_datasheetErratum() {
        let sim = MifareUltralightCSimulator()
        XCTAssertEqual(sim.pages[40][sim.pages[40].startIndex + 3], 0x00)
    }

    /// A virgin tag is not NDEF-formatted, so the reader path must refuse it
    /// exactly as CoreNFC's `queryNDEFStatus` does.
    func test_virginTag_hasNoReadableNDEF() {
        let sim = MifareUltralightCSimulator()
        XCTAssertThrowsError(try sim.readNDEF())
    }

    // MARK: - Commands this silicon does not have

    /// The defining property of this chip. `GET_VERSION` NAKing is why a stack
    /// of these sat unidentified, and a simulator that answered it would hide
    /// the very behaviour the identification path has to cope with.
    func test_absentCommands_allNAK() {
        let sim = MifareUltralightCSimulator()
        let nak = Data([0x00])
        XCTAssertEqual(sim.handle(command: Data([0x60])), nak, "GET_VERSION")
        XCTAssertEqual(sim.handle(command: Data([0x3A, 0x03, 0x04])), nak, "FAST_READ")
        XCTAssertEqual(sim.handle(command: Data([0x3C, 0x00])), nak, "READ_SIG")
        XCTAssertEqual(sim.handle(command: Data([0x39, 0x00])), nak, "READ_CNT")
        XCTAssertEqual(sim.handle(command: Data([0x1B, 0, 0, 0, 0])), nak, "PWD_AUTH")
        XCTAssertEqual(sim.handle(command: Data([0x3E, 0x00])), nak, "CHECK_TEARING_EVENT")
        XCTAssertEqual(sim.handle(command: Data([0xA5, 0, 1, 0, 0])), nak, "INCR_CNT")
    }

    /// `PWD_AUTH` is absent at the API surface too, not merely on the wire.
    func test_passwordAPIs_areRefused() {
        let sim = MifareUltralightCSimulator()
        XCTAssertThrowsError(try sim.authenticate(password: Data([1, 2, 3, 4])))
        XCTAssertThrowsError(try sim.setPassword(Data([1, 2, 3, 4]), pack: Data([0, 0])))
    }

    /// The key pages are not masked, they are **not decoded for reads at all**.
    ///
    /// Live-confirmed 2026-08-07 on real silicon: `30 2C` → `00`, a one-byte
    /// NAK, not sixteen zero bytes. The distinction is the whole point, because
    /// a NAK returns a Type-2 tag to HALT for the rest of the activation — so a
    /// caller that reads here does not come up four pages short, it kills the
    /// session. The simulator originally modelled zeros and understated it.
    func test_keyPages_areNotReadDecoded_andAReadHaltsTheTag() throws {
        let sim = MifareUltralightCSimulator()
        XCTAssertEqual(sim.handle(command: Data([0x30, 0x2C])), Data([0x00]), "expected a NAK")
        XCTAssertEqual(sim.handle(command: Data([0x30, 0x00])), Data([0x00]),
                       "the NAK must leave the tag halted, so even a page-0 read fails")
        XCTAssertThrowsError(try sim.readMemory(range: 44 * 4 ..< 48 * 4))
        XCTAssertNotNil(sim.storedKey, "the key is still there, just unreachable by READ")
    }

    /// The safe configuration read: `30 28` returns 28h–2Bh, entirely inside the
    /// decoded region, so it can never stray into the key pages. This is the
    /// exact frame the live capture used.
    func test_readConfiguration_usesTheSafeStartPage() async throws {
        let sim = MifareUltralightCSimulator()
        let frames = Recorder()
        let driver = UltralightCProtectionDriver(transceive: { command in
            await frames.record(Int(command.bytes[command.bytes.startIndex + 1]))
            return sim.handle(command: command.bytes)
        })
        let config = try await driver.readConfiguration()
        XCTAssertEqual(config, UltralightCConfiguration(auth0: 0x30, auth1: 0x00))
        let read = await frames.pages
        XCTAssertEqual(read, [0x28], "must read from 28h, not from AUTH0 at 2Ah")
        XCTAssertFalse(sim.handle(command: Data([0x30, 0x00])) == Data([0x00]),
                       "the tag must still be alive after a config read")
    }

    /// A full memory dump must stop at the decoded boundary. Walking to
    /// `pageCount` would NAK and take the session down with it.
    func test_readablePageCount_stopsBeforeTheKeyPages() throws {
        XCTAssertEqual(try profile.readablePageCount, 44)
        XCTAssertLessThan(try profile.readablePageCount, try profile.memoryLayout.pageCount)
        let sim = MifareUltralightCSimulator()
        XCTAssertNoThrow(try sim.readMemory(range: 0 ..< 44 * 4))
    }

    func test_addressingPastTheEnd_isRefused() {
        let sim = MifareUltralightCSimulator()
        XCTAssertEqual(sim.handle(command: Data([0x30, 0x30])), Data([0x00]), "page 48 does not exist")
        XCTAssertThrowsError(try sim.writeMemory(at: 48 * 4, bytes: Data(repeating: 0, count: 4)))
    }

    func test_uidPages_areReadOnly() {
        let sim = MifareUltralightCSimulator()
        XCTAssertEqual(sim.handle(command: Data([0xA2, 0x00, 1, 2, 3, 4])), Data([0x00]))
        XCTAssertEqual(sim.handle(command: Data([0xA2, 0x01, 1, 2, 3, 4])), Data([0x00]))
    }

    /// Page 3 is OTP: bits OR in and can never be cleared.
    func test_ccPage_isOneWay() throws {
        let sim = MifareUltralightCSimulator()
        try sim.writeMemory(at: 3 * 4, bytes: Data([0xE1, 0x10, 0x12, 0x00]))
        try sim.writeMemory(at: 3 * 4, bytes: Data([0x00, 0x00, 0x00, 0x00]))
        XCTAssertEqual(sim.pages[3], Data([0xE1, 0x10, 0x12, 0x00]), "OTP bits cannot be cleared")
    }

    // MARK: - The plan must never halt the tag

    /// **The regression guard for the 2026-08-07 live failure.**
    ///
    /// `ulc.identify` used to send `GET_VERSION` in order to assert that this
    /// chip refuses it. The assertion passed, the NAK halted the tag, and the
    /// next step died on a plain READ of page 0, failing the whole suite. CI was
    /// green throughout, because the simulator NAKed without halting.
    ///
    /// Both halves are now fixed, and this pins both: the simulator halts on any
    /// NAK, and no plan step sends a frame this silicon refuses.
    func test_plan_sendsNoCommandThatWouldHaltTheTag() async throws {
        let sim = MifareUltralightCSimulator()
        let profile = try XCTUnwrap(sim.profile)
        let report = await TagTestRunner(plan: TagTestPlan.plan(for: profile))
            .run(using: SimulatedSession(chip: sim))
        XCTAssertTrue(report.isCleanPass, "suite must pass end to end\n\(report.plainTextLog)")

        // The complete command set is READ, WRITE, COMPATIBILITY_WRITE,
        // AUTHENTICATE and HALT (rev 3.3 Table 14). Anything else is NAKed by
        // real silicon, and a NAK ends the activation.
        let supported: Set<UInt8> = [0x30, 0xA2, 0xA0, 0x1A, 0xAF, 0x50]
        for frame in sim.receivedCommands {
            guard let opcode = frame.first else { continue }
            // Continuation frames of the 3DES handshake are raw cryptogram
            // bytes, not opcodes; they follow an `AF` and are 17 bytes long.
            if frame.count == 17, opcode == 0xAF {
                continue
            }
            XCTAssertTrue(
                supported.contains(opcode),
                "plan sent \(String(format: "%02X", opcode)), which this chip NAKs — a NAK halts "
                    + "the tag and every following step fails"
            )
        }
        XCTAssertFalse(
            sim.receivedCommands.contains { $0.first == 0x60 },
            "GET_VERSION must never be sent to an Ultralight C, not even to prove it is refused"
        )
        // No READ may address the pages that are not decoded for reads.
        for frame in sim.receivedCommands where frame.first == 0x30 && frame.count >= 2 {
            let page = Int(frame[frame.startIndex + 1])
            XCTAssertLessThan(page, UltralightCLayout.readDecodedPageCount,
                              "READ of page \(page) is not decoded and would halt the tag")
        }
    }

    /// **A second `AUTHENTICATE` in one activation is refused**, and the refusal
    /// halts the tag. Live-confirmed 2026-08-07: `ulc.auth` completed the
    /// handshake, `ulc.protect` issued `1A 00` again, got a one-byte NAK, and
    /// the rest of the suite failed with "tag connection lost".
    func test_secondAuthenticateInOneActivation_isRefusedAndHalts() async throws {
        let sim = MifareUltralightCSimulator()
        _ = try await makeDriver(sim).authenticate(key: .factoryDefault)
        XCTAssertTrue(sim.isAuthenticated)

        XCTAssertEqual(sim.handle(command: Data([0x1A, 0x00])), Data([0x00]),
                       "a repeat handshake must be refused")
        XCTAssertEqual(sim.handle(command: Data([0x30, 0x00])), Data([0x00]),
                       "and the refusal halts the tag")
    }

    /// The tag remembers, because the card cannot be asked. Two protection
    /// operations in one tap must issue exactly **one** handshake.
    func test_connectedTag_authenticatesOnlyOncePerActivation() async throws {
        let sim = MifareUltralightCSimulator()
        let tag = try await SimulatedSession(chip: sim).start(alert: "")
        let firstDataPage = try XCTUnwrap(sim.profile?.memoryLayout.ndefRange).lowerBound

        _ = try await tag.authenticate(.ultralightC(key: .factoryDefault))
        // Would be a second handshake without the per-tap bookkeeping.
        try await tag.enableProtection(
            .ultralightC(key: newKey(), protectFromPage: firstDataPage, readProtect: false),
            replacing: .ultralightC(key: .factoryDefault)
        )

        XCTAssertEqual(sim.successfulAuthentications, 1,
                       "exactly one handshake per activation, however many operations run")
        XCTAssertTrue(sim.configuration.isProtected, "and the protection still landed")
    }

    /// The simulator must be no more forgiving than the silicon: any refused
    /// command ends the activation.
    func test_anyNAK_haltsTheTag() {
        let sim = MifareUltralightCSimulator()
        XCTAssertEqual(sim.handle(command: Data([0x60])), Data([0x00]), "GET_VERSION is refused")
        XCTAssertEqual(sim.handle(command: Data([0x30, 0x00])), Data([0x00]),
                       "after a NAK the tag answers nothing, not even a page-0 read")
        sim.endSession()
        XCTAssertNotEqual(sim.handle(command: Data([0x30, 0x00])).count, 1,
                          "a fresh activation wakes it again")
    }

    /// Real tags from our stock are **not blank in user memory**, and the
    /// datasheet permits it: §7.5.9 says the delivery content of pages 04h–27h
    /// is "not defined". The simulator seeds zeros as a fixture, which is a
    /// choice rather than a claim, so this pins that the plan does not quietly
    /// depend on it.
    ///
    /// Bytes are the live dump of 2026-08-07 (UID 04:B8:EC:CA:79:77:80): pages
    /// 4–6 carry 12 bytes that are not a valid NDEF TLV stream, and the rest of
    /// the user area is zero.
    func test_plan_passesOnATagWithNonBlankUserMemory() async throws {
        let sim = MifareUltralightCSimulator()
        try sim.writeMemory(at: 4 * 4, bytes: Data([
            0x02, 0x00, 0x00, 0x10,
            0x00, 0x06, 0x01, 0x10,
            0x11, 0xFF, 0x00, 0x00,
        ]))
        let profile = try XCTUnwrap(sim.profile)
        let report = await TagTestRunner(plan: TagTestPlan.plan(for: profile))
            .run(using: SimulatedSession(chip: sim))
        XCTAssertTrue(report.isCleanPass, "\(report.plainTextLog)")
    }

    // MARK: - Identification without GET_VERSION

    /// The chip identifies from its memory shape, using only reads it always
    /// answers. Driven off the simulator's own delivery state so the decoder and
    /// the factory model cannot drift apart.
    func test_identify_fromMemoryShape() {
        let sim = MifareUltralightCSimulator()
        let p0 = sim.handle(command: Data([0x30, 0x00]))
        let p40 = sim.handle(command: Data([0x30, 0x28]))
        let profile = ChipCatalog.identify(preEV1PageZero: p0, configPages: p40)
        XCTAssertEqual(profile?.id, .mifareUltralightC)
    }

    /// A protected tag must still identify: AUTH0 anywhere in 03h–30h is valid,
    /// and a tag that arrives gated is exactly the one we most need to name.
    func test_identify_worksOnAProtectedTag() async throws {
        let sim = MifareUltralightCSimulator()
        try await makeDriver(sim).enable(key: newKey(), protectFromPage: 20,
                                         readProtect: false, currentKey: .factoryDefault)
        sim.endSession()
        let profile = ChipCatalog.identify(
            preEV1PageZero: sim.handle(command: Data([0x30, 0x00])),
            configPages: sim.handle(command: Data([0x30, 0x28]))
        )
        XCTAssertEqual(profile?.id, .mifareUltralightC)
    }

    /// A chip smaller than 48 pages rolls a READ of 28h back to page 0. That
    /// echo means "this address does not exist", and must not be mistaken for
    /// config pages — an NTAG203 or original Ultralight would otherwise be
    /// misidentified and handed a 48-page layout.
    func test_identify_rejectsARollOverEcho() {
        let sim = MifareUltralightCSimulator()
        let p0 = sim.handle(command: Data([0x30, 0x00]))
        XCTAssertNil(ChipCatalog.identify(preEV1PageZero: p0, configPages: p0))
    }

    /// A refused `30 28` (no such page) rules the chip out rather than
    /// defaulting to it.
    func test_identify_rejectsAMissingConfigRead() {
        let sim = MifareUltralightCSimulator()
        let p0 = sim.handle(command: Data([0x30, 0x00]))
        XCTAssertNil(ChipCatalog.identify(preEV1PageZero: p0, configPages: nil))
        XCTAssertNil(ChipCatalog.identify(preEV1PageZero: p0, configPages: Data([0x00])))
    }

    /// Integrity checks come before the shape checks, so a garbled read cannot
    /// match by accident and hand the caller a wrong page map.
    func test_identify_rejectsABadBCCOrNonNXPManufacturer() {
        let sim = MifareUltralightCSimulator()
        let p40 = sim.handle(command: Data([0x30, 0x28]))

        var corruptBCC = [UInt8](sim.handle(command: Data([0x30, 0x00])))
        corruptBCC[3] ^= 0xFF
        XCTAssertNil(ChipCatalog.identify(preEV1PageZero: Data(corruptBCC), configPages: p40))

        var notNXP = [UInt8](sim.handle(command: Data([0x30, 0x00])))
        notNXP[0] = 0x16 // EM Microelectronic
        notNXP[3] = 0x88 ^ notNXP[0] ^ notNXP[1] ^ notNXP[2]
        XCTAssertNil(ChipCatalog.identify(preEV1PageZero: Data(notNXP), configPages: p40))
    }

    /// An out-of-range AUTH0 is not this chip.
    func test_identify_rejectsAnImplausibleAuth0() {
        let sim = MifareUltralightCSimulator()
        let p0 = sim.handle(command: Data([0x30, 0x00]))
        var config = [UInt8](sim.handle(command: Data([0x30, 0x28])))
        config[8] = 0xFF
        XCTAssertNil(ChipCatalog.identify(preEV1PageZero: p0, configPages: Data(config)))
    }

    // MARK: - 3DES handshake against the production driver

    /// Production driver against the simulator's card-side implementation. Both
    /// sides compute independently, so this proves the two agree on cipher
    /// direction, IV chaining and the rotate, not merely that one calls the other.
    func test_handshake_succeedsWithTheFactoryKey() async throws {
        let sim = MifareUltralightCSimulator()
        let rndA = try await makeDriver(sim).authenticate(key: .factoryDefault)
        XCTAssertEqual(rndA.count, 8)
        XCTAssertTrue(sim.isAuthenticated)
        XCTAssertEqual(sim.successfulAuthentications, 1)
    }

    func test_handshake_failsWithTheWrongKey() async throws {
        let sim = MifareUltralightCSimulator()
        let wrong = try UltralightCKey(cipherOrder: Data(repeating: 0x11, count: 16))
        do {
            _ = try await makeDriver(sim).authenticate(key: wrong)
            XCTFail("a wrong key must not authenticate")
        } catch let error as TagError {
            guard case .authFailed = error.kind else { return XCTFail("got \(error.kind)") }
        }
        XCTAssertFalse(sim.isAuthenticated)
        XCTAssertEqual(sim.failedAuthentications, 1)
    }

    /// The byte-order trap, end to end. A key written in memory order but used
    /// in cipher order (or vice versa) is 16 valid bytes either way, so nothing
    /// catches it except the card.
    func test_handshake_failsWhenTheKeyOrderIsSwapped() async throws {
        let sim = MifareUltralightCSimulator()
        let swapped = try UltralightCKey(cipherOrder: UltralightCKey.factoryDefault.memoryOrder)
        do {
            _ = try await makeDriver(sim).authenticate(key: swapped)
            XCTFail("the swapped-order key must not authenticate")
        } catch {
            // expected
        }
    }

    // MARK: - Protection lifecycle

    private func newKey() throws -> UltralightCKey {
        try UltralightCKey(cipherOrder: Data((0 ..< 16).map { UInt8(0xA0 + $0) }))
    }

    func test_enable_writesKeyThenConfig_andArmsProtection() async throws {
        let sim = MifareUltralightCSimulator()
        let driver = makeDriver(sim)
        let key = try newKey()

        try await driver.enable(key: key, protectFromPage: 4, readProtect: false,
                                currentKey: .factoryDefault)

        XCTAssertEqual(sim.configuration.auth0, 0x04)
        XCTAssertEqual(sim.configuration.auth1, 0x01, "write-only is AUTH1 bit 0 SET")
        XCTAssertTrue(sim.configuration.isProtected)
        XCTAssertFalse(sim.configuration.readProtect)
        XCTAssertEqual(sim.storedKey, key, "the key is stored in memory order")
    }

    /// The new key only takes effect after an RF reset (rev 3.3 §7.5.7 remark).
    /// Modelling this stops us encoding a flow that only works in CI.
    func test_newKey_onlyAuthenticatesAfterReactivation() async throws {
        let sim = MifareUltralightCSimulator()
        let key = try newKey()
        try await makeDriver(sim).enable(key: key, protectFromPage: 4, readProtect: false,
                                         currentKey: .factoryDefault)

        sim.endSession()
        // Fresh tap: the old key is gone and the new one works.
        await assertAuthFails(sim, with: .factoryDefault)
        sim.endSession()
        _ = try await makeDriver(sim).authenticate(key: key)
        XCTAssertTrue(sim.isAuthenticated)
    }

    /// Write protection actually gates writes on a fresh tap.
    func test_writeProtection_isEnforcedAfterReactivation() async throws {
        let sim = MifareUltralightCSimulator()
        let key = try newKey()
        try await makeDriver(sim).enable(key: key, protectFromPage: 4, readProtect: false,
                                         currentKey: .factoryDefault)
        sim.endSession()

        XCTAssertEqual(sim.handle(command: Data([0xA2, 0x04, 1, 2, 3, 4])), Data([0x00]),
                       "unauthenticated write to a protected page must NAK")
        // That refusal halted the tag, so verifying "reads stay open" needs a
        // fresh activation. On silicon this is why the enforcement verifier
        // needs three sessions rather than one.
        sim.endSession()
        XCTAssertNotEqual(sim.handle(command: Data([0x30, 0x04])).count, 1,
                          "reads stay open under write-only protection")

        _ = try await makeDriver(sim).authenticate(key: key)
        XCTAssertEqual(sim.handle(command: Data([0xA2, 0x04, 1, 2, 3, 4])), Data([0x0A]),
                       "authenticated write goes through")
    }

    /// Read protection is the inverted-polarity case: AUTH1 bit 0 **clear**.
    func test_readProtection_gatesReadsToo() async throws {
        let sim = MifareUltralightCSimulator()
        let key = try newKey()
        try await makeDriver(sim).enable(key: key, protectFromPage: 4, readProtect: true,
                                         currentKey: .factoryDefault,
                                         armReadGateUnrecoverably: true)
        XCTAssertEqual(sim.configuration.auth1, 0x00, "read+write restricted is bit 0 CLEAR")
        sim.endSession()

        XCTAssertEqual(sim.handle(command: Data([0x30, 0x04])), Data([0x00]),
                       "unauthenticated read of a protected page must NAK")
        sim.endSession() // the refusal halted the tag
        _ = try await makeDriver(sim).authenticate(key: key)
        XCTAssertNotEqual(sim.handle(command: Data([0x30, 0x04])).count, 1)
    }

    /// Pages below AUTH0 stay open, which is what makes partial protection useful.
    func test_pagesBelowAuth0_stayOpen() async throws {
        let sim = MifareUltralightCSimulator()
        try await makeDriver(sim).enable(key: newKey(), protectFromPage: 20,
                                         readProtect: true, currentKey: .factoryDefault,
                                         armReadGateUnrecoverably: true)
        sim.endSession()
        XCTAssertNotEqual(sim.handle(command: Data([0x30, 0x04])).count, 1, "page 4 is below AUTH0")
        XCTAssertEqual(sim.handle(command: Data([0x30, 0x14])), Data([0x00]), "page 20 is at AUTH0")
        XCTAssertEqual(sim.handle(command: Data([0x30, 0x04])), Data([0x00]),
                       "and that refusal halts the tag, so even an open page stops answering")
    }

    /// Disable must leave the tag genuinely unprotected **and** back on the
    /// factory key, or the next run cannot open it. This is what lets Ultralight
    /// C have an enforcement verifier where ICODE SLIX cannot.
    func test_disable_returnsTheTagToFactory() async throws {
        let sim = MifareUltralightCSimulator()
        let key = try newKey()
        try await makeDriver(sim).enable(key: key, protectFromPage: 4, readProtect: true,
                                         currentKey: .factoryDefault,
                                         armReadGateUnrecoverably: true)
        sim.endSession()

        try await makeDriver(sim).disable(currentKey: key)
        XCTAssertFalse(sim.configuration.isProtected)
        XCTAssertEqual(sim.configuration.auth0, 0x30)
        XCTAssertEqual(sim.configuration.auth1, 0x00, "AUTH1 must go back to its delivery value")
        XCTAssertEqual(sim.storedKey, .factoryDefault)
        // "Restored to factory" should be literally true, byte for byte.
        XCTAssertEqual(sim.pages[UltralightCLayout.auth0Page],
                       MifareUltralightCSimulator
                           .deliveryState(uid: sim.uid, key: .factoryDefault)[UltralightCLayout.auth0Page])
        XCTAssertEqual(sim.pages[UltralightCLayout.auth1Page],
                       MifareUltralightCSimulator
                           .deliveryState(uid: sim.uid, key: .factoryDefault)[UltralightCLayout.auth1Page])

        sim.endSession()
        _ = try await makeDriver(sim).authenticate(key: .factoryDefault)
        XCTAssertEqual(try sim.readProtectionState()?.passwordProtect, false)
    }

    /// **The counterintuitive one.** Immediately after `enable`, the card is
    /// still authenticating against the key it *activated* with, not the key
    /// now sitting in its pages (rev 3.3 §7.5.7 remark). So an in-session
    /// removal takes the old key, and passing the new one fails with a bare NAK
    /// and the misleading "wrong key, or wrong byte order" diagnostic.
    ///
    /// This is not hypothetical: the first version of `ultralightCPlan` passed
    /// the new key here, and this behaviour is what caught it in CI instead of
    /// on a tag that would then have been left gated.
    func test_disableInTheSameSession_takesThePreviouslyActiveKey() async throws {
        let sim = MifareUltralightCSimulator()
        let newKey = try newKey()
        try await makeDriver(sim).enable(key: newKey, protectFromPage: 4, readProtect: false,
                                         currentKey: .factoryDefault)

        // The new key is in the pages but not yet in force.
        XCTAssertEqual(sim.storedKey, newKey)

        // A fresh activation latches it: the factory key stops working and the
        // new one starts. (Within the arming session neither could be tested by
        // re-authenticating, because a second handshake in one activation is
        // refused outright.)
        sim.endSession()
        await assertAuthFails(sim, with: .factoryDefault)

        // That refusal halted the tag, as it does on silicon.
        sim.endSession()
        try await makeDriver(sim).disable(currentKey: newKey)
        XCTAssertFalse(sim.configuration.isProtected)
        XCTAssertEqual(sim.storedKey, .factoryDefault)
    }

    /// A protected tag must not be openable without the key, or "protection"
    /// means nothing.
    func test_disable_failsWithoutTheCurrentKey() async throws {
        let sim = MifareUltralightCSimulator()
        try await makeDriver(sim).enable(key: newKey(), protectFromPage: 4,
                                         readProtect: false, currentKey: .factoryDefault)
        sim.endSession()
        do {
            try await makeDriver(sim).disable(currentKey: .factoryDefault)
            XCTFail("disable must not succeed with the wrong key")
        } catch {
            XCTAssertTrue(sim.configuration.isProtected, "the tag stays protected")
        }
    }

    /// AUTH0 is written last, so a failure part-way through never strands a tag
    /// protected by a credential nobody holds.
    ///
    /// This covers the virgin-tag case, where AUTH0 already reads `30h` and the
    /// driver has no gate to take down first. The re-key case is the one the
    /// write order was changed for, and it is asserted separately in
    /// `UltralightCAbortRecoveryTests.test_enable_onAProtectedTag_authenticatesOnceAndDisarmsFirst`:
    /// there the recorded order starts with an AUTH0 disarm, because writing the
    /// key under a live gate is what leaves a half-written key nobody can use.
    func test_enable_writesAUTH0Last() async throws {
        let sim = MifareUltralightCSimulator()
        let order = Recorder()
        let driver = UltralightCProtectionDriver(transceive: { command in
            let bytes = [UInt8](command.bytes)
            if bytes.first == 0xA2 {
                await order.record(Int(bytes[1]))
            }
            return sim.handle(command: command.bytes)
        })
        try await driver.enable(key: newKey(), protectFromPage: 4, readProtect: false,
                                currentKey: .factoryDefault)

        let written = await order.pages
        XCTAssertEqual(written, [44, 45, 46, 47, UltralightCLayout.auth1Page, UltralightCLayout.auth0Page])
        XCTAssertEqual(written.last, UltralightCLayout.auth0Page, "AUTH0 must be the final write")
    }

    /// Read the configuration back over the wire, the way the harness does.
    ///
    /// The read-back happens in a **fresh, authenticated activation**, because
    /// the tag being asked is read-protected and the configuration pages sit
    /// above AUTH0. Asking in the arming activation would NAK, and the NAK would
    /// halt the tag: see `test_readProtectedArming_leavesTheConfigurationUnreadableUntilUnlocked`,
    /// which asserts exactly that.
    func test_readConfiguration_roundTrips() async throws {
        let sim = MifareUltralightCSimulator()
        let key = try newKey()
        let driver = makeDriver(sim)
        let atDelivery = try await driver.readConfiguration()
        XCTAssertEqual(atDelivery, UltralightCConfiguration(auth0: 0x30, auth1: 0x00))

        try await driver.enable(key: key, protectFromPage: 10, readProtect: true,
                                currentKey: .factoryDefault,
                                armReadGateUnrecoverably: true)
        sim.endSession()
        _ = try await makeDriver(sim).authenticate(key: key)

        let state = try await makeDriver(sim).readProtectionState()
        XCTAssertEqual(state?.passwordProtect, true)
        XCTAssertEqual(state?.effectiveReadProtect, true)
        if case .ultralightC(let settings)? = state?.style {
            XCTAssertEqual(settings.protectFromPage, 10)
            XCTAssertTrue(settings.readProtect)
        } else {
            XCTFail("expected an .ultralightC style, got \(String(describing: state?.style))")
        }
    }

    /// The property the previous version of the test above quietly depended on,
    /// asserted directly rather than assumed.
    ///
    /// Arming read protection over the configuration pages, in an activation
    /// that never authenticated, leaves those pages unreadable for the rest of
    /// that activation. The driver knows it and does not ask: it records a
    /// `.gateProven` failure naming the reason instead of putting a frame on the
    /// wire that would NAK and halt the tag.
    func test_readProtectedArming_leavesTheConfigurationUnreadableUntilUnlocked() async throws {
        let sim = MifareUltralightCSimulator()
        let key = try newKey()
        let residue = try await makeDriver(sim).enable(
            key: key, protectFromPage: 10, readProtect: true, currentKey: .factoryDefault,
            armReadGateUnrecoverably: true
        )

        XCTAssertEqual(sim.successfulAuthentications, 0,
                       "an unprotected tag is never sent a handshake")
        XCTAssertEqual(residue.gate, .unknown,
                       "the gate cannot be read back in this activation, so no verdict is claimed")
        XCTAssertTrue(residue.failures.contains { $0.step == .gateProven },
                      "and the residue says so rather than staying silent")
        XCTAssertTrue(sim.configuration.isProtected, "the configuration itself did land")

        // A fresh activation with the new key reads it fine.
        sim.endSession()
        _ = try await makeDriver(sim).authenticate(key: key)
        let config = try await makeDriver(sim).readConfiguration()
        XCTAssertEqual(config.auth0, 0x0A)
        XCTAssertEqual(config.auth1, 0x00)
    }

    // MARK: - `replacing:` is the only channel for "what opens this tag now"

    /// A tag this app has already personalised is re-keyed end to end, over the
    /// frames production sends, when the caller states the key it holds through
    /// `replacing:`.
    ///
    /// `ProtectionSpec.ultralightC` used to carry a `currentKey` of its own and
    /// the `TagSession` arm preferred it, so a caller's resolved credential was
    /// dropped and the driver handshook with whatever the builder had baked in
    /// (always the published factory key). Driving this through `ConnectedTag`
    /// rather than the driver is the point: on a tag that no longer answers to
    /// the factory key the discard shows up as a refused handshake on leg 2,
    /// which is a NAK, which halts the chip. Every assertion below is either the
    /// wire log or the simulator's own counters, so a parallel in-memory model
    /// could not make it pass.
    func test_enableProtection_reKeysAPersonalisedTag_withTheKeyFromReplacing() async throws {
        let sim = MifareUltralightCSimulator()
        let protectFromPage = try XCTUnwrap(profile.memoryLayout.ndefRange).lowerBound
        let personalised = try newKey()
        let replacement = try UltralightCKey(cipherOrder: Data((0 ..< 16).map { UInt8(0x50 + $0) }))

        // Personalise, then power-cycle the tag so the key it authenticates
        // against is the one just written (rev 3.3 section 7.5.7 remark).
        try await makeDriver(sim).enable(key: personalised, protectFromPage: protectFromPage,
                                         readProtect: false, currentKey: .factoryDefault)
        sim.endSession()

        let tag = try await SimulatedSession(chip: sim).start(alert: "")
        let mark = sim.receivedCommands.count
        let handshakesBefore = sim.successfulAuthentications
        try await tag.enableProtection(
            .ultralightC(key: replacement, protectFromPage: protectFromPage, readProtect: false),
            replacing: .ultralightC(key: personalised)
        )
        let frames = Array(sim.receivedCommands[mark...])

        XCTAssertEqual(sim.successfulAuthentications - handshakesBefore, 1,
                       "the gate opened once, with the key the caller supplied")
        XCTAssertEqual(sim.failedAuthentications, 0, "and nothing was refused on the way")

        // State first: the configuration read precedes any credential, and it
        // starts at 28h so it never reaches the pages this chip does not decode.
        XCTAssertEqual(frames.first, Data([0x30, UInt8(UltralightCLayout.lockBytes23Page)]),
                       "the activation opens with the configuration read, not with a credential")
        XCTAssertTrue(frames.contains(Data([0x1A, 0x00])), "leg 1 of the 3DES handshake went out")
        XCTAssertTrue(frames.contains { $0.first == 0xAF && $0.count == 17 },
                      "and leg 2 carried the 16-byte token")

        let writtenPages = frames.filter { $0.first == 0xA2 }.map { Int($0[$0.startIndex + 1]) }
        XCTAssertEqual(
            writtenPages,
            [UltralightCLayout.auth0Page]
                + Array(UltralightCLayout.keyPages)
                + [UltralightCLayout.auth1Page, UltralightCLayout.auth0Page],
            "AUTH0 comes down first so the key is never written under a live gate, and goes back "
                + "up last so no abort point leaves a gate nobody holds the key to"
        )

        XCTAssertEqual(sim.storedKey, replacement, "the tag holds the replacement key")
        XCTAssertTrue(sim.configuration.isProtected)
        XCTAssertEqual(sim.configuration.auth0, UInt8(protectFromPage))
    }

    /// The fallback is unchanged: with no `replacing:` credential the driver
    /// still presents the published factory key, and on a tag that has been
    /// re-keyed the card refuses it.
    ///
    /// Asserted rather than assumed, because "no credential in hand" is the one
    /// case where the deleted `currentKey` field and `replacing:` agreed. The
    /// refusal is the whole reason the App must resolve a credential before it
    /// gets here: nothing is written, and the NAK ends the activation.
    func test_enableProtection_withoutReplacing_stillPresentsTheFactoryKey() async throws {
        let sim = MifareUltralightCSimulator()
        let protectFromPage = try XCTUnwrap(profile.memoryLayout.ndefRange).lowerBound
        let personalised = try newKey()
        let replacement = try UltralightCKey(cipherOrder: Data((0 ..< 16).map { UInt8(0x50 + $0) }))

        try await makeDriver(sim).enable(key: personalised, protectFromPage: protectFromPage,
                                         readProtect: false, currentKey: .factoryDefault)
        sim.endSession()

        let tag = try await SimulatedSession(chip: sim).start(alert: "")
        let mark = sim.receivedCommands.count
        do {
            try await tag.enableProtection(
                .ultralightC(key: replacement, protectFromPage: protectFromPage, readProtect: false)
            )
            XCTFail("the factory key must not open a tag that has been re-keyed")
        } catch {
            // Expected. The card refuses the token on leg 2 with a bare NAK.
        }
        let frames = Array(sim.receivedCommands[mark...])

        XCTAssertEqual(sim.failedAuthentications, 1,
                       "exactly one handshake attempt, and the card refused it")
        XCTAssertEqual(sim.successfulAuthentications, 0)
        XCTAssertTrue(frames.contains(Data([0x1A, 0x00])), "the factory key was still presented")
        XCTAssertFalse(frames.contains { $0.first == 0xA2 },
                       "and the refusal came before any write, so nothing changed on the tag")
        XCTAssertEqual(sim.storedKey, personalised, "the tag still holds its own key")
        XCTAssertTrue(sim.configuration.isProtected, "and is still gated")
    }

    // MARK: - Permanent lock

    func test_permanentLock_blocksWritesButNotReads() throws {
        let sim = MifareUltralightCSimulator()
        try sim.writeMemory(at: 3 * 4, bytes: Data([0xE1, 0x10, 0x12, 0x00]))
        try sim.permanentLock()
        XCTAssertTrue(sim.isLockedPermanent)
        XCTAssertEqual(sim.handle(command: Data([0xA2, 0x05, 1, 2, 3, 4])), Data([0x00]))
        sim.endSession() // the refused write halted the tag
        XCTAssertNotEqual(sim.handle(command: Data([0x30, 0x00])).count, 1,
                          "a permanent lock blocks writes but never reads")
    }

    private func assertAuthFails(
        _ sim: MifareUltralightCSimulator, with key: UltralightCKey,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await makeDriver(sim).authenticate(key: key)
            XCTFail("expected authentication to fail", file: file, line: line)
        } catch {
            // expected
        }
    }
}

private actor Recorder {
    private(set) var pages: [Int] = []
    func record(_ page: Int) {
        pages.append(page)
    }
}
