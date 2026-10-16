@testable import HexNFCApp
@testable import HexNFCKit
@testable import HexNFCRecords
@testable import HexNFCTagSim
import XCTest

/// Scan with nothing in the field.
///
/// With no tag to hand, Scan and then Cancel on the system sheet used to end
/// on a red "Scan failed / Scan cancelled." pane with diagnostics and the error
/// haptic, and a timeout did the same. That is what App Review saw. Now a
/// cancel on a scan that never had a tag closes the sheet, and a timeout says
/// no tag was found. Anything after a tag keeps the report it always had.
@MainActor
final class ScanNoTagEndingTests: XCTestCase {
    private let password = Data([0xCA, 0xFE, 0xBA, 0xBE])
    private let pack = Data([0x12, 0x34])

    private func readProtectedNTAG215() throws -> NTAG215Simulator {
        let message = try NDEFCodec.encode([NDEFRecord.uri(URIRecord(uri: "https://hex.pro"))])
        let chip = NTAG215Simulator(ndefMessage: message)
        try chip.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: true, authLimit: 0
        )
        return chip
    }

    // MARK: - Nothing in the field

    func test_cancelBeforeAnyTag_isNotAnError() async throws {
        let factory = ScriptedSessionFactory(chip: NTAG215Simulator(), [.cancelled])
        let model = ScanFlowModel(factory: factory)

        await model.begin()

        XCTAssertEqual(model.phase, .cancelled, "the sheet closes; nothing failed")
        let session = try factory.simulated(0)
        XCTAssertTrue(session.didInvalidate, "the ended session is still invalidated, so its teardown is awaited")
        XCTAssertNil(session.invalidationError, "and without an error message, because there was no error")
    }

    func test_timeoutBeforeAnyTag_isNoTagFound_andTryAgainScans() async {
        let factory = ScriptedSessionFactory(chip: NTAG215Simulator(), [.timeout, .ready])
        let model = ScanFlowModel(factory: factory)

        await model.begin()
        XCTAssertEqual(model.phase, .noTagFound)

        // The sheet's Try again.
        model.reset()
        await model.begin()
        XCTAssertEqual(model.phase, .ready, "a no-tag ending leaves nothing stuck behind it")
    }

    /// The reviewer's path: the sheet times out, Try again, then Cancel. The
    /// first ending had no tag either, so the second is still quiet.
    func test_aCancelAfterAnEmptyTimeout_isStillQuiet() async {
        let factory = ScriptedSessionFactory(chip: NTAG215Simulator(), [.timeout, .cancelled])
        let model = ScanFlowModel(factory: factory)

        await model.begin()
        model.reset()
        await model.begin()

        XCTAssertEqual(model.phase, .cancelled)
    }

    // MARK: - A tag in this session

    /// The cancel landed while a detected tag was still being identified. The
    /// tag answered frames, so the session cannot vouch for an empty field.
    func test_cancelWhileADetectedTagIsBeingIdentified_isStillReported() async {
        let model = ScanFlowModel(factory: ScriptedSessionFactory(chip: NTAG215Simulator(), [.cancelledAfterDetection]))

        await model.begin()

        XCTAssertEqual(
            model.phase,
            .error(message: NoTagEndingCopy.cancelled, diagnostics: "simulator behaviour=cancelledAfterDetection")
        )
    }

    func test_timeoutWhileADetectedTagIsBeingIdentified_isStillReported() async {
        let model = ScanFlowModel(factory: ScriptedSessionFactory(chip: NTAG215Simulator(), [.timedOutAfterDetection]))

        await model.begin()

        XCTAssertEqual(
            model.phase,
            .error(message: NoTagEndingCopy.timedOut, diagnostics: "simulator behaviour=timedOutAfterDetection")
        )
    }

    // MARK: - A tag in an earlier session of the same scan

    /// The unlock re-tap follows a session that read the tag and found it
    /// protected. A cancel there is reported exactly as it was.
    func test_cancelOnTheUnlockRetap_isStillReported() async throws {
        let model = try ScanFlowModel(factory: ScriptedSessionFactory(
            chip: readProtectedNTAG215(),
            [.ready, .cancelled]
        ))
        await model.begin()
        XCTAssertEqual(model.phase, .locked)

        await model.unlock(with: .type2(password: password, pack: pack))

        XCTAssertEqual(
            model.phase,
            .error(message: NoTagEndingCopy.cancelled, diagnostics: "simulator behaviour=cancelled")
        )
    }

    func test_timeoutOnTheUnlockRetap_isStillReported() async throws {
        let model = try ScanFlowModel(factory: ScriptedSessionFactory(chip: readProtectedNTAG215(), [.ready, .timeout]))
        await model.begin()
        XCTAssertEqual(model.phase, .locked)

        await model.unlock(with: .type2(password: password, pack: pack))

        XCTAssertEqual(
            model.phase,
            .error(message: NoTagEndingCopy.timedOut, diagnostics: "simulator behaviour=timeout")
        )
    }

    /// `reset()` does not clear it either. The locked pane's Try again is a
    /// reset and a fresh begin on the same model.
    func test_cancelOnATryAgainAfterATagWasRead_isStillReported() async throws {
        let model = try ScanFlowModel(factory: ScriptedSessionFactory(
            chip: readProtectedNTAG215(),
            [.ready, .cancelled]
        ))
        await model.begin()
        XCTAssertEqual(model.phase, .locked)

        model.reset()
        await model.begin()

        XCTAssertEqual(
            model.phase,
            .error(message: NoTagEndingCopy.cancelled, diagnostics: "simulator behaviour=cancelled")
        )
    }

    /// An ending that is neither a cancel nor a timeout may have involved a tag,
    /// so it counts as contact: the empty sheet after it is reported as well.
    func test_cancelAfterALostTag_isStillReported() async {
        let model = ScanFlowModel(factory: ScriptedSessionFactory(chip: NTAG215Simulator(), [.tagLost, .cancelled]))
        await model.begin()
        guard case .error = model.phase else {
            return XCTFail("a lost tag is an error, got \(model.phase)")
        }

        model.reset()
        await model.begin()

        XCTAssertEqual(
            model.phase,
            .error(message: NoTagEndingCopy.cancelled, diagnostics: "simulator behaviour=cancelled")
        )
    }

    /// The same for an error from outside the kit, which nothing can vouch for.
    func test_cancelAfterAnErrorFromOutsideTheKit_isStillReported() async {
        let model = ScanFlowModel(factory: ScriptedSessionFactory([
            { ForeignErrorSession() },
            { SimulatedSession(chip: NTAG215Simulator(), behaviour: .cancelled) },
        ]))
        await model.begin()
        guard case .error = model.phase else {
            return XCTFail("an unaccounted error is reported, got \(model.phase)")
        }

        model.reset()
        await model.begin()

        XCTAssertEqual(
            model.phase,
            .error(message: NoTagEndingCopy.cancelled, diagnostics: "simulator behaviour=cancelled")
        )
    }
}
