import Foundation
@testable import HexNFCKit

/// EM Microelectronic Type-2 simulators (V10 / V11 / V16).
///
/// ## Sourcing caveat
///
/// The byte-level command-frame details for the em|echo-V (EM4425)
/// derivatives V10/V11/V16 are **not publicly documented** — only the
/// short-form 4425-DS-02 datasheet is available, and it omits the
/// proprietary opcode tables. The closest publicly-documented analog is
/// **EM4423** (datasheet 4423-DS-02), but EM4423 has no V suffix and a
/// different feature set (single-die NFC + EPC Gen2, not dual-frequency
/// NFC + RAIN).
///
/// Where this file commits to specific bytes — the "PVM" identifier
/// concept at page 0 bytes 0–1, the per-variant tamper page locations,
/// the V10 `0x1A` "Activate HF crypto mode" canned ACK — those are
/// **simulator-defined fixtures**, not datasheet-derived. They exist so
/// the catalog presets in `CommandPresetCatalog.emMicroelectronic` round-
/// trip deterministically through the test suite; they are **not**
/// claims about how real silicon behaves. When EM publishes a long-form
/// datasheet or we sign an NDA, replace these with the authoritative
/// values.
///
/// Specifically per EM4423's published command set (page 33): real EM
/// chips do support READ (0x30), WRITE (0xA2), SECTOR_SELECT (0xC2), and
/// a proprietary LOGIN (0x1B) — but **not** GET_VERSION (0x60). The
/// simulator inherits the base NTAG21x dispatcher and so accepts 0x60;
/// real EM hardware would NAK it. Treat that as a known fidelity gap.
///
/// ## Modeled chip surface
///
/// EM chips are flat 16-page Type-2 tags — no password slots, no NTAG-
/// style dynamic lock byte. The base-class `.permanentLock` and
/// `.passwordAuth` guards already fire `.capabilityUnsupported` for any
/// route the EM profile doesn't advertise.
///
/// Variant fixtures:
///
///   - **V10** (PVM `0xE0 0x10`): tamper status at page `0x08`. The V10
///     subclass also intercepts opcode `0x1A` with a canned ACK,
///     emulating EM's "Activate HF crypto mode" without modeling the
///     underlying cipher.
///   - **V11** (PVM `0xE0 0x11`): tamper status at page `0x09`.
///   - **V16** (PVM `0xE0 0x16`): tamper status at page `0x0A`.
public class EmType2Simulator: NTAG21xSimulator, @unchecked Sendable {
    /// Page index that holds the 1-byte tamper status (variant-specific).
    public var tamperPage: Int {
        0
    }

    /// Vendor magic bytes that identify the chip via page-0 read. Written
    /// into pages[0][0..1] during init by `seedEmPagesAndTamper`.
    public var pvm: (UInt8, UInt8) {
        (0xE0, 0x00)
    }

    /// Test-mutable: write a new tamper byte at `tamperPage`. Use this to
    /// flip the simulated chip into a "loop broken" state during a test.
    public func writeTamperStatus(_ byte: UInt8) {
        guard tamperPage < pages.count else { return }
        var page = pages[tamperPage]
        page[page.startIndex + 0] = byte
        pages[tamperPage] = page
        // pages is private(set) — assignment through the same property
        // works because we're inside the base class's module.
    }

    /// Read the live tamper byte. Returns nil if `tamperPage` is out of
    /// bounds for this variant.
    public func tamperStatus() -> UInt8? {
        guard tamperPage < pages.count else { return nil }
        return pages[tamperPage][pages[tamperPage].startIndex]
    }

    /// Called after `super.init` to install the PVM at page 0 and seed the
    /// tamper page with `0x55` (closed loop). Implemented as a separate
    /// method so subclasses can call it after their own super.init() chain
    /// completes — Swift does not allow overriding properties before
    /// `super.init` returns.
    func seedEmPagesAndTamper() {
        // Page 0 byte 0/1 = PVM. Real EM tags also keep UID-derived bytes
        // in the rest of page 0, but the kit's identification only looks
        // at the first two bytes — so we leave the rest as init produced
        // (UID + BCC from `makeInitialPages`).
        var page0 = pages[0]
        page0[page0.startIndex + 0] = pvm.0
        page0[page0.startIndex + 1] = pvm.1
        pages[0] = page0
        // Tamper status default: closed loop.
        writeTamperStatus(0x55)
    }
}

/// EM V10 — adds vendor opcode `0x1A` (Activate HF crypto mode).
public final class EmV10Simulator: EmType2Simulator, @unchecked Sendable {
    override public var tamperPage: Int {
        0x08
    }

    override public var pvm: (UInt8, UInt8) {
        (0xE0, 0x10)
    }

    public init(uid: Data = EmV10Simulator.defaultUID, ndefMessage: Data? = nil) {
        super.init(
            variant: .emV10,
            profile: ChipCatalog.require(.emV10),
            uid: uid,
            ndefMessage: ndefMessage,
            signature: Data(repeating: 0x10, count: 32)
        )
        seedEmPagesAndTamper()
    }

    override public func versionBlock() -> Data {
        // EM chips don't support GET_VERSION — return zeros.
        Data(repeating: 0x00, count: 8)
    }

    override public func handle(command: Data) -> Data {
        // V10 vendor-specific: 0x1A "Activate HF crypto mode" — canned ACK.
        if command.first == 0x1A {
            return Data([0x0A])
        }
        return super.handle(command: command)
    }

    public static let defaultUID: Data = .init([0xE0, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10])
}

/// EM V11 — tamper status lives one page higher than V10. Otherwise same
/// command surface.
public final class EmV11Simulator: EmType2Simulator, @unchecked Sendable {
    override public var tamperPage: Int {
        0x09
    }

    override public var pvm: (UInt8, UInt8) {
        (0xE0, 0x11)
    }

    public init(uid: Data = EmV11Simulator.defaultUID, ndefMessage: Data? = nil) {
        super.init(
            variant: .emV11,
            profile: ChipCatalog.require(.emV11),
            uid: uid,
            ndefMessage: ndefMessage,
            signature: Data(repeating: 0x11, count: 32)
        )
        seedEmPagesAndTamper()
    }

    override public func versionBlock() -> Data {
        Data(repeating: 0x00, count: 8)
    }

    public static let defaultUID: Data = .init([0xE0, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11])
}

/// EM V16 — tamper status at page `0x0A`.
public final class EmV16Simulator: EmType2Simulator, @unchecked Sendable {
    override public var tamperPage: Int {
        0x0A
    }

    override public var pvm: (UInt8, UInt8) {
        (0xE0, 0x16)
    }

    public init(uid: Data = EmV16Simulator.defaultUID, ndefMessage: Data? = nil) {
        super.init(
            variant: .emV16,
            profile: ChipCatalog.require(.emV16),
            uid: uid,
            ndefMessage: ndefMessage,
            signature: Data(repeating: 0x16, count: 32)
        )
        seedEmPagesAndTamper()
    }

    override public func versionBlock() -> Data {
        Data(repeating: 0x00, count: 8)
    }

    public static let defaultUID: Data = .init([0xE0, 0x16, 0x16, 0x16, 0x16, 0x16, 0x16])
}
