import Foundation

/// The NFC Forum Type 5 (ISO 15693) Capability Container and NDEF envelope.
///
/// Type-5 is block-addressed and keeps its CC in **block 0**, not in a Type-2
/// style OTP page — which means, unlike `Type2NDEF`, formatting here is
/// *reversible*: block 0 can be rewritten until it is explicitly `LOCK_BLOCK`ed.
///
/// This matters because a factory ICODE SLIX2 ships with **no CC at all** (every
/// block zero). CoreNFC reports such a tag as "Tag Not NDEF formatted", so a
/// content `writeNDEF` fails against it — the app could read and erase a virgin
/// SLIX2 but never write one, and there was no Type-5 formatter to fix that.
/// (The chip simulator seeded a valid CC at construction, so no test could see
/// it.) `Type5CC.bytes` is now the single source of that layout, shared by the
/// app's format operation, the harness plan and the simulator.
///
/// Reference: NFC Forum Type 5 Tag Operation Specification 1.0 §4.2.
public enum Type5CC {
    /// Magic byte for the 4-byte CC form (total memory ≤ 2040 bytes). Larger
    /// tags use `0xE2` with an 8-byte CC, which no supported chip needs.
    public static let magic: UInt8 = 0xE1
    /// Version + access: major 1, minor 0, read always, write always.
    public static let versionAccess: UInt8 = 0x40
    /// Feature flags: bit 0 = READ_MULTIPLE_BLOCKS supported,
    /// bit 3 = LOCK_BLOCK supported. Both true on ICODE SLIX/SLIX2.
    public static let featureFlags: UInt8 = 0x09

    /// Largest total memory the 4-byte CC form can describe.
    public static let fourByteFormLimit = 2040

    /// An empty NDEF TLV plus terminator, seeded into block 1 when the tag
    /// carries no message, so a freshly formatted tag reports as "Type 5 NDEF,
    /// no message" rather than malformed.
    public static let emptyNDEFTLV = Data([0x03, 0x00, 0xFE, 0x00])

    /// Build the 4-byte CC for a tag of `blockCount` × `blockSize` bytes.
    ///
    /// `MLEN` (byte 2) counts the T5T area — the memory **after** the CC block —
    /// in units of 8 bytes, rounded down. For a 28-block × 4-byte ICODE SLIX
    /// that is `(112 − 4) / 8 = 13`, addressing 104 of the 108 available bytes.
    ///
    /// Returns `nil` when the geometry is unknown (`blockCount == 0`, i.e. a
    /// generic profile whose size the tag hasn't self-reported yet) or too large
    /// for the 4-byte form.
    public static func bytes(blockCount: Int, blockSize: Int) -> Data? {
        guard blockCount > 1, blockSize > 0 else { return nil }
        let totalBytes = blockCount * blockSize
        guard totalBytes <= fourByteFormLimit else { return nil }
        let areaBytes = totalBytes - 4 // everything after the CC block
        let mlen = areaBytes / 8
        guard mlen > 0, mlen <= 0xFF else { return nil }
        return Data([magic, versionAccess, UInt8(mlen), featureFlags])
    }

    /// Whether `block0` already carries a Type-5 CC (as opposed to a virgin,
    /// all-zero factory block).
    public static func isFormatted(_ block0: Data) -> Bool {
        block0.first == magic || block0.first == 0xE2
    }

    /// Whether the first block of the T5T area is still blank, meaning nothing
    /// there can be anybody's data.
    ///
    /// A factory Type-5 tag reads all-zero, and `0x00` is the NULL TLV: a reader
    /// skips NULLs, walks to the end of memory, meets no message and no
    /// terminator, and reports the tag as malformed. That is the one state the
    /// seeded empty TLV exists to fix. Any other first byte is a TLV somebody
    /// wrote (NDEF `03`, Lock Control `01`, Memory Control `02`, Proprietary
    /// `FD`, Terminator `FE`) or bytes this app cannot account for, and neither
    /// is a formatter's to overwrite. A short or empty read is not blank either,
    /// because a read that did not happen is not evidence about the tag.
    public static func isBlankMessageArea(_ block: Data) -> Bool {
        !block.isEmpty && block.allSatisfy { $0 == 0x00 }
    }
}

public extension ChipProfile {
    /// Factory Type-5 Capability Container for this chip, derived from its block
    /// geometry. `nil` for non-Type-5 families and for a profile whose geometry
    /// is still unknown.
    ///
    /// The Type-5 sibling of `factoryCC`, and single source of truth for the
    /// app's `format` operation, `HexNFCTestKit`'s Type-5 plan, and
    /// `Iso15693Simulator`'s seeded block 0.
    var factoryType5CC: Data? {
        guard case .type5 = family else { return nil }
        return Type5CC.bytes(blockCount: memoryLayout.pageCount, blockSize: memoryLayout.pageSize)
    }
}

/// Writes the Type-5 CC, plus an empty NDEF TLV where the tag has no message
/// yet, over a `transceive` closure, so the same code drives a real tag
/// (`CoreNFCConnectedTag.transceive`) and the
/// simulator (`SimulatedConnectedTag.transceive`) — the pattern
/// `Iso15693ProtectionClient` already uses.
public struct Type5Formatter {
    public typealias Transceive = @Sendable (RawCommand) async throws -> Data

    public let transceive: Transceive

    public init(transceive: @escaping Transceive) {
        self.transceive = transceive
    }

    /// ISO 15693 "high data rate, no addressing" — matches every preset and the
    /// protection client.
    static let flag: UInt8 = 0x02

    /// Write the Capability Container to block 0, leaving the tag NDEF-formatted,
    /// and seed an empty NDEF TLV into block 1 only when nothing is there yet.
    ///
    /// The seed used to be unconditional, and that made Format on a Type-5 tag
    /// quietly do Erase's job: `03 00 FE 00` over block 1 ends the message the
    /// user had on the tag. Found 2026-09-22, with the Format screen promising
    /// the data area went untouched, which is exactly what the Type-2 path does.
    /// The screen is opened before a tag is tapped and has no idea which family
    /// it is about to talk to, so one behaviour across both families is the only
    /// way anything it says can be true, and clearing records already has its
    /// own operation.
    ///
    /// Blocks are rewritable, so this is reversible: a caller that captured
    /// block 0 beforehand can restore it (which is what the harness step does).
    public func format(cc: Data) async throws {
        guard cc.count == 4 else {
            throw TagError.protocolError("Type-5 CC must be 4 bytes", diagnostics: "len=\(cc.count)")
        }
        // Read before anything is written, so a tag that drops out at this point
        // is left exactly as it was found.
        let messageArea = try await readBlock(1)
        try await writeBlock(0, cc)
        if Type5CC.isBlankMessageArea(messageArea) {
            try await writeBlock(1, Type5CC.emptyNDEFTLV)
        }
    }

    /// Read block 0: the CC, or all-zero on a virgin tag.
    public func readCapabilityContainer() async throws -> Data {
        try await readBlock(0)
    }

    private func readBlock(_ block: UInt8) async throws -> Data {
        let response = try await transceive(
            RawCommand(bytes: Data([Self.flag, Iso15693Opcode.readSingleBlock, block]),
                       name: "READ_SINGLE_BLOCK b\(block)", family: .type5(.icodeSlix))
        )
        guard response.first == 0x00, response.count >= 5 else {
            throw TagError.malformedResponse(response, diagnostics: "READ block \(block) resp=\(response.hexString)")
        }
        return response.subdata(in: (response.startIndex + 1) ..< (response.startIndex + 5))
    }

    private func writeBlock(_ block: UInt8, _ bytes: Data) async throws {
        let response = try await transceive(
            RawCommand(bytes: Data([Self.flag, Iso15693Opcode.writeSingleBlock, block]) + bytes,
                       name: "WRITE_SINGLE_BLOCK b\(block)", family: .type5(.icodeSlix))
        )
        guard response.first == 0x00 else {
            throw TagError.protocolError(
                "WRITE_SINGLE_BLOCK failed",
                diagnostics: "block=\(block) bytes=\(bytes.hexString) resp=\(response.hexString)"
            )
        }
    }
}
