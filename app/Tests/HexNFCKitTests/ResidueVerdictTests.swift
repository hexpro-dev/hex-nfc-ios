@testable import HexNFCKit
import HexNFCRecords
@testable import HexNFCTagSim
import XCTest

/// What the **report** says, as opposed to what the residue records.
///
/// Every other suite on this branch asserts residue fields. This one asserts the
/// sentence the owner of the tag actually reads, because that is the artefact
/// they act on and it is where the fields turn back into a claim about a tag.
/// The bug this exists for: `userMessage` switched on `(intent, gate)` and
/// ignored `credential`, so four abort points printed "The password was saved to
/// the tag" over verdicts that said the credential was unchanged, half written,
/// or unknown. On an Ultralight C or an NTAG424 that is an instruction to keep a
/// key the tag may not hold.
final class ResidueVerdictTests: XCTestCase {
    private let onTag = Data([0xA1, 0xB2, 0xC3, 0xD4])
    private let pack = Data([0x56, 0x78])
    private let newPassword = Data([0x0A, 0x0B, 0x0C, 0x0D])
    private let newPack = Data([0x1E, 0x2F])

    /// The copy for one verdict triple, built the same way production builds it.
    private func message(
        _ family: ProtectionResidue.Family,
        _ intent: ProtectionResidue.Intent,
        gate: ProtectionResidue.GateVerdict,
        credential: ProtectionResidue.CredentialVerdict
    ) -> String {
        String(localized: ProtectionResidue(
            family: family, intent: intent, gate: gate, credential: credential
        ).userMessage)
    }

    // MARK: - The table

    /// Every credential verdict an un-armed gate can be reported with says
    /// something different, and only one of them says the password was saved.
    ///
    /// Spelled out in English rather than by construction, because the whole
    /// point of the finding is that these four states were being described by
    /// one sentence.
    func test_anEnableThatLeftTheGateOpenSaysWhichCredentialTheTagHolds() {
        XCTAssertEqual(
            message(.type2, .enable, gate: .provenOpen, credential: .callerSupplied),
            "The password was saved to the tag, but protection did not switch on. "
                + "Hold the tag against the phone again to finish."
        )
        XCTAssertEqual(
            message(.type2, .enable, gate: .provenOpen, credential: .unchanged),
            "The tag is still unprotected, and the password you entered was not saved to it. "
                + "Hold the tag against the phone again to try again."
        )
        XCTAssertEqual(
            message(.ultralightC, .enable, gate: .provenOpen, credential: .unknown(reason: "torn")),
            "The tag is still unprotected, and this app could not confirm which password it now "
                + "holds. Keep both the password you entered and the one it had before, then hold "
                + "the tag against the phone again."
        )
        XCTAssertEqual(
            message(.type4, .enable, gate: .unknown, credential: .unknown(reason: "either key")),
            "Couldn't confirm that protection switched on, or which password the tag now holds. "
                + "Keep both the password you entered and the one it had before, then hold the tag "
                + "against the phone again."
        )
        // And the four are genuinely four.
        let sentences = Set([
            message(.type2, .enable, gate: .provenOpen, credential: .callerSupplied),
            message(.type2, .enable, gate: .provenOpen, credential: .unchanged),
            message(.type2, .enable, gate: .provenOpen, credential: .unknown(reason: "")),
            message(.type2, .enable, gate: .unknown, credential: .unknown(reason: "")),
        ])
        XCTAssertEqual(sentences.count, 4)
    }

    /// A removal is reported on its gate alone, and that is deliberate: the tag
    /// enforces nothing either way, and the credential residue is the app's own
    /// bookkeeping rather than news for the user.
    func test_aRemovalIsReportedOnTheGateWhateverBecameOfTheCredential() {
        for credential: ProtectionResidue.CredentialVerdict in [
            .unchanged, .factoryDefault, .callerSupplied, .unknown(reason: "PWD reset did not complete"),
        ] {
            XCTAssertEqual(
                message(.type2, .disable, gate: .provenOpen, credential: credential),
                "Password removed."
            )
        }
    }

    // MARK: - Type-2, at the abort points

    /// The site the review named: a refused PWD write on a tag that arrived
    /// un-armed. Nothing was written, and the message must not say it was.
    func test_type2_refusedPasswordWrite_doesNotClaimThePasswordWasSaved() async throws {
        let layout = try XCTUnwrap(Type2ConfigLayout.for(.ntag213))
        let sim = NTAG213Simulator()
        let faults = FaultInjectingSessionFactory(chip: sim)
        faults.arm(TagFault(.write(page: layout.pwdPage), .type2NAK))
        let tag = try await faults.makeSession().start(alert: "")

        do {
            _ = try await tag.enableProtection(
                .type2(
                    password: onTag, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
                ),
                replacing: nil
            )
            XCTFail("a refused PWD write must throw")
        } catch let error as TagError {
            guard case .protectionIncomplete(let residue) = error.kind else {
                return XCTFail("expected protectionIncomplete, got \(error.kind)")
            }
            XCTAssertEqual(residue.credential, .unchanged, "not one credential byte reached the tag")
            XCTAssertEqual(residue.gate, .provenOpen, "and the gate was read, so it may be named")
            XCTAssertEqual(
                String(localized: error.userMessage),
                message(.type2, .enable, gate: .provenOpen, credential: .unchanged)
            )
            XCTAssertNotEqual(
                String(localized: error.userMessage),
                message(.type2, .enable, gate: .provenOpen, credential: .callerSupplied),
                "the sentence about a saved password belongs to the state where one was saved"
            )
        }

        sim.beginActivation()
        XCTAssertEqual(try sim.readProtectionState(), TagProtection.none)
    }

    /// The half-written credential. The PWD landed and the PACK did not, so the
    /// tag answers the new password: "the password you entered was not saved"
    /// would be as wrong as "it was saved".
    func test_type2_refusedPackWrite_reportsTheCredentialAsUndetermined() async throws {
        let layout = try XCTUnwrap(Type2ConfigLayout.for(.ntag213))
        let sim = NTAG213Simulator()
        let faults = FaultInjectingSessionFactory(chip: sim)
        faults.arm(TagFault(.write(page: layout.packPage), .type2NAK))
        let tag = try await faults.makeSession().start(alert: "")

        do {
            _ = try await tag.enableProtection(
                .type2(
                    password: onTag, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
                ),
                replacing: nil
            )
            XCTFail("a refused PACK write must throw")
        } catch let error as TagError {
            guard case .protectionIncomplete(let residue) = error.kind else {
                return XCTFail("expected protectionIncomplete, got \(error.kind)")
            }
            guard case .unknown = residue.credential else {
                return XCTFail("expected an undetermined credential, got \(residue.credential)")
            }
            XCTAssertEqual(
                String(localized: error.userMessage),
                message(.type2, .enable, gate: .provenOpen, credential: .unknown(reason: "")),
                "keep both passwords: the tag holds one of them and cannot be asked which"
            )
        }

        // The tag really does answer the new password, which is why the message
        // may not say it was never saved.
        sim.beginActivation()
        XCTAssertNoThrow(try sim.authenticate(password: onTag))
    }

    // MARK: - Ultralight C

    /// The abort `UltralightCAbortRecoveryTests` already covers, asserted on the
    /// report rather than on the residue: the key write stopped part way, the
    /// residue says the tag may hold neither key, and the message used to say
    /// the password had been saved.
    func test_ultralightC_tornKeyWrite_tellsTheOwnerToKeepBothKeys() async throws {
        let sim = MifareUltralightCSimulator()
        let key = try UltralightCKey(cipherOrder: Data((0 ..< 16).map { UInt8(0xA0 &+ $0) }))
        let counter = Counter()
        let driver = UltralightCProtectionDriver(transceive: { command in
            let bytes = [UInt8](command.bytes)
            // The second key page write never lands: the tag was lifted off.
            if bytes.count >= 2, bytes[0] == 0xA2, Int(bytes[1]) == UltralightCLayout.keyPages.lowerBound + 1,
               await counter.next() >= 1
            {
                throw TagError.tagLost(diagnostics: "test abort mid-key")
            }
            return sim.handle(command: command.bytes)
        })

        do {
            try await driver.enable(
                key: key, protectFromPage: 4, readProtect: false, currentKey: .factoryDefault
            )
            XCTFail("a torn key write must throw")
        } catch let error as TagError {
            guard case .protectionIncomplete(let residue) = error.kind else {
                return XCTFail("expected protectionIncomplete, got \(error.kind)")
            }
            guard case .unknown = residue.credential else {
                return XCTFail("expected an undetermined credential, got \(residue.credential)")
            }
            XCTAssertEqual(residue.gate, .provenOpen, "which was read, twice, before the key was touched")
            XCTAssertEqual(
                String(localized: error.userMessage),
                message(.ultralightC, .enable, gate: .provenOpen, credential: .unknown(reason: "")),
                "the message and the credential verdict on the same object have to agree"
            )
        }
    }

    /// M4. An Ultralight C key cannot be proven in the activation that wrote it
    /// (MF0ICU2 rev 3.3 §7.5.7 remark), so requiring that proof made every clean
    /// protect report `metItsGoal == false` for ever, and `WriteFlowModel` filed
    /// each one as an apply still in flight.
    func test_ultralightC_aCleanProtectMeetsItsGoal() async throws {
        let sim = MifareUltralightCSimulator()
        let key = try UltralightCKey(cipherOrder: Data((0 ..< 16).map { UInt8(0xA0 &+ $0) }))
        let driver = UltralightCProtectionDriver(transceive: { command in sim.handle(command: command.bytes) })

        let residue = try await driver.enable(
            key: key, protectFromPage: 4, readProtect: false, currentKey: .factoryDefault
        )

        XCTAssertTrue(residue.completed.contains(.credentialWritten))
        XCTAssertTrue(residue.completed.contains(.gateProven), "the gate read back armed")
        XCTAssertTrue(
            residue.metItsGoal,
            "the gate read-back is the criterion; the credential proof this family cannot take is not"
        )
        XCTAssertFalse(
            residue.isComplete,
            "and the proof it could not take is still recorded, so nothing is being papered over"
        )
        XCTAssertEqual(String(localized: residue.userMessage), "Password set.")
    }

    /// The Ultralight C twin of S1 below, and the same rule: **nothing after the
    /// success criterion may report a failure.**
    ///
    /// By the time this read is taken the key, AUTH1 and AUTH0 have all been
    /// written and acknowledged, so the tag is gated behind the caller's new key.
    /// The read was a bare `try`, so a slip during the proof threw `.tagLost` and
    /// discarded the residue: the owner was told the app had lost a tag that is
    /// protected with the key they had just entered, and had no reason to keep
    /// it. It is a missing proof, not a failed operation.
    func test_ultralightC_losingTheConfirmingReadBack_reportsAnUnprovenGateNotALostTag() async throws {
        let sim = MifareUltralightCSimulator()
        let key = try UltralightCKey(cipherOrder: Data((0 ..< 16).map { UInt8(0xA0 &+ $0) }))
        let faults = FaultInjectingSessionFactory(chip: sim)
        // Occurrence 2: the first read of this page is the configuration read
        // `enable` opens with, the second is the confirming read-back.
        faults.arm(TagFault(.read(page: UltralightCLayout.lockBytes23Page), .dropped, on: .nth(2)))
        let tag = try await faults.makeSession().start(alert: "")
        let driver = UltralightCProtectionDriver(transceive: { try await tag.transceive($0) })

        let residue = try await driver.enable(
            key: key, protectFromPage: 4, readProtect: false, currentKey: .factoryDefault
        )

        XCTAssertTrue(residue.completed.contains(.gateArmed), "AUTH0 landed and was acknowledged")
        XCTAssertEqual(residue.credential, .callerSupplied)
        XCTAssertEqual(residue.gate, .unknown, "and nothing witnessed it")
        XCTAssertTrue(residue.failures.contains { $0.step == .gateProven })
        XCTAssertFalse(residue.metItsGoal, "an unproven gate is not a met criterion")
        XCTAssertEqual(
            String(localized: residue.userMessage),
            message(.ultralightC, .enable, gate: .unknown, credential: .callerSupplied)
        )
        XCTAssertNotEqual(
            String(localized: residue.userMessage),
            String(localized: TagError.tagLost().userMessage),
            "the tag is gated behind the new key; 'lost the tag' is what strands one"
        )

        // Which is exactly the tag the report has to describe.
        sim.beginActivation()
        XCTAssertTrue(sim.configuration.isProtected)
        XCTAssertEqual(sim.storedKey, key)
    }

    // MARK: - NTAG424, the gate it did not read

    /// B3, and the mirror of `Type2GateAttemptTests.test_aReKeyThatTearsDoesNotClaimTheGateIsOpen`.
    ///
    /// Re-keying an already-gated NTAG424 is a live production path
    /// (`WriteFlowModel` passes `replacing:`, which becomes `currentKeys`). The
    /// access rights are never touched until the arming ChangeFileSettings, so a
    /// tear before it leaves the file gated exactly as it arrived. `provenOpen`
    /// there is a protection state nothing read, and the diagnostics said so in
    /// words: "the NDEF file is still free, so nothing is gated."
    func test_ntag424_aReKeyThatTearsAtTheGateDoesNotClaimTheFileIsFree() async throws {
        let sim = NTAG424DNASimulator()
        let userKey = Data((0 ..< 16).map { UInt8(0xA0 &+ $0) })
        let nextKey = Data((0 ..< 16).map { UInt8(0x50 &+ $0) })
        let plain = NTAG424ProtectionDriver(transceive: { command in sim.handle(command: command.bytes) })
        try await plain.enable(aesKey: userKey, keySlot: 0, readProtect: false)
        sim.endSession()

        let counter = Counter()
        let tearing = NTAG424ProtectionDriver(transceive: { command in
            let bytes = [UInt8](command.bytes)
            // The arming ChangeFileSettings never lands.
            if bytes.count >= 2, bytes[0] == 0x90, bytes[1] == 0x5F, await counter.next() >= 1 {
                throw TagError.tagLost(diagnostics: "test abort before ChangeFileSettings")
            }
            return sim.handle(command: command.bytes)
        })

        do {
            try await tearing.enable(
                aesKey: nextKey, keySlot: 0, readProtect: false, currentKeys: [userKey]
            )
            XCTFail("a torn ChangeFileSettings must throw")
        } catch let error as TagError {
            guard case .protectionIncomplete(let residue) = error.kind else {
                return XCTFail("expected protectionIncomplete, got \(error.kind)")
            }
            XCTAssertEqual(
                residue.gate, .unknown,
                "this tag arrived gated and its access rights were never re-read"
            )
            XCTAssertFalse(
                error.diagnostics.lowercased().contains("still free"),
                "and the diagnostics may not state it either"
            )
        }

        // The claim the old verdict made, checked against the tag.
        sim.endSession()
        let after = try await plain.readState(keySlot: 0)
        XCTAssertTrue(after.isGated, "the file is still gated, which is why provenOpen was a fabrication")
    }

    /// The arming command is the one exception to "carry the reading forward",
    /// and it applies to a first-time protect too.
    ///
    /// A ChangeFileSettings that neither acknowledged nor stated a refusal may
    /// have landed, so the rights are either the free ones read at the top or
    /// the gate this command just wrote. Reporting the tag as free is the
    /// lost-ACK mistake CLAUDE.md names, on the command that decides whether the
    /// tag is protected at all.
    func test_ntag424_aFirstProtectThatTearsAtTheGateClaimsNeitherWay() async throws {
        let sim = NTAG424DNASimulator()
        let userKey = Data((0 ..< 16).map { UInt8(0xA0 &+ $0) })
        let counter = Counter()
        let tearing = NTAG424ProtectionDriver(transceive: { command in
            let bytes = [UInt8](command.bytes)
            if bytes.count >= 2, bytes[0] == 0x90, bytes[1] == 0x5F, await counter.next() >= 1 {
                throw TagError.tagLost(diagnostics: "test abort before ChangeFileSettings")
            }
            return sim.handle(command: command.bytes)
        })

        do {
            try await tearing.enable(aesKey: userKey, keySlot: 0, readProtect: false)
            XCTFail("a torn ChangeFileSettings must throw")
        } catch let error as TagError {
            guard case .protectionIncomplete(let residue) = error.kind else {
                return XCTFail("expected protectionIncomplete, got \(error.kind)")
            }
            XCTAssertEqual(residue.gate, .unknown, "the arming command's outcome is not known")
            XCTAssertEqual(residue.credential, .callerSupplied, "the key is on the tag, and was proven")
            XCTAssertEqual(
                String(localized: error.userMessage),
                message(.type4, .enable, gate: .unknown, credential: .callerSupplied)
            )
        }
    }

    /// And the other half of the rule, at an abort point where nothing has been
    /// asked of the access rights: the read at the top of `enable` still stands,
    /// so a tag that arrived free is reported free.
    func test_ntag424_aFailedProofOnAFreeTagStillReportsTheFileFree() async throws {
        let sim = NTAG424DNASimulator()
        let userKey = Data((0 ..< 16).map { UInt8(0xA0 &+ $0) })
        let counter = Counter()
        // The re-authentication that proves the new key never completes. The
        // ChangeKey before it did, and neither touches the access rights.
        let tearing = NTAG424ProtectionDriver(transceive: { command in
            let bytes = [UInt8](command.bytes)
            if bytes.count >= 2, bytes[0] == 0x90, bytes[1] == 0x71, await counter.next() >= 2 {
                throw TagError.tagLost(diagnostics: "test abort before the proof re-authentication")
            }
            return sim.handle(command: command.bytes)
        })

        do {
            try await tearing.enable(aesKey: userKey, keySlot: 0, readProtect: false)
            XCTFail("a failed proof must throw")
        } catch let error as TagError {
            guard case .protectionIncomplete(let residue) = error.kind else {
                return XCTFail("expected protectionIncomplete, got \(error.kind)")
            }
            XCTAssertEqual(residue.gate, .provenOpen, "the rights were read, and they said free")
            XCTAssertTrue(residue.failures.contains { $0.step == .credentialProven })
        }
    }

    /// A ChangeKey the chip refused, on a tag that arrived gated. Nothing on the
    /// tag changed, so the gate is where it was, and where it was is not
    /// something this path re-read.
    func test_ntag424_aRefusedReKeyDoesNotClaimTheFileIsFree() async throws {
        let sim = NTAG424DNASimulator()
        let userKey = Data((0 ..< 16).map { UInt8(0xA0 &+ $0) })
        let nextKey = Data((0 ..< 16).map { UInt8(0x50 &+ $0) })
        let plain = NTAG424ProtectionDriver(transceive: { command in sim.handle(command: command.bytes) })
        try await plain.enable(aesKey: userKey, keySlot: 0, readProtect: false)
        sim.endSession()

        let counter = Counter()
        let refusing = NTAG424ProtectionDriver(transceive: { command in
            let bytes = [UInt8](command.bytes)
            if bytes.count >= 2, bytes[0] == 0x90, bytes[1] == 0xC4, await counter.next() >= 1 {
                throw TagError.tagLost(diagnostics: "test: ChangeKey never reached the tag")
            }
            return sim.handle(command: command.bytes)
        })

        do {
            try await refusing.enable(
                aesKey: nextKey, keySlot: 0, readProtect: false, currentKeys: [userKey]
            )
            XCTFail("a refused ChangeKey must throw")
        } catch let error as TagError {
            guard case .protectionIncomplete(let residue) = error.kind else {
                return XCTFail("expected protectionIncomplete, got \(error.kind)")
            }
            XCTAssertEqual(residue.credential, .unchanged, "the chip still holds the key it had")
            XCTAssertEqual(residue.gate, .unknown, "and its gate was never re-read")
            XCTAssertFalse(error.diagnostics.lowercased().contains("still usable"))
        }
    }

    // MARK: - S1: the read-back that used to throw past the residue

    /// PWD, PACK, ACCESS and AUTH0 have all been written and acknowledged when
    /// the confirming read is taken. A slip there threw `.tagLost` and discarded
    /// the residue, so the owner was told the tag had been lost about a tag now
    /// armed with their new password, and the message written for exactly this
    /// state was unreachable.
    func test_enable_losingTheGateReadBack_reportsAnUnconfirmedGateNotALostTag() async throws {
        let layout = try XCTUnwrap(Type2ConfigLayout.for(.ntag213))
        let sim = NTAG213Simulator()
        let faults = FaultInjectingSessionFactory(chip: sim)
        // Occurrence 2: the first read of this page is the state read `enable`
        // opens with, the second is the confirming read-back.
        faults.arm(TagFault(.read(page: layout.config0Page), .dropped, on: .nth(2)))
        let tag = try await faults.makeSession().start(alert: "")

        do {
            _ = try await tag.enableProtection(
                .type2(
                    password: newPassword, pack: newPack,
                    protectFromPage: 4, readProtect: false, authLimit: 0
                ),
                replacing: nil
            )
            XCTFail("a read-back that cannot be taken is not a success")
        } catch let error as TagError {
            guard case .protectionIncomplete(let residue) = error.kind else {
                return XCTFail("expected protectionIncomplete, got \(error.kind)")
            }
            XCTAssertTrue(
                residue.completed.contains(.gateArmed),
                "the residue that survives has to name the AUTH0 write that did land"
            )
            XCTAssertEqual(residue.credential, .callerSupplied)
            XCTAssertEqual(residue.gate, .unknown, "nothing read it back")
            XCTAssertEqual(
                String(localized: error.userMessage),
                message(.type2, .enable, gate: .unknown, credential: .callerSupplied)
            )
            XCTAssertNotEqual(
                String(localized: error.userMessage),
                String(localized: TagError.tagLost().userMessage),
                "the tag is armed with the new password; 'lost the tag' is what stranded the last one"
            )
        }

        // And it really is armed, with the new credential.
        sim.beginActivation()
        XCTAssertEqual(try sim.readProtectionState()?.passwordProtect, true)
        XCTAssertEqual(try sim.authenticate(password: newPassword), newPack)
    }

    /// The same shape on a removal, where the read-back is the success criterion
    /// itself. The report has to be "couldn't confirm", never "lost the tag",
    /// and the residue naming ACCESS and AUTH0 has to survive.
    func test_disable_losingTheGateReadBack_reportsAnUnconfirmedRemoval() async throws {
        let layout = try XCTUnwrap(Type2ConfigLayout.for(.ntag213))
        let sim = NTAG213Simulator()
        try sim.enablePasswordProtection(
            password: onTag, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        sim.beginActivation()

        let faults = FaultInjectingSessionFactory(chip: sim)
        // `.fromNth(2)`, not `.nth(2)`: the criterion read now costs two attempts,
        // because a single lost frame there used to throw a removal that had
        // already disarmed the gate into "couldn't confirm". To reach the genuinely
        // unconfirmed state the read has to stay unavailable, which is exactly what
        // a chip halted by the previous frame does.
        faults.arm(TagFault(.read(page: layout.config0Page), .dropped, on: .fromNth(2)))
        let tag = try await faults.makeSession().start(alert: "")

        do {
            _ = try await tag.disableProtection(using: .type2(password: onTag, pack: pack))
            XCTFail("a removal whose read-back was lost has not been confirmed")
        } catch let error as TagError {
            guard case .protectionIncomplete(let residue) = error.kind else {
                return XCTFail("expected protectionIncomplete, got \(error.kind)")
            }
            XCTAssertTrue(residue.completed.contains(.gateDisarmed))
            XCTAssertEqual(residue.credential, .unchanged, "the reset never ran, so keep the password")
            XCTAssertEqual(residue.gate, .unknown)
            XCTAssertEqual(
                String(localized: error.userMessage),
                message(.type2, .disable, gate: .unknown, credential: .unchanged)
            )
        }

        // The gate did come down, and the tag still holds the user's password:
        // both halves of what the residue said.
        sim.beginActivation()
        XCTAssertEqual(try sim.readProtectionState(), TagProtection.none)
        sim.beginActivation()
        XCTAssertEqual(try sim.authenticate(password: onTag), pack)
    }

    // MARK: - One unlucky frame at the criterion

    /// Modelled on the 2026-09-09 NTAG213 capture, and the reason the criterion
    /// read takes a follow-up.
    ///
    /// The tap that produced this: ACCESS and AUTH0 were both written and both
    /// ACKed, then the read-back's `30 29` came back as a single byte, `1F`, on a
    /// clean 6.5 ms callback with no adjacent error line. This stages the byte on
    /// the read-back's page-3 probe instead, where `readPages` now asks again
    /// itself, so it is absorbed there. `ShortReadLengthTests` replays it on the
    /// frame it actually answered, where the read-back's follow-up absorbs it. The
    /// whole removal was
    /// reported as "Couldn't confirm whether the password was removed", the
    /// PWD/PACK tidy-up never ran, and the flow model's own free second read-back
    /// in the same activation never ran either, because the driver had thrown.
    ///
    /// The byte is replayed here and nowhere else, and nothing branches on it.
    /// It is one observed value from one phone, it is not any documented NTAG21x
    /// NAK, and `halts: false` is a modelling choice: the capture ended there. A READ mutates nothing
    /// and spends no authentication attempt, so the follow-up is free.
    func test_disable_aSingleShortAnswerAtTheCriterionIsRetriedAndTheRemovalCompletes() async throws {
        let sim = NTAG213Simulator()
        try sim.enablePasswordProtection(
            password: onTag, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        sim.beginActivation()

        let faults = FaultInjectingSessionFactory(chip: sim)
        // Occurrence 1 is the state read `disable` opens with; occurrence 2 is the
        // criterion read's page-3 probe. Occurrence 3 is `readPages`' own second
        // READ of the same page, unfaulted.
        faults.arm(TagFault(
            .read(page: Type2PasswordDriver.capabilityContainerPage),
            .refused(response: Data([0x1F]), halts: false),
            on: .nth(2)
        ))
        let tag = try await faults.makeSession().start(alert: "")

        let residue = try await tag.disableProtection(using: .type2(password: onTag, pack: pack))

        XCTAssertEqual(
            residue.gate, .provenOpen,
            "the follow-up read took, and it is the read-back that is the success criterion"
        )
        XCTAssertTrue(residue.metItsGoal, "a removal whose gate reads open has met its goal")
        XCTAssertEqual(
            residue.credential, .factoryDefault,
            "and because the criterion was met, the tidy-up ran: the tag holds the delivery password"
        )

        sim.beginActivation()
        XCTAssertEqual(try sim.readProtectionState(), TagProtection.none)
        sim.beginActivation()
        XCTAssertEqual(try sim.authenticate(password: Type2Credential.factoryPassword), Type2Credential.factoryPack)
    }

    // MARK: - Read back, and still armed

    /// "An ACK is not proof" in its exact shape, and the one verdict this app
    /// could never previously produce.
    ///
    /// The AUTH0 write is answered with the chip's own `0A` without the chip
    /// seeing the frame, so the driver is told the gate came down and the gate did
    /// not. The criterion read then says so. Before this branch existed, "the gate
    /// could not be read" and "the gate was read and is still armed" produced an
    /// identical residue and an identical sentence, and the copy written for the
    /// second had no producer anywhere in the app.
    ///
    /// What the user moves from and to: "Couldn't confirm whether the password was
    /// removed." becomes a sentence that says the tag is still protected and
    /// nothing has been lost. Both send them back for a tap; only one is true.
    func test_disable_anAckThatDidNotTakeReportsTheGateItReadBack() async throws {
        let layout = try XCTUnwrap(Type2ConfigLayout.for(.ntag213))
        let sim = NTAG213Simulator()
        try sim.enablePasswordProtection(
            password: onTag, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        sim.beginActivation()

        let faults = FaultInjectingSessionFactory(chip: sim)
        // `.refused` does not forward the frame to the chip, so this is a real `0A`
        // over a write that never happened. No invented byte, no invented refusal.
        faults.arm(TagFault(
            .write(page: layout.config0Page),
            .refused(response: Data([Type2PasswordDriver.ack]), halts: false)
        ))
        let tag = try await faults.makeSession().start(alert: "")

        do {
            _ = try await tag.disableProtection(using: .type2(password: onTag, pack: pack))
            XCTFail("the gate is still armed, so the removal has not succeeded")
        } catch let error as TagError {
            guard case .protectionIncomplete(let residue) = error.kind else {
                return XCTFail("expected protectionIncomplete, got \(error.kind)")
            }
            XCTAssertEqual(
                residue.gate, .provenArmed(fromPage: 4),
                "the driver read AUTH0 back and it said page 4, so that is what it files"
            )
            XCTAssertTrue(
                residue.completed.contains(.gateDisarmed),
                "the write was ACKed, so the driver believed it landed: that is the whole premise"
            )
            XCTAssertEqual(residue.credential, .unchanged, "the tidy-up may not run on an unproven gate")
            XCTAssertFalse(residue.metItsGoal, "`.disable` requires `.provenOpen`, and this is not it")
            XCTAssertEqual(
                String(localized: error.userMessage),
                message(.type2, .disable, gate: .provenArmed(fromPage: 4), credential: .unchanged),
                "the user gets the still-protected sentence, not the couldn't-confirm one"
            )
            XCTAssertNotEqual(
                String(localized: error.userMessage),
                message(.type2, .disable, gate: .unknown, credential: .unchanged),
                "and the two are pinned apart, which is the point of the branch"
            )
        }

        // Still protected, and still holding the user's own password.
        sim.beginActivation()
        XCTAssertEqual(try sim.readProtectionState()?.passwordProtect, true)
        sim.beginActivation()
        XCTAssertEqual(try sim.authenticate(password: onTag), pack)
    }

    /// The sibling branch, pinned apart from the one above.
    ///
    /// Gated reads prove the gate is armed and prove nothing about the page it
    /// starts from. `provenArmed` carries a page, so `.unknown` stands rather than
    /// an invented number. This is the same choice `enable` already makes, and it
    /// is why the two branches file different verdicts off the same failure.
    ///
    /// **This test passes before and after the fix**, because the branch it covers
    /// used to fall through the same guard and filed `.unknown` by accident rather
    /// than by decision. It is here so the two outcomes cannot drift back together:
    /// the temptation, once one branch files a page, is to file one here too.
    func test_disable_configPagesStillGatedFilesNoPage() async throws {
        let layout = try XCTUnwrap(Type2ConfigLayout.for(.ntag213))
        let sim = NTAG213Simulator()
        try sim.enablePasswordProtection(
            password: onTag, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        sim.beginActivation()

        let faults = FaultInjectingSessionFactory(chip: sim)
        faults.arm(TagFault(
            .write(page: layout.config0Page),
            .refused(response: Data([Type2PasswordDriver.ack]), halts: false)
        ))
        // From the criterion read onwards the tag rolls over to page 0 instead of
        // serving the page it was asked for, which is how a read-gated Type-2 chip
        // declines (`Type2LockReadTests.test_rolledOverStaticReplyIsRejected` builds
        // the same reply for the same reason). The bytes are derived from the
        // production helper rather than typed out, so nothing here is invented: a
        // 16-byte reply carrying `SN0 SN1 SN2 BCC0 SN3 SN4 SN5 SN6 BCC1` where
        // pages 0, 1 and 2 would land is exactly what `detectReadProtection` looks
        // for. `.refused` is the seam that returns stated bytes without forwarding
        // the frame; the bytes themselves are a roll-over, not a refusal code.
        let signature = try XCTUnwrap(Type2Rollover.signature(forUID: NTAG213Simulator.defaultUID))
        var rolledOver = Data(repeating: 0x00, count: 16)
        rolledOver.replaceSubrange(Type2Rollover.signatureRange, with: signature)
        faults.arm(TagFault(
            .read(page: Type2PasswordDriver.capabilityContainerPage),
            .refused(response: rolledOver, halts: false),
            on: .fromNth(2)
        ))
        let tag = try await faults.makeSession().start(alert: "")

        do {
            _ = try await tag.disableProtection(using: .type2(password: onTag, pack: pack))
            XCTFail("the configuration could not be re-read, so nothing is confirmed")
        } catch let error as TagError {
            guard case .protectionIncomplete(let residue) = error.kind else {
                return XCTFail("expected protectionIncomplete, got \(error.kind)")
            }
            XCTAssertEqual(
                residue.gate, .unknown,
                "gated reads prove the gate is up and prove nothing about the page it starts from"
            )
            XCTAssertEqual(residue.credential, .unchanged)
        }
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
