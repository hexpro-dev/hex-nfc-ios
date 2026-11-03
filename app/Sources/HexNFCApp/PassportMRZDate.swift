import Foundation

/// Turns a machine-readable zone's two-digit-year `YYMMDD` into a calendar
/// date. Two-digit years are inherently ambiguous: expiry is always 20YY; a date
/// of birth is in the past, so a candidate 20YY that lands in the future rolls
/// back to 19YY. This ages with the calendar (no hardcoded pivot) and never
/// produces a future birth date.
enum PassportMRZDate {
    /// `nil` when any part is unknown (`<<`) or the date does not exist.
    static func date(_ yymmdd: String, isExpiry: Bool, now: Date = Date()) -> Date? {
        guard yymmdd.count == 6, let yy = Int(yymmdd.prefix(2)),
              let mm = Int(yymmdd.dropFirst(2).prefix(2)),
              let dd = Int(yymmdd.suffix(2)) else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        let year: Int
        if isExpiry {
            year = 2000 + yy
        } else {
            let currentYear = calendar.component(.year, from: now)
            let candidate = 2000 + yy
            year = candidate > currentYear ? candidate - 100 : candidate
        }
        let components = DateComponents(year: year, month: mm, day: dd)
        // `date(from:)` rolls 31 April over into May; a date that moved did
        // not exist.
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == dd else { return nil }
        return date
    }

    /// Device-locale, abbreviated-month formatting (no hardcoded `en_US_POSIX`
    /// pattern). Falls back to the raw six characters for a date with an
    /// unknown part, which some documents legitimately carry.
    static func display(_ yymmdd: String, isExpiry: Bool) -> String {
        guard let date = date(yymmdd, isExpiry: isExpiry) else { return yymmdd }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}
