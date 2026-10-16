@testable import HexNFCApp
@testable import HexNFCKit
@testable import HexNFCRecords
import HexNFCStorage
@testable import HexNFCTagSim
import XCTest

/// What the unlock prompts say when the tag has an attempt limit.
///
/// Bench finding 17 (2026-09-10): an NTAG213 whose `AUTH_LIM` was spent refused
/// the **correct** password, tag A at 11:29:51 and tag B at 11:58:33. The driver
/// was taught to say so wherever it had read the limit (`TagError.attemptLimit`),
/// and Operations shows that copy. The two unlock prompts did not: both write
/// "That password didn't unlock the tag. Check it and try again." from their own
/// strings, which sends the owner of an exhausted tag to doubt a right password
/// and spend another try.
///
/// The write route also threw the refusal away before it could reach the
/// prompt. It authenticated inside a `try?`, then read a chip the refusal had
/// already halted: on silicon those reads drew "Tag connection lost" twice, about
/// 620 ms, and only then reached the prompt (tag B, 11:57:45 to 11:58:33).
final class UnlockRefusalCopyTests: XCTestCase {
    private let password = Data([0xA1, 0xB2, 0xC3, 0xD4])
    private let wrong = Data([0x00, 0x00, 0x00, 0x01])
    private let pack = Data([0x56, 0x78])
    private let records: [NDEFRecord] = [.uri(URIRecord(uri: "https://hex.pro"))]

    private func armed(limit: Int) throws -> NTAG213Simulator {
        let sim = NTAG213Simulator()
        try sim.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: false, authLimit: limit
        )
        return sim
    }

    private func exhausted() throws -> NTAG213Simulator {
        let sim = try armed(limit: 1)
        // The chip locks one past its limit, so a limit of one takes two.
        _ = try? sim.authenticate(password: wrong)
        _ = try? sim.authenticate(password: wrong)
        XCTAssertTrue(sim.isAuthLocked, "the fixture must actually be exhausted")
        return sim
    }

    // MARK: - The copy rule

    /// A refusal replaces the prompt's copy only when it knows about a limit.
    func test_onlyARefusalThatKnowsTheLimitReplacesThePromptsCopy() throws {
        XCTAssertNil(TagError.authFailed().unlockPromptCopy, "no limit read, so the sheet's own copy stands")
        XCTAssertNil(TagError.authRefused(attemptLimit: nil).unlockPromptCopy)
        XCTAssertNil(TagError.authRefused(attemptLimit: 0).unlockPromptCopy, "0 is not a limit")
        XCTAssertNil(TagError.readProtected().unlockPromptCopy, "a gated read presented no password at all")
        XCTAssertNil(
            TagError(
                kind: .protectionIncomplete(ProtectionResidue(family: .type2, intent: .enable)),
                userMessage: "x", diagnostics: "d", attemptLimit: 2
            ).unlockPromptCopy,
            "a half-applied operation is not an unlock outcome, even when it read the limit"
        )

        let copy = try String(localized: XCTUnwrap(TagError.authRefused(attemptLimit: 2).unlockPromptCopy))
        XCTAssertTrue(copy.contains("attempt limit"), "Got: \(copy)")
        XCTAssertFalse(copy.contains("Check it and try again"), "Got: \(copy)")

        // On a limited tag the transport form is what an unlocked chip gives a
        // wrong password (2026-09-14), so it is the form the owner of a tag that
        // can still be saved meets first. Its copy says a wrong try counts and
        // to check the password before trying again, which is the warning the
        // sheet's own words lack.
        let transport = try String(localized: XCTUnwrap(TagError.authInconclusive(attemptLimit: 2).unlockPromptCopy))
        XCTAssertTrue(transport.contains("attempt limit"), "Got: \(transport)")
        XCTAssertFalse(transport.contains("stopped answering"), "Got: \(transport)")
        XCTAssertNil(TagError.authInconclusive(attemptLimit: nil).unlockPromptCopy, "no limit read, no hedge")
    }

    // MARK: - The write route

    /// The finding, on the write route: the right password, an exhausted tag.
    @MainActor
    func test_writeFlow_anExhaustedTagRefusingTheRightPassword_saysTheLimitAndStopsAtTheRefusal() async throws {
        let faults = try FaultInjectingSessionFactory(chip: exhausted())
        let model = WriteFlowModel(
            factory: faults, dataArea: .replace(records), credentials: InMemoryTagCredentialStore(),
            unlockCredential: .type2(password: password, pack: Data()),
            uidConfirmation: .required
        )

        await model.begin()

        XCTAssertEqual(model.phase, .needsUnlock)
        XCTAssertTrue(model.unlockFailed)
        let refusal = try XCTUnwrap(model.unlockRefusal, "the refusal has to reach the prompt")
        XCTAssertEqual(refusal.attemptLimit, 1)
        XCTAssertNotNil(refusal.unlockPromptCopy)
        guard case .type2? = model.unlockStyle else {
            return XCTFail("the prompt must ask for a Type-2 password, got \(String(describing: model.unlockStyle))")
        }
        let tap = faults.report.frames(inTap: faults.tapCount)
        let passwordFrames = tap.indices.filter { tap[$0].request.first == Type2PasswordDriver.pwdAuth }
        XCTAssertEqual(passwordFrames.count, 1, "one authentication attempt per activation")
        XCTAssertEqual(
            passwordFrames.last, tap.indices.last,
            "nothing is sent to a chip the refusal has halted"
        )
    }

    /// A tag with no limit keeps today's route and today's copy.
    @MainActor
    func test_writeFlow_aWrongPasswordWithNoLimit_keepsTheSheetsOwnCopy() async throws {
        let model = try WriteFlowModel(
            factory: SimulatedSessionFactory(chip: armed(limit: 0)), dataArea: .replace(records),
            credentials: InMemoryTagCredentialStore(), unlockCredential: .type2(password: wrong, pack: Data()),
            uidConfirmation: .required
        )

        await model.begin()

        XCTAssertEqual(model.phase, .needsUnlock)
        XCTAssertTrue(model.unlockFailed)
        XCTAssertNil(model.unlockRefusal?.unlockPromptCopy, "nothing about this tag makes the refusal ambiguous")
    }

    /// The transport form on a limited tag ends the activation at the refusal
    /// too, and reaches the prompt with its own copy (see
    /// `TagError.unlockPromptCopy`): on silicon it is the ordinary wrong
    /// password on a tag that is not yet locked, the one case a warning can
    /// still save.
    ///
    /// `.dropped` leaves the simulated chip awake, where silicon's transport-form
    /// refusal leaves it halted, so the old route used to present the password a
    /// second time in this tap and could even write. This pins the one-attempt
    /// rule and the copy, not a silicon sequence.
    @MainActor
    func test_writeFlow_aLostPasswordFrameOnALimitedTag_saysTheLimitWithoutASecondAttempt() async throws {
        let faults = try FaultInjectingSessionFactory(chip: armed(limit: 3))
        faults.arm(TagFault(.opcode(Type2PasswordDriver.pwdAuth), .dropped))
        let model = WriteFlowModel(
            factory: faults, dataArea: .replace(records), credentials: InMemoryTagCredentialStore(),
            unlockCredential: .type2(password: password, pack: Data()),
            uidConfirmation: .required
        )

        await model.begin()

        XCTAssertEqual(model.phase, .needsUnlock)
        XCTAssertEqual(model.unlockRefusal?.kind, .authInconclusive)
        XCTAssertEqual(model.unlockRefusal?.attemptLimit, 3)
        XCTAssertTrue(model.unlockFailed, "the attempt did not unlock the tag")
        let copy = try String(localized: XCTUnwrap(
            model.unlockRefusal?.unlockPromptCopy,
            "the prompt must say the limit"
        ))
        XCTAssertTrue(copy.contains("attempt limit"), "Got: \(copy)")
        XCTAssertEqual(faults.report.frames(matching: .opcode(Type2PasswordDriver.pwdAuth)).count, 1)
    }

    /// A read that failed before any password went out is not a refusal.
    ///
    /// `TagError.readProtected` shares `.authFailed` with a real refusal, and the
    /// 2026-09-09 `1F` answered this exact frame on a tag whose gate was open.
    /// Treating it as a refusal would stop a write that the right password was
    /// about to complete.
    @MainActor
    func test_writeFlow_aShortAnswerBeforeThePasswordIsNotFiledAsARefusal() async throws {
        let layout = try XCTUnwrap(Type2ConfigLayout.for(.ntag213))
        let faults = try FaultInjectingSessionFactory(chip: armed(limit: 1))
        faults.arm(TagFault(.read(page: layout.config0Page), .refused(response: Data([0x1F]), halts: false)))
        let model = WriteFlowModel(
            factory: faults, dataArea: .replace(records), credentials: InMemoryTagCredentialStore(),
            unlockCredential: .type2(password: password, pack: Data()),
            uidConfirmation: .required
        )

        await model.begin()

        XCTAssertEqual(model.phase, .done, "the right password still writes in one tap, got \(model.phase)")
        XCTAssertNil(model.unlockRefusal)
        XCTAssertEqual(faults.report.frames(matching: .opcode(Type2PasswordDriver.pwdAuth)).count, 1)
    }

    /// The editor hands the write flow the key it is about to write. On a blank
    /// NTAG424 that handshake is refused, and the tag is not protected, so the
    /// write has to go ahead. Every family except Type-2 presents its credential
    /// without reading the gate first, which is why only a refusal carrying an
    /// attempt limit may end the activation.
    @MainActor
    func test_writeFlow_protectingABlankNTAG424WithItsNewKeySeeded_stillCompletes() async {
        let key = Data((0 ..< 16).map { UInt8(0x30 &+ $0) })
        var settings = TagProtection()
        settings.passwordProtect = true
        settings.style = .type4(.init(keySlot: 0, readProtect: false))
        let model = WriteFlowModel(
            factory: SimulatedSessionFactory(chip: NTAG424DNASimulator()), dataArea: .replace(records),
            credentials: InMemoryTagCredentialStore(),
            protection: PendingProtection(settings: settings, credential: .type4(aesKey: key, keySlot: 0)),
            unlockCredential: .type4(aesKey: key, keySlot: 0),
            uidConfirmation: .required
        )

        await beginConfirmingUID(model)

        XCTAssertEqual(model.phase, .done, "a blank 424 has nothing to unlock, got \(model.phase)")
        XCTAssertNil(model.unlockRefusal)
    }

    // MARK: - The scan route

    /// The scan route reaches the limit too: a write-only-protected tag lifted
    /// mid-read, whose message runs past page 6, still gets the prompt, and the
    /// re-tap reads the configuration pages the gate leaves readable.
    @MainActor
    func test_scanFlow_anExhaustedTagRefusingTheRightPassword_saysTheLimit() async throws {
        let message = try NDEFCodec.encode([.uri(URIRecord(uri: "https://hex.pro/a-message-that-runs-past-page-six"))])
        let sim = LiftedOnceNTAG213(ndefMessage: message)
        try sim.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 1
        )
        _ = try? sim.authenticate(password: wrong)
        _ = try? sim.authenticate(password: wrong)
        let model = ScanFlowModel(factory: SimulatedSessionFactory(chip: sim))

        await model.begin()
        XCTAssertEqual(model.phase, .locked, "the lift is not disproved by a chain that runs past page 6")

        await model.unlock(with: .type2(password: password, pack: Data()))

        XCTAssertEqual(model.phase, .locked)
        XCTAssertEqual(model.unlockRefusal?.attemptLimit, 1)
        XCTAssertNotNil(model.unlockRefusal?.unlockPromptCopy)
    }

    /// The write sheet's prompt is the other one, and it was the one this fix
    /// first missed: `WriteFlowModel` filtered refusals on `attemptLimit`, which
    /// is nil for a hidden reading, so the refusal was dropped and the prompt
    /// fell back to "That password didn't unlock the tag. Check it and try
    /// again." on the very tag whose counter cannot be watched. Found by review
    /// before this branch landed.
    @MainActor
    func test_writeFlow_aRefusalFromAReadProtectedTag_saysTheTryMayHaveCounted() async throws {
        let sim = NTAG213Simulator()
        try sim.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: true, authLimit: 1
        )
        let model = WriteFlowModel(
            factory: SimulatedSessionFactory(chip: sim), dataArea: .replace(records),
            credentials: InMemoryTagCredentialStore(),
            unlockCredential: .type2(password: wrong, pack: Data()),
            uidConfirmation: .required
        )

        await beginConfirmingUID(model)

        XCTAssertEqual(model.phase, .needsUnlock, "a refused password sends the write to the prompt")
        XCTAssertEqual(
            model.unlockRefusal?.limitReading, .hidden,
            "the refusal knows the tag would not disclose AUTH_LIM, and the prompt needs that"
        )
        let copy = try XCTUnwrap(
            model.unlockRefusal?.unlockPromptCopy,
            "the write prompt must replace its own copy, exactly as the scan prompt does"
        )
        XCTAssertTrue(String(localized: copy).contains("attempt limit"))
        XCTAssertFalse(sim.isAuthLocked, "the fixture keeps a try in hand at a limit of 1")
    }

    /// A read-protected tag hides `AUTH_LIM` behind the gate being opened, so a
    /// refusal carries no number. Said as "no limit", the prompt came back in
    /// its neutral first-run copy with nothing to show a try had been spent, and
    /// the same button spent the next one. At a limit of 1 that is two presses
    /// to a tag that never accepts its password again.
    ///
    /// The prompt's colour follows the same property (`ScanSheet`), so this is
    /// also what turns the copy red.
    @MainActor
    func test_scanFlow_aRefusalFromAReadProtectedTag_saysTheTryMayHaveCounted() async throws {
        let sim = NTAG213Simulator()
        try sim.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: true, authLimit: 1
        )
        let model = ScanFlowModel(factory: SimulatedSessionFactory(chip: sim))

        await model.begin()
        XCTAssertEqual(model.phase, .locked, "a read-gated tag reaches the unlock prompt")

        await model.unlock(with: .type2(password: wrong, pack: Data()))

        XCTAssertEqual(model.phase, .locked)
        XCTAssertEqual(
            model.unlockRefusal?.limitReading, .hidden,
            "the tag would not disclose AUTH_LIM: that is not the same as having none"
        )
        XCTAssertNil(
            model.unlockRefusal?.attemptLimit,
            "and no number may be invented for it"
        )
        let copy = try XCTUnwrap(
            model.unlockRefusal?.unlockPromptCopy,
            "the prompt must replace its first-run copy after a refusal it cannot count"
        )
        let rendered = String(localized: copy)
        XCTAssertTrue(
            rendered.contains("didn't open the tag"),
            "the copy has to say the password did not open it. Got: \(rendered)"
        )
        XCTAssertFalse(
            sim.isAuthLocked,
            "the fixture keeps a try in hand: a limit of 1 tolerates the one wrong password above"
        )
    }
}

/// An NTAG213 that is lifted during its first NDEF read and answers normally
/// after, which the fault seam cannot stage: `tagLeavesTheField` removes the tag
/// from every entry point at once, so the pre-read would fail too.
private final class LiftedOnceNTAG213: NTAG21xSimulator, @unchecked Sendable {
    private var lifted = false

    init(ndefMessage: Data) {
        super.init(
            variant: .ntag213,
            profile: ChipCatalog.require(.ntag213),
            uid: NTAG213Simulator.defaultUID,
            ndefMessage: ndefMessage
        )
    }

    override func versionBlock() -> Data {
        Data([0x00, 0x04, 0x04, 0x02, 0x01, 0x00, 0x0F, 0x03])
    }

    override func readNDEF() throws -> Data {
        guard lifted else {
            lifted = true
            throw TagError.tagLost(diagnostics: "lifted mid-read")
        }
        return try super.readNDEF()
    }
}
