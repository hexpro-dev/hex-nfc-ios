@testable import HexNFCApp
@testable import HexNFCKit
@testable import HexNFCRecords
import HexNFCStorage
@testable import HexNFCTagSim
import XCTest

/// The second tap that gets a stranded tag back.
///
/// ## The tag this exists for
///
/// On 2026-09-04 a password removal came apart in the middle. The gate went
/// down, the PWD reset to the delivery value was acknowledged, and then the tag
/// slipped on the PACK write, so the operation reported total failure. The tag
/// was unprotected and holding `FF FF FF FF` while the app went on presenting
/// the password its owner had chosen. Every retry earned a NAK, and a NAK halts
/// a Type-2 chip for the rest of the activation. The only way out was knowing to
/// type the delivery value by hand.
///
/// ## Why the trigger is not an error code
///
/// The obvious trigger is `TagError.kind == .authFailed`, and it would have been
/// green here and invisible on a phone. `Type2PasswordDriver.authenticate`
/// produces `.authFailed` only for a short *payload*; a transport error becomes
/// `.authInconclusive`, a NAK returns the chip to HALT, `CoreNFCSession` says
/// that reaches iOS "as a 1-byte payload or a transport error, depending on iOS
/// version", and the one live capture in `docs/internal/test-harness.md`
/// (2026-08-07, NTAG216) shows "Tag connection lost". `NTAG21xSimulator` returns
/// the payload form. So `test_theOfferSurvivesATransportLossOnTheAuthentication`
/// is the load-bearing test in this file: it drives the *other* shape through
/// the fault seam and requires the same offer.
///
/// The trigger is what the driver did instead: it read the tag's configuration,
/// found the gate armed, and put one `PWD_AUTH` on the wire. That arrives as a
/// failed `ProtectionResidue.Step.gateOpened`.
final class FactoryDefaultRecoveryTests: XCTestCase {
    private let onTag = Data([0xA1, 0xB2, 0xC3, 0xD4])
    private let pack = Data([0x56, 0x78])
    private let typed = Data([0xDE, 0xAD, 0xBE, 0xEF])

    // MARK: - The offer appears when a credential was actually presented

    /// A stated refusal: the simulator answers the wrong password with a 1-byte
    /// NAK, which the driver reports as `.authFailed`.
    @MainActor
    func test_aRefusedRemovalOffersTheFactoryDefault() async throws {
        let sim = NTAG213Simulator()
        try sim.enablePasswordProtection(
            password: onTag, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let model = removal(on: sim, presenting: typed)

        await runToCompletion(model)

        // The refusal reaches the prompt rather than an error card now: the
        // tap that writes runs the shared preamble, so a credential the tag will
        // not take is caught before the operation starts and the user is asked
        // for another one instead of being told the operation failed.
        XCTAssertEqual(model.phase, .needsUnlock, "got \(model.phase)")
        XCTAssertTrue(model.unlockFailed)
        XCTAssertEqual(
            model.unlockRefusal.map { String(localized: $0.userMessage) },
            String(localized: TagError.authFailed().userMessage),
            "carrying the residue out must not cost the user the plain 'Wrong password.' explanation"
        )
        XCTAssertEqual(
            model.recovery, .tryType2FactoryDefault,
            "a credential that went on the wire and did not open the tag earns the offer of a second tap"
        )
    }

    /// **The test the whole design turns on.** The password is the right one and
    /// the frame is simply lost, so the driver reports `.authInconclusive`, which
    /// is very possibly the only shape a phone ever produces for a refusal too.
    /// The offer must not depend on telling those two apart, because this repo
    /// cannot.
    @MainActor
    func test_theOfferSurvivesATransportLossOnTheAuthentication() async throws {
        let sim = NTAG213Simulator()
        try sim.enablePasswordProtection(
            password: onTag, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let faults = FaultInjectingSessionFactory(chip: sim)
        faults.arm(TagFault(.opcode(Type2PasswordDriver.pwdAuth), .dropped))
        // The credential the tag actually holds. Nothing here is wrong except
        // that the answer never arrived.
        let model = removal(factory: faults, presenting: onTag, pack: pack)

        await runToCompletion(model)

        XCTAssertEqual(model.phase, .needsUnlock, "a lost PWD_AUTH must not report success, got \(model.phase)")
        // Pins the shape this test is about. If the driver had reported
        // `.authFailed` here the message would read "Wrong password." and this
        // test would no longer be exercising the transport-loss path at all.
        XCTAssertEqual(
            model.unlockRefusal.map { String(localized: $0.userMessage) },
            String(localized: TagError.authInconclusive().userMessage),
            "a lost frame establishes nothing about the password, and the copy has to say so"
        )
        XCTAssertEqual(
            model.recovery, .tryType2FactoryDefault,
            "the offer must not be gated on TagError.kind: a phone may report every refusal as a lost tag"
        )
    }

    // MARK: - The offer stays away where nothing was presented

    /// `TagError.readProtected` carries kind `.authFailed` and is thrown by
    /// `readState` *before* any authentication. An error-code trigger would offer
    /// the recovery here and tell the user their tag is holding the delivery
    /// password, about a tag that refused no credential at all.
    @MainActor
    func test_aReadRefusalBeforeAnyAuthenticationOffersNothing() async throws {
        let layout = try XCTUnwrap(Type2ConfigLayout.for(.ntag213))
        let sim = NTAG213Simulator()
        try sim.enablePasswordProtection(
            password: onTag, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let faults = FaultInjectingSessionFactory(chip: sim)
        // The configuration read is refused, so the run stops before it can
        // present anything. `.every`, because both taps read it now: the
        // identify tap establishes the state the removal needs, and a fault
        // spent on tap 1 would leave tap 2 reading a perfectly good tag.
        faults.arm(TagFault(.read(page: layout.config0Page), .type2NAK, on: .every))
        let model = removal(factory: faults, presenting: typed)

        await runToCompletion(model)

        // Refused before anything was presented, so the run asks for a
        // credential rather than reporting one as wrong.
        XCTAssertEqual(model.phase, .needsUnlock, "got \(model.phase)")
        XCTAssertNil(
            model.recovery,
            "no credential was refused, so there is nothing to offer a second tap for"
        )
        XCTAssertFalse(
            faults.report.contains(.opcode(Type2PasswordDriver.pwdAuth)),
            "the removal must not have authenticated at all on this path"
        )
    }

    /// A tag whose `AUTH_LIM` the driver read armed cannot afford the offer.
    ///
    /// The second tap costs one more counted attempt, and the chip locks one
    /// past its limit for good. On 2026-09-10 this offer spent tag A's last try
    /// (`04:A9:DB:3A:D6:1F:90`, limit 1, 11:29:06) and the tag has refused its
    /// real password ever since. The limit is only ever non-nil because the
    /// driver read it off the tag before presenting anything, so this withholds
    /// on a reading rather than on a guess.
    @MainActor
    func test_aRefusalFromALimitedTagOffersNothing() async throws {
        let sim = NTAG213Simulator()
        try sim.enablePasswordProtection(
            password: onTag, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 1
        )
        let model = removal(on: sim, presenting: typed)

        await runToCompletion(model)

        XCTAssertEqual(model.phase, .needsUnlock, "got \(model.phase)")
        XCTAssertNil(
            model.recovery,
            "the app must not propose spending a counted try on a tag it has just read as limited"
        )
        XCTAssertFalse(
            sim.isAuthLocked,
            "the fixture must still be recoverable: a limit of 1 tolerates the one wrong try above"
        )
    }

    /// The other half of the rule. A read-protected tag hides `AUTH_LIM`, so its
    /// refusals carry no limit and keep the offer: the app cannot know either
    /// way, and the stranded tags this recovery exists for are unreadable by
    /// definition.
    @MainActor
    func test_aRefusalThatCouldNotReadTheLimitKeepsTheOffer() {
        var residue = ProtectionResidue(family: .type2, intent: .disable)
        residue.record(.stateRead)
        residue.record(failure: .gateOpened, "PWD_AUTH did not open the gate")

        XCTAssertEqual(
            OperationsFlowModel.recovery(
                after: TagError(
                    kind: .protectionIncomplete(residue),
                    userMessage: residue.userMessage,
                    diagnostics: residue.diagnostics
                ),
                presenting: .type2(password: typed, pack: Data())
            ),
            .tryType2FactoryDefault
        )
        XCTAssertNil(
            OperationsFlowModel.recovery(
                after: TagError(
                    kind: .protectionIncomplete(residue),
                    userMessage: residue.userMessage,
                    diagnostics: residue.diagnostics,
                    attemptLimit: 3
                ),
                presenting: .type2(password: typed, pack: Data())
            ),
            "a refusal carrying a limit is a reading of the tag, and it says this tap is not free"
        )
    }

    /// Closes the loop where the offer would propose re-sending the identical
    /// frame for ever.
    @MainActor
    func test_aRunThatAlreadyPresentedTheFactoryDefaultOffersNothing() {
        var residue = ProtectionResidue(family: .type2, intent: .disable)
        residue.record(.stateRead)
        residue.record(failure: .gateOpened, "PWD_AUTH did not open the gate")
        let refusal = TagError.protectionIncomplete(residue)

        XCTAssertEqual(
            OperationsFlowModel.recovery(
                after: refusal,
                presenting: .type2(password: typed, pack: Data())
            ),
            .tryType2FactoryDefault
        )
        XCTAssertNil(
            OperationsFlowModel.recovery(
                after: refusal,
                presenting: .type2(
                    password: Type2Credential.factoryPassword,
                    pack: Type2Credential.factoryPack
                )
            ),
            "offering the delivery password to a run that just presented it is offering the same frame twice"
        )
    }

    /// An `.authFailed` with no residue behind it establishes nothing about a
    /// credential, and must not reach the classifier's `true` branch by kind.
    @MainActor
    func test_aBareAuthFailureWithNoResidueOffersNothing() {
        XCTAssertNil(
            OperationsFlowModel.recovery(
                after: TagError.authFailed(diagnostics: "PWD_AUTH refused"),
                presenting: .type2(password: typed, pack: Data())
            ),
            "the trigger is the driver's report of what it sent, never the error kind"
        )
        XCTAssertNil(
            OperationsFlowModel.recovery(
                after: TagError.readProtected(diagnostics: "READ refused"),
                presenting: .type2(password: typed, pack: Data())
            )
        )
    }

    // MARK: - The tap itself

    @MainActor
    func test_theFactoryDefaultTapRemovesTheProtectionAndReportsIt() async throws {
        let sim = NTAG213Simulator()
        // The state a torn removal leaves: still armed, and holding the value
        // this app's own removal writes back.
        try sim.enablePasswordProtection(
            password: Type2Credential.factoryPassword,
            pack: Type2Credential.factoryPack,
            protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let model = removal(on: sim, presenting: typed)

        await runToCompletion(model)
        XCTAssertEqual(model.recovery, .tryType2FactoryDefault)

        model.retryWithFactoryDefault()
        XCTAssertEqual(model.phase, .idle, "the recovery tap starts the flow over, it does not resume it")
        XCTAssertTrue(model.presentsFactoryDefault)
        XCTAssertNil(model.recovery, "the offer is spent once it has been taken")

        await runToCompletion(model)

        guard case .done(.passwordRemoved) = model.phase else {
            return XCTFail("expected the removal to complete, got \(model.phase)")
        }
        XCTAssertTrue(model.didOpenGate, "this tap really did authenticate, so the success copy may say so")
        XCTAssertEqual(try sim.readProtectionState(), TagProtection.none, "the tag must come back unprotected")
    }

    /// A removal that finds the gate already open sends **no** `PWD_AUTH`
    /// (`Type2PasswordDriver.disable` skips it when `isGateArmed` is false), so
    /// nothing opened the tag and the success copy must not claim the delivery
    /// password did.
    @MainActor
    func test_aRemovalThatSentNoCredentialDoesNotClaimTheFactoryDefaultOpenedIt() async throws {
        let sim = NTAG213Simulator()
        try sim.enablePasswordProtection(
            password: Type2Credential.factoryPassword,
            pack: Type2Credential.factoryPack,
            protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let faults = FaultInjectingSessionFactory(chip: sim)
        let model = removal(factory: faults, presenting: typed)

        await runToCompletion(model)
        model.retryWithFactoryDefault()

        // Between the identify tap and the tap that writes, the tag turns out to
        // be ungated after all, which is precisely the incident's end state: a
        // removal that finished on the chip while reporting failure. The gap
        // between the two taps is where it has to be staged now, because the
        // identify tap refuses a removal it can read as unnecessary.
        let run = Task { await model.begin() }
        await until {
            if case .awaitingConfirmation = model.phase {
                return true
            }
            return false
        }
        sim.beginActivation()
        try sim.disablePasswordProtection(currentPassword: Type2Credential.factoryPassword)
        faults.resetLog()
        model.confirm()
        await run.value

        guard case .done(.passwordRemoved) = model.phase else {
            return XCTFail("removing protection from an open tag is a success, got \(model.phase)")
        }
        XCTAssertTrue(model.presentsFactoryDefault, "the run did present the substituted credential")
        XCTAssertFalse(
            model.didOpenGate,
            "nothing was authenticated, so 'the factory default is what opened this tag' would be a fabrication"
        )
        XCTAssertFalse(
            faults.report.contains(.opcode(Type2PasswordDriver.pwdAuth)),
            "an ungated tag must be sent no password at all"
        )
    }

    /// Re-keying a tag that is already armed, end to end.
    ///
    /// The standalone Protect screen has read nothing off the tag when the user
    /// presses Continue, so what opens the tag has to be collected somewhere.
    /// The identify tap is what discovers the gate, and the typed-UID gate is
    /// where the field goes: `requiresUnlockCredential` says so, and `confirm()`
    /// will not pass without one. A credential the tag then refuses lands on the
    /// prompt with the delivery-password offer beside it, which is what gets the
    /// tag back.
    @MainActor
    func test_protectOnAnArmedTagAsksForTheCurrentCredentialAndTheRecoveryReKeysIt() async throws {
        let sim = NTAG213Simulator()
        try sim.enablePasswordProtection(
            password: Type2Credential.factoryPassword,
            pack: Type2Credential.factoryPack,
            protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let newPassword = Data([0x0A, 0x0B, 0x0C, 0x0D])
        let newPack = Data([0x1E, 0x2F])
        let model = OperationsFlowModel(
            factory: SingleChipFactory(chip: sim),
            operation: .enableProtection(PendingProtection(
                settings: TagProtection(passwordProtect: true, protectFromPage: 4),
                credential: .type2(password: newPassword, pack: newPack)
            )),
            credentials: InMemoryTagCredentialStore()
        )

        let run = Task { await model.begin() }
        await until {
            if case .awaitingConfirmation = model.phase {
                return true
            }
            return false
        }
        XCTAssertTrue(
            model.requiresUnlockCredential,
            "the identify tap found a gate, so the gate card has to collect what opens it"
        )
        model.confirm()
        guard case .awaitingConfirmation = model.phase else {
            return XCTFail("the gate must not open for a run holding nothing, got \(model.phase)")
        }

        // What the user has: the password they are about to write, which on this
        // tag is the wrong one.
        model.supplyUnlockCredential(.type2(password: newPassword, pack: newPack))
        model.confirm()
        await run.value

        XCTAssertEqual(model.phase, .needsUnlock, "got \(model.phase)")
        XCTAssertEqual(model.recovery, .tryType2FactoryDefault)

        model.retryWithFactoryDefault()
        await runToCompletion(model)

        guard case .done(.passwordSet) = model.phase else {
            return XCTFail("expected the re-key to complete, got \(model.phase)")
        }
        sim.beginActivation()
        XCTAssertEqual(try sim.authenticate(password: newPassword), newPack, "the tag must hold the new credential")
    }

    // MARK: - The substitution can never be silent, and can never spread

    /// "Try again" forgets the credential entirely, so the next tap presents
    /// nothing the user did not type again.
    ///
    /// It used to restore the *operation*, which carried the credential, so the
    /// banner disappeared while the next tap went on sending the password the
    /// tag had just refused. Silent credential substitution in one direction and
    /// a silently repeated wrong try in the other: both are why the credential
    /// now has one home and `retry()` clears it.
    @MainActor
    func test_retryForgetsTheCredentialAndTheBannerWithIt() async throws {
        let sim = NTAG213Simulator()
        try sim.enablePasswordProtection(
            password: onTag, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let model = removal(on: sim, presenting: typed)

        await runToCompletion(model)
        model.retryWithFactoryDefault()

        XCTAssertEqual(
            model.unlockCredential,
            .type2(password: Type2Credential.factoryPassword, pack: Type2Credential.factoryPack)
        )
        XCTAssertEqual(
            model.presentedType2Password, Type2Credential.factoryPassword,
            "`RemovePasswordOperationView` renders its field off this property, so it is what stops the "
                + "screen showing the refused password under a banner announcing the substitution "
                + "(bench 2026-09-09, finding 1)"
        )
        XCTAssertEqual(
            model.operation, .disableProtection,
            "the recovery moves the credential and can never move the verb"
        )

        model.retry()

        XCTAssertNil(model.unlockCredential, "a plain retry must not keep sending the substituted credential")
        XCTAssertNil(
            model.presentedType2Password,
            "and with nothing held the field has no model answer to render, so it goes back to the form"
        )
        XCTAssertFalse(model.presentsFactoryDefault, "and the screen must stop saying that it will")
    }

    @MainActor
    func test_cancelAlsoForgetsTheCredential() async throws {
        let sim = NTAG213Simulator()
        try sim.enablePasswordProtection(
            password: onTag, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let model = removal(on: sim, presenting: typed)

        await runToCompletion(model)
        model.retryWithFactoryDefault()
        model.cancel()

        XCTAssertNil(model.unlockCredential)
        XCTAssertEqual(model.operation, .disableProtection)
        XCTAssertFalse(model.presentsFactoryDefault)
    }

    /// The recovery may not reach the one operation whose credential guess is
    /// not the app's to propose.
    ///
    /// Arming `AUTH_LIM` costs a counted `PWD_AUTH` on the screen that arms the
    /// counter, so a wrong guess there is a try the tag never gets back. The
    /// exclusion used to be structural, because the substitution rebuilt the
    /// operation and `.setAttemptLimit` had no substitution to rebuild into.
    /// Now the credential moves on its own, so the guard has to be stated.
    @MainActor
    func test_theRecoveryIsRefusedForTheAttemptLimit() async throws {
        let sim = NTAG213Simulator()
        try sim.enablePasswordProtection(
            password: onTag, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let model = OperationsFlowModel(
            factory: SingleChipFactory(chip: sim),
            operation: .setAttemptLimit(limit: 3),
            credentials: InMemoryTagCredentialStore()
        )
        model.supplyUnlockCredential(.type2(password: typed, pack: Data()))

        await runToCompletion(model)

        XCTAssertEqual(model.phase, .needsUnlock, "a wrong password must stop the run, got \(model.phase)")
        XCTAssertNil(
            model.recovery,
            "the app must never offer to spend a counted try on the screen that arms the counter"
        )

        model.retryWithFactoryDefault()

        XCTAssertFalse(model.presentsFactoryDefault, "and the tap itself is inert on this operation")
        XCTAssertEqual(
            model.presentedType2Password, typed,
            "the user's own password is still the one this run holds"
        )
    }

    /// The rule itself, stated over every operation.
    ///
    /// The behavioural test above cannot discriminate it on its own: an attempt
    /// limit refused at `openGate` throws `.authFailed`, never the
    /// `.protectionIncomplete` the classifier keys on, so the offer would not
    /// appear even without the guard. That is a fact about today's driver and
    /// not a rule, and the rule is what may not drift.
    @MainActor
    func test_onlyTheAttemptLimitIsBarredFromTheFactoryDefault() {
        let pending = PendingProtection(
            settings: TagProtection(passwordProtect: true, protectFromPage: 4),
            credential: .type2(password: typed, pack: pack)
        )
        let table: [(OperationsFlowModel.Operation, Bool)] = [
            (.erase, true),
            (.format, true),
            (.permanentLock, true),
            (.enableProtection(pending), true),
            (.disableProtection, true),
            (.setAttemptLimit(limit: 3), false),
            (.memoryDump, true),
        ]
        for (operation, allowed) in table {
            let model = OperationsFlowModel(
                factory: SingleChipFactory(chip: NTAG213Simulator()),
                operation: operation,
                credentials: InMemoryTagCredentialStore()
            )
            XCTAssertEqual(
                model.mayPresentTheFactoryDefault, allowed,
                "\(operation) must \(allowed ? "allow" : "refuse") a delivery-password tap"
            )
        }
        XCTAssertEqual(table.count, 7, "an Operation was added without saying whether it may guess")
    }

    /// The classifier keys on the credential that went out, and a family with
    /// no Type-2 delivery password earns no offer.
    @MainActor
    func test_theRecoveryIsRefusedForANonType2Credential() {
        var residue = ProtectionResidue(family: .type2, intent: .disable)
        residue.record(.stateRead)
        residue.record(failure: .gateOpened, "PWD_AUTH did not open the gate")
        let refusal = TagError.protectionIncomplete(residue)

        XCTAssertNil(
            OperationsFlowModel.recovery(
                after: refusal,
                presenting: .type4(aesKey: Data(repeating: 0, count: 16), keySlot: 0)
            )
        )
        XCTAssertNil(
            OperationsFlowModel.recovery(after: refusal, presenting: nil),
            "a run that presented nothing has nothing to substitute for"
        )
    }

    @MainActor
    func test_aPermanentLockFailureOffersNothingAndTheRecoveryTapIsInert() async {
        let factory = SingleChipFactory(chip: NTAG213Simulator(), firstSessionLosesTheTag: true)
        let model = OperationsFlowModel(
            factory: factory,
            operation: .permanentLock,
            credentials: InMemoryTagCredentialStore()
        )

        await runToCompletion(model)

        guard case .error = model.phase else {
            return XCTFail("expected the identify tap to fail, got \(model.phase)")
        }
        XCTAssertNil(model.recovery)
        let before = model.phase
        model.retryWithFactoryDefault()
        XCTAssertEqual(model.phase, before, "with no offer standing, the recovery tap does nothing")
        XCTAssertFalse(model.presentsFactoryDefault)
    }

    @MainActor
    func test_recoveryIsIgnoredWhileARunIsInFlight() async throws {
        let sim = NTAG213Simulator()
        try sim.enablePasswordProtection(
            password: onTag, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let model = removal(on: sim, presenting: typed)

        let run = Task { await model.begin() }
        await until {
            if case .awaitingConfirmation = model.phase {
                return true
            }
            return false
        }

        model.retryWithFactoryDefault()
        guard case .awaitingConfirmation = model.phase else {
            return XCTFail("the gate must not be yanked out from under a live run, got \(model.phase)")
        }
        XCTAssertFalse(model.presentsFactoryDefault)

        model.confirm()
        await run.value
    }

    /// The recovery reuses `retry()`'s reset, so consent is taken again against a
    /// freshly identified tag rather than inherited from the run that failed.
    @MainActor
    func test_theRecoveryTapReIdentifiesAndReConfirms() async throws {
        let sim = NTAG213Simulator()
        try sim.enablePasswordProtection(
            password: Type2Credential.factoryPassword,
            pack: Type2Credential.factoryPack,
            protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let factory = SingleChipFactory(chip: sim)
        let model = removal(factory: factory, presenting: typed)

        await runToCompletion(model)
        XCTAssertEqual(factory.sessionsStarted, 2, "identify, then the run itself")

        model.retryWithFactoryDefault()
        var sawTheGateAgain = false
        let run = Task { await model.begin() }
        await until {
            if case .awaitingConfirmation = model.phase {
                sawTheGateAgain = true
                return true
            }
            return false
        }
        model.confirm()
        await run.value

        XCTAssertTrue(sawTheGateAgain, "the typed-UID gate has to be satisfied again, not carried over")
        XCTAssertEqual(factory.sessionsStarted, 4, "the recovery run identifies the tag before it writes to it")
    }

    // MARK: - Driving the two-tap flow

    /// A removal run holding one Type-2 password.
    ///
    /// The operation names the verb and nothing else; the credential goes in
    /// through the model's one channel for one, which is what
    /// `RemovePasswordOperationView.launch()` does.
    @MainActor
    private func removal(on chip: ChipSimulator, presenting password: Data) -> OperationsFlowModel {
        removal(factory: SingleChipFactory(chip: chip), presenting: password)
    }

    @MainActor
    private func removal(
        factory: TagSessionFactory,
        presenting password: Data,
        pack: Data = Data()
    ) -> OperationsFlowModel {
        let model = OperationsFlowModel(
            factory: factory,
            operation: .disableProtection,
            credentials: InMemoryTagCredentialStore()
        )
        model.supplyUnlockCredential(.type2(password: password, pack: pack))
        return model
    }

    @MainActor
    private func runToCompletion(_ model: OperationsFlowModel) async {
        let run = Task { await model.begin() }
        await until {
            switch model.phase {
            case .awaitingConfirmation, .needsUnlock, .done, .error: true
            default: false
            }
        }
        if case .awaitingConfirmation = model.phase {
            // The gate refuses to open for a run that needs a credential and
            // holds none, which some of these fixtures are deliberately in.
            // Confirming such a run leaves `begin()` suspended on its
            // continuation, which hangs the suite rather than failing it, so ask
            // the same question the gate asks and cancel instead.
            if model.requiresUnlockCredential, model.unlockCredential == nil {
                model.cancel()
            } else {
                model.confirm()
            }
        }
        await run.value
    }
}

@MainActor
private func until(timeout: Duration = .seconds(2), _ predicate: @MainActor () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if predicate() {
            return
        }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }
}

/// Vends sessions over one chip, so state carries across taps as it does on a
/// physical tag, and counts them so a test can assert that a recovery tap opened
/// a fresh pair rather than resuming the failed one.
///
/// Deliberately local. The equivalents in `ConfirmationGateTests` and
/// `HexNFCAppTests` are `private` to those files, and a shared helper file is a
/// bigger change than the twenty lines it would save.
private final class SingleChipFactory: TagSessionFactory, @unchecked Sendable {
    private let chip: ChipSimulator
    private let firstSessionLosesTheTag: Bool
    private(set) var sessionsStarted = 0

    init(chip: ChipSimulator, firstSessionLosesTheTag: Bool = false) {
        self.chip = chip
        self.firstSessionLosesTheTag = firstSessionLosesTheTag
    }

    func makeSession() -> TagSession {
        sessionsStarted += 1
        if firstSessionLosesTheTag, sessionsStarted == 1 {
            return SimulatedSession(chip: chip, behaviour: .tagLost)
        }
        return SimulatedSession(chip: chip)
    }
}
