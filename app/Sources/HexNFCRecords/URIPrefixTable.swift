import Foundation

/// The NFC Forum "URI Record Type" defines a single-byte prefix code
/// (`0x00`–`0x23`) that shortens common scheme/host pairs into one byte.
/// Reference: NFC Forum *URI Record Type Definition* §3.2.2.
///
/// We use this in two places:
///   - decoding: `prefix(for:)` expands the byte into its string.
///   - encoding: `shortest(matchingPrefixFor:)` finds the longest matching
///     prefix so the on-tag payload is as small as possible — important for
///     NTAG213 where total NDEF capacity is only 144 bytes.
public enum URIPrefixTable {
    /// Lookup table, indexed by the prefix byte. Indices outside `0...35`
    /// are reserved by the spec and decode to an empty prefix.
    public static let entries: [String] = [
        "", // 0x00. No prefix
        "http://www.", // 0x01
        "https://www.", // 0x02
        "http://", // 0x03
        "https://", // 0x04
        "tel:", // 0x05
        "mailto:", // 0x06
        "ftp://anonymous:anonymous@", // 0x07
        "ftp://ftp.", // 0x08
        "ftps://", // 0x09
        "sftp://", // 0x0A
        "smb://", // 0x0B
        "nfs://", // 0x0C
        "ftp://", // 0x0D
        "dav://", // 0x0E
        "news:", // 0x0F
        "telnet://", // 0x10
        "imap:", // 0x11
        "rtsp://", // 0x12
        "urn:", // 0x13
        "pop:", // 0x14
        "sip:", // 0x15
        "sips:", // 0x16
        "tftp:", // 0x17
        "btspp://", // 0x18
        "btl2cap://", // 0x19
        "btgoep://", // 0x1A
        "tcpobex://", // 0x1B
        "irdaobex://", // 0x1C
        "file://", // 0x1D
        "urn:epc:id:", // 0x1E
        "urn:epc:tag:", // 0x1F
        "urn:epc:pat:", // 0x20
        "urn:epc:raw:", // 0x21
        "urn:epc:", // 0x22
        "urn:nfc:", // 0x23
    ]

    /// Returns the prefix for a given byte, or empty string for any byte
    /// outside the spec range. A decode never throws on this — unknown
    /// prefixes are treated as "no prefix".
    public static func prefix(for byte: UInt8) -> String {
        let index = Int(byte)
        guard index < entries.count else { return "" }
        return entries[index]
    }

    /// Find the longest entry that prefixes `string`, returning the
    /// `(code, remainder)` pair. If nothing matches, returns `(0x00, string)`.
    public static func shortest(matchingPrefixFor string: String) -> (code: UInt8, remainder: String) {
        var best: (code: UInt8, length: Int) = (0x00, 0)
        // Index 0 is the empty entry, skip it.
        for index in 1 ..< entries.count {
            let candidate = entries[index]
            if string.hasPrefix(candidate), candidate.count > best.length {
                best = (UInt8(index), candidate.count)
            }
        }
        let remainder = String(string.dropFirst(best.length))
        return (best.code, remainder)
    }
}
