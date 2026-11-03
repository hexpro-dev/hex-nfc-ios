import Foundation

/// The machine-readable-zone layouts the camera recognises (ICAO Doc 9303
/// Parts 4-6). Only the access key is lifted from any of them, and the key
/// fields mean the same thing in all three.
public enum MRZLayout: String, Sendable, Equatable {
    /// Passport booklet: 2 lines of 44.
    case td3
    /// 2 lines of 36.
    case td2
    /// ID-1 card: 3 lines of 30.
    case td1
}

/// One run of text the camera's recogniser found: its best few readings and
/// where it sat in the frame. Deliberately free of Vision, so everything that
/// decides what the camera saw can be tested on macOS.
public struct MRZTextObservation: Sendable, Equatable {
    /// Best first, as `VNRecognizedTextObservation.topCandidates(3)` orders them.
    public var candidates: [String]
    /// Normalised bounding box, origin bottom left, the way Vision reports it.
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(candidates: [String], minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.candidates = candidates
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }
}

/// One frame's reading of the access-key fields, aligned to fixed positions so
/// readings from different frames can be voted on character by character
/// (`MRZScanConsensus`).
public struct MRZReading: Sendable, Equatable {
    public var layout: MRZLayout
    /// The 28 key positions in TD3 line-2 order, whatever the layout: number
    /// (9), its check digit, nationality (3), date of birth (6), its check
    /// digit, sex, date of expiry (6), its check digit. Digit-only and
    /// letter-only positions are already coerced (see `MRZLineReader`).
    public var slots: [Character]
    /// Whether the composite check digit agreed. `nil` when the rest of the
    /// zone was not read well enough to compute it.
    public var compositeValid: Bool?
    /// `false` for a reading built from the recogniser's second or third guess.
    public var isPrimary: Bool

    public init(layout: MRZLayout, slots: [Character], compositeValid: Bool?, isPrimary: Bool) {
        self.layout = layout
        self.slots = slots
        self.compositeValid = compositeValid
        self.isPrimary = isPrimary
    }

    /// The access key, when every check this reading can make passes.
    public var key: PassportMRZ? {
        MRZKeySlots.key(from: slots)
    }
}

/// Turns one camera frame's recognised text into `MRZReading`s.
///
/// The recogniser is good but not exact, so this is built around what it gets
/// wrong on a machine-readable zone:
///
/// - It splits a line at long `<` runs, so observations sharing a baseline are
///   merged before anything else.
/// - It adds or drops filler, and picks up a stray glyph at a page edge, so a
///   line is anchored on its date block (date of birth, check, sex, expiry,
///   check) rather than on its first character. Positions before the anchor
///   are counted back from it, so a stray leading glyph cannot shift a field.
/// - It confuses look-alikes (`O`/`0`, `B`/`8`, `S`/`5`). Where a position can
///   only hold a digit, or only a letter, there is one right answer and it is
///   applied; the check digit still has to agree afterwards.
///
/// The document number is the exception. It is genuinely alphanumeric, so a
/// single frame never "repairs" it: with a dozen look-alike variants, each of
/// which passes a mod-10 check one time in ten, a variant that happens to pass
/// is wrong as often as not. Misreads there are left for the consensus to vote
/// out across frames.
public enum MRZLineReader {
    /// Every reading the frame supports, primary readings first.
    public static func readings(from observations: [MRZTextObservation]) -> [MRZReading] {
        let lines = mergeIntoLines(observations)
        var out: [MRZReading] = []
        for (index, line) in lines.enumerated() {
            let previous = index > 0 ? lines[index - 1].first : nil
            for (rank, candidate) in line.enumerated() {
                let isPrimary = rank == 0
                out += twoLineReadings(line: candidate, isPrimary: isPrimary)
                if let previous {
                    out += td1Readings(line1: previous, line2: candidate, isPrimary: isPrimary)
                }
            }
        }
        var seen: [[Character]] = []
        return out.filter { reading in
            guard !seen.contains(reading.slots) else { return false }
            seen.append(reading.slots)
            return true
        }
    }

    // MARK: - Lines

    /// Group observations into visual lines, top to bottom, each line holding
    /// its normalised candidate strings (the joined primary readings first,
    /// then up to two variants that swap in one observation's next guess).
    static func mergeIntoLines(_ observations: [MRZTextObservation]) -> [[String]] {
        var groups: [[MRZTextObservation]] = []
        for observation in observations.sorted(by: { $0.maxY > $1.maxY }) {
            if let index = groups.firstIndex(where: { sharesBaseline($0[0], observation) }) {
                groups[index].append(observation)
            } else {
                groups.append([observation])
            }
        }
        return groups.compactMap { group in
            let parts = group.sorted { $0.minX < $1.minX }
            let primary = parts.map { $0.candidates.first ?? "" }
            var strings = [primary.joined()]
            for (index, part) in parts.enumerated() {
                for alternate in part.candidates.dropFirst() {
                    var variant = primary
                    variant[index] = alternate
                    strings.append(variant.joined())
                }
            }
            var normalised: [String] = []
            for string in strings {
                guard let clean = normalise(string), !normalised.contains(clean) else { continue }
                normalised.append(clean)
                if normalised.count == 3 { break }
            }
            return normalised.isEmpty ? nil : normalised
        }
    }

    private static func sharesBaseline(_ a: MRZTextObservation, _ b: MRZTextObservation) -> Bool {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        let smaller = min(a.maxY - a.minY, b.maxY - b.minY)
        return smaller > 0 && overlap / smaller >= 0.5
    }

    /// Upper-case, drop spaces, fold the recogniser's usual stand-ins for `<`,
    /// and refuse anything else. Refusing matters: `PassportMRZ.checkDigit`
    /// scores an unknown character as 0, exactly like `<`, so a stray glyph
    /// left in place would pass for filler.
    static func normalise(_ raw: String) -> String? {
        let edgeNoise: Set<Character> = [".", ",", "'", "`", "|", ":", ";", "-", "_"]
        var text = Substring(raw.uppercased())
        while let first = text.first, edgeNoise.contains(first) {
            text = text.dropFirst()
        }
        while let last = text.last, edgeNoise.contains(last) {
            text = text.dropLast()
        }
        var out = ""
        for character in text {
            switch character {
            case " ", "\t":
                continue
            case "«", "≪":
                out += "<<"
            case "<", "‹", "(", "[", "{", "〈", "＜":
                out.append("<")
            case "A" ... "Z", "0" ... "9":
                out.append(character)
            default:
                return nil
            }
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - TD3 / TD2

    /// Readings from a line that could be TD3 or TD2 line 2: the date block
    /// sits 13 characters in, after the number, its check digit and the
    /// nationality. The line carries the whole key, so the noisier line 1 is
    /// never waited on.
    private static func twoLineReadings(line: String, isPrimary: Bool) -> [MRZReading] {
        let chars = Array(line)
        guard chars.count >= 28 else { return [] }
        var out: [MRZReading] = []
        // A stray leading glyph at most two deep; any more and this is not a
        // zone line.
        for anchor in 13 ... min(15, chars.count - 15) where isDateBlock(chars, at: anchor) {
            let start = anchor - 13
            let slots = coerce(Array(chars[start ..< anchor + 15]))
            let tail = Array(chars[(anchor + 15)...])
            let layout: MRZLayout
            let composite: Bool?
            switch tail.count {
            case 13 ... 19:
                layout = .td3
                composite = td3Composite(slots: slots, tail: tail)
            case 5 ... 11:
                layout = .td2
                composite = td2Composite(slots: slots, tail: tail)
            default:
                continue
            }
            out.append(MRZReading(layout: layout, slots: slots, compositeValid: composite, isPrimary: isPrimary))
        }
        return out
    }

    /// TD3 line 2 after the key: optional data (14), its check digit, the
    /// composite. Filler miscounts only ever touch the optional data's
    /// trailing run, and trailing `<` adds nothing to a check digit wherever it
    /// sits, so refitting that run to length is safe.
    private static func td3Composite(slots: [Character], tail: [Character]) -> Bool? {
        guard tail.count >= 3, let composite = digitValue(tail[tail.count - 1]) else { return nil }
        let optionalCheck = coerceDigit(tail[tail.count - 2])
        guard let optional = fitTrailingFiller(Array(tail[0 ..< tail.count - 2]), length: 14) else { return nil }
        let input = String(slots[0 ..< 10]) + String(slots[13 ..< 20]) + String(slots[21 ..< 28])
            + optional + String(optionalCheck)
        return PassportMRZ.checkDigit(input) == composite
    }

    /// TD2 line 2 after the key: optional data (7), then the composite.
    private static func td2Composite(slots: [Character], tail: [Character]) -> Bool? {
        guard tail.count >= 2, let composite = digitValue(tail[tail.count - 1]) else { return nil }
        guard let optional = fitTrailingFiller(Array(tail[0 ..< tail.count - 1]), length: 7) else { return nil }
        let input = String(slots[0 ..< 10]) + String(slots[13 ..< 20]) + String(slots[21 ..< 28]) + optional
        return PassportMRZ.checkDigit(input) == composite
    }

    // MARK: - TD1

    /// Readings from a TD1 card, whose number sits on line 1 (from position 5)
    /// and whose dates open line 2. Only the primary reading of line 1 is used.
    private static func td1Readings(line1: String, line2: String, isPrimary: Bool) -> [MRZReading] {
        let top = Array(line1)
        let bottom = Array(line2)
        guard (28 ... 32).contains(top.count), bottom.count >= 18 else { return [] }
        var out: [MRZReading] = []
        for anchor in 0 ... min(2, bottom.count - 18) where isDateBlock(bottom, at: anchor) {
            for offset in 0 ... max(0, top.count - 30) where top.count >= offset + 15 {
                // Number, check digit, nationality, then the date block.
                var raw = Array(top[(offset + 5) ..< (offset + 15)])
                raw += bottom[(anchor + 15) ..< (anchor + 18)]
                raw += bottom[anchor ..< (anchor + 15)]
                let slots = coerce(raw)
                let composite = td1Composite(
                    slots: slots,
                    optional1: Array(top[(offset + 15)...]),
                    tail: Array(bottom[(anchor + 18)...])
                )
                out.append(MRZReading(layout: .td1, slots: slots, compositeValid: composite, isPrimary: isPrimary))
            }
        }
        return out
    }

    /// TD1 composite over line 1 from the number on, and line 2's dates and
    /// optional data (Doc 9303 Part 5 §4.2.2).
    private static func td1Composite(slots: [Character], optional1: [Character], tail: [Character]) -> Bool? {
        guard tail.count >= 2, let composite = digitValue(tail[tail.count - 1]),
              let first = fitTrailingFiller(optional1, length: 15),
              let second = fitTrailingFiller(Array(tail[0 ..< tail.count - 1]), length: 11) else { return nil }
        let input = String(slots[0 ..< 10]) + first + String(slots[13 ..< 20]) + String(slots[21 ..< 28]) + second
        return PassportMRZ.checkDigit(input) == composite
    }

    // MARK: - Characters

    /// Look-alikes that can only mean one digit.
    static let digitForLetter: [Character: Character] = [
        "O": "0", "Q": "0", "D": "0", "U": "0",
        "I": "1", "L": "1",
        "Z": "2", "S": "5", "G": "6", "B": "8",
    ]

    /// Look-alikes that can only mean one letter.
    static let letterForDigit: [Character: Character] = [
        "0": "O", "1": "I", "2": "Z", "4": "A", "5": "S", "6": "G", "8": "B",
    ]

    /// The date block: date of birth (6), check, sex, expiry (6), check. Month
    /// and day of birth may be `<<` (unknown, Doc 9303 Part 3). At least half
    /// of it must be real digits, which keeps a run of look-alike letters in a
    /// name line from anchoring.
    static func isDateBlock(_ chars: [Character], at start: Int) -> Bool {
        guard start >= 0, start + 15 <= chars.count else { return false }
        var realDigits = 0
        for offset in 0 ..< 15 {
            let character = chars[start + offset]
            if character.isASCII, character.isNumber { realDigits += 1 }
            switch offset {
            case 7:
                guard "MFX<".contains(character) else { return false }
            case 2 ... 5:
                guard isDigitLike(character) || character == "<" else { return false }
            default:
                guard isDigitLike(character) else { return false }
            }
        }
        return realDigits >= 8
    }

    private static func isDigitLike(_ character: Character) -> Bool {
        ("0" ... "9").contains(character) || digitForLetter[character] != nil
    }

    /// Apply the one-right-answer coercions to the 28 key positions. The
    /// document number (0-8) is left exactly as read.
    static func coerce(_ raw: [Character]) -> [Character] {
        var slots = raw
        for index in MRZKeySlots.digitPositions {
            slots[index] = coerceDigit(slots[index])
        }
        for index in MRZKeySlots.nationality {
            slots[index] = letterForDigit[slots[index]] ?? slots[index]
        }
        return slots
    }

    private static func coerceDigit(_ character: Character) -> Character {
        digitForLetter[character] ?? character
    }

    private static func digitValue(_ character: Character) -> Int? {
        coerceDigit(character).wholeNumberValue
    }

    /// Strip a field's trailing filler and pad it back to `length`; `nil` when
    /// what is left is longer than the field.
    private static func fitTrailingFiller(_ field: [Character], length: Int) -> String? {
        var content = field
        while content.last == "<" {
            content.removeLast()
        }
        guard content.count <= length else { return nil }
        return String(content) + String(repeating: "<", count: length - content.count)
    }
}

/// The 28 key positions shared by every layout, and the checks that decide
/// whether a set of them is a usable access key.
public enum MRZKeySlots {
    public static let count = 28
    public static let documentNumber = 0 ..< 9
    public static let documentCheck = 9
    public static let nationality = 10 ..< 13
    public static let dateOfBirth = 13 ..< 19
    public static let dateOfBirthCheck = 19
    public static let sex = 20
    public static let dateOfExpiry = 21 ..< 27
    public static let dateOfExpiryCheck = 27

    /// Positions that can only hold a digit (or, for the date of birth's month
    /// and day, filler).
    static let digitPositions: [Int] = [documentCheck] + Array(dateOfBirth) + [dateOfBirthCheck]
        + Array(dateOfExpiry) + [dateOfExpiryCheck]

    /// Positions the access key is made of: the number, the dates and their
    /// check digits. Nationality and sex are checked for shape but are not part
    /// of the key, so two readings that differ only there agree.
    public static let keyPositions: [Int] = Array(documentNumber) + [documentCheck] + Array(dateOfBirth)
        + [dateOfBirthCheck] + Array(dateOfExpiry) + [dateOfExpiryCheck]

    /// The access key, when the slots pass every check: the three check digits,
    /// real calendar dates, and the shape of nationality and sex.
    ///
    /// `<` is refused in a check-digit position even though it scores 0. A `<`
    /// at the number's check digit means a number longer than nine characters,
    /// continued in the optional data (Doc 9303-5 note j, a Belgian eID's 12
    /// digits). `PassportMRZ` takes such a number whole, but these 28 slots
    /// hold nine, so the camera refuses the document rather than locking a cut
    /// number, and the holder types it.
    public static func key(from slots: [Character]) -> PassportMRZ? {
        guard slots.count == count else { return nil }
        let number = String(slots[documentNumber])
        let birth = String(slots[dateOfBirth])
        let expiry = String(slots[dateOfExpiry])
        guard number.first != "<",
              number.allSatisfy({ ("A" ... "Z").contains($0) || ("0" ... "9").contains($0) || $0 == "<" }),
              checks(number, slots[documentCheck]),
              checks(birth, slots[dateOfBirthCheck]),
              checks(expiry, slots[dateOfExpiryCheck]),
              isDate(birth, allowUnknown: true),
              isDate(expiry, allowUnknown: false),
              slots[nationality].allSatisfy({ ("A" ... "Z").contains($0) || $0 == "<" }),
              "MFX<".contains(slots[sex]) else { return nil }
        var trimmed = number
        while trimmed.hasSuffix("<") {
            trimmed.removeLast()
        }
        return PassportMRZ(documentNumber: trimmed, dateOfBirth: birth, dateOfExpiry: expiry)
    }

    private static func checks(_ field: String, _ digit: Character) -> Bool {
        guard let value = digit.wholeNumberValue, digit.isASCII else { return false }
        return PassportMRZ.checkDigit(field) == value
    }

    /// `YYMMDD`, a real day of a real month. 29 February is allowed in any year
    /// divisible by four, which is every leap year the two-digit year can name
    /// except 1900, and no living holder was born in February 1900. With
    /// `allowUnknown`, month and day may be `<<`, and an unknown month forces an
    /// unknown day.
    static func isDate(_ text: String, allowUnknown: Bool) -> Bool {
        let chars = Array(text)
        guard chars.count == 6,
              let year = Int(String(chars[0 ..< 2])), chars[0].isASCII, chars[1].isASCII else { return false }
        let monthText = String(chars[2 ..< 4])
        let dayText = String(chars[4 ..< 6])
        if allowUnknown, monthText == "<<" { return dayText == "<<" }
        guard let month = Int(monthText), (1 ... 12).contains(month),
              monthText.allSatisfy(\.isASCII) else { return false }
        if allowUnknown, dayText == "<<" { return true }
        guard let day = Int(dayText), dayText.allSatisfy(\.isASCII) else { return false }
        let days = [31, year % 4 == 0 ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return (1 ... days[month - 1]).contains(day)
    }
}
