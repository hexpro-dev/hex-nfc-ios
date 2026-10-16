@testable import HexNFCApp
@testable import HexNFCKit
import HexNFCRecords
import HexNFCStorage
import HexNFCTagSim
import XCTest

/// The write flow used to present a credential to a tag before it had
/// established that the tag wanted one.
///
/// On a Type-2 chip a refused `PWD_AUTH` NAKs, and a NAK returns the chip to
/// HALT for the rest of the activation. So a speculative authentication against
/// a tag that is not gated did not merely waste a frame: it killed the session,
/// and the silence that followed was then read as a refusal. An entirely
/// unprotected tag came out of that chain reported to the user as
/// password-protected, asking for a password it had never had.
///
/// Two ways in, both covered here:
///
///  - a **stale** credential, the state the 2026-09-04 incident left behind
///  - a **not-yet-written** credential, which is what the editor hands the write
///    flow every time a user configures protection on a blank tag
final class SpeculativeAuthTests: XCTestCase {
    private let password = Data([0xA1, 0xB2, 0xC3, 0xD4])
    private let pack = Data([0x56, 0x78])

    /// A blank tag being protected for the first time. The editor passes the new
    /// password as the unlock credential, so the flow would authenticate with a
    /// password the tag does not hold yet.
    @MainActor
    func test_writeToABlankTag_whileConfiguringANewPassword_doesNotHaltTheTag() async {
        let simulator = NTAG215Simulator()
        let model = WriteFlowModel(
            factory: SingletonChipFactory(chip: simulator),
            dataArea: .replace([.uri(URIRecord(uri: "https://hex.pro"))]),
            credentials: InMemoryTagCredentialStore(),
            unlockCredential: .type2(password: password, pack: pack),
            uidConfirmation: .required
        )

        await model.begin()

        XCTAssertEqual(
            model.phase, WriteFlowModel.Phase.done,
            "a blank tag is not gated, so no password may be presented and the write must simply succeed. "
                + "Got \(model.phase)"
        )
        XCTAssertFalse(
            simulator.isHalted,
            "no PWD_AUTH should have been sent, so nothing could have NAKed and halted the chip"
        )
    }

    /// The incident's end state: the tag is open, the app still holds the old
    /// password. Writing must work, and must not ask for a password.
    @MainActor
    func test_writeToATagWhoseProtectionWasAlreadyRemoved_doesNotAskForAPassword() async throws {
        let simulator = NTAG213Simulator()
        try simulator.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        try simulator.disablePasswordProtection(currentPassword: password)
        simulator.beginActivation()

        let model = WriteFlowModel(
            factory: SingletonChipFactory(chip: simulator),
            dataArea: .replace([.text(TextRecord(text: "recovered"))]),
            credentials: InMemoryTagCredentialStore(),
            unlockCredential: .type2(password: password, pack: pack),
            uidConfirmation: .required
        )

        await model.begin()

        XCTAssertEqual(
            model.phase, WriteFlowModel.Phase.done,
            "the tag is unprotected, so the stale credential must be ignored rather than fired at it. "
                + "Got \(model.phase)"
        )
        XCTAssertFalse(simulator.isHalted)
    }

    /// A tag already armed with AUTH0 *above* its data area, being re-keyed.
    ///
    /// The records are not gated: AUTH0 sits past the last NDEF page, so they go
    /// on unauthenticated. The four config-page writes that follow them are
    /// gated, and every one of them sits at or above AUTH0. The preamble used to
    /// ask only whether the *data area* was in the way, so a tap that was going
    /// to rewrite PWD, PACK, ACCESS and AUTH0 was waved through with no
    /// credential, and `Type2PasswordDriver.enable` then found the tag armed and
    /// presented the only credential it had: the NEW password, to a tag holding
    /// the OLD one. One refusal, one NAK, and a chip that answers nothing for
    /// the rest of the tap.
    ///
    /// Saying what the tap will touch (`.writesConfigPages`) is what turns that
    /// into a question asked before anything is written.
    @MainActor
    func test_armingATagAlreadyArmedAboveTheNDEFArea_asksForItsPasswordRatherThanPresentingTheNewOne() async throws {
        let simulator = NTAG213Simulator()
        let dataAreaPages = try XCTUnwrap(ChipCatalog.require(.ntag213).memoryLayout.ndefRange)
        try simulator.enablePasswordProtection(
            password: password,
            pack: pack,
            protectFromPage: dataAreaPages.upperBound + 1,
            readProtect: false,
            authLimit: 0
        )
        simulator.beginActivation()

        let faults = FaultInjectingSessionFactory(chip: simulator)
        let model = WriteFlowModel(
            factory: faults,
            dataArea: .replace([.text(TextRecord(text: "re-keyed"))]),
            credentials: InMemoryTagCredentialStore(),
            protection: PendingProtection(
                settings: TagProtection(passwordProtect: true, protectFromPage: 4, readProtect: false, authLimit: 0),
                credential: .type2(password: Data([0x0F, 0x0E, 0x0D, 0x0C]), pack: Data([0x9A, 0xBC]))
            ),
            // Nothing is held for this tag. The only credential in hand is the
            // one about to be written, which is not the one the tag answers to.
            unlockCredential: nil,
            uidConfirmation: .notRequired
        )

        await model.begin()

        XCTAssertEqual(model.phase, .needsUnlock, "expected the prompt, got \(model.phase)")
        XCTAssertFalse(model.unlockFailed, "nothing was presented, so nothing failed")
        XCTAssertTrue(
            faults.report.frames(matching: .opcode(Type2PasswordDriver.pwdAuth)).isEmpty,
            "a password the tag has never held may not be presented to it"
        )
        XCTAssertFalse(simulator.isHalted, "and the chip is still answering for the tap that follows")
    }

    /// The control: a tag that really is gated still gets exactly one
    /// authentication, and the write goes through.
    @MainActor
    func test_writeToAGenuinelyProtectedTag_stillAuthenticatesOnce() async throws {
        let simulator = NTAG213Simulator()
        try simulator.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        simulator.beginActivation()

        let model = WriteFlowModel(
            factory: SingletonChipFactory(chip: simulator),
            dataArea: .replace([.text(TextRecord(text: "authorised"))]),
            credentials: InMemoryTagCredentialStore(),
            unlockCredential: .type2(password: password, pack: pack),
            uidConfirmation: .required
        )

        await model.begin()

        XCTAssertEqual(
            model.phase,
            WriteFlowModel.Phase.done,
            "a correct password must still unlock and write. Got \(model.phase)"
        )
    }
}

/// Hands out sessions over one shared simulator, so the write, the verify and
/// the protection step all see the same chip state across re-taps.
private final class SingletonChipFactory: TagSessionFactory, @unchecked Sendable {
    private let chip: ChipSimulator
    init(chip: ChipSimulator) {
        self.chip = chip
    }

    func makeSession() -> TagSession {
        SimulatedSession(chip: chip)
    }
}

/// "Also require password to read" used to report failure on a tag it had just
/// protected correctly.
///
/// `OperationsFlowModel.verify` reads the protection state back, and with PROT
/// set the configuration pages are inside the gated range. The read was issued
/// unauthenticated, so the chip NAKed it, the NAK halted the tag, and a
/// correctly protected tag surfaced as an error. Every retry then died at the
/// opening config read of the next attempt, because by then the tag really was
/// read-protected: an unbreakable loop on a tag that was fine.
///
/// The driver now proves what it did before returning, which means presenting
/// the credential it just wrote, so the session is authenticated by the time
/// the flow's own read-back runs. Only ever tested with `readProtect: false`
/// before, which is why it survived.
final class ReadProtectVerifyTests: XCTestCase {
    @MainActor
    func test_protectWithReadProtection_reportsSuccessNotFailure() async {
        let simulator = NTAG215Simulator()
        let model = OperationsFlowModel(
            factory: SingletonChipFactory(chip: simulator),
            operation: .enableProtection(PendingProtection(
                settings: TagProtection(passwordProtect: true, protectFromPage: 4, readProtect: true),
                credential: .type2(password: Data([0x0A, 0x0B, 0x0C, 0x0D]), pack: Data([0x1E, 0x2F]))
            )),
            credentials: InMemoryTagCredentialStore()
        )

        let run = Task { await model.begin() }
        await untilConfirmable(model)
        model.confirm()
        await run.value

        guard case .done = model.phase else {
            return XCTFail("a tag protected correctly must not report failure. Got \(model.phase)")
        }
    }
}

@MainActor
private func untilConfirmable(_ model: OperationsFlowModel) async {
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
    while ContinuousClock.now < deadline {
        if case .awaitingConfirmation = model.phase {
            return
        }
        switch model.phase {
        case .needsUnlock, .done, .error: return
        default: break
        }
        await Task.yield()
    }
}
