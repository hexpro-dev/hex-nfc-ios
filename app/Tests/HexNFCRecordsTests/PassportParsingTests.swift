@testable import HexNFCRecords
import XCTest

/// Records-layer eMRTD parsing: BER-TLV, MRZ check digits, MRZ field extraction,
/// and data-group decoding. All pure — no NFC, no crypto. The MRZ fixture is the
/// ICAO Doc 9303 "Anna Eriksson" specimen aligned with the Part 11 BAC worked
/// example (document `L898902C<`, DOB `690806`, expiry `940623`).
final class PassportParsingTests: XCTestCase {
    // Canonical specimen MRZ lines (TD3), 44 chars each.
    private let line1 = "P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<"
    private let line2 = "L898902C<3UTO6908061F9406236ZE184226B<<<<<14"

    // MARK: - BER-TLV

    func test_bertlv_primitive() throws {
        let node = try BERTLV.parseFirst(Data([0x5F, 0x1F, 0x02, 0xAB, 0xCD]))
        XCTAssertEqual(node.tag, 0x5F1F)
        XCTAssertFalse(node.isConstructed)
        XCTAssertEqual(node.value, Data([0xAB, 0xCD]))
        XCTAssertTrue(node.children.isEmpty)
    }

    func test_bertlv_constructed_nesting() throws {
        // 0x61 { 0x5F1F { AB CD } }
        let node = try BERTLV.parseFirst(Data([0x61, 0x05, 0x5F, 0x1F, 0x02, 0xAB, 0xCD]))
        XCTAssertEqual(node.tag, 0x61)
        XCTAssertTrue(node.isConstructed)
        XCTAssertEqual(node.children.count, 1)
        XCTAssertEqual(node.firstDescendant(tag: 0x5F1F)?.value, Data([0xAB, 0xCD]))
    }

    func test_bertlv_longForm_length() throws {
        var bytes = Data([0x5F, 0x1F, 0x81, 0x80]) // long form: 1 length octet, 0x80 = 128
        bytes.append(Data(repeating: 0x42, count: 128))
        let node = try BERTLV.parseFirst(bytes)
        XCTAssertEqual(node.value.count, 128)
    }

    func test_bertlv_multipleTopLevel() throws {
        let nodes = try BERTLV.parse(Data([0x81, 0x01, 0x01, 0x82, 0x01, 0x02]))
        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(nodes[0].tag, 0x81)
        XCTAssertEqual(nodes[1].value, Data([0x02]))
    }

    func test_bertlv_truncatedValue_throws() {
        XCTAssertThrowsError(try BERTLV.parseFirst(Data([0x5F, 0x1F, 0x05, 0xAB])))
    }

    // MARK: - Check digits (ICAO 9303 Part 3)

    func test_checkDigit_knownValues() {
        XCTAssertEqual(PassportMRZ.checkDigit("L898902C<"), 3)
        XCTAssertEqual(PassportMRZ.checkDigit("690806"), 1)
        XCTAssertEqual(PassportMRZ.checkDigit("940623"), 6)
    }

    func test_mrzInformation_matchesDoc9303Example() {
        let mrz = PassportMRZ(documentNumber: "L898902C", dateOfBirth: "690806", dateOfExpiry: "940623")
        // Padded doc field "L898902C<" + check 3, DOB + check 1, expiry + check 6.
        XCTAssertEqual(mrz.mrzInformation, "L898902C<369080619406236")
        XCTAssertTrue(mrz.isWellFormed)
    }

    func test_mrz_isWellFormed_rejectsBadDates() {
        XCTAssertFalse(PassportMRZ(documentNumber: "X", dateOfBirth: "69080", dateOfExpiry: "940623").isWellFormed)
        XCTAssertFalse(PassportMRZ(documentNumber: "", dateOfBirth: "690806", dateOfExpiry: "940623").isWellFormed)
    }

    // MARK: - MRZ field extraction

    func test_mrzParser_td3_fields() throws {
        let fields = try XCTUnwrap(MRZParser.parse(line1 + line2))
        XCTAssertEqual(fields.documentType, "P")
        XCTAssertEqual(fields.issuingState, "UTO")
        XCTAssertEqual(fields.primaryIdentifier, "ERIKSSON")
        XCTAssertEqual(fields.secondaryIdentifier, "ANNA MARIA")
        XCTAssertEqual(fields.documentNumber, "L898902C")
        XCTAssertEqual(fields.nationality, "UTO")
        XCTAssertEqual(fields.dateOfBirth, "690806")
        XCTAssertEqual(fields.sex, "F")
        XCTAssertEqual(fields.dateOfExpiry, "940623")
        XCTAssertEqual(fields.optionalData, "ZE184226B")
    }

    func test_mrzParser_unknownLength_returnsNil() {
        XCTAssertNil(MRZParser.parse("TOO SHORT"))
    }

    // MARK: - DG1 decode

    func test_decodeDG1_buildsPassportData() {
        let mrz = Array((line1 + line2).utf8) // 88 bytes
        var dg1 = Data([0x61, UInt8(mrz.count + 3), 0x5F, 0x1F, UInt8(mrz.count)])
        dg1.append(contentsOf: mrz)

        let data = PassportDataDecoder.decodeDG1(dg1)
        XCTAssertEqual(data?.documentNumber, "L898902C")
        XCTAssertEqual(data?.primaryIdentifier, "ERIKSSON")
        XCTAssertEqual(data?.nationality, "UTO")
        XCTAssertEqual(data?.dateOfExpiry, "940623")
    }

    // MARK: - DG2 image extraction

    func test_findImage_jpeg() {
        let bytes = Data([0x00, 0x11, 0xFF, 0xD8, 0xFF, 0xAA, 0xBB])
        let image = PassportDataDecoder.findImage(in: bytes)
        XCTAssertEqual(image?.format, .jpeg)
        XCTAssertEqual(image?.data, Data([0xFF, 0xD8, 0xFF, 0xAA, 0xBB]))
    }

    func test_findImage_jpeg2000_codestream() {
        let bytes = Data([0x00, 0x00, 0xFF, 0x4F, 0xFF, 0x51, 0x01, 0x02])
        let image = PassportDataDecoder.findImage(in: bytes)
        XCTAssertEqual(image?.format, .jpeg2000)
    }

    func test_findImage_none() {
        XCTAssertNil(PassportDataDecoder.findImage(in: Data([0x01, 0x02, 0x03])))
    }

    // MARK: - DG7 signature extraction

    func test_decodeDG7_extractsSignature() {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0x11, 0x22])
        // DG7 (0x67) { count (02 01 01), 5F43 { jpeg } }
        let sigElement = Data([0x5F, 0x43, UInt8(jpeg.count)]) + jpeg
        let body = Data([0x02, 0x01, 0x01]) + sigElement
        let dg7 = Data([0x67, UInt8(body.count)]) + body

        let image = PassportDataDecoder.decodeDG7(dg7)
        XCTAssertEqual(image?.format, .jpeg)
        XCTAssertEqual(image?.data, jpeg)
    }
}
