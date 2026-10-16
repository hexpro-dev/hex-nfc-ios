@testable import HexNFCApp
@testable import HexNFCKit
@testable import HexNFCRecords
import HexNFCStorage
@testable import HexNFCTagSim
import XCTest

/// The chip's failed-authentication limit, `AUTH_LIM`, is ACCESS bits 2-0 on an
/// NTAG21x or Ultralight EV1. A limit of N allows N wrong tries; the next one
/// stops the tag accepting its password (rev 3.2 §8.8.2, measured on NTAG213
/// 2026-09-14), and a tag that can no longer authenticate can no longer have
/// its protection removed. There is no command that undoes it.
///
/// It used to be a Stepper in the editor's Protection card, which put that
/// decision onto a preset: a `TagProtection` is deliberately not pinned to one
/// chip, the Library replays one across a whole stack of tags, and it travels in
/// `.hexnfc` exports. CLAUDE.md forbids exactly that shape for a permanent lock,
/// and this arms the same unrecoverable outcome, just deferred until somebody
/// mistypes.
///
/// So these tests pin the shape it moved to: one tag, its whole UID typed
/// between two taps, a refusal against a tag whose gate is open, one
/// authentication attempt per activation, and a read-back before it claims
/// anything.
@MainActor
final class AttemptLimitTests: XCTestCase {
    private let password = Data([0x11, 0x22, 0x33, 0x44])
    private let pack = Data([0xAA, 0xBB])

    /// A run of the operation, with the credential supplied through the model's
    /// one channel for one. The operation itself carries no credential: two
    /// homes for "what opens this tag" is the desync that cost the Ultralight C
    /// arm its caller-resolved key.
    private func model(
        limit: Int,
        password: Data? = nil,
        on simulator: ChipSimulator
    ) -> OperationsFlowModel {
        let model = OperationsFlowModel(
            factory: SingletonChipFactory(chip: simulator),
            operation: .setAttemptLimit(limit: limit),
            credentials: InMemoryTagCredentialStore()
        )
        model.supplyUnlockCredential(.type2(password: password ?? self.password, pack: Data()))
        return model
    }

    /// The ACCESS byte as the chip *holds* it, taken straight from the
    /// simulator's page store rather than through a READ.
    ///
    /// Deliberately not `readMemory`: a read-protected tag refuses that page
    /// until a password is presented, and a tag halted by a NAK refuses
    /// everything, so a helper built on a read could not assert "nothing
    /// changed" about either of the two states this file cares most about. The
    /// page number still comes from `Type2ConfigLayout`, never a literal: a
    /// wrong one would have the test reading a different page than the driver
    /// writes, agreeing with itself while disagreeing with the tag.
    private func access(of simulator: NTAG21xSimulator, layout: Type2ConfigLayout) -> UInt8 {
        let page = simulator.pages[layout.config1Page]
        return page[page.startIndex + Type2ConfigLayout.accessByteOffset]
    }

    // MARK: - It is a Dangerous Action, not a setting

    func test_theOperationConfirmsAgainstAUIDAndVerifies() {
        let op = OperationsFlowModel.Operation.setAttemptLimit(limit: 3)
        XCTAssertTrue(
            op.requiresUIDConfirmation,
            "arming AUTH_LIM is irreversible, so it must go through the two-tap typed-UID gate"
        )
        XCTAssertTrue(
            op.verifies,
            "an ACK is not proof: the ACCESS byte has to be read back"
        )
    }

    // MARK: - It refuses a tag whose gate is open

    /// The refusal lands on **tap 1**, before the user has typed a
    /// fourteen-character UID, and with nothing written. An attempt limit on a
    /// tag whose AUTH0 gates nothing protects nothing: all it does is take the
    /// password away from whoever owns the tag later.
    func test_refusesATagWhosePasswordGateIsOpen_beforeTheUIDIsEverTyped() async throws {
        let layout = try XCTUnwrap(Type2ConfigLayout.for(.ntag213))
        let simulator = NTAG213Simulator()
        let before = access(of: simulator, layout: layout)
        let model = model(limit: 3, on: simulator)

        await model.begin()

        guard case .error(_, let diagnostics) = model.phase else {
            return XCTFail("an unprotected tag must be refused, got \(model.phase)")
        }
        XCTAssertTrue(
            diagnostics.contains("AUTH0"),
            "the refusal must name the state it read, got: \(diagnostics)"
        )
        XCTAssertEqual(
            access(of: simulator, layout: layout), before,
            "a refused operation must not have touched the ACCESS byte"
        )
    }

    // MARK: - It arms the limit, and proves it

    func test_armsTheLimitOnAProtectedTagAndProvesItByReadingTheByteBack() async throws {
        let layout = try XCTUnwrap(Type2ConfigLayout.for(.ntag213))
        let simulator = NTAG213Simulator()
        try simulator.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let model = model(limit: 3, on: simulator)

        await runThroughTheGate(model)

        guard case .done(.attemptLimitSet(let limit, let verified)) = model.phase else {
            return XCTFail("expected the limit to be set, got \(model.phase)")
        }
        XCTAssertEqual(limit, 3)
        XCTAssertTrue(verified, "the ACCESS byte was readable, so the read-back must be the verdict")
        XCTAssertEqual(
            access(of: simulator, layout: layout) & Type2ConfigLayout.authLimMask, 3,
            "AUTH_LIM must hold the value the user asked for"
        )
    }

    /// The operation changes three bits and must leave the rest of the byte
    /// exactly as the tag reported it. PROT in particular: silently moving the
    /// read gate as a side effect of setting an attempt limit would be a second,
    /// unasked-for change to how the tag behaves.
    func test_leavesTheReadGateAndTheRestOfTheAccessByteAlone() async throws {
        let layout = try XCTUnwrap(Type2ConfigLayout.for(.ntag213))
        let simulator = NTAG213Simulator()
        try simulator.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: true, authLimit: 0
        )
        let before = access(of: simulator, layout: layout)
        let model = model(limit: 5, on: simulator)

        await runThroughTheGate(model)

        guard case .done(.attemptLimitSet(5, true)) = model.phase else {
            return XCTFail("expected a proven limit of 5, got \(model.phase)")
        }
        let after = access(of: simulator, layout: layout)
        XCTAssertEqual(after & Type2ConfigLayout.authLimMask, 5)
        XCTAssertNotEqual(
            after & Type2ConfigLayout.protBitMask, 0,
            "the read gate was on before and must still be on"
        )
        XCTAssertEqual(
            after & ~(Type2ConfigLayout.protBitMask | Type2ConfigLayout.authLimMask),
            before & ~(Type2ConfigLayout.protBitMask | Type2ConfigLayout.authLimMask),
            "every bit outside PROT and AUTH_LIM must survive the read-modify-write"
        )
    }

    // MARK: - One authentication attempt per activation

    /// A refused `PWD_AUTH` NAKs, and a NAK returns a Type-2 chip to HALT for the
    /// rest of the activation, so a second password is always a second tap. If a
    /// retry ever creeps into this operation the simulator will count it, because
    /// its halt modelling means every frame after the NAK draws nothing at all.
    func test_aWrongPasswordSpendsExactlyOneAttemptAndChangesNothing() async throws {
        let layout = try XCTUnwrap(Type2ConfigLayout.for(.ntag213))
        let simulator = NTAG213Simulator()
        try simulator.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let before = access(of: simulator, layout: layout)
        let model = model(limit: 3, password: Data([0xDE, 0xAD, 0xBE, 0xEF]), on: simulator)

        await runThroughTheGate(model)

        // The refusal reaches the unlock prompt now rather than an error card:
        // tap 2 runs the shared preamble, so a credential the chip will not take
        // is caught before the ACCESS write and the user is asked for another.
        XCTAssertEqual(model.phase, .needsUnlock, "a wrong password must not arm anything, got \(model.phase)")
        XCTAssertEqual(
            simulator.failedAuthAttempts, 1,
            "exactly one PWD_AUTH may reach the chip in one activation"
        )
        XCTAssertEqual(
            access(of: simulator, layout: layout), before,
            "the ACCESS byte must be untouched when the gate never opened"
        )
    }

    /// A plain `retry()` forgets the credential, so the tag is not asked twice
    /// for one mistyped password.
    ///
    /// It used to keep it. The operation carried the credential, `retry()` put
    /// the requested operation back, and the next run therefore put the same
    /// refused password on the wire: one mistype, two counted `PWD_AUTH`s, on
    /// the one screen in the app that arms `AUTH_LIM`. A tag arriving with three
    /// tries left could be spent by three presses of a button reading "Try
    /// again".
    ///
    /// Now the credential lives on the model and `retry()` clears it, so the
    /// second run reaches tap 2 holding nothing and refuses before composing a
    /// frame. The screens still hand the form back rather than calling
    /// `retry()` at all (`OperationsSheetAffordanceTests`); this is what makes
    /// the model safe whichever route reaches it.
    func test_aPlainRetryDropsTheCredentialSoNoSecondTryIsSpent() async throws {
        let simulator = NTAG213Simulator()
        try simulator.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 3
        )
        let wrong = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let model = model(limit: 3, password: wrong, on: simulator)

        await runThroughTheGate(model)
        XCTAssertEqual(simulator.failedAuthAttempts, 1, "the first run spends one counted attempt")

        model.retry()

        XCTAssertNil(
            model.unlockCredential,
            "the refused password may not survive into the next run: the chip counts every try and "
                + "nothing on screen said one had been spent"
        )

        await runThroughTheGate(model)

        XCTAssertEqual(
            simulator.failedAuthAttempts, 1,
            "the second run held no credential, so the gate never opened and no PWD_AUTH was composed"
        )
    }

    // MARK: - What the tag already holds

    /// Tap 1 reads the ACCESS byte to establish the gate is armed at all, so the
    /// limit the tag already carries is in hand by the time the user is asked to
    /// type its UID. This is the only place in the app that reports it.
    func test_tapOneReportsTheLimitTheTagAlreadyCarries() async throws {
        let simulator = NTAG213Simulator()
        try simulator.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 2
        )
        let model = model(limit: 4, on: simulator)

        let run = Task { await model.begin() }
        await untilConfirmable(model)
        XCTAssertEqual(model.detectedAttemptLimit, 2)
        model.cancel()
        await run.value
        XCTAssertNil(model.detectedAttemptLimit, "cancelling must not leave a reading behind")
    }

    /// A read-protected tag keeps its configuration pages out of reach until a
    /// password is presented, so tap 1 learns that the gate is armed and nothing
    /// else. `nil` says that. Reporting `0` would be an invention with a number
    /// on it, and this app has already shipped one flow that asserted protection
    /// state it never read.
    func test_readProtectedTagReportsNoReadingRatherThanZero() async throws {
        let simulator = NTAG213Simulator()
        try simulator.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: true, authLimit: 3
        )
        let model = model(limit: 4, on: simulator)

        let run = Task { await model.begin() }
        await untilConfirmable(model)
        XCTAssertNil(
            model.detectedAttemptLimit,
            "the ACCESS byte was unreadable, so there is nothing to report"
        )
        model.cancel()
        await run.value
    }

    /// A wrong password on this screen, on a tag whose `AUTH_LIM` it cannot
    /// read, must not come back with copy that invites the same password again.
    ///
    /// This is the screen that arms the counter, and a read-gated tag is the one
    /// shape whose counter the app cannot watch: `AUTH_LIM` lives behind the
    /// gate being opened. Unqualified, the refusal reads "Couldn't check the
    /// password: the tag stopped answering. Hold it steady…", which is an
    /// invitation to spend another try on a tag that may have one left.
    ///
    /// The qualification is `authenticateThroughAReadGate`'s, and this is what
    /// pins the screen to it: the raw primitive is still right here, because
    /// `openGate`'s state read is the very read such a tag refuses.
    func test_aWrongPasswordOnAReadGatedTagSaysTheTryMayHaveCounted() async throws {
        let simulator = NTAG213Simulator()
        try simulator.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: true, authLimit: 1
        )
        let model = model(limit: 4, password: Data([0xDE, 0xAD, 0xBE, 0xEF]), on: simulator)

        await runThroughTheGate(model)

        XCTAssertEqual(model.phase, .needsUnlock, "a wrong password must stop the run, got \(model.phase)")
        let refusal = try XCTUnwrap(model.unlockRefusal)
        let message = String(localized: refusal.userMessage)
        XCTAssertNotEqual(
            message, String(localized: TagError.authInconclusive().userMessage),
            "\"hold it steady and try again\" is the copy that invites the next counted try"
        )
        XCTAssertTrue(message.contains("attempt limit"), "Got: \(message)")
        XCTAssertNotNil(
            refusal.unlockPromptCopy,
            "and the prompt has to show the driver's words rather than its own neutral first-run copy"
        )
        XCTAssertFalse(simulator.isAuthLocked, "the fixture keeps a try in hand at a limit of 1")
    }

    // MARK: - Helpers

    private func runThroughTheGate(_ model: OperationsFlowModel) async {
        let run = Task { await model.begin() }
        await untilConfirmable(model)
        // The gate refuses to open for a run that needs a credential and holds
        // none, which some of these fixtures are deliberately in. Confirming
        // such a run leaves `begin()` suspended on its continuation, which hangs
        // the suite rather than failing it, so ask the same question the gate
        // asks and cancel instead.
        if model.requiresUnlockCredential, model.unlockCredential == nil {
            model.cancel()
        } else {
            model.confirm()
        }
        await run.value
    }
}

@MainActor
private func untilConfirmable(_ model: OperationsFlowModel) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while ContinuousClock.now < deadline {
        if case .awaitingConfirmation = model.phase {
            return
        }
        if case .needsUnlock = model.phase {
            return
        }
        if case .error = model.phase {
            return
        }
        await Task.yield()
    }
}

/// Hands out sessions over one shared simulator, so tap 1 and tap 2 see the same
/// chip state. Each session still calls `beginActivation()`, so tap 2 starts
/// unauthenticated exactly as a re-selected tag does.
private final class SingletonChipFactory: TagSessionFactory, @unchecked Sendable {
    private let chip: ChipSimulator
    init(chip: ChipSimulator) {
        self.chip = chip
    }

    func makeSession() -> TagSession {
        SimulatedSession(chip: chip)
    }
}

/// Two source-text guards, walked off disk through `#filePath`.
///
/// `ProtectionConfigSheet.swift` is `#if os(iOS)`, so `swift test` on macOS never
/// compiles it and no ordinary assertion can reach it. And "nothing anywhere
/// reports a remaining attempt count" is a property of the whole tree rather
/// than of any one type, which is the same reason
/// `PromoImportContainmentTests` reads its sources rather than its module.
final class AttemptLimitContainmentTests: XCTestCase {
    private static var appRoot: URL {
        URL(fileURLWithPath: #filePath) // …/app/Tests/HexNFCAppTests/AttemptLimitTests.swift
            .deletingLastPathComponent() // …/HexNFCAppTests
            .deletingLastPathComponent() // …/Tests
            .deletingLastPathComponent() // …/app
    }

    private func swiftFiles(under relativePath: String) throws -> [URL] {
        let root = Self.appRoot.appendingPathComponent(relativePath, isDirectory: true)
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "swift" {
                files.append(url)
            }
        }
        XCTAssertFalse(files.isEmpty, "found no sources under \(relativePath); the guard would be inert")
        return files
    }

    /// No chip this app drives reports how many attempts a tag has left.
    ///
    /// A Type-2 refusal is a payload-free NAK, Ultralight C has no attempt limit
    /// at all (MF0ICU2), ICODE SLIX2 answers the generic `0F` to every refusal,
    /// and NTAG424 DNA answers `91 9D` / `91 AE`. `TagError.authFailed` therefore
    /// carries no count, and the NTAG21x simulator no longer computes one either:
    /// it used to, which is what made a field every production site passed `nil`
    /// to look like something the silicon could fill.
    ///
    /// The one standard that really does define a retry counter is an eMRTD's
    /// ISO 7816-4 `63 CX`, which `EPassportReader` does not parse. If that is ever
    /// wanted it arrives as a passport-specific value on a parsed status word, and
    /// this guard is where to come and say so.
    func test_noSourceReportsARemainingAttemptCount() throws {
        // The needle has to be built rather than written, or this file would be
        // its own first offender: the guard cannot name the thing it forbids.
        let needle = "attempts" + "Remaining"
        var offenders: [String] = []
        for path in ["Sources", "Tests"] {
            for url in try swiftFiles(under: path) {
                let text = try String(contentsOf: url, encoding: .utf8)
                if text.contains(needle) {
                    offenders.append(url.lastPathComponent)
                }
            }
        }
        XCTAssertEqual(
            offenders, [],
            "these files report a remaining attempt count: \(offenders). No chip in the catalogue "
                + "discloses one, so any number here is invented. See TagError.Kind.authFailed."
        )
    }

    /// The editor's Protection card cannot carry an attempt limit.
    ///
    /// Deleting the Stepper alone would not have been enough: the sheet also
    /// *seeded* itself from the scanned tag's value, so a tag arriving with a
    /// limit of 3 pre-loaded 3 and Done silently re-committed it. The only
    /// mention left is the normalisation that writes 0.
    ///
    /// That normalisation only runs when someone opens the card and presses
    /// Done, so it is not what makes the rule hold. A settings object can carry
    /// a limit that never passed through here at all: "Save as preset" on a
    /// scanned tag stores the value read off that tag, an imported `.hexnfc`
    /// carries `TagProtection` whole, and rows saved before this change keep
    /// what they held. The rule holds because `ProtectionSpec.make` applies 0
    /// whatever the settings say, which is the choke point every batchable write
    /// passes through. See
    /// `ProtectionSpecTests.test_make_type2_neverAppliesAnAttemptLimit_whateverTheSettingsCarry`.
    /// This test guards the affordance; that one guards the outcome.
    func test_theProtectionCardCannotCarryAnAttemptLimit() throws {
        let url = Self.appRoot
            .appendingPathComponent("Sources/HexNFCApp/Screens/ProtectionConfigSheet.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        let mentions = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("authLimit") && !$0.hasPrefix("//") && !$0.hasPrefix("///") }
        XCTAssertEqual(
            mentions, ["settings.authLimit = 0"],
            "the Protection card writes a preset, and a preset is not pinned to one tag. The only "
                + "line here that may name authLimit is the one that clears it."
        )
    }
}
