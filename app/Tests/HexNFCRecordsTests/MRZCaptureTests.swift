@testable import HexNFCRecords
import XCTest

/// Camera capture of the access key: `MRZLineReader` (one frame's text to
/// aligned readings) and `MRZScanConsensus` (frames to a lock). Fixtures are
/// the ICAO Doc 9303 specimens (Parts 4, 5 and 6), whose check digits were
/// recomputed independently before they were written down here.
final class MRZCaptureTests: XCTestCase {
    private let td3Line1 = "P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<"
    private let td3Line2 = "L898902C36UTO7408122F1204159ZE184226B<<<<<10"
    private let td2Line1 = "I<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<"
    private let td2Line2 = "D231458907UTO7408122F1204159<<<<<<<6"
    private let td1Lines = [
        "I<UTOD231458907<<<<<<<<<<<<<<<",
        "7408122F1204159UTO<<<<<<<<<<<6",
        "ERIKSSON<<ANNA<MARIA<<<<<<<<<<",
    ]

    private var specimenKey: PassportMRZ {
        PassportMRZ(documentNumber: "L898902C3", dateOfBirth: "740812", dateOfExpiry: "120415")
    }

    // MARK: - Reader

    func test_td3Specimen_readsKeyAndComposite() throws {
        let reading = try XCTUnwrap(primary(read([td3Line1, td3Line2])))
        XCTAssertEqual(reading.layout, .td3)
        XCTAssertEqual(reading.key, specimenKey)
        XCTAssertEqual(reading.compositeValid, true)
    }

    func test_td3_part11Specimen_stripsNumberFiller() throws {
        let reading = try XCTUnwrap(primary(read(["L898902C<3UTO6908061F9406236ZE184226B<<<<<14"])))
        XCTAssertEqual(reading.key?.documentNumber, "L898902C")
        // Padding the number back gives the field the BAC key is derived from.
        XCTAssertEqual(reading.key?.documentNumberField, "L898902C<")
    }

    func test_td2Specimen() throws {
        let reading = try XCTUnwrap(primary(read([td2Line1, td2Line2])))
        XCTAssertEqual(reading.layout, .td2)
        XCTAssertEqual(reading.key?.documentNumber, "D23145890")
        XCTAssertEqual(reading.compositeValid, true)
    }

    func test_td1Specimen_takesNumberFromLineOne() throws {
        let readings = read(td1Lines).filter { $0.layout == .td1 && $0.key != nil }
        let reading = try XCTUnwrap(readings.first)
        XCTAssertEqual(reading.key, PassportMRZ(documentNumber: "D23145890", dateOfBirth: "740812", dateOfExpiry: "120415"))
        XCTAssertEqual(reading.compositeValid, true)
    }

    func test_visualZoneTextAndOrderDoNotMatter() throws {
        let observations = [
            observation(td3Line2, line: 6),
            observation("PASSPORT  PASSEPORT", line: 0),
            observation("Surname / Nom", line: 1),
            observation("ERIKSSON", line: 2),
            observation("12 AUG/AOUT 74", line: 3),
            observation(td3Line1, line: 5),
        ]
        let reading = try XCTUnwrap(primary(MRZLineReader.readings(from: observations)))
        XCTAssertEqual(reading.key, specimenKey)
    }

    func test_lineSplitAtFillerRun_isMergedBeforeReading() throws {
        let cut = td3Line2.index(td3Line2.startIndex, offsetBy: 38)
        let left = MRZTextObservation(candidates: [String(td3Line2[..<cut])], minX: 0.02, minY: 0.10, maxX: 0.80, maxY: 0.20)
        let right = MRZTextObservation(candidates: [String(td3Line2[cut...])], minX: 0.82, minY: 0.11, maxX: 0.98, maxY: 0.21)
        let reading = try XCTUnwrap(primary(MRZLineReader.readings(from: [right, left])))
        XCTAssertEqual(reading.key, specimenKey)
        XCTAssertEqual(reading.compositeValid, true)
    }

    func test_guillemetsSpacesAndLowerCase_areNormalised() throws {
        let noisy = "l898902c3 6uto 7408122f1204159ze184226b««<10"
        let reading = try XCTUnwrap(primary(read([noisy])))
        XCTAssertEqual(reading.key, specimenKey)
        XCTAssertEqual(reading.compositeValid, true)
    }

    func test_strayLeadingGlyph_doesNotShiftFields() throws {
        let reading = try XCTUnwrap(primary(read(["1" + td3Line2])))
        XCTAssertEqual(reading.key, specimenKey)
    }

    func test_fillerMiscountInOptionalData_keepsComposite() throws {
        for line in [
            td3Line2.replacingOccurrences(of: "B<<<<<10", with: "B<<<10"),
            td3Line2.replacingOccurrences(of: "B<<<<<10", with: "B<<<<<<<10"),
        ] {
            let reading = try XCTUnwrap(primary(read([line])), line)
            XCTAssertEqual(reading.key, specimenKey, line)
            XCTAssertEqual(reading.compositeValid, true, line)
        }
    }

    func test_lookAlikeInDigitPosition_isCoerced() throws {
        // O for 0 in the date of birth and in the expiry: positions that can
        // only hold a digit, so there is one right answer.
        let noisy = "L898902C36UTO74O8122F12O4159ZE184226B<<<<<10"
        let reading = try XCTUnwrap(primary(read([noisy])))
        XCTAssertEqual(reading.key, specimenKey)
    }

    func test_lookAlikeInDocumentNumber_isNotRepaired() throws {
        // O for 0 inside the number: alphanumeric, so the frame is left to fail.
        let reading = try XCTUnwrap(primary(read(["L8989O2C36UTO7408122F1204159ZE184226B<<<<<10"])))
        XCTAssertNil(reading.key)
    }

    func test_numberLongerThanNine_isRefused() throws {
        // `<` at the number's check digit: the number continues in the optional
        // data. The camera's nine-character slots cannot hold it, so it refuses
        // rather than lock a cut number; typing takes it whole.
        let overflow = line2(number: "D23145890", check: "<", birth: "740812", sex: "F", expiry: "120415")
        XCTAssertNil(primary(read([overflow]))?.key)
    }

    func test_unknownDayOfBirth_isAccepted() throws {
        let line = line2(number: "AB1234567", birth: "7408<<", sex: "M", expiry: "301231")
        XCTAssertEqual(primary(read([line]))?.key?.dateOfBirth, "7408<<")
    }

    func test_unknownMonthNeedsUnknownDay() {
        let line = line2(number: "AB1234567", birth: "74<<12", sex: "M", expiry: "301231")
        XCTAssertNil(primary(read([line]))?.key)
    }

    func test_leapDay() {
        XCTAssertTrue(MRZKeySlots.isDate("000229", allowUnknown: false))
        XCTAssertTrue(MRZKeySlots.isDate("960229", allowUnknown: false))
        XCTAssertFalse(MRZKeySlots.isDate("010229", allowUnknown: false))
        XCTAssertFalse(MRZKeySlots.isDate("011301", allowUnknown: false))
        XCTAssertFalse(MRZKeySlots.isDate("010431", allowUnknown: false))
        XCTAssertFalse(MRZKeySlots.isDate("12<<<<", allowUnknown: false))
    }

    func test_sexX_isAccepted() {
        let line = line2(number: "UE3906571", birth: "011203", sex: "X", expiry: "350509")
        XCTAssertEqual(primary(read([line]))?.key?.documentNumber, "UE3906571")
    }

    func test_unknownCharacter_rejectsTheLine() {
        XCTAssertNil(MRZLineReader.normalise("L898902C3€6UTO"))
        XCTAssertTrue(read(["L898902C36UTO7408122F12041€9ZE184226B<<<<<10"]).isEmpty)
    }

    func test_edgePunctuation_isDropped() {
        XCTAssertEqual(MRZLineReader.normalise(".L898<<|"), "L898<<")
    }

    func test_secondCandidate_givesAWeakReading() throws {
        let bad = "L8989O2C36UTO7408122F1204159ZE184226B<<<<<10"
        let observations = [MRZTextObservation(candidates: [bad, td3Line2], minX: 0, minY: 0, maxX: 1, maxY: 0.1)]
        let readings = MRZLineReader.readings(from: observations)
        XCTAssertEqual(readings.first?.isPrimary, true)
        XCTAssertNil(readings.first?.key)
        XCTAssertEqual(readings.first(where: { !$0.isPrimary })?.key, specimenKey)
    }

    // MARK: - Consensus

    func test_twoAgreeingFramesWithComposite_lock() {
        var consensus = MRZScanConsensus()
        XCTAssertNil(consensus.add(read([td3Line2]), at: 0))
        let lock = consensus.add(read([td3Line2]), at: 0.12)
        XCTAssertEqual(lock?.key, specimenKey)
        XCTAssertEqual(lock?.layout, .td3)
    }

    func test_withoutComposite_threeFramesAreNeeded() {
        // Composite digit misread as a letter no coercion covers.
        let line = String(td3Line2.dropLast()) + "X"
        var consensus = MRZScanConsensus()
        XCTAssertNil(consensus.add(read([line]), at: 0))
        XCTAssertNil(consensus.add(read([line]), at: 0.1))
        XCTAssertEqual(consensus.add(read([line]), at: 0.2)?.key, specimenKey)
    }

    func test_framesOutsideTheWindow_doNotCount() {
        var consensus = MRZScanConsensus(window: 1.5)
        XCTAssertNil(consensus.add(read([td3Line2]), at: 0))
        XCTAssertNil(consensus.add(read([td3Line2]), at: 2.0))
    }

    func test_validRival_holdsTheLockUntilOutnumbered() throws {
        let rival = line2(number: "L898902C3", birth: "740813", sex: "F", expiry: "120415")
        var consensus = MRZScanConsensus()
        XCTAssertNil(consensus.add(read([td3Line2]), at: 0.0))
        XCTAssertNil(consensus.add(read([rival]), at: 0.1))
        XCTAssertNil(consensus.add(read([td3Line2]), at: 0.2))
        let lock = try XCTUnwrap(consensus.add(read([td3Line2]), at: 0.3))
        XCTAssertEqual(lock.key, specimenKey)
        XCTAssertEqual(lock.alternates.first?.dateOfBirth, "740813")
    }

    func test_differentErrorsEveryFrame_voteToTheRightKey() {
        // No frame reads the number correctly; each gets a different
        // character wrong, so none passes its check digit alone.
        let frames = [
            "L8989O2C36UTO7408122F1204159ZE184226B<<<<<10",
            "LB98902C36UTO7408122F1204159ZE184226B<<<<<10",
            "L898902G36UTO7408122F1204159ZE184226B<<<<<10",
            "L89B902C36UTO7408122F1204159ZE184226B<<<<<10",
            "L898902C3OUTO7408122F1204159ZE184226B<<<<<10",
        ]
        var consensus = MRZScanConsensus()
        var lock: MRZScanConsensus.Lock?
        for (index, frame) in frames.enumerated() where lock == nil {
            lock = consensus.add(read([frame]), at: Double(index) * 0.1)
        }
        XCTAssertEqual(lock?.key, specimenKey)
    }

    func test_fillerReadAsK_carriesTheFillerAlternate() throws {
        let truth = line2(number: "AB123456", birth: "850101", sex: "M", expiry: "300101")
        let misread = truth.replacingOccurrences(of: "AB123456<", with: "AB123456K")
        var consensus = MRZScanConsensus()
        var lock: MRZScanConsensus.Lock?
        for index in 0 ..< 3 where lock == nil {
            lock = consensus.add(read([misread]), at: Double(index) * 0.1)
        }
        let unwrapped = try XCTUnwrap(lock)
        XCTAssertEqual(unwrapped.key.documentNumber, "AB123456K")
        XCTAssertEqual(unwrapped.alternates.first?.documentNumber, "AB123456")
    }

    func test_congruentMisreadWithoutEvidence_isSuspectedFromTheNumbersShape() throws {
        // 8 read as S passes every check digit, and no frame points at the 8.
        // A letter after the digits have begun is still suspicious enough to
        // offer the swap.
        let truth = line2(number: "UA4817265", birth: "910412", sex: "F", expiry: "331103")
        let misread = truth.replacingOccurrences(of: "UA4817265", with: "UA4S17265")
        var consensus = MRZScanConsensus()
        XCTAssertNil(consensus.add(read([misread]), at: 0))
        let lock = try XCTUnwrap(consensus.add(read([misread]), at: 0.1))
        XCTAssertEqual(lock.key.documentNumber, "UA4S17265")
        XCTAssertEqual(lock.alternates.first?.documentNumber, "UA4817265")
    }

    func test_congruentMisreadWithAFrameOfTruth_carriesItAsAlternate() throws {
        let truth = line2(number: "UA4817265", birth: "910412", sex: "F", expiry: "331103")
        let misread = truth.replacingOccurrences(of: "UA4817265", with: "UA4S17265")
        var consensus = MRZScanConsensus()
        XCTAssertNil(consensus.add(read([misread]), at: 0))
        XCTAssertNil(consensus.add(read([truth]), at: 0.1))
        XCTAssertNil(consensus.add(read([misread]), at: 0.2))
        let lock = try XCTUnwrap(consensus.add(read([misread]), at: 0.3))
        XCTAssertEqual(lock.key.documentNumber, "UA4S17265")
        XCTAssertEqual(lock.alternates.first?.documentNumber, "UA4817265")
    }

    func test_congruentMisreadWithTruthAsSecondCandidate_carriesItAsAlternate() throws {
        let truth = line2(number: "UA4817265", birth: "910412", sex: "F", expiry: "331103")
        let misread = truth.replacingOccurrences(of: "UA4817265", with: "UA4S17265")
        let frame = [MRZTextObservation(candidates: [misread, truth], minX: 0, minY: 0, maxX: 1, maxY: 0.1)]
        var consensus = MRZScanConsensus()
        XCTAssertNil(consensus.add(MRZLineReader.readings(from: frame), at: 0))
        let lock = try XCTUnwrap(consensus.add(MRZLineReader.readings(from: frame), at: 0.1))
        XCTAssertEqual(lock.key.documentNumber, "UA4S17265")
        XCTAssertEqual(lock.alternates.first?.documentNumber, "UA4817265")
    }

    func test_resetAndTracking() {
        var consensus = MRZScanConsensus()
        XCTAssertFalse(consensus.isTracking(at: 0))
        _ = consensus.add(read([td3Line2]), at: 0)
        XCTAssertTrue(consensus.isTracking(at: 0.3))
        XCTAssertFalse(consensus.isTracking(at: 1.0))
        consensus.reset()
        XCTAssertFalse(consensus.isTracking(at: 0))
        XCTAssertNil(consensus.add(read([td3Line2]), at: 0.1))
    }

    func test_cardAndBookletReadingsNeverMix() {
        var consensus = MRZScanConsensus()
        XCTAssertNil(consensus.add(read(td1Lines), at: 0))
        // A TD3 frame of a different document does not add to the card's count.
        XCTAssertNil(consensus.add(read([td3Line2]), at: 0.1))
        XCTAssertEqual(consensus.add(read(td1Lines), at: 0.2)?.key.documentNumber, "D23145890")
    }

    // MARK: - Helpers

    private func read(_ lines: [String]) -> [MRZReading] {
        MRZLineReader.readings(from: lines.enumerated().map { observation($1, line: $0) })
    }

    private func primary(_ readings: [MRZReading]) -> MRZReading? {
        readings.first(where: \.isPrimary)
    }

    private func observation(_ text: String, line: Int) -> MRZTextObservation {
        let top = 0.95 - Double(line) * 0.1
        return MRZTextObservation(candidates: [text], minX: 0.02, minY: top - 0.08, maxX: 0.98, maxY: top)
    }

    /// A TD3 line 2 with correct check digits, empty optional data.
    private func line2(number: String, check: String? = nil, birth: String, sex: String, expiry: String) -> String {
        let field = number.padding(toLength: 9, withPad: "<", startingAt: 0)
        let numberCheck = check ?? String(PassportMRZ.checkDigit(field))
        let head = field + numberCheck + "UTO" + birth + String(PassportMRZ.checkDigit(birth)) + sex
            + expiry + String(PassportMRZ.checkDigit(expiry))
        let optional = String(repeating: "<", count: 14)
        let composite = PassportMRZ.checkDigit(
            String(head.prefix(10)) + String(Array(head)[13 ..< 20]) + String(Array(head)[21 ..< 28]) + optional + "<"
        )
        return head + optional + "<" + String(composite)
    }
}
