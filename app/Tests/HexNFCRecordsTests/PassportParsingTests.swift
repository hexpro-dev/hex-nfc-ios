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

    /// Doc 9303-11 Appendix D.2: a number longer than nine characters goes
    /// into the key whole, with its check digit over all of it.
    func test_mrzInformation_longDocumentNumber_matchesAppendixD2() {
        let mrz = PassportMRZ(documentNumber: "D23145890734", dateOfBirth: "340712", dateOfExpiry: "950712")
        XCTAssertEqual(mrz.mrzInformation, "D23145890734934071279507122")
    }

    /// Spaces, hyphens and filler typed from a card are not part of the number.
    func test_documentNumberField_dropsSeparators() {
        XCTAssertEqual(
            PassportMRZ(documentNumber: "d2314-5890 734", dateOfBirth: "", dateOfExpiry: "").documentNumberField,
            "D23145890734"
        )
        XCTAssertEqual(
            PassportMRZ(documentNumber: "L898902C<", dateOfBirth: "", dateOfExpiry: "").documentNumberField,
            "L898902C<"
        )
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

    // MARK: - TD1, and the 90-character strings that are not TD1

    /// Doc 9303 Part 5's TD1 specimen.
    private let td1Line1 = "I<UTOD231458907<<<<<<<<<<<<<<<"
    private let td1Line2 = "7408122F1204159UTO<<<<<<<<<<<6"
    private let td1Line3 = "ERIKSSON<<ANNA<MARIA<<<<<<<<<<"

    /// A permit for Hong Kong and Macao (`CS`) in the shape a real permit
    /// showed on 2026-10-27, with invented values: number `C12345678`, expiry
    /// 2033-01-01, birth 1990-01-01, every check digit valid. Line 2 is 12
    /// letters for the encoded Chinese name, then the Latin name.
    private let csLine1 = "CSC123456788<3301018<9001011<4"
    private let csLine2 = "LMLNLOLPMAMBZHENGJIAN<<YANGBEN"
    /// Stand-ins for lines whose content is not read: letters where TD1
    /// expects dates.
    private let permitLine2 = "LMLNLOLPMAMB<<<<<G<<<<<<<<<<<<"
    private let permitLine3 = "ABCD000000<<EFGH0000<<<<<<<<<<"

    /// A `CR` (GA/T 704.14-2015 §4.2) with invented values: number
    /// `H12345678`, expiry 2033-01-01, male, born 1990-01-01, Hong Kong
    /// identity number `A1234567`, every check digit valid.
    private let crLines = [
        "CRH1234567830003301018M9001011",
        "LMLNLOLPMAMB<<<<AABA1234567<62",
        "CHAN<<TAI<MAN<<<<<<<<<<<<<<<<<",
    ]

    /// A `CT` on the same scheme: number `12345678`, expiry 2030-01-01,
    /// female, born 1985-06-15, Taiwan identity number `A123456788`, issuing
    /// authority `3501`.
    private let ctLines = [
        "CT12345678<80133001019F8506151",
        "LMLNLOLPMAMB<<<<AABA1234567884",
        "LIN<<MEI<LING<<<<<<<<<<<<<3501",
    ]

    /// A `CT` permit's first line: number and check digit, then a tail whose
    /// layout is not known, so no dates are read from it.
    private let ctLine1 = "CT12345678<801<<<<<<<<<<<<<<<<"

    private func dg1File(_ mrz: String) -> Data {
        let bytes = Array(mrz.utf8)
        var data = Data([0x61, UInt8(bytes.count + 3), 0x5F, 0x1F, UInt8(bytes.count)])
        data.append(contentsOf: bytes)
        return data
    }

    func test_mrzParser_td1_fields() throws {
        let fields = try XCTUnwrap(MRZParser.parse(td1Line1 + td1Line2 + td1Line3))
        XCTAssertEqual(fields.layout, .td1)
        XCTAssertEqual(fields.documentType, "I")
        XCTAssertEqual(fields.issuingState, "UTO")
        XCTAssertEqual(fields.documentNumber, "D23145890")
        XCTAssertEqual(fields.dateOfBirth, "740812")
        XCTAssertEqual(fields.sex, "F")
        XCTAssertEqual(fields.dateOfExpiry, "120415")
        XCTAssertEqual(fields.primaryIdentifier, "ERIKSSON")
        XCTAssertEqual(fields.secondaryIdentifier, "ANNA MARIA")
    }

    /// `C` is an ICAO document code too. A TD1 card that uses it, with dates
    /// where its dates go, must stay TD1 and not be taken for a permit.
    func test_mrzParser_td1_withCDocumentCode_staysTD1() throws {
        let line1 = "C" + td1Line1.dropFirst()
        let fields = try XCTUnwrap(MRZParser.parse(line1 + td1Line2 + td1Line3))
        XCTAssertEqual(fields.layout, .td1)
        XCTAssertEqual(fields.primaryIdentifier, "ERIKSSON")
    }

    /// A known permit code with verified dates wins even where a TD1 reading
    /// would find dates; any other `C` code does not.
    func test_mrzParser_permitPrecedence_onlyForKnownCodes() throws {
        let asPermit = try XCTUnwrap(MRZParser.parse(csLine1 + td1Line2 + td1Line3))
        XCTAssertEqual(asPermit.layout, .chineseTravelPermit)

        let norwegianStyle = "CA" + csLine1.dropFirst(2)
        let asTD1 = try XCTUnwrap(MRZParser.parse(norwegianStyle + td1Line2 + td1Line3))
        XCTAssertEqual(asTD1.layout, .td1)
        XCTAssertEqual(asTD1.primaryIdentifier, "ERIKSSON")
    }

    func test_mrzParser_csPermit_readsLineOneAndLatinName() throws {
        let fields = try XCTUnwrap(MRZParser.parse(csLine1 + csLine2 + permitLine3))
        XCTAssertEqual(fields.layout, .chineseTravelPermit)
        XCTAssertEqual(fields.documentType, "CS")
        XCTAssertEqual(fields.documentNumber, "C12345678")
        XCTAssertEqual(fields.dateOfExpiry, "330101")
        XCTAssertEqual(fields.dateOfBirth, "900101")
        XCTAssertEqual(fields.primaryIdentifier, "ZHENGJIAN")
        XCTAssertEqual(fields.secondaryIdentifier, "YANGBEN")
        // Line 3 is not known, and the permit has no ICAO nationality or sex.
        XCTAssertEqual(fields.nationality, "")
        XCTAssertEqual(fields.issuingState, "")
        XCTAssertEqual(fields.sex, "")
        XCTAssertEqual(fields.optionalData, "")
        XCTAssertEqual(fields.raw, [csLine1, csLine2, permitLine3].joined(separator: "\n"))
    }

    func test_mrzParser_crPermit_fields() throws {
        let fields = try XCTUnwrap(MRZParser.parse(crLines.joined()))
        XCTAssertEqual(fields.layout, .chineseTravelPermit)
        XCTAssertEqual(fields.documentType, "CR")
        XCTAssertEqual(fields.documentNumber, "H12345678")
        XCTAssertEqual(fields.dateOfExpiry, "330101")
        XCTAssertEqual(fields.dateOfBirth, "900101")
        XCTAssertEqual(fields.sex, "M")
        XCTAssertEqual(fields.primaryIdentifier, "CHAN")
        XCTAssertEqual(fields.secondaryIdentifier, "TAI MAN")
        XCTAssertEqual(fields.optionalData, "A1234567")
    }

    func test_mrzParser_ctPermit_fields() throws {
        let fields = try XCTUnwrap(MRZParser.parse(ctLines.joined()))
        XCTAssertEqual(fields.layout, .chineseTravelPermit)
        XCTAssertEqual(fields.documentType, "CT")
        XCTAssertEqual(fields.documentNumber, "12345678")
        XCTAssertEqual(fields.dateOfExpiry, "300101")
        XCTAssertEqual(fields.dateOfBirth, "850615")
        XCTAssertEqual(fields.sex, "F")
        // The issuing authority code after column 26 is not part of the name.
        XCTAssertEqual(fields.primaryIdentifier, "LIN")
        XCTAssertEqual(fields.secondaryIdentifier, "MEI LING")
        XCTAssertEqual(fields.optionalData, "A123456788")
    }

    /// The Taiwan identity number has no check digit of its own; without the
    /// composite it is not shown.
    func test_mrzParser_ctPermit_badCompositeDropsIdentityNumber() throws {
        let line2 = ctLines[1].dropLast() + "0"
        let fields = try XCTUnwrap(MRZParser.parse(ctLines[0] + line2 + ctLines[2]))
        XCTAssertEqual(fields.dateOfBirth, "850615")
        XCTAssertEqual(fields.optionalData, "")
    }

    /// With no Chinese name the encoded-name field is all filler, which is
    /// where TD1 looks for its dates. The permit's check digits decide.
    func test_mrzParser_crPermitWithoutChineseName_isNotTD1() throws {
        let lines = [
            "CRM8765432140003301018F9001011",
            "<<<<<<<<<<<<<<<<AAB1234567<<44",
            "CHAN<<TAI<MAN<<<<<<<<<<<<<<<<<",
        ]
        let fields = try XCTUnwrap(MRZParser.parse(lines.joined()))
        XCTAssertEqual(fields.layout, .chineseTravelPermit)
        XCTAssertEqual(fields.documentNumber, "M87654321")
        XCTAssertEqual(fields.optionalData, "1234567")
    }

    /// One wrong check digit and the dates are not trusted, though the number,
    /// which has its own, still is.
    func test_mrzParser_csPermit_badCompositeLeavesDatesBlank() throws {
        let line1 = csLine1.dropLast() + "5"
        let fields = try XCTUnwrap(MRZParser.parse(line1 + permitLine2 + permitLine3))
        XCTAssertEqual(fields.layout, .chineseTravelPermit)
        XCTAssertEqual(fields.documentNumber, "C12345678")
        XCTAssertEqual(fields.dateOfBirth, "")
        XCTAssertEqual(fields.dateOfExpiry, "")
        XCTAssertEqual(fields.primaryIdentifier, "")
    }

    /// A first line whose tail fits neither family keeps only its number.
    func test_mrzParser_ctPermit_numberOnly() throws {
        let fields = try XCTUnwrap(MRZParser.parse(ctLine1 + permitLine2 + permitLine3))
        XCTAssertEqual(fields.layout, .chineseTravelPermit)
        XCTAssertEqual(fields.documentType, "CT")
        XCTAssertEqual(fields.documentNumber, "12345678")
        XCTAssertEqual(fields.dateOfBirth, "")
        XCTAssertEqual(fields.dateOfExpiry, "")
    }

    /// Letters in the date fields and no permit line: no fields at all, rather
    /// than the wrong ones.
    func test_mrzParser_notTD1_isUnrecognised() throws {
        let fields = try XCTUnwrap(MRZParser.parse(td1Line1 + permitLine2 + td1Line3))
        XCTAssertEqual(fields.layout, .unrecognised)
        XCTAssertEqual(fields.documentType, "I")
        XCTAssertEqual(fields.documentNumber, "")
        XCTAssertEqual(fields.primaryIdentifier, "")
        XCTAssertEqual(fields.dateOfBirth, "")
        XCTAssertEqual(fields.raw, [td1Line1, permitLine2, td1Line3].joined(separator: "\n"))
    }

    // MARK: - Document numbers longer than nine characters

    /// Doc 9303-11 Appendix D.2's TD1 specimen.
    func test_mrzParser_td1_longDocumentNumber() throws {
        let fields = try XCTUnwrap(MRZParser.parse(
            "I<UTOD23145890<7349<<<<<<<<<<<" + "3407127M9507122UTO<<<<<<<<<<<2" + "STEVENSON<<PETER<JOHN<<<<<<<<<"
        ))
        XCTAssertEqual(fields.layout, .td1)
        XCTAssertEqual(fields.documentNumber, "D23145890734")
        XCTAssertEqual(fields.optionalData, "")
        XCTAssertEqual(fields.primaryIdentifier, "STEVENSON")
    }

    /// The same, TD2.
    func test_mrzParser_td2_longDocumentNumber() throws {
        let fields = try XCTUnwrap(MRZParser.parse(
            "I<UTOSTEVENSON<<PETER<JOHN<<<<<<<<<<" + "D23145890<UTO3407127M95071227349<<<8"
        ))
        XCTAssertEqual(fields.layout, .td2)
        XCTAssertEqual(fields.documentNumber, "D23145890734")
        XCTAssertEqual(fields.optionalData, "")
    }

    /// A Belgian eID specimen: 12-digit card number, then real optional data.
    func test_mrzParser_belgianSpecimen_longDocumentNumber() throws {
        let fields = try XCTUnwrap(MRZParser.parse(
            "IDBEL000590696<1015<<<<<<<<<<<" + "9401013F2710017BEL000101123453" + "SPECIMEN<<SPECIMEN<<<<<<<<<<<<"
        ))
        XCTAssertEqual(fields.documentNumber, "000590696101")
        XCTAssertEqual(PassportMRZ.checkDigit("000590696101"), 5)
    }

    func test_mrzParser_permitWithBadNumberCheck_isUnrecognised() throws {
        let line1 = "CSC123456789" + csLine1.dropFirst(12)
        let fields = try XCTUnwrap(MRZParser.parse(line1 + permitLine2 + permitLine3))
        XCTAssertEqual(fields.layout, .unrecognised)
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
        XCTAssertEqual(data?.mrzLayout, .td3)
    }

    /// A permit whose MRZ has no dates the parser knows takes them from the
    /// access key, which the chip accepted.
    func test_decodeDG1_permit_fillsBlankDatesFromAccessKey() {
        let key = PassportMRZ(documentNumber: "12345678", dateOfBirth: "900101", dateOfExpiry: "330101")
        let data = PassportDataDecoder.decodeDG1(dg1File(ctLine1 + permitLine2 + permitLine3), accessKey: key)
        XCTAssertEqual(data?.mrzLayout, .chineseTravelPermit)
        XCTAssertEqual(data?.documentNumber, "12345678")
        XCTAssertEqual(data?.dateOfBirth, "900101")
        XCTAssertEqual(data?.dateOfExpiry, "330101")
        XCTAssertEqual(data?.primaryIdentifier, "")
    }

    /// Dates DG1 does carry are kept over the key's.
    func test_decodeDG1_permit_prefersItsOwnDates() {
        let key = PassportMRZ(documentNumber: "C12345678", dateOfBirth: "010101", dateOfExpiry: "010101")
        let data = PassportDataDecoder.decodeDG1(dg1File(csLine1 + csLine2 + permitLine3), accessKey: key)
        XCTAssertEqual(data?.dateOfBirth, "900101")
        XCTAssertEqual(data?.dateOfExpiry, "330101")
    }

    func test_decodeDG1_unrecognised_takesKeyFields() {
        let key = PassportMRZ(documentNumber: "d23145890", dateOfBirth: "740812", dateOfExpiry: "120415")
        let data = PassportDataDecoder.decodeDG1(dg1File(td1Line1 + permitLine2 + td1Line3), accessKey: key)
        XCTAssertEqual(data?.mrzLayout, .unrecognised)
        XCTAssertEqual(data?.documentNumber, "D23145890")
        XCTAssertEqual(data?.dateOfBirth, "740812")
        XCTAssertEqual(data?.dateOfExpiry, "120415")
    }

    /// An ICAO layout is read from DG1 alone; the key never overrides it.
    func test_decodeDG1_icao_ignoresAccessKey() {
        let key = PassportMRZ(documentNumber: "X", dateOfBirth: "010101", dateOfExpiry: "010101")
        let data = PassportDataDecoder.decodeDG1(dg1File(td1Line1 + td1Line2 + td1Line3), accessKey: key)
        XCTAssertEqual(data?.mrzLayout, .td1)
        XCTAssertEqual(data?.documentNumber, "D23145890")
        XCTAssertEqual(data?.dateOfBirth, "740812")
    }

    // MARK: - DG11

    /// Other names are `5F0F` inside an `A0` template (Doc 9303-10 Table 71);
    /// `5F15` is the personal summary and must not be shown as a name.
    func test_decode_dg11_otherNamesFrom5F0F() throws {
        func tlv(_ tag: [UInt8], _ value: Data) -> Data {
            Data(tag) + Data([UInt8(value.count)]) + value
        }
        let others = tlv([0x02], Data([0x01])) + tlv([0x5F, 0x0F], Data("SMITH<<JOHN".utf8))
        let body = tlv([0x5F, 0x0E], Data("SMITH<<JOHN<PAUL".utf8))
            + tlv([0xA0], others)
            + tlv([0x5F, 0x15], Data("SUMMARY".utf8))
        let dg11 = tlv([0x6B], body)
        let mrz = Array((line1 + line2).utf8)
        let dg1 = Data([0x61, UInt8(mrz.count + 3), 0x5F, 0x1F, UInt8(mrz.count)]) + Data(mrz)

        let data = try XCTUnwrap(PassportDataDecoder.decode(dataGroups: [1: dg1, 11: dg11]))
        XCTAssertEqual(data.biographical?.fullName, "SMITH, JOHN PAUL")
        XCTAssertEqual(data.biographical?.otherNames, ["SMITH, JOHN"])
    }

    /// DG11 and DG12 dates arrive as ASCII or as packed BCD.
    func test_decode_dg11dg12_datesInASCIIAndBCD() throws {
        func tlv(_ tag: [UInt8], _ value: Data) -> Data {
            Data(tag) + Data([UInt8(value.count)]) + value
        }
        let mrz = Array((line1 + line2).utf8)
        let dg1 = Data([0x61, UInt8(mrz.count + 3), 0x5F, 0x1F, UInt8(mrz.count)]) + Data(mrz)
        let dg11 = tlv([0x6B], tlv([0x5F, 0x2B], Data([0x19, 0x69, 0x08, 0x06])))
        let dg12 = tlv([0x6C], tlv([0x5F, 0x26], Data("20190415".utf8)))

        let data = try XCTUnwrap(PassportDataDecoder.decode(dataGroups: [1: dg1, 11: dg11, 12: dg12]))
        XCTAssertEqual(data.biographical?.fullDateOfBirth, "19690806")
        XCTAssertEqual(data.biographical?.dateOfIssue, "20190415")

        let yearOnly = tlv([0x6B], tlv([0x5F, 0x2B], Data("1969".utf8)))
        let partial = try XCTUnwrap(PassportDataDecoder.decode(dataGroups: [1: dg1, 11: yearOnly]))
        XCTAssertEqual(partial.biographical?.fullDateOfBirth, "1969")
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
