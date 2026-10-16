@testable import HexNFCApp
@testable import HexNFCKit
@testable import HexNFCRecords
import HexNFCStorage
@testable import HexNFCTagSim
import XCTest

/// Write with nothing in the field, and the invariant that bounds it.
///
/// A write that never had a tag has written nothing, so an empty sheet the user
/// closed puts them back at Write and a timeout says no tag was found. A write
/// that has had a tag on *any* tap may already have changed it: the identify
/// tap read it, an earlier write tap may have armed half a password. Those keep
/// their report exactly, because a quiet close there would hide a half-finished
/// change behind a dismissed sheet.
@MainActor
final class WriteNoTagEndingTests: XCTestCase {
    private let password = Data([0x11, 0x22, 0x33, 0x44])
    private let pack = Data([0xAA, 0xBB])
    private let records: [NDEFRecord] = [.uri(URIRecord(uri: "https://hex.pro"))]

    private func armingProtection() -> PendingProtection {
        PendingProtection(
            settings: TagProtection(passwordProtect: true, protectFromPage: 4, readProtect: false, authLimit: 0),
            credential: .type2(password: password, pack: pack)
        )
    }

    private func plainWrite(_ factory: TagSessionFactory) -> WriteFlowModel {
        WriteFlowModel(
            factory: factory, dataArea: .replace(records), credentials: InMemoryTagCredentialStore(),
            uidConfirmation: .required
        )
    }

    private func armingWrite(_ factory: TagSessionFactory) -> WriteFlowModel {
        WriteFlowModel(
            factory: factory, dataArea: .replace(records), credentials: InMemoryTagCredentialStore(),
            protection: armingProtection(), uidConfirmation: .required
        )
    }

    // MARK: - Nothing in the field

    func test_cancelBeforeAnyTag_isNotAnError_andWritesNothing() async throws {
        let chip = NTAG215Simulator()
        let factory = ScriptedSessionFactory(chip: chip, [.cancelled])
        let model = plainWrite(factory)

        await model.begin()

        XCTAssertEqual(model.phase, .cancelled, "the sheet closes back to where Write was pressed")
        XCTAssertTrue(try NDEFCodec.isEmptyMessage(chip.readNDEF()))
        let session = try factory.simulated(0)
        XCTAssertTrue(session.didInvalidate)
        XCTAssertNil(session.invalidationError)
    }

    /// Tap 1 of a confirmed write is the first session, so a cancel there has
    /// nothing before it either.
    func test_cancelOnTheIdentifyTapBeforeAnyTag_isNotAnError() async {
        let chip = NTAG215Simulator()
        let factory = ScriptedSessionFactory(chip: chip, [.cancelled])
        let model = armingWrite(factory)

        await model.begin()

        XCTAssertEqual(model.phase, .cancelled)
        XCTAssertEqual(factory.made.count, 1, "and no write tap follows it")
        XCTAssertEqual(try? chip.readProtectionState()?.passwordProtect, false)
    }

    func test_timeoutBeforeAnyTag_isNoTagFound_andTryAgainWrites() async throws {
        let chip = NTAG215Simulator()
        let model = plainWrite(ScriptedSessionFactory(chip: chip, [.timeout, .ready]))

        await model.begin()
        XCTAssertEqual(model.phase, .noTagFound)
        XCTAssertTrue(try NDEFCodec.isEmptyMessage(chip.readNDEF()))

        await model.retry()
        XCTAssertEqual(model.phase, .done, "Try again runs the same write")
        XCTAssertFalse(try NDEFCodec.isEmptyMessage(chip.readNDEF()))
    }

    func test_timeoutOnTheIdentifyTapBeforeAnyTag_isNoTagFound_andTryAgainIdentifies() async {
        let model = armingWrite(ScriptedSessionFactory(chip: NTAG215Simulator(), [.timeout, .ready]))

        await model.begin()
        XCTAssertEqual(model.phase, .noTagFound)

        let before = model.transitionCount
        let run = Task { await model.retry() }
        await untilSettled(model, after: before)
        guard case .awaitingConfirmation = model.phase else {
            model.reset()
            await run.value
            return XCTFail("Try again must identify the tag again, got \(model.phase)")
        }
        model.reset()
        await run.value
    }

    // MARK: - A tag in this session

    func test_cancelWhileADetectedTagIsBeingIdentified_isStillReported() async {
        let model = plainWrite(ScriptedSessionFactory(chip: NTAG215Simulator(), [.cancelledAfterDetection]))

        await model.begin()

        XCTAssertEqual(
            model.phase,
            .error(message: NoTagEndingCopy.cancelled, diagnostics: "simulator behaviour=cancelledAfterDetection")
        )
    }

    func test_timeoutWhileADetectedTagIsBeingIdentified_isStillReported() async {
        let model = armingWrite(ScriptedSessionFactory(chip: NTAG215Simulator(), [.timedOutAfterDetection]))

        await model.begin()

        XCTAssertEqual(
            model.phase,
            .error(message: NoTagEndingCopy.timedOut, diagnostics: "simulator behaviour=timedOutAfterDetection")
        )
    }

    // MARK: - A tag in an earlier session of the same write

    /// Tap 1 read the tag. The write tap that follows is about that tag, so an
    /// empty sheet there is reported as it always was.
    func test_cancelOnTheWriteTapAfterTheIdentifyTap_isStillReported() async {
        let chip = NTAG215Simulator()
        let model = armingWrite(ScriptedSessionFactory(chip: chip, [.ready, .cancelled]))

        await beginConfirmingUID(model)

        XCTAssertEqual(
            model.phase,
            .error(message: NoTagEndingCopy.cancelled, diagnostics: "simulator behaviour=cancelled")
        )
        XCTAssertEqual(try? chip.readProtectionState()?.passwordProtect, false)
    }

    func test_timeoutOnTheWriteTapAfterTheIdentifyTap_isStillReported() async {
        let model = armingWrite(ScriptedSessionFactory(chip: NTAG215Simulator(), [.ready, .timeout]))

        await beginConfirmingUID(model)

        XCTAssertEqual(
            model.phase,
            .error(message: NoTagEndingCopy.timedOut, diagnostics: "simulator behaviour=timeout")
        )
    }

    /// The unlock re-tap follows a tap that found the tag protected.
    func test_cancelOnTheUnlockRetap_isStillReported() async throws {
        let chip = NTAG213Simulator()
        try chip.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let model = plainWrite(ScriptedSessionFactory(chip: chip, [.ready, .cancelled]))
        await model.begin()
        XCTAssertEqual(model.phase, .needsUnlock)

        await model.unlock(with: .type2(password: password, pack: pack))

        XCTAssertEqual(
            model.phase,
            .error(message: NoTagEndingCopy.cancelled, diagnostics: "simulator behaviour=cancelled")
        )
    }

    /// The case the invariant exists for. A write tap armed the tag and lost the
    /// answer, so the tag is now protected and the write reported a failure.
    /// Try again re-identifies, and the user cancels that empty sheet. Closing it
    /// quietly would put them back in the editor with the tag's new password
    /// unreported, so it keeps the report it always had.
    func test_cancelOnARetryAfterAHalfFinishedArm_isStillReported() async throws {
        let chip = NTAG213Simulator()
        let layout = try XCTUnwrap(Type2ConfigLayout.for(.ntag213))
        let faults = FaultInjectingSessionFactory(chip: chip)
        // AUTH0 goes down last and the chip applies it, but the answer is lost.
        faults.arm(TagFault(.write(page: layout.config0Page), .lostACK))
        let factory = ScriptedSessionFactory([
            { faults.makeSession() },
            { faults.makeSession() },
            { SimulatedSession(chip: chip, behaviour: .cancelled) },
        ])
        let model = armingWrite(factory)

        await beginConfirmingUID(model)
        guard case .error = model.phase else {
            return XCTFail("a lost answer to the arming write is reported, got \(model.phase)")
        }
        XCTAssertTrue(faults.report.swallowed.contains { $0.request.first == 0xA2 }, "the chip applied the write")

        await model.retry()

        XCTAssertEqual(
            model.phase,
            .error(message: NoTagEndingCopy.cancelled, diagnostics: "simulator behaviour=cancelled")
        )
        XCTAssertEqual(factory.made.count, 3)
    }

    // MARK: - An ending nothing can vouch for

    /// An error from outside the kit on the write tap may have come from a tag,
    /// so the empty sheet on the retry after it is reported too.
    func test_cancelOnARetryAfterAnErrorFromOutsideTheKitOnTheWriteTap_isStillReported() async {
        let chip = NTAG215Simulator()
        let model = plainWrite(ScriptedSessionFactory([
            { ForeignErrorSession() },
            { SimulatedSession(chip: chip, behaviour: .cancelled) },
        ]))
        await model.begin()
        guard case .error = model.phase else {
            return XCTFail("an unaccounted error is reported, got \(model.phase)")
        }

        await model.retry()

        XCTAssertEqual(
            model.phase,
            .error(message: NoTagEndingCopy.cancelled, diagnostics: "simulator behaviour=cancelled")
        )
    }

    func test_cancelOnARetryAfterAnErrorFromOutsideTheKitOnTheIdentifyTap_isStillReported() async {
        let chip = NTAG215Simulator()
        let model = armingWrite(ScriptedSessionFactory([
            { ForeignErrorSession() },
            { SimulatedSession(chip: chip, behaviour: .cancelled) },
        ]))
        await model.begin()
        guard case .error = model.phase else {
            return XCTFail("an unaccounted error is reported, got \(model.phase)")
        }

        await model.retry()

        XCTAssertEqual(
            model.phase,
            .error(message: NoTagEndingCopy.cancelled, diagnostics: "simulator behaviour=cancelled")
        )
    }
}
