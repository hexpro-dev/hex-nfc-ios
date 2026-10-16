@testable import HexNFCApp
@testable import HexNFCKit
@testable import HexNFCRecords
import HexNFCStorage
@testable import HexNFCTagSim
import XCTest

/// The Operations arm builds its `ProtectionSpec` through `ProtectionSpec.make`
/// like every other caller.
///
/// `make` is the choke point that forces `authLimit: 0` and pins a read gate to
/// the chip's own first data page. Both rules exist because getting them wrong
/// strands a tag: a non-zero limit destroys it after that many wrong passwords,
/// and a read gate above the first data page makes `Type2PasswordDriver.readState`
/// unable to recognise the roll-over, so every later unlock, rewrite and removal
/// reports that the owner's correct password did not open the tag.
///
/// `ProtectWithPasswordOperationView.launch()` used to assemble the spec itself,
/// `protectFromPage: 4` spelled in the screen, and was the only shipped caller
/// that went round both. These tests are what make going round it again fail.
@MainActor
final class OperationsArmSpecTests: XCTestCase {
    private let password = Data([0x0A, 0x0B, 0x0C, 0x0D])
    private let pack = Data([0x1E, 0x2F])

    private func arm(_ settings: TagProtection, on chip: ChipSimulator) -> OperationsFlowModel {
        OperationsFlowModel(
            factory: SingleChipFactory(chip: chip),
            operation: .enableProtection(PendingProtection(
                settings: settings,
                credential: .type2(password: password, pack: pack)
            )),
            credentials: InMemoryTagCredentialStore()
        )
    }

    // MARK: - The two rules the choke point exists for

    /// Settings can arrive carrying a limit without anyone choosing one here: a
    /// scanned tag's own `AUTH_LIM` reads back into `detectedProtection`, "Save
    /// as preset" stores it verbatim, and an imported `.hexnfc` carries a whole
    /// `TagProtection`. Every one of those now reaches the silicon through
    /// `make`, which writes zero.
    func test_theArmNeverWritesAnAttemptLimitWhateverTheSettingsCarry() async throws {
        let layout = try XCTUnwrap(Type2ConfigLayout.for(.ntag213))
        let chip = NTAG213Simulator()
        let model = arm(
            TagProtection(passwordProtect: true, protectFromPage: 4, readProtect: false, authLimit: 7),
            on: chip
        )

        await runToCompletion(model)

        guard case .done(.passwordSet) = model.phase else {
            return XCTFail("expected the arm to complete, got \(model.phase)")
        }
        let access = chip.pages[layout.config1Page]
        XCTAssertEqual(
            access[access.startIndex + Type2ConfigLayout.accessByteOffset] & Type2ConfigLayout.authLimMask,
            0,
            "arming an attempt limit is a standalone, UID-confirmed Dangerous Action and may never "
                + "ride in on a settings object"
        )
    }

    /// A read gate has to start at the chip's first data page or the driver
    /// cannot recognise the roll-over that identifies a read-gated tag, and the
    /// tag is then unreachable through this app.
    func test_aReadGateIsPinnedToTheChipsFirstDataPage() async throws {
        let layout = try XCTUnwrap(Type2ConfigLayout.for(.ntag213))
        let chip = NTAG213Simulator()
        let firstDataPage = try XCTUnwrap(chip.profile?.memoryLayout.ndefRange?.lowerBound)
        let model = arm(
            TagProtection(passwordProtect: true, protectFromPage: 20, readProtect: true),
            on: chip
        )

        await runToCompletion(model)

        guard case .done(.passwordSet) = model.phase else {
            return XCTFail("expected the arm to complete, got \(model.phase)")
        }
        let config0 = chip.pages[layout.config0Page]
        XCTAssertEqual(
            Int(config0[config0.startIndex + Type2ConfigLayout.auth0ByteOffset]), firstDataPage,
            "a read gate above the first data page leaves the tag unreachable through this app"
        )
    }

    /// And the page the arm resolves comes from the tag it connected to, not
    /// from a number written in a screen. The screen no longer has one.
    func test_anArmWithNoStartPageResolvesItAgainstTheTag() async throws {
        let layout = try XCTUnwrap(Type2ConfigLayout.for(.ntag215))
        let chip = NTAG215Simulator()
        let firstDataPage = try XCTUnwrap(chip.profile?.memoryLayout.ndefRange?.lowerBound)
        let model = arm(TagProtection(passwordProtect: true), on: chip)

        await runToCompletion(model)

        guard case .done(.passwordSet) = model.phase else {
            return XCTFail("expected the arm to complete, got \(model.phase)")
        }
        let config0 = chip.pages[layout.config0Page]
        XCTAssertEqual(
            Int(config0[config0.startIndex + Type2ConfigLayout.auth0ByteOffset]), firstDataPage
        )
    }

    // MARK: - A credential that does not match the settings

    /// `make` answers nil for a mismatch, which the caller has to surface rather
    /// than dispatch. Before, the mismatch reached driver dispatch instead, which
    /// is after the point of no return on the other families.
    func test_aCredentialFromAnotherFamilyIsRefusedByTheArm() async {
        let model = OperationsFlowModel(
            factory: SingleChipFactory(chip: NTAG213Simulator()),
            operation: .enableProtection(PendingProtection(
                // Type-2 settings, so the preamble's own chip guard is happy and
                // the mismatch is the one `make` answers nil for.
                settings: TagProtection(passwordProtect: true),
                credential: .type4(aesKey: Data(repeating: 0, count: 16), keySlot: 0)
            )),
            credentials: InMemoryTagCredentialStore()
        )

        await runToCompletion(model)

        guard case .error(_, let diagnostics) = model.phase else {
            return XCTFail("an AES key cannot arm Type-2 settings, got \(model.phase)")
        }
        XCTAssertTrue(diagnostics.contains("doesn't match"), "Got: \(diagnostics)")
    }

    /// The other mismatch, and it is refused a tap earlier. Settings built for a
    /// family this chip does not have never reach the spec at all: the preamble's
    /// chip guard sees them on the identify tap, before the user types a UID.
    func test_settingsForAnotherFamilyAreRefusedOnTheIdentifyTap() async {
        let model = OperationsFlowModel(
            factory: SingleChipFactory(chip: NTAG213Simulator()),
            operation: .enableProtection(PendingProtection(
                settings: TagProtection(passwordProtect: true, style: .type4(.init())),
                credential: .type2(password: password, pack: pack)
            )),
            credentials: InMemoryTagCredentialStore()
        )

        await runToCompletion(model)

        guard case .error(_, let diagnostics) = model.phase else {
            return XCTFail("Type-4 settings cannot arm an NTAG213, got \(model.phase)")
        }
        XCTAssertTrue(diagnostics.contains("staged type4"), "Got: \(diagnostics)")
    }

    // MARK: - Restating what the run will arm

    func test_supplyProtectionRestatesTheArmAndIsInertOnEverythingElse() {
        let chip = NTAG213Simulator()
        let model = arm(TagProtection(passwordProtect: true), on: chip)
        let restated = PendingProtection(
            settings: TagProtection(passwordProtect: true, readProtect: true),
            credential: .type2(password: Data([0xDE, 0xAD, 0xBE, 0xEF]), pack: pack)
        )

        model.supplyProtection(restated)

        XCTAssertEqual(model.operation, .enableProtection(restated))

        let erase = OperationsFlowModel(
            factory: SingleChipFactory(chip: chip),
            operation: .erase,
            credentials: InMemoryTagCredentialStore()
        )
        erase.supplyProtection(restated)
        XCTAssertEqual(erase.operation, .erase, "an erase has no protection to restate")
    }

    /// The arm is staged **at** the typed-UID gate, and frozen once a session is
    /// open.
    ///
    /// The window matters and the two halves used to be one rule. This was
    /// guarded on "no run is in flight", which reads right and is the wrong
    /// question: `begin()` is suspended on its continuation at the gate, so the
    /// run *is* in flight there, and refusing the gate refused the only phase
    /// the Protect screen can collect anything in. The screen renders its fields
    /// from the identify tap's reading, so the reading and the gate arrive
    /// together and the arm is filled in between them. The rule that survives is
    /// the one about the tag: nothing may change what the next frame carries
    /// while a session is open, which is `isHoldingATag`, exactly as
    /// `supplyUnlockCredential` has it.
    func test_theArmIsStagedAtTheGateAndFrozenUnderALiveSession() async {
        let chip = NTAG213Simulator()
        let model = OperationsFlowModel(
            factory: StallingFactory(chip: chip),
            operation: .enableProtection(PendingProtection(
                settings: TagProtection(passwordProtect: true),
                credential: .type2(password: password, pack: pack)
            )),
            credentials: InMemoryTagCredentialStore()
        )
        let staged = PendingProtection(
            settings: TagProtection(passwordProtect: true, readProtect: true),
            credential: .type2(password: Data([0xDE, 0xAD, 0xBE, 0xEF]), pack: pack)
        )

        let run = Task { await model.begin() }
        await until {
            if case .awaitingConfirmation = model.phase {
                return true
            }
            return false
        }
        model.supplyProtection(staged)
        XCTAssertEqual(
            model.operation, .enableProtection(staged),
            "the gate is the window with no session open, so it is where the arm is collected"
        )

        // Tap 2's session is held open on its poll, so the run is now holding a
        // tag with nothing typed against it.
        model.confirm()
        await until {
            if case .polling = model.phase {
                return true
            }
            return false
        }
        model.supplyProtection(PendingProtection(
            settings: TagProtection(passwordProtect: true),
            credential: .type2(password: Data([0x11, 0x22, 0x33, 0x44]), pack: pack)
        ))
        XCTAssertEqual(
            model.operation, .enableProtection(staged),
            "settings swapped under a live session would be applied by a tap the user set up for "
                + "different ones"
        )

        model.cancel()
        run.cancel()
        _ = await run.result
    }

    // MARK: - Helpers

    private func runToCompletion(_ model: OperationsFlowModel) async {
        let run = Task { await model.begin() }
        await until {
            switch model.phase {
            case .awaitingConfirmation, .needsUnlock, .done, .error: true
            default: false
            }
        }
        if case .awaitingConfirmation = model.phase {
            model.confirm()
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

private final class SingleChipFactory: TagSessionFactory, @unchecked Sendable {
    private let chip: ChipSimulator

    init(chip: ChipSimulator) {
        self.chip = chip
    }

    func makeSession() -> TagSession {
        SimulatedSession(chip: chip)
    }
}

/// Identifies normally on tap 1 and then holds tap 2 open on its poll.
///
/// The only way to observe the model with a session open and nothing else
/// happening. A simulated session connects immediately, so a run that gets past
/// the gate is through `.executing` before a test can look at it, and the guard
/// this exists for is precisely about the window where a tag is in the field.
private final class StallingFactory: TagSessionFactory, @unchecked Sendable {
    private let chip: ChipSimulator
    private let lock = NSLock()
    private var taps = 0

    init(chip: ChipSimulator) {
        self.chip = chip
    }

    func makeSession() -> TagSession {
        lock.lock()
        taps += 1
        let tap = taps
        lock.unlock()
        return tap == 1 ? SimulatedSession(chip: chip) : StalledSession()
    }
}

private final class StalledSession: TagSession, @unchecked Sendable {
    func start(alert _: String) async throws -> ConnectedTag {
        // Sleeping rather than suspending on a continuation, so cancelling the
        // run is what ends it and the test cannot leak a task.
        while true {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func updateAlert(_: String) async {}

    func invalidate(error _: String?) async {}
}
