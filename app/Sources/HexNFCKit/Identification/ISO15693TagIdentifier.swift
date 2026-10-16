#if canImport(CoreNFC) && os(iOS)
import CoreNFC
import Foundation

/// Identifies ISO 15693 / NFC Type 5 tags.
///
/// NXP ICODE silicon is recognised by its IC manufacturer code (`0x04`), and the
/// tag's own *Get System Information* (`0x2B`) supplies the real memory geometry
/// — which beats the datasheet estimate when the read is clean, and falls back
/// to it when the field is absent or the read is weak (iOS ISO 15693 is only
/// ~10-15% reliable). The IC-reference byte — the SLIX / SLIX2 / SLIX-S / SLIX-L
/// discriminator — is logged but not yet mapped to a variant: no datasheet-
/// verified value lives in the repo, so a real-tag capture has to seed it first.
/// The pure decode lives in `ChipCatalog.iso15693Profile`, testable without an
/// entitled session.
struct ISO15693TagIdentifier: Sendable {
    func identify(_ tag: NFCISO15693Tag) async -> ChipProfile? {
        let manufacturer = UInt8(truncatingIfNeeded: tag.icManufacturerCode)
        let info = await Self.readSystemInfo(tag)
        // Capture icMfr + the IC-reference byte + self-reported memory in the
        // trace: the IC reference is the verified anchor we need to start
        // distinguishing ICODE variants over the air on a future tap.
        NFCTrace.shared.note(
            "ISO15693 uid=\(tag.identifier.hexString) "
                + "icMfr=\(String(format: "%02X", manufacturer)) "
                + "icRef=\(info?.icReference.map { String(format: "%02X", $0) } ?? "n/a") "
                + "mem=\(info?.memoryBytes.map { "\($0)B" } ?? "n/a")",
            label: "identify"
        )
        return ChipCatalog.iso15693Profile(icManufacturerCode: manufacturer, systemInfo: info)
    }

    /// Best-effort *Get System Information* (`0x2B`). A read failure — a weak
    /// ISO 15693 field, or a tag that doesn't answer 0x2B — resolves to `nil`,
    /// and the profile builder falls back to the datasheet memory estimate. The
    /// `-1` sentinels CoreNFC returns for fields the response omitted (or a
    /// truncated frame) are mapped to `nil` by `ISO15693SystemInfo`.
    private static func readSystemInfo(_ tag: NFCISO15693Tag) async -> ISO15693SystemInfo? {
        guard let info = try? await tag.systemInfo(requestFlags: .highDataRate) else {
            return nil
        }
        // CoreNFC returns -1 for any field the response omitted; `ISO15693SystemInfo`
        // maps those to nil so the profile builder falls back to the datasheet.
        return ISO15693SystemInfo(
            coreNFCBlockSize: info.blockSize,
            blockCount: info.totalBlocks,
            icReference: info.icReference
        )
    }
}
#endif
