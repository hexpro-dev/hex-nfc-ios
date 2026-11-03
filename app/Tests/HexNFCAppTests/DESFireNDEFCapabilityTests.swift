@testable import HexNFCApp
@testable import HexNFCKit
@testable import HexNFCRecords
import HexNFCStorage
@testable import HexNFCTagSim
import XCTest

/// A DESFire's NDEF support belongs to the card, not the chip, so the tag card
/// and Erase have to take it from what the card says.
///
/// The tag card used to show "Supports: Raw commands" for every DESFire,
/// including one set up as an NDEF tag whose records were on the same screen,
/// and Erase refused that card in preflight for want of a Write it could do.
final class DESFireNDEFCapabilityTests: XCTestCase {
    @MainActor
    func test_scanOfAnNDEFCard_listsReadAndWrite() async throws {
        let message = try NDEFCodec.encode([.text(TextRecord(text: "hello"))])
        let model = ScanFlowModel(factory: SimulatedSessionFactory(makeChip: {
            DESFireEV3Simulator.ndefFormatted(message: message)
        }))

        await model.begin()

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.records.count, 1)
        XCTAssertEqual(model.scannedTagInfo?.capabilitySummary, "Read, Write, Raw commands")
    }

    @MainActor
    func test_scanOfAFactoryCard_stillListsRawCommandsAlone() async {
        let model = ScanFlowModel(factory: SimulatedSessionFactory(makeChip: { DESFireEV3Simulator() }))

        await model.begin()

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.scannedTagInfo?.capabilitySummary, "Raw commands")
    }

    @MainActor
    func test_erase_clearsAnNDEFCard() async throws {
        let message = try NDEFCodec.encode([.uri(URIRecord(uri: "https://hex.pro"))])
        let simulator = DESFireEV3Simulator.ndefFormatted(message: message)

        let phase = await runErase(on: simulator)

        guard case .done(.erased) = phase else {
            return XCTFail("expected .done(.erased), got \(phase)")
        }
        let left = try XCTUnwrap(simulator.ndefApplication?.message)
        XCTAssertTrue(NDEFCodec.isEmptyMessage(left), "card still holds \(left.hexString)")
    }

    /// Refused in preflight, after the card has been asked, and before any
    /// write reaches it.
    @MainActor
    func test_erase_refusesAFactoryCard() async {
        let simulator = DESFireEV3Simulator()

        let phase = await runErase(on: simulator)

        guard case .error = phase else {
            return XCTFail("expected an error on a card with no NDEF application, got \(phase)")
        }
        XCTAssertNil(simulator.ndefApplication)
    }

    @MainActor
    private func runErase(on simulator: DESFireEV3Simulator) async -> OperationsFlowModel.Phase {
        await run(.erase, on: simulator).phase
    }

    @MainActor
    private func run(
        _ operation: OperationsFlowModel.Operation,
        on simulator: ChipSimulator
    ) async -> OperationsFlowModel {
        let model = OperationsFlowModel(
            factory: SingletonChipFactory(chip: simulator),
            operation: operation,
            credentials: InMemoryTagCredentialStore()
        )
        let runTask = Task { await model.begin() }
        await waitFor {
            switch model.phase {
            case .awaitingConfirmation, .error: true
            default: false
            }
        }
        if case .awaitingConfirmation = model.phase {
            // A DESFire has no protection backend, so there is no credential the
            // screen could collect. Asking for one left `confirm()` waiting on it
            // for good.
            XCTAssertFalse(model.requiresUnlockCredential, "nothing to ask for on a chip with no protection backend")
            model.confirm()
        }
        // Waits on the phase rather than on `begin()`, so a run that stalls
        // fails with the phase it stalled in instead of hanging the suite.
        await waitFor(timeout: .seconds(5)) {
            switch model.phase {
            case .done, .error, .needsUnlock: true
            default: false
            }
        }
        runTask.cancel()
        return model
    }

    // MARK: - Format sets a blank card up

    @MainActor
    func test_format_setsUpABlankCard_andTheEditorAndScanSeeIt() async throws {
        let simulator = DESFireEV3Simulator()

        let model = await run(.format, on: simulator)

        guard case .done(.ndefApplicationCreated) = model.phase else {
            return XCTFail("expected .done(.ndefApplicationCreated), got \(model.phase)")
        }
        XCTAssertEqual(simulator.ndefAccess, .readWrite)
        XCTAssertEqual(simulator.violations, [])
        let observation = try XCTUnwrap(model.observation)
        XCTAssertEqual(observation.ndefAccess, .readWrite)
        XCTAssertEqual(observation.formatted, true)

        // The editor that sent the user to Format, for this card.
        let editor = EditFlowModel(
            tag: ScannedTagInfo(
                chipName: simulator.profile?.displayName,
                uidHex: simulator.uid.hexString,
                capabilitySummary: "Raw commands",
                formatState: .noNDEFApplication
            ),
            origin: .liveScan
        )
        XCTAssertTrue(editor.apply(observation))
        XCTAssertEqual(editor.tag?.capabilitySummary, "Read, Write, Raw commands")
        XCTAssertEqual(editor.tag?.formatState, .unknown, "the notice goes")

        let scan = ScanFlowModel(factory: SingletonChipFactory(chip: simulator))
        await scan.begin()
        XCTAssertEqual(scan.scannedTagInfo?.capabilitySummary, "Read, Write, Raw commands")
    }

    @MainActor
    func test_format_onACardAlreadySetUp_writesNothing() async {
        let model = await run(.format, on: DESFireEV3Simulator.ndefFormatted())
        guard case .done(.ndefAlreadySetUp) = model.phase else {
            return XCTFail("expected .done(.ndefAlreadySetUp), got \(model.phase)")
        }
    }

    /// The transit card is refused on the first tap, before the typed-UID gate,
    /// with nothing sent that changes it.
    @MainActor
    func test_format_refusesATransitCardOnTheFirstTap() async {
        let simulator = DESFireEV3Simulator.personalised()
        let model = await run(.format, on: simulator)
        guard case .error = model.phase else {
            return XCTFail("expected an error, got \(model.phase)")
        }
        XCTAssertNil(model.reading, "refused before tap 1 produced the reading the typed-UID gate shows")
        XCTAssertEqual(simulator.applicationIDs.count, 2)
        XCTAssertEqual(simulator.violations, [])
    }

    // MARK: - Remove NDEF setup takes it off again

    @MainActor
    func test_remove_returnsASetUpCardToBlank_andTheEditorSeesIt() async throws {
        let message = try NDEFCodec.encode([.text(TextRecord(text: "hello"))])
        let simulator = DESFireEV3Simulator.ndefFormatted(message: message)

        let model = await run(.removeNDEFSetup, on: simulator)

        guard case .done(.ndefSetupRemoved) = model.phase else {
            return XCTFail("expected .done(.ndefSetupRemoved), got \(model.phase)")
        }
        XCTAssertEqual(simulator.applications, [])
        XCTAssertEqual(simulator.authenticationAttempts, 1)
        XCTAssertEqual(simulator.violations, [])
        let observation = try XCTUnwrap(model.observation)
        XCTAssertEqual(observation.ndefAccess, .notSupported)
        XCTAssertEqual(observation.records, [])

        let editor = EditFlowModel(
            records: [.text(TextRecord(text: "hello"))],
            tag: ScannedTagInfo(
                chipName: simulator.profile?.displayName,
                uidHex: simulator.uid.hexString,
                capabilitySummary: "Read, Write, Raw commands"
            ),
            origin: .liveScan
        )
        XCTAssertTrue(editor.apply(observation))
        XCTAssertEqual(editor.tag?.capabilitySummary, "Raw commands")
        XCTAssertEqual(editor.tag?.formatState, .noNDEFApplication, "the notice points back at Format")
        XCTAssertTrue(editor.records.isEmpty)
    }

    @MainActor
    func test_remove_onABlankCard_changesNothing() async {
        let simulator = DESFireEV3Simulator()
        let model = await run(.removeNDEFSetup, on: simulator)
        guard case .done(.alreadyBlank) = model.phase else {
            return XCTFail("expected .done(.alreadyBlank), got \(model.phase)")
        }
        XCTAssertEqual(simulator.authenticationAttempts, 0)
    }

    @MainActor
    func test_remove_refusesATransitCardOnTheFirstTap() async {
        let simulator = DESFireEV3Simulator.personalised()
        let model = await run(.removeNDEFSetup, on: simulator)
        guard case .error = model.phase else {
            return XCTFail("expected an error, got \(model.phase)")
        }
        XCTAssertNil(model.reading)
        XCTAssertEqual(simulator.authenticationAttempts, 0, "the factory key is never presented to it")
        XCTAssertEqual(simulator.applicationIDs.count, 2)
    }

    @MainActor
    func test_remove_refusesATagThatIsNotADESFire() async {
        let model = await run(.removeNDEFSetup, on: NTAG213Simulator())
        guard case .error = model.phase else {
            return XCTFail("expected an error, got \(model.phase)")
        }
        XCTAssertNil(model.reading)
    }
}

private func waitFor(timeout: Duration = .milliseconds(500), _ predicate: @MainActor () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await predicate() {
            return
        }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }
}

/// A factory that always vends a fresh session over the *same chip simulator*,
/// so a write and the verify-read that follows see the same memory.
private final class SingletonChipFactory: TagSessionFactory, @unchecked Sendable {
    let chip: ChipSimulator

    init(chip: ChipSimulator) {
        self.chip = chip
    }

    func makeSession() -> TagSession {
        SimulatedSession(chip: chip)
    }
}
