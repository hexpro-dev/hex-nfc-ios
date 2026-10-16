@testable import HexNFCKit
@testable import HexNFCTagSim
@testable import HexNFCTestKit
import XCTest

/// NTAG 210µ (NT2H1001) behaviour. The point of this suite is the chip's
/// *absences*: it is the most reduced die in the NTAG21x family, and every
/// command it lacks is one the rest of the family has, so a simulator that
/// inherits family behaviour wholesale would be more capable than the silicon
/// and let a harness step pass in CI while NAKing on a real tag.
///
/// Datasheet: NXP NT2L1001_NT2H1001 rev 3.0 (doc 343930).
final class NTAG210MicroTests: XCTestCase {
    private func makeTag(_ simulator: NTAG210MicroSimulator) async throws -> any ConnectedTag {
        try await SimulatedSession(chip: simulator).start(alert: "")
    }

    // MARK: - Profile shape

    func test_capabilities_omitPasswordCounterAndFastRead() {
        let caps = ChipProfile.ntag210Micro.capabilities
        // Present.
        XCTAssertTrue(caps.contains(.ndefRead))
        XCTAssertTrue(caps.contains(.ndefWrite))
        XCTAssertTrue(caps.contains(.permanentLock))
        XCTAssertTrue(caps.contains(.signatureRead))
        XCTAssertTrue(caps.contains(.formatCC))
        // Absent — each of these is a command the chip does not implement.
        XCTAssertFalse(caps.contains(.passwordAuth), "no PWD_AUTH: the µ die has no config pages")
        XCTAssertFalse(caps.contains(.counterRead), "no READ_CNT (39h)")
        XCTAssertFalse(caps.contains(.fastRead), "no FAST_READ (3Ah)")
        XCTAssertFalse(caps.contains(.tamperStatus))
    }

    func test_memoryLayout_matchesDatasheet() {
        let layout = ChipProfile.ntag210Micro.memoryLayout
        XCTAssertEqual(layout.pageCount, 16, "16 pages, 00h–0Fh")
        XCTAssertEqual(layout.byteCount, 64)
        XCTAssertEqual(layout.ccPage, 3)
        XCTAssertEqual(layout.ndefRange, 4 ... 15, "user memory 04h–0Fh")
        XCTAssertEqual(ChipProfile.ntag210Micro.ndefByteCapacity, 48)
        // Lock bytes exist; password pages do not. These two facts are
        // independent, and conflating them is what previously made
        // `permanentLock` unreachable on this chip.
        XCTAssertEqual(layout.lockPages, [2])
        XCTAssertNil(layout.dynamicLockPage, "static lock bytes cover the whole 48 B user area")
        XCTAssertNil(layout.pwdPage)
        XCTAssertNil(layout.packPage)
        XCTAssertEqual(layout.configPages, [])
    }

    func test_factoryCC_isPreWrittenAtDelivery() async throws {
        // rev 3.0 Table 4: page 03h ships as E1 10 06 00. Unlike UL EV1, this
        // chip is NDEF-formatted out of the box.
        let tag = try await makeTag(NTAG210MicroSimulator())
        let page3 = try await tag.readMemory(range: 12 ..< 16)
        XCTAssertEqual(page3, Data([0xE1, 0x10, 0x06, 0x00]))
        XCTAssertEqual(ChipProfile.ntag210Micro.factoryCC, page3)
    }

    // MARK: - Commands the chip does NOT implement

    func test_fastRead_naks() {
        let sim = NTAG210MicroSimulator()
        XCTAssertEqual(sim.handle(command: Data([0x3A, 0x03, 0x03])), Data([0x00]),
                       "FAST_READ is absent from rev 3.0 Table 5")
    }

    func test_readCounter_naks() {
        let sim = NTAG210MicroSimulator()
        XCTAssertEqual(sim.handle(command: Data([0x39, 0x02])), Data([0x00]),
                       "no NFC counter hardware on this die")
    }

    func test_passwordAuth_naks() {
        let sim = NTAG210MicroSimulator()
        XCTAssertEqual(sim.handle(command: Data([0x1B, 0x48, 0x45, 0x58, 0x21])), Data([0x00]))
    }

    func test_checkTearingEvent_naks() {
        let sim = NTAG210MicroSimulator()
        XCTAssertEqual(sim.handle(command: Data([0x3E, 0x00])), Data([0x00]),
                       "CHECK_TEARING_EVENT is Ultralight EV1 only")
    }

    // MARK: - Addressing limits

    func test_readBeyondLastPage_naks() {
        // rev 3.0 §11.2: valid READ addresses are 00h–0Fh; beyond that, NAK.
        let sim = NTAG210MicroSimulator()
        XCTAssertEqual(sim.handle(command: Data([0x30, 0x10])), Data([0x00]))
        XCTAssertEqual(sim.handle(command: Data([0x30, 0x13])), Data([0x00]),
                       "10h–13h are the plain NTAG210's config pages and do not exist on the µ")
    }

    func test_readRollsOverAtEndOfMemory() {
        // rev 3.0 §11.2, verbatim: "Reading from address 0Dh on a NTAG 210µ
        // results in blocks 0Dh, 0Eh, 0Fh and 00h being returned."
        let sim = NTAG210MicroSimulator()
        let response = sim.handle(command: Data([0x30, 0x0D]))
        XCTAssertEqual(response.count, 16)
        let page0 = sim.pages[0]
        XCTAssertEqual(response.suffix(4), page0, "4th page of the read must roll over to block 00h")
    }

    func test_writeBeyondLastPage_naks() {
        let sim = NTAG210MicroSimulator()
        let write = sim.handle(command: Data([0xA2, 0x10, 0xDE, 0xAD, 0xBE, 0xEF]))
        XCTAssertEqual(write, Data([0x00]), "rev 3.0 §11.3: WRITE range is 02h–0Fh")
    }

    // MARK: - Originality signature (READ_SIG / WRITE_SIG / LOCK_SIG)

    func test_readSignature_returns32Bytes() {
        let sim = NTAG210MicroSimulator()
        XCTAssertEqual(sim.handle(command: Data([0x3C, 0x00])).count, 32,
                       "32-byte ECDSA secp128r1 originality signature")
    }

    func test_writeSignature_naksAtFactoryBecauseSignatureShipsLocked() {
        // rev 3.0 §9.6: "This signature is locked in the dedicated memory."
        // The factory state is locked, NOT unlocked — so WRITE_SIG must refuse
        // until an explicit unlock.
        let sim = NTAG210MicroSimulator()
        XCTAssertEqual(sim.signatureLock, .locked)
        XCTAssertEqual(sim.handle(command: Data([0xA9, 0x00, 0x01, 0x02, 0x03, 0x04])), Data([0x00]))
    }

    func test_lockSig_unlockThenWriteThenPermanentlyLock() {
        let sim = NTAG210MicroSimulator()
        let original = sim.handle(command: Data([0x3C, 0x00]))

        // AC 00 — unlock.
        XCTAssertEqual(sim.handle(command: Data([0xAC, 0x00])), Data([0x0A]))
        XCTAssertEqual(sim.signatureLock, .unlocked)

        // WRITE_SIG block 00h now succeeds and lands at the MSByte end.
        XCTAssertEqual(sim.handle(command: Data([0xA9, 0x00, 0xAA, 0xBB, 0xCC, 0xDD])), Data([0x0A]))
        let rewritten = sim.handle(command: Data([0x3C, 0x00]))
        XCTAssertEqual(rewritten.prefix(4), Data([0xAA, 0xBB, 0xCC, 0xDD]))
        XCTAssertEqual(rewritten.dropFirst(4), original.dropFirst(4), "other blocks untouched")

        // Out-of-range block NAKs (valid range 00h–07h).
        XCTAssertEqual(sim.handle(command: Data([0xA9, 0x08, 0x01, 0x02, 0x03, 0x04])), Data([0x00]))
        // Every refusal below ends the activation, so each is followed by the
        // re-tap a real flow would need. This test walks the command semantics
        // rather than one session; the HALT is asserted on its own further down.
        sim.wakeUp()

        // AC 02 — permanent, and terminal.
        XCTAssertEqual(sim.handle(command: Data([0xAC, 0x02])), Data([0x0A]))
        XCTAssertEqual(sim.signatureLock, .permanentlyLocked)
        XCTAssertEqual(sim.handle(command: Data([0xAC, 0x00])), Data([0x00]),
                       "rev 3.0 §11.7: a permanently locked signature can never be unlocked")
        sim.wakeUp()
        XCTAssertEqual(sim.handle(command: Data([0xA9, 0x00, 0x01, 0x02, 0x03, 0x04])), Data([0x00]))
        sim.wakeUp()
        // READ_SIG survives: permanent lock removes the ability to *change* the
        // signature, not to read it.
        XCTAssertEqual(sim.handle(command: Data([0x3C, 0x00])).count, 32)
    }

    func test_lockSig_rejectsUndefinedArgument() {
        let sim = NTAG210MicroSimulator()
        XCTAssertEqual(sim.handle(command: Data([0xAC, 0x03])), Data([0x00]),
                       "only 00h/01h/02h are defined in rev 3.0 Table 23")
    }

    /// The rest of the family has a fixed NXP signature and no way to change it.
    func test_signatureCommandsAreNAKedByOtherType2Chips() {
        for sim: NTAG21xSimulator in [NTAG213Simulator(), NTAG216Simulator(), MifareUltralightEV1_48Simulator()] {
            XCTAssertEqual(sim.handle(command: Data([0xAC, 0x02])), Data([0x00]), "\(sim.variant) must NAK LOCK_SIG")
            XCTAssertEqual(sim.handle(command: Data([0xA9, 0x00, 0x01, 0x02, 0x03, 0x04])), Data([0x00]),
                           "\(sim.variant) must NAK WRITE_SIG")
        }
    }

    // MARK: - Permanent lock (memory), which the chip DOES support

    func test_permanentLock_setsStaticLockBytesOnly() throws {
        let sim = NTAG210MicroSimulator()
        try sim.permanentLock()
        let lockPage = sim.pages[2]
        XCTAssertEqual(lockPage[lockPage.startIndex + 2], 0xFF)
        XCTAssertEqual(lockPage[lockPage.startIndex + 3], 0xFF)
        XCTAssertEqual(sim.pages.count, 16, "permanent lock must not have addressed a page beyond 0Fh")
        XCTAssertTrue(sim.isLockedPermanent)
    }

    // MARK: - NDEF round trip

    func test_ndefRoundTrip() async throws {
        let sim = NTAG210MicroSimulator()
        let tag = try await makeTag(sim)
        let message = Data([0xD1, 0x01, 0x03, 0x54, 0x02, 0x65, 0x6E])
        try sim.writeNDEF(NDEFEnvelope.wrap(message: message))
        let read = try await tag.readNDEF()
        XCTAssertEqual(read, message)
    }

    // MARK: - Harness plan shape

    /// The plan must *skip* the unsupported steps for a capability reason rather
    /// than run and fail them — a failing suite would withhold the clean pass the
    /// gated irreversible ops depend on, which is what makes this load-bearing
    /// rather than cosmetic.
    func test_harnessPlan_skipsUnsupportedStepsAndPassesClean() async throws {
        let plan = TagTestPlan.plan(for: ChipProfile.ntag210Micro)
        let report = await TagTestRunner(plan: plan)
            .run(using: SimulatedSession(chip: NTAG210MicroSimulator()))

        XCTAssertTrue(report.passed, "suite must pass")
        XCTAssertTrue(report.isCleanPass, "a clean pass is what unlocks the gated ops")
        XCTAssertFalse(report.cleanupLeftTagProtected)

        let byID = Dictionary(uniqueKeysWithValues: report.results.map { ($0.id, $0) })
        // Password steps are never even appended (no `.passwordAuth`, no layout).
        XCTAssertNil(byID["t2.preflight"])
        XCTAssertNil(byID["t2.password"])
        XCTAssertNil(byID["t2.tearing"], "Ultralight EV1 only")
        // These are appended but must skip on the capability gate.
        for id in ["t2.fastRead", "t2.counters"] {
            let result = try XCTUnwrap(byID[id], "\(id) should be present but skipped")
            XCTAssertEqual(result.status, .skipped, "\(id) must skip, not run")
            XCTAssertEqual(result.skipReason, "required capability not advertised by this chip")
        }
        // And these must actually run.
        for id in ["t2.identify", "t2.uidBcc", "t2.ccVerify", "t2.signature", "t2.ndef"] {
            let result = try XCTUnwrap(byID[id], "\(id) missing from plan")
            XCTAssertEqual(result.status, .passed, "\(id) should have run and passed")
        }
    }
}
