import Foundation

/// Turns raw data-group file bytes (already decrypted out of secure messaging)
/// into a presentable `PassportData`. Pure and side-effect-free so it unit-tests
/// without any NFC or crypto. DG1 is required; DG2/DG11/DG12 are best-effort and
/// a failure in any of them degrades gracefully to "not present".
public enum PassportDataDecoder {
    /// Data-group / element tags (ICAO Doc 9303 Part 10).
    private enum Tag {
        static let dg1MRZ: UInt64 = 0x5F1F
        static let bioData1: UInt64 = 0x5F2E
        static let bioData2: UInt64 = 0x7F2E
        static let dg7Signature: UInt64 = 0x5F43
        // DG11
        static let fullName: UInt64 = 0x5F0E
        static let personalNumber: UInt64 = 0x5F10
        static let fullDOB: UInt64 = 0x5F2B
        static let placeOfBirth: UInt64 = 0x5F11
        static let address: UInt64 = 0x5F42
        static let telephone: UInt64 = 0x5F12
        static let profession: UInt64 = 0x5F13
        static let title: UInt64 = 0x5F14
        static let otherName: UInt64 = 0x5F15
        // DG12
        static let issuingAuthority: UInt64 = 0x5F19
        static let dateOfIssue: UInt64 = 0x5F26
    }

    /// Assemble a passport from a map of data-group number → raw file bytes.
    /// Returns `nil` only when DG1 is missing or unparseable — everything else
    /// is optional.
    public static func decode(dataGroups: [Int: Data]) -> PassportData? {
        guard let dg1 = dataGroups[1], var data = decodeDG1(dg1) else { return nil }

        if let dg2 = dataGroups[2] {
            data.faceImage = decodeDG2(dg2)
        }

        if let dg7 = dataGroups[7] {
            data.signatureImage = decodeDG7(dg7)
        }

        var bio = PassportBiographical()
        if let dg11 = dataGroups[11] {
            applyDG11(dg11, into: &bio)
        }
        if let dg12 = dataGroups[12] {
            applyDG12(dg12, into: &bio)
        }
        if !bio.isEmpty {
            data.biographical = bio
        }

        return data
    }

    // MARK: - DG1 (MRZ)

    static func decodeDG1(_ bytes: Data) -> PassportData? {
        guard
            let root = try? BERTLV.parseFirst(bytes),
            let mrzNode = root.firstDescendant(tag: Tag.dg1MRZ),
            let mrzString = text(mrzNode.value),
            let fields = MRZParser.parse(mrzString)
        else { return nil }

        return PassportData(
            documentType: fields.documentType,
            issuingState: fields.issuingState,
            primaryIdentifier: fields.primaryIdentifier,
            secondaryIdentifier: fields.secondaryIdentifier,
            documentNumber: fields.documentNumber,
            nationality: fields.nationality,
            dateOfBirth: fields.dateOfBirth,
            sex: fields.sex,
            dateOfExpiry: fields.dateOfExpiry,
            optionalData: fields.optionalData,
            rawMRZ: fields.raw
        )
    }

    // MARK: - DG2 (face image)

    /// Extract the encoded face image from DG2. Rather than fully parse the
    /// nested CBEFF / ISO 19794-5 facial record (whose header length varies by
    /// version), locate the biometric data block by tag and then scan it for the
    /// JPEG or JPEG 2000 magic — the approach production readers use. Returns
    /// `nil` if no image marker is found.
    static func decodeDG2(_ bytes: Data) -> PassportImage? {
        let haystack: Data = {
            guard let root = try? BERTLV.parseFirst(bytes) else { return bytes }
            if let block = root.firstDescendant(tag: Tag.bioData1) {
                return block.value
            }
            if let block = root.firstDescendant(tag: Tag.bioData2) {
                return block.value
            }
            return bytes
        }()
        return findImage(in: haystack)
    }

    /// Scan `data` for the first JPEG (`FF D8 FF`) or JPEG 2000 (JP2 box or J2K
    /// codestream) marker and slice from there to the end.
    static func findImage(in data: Data) -> PassportImage? {
        let bytes = [UInt8](data)

        let jp2Box: [UInt8] = [0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20]
        let j2kCodestream: [UInt8] = [0xFF, 0x4F, 0xFF, 0x51]
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF]

        if let idx = firstIndex(of: jp2Box, in: bytes) {
            return PassportImage(data: Data(bytes[idx...]), format: .jpeg2000)
        }
        if let idx = firstIndex(of: j2kCodestream, in: bytes) {
            return PassportImage(data: Data(bytes[idx...]), format: .jpeg2000)
        }
        if let idx = firstIndex(of: jpeg, in: bytes) {
            return PassportImage(data: Data(bytes[idx...]), format: .jpeg)
        }
        return nil
    }

    // MARK: - DG7 (displayed signature / usual mark)

    /// Extract the signature image from DG7. Like DG2, the image sits inside a
    /// `0x5F43` element; scan it for the JPEG / JPEG 2000 marker.
    static func decodeDG7(_ bytes: Data) -> PassportImage? {
        let haystack: Data = {
            guard let root = try? BERTLV.parseFirst(bytes) else { return bytes }
            return root.firstDescendant(tag: Tag.dg7Signature)?.value ?? bytes
        }()
        return findImage(in: haystack)
    }

    // MARK: - DG11 / DG12 (extended detail)

    private static func applyDG11(_ bytes: Data, into bio: inout PassportBiographical) {
        guard let root = try? BERTLV.parseFirst(bytes) else { return }
        bio.fullName = humanName(root.firstDescendant(tag: Tag.fullName)?.value)
        bio.personalNumber = trimmedText(root.firstDescendant(tag: Tag.personalNumber)?.value)
        bio.fullDateOfBirth = trimmedText(root.firstDescendant(tag: Tag.fullDOB)?.value)
        bio.placeOfBirth = humanName(root.firstDescendant(tag: Tag.placeOfBirth)?.value)
        bio.permanentAddress = humanName(root.firstDescendant(tag: Tag.address)?.value)
        bio.telephone = trimmedText(root.firstDescendant(tag: Tag.telephone)?.value)
        bio.profession = humanName(root.firstDescendant(tag: Tag.profession)?.value)
        bio.title = humanName(root.firstDescendant(tag: Tag.title)?.value)
        // "Other names" can appear once (0x5F15) or grouped; collect all.
        bio.otherNames = collectAll(tag: Tag.otherName, in: root)
            .compactMap { humanName($0) }
            .filter { !$0.isEmpty }
    }

    private static func applyDG12(_ bytes: Data, into bio: inout PassportBiographical) {
        guard let root = try? BERTLV.parseFirst(bytes) else { return }
        bio.issuingAuthority = humanName(root.firstDescendant(tag: Tag.issuingAuthority)?.value)
        bio.dateOfIssue = trimmedText(root.firstDescendant(tag: Tag.dateOfIssue)?.value)
    }

    // MARK: - Text helpers

    private static func text(_ data: Data) -> String? {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private static func trimmedText(_ data: Data?) -> String? {
        guard let data, let s = text(data)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty
        else { return nil }
        return s
    }

    /// Decode a name-like field and turn `<` filler into readable separators.
    private static func humanName(_ data: Data?) -> String? {
        guard let raw = trimmedText(data) else { return nil }
        let spaced = raw
            .replacingOccurrences(of: "<<", with: ", ")
            .replacingOccurrences(of: "<", with: " ")
        let collapsed = spaced.split(whereSeparator: { $0 == " " }).joined(separator: " ")
        let result = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        return result.isEmpty ? nil : result
    }

    /// Every descendant value for `tag` in the tree (self-inclusive).
    private static func collectAll(tag: UInt64, in node: BERTLV) -> [Data] {
        var out: [Data] = []
        if node.tag == tag {
            out.append(node.value)
        }
        for child in node.children {
            out.append(contentsOf: collectAll(tag: tag, in: child))
        }
        return out
    }

    private static func firstIndex(of pattern: [UInt8], in bytes: [UInt8]) -> Int? {
        guard !pattern.isEmpty, bytes.count >= pattern.count else { return nil }
        for start in 0 ... (bytes.count - pattern.count) {
            var matched = true
            for offset in 0 ..< pattern.count where bytes[start + offset] != pattern[offset] {
                matched = false
                break
            }
            if matched {
                return start
            }
        }
        return nil
    }
}
