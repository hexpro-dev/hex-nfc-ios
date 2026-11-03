import Foundation

/// Parses the Machine-Readable Zone string stored in DG1 into its fields.
/// Passports are TD3 (2 lines × 44 chars); TD2 (2 × 36) and TD1 (3 × 30) are
/// handled too so the parser is robust to ID-card-style eMRTDs, but TD3 is the
/// path that matters here.
///
/// A length picks a layout but does not prove it. China's travel permits carry
/// a 90-character DG1 that is not TD1, and reading it as TD1 put the holder's
/// encoded name under "Date of birth" (2026-10-27). So an ICAO layout is kept
/// only when its date fields hold dates; otherwise the string is tried as a
/// permit, and failing that it is `.unrecognised`, which shows the raw lines
/// and no fields rather than fields that are wrong.
///
/// Reference: ICAO Doc 9303 Parts 4–6 (MRZ field layouts).
public enum MRZParser {
    /// Which layout the MRZ was read as.
    public enum Layout: String, Sendable, Codable {
        /// ICAO Doc 9303 Part 5: ID-1 card, 3 × 30.
        case td1
        /// ICAO Doc 9303 Part 6: 2 × 36.
        case td2
        /// ICAO Doc 9303 Part 4: passport booklet, 2 × 44.
        case td3
        /// A travel permit from China's exit-entry administration (`CS`, `CT`).
        /// See `parseChineseTravelPermit`.
        case chineseTravelPermit
        /// An ICAO length whose content is not that layout or any other this
        /// parser knows. Only the document code and the raw lines are kept.
        case unrecognised

        /// `true` for the three ICAO layouts, whose fields are all read from DG1.
        public var isICAO: Bool {
            switch self {
            case .td1, .td2, .td3: true
            case .chineseTravelPermit, .unrecognised: false
            }
        }
    }

    /// The raw fields lifted from an MRZ, before they become a `PassportData`.
    public struct Fields: Equatable, Sendable {
        public var documentType: String
        public var issuingState: String
        public var primaryIdentifier: String
        public var secondaryIdentifier: String
        public var documentNumber: String
        public var nationality: String
        public var dateOfBirth: String
        public var sex: String
        public var dateOfExpiry: String
        public var optionalData: String
        public var raw: String
        public var layout: Layout
    }

    /// Parse an MRZ. `mrz` may contain newlines or be a single contiguous run of
    /// characters (as DG1 stores it); both are normalised. Returns `nil` when
    /// the length matches no known document type.
    public static func parse(_ mrz: String) -> Fields? {
        let compact = mrz.filter { !$0.isWhitespace }.uppercased()
        let icao: Fields
        switch compact.count {
        case 88: icao = parseTD3(compact)
        case 72: icao = parseTD2(compact)
        case 90: icao = parseTD1(compact)
        default: return nil
        }
        let permit = compact.count == 90 ? parseChineseTravelPermit(compact, raw: icao.raw) : nil
        // A permit whose dates passed their check digits outranks a TD1
        // reading, which only asks for digits or filler where its dates go: a
        // permit with an empty Chinese-name field would pass that on filler.
        // Only the four known codes outrank it; `C` also opens ICAO cards,
        // such as Norway's `CA` residence card.
        if let permit, !permit.dateOfBirth.isEmpty, chinesePermitCodes.contains(permit.documentType) {
            return permit
        }
        if holdsDates(icao) {
            return icao
        }
        if let permit {
            return permit
        }
        return Fields(
            documentType: humanize(slice(compact, 0, 2)),
            issuingState: "",
            primaryIdentifier: "",
            secondaryIdentifier: "",
            documentNumber: "",
            nationality: "",
            dateOfBirth: "",
            sex: "",
            dateOfExpiry: "",
            optionalData: "",
            raw: icao.raw,
            layout: .unrecognised
        )
    }

    /// Whether an ICAO reading put dates where its dates go. Doc 9303 allows
    /// `<` for an unknown part of a date, but never a letter, so a letter there
    /// means the layout is wrong. Nothing else is tested: a check digit some
    /// issuer computed wrongly should not cost a real passport its fields.
    private static func holdsDates(_ fields: Fields) -> Bool {
        [fields.dateOfBirth, fields.dateOfExpiry].allSatisfy { date in
            date.allSatisfy { ("0" ... "9").contains($0) || $0 == "<" }
        }
    }

    // MARK: - TD3 (passport booklet)

    private static func parseTD3(_ s: String) -> Fields {
        let line1 = slice(s, 0, 44)
        let line2 = slice(s, 44, 44)
        let (primary, secondary) = names(from: slice(line1, 5, 39))
        return Fields(
            documentType: humanize(slice(line1, 0, 2)),
            issuingState: field(slice(line1, 2, 3)),
            primaryIdentifier: primary,
            secondaryIdentifier: secondary,
            documentNumber: field(slice(line2, 0, 9)),
            nationality: field(slice(line2, 10, 3)),
            dateOfBirth: field(slice(line2, 13, 6)),
            sex: field(slice(line2, 20, 1)),
            dateOfExpiry: field(slice(line2, 21, 6)),
            optionalData: field(slice(line2, 28, 14)),
            raw: line1 + "\n" + line2,
            layout: .td3
        )
    }

    // MARK: - TD2

    private static func parseTD2(_ s: String) -> Fields {
        let line1 = slice(s, 0, 36)
        let line2 = slice(s, 36, 36)
        let (primary, secondary) = names(from: slice(line1, 5, 31))
        let (number, optional) = documentNumber(
            slice(line2, 0, 9),
            check: slice(line2, 9, 1),
            optional: slice(line2, 28, 7)
        )
        return Fields(
            documentType: humanize(slice(line1, 0, 2)),
            issuingState: field(slice(line1, 2, 3)),
            primaryIdentifier: primary,
            secondaryIdentifier: secondary,
            documentNumber: number,
            nationality: field(slice(line2, 10, 3)),
            dateOfBirth: field(slice(line2, 13, 6)),
            sex: field(slice(line2, 20, 1)),
            dateOfExpiry: field(slice(line2, 21, 6)),
            optionalData: optional,
            raw: line1 + "\n" + line2,
            layout: .td2
        )
    }

    // MARK: - TD1 (ID-1 card)

    private static func parseTD1(_ s: String) -> Fields {
        let line1 = slice(s, 0, 30)
        let line2 = slice(s, 30, 30)
        let line3 = slice(s, 60, 30)
        let (primary, secondary) = names(from: slice(line3, 0, 30))
        let (number, optional) = documentNumber(
            slice(line1, 5, 9),
            check: slice(line1, 14, 1),
            optional: slice(line1, 15, 15)
        )
        return Fields(
            documentType: humanize(slice(line1, 0, 2)),
            issuingState: field(slice(line1, 2, 3)),
            primaryIdentifier: primary,
            secondaryIdentifier: secondary,
            documentNumber: number,
            nationality: field(slice(line2, 15, 3)),
            dateOfBirth: field(slice(line2, 0, 6)),
            sex: field(slice(line2, 7, 1)),
            dateOfExpiry: field(slice(line2, 8, 6)),
            optionalData: optional,
            raw: line1 + "\n" + line2 + "\n" + line3,
            layout: .td1
        )
    }

    /// The document number and the optional data that follows it, for TD1 and
    /// TD2. A number longer than nine characters (Doc 9303-5 and -6, note j)
    /// fills the number field, puts `<` where its check digit would be, and
    /// opens the optional data with the rest of the number, its check digit and
    /// a `<`. Belgian eID cards are one: 12 digits.
    private static func documentNumber(
        _ numberField: String,
        check: String,
        optional: String
    ) -> (number: String, optional: String) {
        let overflow = optional.prefix { $0 != "<" }
        guard check == "<", overflow.count >= 2 else { return (field(numberField), field(optional)) }
        return (numberField + overflow.dropLast(), field(String(optional.dropFirst(overflow.count + 1))))
    }

    // MARK: - China travel permits

    /// China's exit-entry permits store 90 characters in DG1, as TD1 does, in
    /// layouts of their own. Two families are known.
    ///
    /// **One printed line** (`CS`, the mainland residents' permit for Hong Kong
    /// and Macao; `CD`, for Taiwan). The card prints a single 30-character line
    /// (GA/T 704.16-2015 §3.2.2) and the chip adds two more. Line 1: code,
    /// number (2-10) and check digit, `<`, expiry and check digit, `<`, birth
    /// date and check digit, `<`, then a composite over number, expiry and
    /// birth date with their check digits. Line 2 holds 12 characters (the
    /// Chinese name, encoded) and then the Latin name from column 12. Line 3 is
    /// not known and nothing is read from it. A tester's `CS` on 2026-10-27
    /// passed all four check digits, and an independent reader tested on two
    /// real permits (BG5VYX/edoc-reader) uses the same columns.
    ///
    /// **Three printed lines** (`CR`, the Hong Kong and Macao residents' permit,
    /// GA/T 704.14-2015 §4.2; `CT`, the Taiwan residents' permit, which follows
    /// the same scheme). Line 1: code, number (2-10) and check digit, issue
    /// count (12-13) and check digit, expiry (15-20) and check digit, sex (22),
    /// birth date (23-28) and check digit. Line 2: the Chinese name as GBK bytes
    /// written one letter per nibble (0-15 as A-P, GA/T 704.14 §6), counts of
    /// characters dropped (16-17), birth century (18), then a `CR` holder's
    /// Hong Kong or Macao identity number (19-27) with its own check digit
    /// (28), or a `CT` holder's Taiwan identity number (19-28), and a composite
    /// (29) over line 1 columns 2-21 and 23-29 and line 2 columns 19-28. Line
    /// 3: the Latin name, all 30 columns on a `CR`, the first 26 on a `CT`
    /// before a four-character issuing authority code.
    ///
    /// A field is taken only when its check digits pass, and a layout's
    /// identity numbers and line 3 only for the code that layout belongs to.
    /// What fails stays blank, and the decoder fills a blank number or date
    /// from the access key the chip accepted.
    private static let chinesePermitCodes: Set = ["CS", "CD", "CT", "CR"]

    private static func parseChineseTravelPermit(_ s: String, raw: String) -> Fields? {
        let line1 = slice(s, 0, 30)
        let line2 = slice(s, 30, 30)
        let line3 = slice(s, 60, 30)
        let code = slice(line1, 0, 2)
        let number = slice(line1, 2, 9)
        guard line1.hasPrefix("C"), checks(number, slice(line1, 11, 1)) else { return nil }

        var fields = Fields(
            documentType: humanize(code),
            issuingState: "",
            primaryIdentifier: "",
            secondaryIdentifier: "",
            documentNumber: field(number),
            nationality: "",
            dateOfBirth: "",
            sex: "",
            dateOfExpiry: "",
            optionalData: "",
            raw: raw,
            layout: .chineseTravelPermit
        )

        if slice(line1, 12, 1) == "<", slice(line1, 20, 1) == "<", slice(line1, 28, 1) == "<",
           checks(slice(line1, 13, 6), slice(line1, 19, 1)), checks(slice(line1, 21, 6), slice(line1, 27, 1)),
           checks(slice(line1, 2, 10) + slice(line1, 13, 7) + slice(line1, 21, 7), slice(line1, 29, 1))
        {
            fields.dateOfExpiry = slice(line1, 13, 6)
            fields.dateOfBirth = slice(line1, 21, 6)
            (fields.primaryIdentifier, fields.secondaryIdentifier) = names(from: slice(line2, 12, 18))
        } else if checks(slice(line1, 12, 2), slice(line1, 14, 1)),
                  checks(slice(line1, 15, 6), slice(line1, 21, 1)),
                  checks(slice(line1, 23, 6), slice(line1, 29, 1))
        {
            fields.dateOfExpiry = slice(line1, 15, 6)
            fields.dateOfBirth = slice(line1, 23, 6)
            fields.sex = field(slice(line1, 22, 1))
            let composite = checks(
                slice(line1, 2, 20) + slice(line1, 23, 7) + slice(line2, 19, 10),
                slice(line2, 29, 1)
            )
            switch code {
            case "CR":
                (fields.primaryIdentifier, fields.secondaryIdentifier) = names(from: line3)
                if checks(slice(line2, 19, 9), slice(line2, 28, 1)) {
                    fields.optionalData = field(slice(line2, 19, 9))
                }

            case "CT":
                (fields.primaryIdentifier, fields.secondaryIdentifier) = names(from: slice(line3, 0, 26))
                if composite {
                    fields.optionalData = field(slice(line2, 19, 10))
                }

            default:
                break
            }
        }
        return fields
    }

    /// `true` when `digit` is the ICAO check digit of `input`.
    private static func checks(_ input: String, _ digit: String) -> Bool {
        Int(digit) == PassportMRZ.checkDigit(input)
    }

    // MARK: - Helpers

    /// Split a name field on the `<<` surname/given-names separator and turn
    /// `<`-filler into spaces.
    private static func names(from nameField: String) -> (primary: String, secondary: String) {
        let parts = nameField.components(separatedBy: "<<")
        let primary = humanize(parts.first ?? "")
        let secondary = parts.count > 1 ? humanize(parts[1...].joined(separator: " ")) : ""
        return (primary, secondary)
    }

    /// A whole field with trailing `<` filler stripped (interior `<` kept as-is
    /// for machine fields like the document number).
    private static func field(_ s: String) -> String {
        var trimmed = s
        while trimmed.hasSuffix("<") {
            trimmed.removeLast()
        }
        return trimmed
    }

    /// Turn MRZ filler into human text: `<` → space, collapse runs, trim.
    private static func humanize(_ s: String) -> String {
        let spaced = s.replacingOccurrences(of: "<", with: " ")
        let collapsed = spaced.split(whereSeparator: { $0 == " " }).joined(separator: " ")
        return collapsed.trimmingCharacters(in: .whitespaces)
    }

    /// Safe substring by character offset+length; clamps to the string's bounds.
    private static func slice(_ s: String, _ start: Int, _ length: Int) -> String {
        let chars = Array(s)
        guard start < chars.count else { return "" }
        let end = min(start + length, chars.count)
        return String(chars[start ..< end])
    }
}
