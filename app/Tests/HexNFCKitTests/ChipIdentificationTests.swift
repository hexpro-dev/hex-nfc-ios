@testable import HexNFCKit
@testable import HexNFCRecords
@testable import HexNFCTagSim
import XCTest

/// Covers the chip-identification layer: that `ChipCatalog`'s GET_VERSION
/// decoder agrees with the chip simulators (the protocol-level source of
/// truth), and that the generic fallback profiles used by the production
/// identifiers (`Identification/`) are well-formed.
///
/// The CoreNFC-facing identifiers themselves are `#if os(iOS)` and exercised on
/// device / simulator builds; this suite pins the pure, host-testable parts.
final class ChipIdentificationTests: XCTestCase {
    // MARK: GET_VERSION decode ↔ simulator agreement

    func testGetVersionDecodesNTAG213() {
        let block = NTAG213Simulator().versionBlock()
        XCTAssertEqual(ChipCatalog.identify(getVersion: block)?.id, .ntag213)
    }

    func testGetVersionDecodesNTAG216() {
        let block = NTAG216Simulator().versionBlock()
        XCTAssertEqual(ChipCatalog.identify(getVersion: block)?.id, .ntag216)
    }

    func testGetVersionDecodesUltralightEV1_48() {
        let block = MifareUltralightEV1_48Simulator().versionBlock()
        XCTAssertEqual(ChipCatalog.identify(getVersion: block)?.id, .mifareUltralightEV1_48)
    }

    func testGetVersionDecodesNTAG210Micro() {
        let block = NTAG210MicroSimulator().versionBlock()
        XCTAssertEqual(block, Data([0x00, 0x04, 0x04, 0x02, 0x02, 0x00, 0x0B, 0x03]),
                       "simulator must reproduce the block captured from real NT2H1001 silicon")
        XCTAssertEqual(ChipCatalog.identify(getVersion: block)?.id, .ntag210Micro)
    }

    /// The 17 pF sibling die (NT2L1001) differs only in the capacitance byte and
    /// is the same chip for our purposes.
    func testGetVersionDecodesNTAG210Micro17pF() {
        let block = Data([0x00, 0x04, 0x04, 0x01, 0x02, 0x00, 0x0B, 0x03])
        XCTAssertEqual(ChipCatalog.identify(getVersion: block)?.id, .ntag210Micro)
    }

    // MARK: Mis-keying regression guards

    //
    // `identify(getVersion:)` used to switch on `(subType, storageSize)` alone,
    // discarding `productType` and never reading the major-version byte. Each of
    // these blocks was decoded as a confidently *wrong* chip. They must now come
    // back `nil` — an honest "unidentified" that the fallback card explains —
    // rather than silently mis-driving another chip's page map.

    /// NTAG210 differs from MIFARE Ultralight EV1 48 only in `productType`
    /// (04h NTAG vs 03h Ultralight). It used to report as the Ultralight.
    func testGetVersionDoesNotMistakeNTAG210ForUltralightEV1() {
        let ntag210 = Data([0x00, 0x04, 0x04, 0x01, 0x01, 0x00, 0x0B, 0x03])
        XCTAssertNotEqual(ChipCatalog.identify(getVersion: ntag210)?.id, .mifareUltralightEV1_48)
        XCTAssertNil(ChipCatalog.identify(getVersion: ntag210))
    }

    /// Same collision one size up: NTAG212 vs MIFARE Ultralight EV1 128.
    func testGetVersionDoesNotMistakeNTAG212ForUltralightEV1() {
        let ntag212 = Data([0x00, 0x04, 0x04, 0x01, 0x01, 0x00, 0x0E, 0x03])
        XCTAssertNotEqual(ChipCatalog.identify(getVersion: ntag212)?.id, .mifareUltralightEV1_128)
        XCTAssertNil(ChipCatalog.identify(getVersion: ntag212))
    }

    /// Subtype 04h means "50 pF + field-detect pin" (NTAG213F/216F), not
    /// "NTAG424 DNA". A blanket `(0x04, _)` rule reported the F variants — plain
    /// Type-2 chips — as a Type-4 chip with an entirely different command set.
    func testGetVersionDoesNotMistakeNTAG213FForNTAG424() {
        let ntag213F = Data([0x00, 0x04, 0x04, 0x04, 0x01, 0x00, 0x0F, 0x03])
        XCTAssertNotEqual(ChipCatalog.identify(getVersion: ntag213F)?.id, .ntag424DNA)
        XCTAssertNil(ChipCatalog.identify(getVersion: ntag213F))

        let ntag216F = Data([0x00, 0x04, 0x04, 0x04, 0x01, 0x00, 0x13, 0x03])
        XCTAssertNotEqual(ChipCatalog.identify(getVersion: ntag216F)?.id, .ntag424DNA)
        XCTAssertNil(ChipCatalog.identify(getVersion: ntag216F))
    }

    /// Removing that catch-all must not cost us NTAG424 identification, which
    /// legitimately arrives via the wrapped-APDU path. A real 424 rejects the
    /// bare `60h` with `67 00`, too short for the decoder to consider at all.
    func testNTAG424StillIdentifiesViaWrappedPathAfterRekeying() {
        let response = NTAG424DNASimulator().handle(command: Data([0x90, 0x60, 0x00, 0x00, 0x00]))
        XCTAssertEqual(ChipCatalog.identify(type4Version: response)?.id, .ntag424DNA)
        XCTAssertNil(ChipCatalog.identify(getVersion: Data([0x67, 0x00])))
    }

    // MARK: Unidentified-chip fallback decode

    /// The whole point of the fallback: a chip we can't name still reports
    /// something useful, rather than the user seeing a bare UID.
    func testDescribeDecodesAnUnrecognisedNTAG() throws {
        // NTAG213F — a real chip the catalog deliberately doesn't profile.
        let block = Data([0x00, 0x04, 0x04, 0x04, 0x01, 0x00, 0x0F, 0x03])
        XCTAssertNil(ChipCatalog.identify(getVersion: block), "precondition: unidentified")
        let report = try XCTUnwrap(ChipCatalog.describe(getVersion: block))
        XCTAssertEqual(report.vendor, "NXP")
        XCTAssertEqual(report.productType, "NTAG")
        XCTAssertEqual(report.version, "v1.0")
        XCTAssertEqual(report.versionBlock, block)
        XCTAssertNotNil(report.summary)
    }

    /// The storage byte's low bit is a *range* flag. Reporting the lower bound
    /// as the size is what makes a 48 B chip look like a 32 B one.
    func testDescribeStorageSizeHonoursTheRangeFlag() {
        // 0x0B -> n=5, low bit set -> "between 32 and 64".
        XCTAssertEqual(ChipCatalog.describeStorageSize(0x0B), "32-64 bytes")
        // 0x0E -> n=7, low bit clear -> exactly 128.
        XCTAssertEqual(ChipCatalog.describeStorageSize(0x0E), "128 bytes")
        // 0x10 -> n=8, low bit clear -> exactly 256.
        XCTAssertEqual(ChipCatalog.describeStorageSize(0x10), "256 bytes")
        XCTAssertNil(ChipCatalog.describeStorageSize(0x00), "implausible exponent")
    }

    func testDescribeReportsUnknownVendorAsRawHexRatherThanGuessing() throws {
        let block = Data([0x00, 0x99, 0x07, 0x01, 0x01, 0x00, 0x0B, 0x03])
        let report = try XCTUnwrap(ChipCatalog.describe(getVersion: block))
        XCTAssertEqual(report.vendor, "Vendor 99h")
        XCTAssertEqual(report.productType, "Product type 07h")
    }

    func testDescribeRejectsShortBlock() {
        XCTAssertNil(ChipCatalog.describe(getVersion: Data([0x00, 0x04])))
    }

    func testGetVersionRejectsShortBlock() {
        XCTAssertNil(ChipCatalog.identify(getVersion: Data([0x00, 0x04])))
    }

    func testGetVersionRejectsNonNXPVendor() {
        // Same shape as an NTAG213 block but vendor != 0x04.
        let block = Data([0x00, 0x05, 0x04, 0x02, 0x01, 0x00, 0x0F, 0x03])
        XCTAssertNil(ChipCatalog.identify(getVersion: block))
    }

    // MARK: Wrapped-APDU GET_VERSION (NTAG424 DNA, Type-4)

    func testType4VersionDecodesNTAG424DNA() {
        // Drive the simulator's wrapped GET_VERSION exactly as the kit would,
        // so the decoder stays pinned to the protocol-level source of truth.
        let response = NTAG424DNASimulator().handle(command: Data([0x90, 0x60, 0x00, 0x00, 0x00]))
        XCTAssertEqual(ChipCatalog.identify(type4Version: response)?.id, .ntag424DNA)
    }

    func testType4VersionDecodesRealChipFirstFrame() {
        // A real chip returns only the 7-byte HW frame + 91 AF ("more frames")
        // on the first response; identification must succeed off that alone.
        let firstFrame = Data([0x04, 0x04, 0x02, 0x30, 0x00, 0x11, 0x05, 0x91, 0xAF])
        XCTAssertEqual(ChipCatalog.identify(type4Version: firstFrame)?.id, .ntag424DNA)
    }

    func testType4VersionRejectsDESFire() {
        // DESFire's HW type is 0x01, not 0x04 (it also arrives via its own
        // family) — it must not be mistaken for an NTAG424 DNA.
        let desfire = Data([0x04, 0x01, 0x01, 0x33, 0x00, 0x18, 0x05, 0x91, 0xAF])
        XCTAssertNil(ChipCatalog.identify(type4Version: desfire))
    }

    func testType4VersionRejectsRawRejectStatus() {
        // The bare-0x60 rejection (ISO 7816 "wrong length") that triggers the
        // wrapped-APDU fallback in the first place must not decode to anything.
        XCTAssertNil(ChipCatalog.identify(type4Version: Data([0x67, 0x00])))
    }

    func testType4VersionRejectsNonNXPVendor() {
        let block = Data([0x05, 0x04, 0x02, 0x30, 0x00, 0x11, 0x05, 0x91, 0x00])
        XCTAssertNil(ChipCatalog.identify(type4Version: block))
    }

    func testNTAG424ReportsFullUserMemory() {
        // NT4H2421Gx datasheet: 416 B user memory = CC(32) + NDEF(256) +
        // proprietary(128). The scan card must report the full figure, not the
        // 256 B NDEF file alone.
        let profile = ChipCatalog.profile(for: .ntag424DNA)
        XCTAssertEqual(profile?.memoryLayout.byteCount, 416)
        XCTAssertEqual(32 + 256 + 128, profile?.memoryLayout.byteCount)
    }

    // MARK: Memory reporting — usable NDEF capacity vs total, per chip

    /// Pins the (usable NDEF, total addressable) byte pair that drives the scan
    /// card's "X Bytes (YB Total)" line for every catalogued chip, so neither
    /// figure can silently drift from the datasheet.
    func testMemoryFiguresAcrossChips() {
        // chip → (usable NDEF bytes, total addressable bytes)
        let expected: [ChipID: (ndef: Int, total: Int)] = [
            // 12 user pages (04h–0Fh) of 16 total. The storage byte 0Bh reads as
            // "between 32 and 64 B" — decoding it as a bare 2^n would report 32.
            .ntag210Micro: (48, 64),
            .ntag213: (144, 180),
            .ntag213TT: (144, 180),
            .ntag215: (504, 540),
            .ntag216: (888, 924),
            .mifareUltralightEV1_48: (48, 80),
            .mifareUltralightEV1_128: (128, 164),
            .ntag424DNA: (256, 416),
            // 112 B of memory but 104 B writable: the CC occupies block 0, and
            // MLEN counts the T5T area in whole 8-byte units — (112 − 4) / 8 =
            // 13 → 104. Reporting the full 112 overstated what would fit.
            .icodeSlix: (104, 112),
            .emV10: (48, 64),
            .emV11: (48, 64),
            .emV16: (48, 64),
        ]
        for (id, figures) in expected {
            let profile = ChipCatalog.profile(for: id)
            XCTAssertEqual(profile?.ndefByteCapacity, figures.ndef, "NDEF capacity for \(id)")
            XCTAssertEqual(profile?.memoryLayout.byteCount, figures.total, "total bytes for \(id)")
        }
    }

    func testNDEFCapacityZeroForKeyLockedFamilies() {
        // DESFire data is key-locked and ISO 15693/FeliCa generics expose no
        // blind-readable NDEF area — the card shows the total alone, no "(… Total)".
        XCTAssertEqual(ChipCatalog.profile(for: .genericMifareDESFire)?.ndefByteCapacity, 0)
        XCTAssertEqual(ChipCatalog.profile(for: .genericIso15693)?.ndefByteCapacity, 0)
        XCTAssertEqual(ChipCatalog.profile(for: .genericFeliCa)?.ndefByteCapacity, 0)
    }

    // MARK: ISO 15693 Get System Information → profile

    func testISO15693UsesSelfReportedMemoryForNXP() {
        // An NXP ICODE that self-reports 28 × 4-byte blocks resolves to the
        // ICODE profile with its real (here datasheet-matching) memory.
        let info = ISO15693SystemInfo(blockSize: 4, blockCount: 28, icReference: 0x01)
        let profile = ChipCatalog.iso15693Profile(icManufacturerCode: 0x04, systemInfo: info)
        XCTAssertEqual(profile.id, .icodeSlix)
        XCTAssertEqual(profile.manufacturer, "NXP")
        XCTAssertEqual(profile.memoryLayout.byteCount, 112)
    }

    func testISO15693SelfReportedMemoryOverridesDatasheetEstimate() {
        // A larger ICODE self-reporting 79 blocks must show its real memory,
        // not the 112-byte SLIX datasheet fallback.
        let info = ISO15693SystemInfo(blockSize: 4, blockCount: 79, icReference: 0x01)
        let profile = ChipCatalog.iso15693Profile(icManufacturerCode: 0x04, systemInfo: info)
        XCTAssertEqual(profile.memoryLayout.byteCount, 316)
        // NDEF capacity is NOT the whole user area: block 0 holds the CC, so
        // the writable area is 316 − 4 = 312 B, which is exactly what the CC
        // this app writes declares (MLEN 39 × 8).
        XCTAssertEqual(profile.ndefByteCapacity, 312)
    }

    /// The SLIX2 loses a second block to the 16-bit counter at block 79, which
    /// "cannot be used to store user data" (SL2S2602 §8.1.1) and cannot be
    /// locked (§9.5.2.3). 320 B of memory, 312 B writable — the raw block span
    /// would have claimed all 320.
    func testSLIX2NDEFCapacityExcludesTheCCAndCounterBlocks() {
        let info = ISO15693SystemInfo(blockSize: 4, blockCount: 80, icReference: 0x01)
        let profile = ChipCatalog.iso15693Profile(icManufacturerCode: 0x04, systemInfo: info)
        XCTAssertEqual(profile.id, .icodeSlix2)
        XCTAssertEqual(profile.memoryLayout.byteCount, 320)
        XCTAssertEqual(profile.ndefByteCapacity, 312)
        XCTAssertLessThan(
            profile.ndefByteCapacity, profile.memoryLayout.byteCount,
            "writable NDEF area must never equal total memory on a Type-5 tag"
        )
    }

    /// 80 blocks is unambiguously SLIX2 — nothing else in the ICODE line carries
    /// 2560-bit user memory. Block geometry is the *only* discriminator that
    /// held up: the IC reference reads `0x01` on both SLIX and SLIX2, and so
    /// does UID byte 2 (live-verified 2026-08-07).
    func testISO15693IdentifiesSLIX2By80BlockGeometry() {
        let info = ISO15693SystemInfo(blockSize: 4, blockCount: 80, icReference: 0x01)
        let profile = ChipCatalog.iso15693Profile(icManufacturerCode: 0x04, systemInfo: info)
        XCTAssertEqual(profile.id, .icodeSlix2)
        XCTAssertEqual(profile.family, .type5(.icodeSlix2))
        XCTAssertEqual(profile.displayName, "ICODE SLIX2")
        XCTAssertEqual(profile.memoryLayout.byteCount, 320)
    }

    /// The IC reference must not sway the answer either way, since it is the
    /// discriminator three code comments used to propose and it does not work.
    func testISO15693ICReferenceIsNotADiscriminator() {
        for icRef: UInt8 in [0x00, 0x01, 0x02, 0xFF] {
            let slix = ChipCatalog.iso15693Profile(
                icManufacturerCode: 0x04,
                systemInfo: ISO15693SystemInfo(blockSize: 4, blockCount: 28, icReference: icRef)
            )
            XCTAssertEqual(slix.id, .icodeSlix, "icRef \(icRef) changed the 28-block answer")
            let slix2 = ChipCatalog.iso15693Profile(
                icManufacturerCode: 0x04,
                systemInfo: ISO15693SystemInfo(blockSize: 4, blockCount: 80, icReference: icRef)
            )
            XCTAssertEqual(slix2.id, .icodeSlix2, "icRef \(icRef) changed the 80-block answer")
        }
    }

    /// Emitting a new Type-5 variant without widening `backendStyle` silently
    /// removes the protection affordance from the chips that support it best.
    /// This is the guard on those two edits staying together.
    func testSLIX2KeepsAProtectionBackend() {
        let profile = ChipCatalog.iso15693Profile(
            icManufacturerCode: 0x04,
            systemInfo: ISO15693SystemInfo(blockSize: 4, blockCount: 80, icReference: 0x01)
        )
        let style = ProtectionStyle.backendStyle(for: profile.family, capabilities: profile.capabilities)
        guard case .type5? = style else {
            return XCTFail("SLIX2 lost its protection backend, got \(String(describing: style))")
        }
    }

    /// A non-NXP 80-block Type-5 tag is not an ICODE SLIX2.
    func testISO15693NonNXP80BlocksStaysGeneric() {
        let info = ISO15693SystemInfo(blockSize: 4, blockCount: 80, icReference: 0x01)
        let profile = ChipCatalog.iso15693Profile(icManufacturerCode: 0x02, systemInfo: info)
        XCTAssertEqual(profile.id, .genericIso15693)
    }

    func testISO15693FallsBackToDatasheetWhenMemoryAbsent() {
        // A weak read omits the memory-size field — CoreNFC returns -1, which
        // maps to nil. The NXP profile then keeps its datasheet 112-byte estimate.
        let info = ISO15693SystemInfo(coreNFCBlockSize: -1, blockCount: -1, icReference: -1)
        XCTAssertNil(info.memoryBytes)
        XCTAssertNil(info.icReference)
        let profile = ChipCatalog.iso15693Profile(icManufacturerCode: 0x04, systemInfo: info)
        XCTAssertEqual(profile.id, .icodeSlix)
        XCTAssertEqual(profile.memoryLayout.byteCount, 112, "datasheet fallback")
    }

    func testISO15693FallsBackWhenNoSystemInfoAtAll() {
        // The whole probe can fail (nil). An NXP tag still resolves to the ICODE
        // profile rather than a bare "ISO 15693" / "Unknown".
        let profile = ChipCatalog.iso15693Profile(icManufacturerCode: 0x04, systemInfo: nil)
        XCTAssertEqual(profile.id, .icodeSlix)
        XCTAssertEqual(profile.memoryLayout.byteCount, 112)
    }

    func testISO15693PartialFrameDoesNotComputeBogusMemory() {
        // info-flags advertised memory but the frame truncated mid-field:
        // CoreNFC gives blockSize but -1 blockCount. memoryBytes must be nil so
        // we don't multiply by a missing dimension — fall back to the datasheet.
        let info = ISO15693SystemInfo(coreNFCBlockSize: 4, blockCount: -1, icReference: 0x01)
        XCTAssertNil(info.memoryBytes)
        XCTAssertEqual(info.icReference, 0x01, "IC reference still captured for the log")
        let profile = ChipCatalog.iso15693Profile(icManufacturerCode: 0x04, systemInfo: info)
        XCTAssertEqual(profile.memoryLayout.byteCount, 112, "datasheet fallback on truncated frame")
    }

    func testISO15693NonNXPIsGenericWithSelfReportedMemory() {
        // ST / EM Type-5 silicon (mfr ≠ 0x04) → generic ISO 15693 profile, but
        // still honours the self-reported geometry when the read carried it.
        let info = ISO15693SystemInfo(blockSize: 4, blockCount: 64, icReference: 0x2C)
        let profile = ChipCatalog.iso15693Profile(icManufacturerCode: 0x02, systemInfo: info)
        XCTAssertEqual(profile.id, .genericIso15693)
        XCTAssertEqual(profile.memoryLayout.byteCount, 256)
    }

    func testISO15693NonNXPWithNoInfoStaysBareGeneric() {
        // Non-NXP with no readable system info keeps the conservative generic
        // profile (pageCount 0 → the scan card shows no bogus memory figure).
        let profile = ChipCatalog.iso15693Profile(icManufacturerCode: 0x02, systemInfo: nil)
        XCTAssertEqual(profile.id, .genericIso15693)
        XCTAssertEqual(profile.memoryLayout.byteCount, 0)
    }

    // MARK: Generic fallback profiles

    func testDESFireProfileNamesTheChip() {
        let profile = ChipCatalog.profile(for: .genericMifareDESFire)
        XCTAssertNotNil(profile)
        XCTAssertEqual(profile?.displayName, "MIFARE DESFire")
        XCTAssertEqual(profile?.family.shortName, "MIFARE DESFire")
        // DESFire data is key-locked; only raw transceive is advertised.
        XCTAssertEqual(profile?.capabilities, [.rawTransceive])
    }

    func testGenericISO15693ProfileExists() {
        let profile = ChipCatalog.profile(for: .genericIso15693)
        XCTAssertEqual(profile?.family.shortName, "ISO 15693")
    }

    func testGenericFeliCaProfileExists() {
        let profile = ChipCatalog.profile(for: .genericFeliCa)
        XCTAssertEqual(profile?.family.shortName, "FeliCa")
    }
}
