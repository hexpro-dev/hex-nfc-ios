import Foundation

/// The **LDS Security Object** (EF.SOD) — the chip's signed manifest of
/// data-group hashes (ICAO Doc 9303 Part 10 §4.6.2 / Part 11). It lets a reader
/// confirm that the data groups it read match what the issuer sealed: hash each
/// DG, compare against the value listed here.
///
/// This parser is deliberately **integrity-only**. It walks the CMS `SignedData`
/// to the `LDSSecurityObject` and lifts the hash algorithm + per-DG hashes; it
/// does **not** verify the `SignedData` signature or any certificate chain
/// (that is Passive Authentication, which needs a CSCA trust store the app does
/// not carry). So a match means "not altered on the chip", never "genuine".
///
/// Pure ASN.1 (built on `BERTLV`) — no NFC, no crypto — so it unit-tests alone.
public struct LDSSecurityObject: Sendable, Equatable {
    /// The digest algorithm the security object used for its DG hashes.
    public enum HashAlgorithm: String, Sendable, Equatable {
        case sha1 = "SHA-1"
        case sha224 = "SHA-224"
        case sha256 = "SHA-256"
        case sha384 = "SHA-384"
        case sha512 = "SHA-512"

        /// Match on the DER *value* bytes of the algorithm's OBJECT IDENTIFIER.
        init?(oidValue: Data) {
            switch [UInt8](oidValue) {
            case [0x2B, 0x0E, 0x03, 0x02, 0x1A]: self = .sha1
            case [0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x04]: self = .sha224
            case [0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01]: self = .sha256
            case [0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x02]: self = .sha384
            case [0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x03]: self = .sha512
            default: return nil
            }
        }
    }

    public let hashAlgorithm: HashAlgorithm
    /// DG number → the hash value the security object lists for that data group.
    public let dataGroupHashes: [Int: Data]

    public init(hashAlgorithm: HashAlgorithm, dataGroupHashes: [Int: Data]) {
        self.hashAlgorithm = hashAlgorithm
        self.dataGroupHashes = dataGroupHashes
    }

    // MARK: - Parsing

    /// Parse an EF.SOD file into its LDS Security Object, or `nil` if it does not
    /// have the expected CMS `SignedData` → `LDSSecurityObject` shape.
    public static func parse(_ efSOD: Data) -> LDSSecurityObject? {
        guard let root = try? BERTLV.parseFirst(efSOD) else { return nil }

        // EF.SOD wraps a CMS ContentInfo in application tag 0x77; tolerate a file
        // that begins directly with the ContentInfo SEQUENCE.
        let contentInfo = (root.tag == 0x77 ? root.children.first : root) ?? root

        // ContentInfo -> [0] EXPLICIT -> SignedData SEQUENCE.
        guard let explicit0 = contentInfo.child(tag: 0xA0),
              let signedData = explicit0.children.first(where: { $0.tag == 0x30 })
        else { return nil }

        // SignedData -> encapContentInfo (its only SEQUENCE child) -> [0] -> eContent.
        guard let encap = signedData.children.first(where: { $0.tag == 0x30 }),
              let eContentExplicit = encap.child(tag: 0xA0),
              let octet = eContentExplicit.firstDescendant(tag: 0x04)
        else { return nil }

        // The eContent OCTET STRING's value is the DER of the LDSSecurityObject.
        guard let lds = try? BERTLV.parseFirst(octet.value), lds.tag == 0x30 else { return nil }

        // LDSSecurityObject ::= { version INTEGER, hashAlgorithm AlgId,
        //                         dataGroupHashValues SEQUENCE OF DataGroupHash }.
        let sequences = lds.children.filter { $0.tag == 0x30 }
        guard sequences.count >= 2,
              let oid = sequences[0].child(tag: 0x06)?.value,
              let algorithm = HashAlgorithm(oidValue: oid)
        else { return nil }

        var hashes: [Int: Data] = [:]
        for entry in sequences[1].children where entry.tag == 0x30 {
            guard let number = entry.child(tag: 0x02),
                  let value = entry.child(tag: 0x04) else { continue }
            let dg = number.value.reduce(0) { ($0 << 8) | Int($1) }
            hashes[dg] = value.value
        }
        guard !hashes.isEmpty else { return nil }

        return LDSSecurityObject(hashAlgorithm: algorithm, dataGroupHashes: hashes)
    }
}
