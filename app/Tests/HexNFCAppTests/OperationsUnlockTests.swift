@testable import HexNFCApp
@testable import HexNFCKit
@testable import HexNFCRecords
import HexNFCStorage
@testable import HexNFCTagSim
import XCTest

/// Where an operation collects the tag's credential, and what it costs.
///
/// A confirming operation already stops between two taps with no session open,
/// which is the window the write route has to buy with a whole `.needsUnlock`
/// round trip. So the credential is collected there and no confirming operation
/// gains a tap for it. `.needsUnlock` is the fallback for a credential the tag
/// then refused, and it keeps the typed UID so supplying another resumes at tap
/// 2 rather than starting over.
@MainActor
final class OperationsUnlockTests: XCTestCase {
    private let password = Data([0xCA, 0xFE, 0xBA, 0xBE])
    private let pack = Data([0x12, 0x34])

    // MARK: - The headline: an operation that could not reach a protected tag now can

    /// Erase on a password-protected tag.
    ///
    /// It used to write the data area with no credential at all, which a gated
    /// tag NAKs, while the editor could erase the same tag by asking for its
    /// password. That asymmetry is the whole of what this is about: the same
    /// operation now behaves the same way whichever route reaches it.
    func test_eraseOnAProtectedTagCompletesOnceTheGateHasItsCredential() async throws {
        let chip = NTAG213Simulator()
        try chip.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let factory = CountingFactory(chip: chip)
        let model = OperationsFlowModel(factory: factory, operation: .erase, credentials: InMemoryTagCredentialStore())

        let run = Task { await model.begin() }
        await untilGated(model)
        XCTAssertTrue(
            model.requiresUnlockCredential,
            "the tag gates the data area this erase writes, so the gate card has to ask for a password"
        )

        model.supplyUnlockCredential(.type2(password: password, pack: pack))
        model.confirm()
        await run.value

        guard case .done(.erased) = model.phase else {
            return XCTFail("expected the erase to complete, got \(model.phase)")
        }
        XCTAssertEqual(factory.sessionsStarted, 2, "identify, then the tap that writes. No third hold.")
    }

    // MARK: - Which operations need one, and why it is not a list of names

    /// Format's intent is empty because its one write and its read-back are both
    /// page 3, which sits below every AUTH0 this app is able to write. A
    /// hand-written list of operation names would have to remember that, and the
    /// day it did not, Format would stop working on a protected tag where it
    /// works today.
    func test_formatNeedsNoCredentialOnAProtectedTag() async throws {
        let chip = NTAG213Simulator()
        try chip.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let model = OperationsFlowModel(
            factory: SingleChipFactory(chip: chip),
            operation: .format,
            credentials: InMemoryTagCredentialStore()
        )

        let run = Task { await model.begin() }
        await untilGated(model)

        guard !model.requiresUnlockCredential else {
            // Bail rather than confirm. The gate will not open for a run that
            // needs a credential and holds none, so confirming here would leave
            // `begin()` suspended and hang the suite instead of failing it.
            model.cancel()
            await run.value
            return XCTFail("a write to page 3 is below every gate this app can arm")
        }
        model.confirm()
        await run.value

        guard case .done(.formatted) = model.phase else {
            return XCTFail("expected the format to complete, got \(model.phase)")
        }
    }

    /// The same question the other way round: a tag gated only above its data
    /// area leaves an erase nothing to authenticate for.
    func test_anEraseNeedsNoCredentialWhenTheGateSitsAboveTheDataArea() async throws {
        let chip = NTAG213Simulator()
        let layout = try XCTUnwrap(chip.profile?.memoryLayout)
        let above = try XCTUnwrap(layout.ndefRange?.upperBound) + 1
        try chip.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: above, readProtect: false, authLimit: 0
        )
        let model = OperationsFlowModel(
            factory: SingleChipFactory(chip: chip),
            operation: .erase,
            credentials: InMemoryTagCredentialStore()
        )

        let run = Task { await model.begin() }
        await untilGated(model)

        XCTAssertEqual(model.reading?.protection?.passwordProtect, true, "the tag is protected")
        XCTAssertFalse(
            model.requiresUnlockCredential,
            "AUTH0 is past the last data page, so the erase writes nothing the gate covers"
        )
        model.cancel()
        await run.value
    }

    /// A tag whose gate could not be read is treated as gated over everything.
    /// The rule is "the reading has not positively proven the gate open", not
    /// "the reading says protected": a read-gated Type-2 tag answers tap 1 with
    /// a credential request rather than with configuration bytes, and a SLIX2's
    /// state cannot be established on an identify tap at all.
    func test_aTagWhoseGateCouldNotBeReadStillAsksForACredential() async throws {
        let chip = NTAG213Simulator()
        try chip.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: true, authLimit: 0
        )
        let model = OperationsFlowModel(
            factory: SingleChipFactory(chip: chip),
            operation: .disableProtection,
            credentials: InMemoryTagCredentialStore()
        )

        let run = Task { await model.begin() }
        await untilGated(model)

        XCTAssertNil(model.reading?.protection, "nothing read the configuration")
        XCTAssertTrue(model.requiresUnlockCredential, "and an unread gate is treated as a gate")
        model.cancel()
        await run.value
    }

    /// A single-tap operation has no identify tap, so it has no reading, so it
    /// asks for nothing before it runs.
    func test_aSingleTapOperationAsksForNothing() {
        let model = OperationsFlowModel(
            factory: SingleChipFactory(chip: NTAG213Simulator()),
            operation: .memoryDump,
            credentials: InMemoryTagCredentialStore()
        )
        XCTAssertFalse(model.requiresUnlockCredential)
    }

    // MARK: - The prompt, and what it keeps

    /// A credential the tag refuses stops the run at the prompt, and the typed
    /// UID survives it: supplying another resumes at tap 2 rather than asking
    /// for fourteen characters again because a password was mistyped.
    func test_aRefusedCredentialStopsAtThePromptAndKeepsTheTypedUID() async throws {
        let chip = NTAG213Simulator()
        try chip.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let factory = CountingFactory(chip: chip)
        let model = OperationsFlowModel(
            factory: factory,
            operation: .disableProtection,
            credentials: InMemoryTagCredentialStore()
        )

        let run = Task { await model.begin() }
        await untilGated(model)
        model.supplyUnlockCredential(.type2(password: Data([0xDE, 0xAD, 0xBE, 0xEF]), pack: Data()))
        model.confirm()
        await run.value

        XCTAssertEqual(model.phase, .needsUnlock, "got \(model.phase)")
        XCTAssertTrue(model.unlockFailed)
        XCTAssertEqual(factory.sessionsStarted, 2, "identify, then the refused tap")
        XCTAssertEqual(
            chip.failedAuthAttempts, 1,
            "one authentication attempt per activation: a refused PWD_AUTH halts the chip, so a "
                + "second password is always a second hold"
        )

        // Driven from its own task. `unlock(with:)` awaits `begin()`, and a
        // resumed run that lost the typed UID would suspend at the gate rather
        // than finish, which has to fail here and not hang.
        //
        // Waiting on the transition count rather than on the phase, because the
        // phase this run starts in is already one of the ones being waited for.
        let before = model.transitionCount
        let resumed = Task { await model.unlock(with: .type2(password: password, pack: pack)) }
        await until {
            guard model.transitionCount > before else { return false }
            switch model.phase {
            // `.idle` is the step `unlock(with:)` passes through on its way into
            // `begin()`, so it is not settled.
            case .awaitingConfirmation, .needsUnlock, .done, .error: return true
            default: return false
            }
        }

        guard case .done(.passwordRemoved) = model.phase else {
            model.cancel()
            await resumed.value
            return XCTFail("supplying the credential must resume at tap 2, got \(model.phase)")
        }
        await resumed.value
        XCTAssertEqual(
            factory.sessionsStarted, 3,
            "the credential resumed at tap 2: no third identify, and no second typed UID"
        )
        XCTAssertEqual(try chip.readProtectionState(), TagProtection.none)
    }

    /// Walking away from the prompt. No session is open there and no task is
    /// suspended, so `cancel()` has only state to drop, and it drops all of it.
    func test_cancellingAtThePromptDropsTheCredentialAndTheConsent() async throws {
        let chip = NTAG213Simulator()
        try chip.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let factory = CountingFactory(chip: chip)
        let model = OperationsFlowModel(
            factory: factory,
            operation: .disableProtection,
            credentials: InMemoryTagCredentialStore()
        )

        let run = Task { await model.begin() }
        await untilGated(model)
        model.supplyUnlockCredential(.type2(password: Data([0xDE, 0xAD, 0xBE, 0xEF]), pack: Data()))
        model.confirm()
        await run.value
        XCTAssertEqual(model.phase, .needsUnlock)

        model.cancel()

        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.unlockCredential)
        XCTAssertNil(model.reading)

        // And the next run starts from the beginning: a typed UID is consent for
        // one run against one tag, and a cancelled run is not that run.
        let second = Task { await model.begin() }
        await untilGated(model)
        XCTAssertEqual(factory.sessionsStarted, 3, "the next run identifies the tag again")
        model.cancel()
        await second.value
    }

    /// The prompt asks for the shape of secret the tag's family uses, and keeps
    /// knowing it across the run that clears everything else.
    func test_thePromptKnowsWhichKindOfSecretToAskFor() async throws {
        let chip = NTAG213Simulator()
        try chip.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let model = OperationsFlowModel(
            factory: SingleChipFactory(chip: chip),
            operation: .disableProtection,
            credentials: InMemoryTagCredentialStore()
        )

        let run = Task { await model.begin() }
        await untilGated(model)
        XCTAssertEqual(model.unlockStyle?.family, .type2)
        model.supplyUnlockCredential(.type2(password: Data([0xDE, 0xAD, 0xBE, 0xEF]), pack: Data()))
        model.confirm()
        await run.value

        XCTAssertEqual(model.phase, .needsUnlock)
        XCTAssertEqual(
            model.unlockStyle?.family, .type2,
            "the family is a fact about the chip, so the run that clears the reading must not clear it"
        )
    }

    // MARK: - Helpers

    private func untilGated(_ model: OperationsFlowModel) async {
        await until {
            switch model.phase {
            case .awaitingConfirmation, .needsUnlock, .done, .error: true
            default: false
            }
        }
    }
}

private final class SingleChipFactory: TagSessionFactory, @unchecked Sendable {
    private let chip: ChipSimulator

    init(chip: ChipSimulator) {
        self.chip = chip
    }

    func makeSession() -> TagSession {
        SimulatedSession(chip: chip)
    }
}

/// The same, counting sessions, so a test can assert that supplying a credential
/// resumed at tap 2 rather than opening a fresh pair of taps.
private final class CountingFactory: TagSessionFactory, @unchecked Sendable {
    private let chip: ChipSimulator
    private(set) var sessionsStarted = 0

    init(chip: ChipSimulator) {
        self.chip = chip
    }

    func makeSession() -> TagSession {
        sessionsStarted += 1
        return SimulatedSession(chip: chip)
    }
}
