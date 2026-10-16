@testable import HexNFCKit
@testable import HexNFCRecords
@testable import HexNFCTagSim
import XCTest

/// End-to-end Type-5 (ICODE SLIX2) protection: the production
/// `Iso15693ProtectionClient` (reached via the family-agnostic `enableProtection`)
/// run against the SLIX simulator through `transceive`. The simulator now refuses
/// unauthenticated writes once a write password is set, so "enable → re-tap →
/// write refused → present password → write allowed" is a real assertion.
final class Iso15693ProtectionTests: XCTestCase {
    private let writePw = Data([0xDE, 0xAD, 0xBE, 0xEF])

    /// An 80-block SLIX2, because that is the only ICODE geometry the app now
    /// offers protection to: 28 blocks is shared by the SLI, SLIX, SLIX-S and
    /// SLIX-L, and the SLI has no password machinery at all.
    private func makeTag() async throws -> (ConnectedTag, Iso15693Simulator) {
        let sim = Iso15693Simulator.slix2()
        let tag = try await SimulatedSession(chip: sim).start(alert: "")
        return (tag, sim)
    }

    /// Write a data block; returns the leading status byte (0x00 ok, 0x01 error)
    /// and the error code (or 0).
    private func writeBlock(_ tag: ConnectedTag, _ index: UInt8) async throws -> (status: UInt8, code: UInt8) {
        let resp = try await tag.transceive(RawCommand(bytes: Data([0x02, 0x21, index, 0x11, 0x22, 0x33, 0x44])))
        return (resp.first ?? 0xFF, resp.count >= 2 ? resp[resp.startIndex + 1] : 0)
    }

    func test_protectionStyle_slix2_isType5() async throws {
        let (tag, _) = try await makeTag()
        guard case .type5? = tag.protectionStyle else {
            return XCTFail("ICODE SLIX2 should report a .type5 protectionStyle")
        }
    }

    /// The narrowing, from the tag's side. A 28-block ICODE is an SLI, an SLIX,
    /// an SLIX-S or an SLIX-L and nothing over the air separates them, so the
    /// app must not offer a protection backend that answers B3h with silence on
    /// three of the four.
    func test_protectionStyle_28BlockICODE_offersNoBackend() async throws {
        let sim = Iso15693Simulator(blockCount: 28)
        let tag = try await SimulatedSession(chip: sim).start(alert: "")
        XCTAssertEqual(tag.chip?.id, .icodeSlix)
        XCTAssertNil(
            tag.protectionStyle,
            "28 blocks is shared with the plain ICODE SLI, which has no password hardware at all"
        )
    }

    func test_enableWritePassword_refusesUnauthenticatedWrite_thenAuthAllows() async throws {
        let (tag, sim) = try await makeTag()

        // Free tag: a write succeeds.
        let before = try await writeBlock(tag, 5)
        XCTAssertEqual(before.status, 0x00, "a free SLIX tag should accept a write")

        // Enable write-password protection.
        try await tag.enableProtection(.type5(write: writePw, read: nil, kind: .write))

        // Fresh tap: unauthenticated write refused — with the SLIX2's one and
        // only error code, the generic 0F (§9.6), not the 0x40 the ISO table
        // defines and this chip never sends.
        sim.endSession()
        let refused = try await writeBlock(tag, 5)
        XCTAssertEqual(refused.status, 0x01)
        XCTAssertEqual(refused.code, 0x0F, "the SLIX2 refuses with its generic 0F")

        // Present the password → writes allowed this tap.
        try await tag.authenticate(.type5(password: writePw, kind: .write))
        let allowed = try await writeBlock(tag, 5)
        XCTAssertEqual(allowed.status, 0x00, "after presenting the password the write goes through")
    }

    /// An unprotected tag must answer `TagProtection.none` — "I probed, it is
    /// not protected" — not `nil`, which across this codebase means "this chip
    /// doesn't model protection state, so I can't tell you".
    ///
    /// `return .none` in a `TagProtection?` function inferred `Optional.none`,
    /// so Type-5 answered "don't know" for every unprotected tag. That silently
    /// skipped the harness's `if let state` unprotected assertion and turned
    /// `cleanupLeftTagProtected` into an assumption — on the one family whose
    /// protection gate latches permanently.
    func test_readProtectionState_onAnUnprotectedTag_reportsDeterminedNotProtected() async throws {
        let (tag, _) = try await makeTag()
        let state = try await tag.readProtectionState()
        XCTAssertNotNil(state, "an unprotected Type-5 tag must not answer 'unknown'")
        XCTAssertEqual(state?.passwordProtect, false)
        XCTAssertEqual(state?.effectiveReadProtect, false)
    }

    func test_readProtectionState_reportsWriteProtected() async throws {
        let (tag, sim) = try await makeTag()
        try await tag.enableProtection(.type5(write: writePw, read: nil, kind: .write))
        sim.endSession()
        let state = try await tag.readProtectionState()
        XCTAssertEqual(state?.passwordProtect, true)
        XCTAssertEqual(state?.effectiveReadProtect, false)
    }

    /// The ordinary protection path may not arm privacy mode.
    ///
    /// This replaces `test_enableReadWrite_gatesReadsViaPrivacy`, whose premise
    /// was wrong twice over: a read+write request armed privacy from a savable
    /// preset with no warning, and its assertion expected a privacy tag to
    /// answer an error frame when a real one answers nothing at all (§9.5.3.9).
    /// Privacy is now a deliberate, opt-in act; see `Iso15693PrivacyTests`.
    func test_enableReadWrite_isRefusedWithoutTheExplicitPrivacyOptIn() async throws {
        let (tag, sim) = try await makeTag()
        do {
            try await tag.enableProtection(.type5(write: writePw, read: writePw, kind: .readWrite))
            XCTFail("arming privacy mode from ordinary protection must be refused")
        } catch let error as TagError {
            guard case .capabilityUnsupported = error.kind else {
                return XCTFail("expected .capabilityUnsupported, got \(error.kind)")
            }
        }
        XCTAssertFalse(sim.privacyMode, "nothing may have been armed")
    }

    func test_permanentLock_blocksAllWrites() async throws {
        let (tag, _) = try await makeTag()
        try await tag.permanentLock()
        let locked = try await writeBlock(tag, 5)
        XCTAssertEqual(locked.status, 0x01)
        XCTAssertEqual(locked.code, 0x0F, "a locked block refuses writes with the SLIX2's generic 0F")
    }

    /// The production lock loop against SLIX2 geometry: the counter block
    /// (79, §9.5.2.3 "cannot be locked") must be skipped — the first live run
    /// locked 00–4E cleanly, then failed the whole op by addressing it — and
    /// the security-status read-back must confirm every lockable block took.
    func test_clientPermanentLock_skipsTheCounterBlock_andVerifies() async throws {
        let sim = Iso15693Simulator(blockCount: 80)
        let tag = try await SimulatedSession(chip: sim).start(alert: "")
        let client = Iso15693ProtectionClient(transceive: { try await tag.transceive($0) })
        try await client.permanentLock(chip: .icodeSlix2, blockCount: 80)
        XCTAssertFalse(sim.blockLocks[79], "the counter block cannot be locked and must not be addressed")
        XCTAssertTrue(sim.blockLocks[0 ..< 79].allSatisfy { $0 }, "every lockable block ends locked")
    }

    /// A re-run on a partially locked tag (exactly the state the first live
    /// run left: 00–4E locked, op reported failure) must skip the already
    /// locked blocks — the chip refuses a re-lock with the same generic 0F as
    /// a real failure, so error-code forgiveness cannot provide idempotency.
    func test_clientPermanentLock_isIdempotent_onAPartiallyLockedTag() async throws {
        let sim = Iso15693Simulator(blockCount: 80)
        for block in 0 ..< 79 {
            _ = sim.handle(command: Data([0x02, 0x22, UInt8(block)]))
        }
        let tag = try await SimulatedSession(chip: sim).start(alert: "")
        let client = Iso15693ProtectionClient(transceive: { try await tag.transceive($0) })
        try await client.permanentLock(chip: .icodeSlix2, blockCount: 80) // must not throw
        XCTAssertTrue(sim.blockLocks[0 ..< 79].allSatisfy { $0 })
    }

    /// Live 2026-08-09: a fresh tag's lock run failed at block 49h with
    /// `01 0F` at 29 ms where every other lock answered in ~11 ms — a lost
    /// ACK on the write-alike LOCK_BLOCK, retransmitted into the now-locked
    /// block's refusal. The block WAS locked; only the answer lied. The
    /// client must consult the security status before declaring failure.
    func test_clientPermanentLock_recoversWhenALockACKIsLost() async throws {
        let sim = Iso15693Simulator()
        let tag = try await SimulatedSession(chip: sim).start(alert: "")
        final class Box: @unchecked Sendable { var lied = false }
        let box = Box()
        let client = Iso15693ProtectionClient(transceive: { command in
            let bytes = [UInt8](command.bytes)
            let response = try await tag.transceive(command)
            // First LOCK_BLOCK of block 5: the lock lands on the tag, but
            // the ACK "gets lost" — the client sees the generic error.
            if bytes.count >= 3, bytes[1] == 0x22, bytes[2] == 0x05, !box.lied {
                box.lied = true
                return Data([0x01, 0x0F])
            }
            return response
        })
        try await client.permanentLock(chip: .icodeSlix, blockCount: 28)
        XCTAssertTrue(box.lied, "the lost-ACK path must actually have been exercised")
        XCTAssertTrue(sim.blockLocks[5])
    }

    /// The other transient shape: the lock genuinely did not reach the tag.
    /// The status check reports the block unlocked, which earns one retry.
    func test_clientPermanentLock_retriesOnceOnATransientLockFailure() async throws {
        let sim = Iso15693Simulator()
        let tag = try await SimulatedSession(chip: sim).start(alert: "")
        final class Box: @unchecked Sendable { var dropped = false }
        let box = Box()
        let client = Iso15693ProtectionClient(transceive: { command in
            let bytes = [UInt8](command.bytes)
            if bytes.count >= 3, bytes[1] == 0x22, bytes[2] == 0x05, !box.dropped {
                box.dropped = true
                return Data([0x01, 0x0F]) // never reaches the tag
            }
            return try await tag.transceive(command)
        })
        try await client.permanentLock(chip: .icodeSlix, blockCount: 28)
        XCTAssertTrue(box.dropped)
        XCTAssertTrue(sim.blockLocks[5], "the retry must have locked the block")
    }

    /// Recovery is bounded: a block that never locks stops the op loudly, after
    /// one retry, never a silent skip or an endless loop.
    ///
    /// **And it stops with the burn counted.** Blocks 0 to 4 are locked forever
    /// by the time block 5 refuses, so "The tag responded outside the expected
    /// protocol" is the one report that is certainly wrong here. The chip's own
    /// security status is read back and the split reported as partial.
    func test_clientPermanentLock_failsLoudly_whenABlockNeverLocks() async throws {
        let sim = Iso15693Simulator()
        let tag = try await SimulatedSession(chip: sim).start(alert: "")
        let client = Iso15693ProtectionClient(transceive: { command in
            let bytes = [UInt8](command.bytes)
            if bytes.count >= 3, bytes[1] == 0x22, bytes[2] == 0x05 {
                return Data([0x01, 0x0F]) // this block never locks
            }
            return try await tag.transceive(command)
        })
        do {
            _ = try await client.permanentLock(chip: .icodeSlix, blockCount: 28)
            XCTFail("a block that never locks must fail the op")
        } catch let error as TagError {
            guard case .permanentLockIncomplete(let outcome) = error.kind else {
                return XCTFail("expected .permanentLockIncomplete, got \(error.kind)")
            }
            guard case .partiallyCommitted(let locked, let total, _) = outcome.stages[.blocks] else {
                return XCTFail("expected a partial burn, got \(String(describing: outcome.stages[.blocks]))")
            }
            XCTAssertEqual(locked, 5, "blocks 0 to 4 locked before block 5 refused")
            XCTAssertEqual(total, 28, "and the whole run is what it is measured against")
            XCTAssertTrue(outcome.isPartial)
            XCTAssertFalse(outcome.burnedNothing, "five blocks are read-only for good")
            XCTAssertEqual(
                String(localized: error.userMessage),
                String(localized: outcome.userMessage),
                "the user is told the tag is part-locked, not that the protocol misbehaved"
            )
        }
        XCTAssertFalse(sim.blockLocks[5])
        XCTAssertTrue(sim.blockLocks[0], "and the blocks that did burn are still burned")
    }

    /// `readProtectionState` on real silicon: every refusal is the generic 0F
    /// (§9.6), so classification rides the security-status bit, not error
    /// codes. A password-gated tag must read as protected; a permanently
    /// locked tag must NOT read as password-protected.
    func test_clientReadProtectionState_seesThroughTheGeneric0F() async throws {
        let sim = Iso15693Simulator.slix2()
        let tag = try await SimulatedSession(chip: sim).start(alert: "")
        let client = Iso15693ProtectionClient(transceive: { try await tag.transceive($0) })

        try await client.enable(writePassword: writePw, readPassword: nil)
        sim.endSession()
        let armed = try await client.readProtectionState()
        XCTAssertEqual(armed?.passwordProtect, true,
                       "a write-gated tag refusing with 0F must still read as protected")

        // Remove the gate, permanently lock instead: refusals continue (0F),
        // but they are the lock, not a password.
        try await client.disable(currentWritePassword: writePw)
        sim.endSession()
        try await client.permanentLock(chip: .icodeSlix2, blockCount: 80)
        sim.endSession()
        let locked = try await client.readProtectionState()
        XCTAssertEqual(locked?.passwordProtect, false,
                       "a permanently locked tag must not masquerade as password-protected")
    }

    /// The wire contract that six live taps failed to meet on 2026-08-07: the
    /// SLIX2 honours its password commands only in Addressed or Selected mode
    /// (§9.5.3.2/3.3), and iOS can only transmit the latter. So `enable` must
    /// SELECT before its first gated frame, and every gated frame must carry
    /// the Select flag (0x12) — asserted on the recorded frames themselves so
    /// a regression to plain 0x02 flags fails here, not on silicon.
    func test_enable_selectsFirst_andFlagsEveryGatedFrameSelected() async throws {
        let sim = Iso15693Simulator.slix2()
        let tag = try await SimulatedSession(chip: sim).start(alert: "")
        final class Recorder: @unchecked Sendable { var frames: [Data] = [] }
        let recorder = Recorder()
        let client = Iso15693ProtectionClient(transceive: { command in
            recorder.frames.append(command.bytes)
            return try await tag.transceive(command)
        })

        try await client.enable(writePassword: writePw, readPassword: nil)

        // Frame zero is the non-mutating state read, not the SELECT: nothing is
        // presented to a chip before it has been asked what it is gating. What
        // has to hold is that the SELECT precedes every *gated* frame.
        let opcodes = recorder.frames.map { $0[$0.startIndex + 1] }
        XCTAssertEqual(opcodes.first, Iso15693Opcode.getNXPSystemInformation,
                       "the state read comes first, before any password is presented")
        let selectIndex = try XCTUnwrap(opcodes.firstIndex(of: Iso15693Opcode.select), "enable must SELECT")
        let firstGated = recorder.frames.firstIndex { frame in
            Iso15693Opcode.requiresAddressedOrSelectedMode(
                opcode: frame[frame.startIndex + 1], params: [UInt8](frame.dropFirst(2))
            )
        }
        XCTAssertLessThan(selectIndex, try XCTUnwrap(firstGated), "SELECT must precede every gated command")
        for frame in recorder.frames {
            let flag = frame[frame.startIndex]
            let opcode = frame[frame.startIndex + 1]
            let params = [UInt8](frame.dropFirst(2))
            if Iso15693Opcode.requiresAddressedOrSelectedMode(opcode: opcode, params: params) {
                XCTAssertEqual(
                    flag, 0x12,
                    "gated opcode \(String(format: "%02X", opcode)) must ride the Select flag — "
                        + "the chip ignores it non-addressed"
                )
            }
        }
    }

    /// The bridge mirrors production: a frame the simulator ignores (a gated
    /// command outside Addressed/Selected mode) surfaces as `tagLost`, exactly
    /// as `CoreNFCSession.iso15693Failure` reports real silence — not as a
    /// zero-byte "answer".
    func test_nonSelectedGatedFrame_throughTheBridge_throwsTagLost() async throws {
        let (tag, _) = try await makeTag()
        do {
            _ = try await tag.transceive(
                RawCommand(bytes: Data([0x02, 0xB4, 0x02, 0xAA, 0xBB, 0xCC, 0xDD]))
            )
            XCTFail("a non-addressed WRITE_PASSWORD must draw silence, surfaced as tagLost")
        } catch let error as TagError {
            guard case .tagLost = error.kind else {
                return XCTFail("expected .tagLost, got \(error.kind)")
            }
        }
    }

    func test_wrongPassword_authFails() async throws {
        let (tag, sim) = try await makeTag()
        try await tag.enableProtection(.type5(write: writePw, read: nil, kind: .write))
        sim.endSession()
        do {
            try await tag.authenticate(.type5(password: Data([0x00, 0x00, 0x00, 0x00]), kind: .write))
            XCTFail("wrong SLIX password should fail")
        } catch let error as TagError {
            if case .authFailed = error.kind {
                return
            }
            XCTFail("expected .authFailed, got \(error.kind)")
        }
    }
}
