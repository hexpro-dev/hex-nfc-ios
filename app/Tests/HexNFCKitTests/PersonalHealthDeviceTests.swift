@testable import HexNFCKit
@testable import HexNFCRecords
@testable import HexNFCTagSim
import XCTest

/// Recognising a personal health device (NFC Forum PHDC) from the first
/// message it leaves in its NDEF file, and naming its maker from the IEEE OUI
/// that leads its system ID.
///
/// No pen has been on the bench yet. The ground truth is a published NovoPen 6
/// trace (lcacheux/nov-open-reader, `nvplib/core/nvp_datatest.txt`, Apache-2.0),
/// whose opening message is pinned below with the pen's own serial replaced.
final class PersonalHealthDeviceTests: XCTestCase {
    /// The trace's 61-byte association request, byte for byte, except the 40
    /// manufacturer-assigned bits of the system ID, which identify one real pen
    /// and are replaced with `00 00 00 00 01`. The OUI (`00 14 65`) is left
    /// alone because it is what the app reads the maker from.
    static let traceAssociationRequest = Data([
        0xD1, 0x03, 0x37, 0x50, 0x48, 0x44, 0x00, 0xE2, 0x00, 0x00, 0x32, 0x80, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x2A, 0x50, 0x79, 0x00, 0x26, 0x80, 0x00, 0x00, 0x00, 0x80, 0x00, 0x80, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00, 0x08, 0x00, 0x14, 0x65, 0x00, 0x00,
        0x00, 0x00, 0x01, 0x40, 0x0A, 0x00, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
    ])

    /// The simulator builds its message field by field. Pinning the result to
    /// the trace is what keeps that construction from drifting into a layout no
    /// real pen sends.
    func test_simulatorAssociationRequest_isTheTraceLayout() {
        XCTAssertEqual(Self.traceAssociationRequest.count, 61, "the trace's NLEN is 00 3D")
        XCTAssertEqual(
            PHDCDeviceSimulator.associationRequest(
                systemID: PHDCDeviceSimulator.syntheticNovoSystemID,
                configurationID: PHDCDeviceSimulator.novoConfigurationID
            ),
            Self.traceAssociationRequest
        )
    }

    func test_association_readsSystemIDConfigurationAndMaker() throws {
        let association = try XCTUnwrap(PHDAssociation(ndefMessage: Self.traceAssociationRequest))

        XCTAssertEqual(association.systemID, Data([0x00, 0x14, 0x65, 0x00, 0x00, 0x00, 0x00, 0x01]))
        XCTAssertEqual(association.configurationID, 0x400A)
        XCTAssertEqual(association.organizationID, Data([0x00, 0x14, 0x65]))
        XCTAssertEqual(association.maker, .novoNordisk)
    }

    /// An OUI the app does not know names nobody. The device is still a health
    /// device; it just gets no maker, and so no referral.
    func test_unknownOUI_namesNoMaker() throws {
        let message = PHDCDeviceSimulator.associationRequest(
            systemID: Data([0xAC, 0xDE, 0x48, 0x00, 0x00, 0x00, 0x00, 0x07]),
            configurationID: 0x0190
        )
        let association = try XCTUnwrap(PHDAssociation(ndefMessage: message))

        XCTAssertNil(association.maker)
        XCTAssertEqual(association.configurationID, 0x0190)
    }

    /// A system ID that is not eight bytes is not an EUI-64, so its first three
    /// bytes are not an OUI and must not be read as one.
    func test_nonEUI64SystemID_hasNoOrganizationID() throws {
        let message = PHDCDeviceSimulator.associationRequest(
            systemID: Data([0x00, 0x14, 0x65, 0x01]),
            configurationID: 0x400A
        )
        let association = try XCTUnwrap(PHDAssociation(ndefMessage: message))

        XCTAssertNil(association.organizationID)
        XCTAssertNil(association.maker)
    }

    func test_truncatedAssociation_doesNotParse() {
        let message = Self.traceAssociationRequest
        // Re-frame a cut payload as a short record so the NDEF layer is valid and
        // only the AARQ inside it is short.
        let payload = Data(message[6 ..< 40])
        let cut = Data([0xD1, 0x03, UInt8(payload.count)]) + Data("PHD".utf8) + payload

        XCTAssertNil(PHDAssociation(ndefMessage: cut))
    }

    // MARK: - Recognising a PHD record from the head alone

    func test_startsWithPHDRecord_fromTheHeadAlone() {
        XCTAssertTrue(PHDAssociation.startsWithPHDRecord(Data(Self.traceAssociationRequest.prefix(16))))
        XCTAssertTrue(PHDAssociation.startsWithPHDRecord(Data(Self.traceAssociationRequest.prefix(6))))
        XCTAssertFalse(PHDAssociation.startsWithPHDRecord(Data(Self.traceAssociationRequest.prefix(5))))
    }

    func test_startsWithPHDRecord_rejectsOrdinaryRecords() throws {
        let uri = try NDEFCodec.encode([.uri(URIRecord(uri: "https://hex.pro"))])
        XCTAssertFalse(PHDAssociation.startsWithPHDRecord(uri))
        XCTAssertFalse(PHDAssociation.startsWithPHDRecord(Data([0xD0, 0x00, 0x00])), "the empty record")
        XCTAssertFalse(PHDAssociation.startsWithPHDRecord(Data()))

        // The right three letters under the wrong TNF are a media type, not PHDC.
        var mediaTyped = [UInt8](Self.traceAssociationRequest)
        mediaTyped[0] = 0xD2
        XCTAssertFalse(PHDAssociation.startsWithPHDRecord(Data(mediaTyped)))
    }

    /// A long (non-SR) record header puts the type four bytes later. A PHDC
    /// message that ever outgrows 255 bytes must still be recognised.
    func test_startsWithPHDRecord_handlesALongRecordHeader() {
        let long = Data([0xC1, 0x03, 0x00, 0x00, 0x01, 0x00]) + Data("PHD".utf8)
        XCTAssertTrue(PHDAssociation.startsWithPHDRecord(long))
    }

    // MARK: - Makers

    func test_novoNordiskIsNamedFromItsRegisteredOUI() {
        XCTAssertEqual(HealthDeviceMaker(oui: Data([0x00, 0x14, 0x65])), .novoNordisk)
        XCTAssertEqual(HealthDeviceMaker.novoNordisk.name, "Novo Nordisk")
        XCTAssertNil(HealthDeviceMaker(oui: Data([0x00, 0x14, 0x66])))
    }
}
