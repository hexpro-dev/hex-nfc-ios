import Foundation

/// Hex parsing, out of the view layer.
///
/// It used to live at the bottom of `OperationsSheet.swift`, inside that file's
/// `#if os(iOS)`, so nothing on the test host could call it: `swift test` on
/// macOS never compiles a screen. `EditFlowModel.targetUID` needs it and is
/// tested, which is what moved it here.
public extension Data {
    /// Parse a flexible hex string (`"AA:BB:CC"` or `"AABBCC"` or
    /// `"aa bb cc"`) into bytes. Returns nil on any malformed input — the
    /// caller uses byte count to decide whether the parse is *acceptable*
    /// for its use.
    static func parseHex(_ input: String) -> Data? {
        let trimmed = input
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\t", with: "")
        guard !trimmed.isEmpty, trimmed.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(trimmed.count / 2)
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let next = trimmed.index(index, offsetBy: 2)
            guard let byte = UInt8(trimmed[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }
}
