@testable import HexNFCKit
import HexNFCTagSim
import XCTest

/// Drives the **production** permanent-lock frames against each simulator.
///
/// Before this existed, nothing did. `SimulatedSession.permanentLock()` answers
/// the `ConnectedTag` protocol by calling the simulator's own lock model, so the
/// frame construction in `CoreNFCSession` was reachable only from real hardware
/// — and a dynamic-lock payload that set reserved bits on every NTAG21x reached
/// a live tag on 2026-08-07 with a full green suite behind it.
///
/// These tests assert the literal bytes. A payload regression shows up as a
/// frame diff, not as a passing test with a wrong tag.
final class Type2LockDriverTests: XCTestCase {
    /// Records every frame the driver emits while forwarding to a simulator.
    private final class Wire: @unchecked Sendable {
        private(set) var frames: [Data] = []
        private let respond: (Data) -> Data
        init(_ respond: @escaping (Data) -> Data) {
            self.respond = respond
        }

        func transceive(_ command: RawCommand) -> Data {
            frames.append(command.bytes)
            return respond(command.bytes)
        }

        /// Only the WRITE frames, which is where every irreversible byte lives.
        var writes: [Data] {
            frames.filter { $0.first == 0xA2 }
        }
    }

    private func lock(
        _ sim: NTAG21xSimulator, id: ChipID
    ) async throws -> Wire {
        let wire = Wire { sim.handle(command: $0) }
        let profile = try XCTUnwrap(ChipCatalog.profile(for: id))
        let driver = Type2LockDriver(transceive: { wire.transceive($0) })
        try await driver.permanentLock(layout: profile.memoryLayout, family: profile.family, configLayout: nil)
        return wire
    }

    // MARK: - The frames, per chip

    func test_ntag213_emitsDynamicThenStaticWithTheFigure10Mask() async throws {
        let sim = NTAG213Simulator()
        let wire = try await lock(sim, id: .ntag213)

        XCTAssertEqual(wire.writes.count, 2, "one dynamic write, one static write")
        // Dynamic first: page 28h, reserved bits clear. See the order note on
        // `Type2LockDriver` for why this one goes first.
        XCTAssertEqual(wire.writes[0], Data([0xA2, 0x28, 0xFF, 0x0F, 0x3F, 0x00]))
        // Static: page 2, bytes 0–1 preserved from the read, 2–3 set.
        let staticWrite = wire.writes[1]
        XCTAssertEqual(staticWrite.prefix(2), Data([0xA2, 0x02]))
        XCTAssertEqual(staticWrite.suffix(2), Data([0xFF, 0xFF]))
    }

    func test_ntag216_usesItsOwnMaskNotTheNTAG213One() async throws {
        let sim = NTAG216Simulator()
        let wire = try await lock(sim, id: .ntag216)
        XCTAssertEqual(wire.writes.count, 2)
        XCTAssertEqual(wire.writes[0], Data([0xA2, 0xE2, 0xFF, 0x3F, 0x7F, 0x00]))
    }

    func test_ultralightEV1_128_usesTheFigure9Mask() async throws {
        let sim = MifareUltralightEV1_128Simulator()
        let wire = try await lock(sim, id: .mifareUltralightEV1_128)
        XCTAssertEqual(wire.writes.count, 2)
        XCTAssertEqual(wire.writes[0], Data([0xA2, 0x24, 0xFF, 0x03, 0x1F, 0x00]))
    }

    /// The regression that reached hardware: this chip's page 28h holds two lock
    /// bytes, and bytes 2–3 are RFU. Live read-back settled at `FF FF 00 00`.
    func test_ultralightC_leavesTheReservedBytesAlone() async throws {
        let sim = MifareUltralightCSimulator()
        let wire = Wire { sim.handle(command: $0) }
        let profile = try XCTUnwrap(ChipCatalog.profile(for: .mifareUltralightC))
        let driver = Type2LockDriver(transceive: { wire.transceive($0) })
        try await driver.permanentLock(layout: profile.memoryLayout, family: profile.family, configLayout: nil)

        XCTAssertEqual(wire.writes.count, 2)
        XCTAssertEqual(wire.writes[0], Data([0xA2, 0x28, 0xFF, 0xFF, 0x00, 0x00]))
    }

    // MARK: - Structure

    /// NTAG 210µ's static lock bytes cover its whole 48 B user area, so it has
    /// no dynamic-lock page. A blind second write would land on a config page.
    func test_ntag210Micro_writesOnlyTheStaticLockPage() async throws {
        let sim = NTAG210MicroSimulator()
        let wire = try await lock(sim, id: .ntag210Micro)
        XCTAssertEqual(wire.writes.count, 1, "no dynamic lock page — exactly one write")
        XCTAssertEqual(wire.writes[0].prefix(2), Data([0xA2, 0x02]))
    }

    /// BCC1 and the internal byte share the static lock page and must survive.
    /// A blind page write would overwrite the UID checksum and brick the tag for
    /// every reader.
    func test_staticLockWrite_preservesBCC1AndTheInternalByte() async throws {
        let sim = NTAG213Simulator()
        let before = try sim.readMemory(range: 8 ..< 12)
        let wire = try await lock(sim, id: .ntag213)

        let written = wire.writes[1].dropFirst(2)
        XCTAssertEqual(Data(written.prefix(2)), before.prefix(2), "bytes 0–1 must be read-modify-written")
        let after = try sim.readMemory(range: 8 ..< 12)
        XCTAssertEqual(after.prefix(2), before.prefix(2))
    }

    /// **Dynamic first, and this order is the fix for a live incident.**
    ///
    /// The static lock page is page 2 on every chip in the catalogue, which sits
    /// *below* every AUTH0 this app writes, so a password-gated tag accepts it.
    /// The dynamic lock page sits above AUTH0, so a gated tag refuses it. Under
    /// the old static-first order a permanent lock on a protected NTAG213 burned
    /// pages 3-15 irreversibly and only then discovered it was gated
    /// (2026-09-04, `A2 02 ... -> 0A` followed by `A2 28 ... -> 00`).
    ///
    /// Attempting the gated page first means a refusal costs nothing.
    func test_dynamicLockIsWrittenBeforeStatic() async throws {
        let sim = NTAG213Simulator()
        let wire = try await lock(sim, id: .ntag213)
        let pages = wire.writes.map { $0[$0.startIndex + 1] }
        XCTAssertEqual(pages, [0x28, 0x02])
    }

    /// The driver reads the static lock page before writing it, and that read is
    /// what makes the static write non-destructive, so its absence is a defect
    /// even though the write would still be ACKed.
    func test_driverReadsTheStaticLockPageBeforeWritingIt() async throws {
        let sim = NTAG213Simulator()
        let wire = try await lock(sim, id: .ntag213)
        let readIndex = try XCTUnwrap(wire.frames.firstIndex(of: Data([0x30, 0x02])))
        let writeIndex = try XCTUnwrap(wire.frames.firstIndex { $0.prefix(2) == Data([0xA2, 0x02]) })
        XCTAssertLessThan(readIndex, writeIndex)
    }

    // MARK: - Effect

    func test_afterLocking_theSimulatorRefusesWritesButNotReads() async throws {
        let sim = NTAG213Simulator()
        _ = try await lock(sim, id: .ntag213)
        XCTAssertEqual(sim.handle(command: Data([0xA2, 0x05, 1, 2, 3, 4])), Data([0x00]), "write refused")
        // The refusal returned the tag to HALT, so the read below needs a fresh
        // activation. That is not a simulator quirk: it is what the live NTAG213
        // did on 2026-08-07, where the refused write ended the session and the
        // read-back came from a separate tap.
        sim.wakeUp()
        XCTAssertGreaterThan(sim.handle(command: Data([0x30, 0x00])).count, 1, "reads still work")
    }

    // MARK: - What the report may say about bits it cannot see

    /// A lock write whose acknowledgement was lost is not a refusal, and the one
    /// stage with a captured read-back can be asked which it was.
    ///
    /// This is CLAUDE.md's "a refusal may be a lost ACK" on the operation with no
    /// undo. The old code filed any thrown write as `.refused`, which made
    /// `burnedNothing` true and printed "Nothing was locked." over bits that had
    /// just burned.
    func test_dynamicLockWhoseAcknowledgementIsLost_isResolvedByReadingTheBitsBack() async throws {
        let sim = NTAG213Simulator()
        let profile = try XCTUnwrap(ChipCatalog.profile(for: .ntag213))
        let dynamicPage = try XCTUnwrap(profile.memoryLayout.dynamicLockPage)
        let faults = FaultInjectingSessionFactory(chip: sim)
        faults.arm(TagFault(.write(page: dynamicPage), .lostACK))
        let tag = try await faults.makeSession().start(alert: "")

        let outcome = try await tag.permanentLock()

        XCTAssertEqual(faults.report.swallowed.count, 1, "the chip applied the write and the answer was hidden")
        XCTAssertEqual(
            outcome.stages[.dynamicLock], .committedVerified,
            "the read-back is what settles it, not the missing ACK"
        )
        XCTAssertFalse(outcome.burnedNothing)
        XCTAssertNotEqual(String(localized: outcome.userMessage), "Nothing was locked.")
    }

    /// The other shape: the frame never reached the chip, so the bits really are
    /// clear and the chip says so. "Nothing was locked." is then the truth, and
    /// this is the case that keeps it available.
    func test_dynamicLockThatNeverReachedTheChip_reportsThatNothingWasLocked() async throws {
        let sim = NTAG213Simulator()
        let profile = try XCTUnwrap(ChipCatalog.profile(for: .ntag213))
        let dynamicPage = try XCTUnwrap(profile.memoryLayout.dynamicLockPage)
        let before = try sim.readMemory(range: 8 ..< 12)
        let faults = FaultInjectingSessionFactory(chip: sim)
        faults.arm(TagFault(.write(page: dynamicPage), .dropped))
        let tag = try await faults.makeSession().start(alert: "")

        do {
            _ = try await tag.permanentLock()
            XCTFail("a lock that burned nothing still has to report the refusal")
        } catch let error as TagError {
            guard case .permanentLockIncomplete(let outcome) = error.kind else {
                return XCTFail("expected permanentLockIncomplete, got \(error.kind)")
            }
            XCTAssertTrue(outcome.burnedNothing)
            XCTAssertEqual(outcome.stages[.staticLock], .notAttempted, "and the static bytes are untouched")
            XCTAssertEqual(String(localized: error.userMessage), "Nothing was locked.")
        }
        XCTAssertEqual(try sim.readMemory(range: 8 ..< 12), before)
    }

    /// The gap that inverting the stage order opened, and which the order itself
    /// is the reason to care about.
    ///
    /// The static write is a read-modify-write, so it reads page 2 first. That
    /// read now runs AFTER the dynamic bits have burned. Left as a bare `try` it
    /// threw straight past the outcome, and a tag with permanent lock bits set
    /// for good came back as "The tag responded outside the expected protocol."
    /// On `main` the same statement was the first in the method, where a throw
    /// really did mean nothing had happened, which is exactly how a safe line
    /// becomes an unsafe one without being edited.
    func test_aLostReadBeforeTheStaticWrite_stillReportsTheDynamicBitsThatBurned() async throws {
        let sim = NTAG213Simulator()
        let profile = try XCTUnwrap(ChipCatalog.profile(for: .ntag213))
        let staticPage = try XCTUnwrap(profile.memoryLayout.lockPages.first)
        let faults = FaultInjectingSessionFactory(chip: sim)
        faults.arm(TagFault(.read(page: staticPage), .dropped))
        let tag = try await faults.makeSession().start(alert: "")

        do {
            _ = try await tag.permanentLock()
            XCTFail("the read failed, so the operation cannot report success")
        } catch let error as TagError {
            guard case .permanentLockIncomplete(let outcome) = error.kind else {
                return XCTFail("a half-burned tag must not surface as \(error.kind)")
            }
            XCTAssertEqual(
                outcome.stages[.dynamicLock], .committedVerified,
                "the dynamic bits burned and were read back before the failure"
            )
            XCTAssertEqual(
                outcome.stages[.staticLock], .notAttempted,
                "the read is half of the write, so no static lock frame went out"
            )
            XCTAssertFalse(outcome.burnedNothing, "something burned, and the report has to say so")
            XCTAssertNotEqual(String(localized: error.userMessage), "Nothing was locked.")
        }
    }

    /// The static lock page has no captured read-back, so a write with no answer
    /// cannot be resolved either way. That is its own verdict: the dynamic bits
    /// are burned for good, and whether the static ones followed is unknown.
    /// What it may not be reported as is nothing.
    func test_staticLockWithNoAnswer_isReportedAsUnknownRatherThanAsNothing() async throws {
        let sim = NTAG213Simulator()
        let profile = try XCTUnwrap(ChipCatalog.profile(for: .ntag213))
        let staticPage = try XCTUnwrap(profile.memoryLayout.lockPages.first)
        let faults = FaultInjectingSessionFactory(chip: sim)
        faults.arm(TagFault(.write(page: staticPage), .dropped))
        let tag = try await faults.makeSession().start(alert: "")

        do {
            _ = try await tag.permanentLock()
            XCTFail("an unresolved irreversible write is not a success")
        } catch let error as TagError {
            guard case .permanentLockIncomplete(let outcome) = error.kind else {
                return XCTFail("expected permanentLockIncomplete, got \(error.kind)")
            }
            XCTAssertEqual(outcome.inconclusive, [.staticLock])
            XCTAssertEqual(outcome.committed, [.dynamicLock], "which did burn, and cannot be undone")
            XCTAssertFalse(outcome.burnedNothing)
            XCTAssertNotEqual(String(localized: error.userMessage), "Nothing was locked.")
            XCTAssertNotEqual(
                String(localized: error.userMessage),
                String(localized: TagError.tagLost().userMessage)
            )
        }
    }

    // MARK: - The pre-flight, and the page it may name

    /// A read-protected tag gates the configuration pages, so AUTH0 cannot be
    /// read at all. The refusal stands; what it may not do is name a page.
    ///
    /// Reading CFG0 straight off the wire has no way to tell a configuration
    /// page from a read roll-over, which serves page 0 and would put BCC0, a
    /// byte derived from the UID, where AUTH0 belongs. Going through
    /// `Type2PasswordDriver.readState` uses the one definition of that check.
    func test_permanentLock_onAReadProtectedTag_refusesWithoutNamingAPage() async throws {
        let sim = NTAG213Simulator()
        try sim.enablePasswordProtection(
            password: Data([1, 2, 3, 4]), pack: Data([5, 6]),
            protectFromPage: 4, readProtect: true, authLimit: 0
        )
        sim.beginActivation()
        let before = try sim.readMemory(range: 8 ..< 12)
        let tag = try await SimulatedSession(chip: sim).start(alert: "")

        do {
            _ = try await tag.permanentLock()
            XCTFail("a permanent lock must refuse a tag whose gate is armed")
        } catch let error as TagError {
            guard case .protectionIncomplete(let residue) = error.kind else {
                return XCTFail("expected protectionIncomplete, got \(error.kind)")
            }
            XCTAssertEqual(
                residue.gate, .unknown,
                "reads are gated, which proves the gate is armed and says nothing about where it starts"
            )
            XCTAssertEqual(
                String(localized: error.userMessage),
                "This tag is password protected, so it cannot be permanently locked. "
                    + "Remove the password first, then lock it.",
                "the residue's own copy is written for a protection change, and this was a lock"
            )
        }
        XCTAssertEqual(try sim.readMemory(range: 8 ..< 12), before, "not one bit burned")
    }

    /// And on a write-protected tag, where CFG0 does read back, the page is a
    /// reading and is still named.
    func test_permanentLock_onAWriteProtectedTag_namesThePageItRead() async throws {
        let sim = NTAG213Simulator()
        try sim.enablePasswordProtection(
            password: Data([1, 2, 3, 4]), pack: Data([5, 6]),
            protectFromPage: 4, readProtect: false, authLimit: 0
        )
        sim.beginActivation()
        let tag = try await SimulatedSession(chip: sim).start(alert: "")

        do {
            _ = try await tag.permanentLock()
            XCTFail("a permanent lock must refuse a tag whose gate is armed")
        } catch let error as TagError {
            guard case .protectionIncomplete(let residue) = error.kind else {
                return XCTFail("expected protectionIncomplete, got \(error.kind)")
            }
            XCTAssertEqual(residue.gate, .provenArmed(fromPage: 4))
        }
    }

    func test_chipWithoutLockPages_throwsRatherThanGuessing() async {
        let driver = Type2LockDriver(transceive: { _ in Data([0x0A]) })
        let layout = ChipMemoryLayout(pageSize: 4, pageCount: 16, lockPages: [])
        do {
            try await driver.permanentLock(layout: layout, family: .type2(.unknown), configLayout: nil)
            XCTFail("expected a permanent lock with no lock pages to throw")
        } catch let error as TagError {
            XCTAssertEqual(error.kind, .capabilityUnsupported(.permanentLock))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
