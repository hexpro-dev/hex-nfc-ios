@testable import HexNFCKit
@testable import HexNFCTagSim
import XCTest

/// Every abort point in the MIFARE Ultralight C protection sequences, exercised
/// as a test rather than argued in a paragraph.
///
/// The claim under test is the one the write reorder exists to make true: **no
/// abort leaves the tag gated behind a credential nobody holds.** The row that
/// matters most is a tag lifted off the phone half way through the four key-page
/// writes, which under the previous order (key first, AUTH0 last, gate armed
/// throughout) left `old[0..7] ‖ new[8..15]` behind a live gate on silicon with
/// no factory reset.
///
/// `sim.beginActivation()` stands in for the tag leaving and returning to the
/// field, which is what latches a newly written key (MF0ICU2 rev 3.3 §7.5.7
/// remark) and clears the one-handshake-per-activation budget.
final class UltralightCAbortRecoveryTests: XCTestCase {
    private func newKey() throws -> UltralightCKey {
        try UltralightCKey(cipherOrder: Data((0 ..< 16).map { UInt8(0xA0 &+ $0) }))
    }

    private func otherKey() throws -> UltralightCKey {
        try UltralightCKey(cipherOrder: Data((0 ..< 16).map { UInt8(0x50 &+ $0) }))
    }

    private func driver(_ sim: MifareUltralightCSimulator) -> UltralightCProtectionDriver {
        UltralightCProtectionDriver(transceive: { command in sim.handle(command: command.bytes) })
    }

    /// A driver whose link stops answering just before the Nth WRITE to `page`,
    /// which is the shape a tag lifted off the phone produces.
    private func aborting(
        _ sim: MifareUltralightCSimulator,
        beforeWriteToPage page: Int,
        occurrence: Int = 1
    ) -> UltralightCProtectionDriver {
        let counter = Counter()
        return UltralightCProtectionDriver(transceive: { command in
            let bytes = [UInt8](command.bytes)
            if bytes.count >= 2, bytes[0] == 0xA2, Int(bytes[1]) == page {
                // `next()` is 1-based here, so `occurrence: 1` stops the first
                // write to that page.
                if await counter.next() >= occurrence {
                    throw TagError.tagLost(diagnostics: "test abort before WRITE p\(page)")
                }
            }
            return sim.handle(command: command.bytes)
        })
    }

    /// A driver whose frames pass through the shared fault-injection seam, so a
    /// test can lose an answer the chip really acted on. The plain closure
    /// helpers above can only stop a frame reaching the chip, which is the one
    /// shape that leaves the tag and the app still agreeing.
    private func driver(faulting faults: FaultInjectingSessionFactory) async throws
        -> UltralightCProtectionDriver
    {
        let tag = try await faults.makeSession().start(alert: "")
        return UltralightCProtectionDriver(transceive: { try await tag.transceive($0) })
    }

    // MARK: - applying a key

    /// U3, the row the reorder exists for. Aborting between two key pages must
    /// leave the tag **unprotected**, not gated behind the scramble.
    func test_enable_abortMidKey_leavesAnUnprotectedTag() async throws {
        let sim = MifareUltralightCSimulator()
        // Start from a protected tag, which is the case the old order bricked:
        // its gate was armed the whole time the key was being written.
        try await driver(sim).enable(
            key: otherKey(), protectFromPage: 4, readProtect: false, currentKey: .factoryDefault
        )
        sim.beginActivation()
        XCTAssertTrue(sim.configuration.isProtected)

        let key = try newKey()
        do {
            try await aborting(sim, beforeWriteToPage: 46).enable(
                key: key, protectFromPage: 4, readProtect: false, currentKey: otherKey()
            )
            XCTFail("the abort should surface")
        } catch let error as TagError {
            guard case .protectionIncomplete(let residue) = error.kind else {
                return XCTFail("expected .protectionIncomplete, got \(error.kind)")
            }
            XCTAssertEqual(residue.gate, .provenOpen,
                           "the residue must say the tag is open, because it is")
        }

        sim.beginActivation()
        XCTAssertEqual(sim.configuration.auth0, UltralightCLayout.protectionOff,
                       "AUTH0 came down before the key was touched, so the tag is unprotected")
        XCTAssertNotEqual(sim.storedKey, key, "and the key really is a scramble")
        XCTAssertNotEqual(sim.storedKey, try otherKey())
    }

    /// And the scramble is repairable, which is the whole point: the recovery tap
    /// sends **no** handshake, because a handshake against a key nobody holds
    /// would NAK and the NAK would halt the very session meant to fix it.
    func test_enable_resumesAfterAMidKeyAbort_withoutAuthenticating() async throws {
        let sim = MifareUltralightCSimulator()
        try await driver(sim).enable(
            key: otherKey(), protectFromPage: 4, readProtect: false, currentKey: .factoryDefault
        )
        sim.beginActivation()

        let key = try newKey()
        _ = try? await aborting(sim, beforeWriteToPage: 46).enable(
            key: key, protectFromPage: 4, readProtect: false, currentKey: otherKey()
        )
        sim.beginActivation()

        let handshakesBefore = sim.successfulAuthentications
        let failuresBefore = sim.failedAuthentications
        // Note the stale `currentKey`: the caller still believes the tag holds
        // the key it had before the torn attempt. It does not, and it must not
        // matter.
        let residue = try await driver(sim).enable(
            key: key, protectFromPage: 4, readProtect: false, currentKey: otherKey()
        )

        XCTAssertEqual(sim.successfulAuthentications, handshakesBefore,
                       "the recovery tap must not authenticate")
        XCTAssertEqual(sim.failedAuthentications, failuresBefore,
                       "and must not have tried and failed, which would have halted the tag")
        XCTAssertEqual(sim.storedKey, key, "all four key pages were rewritten over the scramble")
        XCTAssertEqual(sim.configuration.auth0, 0x04)
        XCTAssertEqual(residue.gate, .provenArmed(fromPage: 4))
        XCTAssertTrue(residue.completed.contains(.gateProven))
    }

    /// The invariant, asserted exhaustively rather than argued: abort before
    /// **every** frame in turn, and at no point is the tag gated behind a key the
    /// caller did not supply.
    func test_enable_neverGatesTheTagBehindAKeyNobodyHolds() async throws {
        let key = try newKey()
        // 24 comfortably exceeds the frame count of the longest path through
        // `enable` (state read, handshake, disarm, read-back, four key pages,
        // AUTH1, AUTH0, read-back).
        for stopAfter in 0 ..< 24 {
            let sim = MifareUltralightCSimulator()
            try await driver(sim).enable(
                key: otherKey(), protectFromPage: 4, readProtect: false, currentKey: .factoryDefault
            )
            sim.beginActivation()

            let counter = Counter()
            let link = UltralightCProtectionDriver(transceive: { command in
                guard await counter.next() < stopAfter else {
                    throw TagError.tagLost(diagnostics: "test abort at frame \(stopAfter)")
                }
                return sim.handle(command: command.bytes)
            })
            _ = try? await link.enable(
                key: key, protectFromPage: 4, readProtect: false, currentKey: otherKey()
            )

            sim.beginActivation()
            if sim.configuration.isProtected {
                // Gated. Then one of the two keys the caller named must open it.
                let stale = try otherKey()
                let opensWithNew = await opens(sim, with: key)
                sim.beginActivation()
                let opensWithOld = opensWithNew ? true : await opens(sim, with: stale)
                XCTAssertTrue(opensWithNew || opensWithOld,
                              "abort at frame \(stopAfter) left the tag gated behind neither key")
            }
        }
    }

    /// A virgin tag is never sent a handshake at all: nothing is gated, so there
    /// is nothing to authenticate past, and the frame could only ever cost the
    /// session.
    func test_enable_onAnUnprotectedTag_sendsNoAuthenticate() async throws {
        let sim = MifareUltralightCSimulator()
        try await driver(sim).enable(
            key: newKey(), protectFromPage: 4, readProtect: false, currentKey: .factoryDefault
        )
        XCTAssertEqual(sim.successfulAuthentications, 0)
        XCTAssertEqual(sim.failedAuthentications, 0)
        XCTAssertFalse(sim.receivedCommands.contains { $0.first == 0x1A },
                       "no AUTHENTICATE frame may reach an ungated tag")
    }

    /// A protected tag authenticates exactly once, and the very first WRITE is
    /// the AUTH0 disarm. The page order is the whole fix, so it is asserted
    /// literally.
    func test_enable_onAProtectedTag_authenticatesOnceAndDisarmsFirst() async throws {
        let sim = MifareUltralightCSimulator()
        try await driver(sim).enable(
            key: otherKey(), protectFromPage: 4, readProtect: false, currentKey: .factoryDefault
        )
        sim.beginActivation()

        let recorder = PageRecorder()
        let link = UltralightCProtectionDriver(transceive: { command in
            let bytes = [UInt8](command.bytes)
            if bytes.count >= 3, bytes[0] == 0xA2 {
                await recorder.record(page: Int(bytes[1]), value: bytes[2])
            }
            return sim.handle(command: command.bytes)
        })
        try await link.enable(
            key: newKey(), protectFromPage: 4, readProtect: false, currentKey: otherKey()
        )

        let written = await recorder.writes
        XCTAssertEqual(written.map(\.page), [42, 44, 45, 46, 47, 43, 42],
                       "AUTH0 down, key, AUTH1, AUTH0 up")
        XCTAssertEqual(written.first?.value, UltralightCLayout.protectionOff,
                       "the first write must take the gate down")
        XCTAssertEqual(written.last?.value, 0x04, "and the last must put it back up")
        XCTAssertEqual(sim.successfulAuthentications, 1)
    }

    // MARK: - the gate verdict an AUTH0 abort may report

    /// The Ultralight C twin of `Type2GateAttemptTests`' AUTH0 rule, and it
    /// matters here for the same reason: AUTH0 is the write that arms the gate,
    /// so the configuration read taken at the top of `enable` is a reading a
    /// later command invalidated.
    ///
    /// This catch used to set `residue.gate = .provenOpen` outright, under
    /// diagnostics that said "the key is on the tag and the tag is still
    /// unprotected". A lost ACK is exactly the case that makes that a
    /// fabrication: the chip applied the write and the answer vanished, so the
    /// tag is gated behind the key written a few frames earlier and its owner was
    /// being told to hold it against the phone again to switch protection on.
    func test_enable_aLostAuth0AckIsNotReportedAsAnUnprotectedTag() async throws {
        let sim = MifareUltralightCSimulator()
        let key = try newKey()
        let faults = FaultInjectingSessionFactory(chip: sim)
        faults.arm(TagFault(.write(page: UltralightCLayout.auth0Page), .lostACK))

        do {
            try await driver(faulting: faults).enable(
                key: key, protectFromPage: 4, readProtect: false, currentKey: .factoryDefault
            )
            XCTFail("an AUTH0 write whose answer never arrived is not a success")
        } catch let error as TagError {
            guard case .protectionIncomplete(let residue) = error.kind else {
                return XCTFail("expected .protectionIncomplete, got \(error.kind)")
            }
            XCTAssertEqual(
                residue.gate, .provenArmed(fromPage: 4),
                "the chip was asked afterwards, and it said the gate is up"
            )
            XCTAssertTrue(residue.completed.contains(.gateProven), "and that answer is what set the verdict")
            XCTAssertFalse(
                error.diagnostics.contains("still unprotected"),
                "which is what the old verdict told the owner of a tag that is gated"
            )
        }

        XCTAssertEqual(faults.report.swallowed.count, 1, "the AUTH0 write did reach the chip")

        // The claim the old verdict made, checked against the tag.
        sim.beginActivation()
        XCTAssertTrue(sim.configuration.isProtected, "the gate is up, which is why provenOpen was wrong")
        XCTAssertEqual(sim.storedKey, key, "and the key that opens it is the one the caller supplied")
    }

    /// The other half: a tag that really is still open is still reported open,
    /// and now the chip is what says so. The recorded `.gateProven` step is the
    /// difference, because the old code reached the same verdict without asking.
    func test_enable_aDroppedAuth0WriteReportsAnOpenGateTheChipItselfConfirmed() async throws {
        let sim = MifareUltralightCSimulator()
        let faults = FaultInjectingSessionFactory(chip: sim)
        faults.arm(TagFault(.write(page: UltralightCLayout.auth0Page), .dropped))

        do {
            try await driver(faulting: faults).enable(
                key: newKey(), protectFromPage: 4, readProtect: false, currentKey: .factoryDefault
            )
            XCTFail("a dropped AUTH0 write must throw")
        } catch let error as TagError {
            guard case .protectionIncomplete(let residue) = error.kind else {
                return XCTFail("expected .protectionIncomplete, got \(error.kind)")
            }
            XCTAssertEqual(residue.gate, .provenOpen)
            XCTAssertTrue(
                residue.completed.contains(.gateProven),
                "provenOpen here has to come from the read-back, not from the read taken on the way in"
            )
        }

        sim.beginActivation()
        XCTAssertEqual(sim.configuration.auth0, UltralightCLayout.protectionOff)
    }

    /// And when the chip will not answer the question, nothing is claimed. The
    /// AUTH0 write goes nowhere and neither does the read that would settle it,
    /// so the honest report is that the owner should keep the key and try again.
    func test_enable_anAuth0AbortWhoseReReadCannotBeTakenClaimsNothing() async throws {
        let sim = MifareUltralightCSimulator()
        let faults = FaultInjectingSessionFactory(chip: sim)
        faults.arm(
            TagFault(.write(page: UltralightCLayout.auth0Page), .dropped),
            // Occurrence 2: the first read of this page is the configuration read
            // `enable` opens with, the second is the catch's re-read.
            TagFault(.read(page: UltralightCLayout.lockBytes23Page), .dropped, on: .nth(2))
        )

        do {
            try await driver(faulting: faults).enable(
                key: newKey(), protectFromPage: 4, readProtect: false, currentKey: .factoryDefault
            )
            XCTFail("a dropped AUTH0 write must throw")
        } catch let error as TagError {
            guard case .protectionIncomplete(let residue) = error.kind else {
                return XCTFail("expected .protectionIncomplete, got \(error.kind)")
            }
            XCTAssertEqual(residue.gate, .unknown)
            XCTAssertFalse(residue.completed.contains(.gateProven), "nothing witnessed the gate either way")
            XCTAssertEqual(
                String(localized: error.userMessage),
                String(localized: ProtectionResidue(
                    family: .ultralightC, intent: .enable, gate: .unknown, credential: .callerSupplied
                ).userMessage)
            )
        }
    }

    // MARK: - removing

    /// R5. Once AUTH0 reads back open the removal has succeeded, so a failed key
    /// restore is residue and never a thrown error.
    func test_disable_abortDuringTheKeyRestore_reportsSuccessWithResidue() async throws {
        let sim = MifareUltralightCSimulator()
        let key = try newKey()
        try await driver(sim).enable(
            key: key, protectFromPage: 4, readProtect: false, currentKey: .factoryDefault
        )
        sim.beginActivation()

        let residue = try await aborting(sim, beforeWriteToPage: 45).disable(currentKey: key)

        XCTAssertEqual(residue.gate, .provenOpen, "the gate is down and was read back down")
        XCTAssertTrue(residue.metItsGoal, "which is the whole of what removing protection promises")
        guard case .unknown(let reason) = residue.credential else {
            return XCTFail("expected an unknown credential verdict, got \(residue.credential)")
        }
        XCTAssertTrue(reason.contains("key restore"), "the residue must name the key restore")
        XCTAssertTrue(residue.failures.contains { $0.step == .credentialWritten })
        XCTAssertFalse(sim.configuration.isProtected)
    }

    /// Every abort at or after the AUTH0 write returns rather than throws.
    func test_disable_neverThrowsOnceTheGateIsDown() async throws {
        let key = try newKey()
        for page in [UltralightCLayout.auth1Page] + Array(UltralightCLayout.keyPages) {
            let sim = MifareUltralightCSimulator()
            try await driver(sim).enable(
                key: key, protectFromPage: 4, readProtect: false, currentKey: .factoryDefault
            )
            sim.beginActivation()

            let residue = try await aborting(sim, beforeWriteToPage: page).disable(currentKey: key)
            XCTAssertEqual(residue.gate, .provenOpen, "abort before page \(page)")
            XCTAssertFalse(sim.configuration.isProtected, "abort before page \(page)")
        }
    }

    /// The mirror image: an abort **before** the gate comes down must throw, and
    /// must say the credential has not been touched.
    func test_disable_abortBeforeTheGateComesDown_throwsAndKeepsTheCredential() async throws {
        let sim = MifareUltralightCSimulator()
        let key = try newKey()
        try await driver(sim).enable(
            key: key, protectFromPage: 4, readProtect: false, currentKey: .factoryDefault
        )
        sim.beginActivation()

        do {
            try await aborting(sim, beforeWriteToPage: UltralightCLayout.auth0Page)
                .disable(currentKey: key)
            XCTFail("an abort before the gate came down must not report success")
        } catch is TagError {
            sim.beginActivation()
            XCTAssertTrue(sim.configuration.isProtected, "the tag is still gated")
            XCTAssertEqual(sim.storedKey, key, "and still holds the caller's key")
        }
    }

    /// R3, the row nothing used to reach. The AUTH0 read-back is the success
    /// criterion, and a bare `try` collapsed two different answers into one: a
    /// read that says the gate is still armed, and a read that does not answer
    /// at all. The second threw a transport error straight past the residue, so
    /// a removal whose AUTH0 write had already landed came back as "lost the
    /// tag" with no record that the gate was disarmed and no record that the key
    /// had not been touched.
    ///
    /// Both answers are now stated, and they are not the same answer: an
    /// unanswered read may not be reported as "removal did not open the gate",
    /// which on this tag would be false.
    func test_disable_aLostReadBackReportsAnUnconfirmedRemovalNotALostTag() async throws {
        let sim = MifareUltralightCSimulator()
        let key = try newKey()
        try await driver(sim).enable(
            key: key, protectFromPage: 4, readProtect: false, currentKey: .factoryDefault
        )

        let faults = FaultInjectingSessionFactory(chip: sim)
        // Occurrence 2: the first read is the configuration read `disable` takes
        // after authenticating, the second is the criterion itself.
        faults.arm(TagFault(.read(page: UltralightCLayout.lockBytes23Page), .dropped, on: .nth(2)))

        do {
            try await driver(faulting: faults).disable(currentKey: key)
            XCTFail("a read-back that cannot be taken has not confirmed anything")
        } catch let error as TagError {
            guard case .protectionIncomplete(let residue) = error.kind else {
                return XCTFail("expected .protectionIncomplete, got \(error.kind)")
            }
            XCTAssertTrue(
                residue.completed.contains(.gateDisarmed),
                "the residue that survives has to name the AUTH0 write that did land"
            )
            XCTAssertEqual(residue.gate, .unknown, "nothing read it back")
            XCTAssertEqual(residue.credential, .unchanged, "the restore never ran, so the caller keeps the key")
            XCTAssertTrue(residue.failures.contains { $0.step == .gateProven })
            XCTAssertFalse(
                residue.failures.contains { $0.diagnostics.contains("still shows the gate armed") },
                "that is the other answer, and on this tag it would be false"
            )
            XCTAssertEqual(
                String(localized: error.userMessage),
                String(localized: ProtectionResidue(
                    family: .ultralightC, intent: .disable, gate: .unknown, credential: .unchanged
                ).userMessage)
            )
            XCTAssertNotEqual(
                String(localized: error.userMessage),
                String(localized: TagError.tagLost().userMessage),
                "the gate is down and the key is the caller's; 'lost the tag' describes neither"
            )
        }

        // Both halves of what the residue said, checked against the tag.
        sim.beginActivation()
        XCTAssertFalse(sim.configuration.isProtected, "the gate really did come down")
        XCTAssertEqual(sim.storedKey, key, "and the key really was left alone")
    }

    /// The other answer, and the one the negative assertion above is written
    /// against: read back, and still armed.
    ///
    /// "An ACK is not proof" in its exact shape. The AUTH0 write is answered with
    /// the chip's own `0A` without the chip seeing the frame, so the driver is
    /// told the gate came down and it did not. The criterion read then says so,
    /// and until this branch filed the reading it holds, this outcome and the lost
    /// read-back above produced an identical residue and an identical sentence.
    ///
    /// On this family "nothing has been lost" is literally true: the key restore
    /// runs strictly after the criterion, so a removal that stops here has not
    /// touched the key.
    func test_disable_anAckThatDidNotTakeReportsTheGateItReadBack() async throws {
        let sim = MifareUltralightCSimulator()
        let key = try newKey()
        try await driver(sim).enable(
            key: key, protectFromPage: 4, readProtect: false, currentKey: .factoryDefault
        )

        let faults = FaultInjectingSessionFactory(chip: sim)
        // `.refused` returns the stated bytes without forwarding the frame, so this
        // is a real `0A` over a write that never reached the chip. Armed on the
        // removal's own driver: the setup `enable` above runs on the plain one.
        faults.arm(TagFault(
            .write(page: UltralightCLayout.auth0Page),
            .refused(response: Data([0x0A]), halts: false)
        ))

        do {
            try await driver(faulting: faults).disable(currentKey: key)
            XCTFail("the gate is still armed, so the removal has not succeeded")
        } catch let error as TagError {
            guard case .protectionIncomplete(let residue) = error.kind else {
                return XCTFail("expected .protectionIncomplete, got \(error.kind)")
            }
            XCTAssertEqual(
                residue.gate, .provenArmed(fromPage: 4),
                "`readConfiguration` returned AUTH0 and it said page 4, so that is what is filed"
            )
            XCTAssertEqual(residue.credential, .unchanged, "the key restore runs after the criterion")
            XCTAssertTrue(
                residue.failures.contains { $0.diagnostics.contains("still shows the gate armed") },
                "this is the branch the sibling test asserts it is not in"
            )
            XCTAssertEqual(
                String(localized: error.userMessage),
                String(localized: ProtectionResidue(
                    family: .ultralightC,
                    intent: .disable,
                    gate: .provenArmed(fromPage: 4),
                    credential: .unchanged
                ).userMessage)
            )
        }

        // Still protected, and still holding the caller's key.
        sim.beginActivation()
        XCTAssertTrue(sim.configuration.isProtected, "the gate never came down")
        XCTAssertEqual(sim.storedKey, key)
    }

    // MARK: - The read gate this app cannot undo

    /// A read gate is refused before a single frame goes out.
    ///
    /// On an Ultralight C the gate covers pages 28h-2Bh, which are the pages
    /// `ChipCatalog.identify(preEV1PageZero:configPages:)` reads to recognise the
    /// chip. Both answers a gated tag can give lose it: a NAK leaves the config
    /// pages nil and a roll-over trips the echo guard, and either way there is no
    /// profile, so no `protectionStyle`, so no unlock route. The key the user
    /// wrote down could never be presented again.
    ///
    /// Same decision and the same shape as SLIX2 privacy mode, where
    /// `Iso15693ProtectionClient.enable` refuses a read password without
    /// `armPrivacyIrreversibly`.
    func test_enable_refusesAReadGateWithoutTheExplicitOptIn() async throws {
        let sim = MifareUltralightCSimulator()
        let wire = RecordingLink(sim)
        let key = try newKey()

        do {
            _ = try await UltralightCProtectionDriver(transceive: wire.transceive).enable(
                key: key, protectFromPage: 4, readProtect: true, currentKey: .factoryDefault
            )
            XCTFail("a read gate this app cannot undo must not be armed by an ordinary protect")
        } catch let error as TagError {
            XCTAssertEqual(error.kind, .protocolError, "the app is declining, the tag is not refusing")
            XCTAssertNotEqual(
                String(localized: error.userMessage),
                String(localized: TagError.capabilityUnsupported(.tripleDESAuth).userMessage),
                "\"This tag does not support that operation\" would be false: it supports it fine"
            )
        }

        XCTAssertTrue(wire.frames.isEmpty, "refused before a single frame goes out")
        XCTAssertFalse(sim.configuration.isProtected, "and the tag is untouched")
    }

    /// The opt-in still works, so the refusal is a policy and not a capability
    /// this driver has lost. Nothing in the shipping app passes it.
    func test_enable_armsTheReadGateWhenTheCallerOwnsTheRecovery() async throws {
        let sim = MifareUltralightCSimulator()
        let key = try newKey()

        _ = try await driver(sim).enable(
            key: key,
            protectFromPage: 4,
            readProtect: true,
            currentKey: .factoryDefault,
            armReadGateUnrecoverably: true
        )

        XCTAssertTrue(sim.configuration.isProtected)
    }

    private func opens(_ sim: MifareUltralightCSimulator, with key: UltralightCKey) async -> Bool {
        await (try? driver(sim).authenticate(key: key)) != nil
    }
}

/// Records every frame that reaches the chip, so a test can assert that none did.
private final class RecordingLink: @unchecked Sendable {
    private let sim: MifareUltralightCSimulator
    private(set) var frames: [Data] = []

    init(_ sim: MifareUltralightCSimulator) {
        self.sim = sim
    }

    @Sendable
    func transceive(_ command: RawCommand) async throws -> Data {
        frames.append(command.bytes)
        return sim.handle(command: command.bytes)
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

private actor PageRecorder {
    private(set) var writes: [(page: Int, value: UInt8)] = []
    func record(page: Int, value: UInt8) {
        writes.append((page, value))
    }
}
