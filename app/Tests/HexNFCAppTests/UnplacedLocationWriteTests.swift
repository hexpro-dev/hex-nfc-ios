@testable import HexNFCApp
@testable import HexNFCKit
@testable import HexNFCRecords
import HexNFCStorage
@testable import HexNFCTagSim
import XCTest

/// A location record with no coordinates and no map URL never reaches a tag.
///
/// The URI builder fills whatever is missing with 0, so such a record used to
/// go onto the tag as `geo:0,0`, a real point that a reading phone opens as if
/// it were meant. Two kinds of record get there: a Location added and left
/// empty (Cancel on the form keeps it in the list), and one saved with the
/// "Current location" source, which the editor no longer offers and which never
/// carried coordinates. The editor marks both, but a Library preset writes
/// without passing through the editor at all, so the refusal lives on the write
/// flow, before any session opens.
@MainActor
final class UnplacedLocationWriteTests: XCTestCase {
    private let placed = NDEFRecord.map(MapRecord(source: .coordinate, latitude: -33.8688, longitude: 151.2093))
    private let legacy = NDEFRecord.map(MapRecord(source: .currentLocation))
    private let text = NDEFRecord.text(TextRecord(text: "hello"))

    private func model(
        _ records: [NDEFRecord],
        factory: TagSessionFactory,
        uidConfirmation: WriteFlowModel.UIDConfirmation = .notRequired,
        protection: PendingProtection? = nil
    ) -> WriteFlowModel {
        WriteFlowModel(
            factory: factory,
            dataArea: .replace(records),
            credentials: InMemoryTagCredentialStore(),
            protection: protection,
            uidConfirmation: uidConfirmation
        )
    }

    // MARK: - Refused

    /// The Library route, which is the one that bypasses the editor.
    func test_aPresetHoldingALegacyCurrentLocationRecord_isRefusedWithNoSessionOpened() async throws {
        let chip = NTAG215Simulator()
        let factory = RecordingFactory(chip: chip)
        let model = model([text, legacy], factory: factory)

        await model.begin()

        guard case .error(let message, let diagnostics) = model.phase else {
            return XCTFail("expected a refusal, got \(model.phase)")
        }
        XCTAssertEqual(
            message,
            "A location record is missing its coordinates or map URL. Nothing was written to the tag."
        )
        XCTAssertTrue(diagnostics.contains("record 2 of 2"), diagnostics)
        XCTAssertTrue(diagnostics.contains("currentLocation"), diagnostics)
        XCTAssertEqual(factory.sessionsStarted, 0, "refused before the NFC sheet, so no tap is spent")
        XCTAssertTrue(try NDEFCodec.isEmptyMessage(chip.readNDEF()), "and the tag is untouched")
    }

    /// A Location added from the Add record sheet and never filled in.
    func test_anEmptyNewLocation_isRefusedToo() async {
        let factory = RecordingFactory(chip: NTAG215Simulator())
        let model = model([.map(MapRecord())], factory: factory)

        await model.begin()

        guard case .error = model.phase else { return XCTFail("expected a refusal, got \(model.phase)") }
        XCTAssertEqual(factory.sessionsStarted, 0)
    }

    /// A write that also arms protection is refused before its identify tap,
    /// not between the taps: the user must not type a UID for a write that was
    /// never going to happen.
    func test_aConfirmedWrite_isRefusedBeforeTheIdentifyTap() async {
        let factory = RecordingFactory(chip: NTAG215Simulator())
        let protection = PendingProtection(
            settings: TagProtection(passwordProtect: true, protectFromPage: 4, readProtect: false, authLimit: 0),
            credential: .type2(password: Data([0x11, 0x22, 0x33, 0x44]), pack: Data([0xAA, 0xBB]))
        )
        let model = model([legacy], factory: factory, uidConfirmation: .required, protection: protection)
        XCTAssertTrue(model.requiresUIDConfirmation, "the refusal has to come first to mean anything here")

        await model.begin()

        guard case .error = model.phase else { return XCTFail("expected a refusal, got \(model.phase)") }
        XCTAssertEqual(factory.sessionsStarted, 0, "no identify tap")
    }

    /// "Try again" on the error card gets the same answer, still without a tap.
    func test_retry_refusesAgainWithoutASession() async {
        let factory = RecordingFactory(chip: NTAG215Simulator())
        let model = model([legacy], factory: factory)

        await model.begin()
        await model.retry()

        guard case .error = model.phase else { return XCTFail("expected a refusal, got \(model.phase)") }
        XCTAssertEqual(factory.sessionsStarted, 0)
    }

    // MARK: - Not refused

    func test_aLocationWithCoordinates_writes() async throws {
        let chip = NTAG215Simulator()
        let factory = RecordingFactory(chip: chip)
        let model = model([placed], factory: factory)

        await model.begin()

        XCTAssertEqual(model.phase, .done, "got \(model.phase)")
        XCTAssertEqual(factory.sessionsStarted, 1)
        guard case .map(let written)? = try NDEFCodec.decode(chip.readNDEF()).first else {
            return XCTFail("the tag should hold a map record")
        }
        XCTAssertEqual(written.latitude, -33.8688)
        XCTAssertEqual(written.longitude, 151.2093)
    }

    /// A legacy record that carries a pasted link is a location: the link is
    /// what the tag has always been given, and the source label never reached
    /// the tag.
    func test_aLegacyCurrentLocationRecordWithALink_writes() async {
        let factory = RecordingFactory(chip: NTAG215Simulator())
        let linked = NDEFRecord.map(MapRecord(source: .currentLocation, rawURL: "https://maps.apple.com/?ll=1,2"))
        let model = model([linked], factory: factory)

        await model.begin()

        XCTAssertEqual(model.phase, .done, "got \(model.phase)")
    }

    func test_theRuleLooksOnlyAtRecordsThatAreWritten() {
        XCTAssertNil(WriteFlowModel.locationsWithNowhereToPoint(in: .untouched))
        XCTAssertNil(WriteFlowModel.locationsWithNowhereToPoint(in: .replace([])))
        XCTAssertNil(WriteFlowModel.locationsWithNowhereToPoint(in: .replace([text, placed])))
        XCTAssertEqual(
            WriteFlowModel.locationsWithNowhereToPoint(in: .replace([.map(MapRecord()), text, legacy])),
            "refused before a session opened: location without coordinates or map URL at "
                + "record 1 of 3 (source coordinate), record 3 of 3 (source currentLocation)"
        )
    }
}
