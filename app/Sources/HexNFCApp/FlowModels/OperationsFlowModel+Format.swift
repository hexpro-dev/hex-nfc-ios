import Foundation
import HexNFCKit
import HexNFCRecords

/// Format's per-family work: where each chip keeps the structure that makes it
/// an NDEF tag, and how to put it there.
///
/// Split from `OperationsFlowModel` because the file reached its length limit,
/// on the same terms as `OperationsPreflight`: nothing here touches the state
/// machine. It takes a connected tag and either writes what the family needs or
/// refuses with the tag as it was.
extension OperationsFlowModel {
    /// Writes the Capability Container. Returns `true` when the tag already
    /// carried the correct CC and nothing was written.
    @discardableResult
    func formatCC(on tag: ConnectedTag) async throws -> Bool {
        // Each family keeps its Capability Container somewhere different, so
        // dispatch on the family rather than on `.memoryWrite` alone — a SLIX
        // advertises `.memoryWrite` but its CC is a block, not a page, and the
        // page writer would refuse it with a misleading "not a Type-2/MIFARE tag".
        switch tag.chip?.family {
        case .type2:
            // Factory CC bytes are the single source of truth on `ChipProfile`,
            // shared with the console presets and the chip simulators.
            //
            // An unidentified Type-2 chip must **refuse**, never fall back. This
            // previously defaulted to the smallest CC (`E1 10 06 00`, 48 B) on
            // the theory that guessing low is conservative. It is not: page 3 is
            // OTP, so the write ORs bits into whatever is already there and can
            // never clear them. Writing a 48-byte CC to a 144-byte chip either
            // permanently under-declares two thirds of its NDEF area, or, if a
            // CC is already present, ORs into it and produces a size byte that
            // belongs to no chip at all (0x12 | 0x06 = 0x16, declaring 176 bytes
            // of a 144-byte tag). There is exactly one attempt per tag, so a
            // guess here is unrecoverable in a way that an error is not.
            guard let cc = tag.chip?.factoryCC else {
                throw TagError.capabilityUnsupported(
                    .formatCC,
                    diagnostics: "Type-2 CC needs a known chip profile; this tag identified as "
                        + "\(tag.chip?.id.description ?? "unidentified") with no factory CC. "
                        + "Page 3 is OTP, so a guessed size byte cannot be undone."
                )
            }
            try tag.require(.memoryWrite)
            // CC lives at page 3 on Type-2 chips, and page 3 is **OTP**: writes
            // OR bits in and can never clear them. So read it first and refuse
            // outright unless it is still blank.
            //
            // Without this guard, formatting an already-formatted tag ORs the
            // factory CC into whatever is there. Identical bytes make that a
            // no-op, which is why it survives the common case — but a tag
            // carrying a foreign CC, or one whose chip we misidentified, gets a
            // size byte belonging to no chip (`0x12 | 0x06 = 0x16`, declaring
            // 176 B of a 144-byte tag) and there is no second attempt. The
            // DEBUG `formatVirginCC` op has always had this check; the shipping
            // path, which is the one users actually reach, did not.
            let existingCC = try await tag.readMemory(range: 12 ..< 16)
            if Type2CC.isFormatted(existingCC) {
                // Already formatted. Two very different cases hide here, and
                // the old code treated both as "just write it again":
                //
                // • Identical bytes — the overwhelmingly common one, since most
                //   NTAG21x ship pre-formatted. ORing identical bits changes
                //   nothing, so skip the write entirely rather than spend the
                //   tag's one OTP shot re-asserting what is already true.
                // • Different bytes — a foreign CC, or a chip we misidentified.
                //   Here the OR genuinely corrupts: `0x12 | 0x06 = 0x16`
                //   declares 176 B of a 144-byte tag, and page 3 can never be
                //   corrected. Refuse.
                guard existingCC == cc else {
                    throw TagError.protocolError(
                        String(localized: "This tag already has a different Capability Container."),
                        diagnostics: "page 3 = \(existingCC.hexString), would OR \(cc.hexString) into it: "
                            + "OTP bits cannot be cleared, so this would corrupt the CC permanently"
                    )
                }
                return true
            }
            try await tag.writeMemory(at: 12, bytes: cc)
            // Read the OTP page back. This is the one write in the app that can
            // never be retried or corrected, so an ACK alone is not proof.
            let writtenCC = try await tag.readMemory(range: 12 ..< 16)
            guard writtenCC == cc else {
                throw TagError.verificationFailed(
                    diff: writtenCC,
                    diagnostics: "CC read-back mismatch: wrote \(cc.hexString), page 3 now reads \(writtenCC.hexString)"
                )
            }
            return false

        case .type5:
            // Type-5 keeps its CC in block 0 and, unlike Type-2, blocks stay
            // rewritable until explicitly locked — so this is recoverable. This
            // is the path a factory ICODE SLIX2 needs: it ships with no CC, and
            // without one CoreNFC refuses every content NDEF write against it.
            guard let cc = tag.chip?.factoryType5CC else {
                throw TagError.capabilityUnsupported(
                    .formatCC,
                    diagnostics: "Type-5 CC needs known block geometry; profile reports "
                        + "\(tag.chip?.memoryLayout.pageCount ?? 0) × \(tag.chip?.memoryLayout.pageSize ?? 0) B"
                )
            }
            try tag.require(.rawTransceive)
            try await Type5Formatter(transceive: { try await tag.transceive($0) }).format(cc: cc)
            // Type-5 blocks are rewritable, so the formatter always writes.
            return false

        default:
            throw TagError.capabilityUnsupported(
                .formatCC,
                diagnostics: "CC format unsupported on chip family \(tag.chip?.family.shortName ?? "unknown")"
            )
        }
    }
}
