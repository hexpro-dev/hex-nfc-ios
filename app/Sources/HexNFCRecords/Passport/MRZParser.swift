import Foundation

/// Parses the Machine-Readable Zone string stored in DG1 into its fields.
/// Passports are TD3 (2 lines × 44 chars); TD2 (2 × 36) and TD1 (3 × 30) are
/// handled too so the parser is robust to ID-card-style eMRTDs, but TD3 is the
/// path that matters here.
///
/// Reference: ICAO Doc 9303 Parts 4–6 (MRZ field layouts).
public enum MRZParser {
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
    }

    /// Parse an MRZ. `mrz` may contain newlines or be a single contiguous run of
    /// characters (as DG1 stores it); both are normalised. Returns `nil` when
    /// the length matches no known document type.
    public static func parse(_ mrz: String) -> Fields? {
        let compact = mrz.filter { !$0.isWhitespace }.uppercased()
        switch compact.count {
        case 88: return parseTD3(compact)
        case 72: return parseTD2(compact)
        case 90: return parseTD1(compact)
        default: return nil
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
            raw: line1 + "\n" + line2
        )
    }

    // MARK: - TD2

    private static func parseTD2(_ s: String) -> Fields {
        let line1 = slice(s, 0, 36)
        let line2 = slice(s, 36, 36)
        let (primary, secondary) = names(from: slice(line1, 5, 31))
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
            optionalData: field(slice(line2, 28, 7)),
            raw: line1 + "\n" + line2
        )
    }

    // MARK: - TD1 (ID-1 card)

    private static func parseTD1(_ s: String) -> Fields {
        let line1 = slice(s, 0, 30)
        let line2 = slice(s, 30, 30)
        let line3 = slice(s, 60, 30)
        let (primary, secondary) = names(from: slice(line3, 0, 30))
        return Fields(
            documentType: humanize(slice(line1, 0, 2)),
            issuingState: field(slice(line1, 2, 3)),
            primaryIdentifier: primary,
            secondaryIdentifier: secondary,
            documentNumber: field(slice(line1, 5, 9)),
            nationality: field(slice(line2, 15, 3)),
            dateOfBirth: field(slice(line2, 0, 6)),
            sex: field(slice(line2, 7, 1)),
            dateOfExpiry: field(slice(line2, 8, 6)),
            optionalData: field(slice(line1, 15, 15)),
            raw: line1 + "\n" + line2 + "\n" + line3
        )
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
