@testable import HexNFCApp
@testable import HexNFCKit
@testable import HexNFCRecords
import HexNFCStorage
@testable import HexNFCTagSim
import XCTest

/// Operations and Memory dump with nothing in the field.
///
/// A confirming operation's first session is the identify tap, and a run that
/// never had a tag has read and written nothing, so an empty sheet there goes
/// back to the operation's start and a timeout says no tag was found. Memory
/// dump opens its sheet on arrival and has one tap, so its empty sheet is the
/// same case. Every ending after a tag, on this tap or an earlier one, keeps the
/// report it always had, including the half-burned lock's.
@MainActor
final class OperationsNoTagEndingTests: XCTestCase {
    private let password = Data([0x0A, 0x0B, 0x0C, 0x0D])
    private let pack = Data([0x1E, 0x2F])

    private func operation(_ operation: OperationsFlowModel.Operation,
                           _ factory: TagSessionFactory) -> OperationsFlowModel
    {
        OperationsFlowModel(factory: factory, operation: operation, credentials: InMemoryTagCredentialStore())
    }

    /// Drive a run to wherever it stops, confirming the typed-UID gate once.
    private func runConfirming(_ model: OperationsFlowModel) async {
        let run = Task { await model.begin() }
        await until {
            switch model.phase {
            case .awaitingConfirmation, .needsUnlock, .done, .cancelled, .noTagFound, .error: true
            default: false
            }
        }
        if case .awaitingConfirmation = model.phase {
            model.confirm()
        }
        await run.value
    }

    /// Start a run and stop it at the gate, which proves it identified a tag.
    ///
    /// Waits on the transition count as well as the phase. A model already
    /// sitting in `.error` would otherwise satisfy the wait before the run has
    /// moved at all, the `cancel()` below would land first, and the run would
    /// then reach the gate with nothing left to release it: a hang rather than
    /// a failure.
    private func expectTheGate(_ model: OperationsFlowModel, file: StaticString = #filePath, line: UInt = #line) async {
        let before = model.transitionCount
        let run = Task { await model.begin() }
        await until {
            guard model.transitionCount > before else { return false }
            switch model.phase {
            case .awaitingConfirmation, .cancelled, .noTagFound, .error: return true
            default: return false
            }
        }
        if case .awaitingConfirmation = model.phase {} else {
            XCTFail("expected tap 1 to reach the gate, got \(model.phase)", file: file, line: line)
        }
        model.cancel()
        await run.value
    }

    // MARK: - Nothing in the field

    func test_cancelOnTheIdentifyTapBeforeAnyTag_returnsToTheStart_andCanStartAgain() async throws {
        let chip = NTAG213Simulator()
        let factory = ScriptedSessionFactory(chip: chip, [.cancelled, .ready])
        let model = operation(.erase, factory)

        await model.begin()

        XCTAssertEqual(model.phase, .cancelled, "the start state again: warning and button, no error")
        XCTAssertNil(model.recovery, "and no offer, because nothing was presented to anything")
        let session = try factory.simulated(0)
        XCTAssertTrue(session.didInvalidate)
        XCTAssertNil(session.invalidationError)
        // The screen's button starts a new run from here.
        await expectTheGate(model)
    }

    func test_timeoutOnTheIdentifyTapBeforeAnyTag_isNoTagFound_andTryAgainIdentifies() async {
        let model = operation(.erase, ScriptedSessionFactory(chip: NTAG213Simulator(), [.timeout, .ready]))

        await model.begin()
        XCTAssertEqual(model.phase, .noTagFound)

        // The screen's Try again.
        model.retry()
        await expectTheGate(model)
    }

    // MARK: - A tag in this session

    func test_cancelWhileADetectedTagIsBeingIdentified_isStillReported() async {
        let model = operation(.erase, ScriptedSessionFactory(chip: NTAG213Simulator(), [.cancelledAfterDetection]))

        await model.begin()

        XCTAssertEqual(
            model.phase,
            .error(message: NoTagEndingCopy.cancelled, diagnostics: "simulator behaviour=cancelledAfterDetection")
        )
    }

    func test_timeoutWhileADetectedTagIsBeingIdentified_isStillReported() async {
        let model = operation(
            .permanentLock,
            ScriptedSessionFactory(chip: NTAG213Simulator(), [.timedOutAfterDetection])
        )

        await model.begin()

        XCTAssertEqual(
            model.phase,
            .error(message: NoTagEndingCopy.timedOut, diagnostics: "simulator behaviour=timedOutAfterDetection")
        )
    }

    // MARK: - A tag in an earlier session of the same run

    func test_cancelOnTheChangeTapAfterTheIdentifyTap_isStillReported() async throws {
        let message = try NDEFCodec.encode([NDEFRecord.uri(URIRecord(uri: "https://hex.pro"))])
        let chip = NTAG213Simulator(ndefMessage: message)
        let model = operation(.erase, ScriptedSessionFactory(chip: chip, [.ready, .cancelled]))

        await runConfirming(model)

        XCTAssertEqual(
            model.phase,
            .error(message: NoTagEndingCopy.cancelled, diagnostics: "simulator behaviour=cancelled")
        )
        XCTAssertFalse(try NDEFCodec.isEmptyMessage(chip.readNDEF()), "nothing was erased")
    }

    func test_timeoutOnTheChangeTapAfterTheIdentifyTap_isStillReported() async {
        let chip = NTAG213Simulator()
        let model = operation(.permanentLock, ScriptedSessionFactory(chip: chip, [.ready, .timeout]))

        await runConfirming(model)

        XCTAssertEqual(
            model.phase,
            .error(message: NoTagEndingCopy.timedOut, diagnostics: "simulator behaviour=timeout")
        )
        XCTAssertFalse(chip.isLockedPermanent)
    }

    /// A cancel on the retry after a lock that burned part of its bits and then
    /// failed. `retry()` does not clear what the run knows about contact: the
    /// tag in the field is the half-locked one, and quietly returning to the
    /// start would read as though nothing had happened to it.
    func test_cancelOnARetryAfterAHalfBurnedLock_isStillReported() async throws {
        let chip = NTAG213Simulator()
        let staticPage = try XCTUnwrap(chip.profile?.memoryLayout.lockPages.first)
        let faults = FaultInjectingSessionFactory(chip: chip)
        // The static lock write is acknowledged and never applied, so the
        // dynamic bits burn and verification then finds page 4 still writable.
        faults.arm(TagFault(.write(page: staticPage), .refused(response: Data([0x0A]), halts: false)))
        let factory = ScriptedSessionFactory([
            { faults.makeSession() },
            { faults.makeSession() },
            { SimulatedSession(chip: chip, behaviour: .cancelled) },
        ])
        let model = operation(.permanentLock, factory)

        await runConfirming(model)
        guard case .error = model.phase else {
            return XCTFail("a lock that cannot be verified is reported, got \(model.phase)")
        }
        XCTAssertEqual(model.observation?.lock?.regions[.dynamicLock], .allSet, "and what burned is published")

        model.retry()
        await model.begin()

        XCTAssertEqual(
            model.phase,
            .error(message: NoTagEndingCopy.cancelled, diagnostics: "simulator behaviour=cancelled")
        )
        XCTAssertEqual(factory.made.count, 3)
    }

    // MARK: - Memory dump

    func test_memoryDump_cancelBeforeAnyTag_isCancelled() async {
        let model = operation(.memoryDump, ScriptedSessionFactory(chip: NTAG213Simulator(), [.cancelled]))

        await model.begin()

        XCTAssertEqual(model.phase, .cancelled, "the screen goes back to the tile it was opened from")
    }

    func test_memoryDump_timeoutBeforeAnyTag_isNoTagFound_andTryAgainDumps() async throws {
        let chip = NTAG213Simulator()
        let model = operation(.memoryDump, ScriptedSessionFactory(chip: chip, [.timeout, .ready]))

        await model.begin()
        XCTAssertEqual(model.phase, .noTagFound)

        model.retry()
        await model.begin()
        guard case .done(.memoryDumped(let bytes)) = model.phase else {
            return XCTFail("Try again dumps the tag, got \(model.phase)")
        }
        XCTAssertEqual(bytes.count, try XCTUnwrap(chip.profile).readablePageCount * 4)
    }

    func test_memoryDump_cancelWhileADetectedTagIsBeingIdentified_isStillReported() async {
        let model = operation(.memoryDump, ScriptedSessionFactory(chip: NTAG213Simulator(), [.cancelledAfterDetection]))

        await model.begin()

        XCTAssertEqual(
            model.phase,
            .error(message: NoTagEndingCopy.cancelled, diagnostics: "simulator behaviour=cancelledAfterDetection")
        )
    }

    /// The unlock re-tap follows a tap that found the tag read-gated.
    func test_memoryDump_cancelOnTheUnlockRetap_isStillReported() async throws {
        let chip = NTAG213Simulator()
        try chip.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: true, authLimit: 0
        )
        let model = operation(.memoryDump, ScriptedSessionFactory(chip: chip, [.ready, .cancelled]))
        await model.begin()
        XCTAssertEqual(model.phase, .needsUnlock)

        await model.unlock(with: .type2(password: password, pack: pack))

        XCTAssertEqual(
            model.phase,
            .error(message: NoTagEndingCopy.cancelled, diagnostics: "simulator behaviour=cancelled")
        )
    }

    // MARK: - An ending nothing can vouch for

    /// An error from outside the kit on tap 1 may have come from a tag, so the
    /// empty sheet on the retry after it is reported too.
    func test_cancelOnARetryAfterAnErrorFromOutsideTheKitOnTheIdentifyTap_isStillReported() async {
        let model = operation(.erase, ScriptedSessionFactory([
            { ForeignErrorSession() },
            { SimulatedSession(chip: NTAG213Simulator(), behaviour: .cancelled) },
        ]))
        await model.begin()
        guard case .error = model.phase else {
            return XCTFail("an unaccounted error is reported, got \(model.phase)")
        }

        model.retry()
        await model.begin()

        XCTAssertEqual(
            model.phase,
            .error(message: NoTagEndingCopy.cancelled, diagnostics: "simulator behaviour=cancelled")
        )
    }

    /// Memory dump's one tap runs through `begin()`'s own catch rather than the
    /// identify tap's.
    func test_memoryDump_cancelOnARetryAfterAnErrorFromOutsideTheKit_isStillReported() async {
        let model = operation(.memoryDump, ScriptedSessionFactory([
            { ForeignErrorSession() },
            { SimulatedSession(chip: NTAG213Simulator(), behaviour: .cancelled) },
        ]))
        await model.begin()
        guard case .error = model.phase else {
            return XCTFail("an unaccounted error is reported, got \(model.phase)")
        }

        model.retry()
        await model.begin()

        XCTAssertEqual(
            model.phase,
            .error(message: NoTagEndingCopy.cancelled, diagnostics: "simulator behaviour=cancelled")
        )
    }

    // MARK: - A model replaced inside one presentation

    /// Set attempt limit's Start over builds a new model for the same screen.
    /// The run it replaces lost the tag on the ACCESS write, so nothing can say
    /// whether the limit landed, and the screen says as much. The replacement
    /// is told the old run had a tag, and the empty sheet on its first tap is
    /// reported as it would have been on the old model.
    func test_attemptLimit_aCancelAfterStartOverFromAnArmThatSlipped_isStillReported() async throws {
        let password = Data([0x11, 0x22, 0x33, 0x44])
        let chip = NTAG213Simulator()
        try chip.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let layout = try XCTUnwrap(Type2ConfigLayout.for(.ntag213))
        let faults = FaultInjectingSessionFactory(chip: chip)
        // The tag leaves the field as the ACCESS write goes out.
        faults.arm(TagFault(.write(page: layout.config1Page), .leavesTheField))
        let first = OperationsFlowModel(
            factory: faults, operation: .setAttemptLimit(limit: 3), credentials: InMemoryTagCredentialStore()
        )
        first.supplyUnlockCredential(.type2(password: password, pack: Data()))
        await runConfirming(first)
        guard case .error = first.phase else {
            return XCTFail("an arm that lost the tag is reported, got \(first.phase)")
        }
        XCTAssertTrue(faults.report.contains(.write(page: layout.config1Page)), "the arm had begun")
        XCTAssertTrue(first.mayHaveTouchedATag)

        // The screen's Start over, then Continue.
        let replacement = OperationsFlowModel(
            factory: ScriptedSessionFactory(chip: chip, [.cancelled]),
            operation: .setAttemptLimit(limit: 3),
            credentials: InMemoryTagCredentialStore(),
            earlierRunMayHaveTouchedATag: first.mayHaveTouchedATag
        )
        await replacement.begin()

        XCTAssertEqual(
            replacement.phase,
            .error(message: NoTagEndingCopy.cancelled, diagnostics: "simulator behaviour=cancelled")
        )
    }

    /// And a replacement whose predecessor never had a tag is as quiet as a
    /// fresh screen, which is the path a tap-1 cancel takes back to the stepper.
    func test_attemptLimit_aReplacementAfterAnEmptySheet_isStillQuiet() async {
        let first = operation(
            .setAttemptLimit(limit: 3),
            ScriptedSessionFactory(chip: NTAG213Simulator(), [.cancelled])
        )
        await first.begin()
        XCTAssertEqual(first.phase, .cancelled)
        XCTAssertFalse(first.mayHaveTouchedATag)

        let replacement = OperationsFlowModel(
            factory: ScriptedSessionFactory(chip: NTAG213Simulator(), [.cancelled]),
            operation: .setAttemptLimit(limit: 5),
            credentials: InMemoryTagCredentialStore(),
            earlierRunMayHaveTouchedATag: first.mayHaveTouchedATag
        )
        await replacement.begin()

        XCTAssertEqual(replacement.phase, .cancelled)
    }
}
