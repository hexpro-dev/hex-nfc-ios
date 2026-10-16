import Foundation

/// A face image read from a passport's DG2. `format` records how the bytes are
/// encoded so the UI can decode (or gracefully skip) — passports commonly use
/// JPEG or JPEG 2000, and iOS decodes the latter inconsistently.
public struct PassportImage: Hashable, Sendable, Codable {
    public enum Format: String, Sendable, Codable {
        case jpeg
        case jpeg2000
        case unknown
    }

    public let data: Data
    public let format: Format

    public init(data: Data, format: Format) {
        self.data = data
        self.format = format
    }
}

/// A data-group integrity result: how the data groups we read compared against
/// the hashes listed in the chip's signed Document Security Object (EF.SOD).
///
/// This is an **integrity** check, not an **authenticity** check — it proves the
/// data groups match the security object the chip carries, but it does **not**
/// verify that security object's signature against a trusted country-signing
/// certificate (no Passive Authentication). So the honest verdict is "likely
/// untampered / likely tampered", never "genuine".
public struct PassportIntegrityReport: Hashable, Sendable, Codable {
    public enum Status: String, Sendable, Codable {
        /// Every data group we read matched its hash in the security object.
        case verified
        /// At least one data group's hash did not match the security object.
        case mismatch
    }

    public let status: Status
    /// The hash algorithm the security object used, for display (e.g. "SHA-256").
    public let hashAlgorithm: String
    /// The data groups that were both read and listed in the security object.
    public let checkedDataGroups: [Int]
    /// The data groups whose computed hash did not match (empty when `verified`).
    public let mismatchedDataGroups: [Int]

    public init(
        status: Status,
        hashAlgorithm: String,
        checkedDataGroups: [Int],
        mismatchedDataGroups: [Int]
    ) {
        self.status = status
        self.hashAlgorithm = hashAlgorithm
        self.checkedDataGroups = checkedDataGroups
        self.mismatchedDataGroups = mismatchedDataGroups
    }
}

/// The parsed, presentable contents of an electronic passport, assembled from
/// the data groups. **Session-only**: shown in the result sheet for one read
/// and then dropped — never written to SwiftData, exports, iCloud, or Keychain.
/// It is `Codable` only for parity with the other read-only card models and for
/// in-memory passing; nothing serialises it to disk.
public struct PassportData: Hashable, Sendable, Codable, Identifiable {
    /// --- DG1 (MRZ) ---
    /// Document code, usually `P` (passport).
    public let documentType: String
    /// Three-letter issuing-state code, e.g. `AUS`.
    public let issuingState: String
    /// Surname / primary identifier.
    public let primaryIdentifier: String
    /// Given names / secondary identifier.
    public let secondaryIdentifier: String
    public let documentNumber: String
    /// Three-letter nationality code.
    public let nationality: String
    /// Date of birth, `YYMMDD`, exactly as encoded in the MRZ.
    public let dateOfBirth: String
    /// `M`, `F`, or `<` (unspecified).
    public let sex: String
    /// Date of expiry, `YYMMDD`.
    public let dateOfExpiry: String
    /// Optional data (personal number etc.) from MRZ line 2, filler stripped.
    public let optionalData: String
    /// The raw MRZ lines, newline-joined, for display and diagnostics.
    public let rawMRZ: String

    /// --- DG2 (face) ---
    public var faceImage: PassportImage?

    /// --- DG7 (displayed signature / usual mark) ---
    public var signatureImage: PassportImage?

    /// --- DG11 / DG12 (extended, optional) ---
    public var biographical: PassportBiographical?

    /// Data-group integrity vs the chip's signed security object (EF.SOD).
    /// `nil` when the check could not run (no EF.SOD, or it wouldn't parse).
    public var integrity: PassportIntegrityReport?

    /// Stable within a session for `Identifiable`. Uses the random chip UID is
    /// not available here, so the document number + expiry pair is used; these
    /// are already shown to the user, so this leaks nothing further.
    public var id: String {
        documentNumber + "\u{2022}" + dateOfExpiry
    }

    public init(
        documentType: String,
        issuingState: String,
        primaryIdentifier: String,
        secondaryIdentifier: String,
        documentNumber: String,
        nationality: String,
        dateOfBirth: String,
        sex: String,
        dateOfExpiry: String,
        optionalData: String,
        rawMRZ: String,
        faceImage: PassportImage? = nil,
        signatureImage: PassportImage? = nil,
        biographical: PassportBiographical? = nil,
        integrity: PassportIntegrityReport? = nil
    ) {
        self.documentType = documentType
        self.issuingState = issuingState
        self.primaryIdentifier = primaryIdentifier
        self.secondaryIdentifier = secondaryIdentifier
        self.documentNumber = documentNumber
        self.nationality = nationality
        self.dateOfBirth = dateOfBirth
        self.sex = sex
        self.dateOfExpiry = dateOfExpiry
        self.optionalData = optionalData
        self.rawMRZ = rawMRZ
        self.faceImage = faceImage
        self.signatureImage = signatureImage
        self.biographical = biographical
        self.integrity = integrity
    }
}
