import Foundation

/// Extended personal / document details from DG11 and DG12, all optional. These
/// data groups are frequently absent or partially populated, so every field is
/// nullable and the reader treats a missing or unparseable group as "no extra
/// details" rather than a failure.
public struct PassportBiographical: Hashable, Sendable, Codable {
    /// --- DG11: additional personal detail ---
    /// Full name of holder (`0x5F0E`), often more complete than the MRZ.
    public var fullName: String?
    /// Personal number (`0x5F10`).
    public var personalNumber: String?
    /// Full date of birth `YYYYMMDD` (`0x5F2B`), disambiguating the MRZ century.
    public var fullDateOfBirth: String?
    /// Place of birth (`0x5F11`), `<`-separated components joined with `, `.
    public var placeOfBirth: String?
    /// Permanent address (`0x5F42`).
    public var permanentAddress: String?
    /// Telephone (`0x5F12`).
    public var telephone: String?
    /// Profession (`0x5F13`).
    public var profession: String?
    /// Title (`0x5F14`).
    public var title: String?
    /// Other names (`0x5F15`).
    public var otherNames: [String]

    /// --- DG12: additional document detail ---
    /// Issuing authority (`0x5F19`).
    public var issuingAuthority: String?
    /// Date of issue `YYYYMMDD` (`0x5F26`).
    public var dateOfIssue: String?

    public init(
        fullName: String? = nil,
        personalNumber: String? = nil,
        fullDateOfBirth: String? = nil,
        placeOfBirth: String? = nil,
        permanentAddress: String? = nil,
        telephone: String? = nil,
        profession: String? = nil,
        title: String? = nil,
        otherNames: [String] = [],
        issuingAuthority: String? = nil,
        dateOfIssue: String? = nil
    ) {
        self.fullName = fullName
        self.personalNumber = personalNumber
        self.fullDateOfBirth = fullDateOfBirth
        self.placeOfBirth = placeOfBirth
        self.permanentAddress = permanentAddress
        self.telephone = telephone
        self.profession = profession
        self.title = title
        self.otherNames = otherNames
        self.issuingAuthority = issuingAuthority
        self.dateOfIssue = dateOfIssue
    }

    /// `true` when no field carries a value — the reader uses this to drop an
    /// empty biographical block rather than showing a blank section.
    public var isEmpty: Bool {
        fullName == nil && personalNumber == nil && fullDateOfBirth == nil
            && placeOfBirth == nil && permanentAddress == nil && telephone == nil
            && profession == nil && title == nil && otherNames.isEmpty
            && issuingAuthority == nil && dateOfIssue == nil
    }
}
