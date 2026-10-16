import Foundation

/// A minimal BER-TLV / ASN.1 DER reader, sized to what eMRTD (ICAO Doc 9303)
/// reading needs: parsing data groups (DG1, DG2, DG11, DG12), `EF.COM`, and the
/// PACE `EF.CardAccess` `SecurityInfos`.
///
/// eMRTD encodes everything as BER-TLV; the ASN.1 structures inside
/// `EF.CardAccess` (SEQUENCE / SET / OBJECT IDENTIFIER / INTEGER) are the same
/// tag-length-value shape, so one reader covers both. This is deliberately
/// read-only and forgiving of trailing bytes — it never encodes.
///
/// References:
///   - ISO/IEC 8825-1 (BER/DER encoding rules), §8.1 identifier / length octets.
///   - ICAO Doc 9303 Part 10 (LDS) for the data-group tag layout.
public struct BERTLV: Equatable, Sendable {
    /// The full tag, packed big-endian from its identifier octets. A one-byte
    /// tag like `0x61` is `0x61`; a two-byte tag like `0x5F1F` is `0x5F1F`.
    public let tag: UInt64
    /// The raw identifier octets exactly as they appeared on the wire.
    public let tagBytes: [UInt8]
    /// `true` when bit 6 of the leading identifier octet is set — the value is
    /// itself a sequence of TLVs (`children`), not primitive content.
    public let isConstructed: Bool
    /// The raw content octets (the "V"). For a constructed node this is the
    /// concatenation of its encoded children.
    public let value: Data
    /// Parsed children, present only for constructed nodes.
    public let children: [BERTLV]

    public enum ParseError: Error, Equatable, Sendable {
        case truncatedTag
        case truncatedLength
        case indefiniteLengthUnsupported
        case lengthTooLarge
        case truncatedValue
    }

    // MARK: - Parsing

    /// Parse every top-level TLV in `data`. Trailing padding shorter than a full
    /// tag+length is tolerated only when it is entirely absent; a partial TLV is
    /// an error so corruption is surfaced rather than silently dropped.
    public static func parse(_ data: Data) throws -> [BERTLV] {
        var nodes: [BERTLV] = []
        var index = data.startIndex
        while index < data.endIndex {
            // Skip inter-TLV 0x00 / 0xFF filler octets that some encoders emit.
            let lead = data[index]
            if lead == 0x00 || lead == 0xFF {
                index += 1
                continue
            }
            let (node, next) = try parseNode(data, at: index)
            nodes.append(node)
            index = next
        }
        return nodes
    }

    /// Parse and return the first TLV in `data`, ignoring anything after it.
    public static func parseFirst(_ data: Data) throws -> BERTLV {
        guard let first = try parse(data).first else { throw ParseError.truncatedTag }
        return first
    }

    private static func parseNode(_ data: Data, at start: Data.Index) throws -> (BERTLV, Data.Index) {
        var cursor = start

        // --- Identifier octets (tag) ---
        guard cursor < data.endIndex else { throw ParseError.truncatedTag }
        let firstByte = data[cursor]
        var tagBytes: [UInt8] = [firstByte]
        cursor += 1
        if (firstByte & 0x1F) == 0x1F {
            // Multi-byte tag: subsequent octets carry a continuation bit (0x80).
            var more = true
            while more {
                guard cursor < data.endIndex else { throw ParseError.truncatedTag }
                let b = data[cursor]
                tagBytes.append(b)
                cursor += 1
                more = (b & 0x80) != 0
                if tagBytes.count > 8 {
                    throw ParseError.lengthTooLarge
                }
            }
        }
        let isConstructed = (firstByte & 0x20) != 0
        var tag: UInt64 = 0
        for b in tagBytes {
            tag = (tag << 8) | UInt64(b)
        }

        // --- Length octets ---
        guard cursor < data.endIndex else { throw ParseError.truncatedLength }
        let firstLen = data[cursor]
        cursor += 1
        var length: Int
        if firstLen & 0x80 == 0 {
            length = Int(firstLen) // short form
        } else {
            let count = Int(firstLen & 0x7F)
            if count == 0 {
                throw ParseError.indefiniteLengthUnsupported
            }
            if count > 4 {
                throw ParseError.lengthTooLarge
            }
            guard data.distance(from: cursor, to: data.endIndex) >= count else {
                throw ParseError.truncatedLength
            }
            length = 0
            for _ in 0 ..< count {
                length = (length << 8) | Int(data[cursor])
                cursor += 1
            }
        }

        // --- Value octets ---
        guard data.distance(from: cursor, to: data.endIndex) >= length else {
            throw ParseError.truncatedValue
        }
        let valueEnd = data.index(cursor, offsetBy: length)
        let value = Data(data[cursor ..< valueEnd])

        let children = isConstructed ? try parse(value) : []
        let node = BERTLV(
            tag: tag,
            tagBytes: tagBytes,
            isConstructed: isConstructed,
            value: value,
            children: children
        )
        return (node, valueEnd)
    }

    // MARK: - Navigation

    /// The first direct child with `tag`, if any.
    public func child(tag: UInt64) -> BERTLV? {
        children.first { $0.tag == tag }
    }

    /// The first node anywhere in this subtree (self included) with `tag`,
    /// depth-first. Used to reach, say, the `0x5F1F` MRZ octet-string nested
    /// inside DG1's `0x61` template regardless of intermediate wrappers.
    public func firstDescendant(tag: UInt64) -> BERTLV? {
        if self.tag == tag {
            return self
        }
        for child in children {
            if let hit = child.firstDescendant(tag: tag) {
                return hit
            }
        }
        return nil
    }
}
