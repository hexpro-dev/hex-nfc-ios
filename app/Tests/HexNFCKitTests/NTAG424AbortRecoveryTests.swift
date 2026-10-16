@testable import HexNFCKit
@testable import HexNFCRecords
@testable import HexNFCTagSim
import XCTest

/// Every abort point in the NTAG424 DNA protection sequences, driven through a
/// transceive closure that stops answering on a named frame.
///
/// The claim under test: **no abort leaves the NDEF file gated behind a key the
/// app does not hold.** That claim was false under the previous order
/// (ChangeFileSettings first, ChangeKey last), and false in the worst possible
/// way: an abort between the two left the file gated behind key 0 while key 0
/// still held the published all-zero factory key (NT4H2421Gx rev 3.2 §9), while
/// the app went on presenting the key the user had configured, which the chip
/// had never been given.
final class NTAG424AbortRecoveryTests: XCTestCase {
    private let userKey = Data((0 ..< 16).map { UInt8(0xA0 &+ $0) })
    private let otherKey = Data((0 ..< 16).map { UInt8(0x50 &+ $0) })
    private let zeroKey = Data(count: 16)

    private func driver(_ sim: NTAG424DNASimulator) -> NTAG424ProtectionDriver {
        NTAG424ProtectionDriver(transceive: { command in sim.handle(command: command.bytes) })
    }

    /// A link that forwards to the simulator until the Nth frame carrying `ins`,
    /// then throws the shape a tag lifted off the phone produces.
    private func aborting(
        _ sim: NTAG424DNASimulator,
        beforeINS ins: UInt8,
        occurrence: Int = 1
    ) -> NTAG424ProtectionDriver {
        let counter = Counter()
        return NTAG424ProtectionDriver(transceive: { command in
            let bytes = [UInt8](command.bytes)
            if bytes.count >= 2, bytes[0] == 0x90, bytes[1] == ins {
                if await counter.next() >= occurrence {
                    throw TagError.tagLost(diagnostics: "test abort before INS \(ins)")
                }
            }
            return sim.handle(command: command.bytes)
        })
    }

    /// A link that lets the simulator **apply** the Nth `ins` frame and then
    /// throws instead of returning its answer: a lost acknowledgement, which is
    /// indistinguishable from a refusal at the reader.
    private func losingTheACK(
        _ sim: NTAG424DNASimulator,
        forINS ins: UInt8
    ) -> NTAG424ProtectionDriver {
        let counter = Counter()
        return NTAG424ProtectionDriver(transceive: { command in
            let bytes = [UInt8](command.bytes)
            let response = sim.handle(command: command.bytes)
            if bytes.count >= 2, bytes[0] == 0x90, bytes[1] == ins, await counter.next() == 1 {
                throw TagError.tagLost(diagnostics: "test: the answer to INS \(ins) was lost")
            }
            return response
        })
    }

    /// A link that answers one command with the chip's own success status word
    /// without letting the chip see it: the tag says OK and the state does not
    /// move. "An ACK is not proof" in its exact shape.
    ///
    /// `changeFileSettings` checks only the status word and discards the data, so
    /// no CMAC has to be forged for the driver to believe this.
    private func ackingButNotApplying(
        _ sim: NTAG424DNASimulator,
        ins: UInt8
    ) -> NTAG424ProtectionDriver {
        NTAG424ProtectionDriver(transceive: { command in
            let bytes = [UInt8](command.bytes)
            if bytes.count >= 2, bytes[0] == 0x90, bytes[1] == ins {
                return Data([0x91, 0x00])
            }
            return sim.handle(command: command.bytes)
        })
    }

    private func indexOfFirstINS(_ ins: UInt8, in commands: [Data]) -> Int? {
        commands.firstIndex { $0.count >= 2 && $0[$0.startIndex] == 0x90 && $0[$0.startIndex + 1] == ins }
    }

    // MARK: - State first

    /// P1, asserted on the wire: the plain state read runs before any key is
    /// offered. `A4` SELECT, then `F5` GetFileSettings and `64` GetKeyVersion,
    /// and only then `71` AuthenticateEV2First.
    func test_enable_readsStateBeforeAnyAuthentication() async throws {
        let sim = NTAG424DNASimulator()
        let recorder = FrameRecorder()
        let link = NTAG424ProtectionDriver(transceive: { command in
            await recorder.record(command.bytes)
            return sim.handle(command: command.bytes)
        })
        try await link.enable(aesKey: userKey, keySlot: 0, readProtect: false)

        let sent = await recorder.frames
        let getFileSettings = try XCTUnwrap(indexOfFirstINS(0xF5, in: sent))
        let getKeyVersion = try XCTUnwrap(indexOfFirstINS(0x64, in: sent))
        let authenticate = try XCTUnwrap(indexOfFirstINS(0x71, in: sent))
        XCTAssertLessThan(getFileSettings, authenticate, "GetFileSettings must precede the handshake")
        XCTAssertLessThan(getKeyVersion, authenticate, "and so must GetKeyVersion")
    }

    /// A tag whose NDEF file is already free and whose key is already the
    /// factory one is never authenticated **for the gate** and reports the
    /// factory credential as proven rather than assumed.
    func test_disable_onATagAlreadyOpen_provesTheFactoryKeyRatherThanAssumingIt() async throws {
        let sim = NTAG424DNASimulator()
        let residue = try await driver(sim).disable(currentKey: zeroKey, keySlot: 0)
        XCTAssertEqual(residue.gate, .provenOpen)
        XCTAssertEqual(residue.credential, .factoryDefault)
        XCTAssertTrue(residue.completed.contains(.credentialProven))
        XCTAssertTrue(residue.metItsGoal)
    }

    // MARK: - enable

    /// E3. An abort between ChangeKey and ChangeFileSettings leaves the tag
    /// **open** and holding the user's key, which is recoverable. The state that
    /// used to appear here (gated behind the factory key, app offering the
    /// user's) does not exist in this order.
    func test_enable_abortBeforeArmingTheGate_leavesTheTagOpenAndHoldingTheKey() async throws {
        let sim = NTAG424DNASimulator()
        do {
            try await aborting(sim, beforeINS: 0x5F).enable(aesKey: userKey, keySlot: 0, readProtect: false)
            XCTFail("the abort should surface")
        } catch let error as TagError {
            guard case .protectionIncomplete(let residue) = error.kind else {
                return XCTFail("expected .protectionIncomplete, got \(error.kind)")
            }
            // `.unknown`, and deliberately so. The tag below really is still
            // free, but the driver cannot know that: the command whose answer
            // went missing is the one that arms the gate, and a refusal may be a
            // lost ACK. This assertion read `.provenOpen` until 2026-09-05,
            // which was the driver stating the outcome of a write it never got
            // an answer to.
            XCTAssertEqual(residue.gate, .unknown)
            XCTAssertTrue(residue.completed.contains(.credentialProven),
                          "the key was proven before the gate was ever attempted")
        }

        sim.endSession()
        XCTAssertEqual(sim.keys[0], userKey, "the key landed")
        XCTAssertEqual(sim.keyVersions[0], NTAG424KeyVersion.appProgrammed)
        XCTAssertEqual(
            NTAG424ProtectionDriver.interpret(accessRights: sim.fileSettings[.ndef]?.accessRights ?? 0),
            TagProtection.none,
            "and the NDEF file is still free, so the tag is not gated behind anything"
        )
    }

    /// And the tap after that abort finishes the job with nothing re-entered:
    /// the driver finds the tag already holds the intended key, skips ChangeKey,
    /// and arms the gate.
    func test_enable_resumesAfterThatAbort_withoutTheUserReenteringAnything() async throws {
        let sim = NTAG424DNASimulator()
        _ = try? await aborting(sim, beforeINS: 0x5F).enable(aesKey: userKey, keySlot: 0, readProtect: false)
        sim.endSession()

        let recorder = FrameRecorder()
        let link = NTAG424ProtectionDriver(transceive: { command in
            await recorder.record(command.bytes)
            return sim.handle(command: command.bytes)
        })
        let residue = try await link.enable(aesKey: userKey, keySlot: 0, readProtect: false)

        let sent = await recorder.frames
        XCTAssertNil(indexOfFirstINS(0xC4, in: sent),
                     "the key already matches, so no second ChangeKey is sent")
        XCTAssertEqual(residue.gate, .provenArmed(fromPage: 0))
        XCTAssertTrue(residue.completed.contains(.gateProven))
        XCTAssertTrue(residue.metItsGoal)
        XCTAssertEqual(sim.keys[0], userKey)
    }

    /// The invariant, asserted for every abort index rather than argued: whenever
    /// a run leaves the NDEF file gated, the intended key opens it.
    func test_enable_neverGatesTheFileBehindAKeyTheAppDoesNotHold() async {
        for stopAfter in 0 ..< 20 {
            let sim = NTAG424DNASimulator()
            let counter = Counter()
            let link = NTAG424ProtectionDriver(transceive: { command in
                guard await counter.next() <= stopAfter else {
                    throw TagError.tagLost(diagnostics: "test abort at frame \(stopAfter)")
                }
                return sim.handle(command: command.bytes)
            })
            _ = try? await link.enable(aesKey: userKey, keySlot: 0, readProtect: false)
            sim.endSession()

            let rights = sim.fileSettings[.ndef]?.accessRights ?? 0
            guard NTAG424ProtectionDriver.interpret(accessRights: rights).passwordProtect else { continue }
            XCTAssertEqual(sim.keys[0], userKey,
                           "abort at frame \(stopAfter) gated the file behind a key the app does not hold")
        }
    }

    /// A tag already carrying a non-factory key is re-keyed rather than assumed
    /// to be at delivery, which is what makes an interrupted removal repairable.
    func test_enable_onAKeyedTag_doesNotAssumeTheFactoryKey() async throws {
        let sim = NTAG424DNASimulator(keys: [otherKey] + [Data](repeating: zeroKey, count: 4))
        let residue = try await driver(sim).enable(
            aesKey: userKey, keySlot: 0, readProtect: false, currentKeys: [otherKey]
        )
        XCTAssertEqual(sim.keys[0], userKey)
        XCTAssertEqual(residue.gate, .provenArmed(fromPage: 0))

        // Without the real current key there is nothing to open the tag with,
        // and the driver says so rather than corrupting anything.
        let stubborn = NTAG424DNASimulator(keys: [otherKey] + [Data](repeating: zeroKey, count: 4))
        do {
            try await driver(stubborn).enable(aesKey: userKey, keySlot: 0, readProtect: false)
            XCTFail("no candidate opens this tag, so enable must fail")
        } catch let error as TagError {
            guard case .authFailed = error.kind else {
                return XCTFail("expected .authFailed, got \(error.kind)")
            }
            XCTAssertEqual(stubborn.keys[0], otherKey, "and nothing was changed on the way")
        }
    }

    /// The state the **old** order produced, and the migration this change owes
    /// it: gated behind key 0 while key 0 still holds the factory key. The
    /// candidate list always ends with that key, so the tag opens and finishes.
    func test_enable_repairsATagLeftGatedBehindTheFactoryKey() async throws {
        let sim = NTAG424DNASimulator()
        // Reproduce the half-applied state the old order produced, by running
        // exactly the old order and stopping where the abort did: authenticate
        // with the factory key, arm the gate, never reach ChangeKey.
        let setup = driver(sim)
        try await setup.selectNDEFApp()
        try await setup.authenticate(keyNo: 0, key: zeroKey)
        try await setup.changeFileSettings(
            fileNo: 0x02, fileOption: 0x00,
            accessRights: NTAG424ProtectionDriver.accessRights(keySlot: 0, readProtect: false)
        )
        sim.endSession()
        XCTAssertTrue(
            NTAG424ProtectionDriver.interpret(accessRights: sim.fileSettings[.ndef]?.accessRights ?? 0)
                .passwordProtect,
            "precondition: the tag is gated"
        )
        XCTAssertEqual(sim.keys[0], zeroKey, "precondition: behind the factory key")

        // The caller offers the credential it believes in, which is the one the
        // old order told the user was on the tag. It is not: the chip never got
        // it. The walk falls through to the published factory key and says so.
        let residue = try await driver(sim).recoverProtection(
            intendedKey: userKey, keySlot: 0, readProtect: false, currentKeys: [otherKey]
        )
        XCTAssertEqual(sim.keys[0], userKey, "the repair re-keys the slot")
        XCTAssertEqual(residue.gate, .provenArmed(fromPage: 0))
        XCTAssertTrue(residue.authenticatedWithFactoryDefault,
                      "and reports that it had to fall back to the published key to get in, "
                          + "which is the clearest single sign an earlier run tore partway")
    }

    // MARK: - The lost ACK

    /// CLAUDE.md lesson 4. A ChangeKey that the tag applied but whose answer was
    /// lost must not be reported as "the key was not applied": the driver asks
    /// the tag which key it now holds and carries on.
    func test_changeKey_lostACK_isNotReportedAsFailure() async throws {
        let sim = NTAG424DNASimulator()
        let residue = try await losingTheACK(sim, forINS: 0xC4)
            .enable(aesKey: userKey, keySlot: 0, readProtect: false)

        XCTAssertEqual(sim.keys[0], userKey, "the tag really did take the key")
        XCTAssertEqual(residue.gate, .provenArmed(fromPage: 0), "and the gate was armed anyway")
        XCTAssertTrue(residue.completed.contains(.credentialProven))
        XCTAssertTrue(residue.metItsGoal)
    }

    /// The other half of the same consultation: a ChangeKey the chip genuinely
    /// refused is reported as "nothing changed", which is a safe retry rather
    /// than an ambiguous one.
    func test_changeKey_genuinelyRefused_isReportedAsNothingApplied() async throws {
        let sim = NTAG424DNASimulator()
        // Corrupt the ChangeKey cryptogram on the wire so the chip rejects the
        // MAC. Nothing is applied, and the tag keeps answering.
        let link = NTAG424ProtectionDriver(transceive: { command in
            var bytes = command.bytes
            if bytes.count >= 2, bytes[bytes.startIndex] == 0x90, bytes[bytes.startIndex + 1] == 0xC4 {
                bytes[bytes.endIndex - 2] ^= 0xFF
            }
            return sim.handle(command: bytes)
        })

        do {
            try await link.enable(aesKey: userKey, keySlot: 0, readProtect: false)
            XCTFail("a refused ChangeKey must not report success")
        } catch let error as TagError {
            guard case .protectionIncomplete(let residue) = error.kind else {
                return XCTFail("expected .protectionIncomplete, got \(error.kind)")
            }
            XCTAssertEqual(residue.credential, .unchanged,
                           "the tag still answers the old key, so nothing changed")
            XCTAssertEqual(residue.gate, .provenOpen)
        }
        XCTAssertEqual(sim.keys[0], zeroKey, "and the slot really is untouched")
    }

    // MARK: - disable

    /// D2. An abort between ChangeFileSettings and ChangeKey is a **successful
    /// removal** with credential residue, not a failure. Reporting it as a
    /// failure is what left tags that could never be protected again.
    func test_disable_abortBeforeTheKeyReset_reportsRemovedWithResidue() async throws {
        let sim = NTAG424DNASimulator()
        try await driver(sim).enable(aesKey: userKey, keySlot: 0, readProtect: false)
        sim.endSession()

        // The first ChangeKey belongs to `enable`; this run's is the reset, so
        // stop on the first one this link sees.
        let residue = try await aborting(sim, beforeINS: 0xC4)
            .disable(currentKey: userKey, keySlot: 0)

        XCTAssertEqual(residue.gate, .provenOpen, "the gate came down and was read back down")
        XCTAssertTrue(residue.metItsGoal)
        guard case .unknown(let reason) = residue.credential else {
            return XCTFail("expected an unknown credential verdict, got \(residue.credential)")
        }
        XCTAssertTrue(reason.contains("key reset"), "the residue must name the key reset")
        XCTAssertEqual(sim.keys[0], userKey, "the tag still holds the user's key, which is the point")
    }

    /// And that tag can still be protected again, which it could not before:
    /// `disable` reported total failure, the credential was discarded, and
    /// `enable` assumed the factory key.
    func test_aTagLeftWithResidue_canStillBeProtectedAgain() async throws {
        let sim = NTAG424DNASimulator()
        try await driver(sim).enable(aesKey: userKey, keySlot: 0, readProtect: false)
        sim.endSession()
        _ = try await aborting(sim, beforeINS: 0xC4).disable(currentKey: userKey, keySlot: 0)
        sim.endSession()

        let residue = try await driver(sim).enable(
            aesKey: otherKey, keySlot: 0, readProtect: false, currentKeys: [userKey]
        )
        XCTAssertEqual(sim.keys[0], otherKey)
        XCTAssertEqual(residue.gate, .provenArmed(fromPage: 0))
    }

    /// An abort **before** the gate comes down throws, and says the credential is
    /// untouched so the caller keeps it.
    func test_disable_abortBeforeTheGateComesDown_throwsAndKeepsTheCredential() async throws {
        let sim = NTAG424DNASimulator()
        try await driver(sim).enable(aesKey: userKey, keySlot: 0, readProtect: false)
        sim.endSession()

        do {
            try await aborting(sim, beforeINS: 0x5F).disable(currentKey: userKey, keySlot: 0)
            XCTFail("an abort before the gate came down must not report success")
        } catch let error as TagError {
            guard case .protectionIncomplete(let residue) = error.kind else {
                return XCTFail("expected .protectionIncomplete, got \(error.kind)")
            }
            XCTAssertNotEqual(residue.gate, .provenOpen)
            XCTAssertEqual(residue.credential, .unchanged)
        }
        sim.endSession()
        XCTAssertEqual(sim.keys[0], userKey)
        XCTAssertTrue(
            NTAG424ProtectionDriver.interpret(accessRights: sim.fileSettings[.ndef]?.accessRights ?? 0)
                .passwordProtect,
            "the tag is still gated"
        )
    }

    /// D4. Read back, and the file is still gated, so the reading is filed.
    ///
    /// The ChangeFileSettings is ACKed with the chip's own `91 00` without the
    /// chip seeing it, so the driver believes the access rights opened and they
    /// did not. Until this branch filed the verdict it holds, this outcome was
    /// indistinguishable in the residue from a read-back that could not be taken.
    ///
    /// Expected noise, asserted rather than ignored: swallowing the
    /// ChangeFileSettings also desyncs `cmdCtr`, so the ChangeKey that follows is
    /// refused and lands a `.credentialWritten` failure with the credential
    /// `.unknown`. The key on the tag is still the caller's, which is the half
    /// that matters for recovery.
    func test_disable_anAckThatDidNotTakeReportsTheGateItReadBack() async throws {
        let sim = NTAG424DNASimulator()
        try await driver(sim).enable(aesKey: userKey, keySlot: 0, readProtect: false)
        sim.endSession()

        do {
            _ = try await ackingButNotApplying(sim, ins: 0x5F)
                .disable(currentKey: userKey, keySlot: 0)
            XCTFail("the file is still gated, so the removal has not succeeded")
        } catch let error as TagError {
            guard case .protectionIncomplete(let residue) = error.kind else {
                return XCTFail("expected .protectionIncomplete, got \(error.kind)")
            }
            XCTAssertEqual(
                residue.gate, .provenArmed(fromPage: 0),
                "a Type-4 gate covers a file rather than a page range, so the key slot is the nearest "
                    + "true number. `enable` files the same verdict off the same read."
            )
            XCTAssertNotEqual(residue.gate, .unknown, "the read-back was taken; this is not that branch")
        }

        sim.endSession()
        XCTAssertEqual(sim.keys[0], userKey, "the key on the tag is still the caller's")
        XCTAssertTrue(
            NTAG424ProtectionDriver.interpret(accessRights: sim.fileSettings[.ndef]?.accessRights ?? 0)
                .passwordProtect,
            "and the file is still gated, which is what the residue said"
        )
    }

    // MARK: - Key version

    /// The key version is written by ChangeKey and read back by GetKeyVersion, so
    /// a later tap can tell a tag this app personalised from one at delivery.
    /// It is only ever a hint: the ordering of the candidate list, nothing else.
    func test_keyVersion_tracksWhatTheDriverWrites() async throws {
        let sim = NTAG424DNASimulator()
        XCTAssertEqual(sim.keyVersions[0], NTAG424KeyVersion.factory)

        try await driver(sim).enable(aesKey: userKey, keySlot: 0, readProtect: false)
        sim.endSession()
        XCTAssertEqual(sim.keyVersions[0], NTAG424KeyVersion.appProgrammed)

        try await driver(sim).disable(currentKey: userKey, keySlot: 0)
        sim.endSession()
        XCTAssertEqual(sim.keyVersions[0], NTAG424KeyVersion.factory)
    }

    /// A chip that refuses GetKeyVersion costs a round trip, not correctness:
    /// the candidate walk still finds the key, and nothing is reported as failed
    /// for that reason alone.
    func test_getKeyVersionRefused_isNotAnError() async throws {
        let sim = NTAG424DNASimulator()
        let link = NTAG424ProtectionDriver(transceive: { command in
            let bytes = [UInt8](command.bytes)
            if bytes.count >= 2, bytes[0] == 0x90, bytes[1] == 0x64 {
                return Data([0x91, 0x9D]) // PERMISSION_DENIED
            }
            return sim.handle(command: command.bytes)
        })
        let version = await link.getKeyVersion(keyNo: 0)
        XCTAssertNil(version, "a refusal reads as unverified, not as factory")

        let residue = try await link.enable(aesKey: userKey, keySlot: 0, readProtect: false)
        XCTAssertEqual(residue.gate, .provenArmed(fromPage: 0))
        XCTAssertEqual(sim.keys[0], userKey)
    }

    /// Candidate ordering is a hint and both orders contain both keys, so a
    /// wrong guess costs one round trip and never an outcome.
    func test_candidateOrdering_alwaysContainsTheFactoryKeyAndTheIntendedOne() {
        let atDelivery = NTAG424ProtectionState(accessRights: 0xE0EE, commMode: 0, keyVersion: 0x00)
        let personalised = NTAG424ProtectionState(accessRights: 0xE0EE, commMode: 0, keyVersion: 0x01)
        let unknown = NTAG424ProtectionState(accessRights: 0xE0EE, commMode: 0, keyVersion: nil)

        for state in [atDelivery, personalised, unknown] {
            let candidates = NTAG424ProtectionDriver.candidatesForEnable(
                state: state, intended: userKey, supplied: []
            )
            XCTAssertTrue(candidates.contains(zeroKey), "the published factory key is always tried")
            XCTAssertTrue(candidates.contains(userKey), "and so is the key we are about to write")
            XCTAssertEqual(Set(candidates).count, candidates.count, "no duplicates")
        }
        XCTAssertEqual(
            NTAG424ProtectionDriver.candidatesForEnable(state: personalised, intended: userKey, supplied: []).first,
            userKey,
            "an app-programmed version puts the intended key first"
        )
        XCTAssertEqual(
            NTAG424ProtectionDriver.candidatesForEnable(state: atDelivery, intended: userKey, supplied: []).first,
            zeroKey,
            "a delivery version puts the factory key first"
        )
    }
}

/// One-based call counter: the first `next()` answers 1.
private actor Counter {
    private var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}

private actor FrameRecorder {
    private(set) var frames: [Data] = []
    func record(_ frame: Data) {
        frames.append(frame)
    }
}
