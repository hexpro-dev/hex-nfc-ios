@testable import HexNFCRecords
import XCTest

/// `MapRecord.hasLocation` against what the codec actually writes.
///
/// The predicate exists because `MapURLBuilder` has no way to say "nothing":
/// a record with neither a map URL nor both coordinates encodes as a real
/// point, most often `geo:0,0`. These tests pin both halves, so a change to
/// the builder's fallback shows up here as well as in the write flow that
/// refuses these records.
final class MapRecordLocationTests: XCTestCase {
    /// The URI the codec puts on the wire for `record`, checked against the
    /// bytes a plain URI record spelling the same thing would get.
    private func written(_ record: MapRecord) throws -> String {
        let uri = MapURLBuilder.url(for: record)
        XCTAssertEqual(
            try NDEFCodec.payload(from: .map(record)),
            try NDEFCodec.payload(from: .uri(URIRecord(uri: uri))),
            "a map record goes onto the tag as exactly this URI"
        )
        return uri
    }

    // MARK: - Records with somewhere to point

    func test_bothCoordinates_areALocation() throws {
        let record = MapRecord(source: .coordinate, latitude: -33.8688, longitude: 151.2093)
        XCTAssertTrue(record.hasLocation)
        XCTAssertEqual(try written(record), "geo:-33.868800,151.209300")
    }

    func test_aMapURL_isALocation_whateverTheSource() throws {
        for source in [MapRecord.Source.appleMaps, .googleMaps, .coordinate, .currentLocation] {
            let record = MapRecord(source: source, rawURL: "https://maps.apple.com/?ll=-33.86,151.20")
            XCTAssertTrue(record.hasLocation, "\(source)")
            XCTAssertEqual(try written(record), "https://maps.apple.com/?ll=-33.86,151.20", "\(source)")
        }
    }

    // MARK: - Records the codec would put on the equator

    /// The finder's case: a record saved with "Current location" selected and
    /// nothing pasted. The app never read the phone's position, so there were
    /// no coordinates to write.
    func test_aLegacyCurrentLocationRecord_hasNoLocation_andWouldEncodeAsNullIsland() throws {
        let record = MapRecord(source: .currentLocation)
        XCTAssertFalse(record.hasLocation)
        XCTAssertEqual(try written(record), "geo:0.000000,0.000000")
    }

    /// A Location added from the Add record sheet and never filled in.
    func test_anEmptyNewLocation_hasNoLocation() throws {
        let record = MapRecord()
        XCTAssertEqual(record.source, .coordinate)
        XCTAssertFalse(record.hasLocation)
        XCTAssertEqual(try written(record), "geo:0.000000,0.000000")
    }

    /// One coordinate is not half a location. The builder fills the other with
    /// 0, which is a point on the equator or the prime meridian.
    func test_oneCoordinate_isNotALocation() throws {
        let latitudeOnly = MapRecord(source: .coordinate, latitude: 51.5)
        XCTAssertFalse(latitudeOnly.hasLocation)
        XCTAssertEqual(try written(latitudeOnly), "geo:51.500000,0.000000")

        let longitudeOnly = MapRecord(source: .coordinate, longitude: -0.12)
        XCTAssertFalse(longitudeOnly.hasLocation)
        XCTAssertEqual(try written(longitudeOnly), "geo:0.000000,-0.120000")
    }

    /// An empty URL is skipped by the builder, so it answers on the coordinates.
    /// A blank one is written as it stands, and says nothing.
    func test_anEmptyOrBlankURL_isNotALocation() {
        XCTAssertFalse(MapRecord(source: .appleMaps, rawURL: "").hasLocation)
        XCTAssertFalse(MapRecord(source: .appleMaps, rawURL: "  \n").hasLocation)
        XCTAssertTrue(
            MapRecord(source: .appleMaps, latitude: 1, longitude: 2, rawURL: "").hasLocation,
            "an empty URL falls through to the coordinates, as the builder does"
        )
    }

    // MARK: - Decoding

    /// Stored records still decode, so a preset saved with the withdrawn source
    /// loads rather than failing the whole preset.
    func test_theWithdrawnSourceStillDecodes() throws {
        let json = Data(#"{"type":"map","id":"9E2B1C64-6A2F-4D0E-9A52-0B7F1C3D8E44","source":"currentLocation"}"#.utf8)
        let decoded = try JSONDecoder().decode(NDEFRecord.self, from: json)
        guard case .map(let record) = decoded else { return XCTFail("expected a map record, got \(decoded)") }
        XCTAssertEqual(record.source, .currentLocation)
        XCTAssertFalse(record.hasLocation)
    }

    /// Whatever a tag holds decodes to a record with a location, so a scanned
    /// map record is never refused on the way back to a tag.
    func test_everythingReadFromATag_hasALocation() {
        for uri in ["geo:-33.8688,151.2093", "geo:10,20?q=cafe", "geo:somewhere", "geo:"] {
            let payload = NDEFPayload(
                tnf: NDEFPayload.tnfWellKnown,
                type: NDEFPayload.typeURI,
                payload: Data([0x00]) + Data(uri.utf8)
            )
            guard case .map(let record) = NDEFCodec.record(from: payload) else {
                XCTFail("\(uri) should read back as a map record")
                continue
            }
            XCTAssertTrue(record.hasLocation, uri)
        }
    }
}
