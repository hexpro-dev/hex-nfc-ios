import Foundation

/// The access key a holder enters to unlock their passport chip: the three
/// Machine-Readable-Zone fields BAC and PACE both derive their keys from —
/// document number, date of birth, date of expiry (each `YYMMDD` for the dates).
///
/// This carries **no cryptography** — it only assembles the canonical "MRZ
/// information" string and computes ICAO 9303 check digits. Key derivation
/// (SHA-1 → K.enc/K.mac for BAC, KDF π for PACE) lives in `HexNFCKit`, which
/// consumes `mrzInformation`. The value is **session-only**: it is held in
/// memory for a single read and never persisted (not to SwiftData, exports,
/// iCloud, or Keychain).
///
/// Reference: ICAO Doc 9303 Part 3 (MRZ check-digit algorithm) and Part 11
/// (`MRZ_information` for Document Basic Access Keys / PACE password).
public struct PassportMRZ: Hashable, Sendable, Codable {
    /// The document (passport) number exactly as printed, e.g. `PA1234567`.
    /// Normalised to upper case and `<`-padded to nine characters when the key
    /// is assembled.
    public var documentNumber: String
    /// Date of birth as six digits `YYMMDD`.
    public var dateOfBirth: String
    /// Date of expiry as six digits `YYMMDD`.
    public var dateOfExpiry: String

    public init(documentNumber: String, dateOfBirth: String, dateOfExpiry: String) {
        self.documentNumber = documentNumber
        self.dateOfBirth = dateOfBirth
        self.dateOfExpiry = dateOfExpiry
    }

    // MARK: - Check digits

    /// ICAO 9303 check digit over `input`: weight the character values by the
    /// repeating `7, 3, 1` pattern, sum, take mod 10. Character values are
    /// `0`–`9` → 0–9, `A`–`Z` → 10–35, and the filler `<` → 0. Any character
    /// outside that set contributes 0, matching how readers treat stray input.
    public static func checkDigit(_ input: String) -> Int {
        let weights = [7, 3, 1]
        var sum = 0
        for (offset, scalar) in input.uppercased().unicodeScalars.enumerated() {
            sum += value(of: scalar) * weights[offset % 3]
        }
        return sum % 10
    }

    private static func value(of scalar: Unicode.Scalar) -> Int {
        switch scalar {
        case "0" ... "9": Int(scalar.value - Unicode.Scalar("0").value)
        case "A" ... "Z": Int(scalar.value - Unicode.Scalar("A").value) + 10
        case "<": 0
        default: 0
        }
    }

    // MARK: - Derived fields

    /// The document number in its 9-character MRZ field form: upper-cased and
    /// right-padded with `<` filler. (Numbers longer than nine characters use
    /// the extended optional-data scheme, which v1 does not support.)
    public var documentNumberField: String {
        let trimmed = String(documentNumber.uppercased().prefix(9))
        return trimmed.padding(toLength: 9, withPad: "<", startingAt: 0)
    }

    /// The canonical `MRZ_information` string BAC/PACE key derivation hashes:
    /// `docNumberField ‖ docCheck ‖ DOB ‖ dobCheck ‖ expiry ‖ expiryCheck`
    /// (24 characters). Doc 9303 Part 11, §D / §9.7.2.
    public var mrzInformation: String {
        let doc = documentNumberField
        let dob = String(dateOfBirth.prefix(6))
        let exp = String(dateOfExpiry.prefix(6))
        return doc
            + String(Self.checkDigit(doc))
            + dob
            + String(Self.checkDigit(dob))
            + exp
            + String(Self.checkDigit(exp))
    }

    // MARK: - Validation

    /// `true` when all three fields are present and the dates are six digits —
    /// the minimum for key derivation to be meaningful. This does **not** verify
    /// the key is correct for a given chip (only a live read can).
    public var isWellFormed: Bool {
        !documentNumber.trimmingCharacters(in: .whitespaces).isEmpty
            && Self.isSixDigits(dateOfBirth)
            && Self.isSixDigits(dateOfExpiry)
    }

    private static func isSixDigits(_ s: String) -> Bool {
        s.count == 6 && s.allSatisfy(\.isNumber)
    }
}
