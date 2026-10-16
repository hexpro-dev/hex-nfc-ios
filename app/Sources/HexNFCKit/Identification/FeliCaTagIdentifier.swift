#if canImport(CoreNFC) && os(iOS)
import CoreNFC
import Foundation

/// Identifies FeliCa (NFC Type 3) tags.
///
/// We report the generic FeliCa profile (the system code alone can't pin down a
/// specific Sony chip part), but when the card polled on the interoperable
/// Japanese transit system code `0x0003` we add the `.transitRead` capability so
/// the scan flow knows to read the history service and present the transit view.
struct FeliCaTagIdentifier: Sendable {
    func identify(_ tag: NFCFeliCaTag) -> ChipProfile? {
        NFCTrace.shared.note(
            "FeliCa idm=\(tag.currentIDm.hexString) systemCode=\(tag.currentSystemCode.hexString)",
            label: "identify"
        )
        guard let base = ChipCatalog.profile(for: .genericFeliCa) else { return nil }
        guard Self.isTransitSystem(tag.currentSystemCode) else { return base }
        return ChipProfile(
            id: base.id,
            family: base.family,
            capabilities: base.capabilities.union(.transitRead),
            displayName: base.displayName,
            manufacturer: base.manufacturer,
            memoryLayout: base.memoryLayout
        )
    }

    /// `currentSystemCode` is 2 bytes, big-endian. `0x0003` is the nationwide
    /// interoperable transit family (Suica / PASMO / ICOCA / …).
    static func isTransitSystem(_ systemCode: Data) -> Bool {
        guard systemCode.count == 2 else { return false }
        let bytes = [UInt8](systemCode)
        let code = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        return code == 0x0003
    }
}
#endif
