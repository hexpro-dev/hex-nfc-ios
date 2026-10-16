import Foundation
@testable import HexNFCKit
@testable import HexNFCRecords

/// Reusable Type-2 / NTAG21x simulator core. Sub-classed by NTAG213/215/216
/// to fix the variant and the GET_VERSION block — every variant shares the
/// same command set otherwise.
///
/// Reference: NXP NTAG213/215/216 datasheet (NXP DS NTAG21x rev 3.2).
/// The relevant commands for our purposes are:
///
///   - `0x30 <page>`         READ        — 16 bytes (4 pages)
///   - `0x3A <start> <end>`  FAST_READ   — (end-start+1)*4 bytes
///   - `0xA2 <page> <4B>`    WRITE       — ACK / NAK
///   - `0x60`                GET_VERSION — 8-byte version block
///   - `0x3C <0x00>`         READ_SIG    — 32-byte signature
///   - `0x39 <0x02>`         READ_CNT    — 3-byte NFC counter
///   - `0x1B <4B>`           PWD_AUTH    — 2-byte PACK or NAK
///
/// Lock bytes:
///   - Static lock (page 2 bytes 2–3) protect pages 3–15.
///   - Dynamic lock (last config page before PWD) protects pages 16 → end.
///
/// Password authentication:
///   - PWD lives at `pwdPage`; PACK at `packPage`.
///   - `AUTH0` (config page 0, byte 3) is the first page protected — pages
///     ≥ AUTH0 require `PWD_AUTH`. Default `0xFF` = no protection.
///   - `ACCESS` (config page 1, byte 0): bit 7 = PROT (1 = read+write protected,
///     0 = write only), bits 2–0 = AUTH_LIM (negative attempts counter,
///     0 = unlimited).
open class NTAG21xSimulator: ChipSimulator, @unchecked Sendable {
    public let uid: Data
    public let profile: ChipProfile?
    public let variant: Type2Variant

    /// Page-major memory. Each entry is exactly 4 bytes. Settable within
    /// the module so subclasses (e.g. EM) can seed variant-specific PVM /
    /// tamper bytes after super.init returns.
    public internal(set) var pages: [Data]
    public private(set) var isAuthenticated: Bool = false
    public private(set) var failedAuthAttempts: Int = 0
    public private(set) var isLockedPermanent: Bool = false
    /// AUTH_LIM exhaustion state — distinct from `isLockedPermanent` (a lock-byte
    /// brick). Per NXP NTAG21x §8.8.2 / UL EV1 §8.6.2, exhausting the negative-auth
    /// limit (one past `AUTH_LIM`, as NTAG213 silicon showed) permanently
    /// disables *authentication* (every later PWD_AUTH fails,
    /// even with the correct password) but does NOT freeze memory cells: write-only
    /// protected pages stay readable and sub-AUTH0 pages stay writable.
    public private(set) var isAuthLocked: Bool = false
    public private(set) var signature: Data

    /// State of the originality-signature memory on chips that expose
    /// `WRITE_SIG` (`A9h`) / `LOCK_SIG` (`ACh`) — the NTAG 210µ and MIFARE
    /// Ultralight Nano. **The factory state is `.locked`, not `.unlocked`**
    /// (NT2L1001_NT2H1001 rev 3.0 §9.6: "This signature is locked in the
    /// dedicated memory"), so an out-of-the-box tag NAKs `WRITE_SIG` until an
    /// explicit `AC 00` unlock.
    public enum SignatureLockState: Sendable {
        case unlocked
        case locked
        case permanentlyLocked
    }

    public private(set) var signatureLock: SignatureLockState = .locked

    /// `true` for chips carrying the customisable-signature command pair. Every
    /// other Type-2 chip in the catalog NAKs both opcodes.
    var supportsSignatureLock: Bool {
        switch variant {
        case .ntag210Micro: true
        default: false
        }
    }

    /// 24-bit NFC counters. NTAG21x has one (auto-incrementing on read);
    /// MIFARE Ultralight EV1 has three (manually incremented via the
    /// 0xA5 INCR_CNT opcode). The base class stores up to three; subclasses
    /// control the count via `counterCount(for:)`.
    public internal(set) var nfcCounters: [UInt32]

    /// Back-compat alias for the original single-counter property. Tests
    /// that pre-date EV1 still read this; for EV1 it returns counter 0.
    public var nfcCounter: UInt32 {
        get { nfcCounters.first ?? 0 }
        set {
            if !nfcCounters.isEmpty {
                nfcCounters[0] = newValue & 0x00FF_FFFF
            }
        }
    }

    /// NTAG213 TT tamper-loop semantic flag. `0x55` = closed loop
    /// (untampered), `0xAA` = broken loop. This is a simulator-internal
    /// convention — the wire response from `READ_TT_STATUS` (0xA4) is the
    /// 4-byte form per NT2H1311TT Rev 1.1: `00 00 00 00` when intact, the
    /// `tamperMessage` page bytes when broken. Tests still flip this byte
    /// directly to drive the broken-loop branch.
    public var tamperStatus: UInt8 = 0x55

    /// 4-byte customer-programmable TT_MESSAGE returned by READ_TT_STATUS
    /// (0xA4) when the tamper loop is broken. Datasheet default is
    /// implementation-defined; we use ASCII "OPEN" as a documentable
    /// fixture for snapshot tests.
    public var tamperMessage: Data = .init([0x4F, 0x50, 0x45, 0x4E])

    /// Halted = `true` after a `HALT` (0x50) until the simulator is reset.
    /// We don't actually drop the session — tests can observe the flag.
    public private(set) var isHalted: Bool = false

    /// Multi-frame opcode state. Currently only `COMPATIBILITY_WRITE` is
    /// modeled — `SECTOR_SELECT` (0xC2) is **not** in the NTAG213/215/216
    /// or MIFARE UL EV1 command sets (it's an NTAG I²C feature, used by
    /// chips with >256 addressable pages). Reintroduce a case here if we
    /// ever add NTAG I²C 1K/2K to the catalog.
    private var pendingMultiFrame: MultiFrame?

    private enum MultiFrame {
        case compatibilityWrite(page: Int)
    }

    /// Per-counter tearing flag. `CHECK_TEARING_EVENT` (0x3E) returns `0xBD` when
    /// no tearing event occurred on that counter — the state a healthy tag is
    /// always in. Ultralight EV1 only; NTAG21x NAKs the opcode.
    public var tearingEvents: [Bool]

    /// - Parameter virgin: `true` leaves page 3 (the OTP Capability Container)
    ///   all-zero — **the state a MIFARE Ultralight EV1 actually ships in**.
    ///   NTAG21x ships NDEF-preformatted, so the default (`false`) seeds the
    ///   factory CC. Modelling only the preformatted state meant no test ever
    ///   exercised the app's format path on the chip family that needs it.
    public init(
        variant: Type2Variant,
        profile: ChipProfile,
        uid: Data,
        ndefMessage: Data? = nil,
        signature: Data = Data(repeating: 0x00, count: 32),
        virgin: Bool = false
    ) {
        precondition(uid.count == 7, "NTAG UID is 7 bytes")
        self.variant = variant
        self.profile = profile
        self.uid = uid
        self.signature = signature
        pages = Self.makeInitialPages(variant: variant, profile: profile, uid: uid, virgin: virgin)
        // EV1 exposes three 24-bit counters; NTAG variants expose one. The
        // counter array length drives both READ_CNT bounds checks and the
        // INCR_CNT opcode's reachable slots.
        let counterCount = switch variant {
        case .mifareUltralightEV1_48, .mifareUltralightEV1_128: 3
        default: 1
        }
        nfcCounters = Array(repeating: 0, count: counterCount)
        tearingEvents = Array(repeating: false, count: counterCount)
        if let message = ndefMessage {
            try? writeNDEFRegion(NDEFEnvelope.wrap(message: message))
        }
    }

    /// `true` for chips whose NFC counter advances on every reader read —
    /// NTAG21x family. False for EV1 (counters change only on INCR_CNT).
    var ticksCounterOnRead: Bool {
        switch variant {
        case .ntag213, .ntag213TT, .ntag215, .ntag216: true
        default: false
        }
    }

    /// `true` for MIFARE Ultralight EV1 variants — gates the INCR_CNT
    /// opcode and the indexed READ_CNT form.
    var isMifareUltralightEV1: Bool {
        switch variant {
        case .mifareUltralightEV1_48, .mifareUltralightEV1_128: true
        default: false
        }
    }

    // MARK: - Memory helpers

    private static func makeInitialPages(variant: Type2Variant, profile: ChipProfile, uid: Data,
                                         virgin: Bool) -> [Data]
    {
        var pages = [Data](repeating: Data(repeating: 0x00, count: 4), count: variant.pageCount)
        // Pages 0–1 hold the UID + BCC0/BCC1. Per NXP layout:
        //   Page 0: SN0 SN1 SN2 BCC0     where BCC0 = 0x88 XOR SN0 XOR SN1 XOR SN2
        //   Page 1: SN3 SN4 SN5 SN6
        //   Page 2: BCC1 INTERNAL LOCK0 LOCK1     where BCC1 = SN3 XOR SN4 XOR SN5 XOR SN6
        let sn0 = uid[uid.startIndex]
        let sn1 = uid[uid.startIndex + 1]
        let sn2 = uid[uid.startIndex + 2]
        let sn3 = uid[uid.startIndex + 3]
        let sn4 = uid[uid.startIndex + 4]
        let sn5 = uid[uid.startIndex + 5]
        let sn6 = uid[uid.startIndex + 6]
        let bcc0: UInt8 = 0x88 ^ sn0 ^ sn1 ^ sn2
        let bcc1: UInt8 = sn3 ^ sn4 ^ sn5 ^ sn6
        pages[0] = Data([sn0, sn1, sn2, bcc0])
        pages[1] = Data([sn3, sn4, sn5, sn6])
        pages[2] = Data([bcc1, 0x48, 0x00, 0x00]) // internal byte, no lock
        // CC: magic, version, size, R/W access. Taken from the production
        // `ChipProfile.factoryCC` so the simulator's page 3 can never disagree
        // with what the app's `formatCC` would write to a real (OTP) page.
        // `FactoryCCTests` asserts the two agree for every Type-2 profile.
        //
        // A `virgin` tag leaves it blank: NXP ships NTAG21x NDEF-preformatted
        // but MIFARE Ultralight EV1 with an empty OTP page, so a real EV1 has
        // no CC until something writes one.
        pages[3] = virgin ? Data([0x00, 0x00, 0x00, 0x00])
            : (profile.factoryCC ?? Data([0x00, 0x00, 0x00, 0x00]))

        // Configuration pages, as a delivered tag reads them back.
        //
        // The surveyed dies carry a byte in CFG0 byte 0 and another in CFG1
        // byte 1 that this simulator used to zero, so neither existed anywhere in
        // CI. That mattered: replacing `config.config1(...)` with a constructed
        // `Data([access, 0, 0, 0])` would have stayed green here while every real
        // NTAG213, NTAG216 and UL EV1 128 quietly lost its `05`. Values from the
        // 2026-09-09 delivery survey, recorded in
        // `docs/internal/chip-config-pages.md`. They are bytes, not meanings:
        // nothing branches on them, and the point is only that a preservation bug
        // has something to destroy.
        if let configPages = ConfigLayout.configPages(for: variant) {
            // AUTH0 in config0 byte 3, default 0xFF meaning "no protection".
            pages[configPages.config0] = deliveryConfig0(for: variant)
            // ACCESS in config1 byte 0, default 0 (PROT=0, no AUTH_LIM, no CFGLCK).
            pages[configPages.config1] = deliveryConfig1(for: variant)
            // Default PWD = 0xFFFFFFFF, PACK = 0x0000.
            pages[configPages.pwd] = Data([0xFF, 0xFF, 0xFF, 0xFF])
            pages[configPages.pack] = Data([0x00, 0x00, 0x00, 0x00])
        }

        // The dynamic lock page as it arrives. Byte 3 is RFUI and reads back as
        // the die's own constant whatever is written to it, so it is there on an
        // unlocked tag too: the delivery survey read 00 00 00 BD on NTAG213,
        // NTAG216 and UL EV1 128, and the HG-1 sweep the same day read the same
        // BD on three locked ones. Bytes 0-2 stay clear, because a delivered tag
        // is unlocked and `writeBlockReason` scores only those three.
        //
        // This is the half that bites a fixture taken from the simulator: until
        // now an unlocked NTAG213 here answered 00 00 00 00, which is a state no
        // NTAG21x has ever been in.
        if let byte3 = deliveryDynamicLockByte3(for: variant),
           let dynamicLockPage = profile.memoryLayout.dynamicLockPage,
           dynamicLockPage < pages.count, pages[dynamicLockPage].count >= 4
        {
            var page = pages[dynamicLockPage]
            page[page.startIndex + 3] = byte3
            pages[dynamicLockPage] = page
        }

        // The start of the data area, as a delivered tag reads it back.
        //
        // Until this was seeded a fresh NTAG213 here served twelve zero bytes
        // below its Capability Container: NULL TLVs and no message at all, which
        // is a data area no NTAG213 has been read with. A virgin tag gets nothing,
        // because the only readings sit beneath a factory CC, and seeding goes
        // before init's `ndefMessage` write, so a fixture overwrites it from the
        // first page exactly as production's page path does.
        if !virgin, let prologue = deliveryDataAreaPrologue(for: variant),
           let start = profile.memoryLayout.ndefRange?.lowerBound,
           start + prologue.count / 4 <= pages.count
        {
            for index in 0 ..< prologue.count / 4 {
                pages[start + index] = prologue.subdata(in: (index * 4) ..< (index * 4 + 4))
            }
        }
        return pages
    }

    /// CFG0 as a delivered tag reads it back, from the 2026-09-09 survey.
    ///
    /// Unsurveyed variants keep the old all-purpose default rather than
    /// borrowing a neighbour's byte. NTAG215, NTAG213 TT and UL EV1 48 were not
    /// in the survey, and a byte nobody has read is not a better default than an
    /// obviously generic one.
    private static func deliveryConfig0(for variant: Type2Variant) -> Data {
        switch variant {
        case .ntag213, .ntag216:
            Data([0x04, 0x00, 0x00, 0xFF])

        default:
            Data([0x00, 0x00, 0x00, 0xFF])
        }
    }

    /// CFG1 as a delivered tag reads it back, from the same survey.
    ///
    /// The `05` in byte 1 is the byte a whole-page ACCESS write destroys, and
    /// destroying it is finding 6 in the same session. Byte 0 is ACCESS and is
    /// genuinely 0 on delivery.
    private static func deliveryConfig1(for variant: Type2Variant) -> Data {
        switch variant {
        case .ntag213, .ntag216, .mifareUltralightEV1_128:
            Data([0x00, 0x05, 0x00, 0x00])

        default:
            Data([0x00, 0x00, 0x00, 0x00])
        }
    }

    /// Byte 3 of the dynamic lock page as a delivered tag reads it back.
    ///
    /// RFUI, and a read artefact rather than storage: `Type2LockWrite` says so in
    /// its `lockBitMask` doc comment, the delivery survey measured BD on three
    /// unlocked dies, and the HG-1 sweep measured the same BD on three locked
    /// ones.
    ///
    /// `nil` means no capture exists for that variant, which is not the same as a
    /// measured zero. Unsurveyed: NTAG215, NTAG213 TT, UL EV1 48. NTAG 210µ and
    /// the EM chips have no dynamic lock page to seed. Ultralight C is not here
    /// at all: it has its own simulator and its own measured 00.
    private static func deliveryDynamicLockByte3(for variant: Type2Variant) -> UInt8? {
        switch variant {
        case .ntag213, .ntag216, .mifareUltralightEV1_128:
            0xBD

        default:
            nil
        }
    }

    /// The first three pages of the data area as a delivered tag reads them back.
    ///
    /// **NTAG213:** `01 03 A0 0C 34 03 00 FE`, a Lock Control TLV, an empty NDEF
    /// message and the terminator, then a page of zeros. All twelve bytes were
    /// read on five dies, none of which this app had written:
    /// `04:63:E5:FA:2A:14:90` on 2026-09-09
    /// (`bench-traces/2026-09-09-t2-3-x-2-ntag213.log`), and
    /// `04:46:93:42:FE:0F:90`, `04:A9:DB:3A:D6:1F:90` and `04:8F:DB:3A:D6:1F:90`
    /// on 2026-09-10 (`bench-traces/2026-09-10-t2-1-ntag213.log`), and a fifth,
    /// `04:D4:B1:52:7C:16:90`, on 2026-09-14. `chip-config-pages.md` records the
    /// first two from the 2026-09-09 survey.
    /// It is not universal: a sixth die, `04:5D:E5:FA:2A:14:90`, read
    /// `04 03 A0 0C` at page 4, which `readNDEF`'s `definedTLVTags` gate models
    /// and `UnformattedTagTests` stages by hand.
    ///
    /// **NTAG 210µ:** `03 00 FE 00`, an empty NDEF message with no Lock Control
    /// TLV. NT2L1001_NT2H1001 rev 3.0 Table 4 "Memory content at delivery" gives
    /// that page 04h, and three dies in the 2026-09-09 survey read it. Two more
    /// read `04 00 FE 00`, the same one-byte fault the NTAG213 outlier carries.
    /// The bytes alone would be indistinguishable from this app's erase, and it
    /// is the datasheet that makes them a delivery image.
    ///
    /// `nil` means no delivery reading exists, and the reason differs by chip:
    ///
    /// - NTAG216 reads `03 00 FE 00`, which is exactly what this app's erase
    ///   writes, and no datasheet table in the repo settles it.
    ///   `chip-config-pages.md` says no simulator should be seeded from it.
    /// - UL EV1 128's surveyed tag read a blank CC above `03 00 FE 00`, which the
    ///   2026-09-09 survey files as the fingerprint of an erase on a virgin tag
    ///   and so not as a delivery reading. `test-harness.md` reads the same image
    ///   off an earlier EV1 as what a virgin tag carries. Neither settles it.
    /// - NTAG215, NTAG213 TT and UL EV1 48 were not surveyed.
    /// - The EM chips (`EmType2Simulator`) have no data-area reading in the repo.
    ///
    /// Pages 7 to 39 of an NTAG213 were never dumped, so the zeros past the
    /// prologue are a fixture choice, not a reading.
    private static func deliveryDataAreaPrologue(for variant: Type2Variant) -> Data? {
        switch variant {
        case .ntag213:
            Data([0x01, 0x03, 0xA0, 0x0C, 0x34, 0x03, 0x00, 0xFE, 0x00, 0x00, 0x00, 0x00])

        case .ntag210Micro:
            Data([0x03, 0x00, 0xFE, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

        default:
            nil
        }
    }

    // MARK: - Authentication / locking guards

    /// Reason a write to `page` would be rejected. `.allowed` is the
    /// success path; the rest distinguish irreversible lock bits from
    /// recoverable auth-required failures so tests can assert which one
    /// fired.
    enum WriteBlockReason: Equatable {
        case allowed
        case permanentLock
        case staticLock
        case dynamicLock
        case authRequired
        /// Pages 0–1 (UID/serial/internal) are factory-programmed read-only — a
        /// WRITE (0xA2) to them is NAK'd by hardware (NXP §8.5.1 / WRITE valid
        /// range starts at page 02h).
        case readOnly
    }

    func writeBlockReason(page: Int) -> WriteBlockReason {
        // UID/serial pages are immutable on real silicon — WRITE → NAK. (Page 02h
        // itself IS writable, but only its lock bytes mutate; see `applyWrite`.)
        if page < 2 {
            return .readOnly
        }
        if isLockedPermanent {
            return .permanentLock
        }
        // Static lock bytes (page 2 bytes 2 and 3) cover pages 3..15.
        if page <= 15 {
            let lockHigh = pages[2][pages[2].startIndex + 2]
            let lockLow = pages[2][pages[2].startIndex + 3]
            let locks = (UInt16(lockLow) << 8) | UInt16(lockHigh)
            // Bit positions 4..15 map to pages 4..15; bit 3 = "block lock 3"
            // covering page 3 (CC). We treat any bit set in the page index as
            // locked; for the simulator this is good enough.
            if page < 16, (locks & (1 << UInt16(page))) != 0 {
                return .staticLock
            }
        }
        // Dynamic lock byte (page beyond NDEF region) covers pages 16..end.
        if let dynamicLockPage = profile?.memoryLayout.dynamicLockPage,
           page >= 16, dynamicLockPage < pages.count
        {
            let dynamicLocks = pages[dynamicLockPage]
            // 3-byte dynamic lock field; we model it as "any bit set ⇒ locked".
            if dynamicLocks.prefix(3).contains(where: { $0 != 0 }) {
                return .dynamicLock
            }
        }
        // Password protection: pages ≥ AUTH0 require authentication.
        if let auth0 = currentAUTH0(), page >= Int(auth0), !isAuthenticated {
            return .authRequired
        }
        return .allowed
    }

    private func canWrite(page: Int) -> Bool {
        writeBlockReason(page: page) == .allowed
    }

    private func canRead(page: Int) -> Bool {
        if isLockedPermanent {
            // Even after permanent lock, reads still succeed — only writes fail.
            return true
        }
        if let auth0 = currentAUTH0(), page >= Int(auth0), readProtected(), !isAuthenticated {
            return false
        }
        return true
    }

    private func currentAUTH0() -> UInt8? {
        guard let configPages = ConfigLayout.configPages(for: variant) else { return nil }
        return pages[configPages.config0][pages[configPages.config0].startIndex + 3]
    }

    private func readProtected() -> Bool {
        guard let configPages = ConfigLayout.configPages(for: variant) else { return false }
        let access = pages[configPages.config1][pages[configPages.config1].startIndex + 0]
        return (access & 0x80) != 0 // PROT bit
    }

    private func authLimit() -> Int {
        guard let configPages = ConfigLayout.configPages(for: variant) else { return 0 }
        return Int(pages[configPages.config1][pages[configPages.config1].startIndex + 0] & 0x07)
    }

    // MARK: - Public ChipSimulator surface

    public func readMemory(range: Range<Int>) throws -> Data {
        // A NAK returns a Type-2 chip to HALT for the rest of the activation, so
        // every later command draws no answer at all. `handle(command:)` models
        // that; these two byte-range helpers used to skip the check, which let a
        // halted simulator keep serving memory that real silicon would not. That
        // divergence is what made a wrong password look like a clean read in CI
        // while it dead-ended the write flow on a real tag.
        if isHalted {
            throw TagError.tagLost(diagnostics: "tag halted by an earlier NAK; no answer until re-activation")
        }
        let pageSize = 4
        guard range.lowerBound >= 0, range.upperBound <= pages.count * pageSize else {
            throw TagError.protocolError("read out of range \(range)")
        }
        let firstPage = range.lowerBound / pageSize
        let lastPage = (range.upperBound - 1) / pageSize
        guard let served = servedPages(startPage: firstPage, count: lastPage - firstPage + 1) else {
            throw TagError.authFailed(
                diagnostics: "page=\(firstPage) requires authentication"
            )
        }
        let output = served.reduce(into: Data()) { $0.append(servedBytes(forPage: $1)) }
        // Trim to the requested byte range.
        let offset = range.lowerBound - firstPage * pageSize
        return output.subdata(in: offset ..< (offset + range.count))
    }

    public func writeMemory(at offset: Int, bytes: Data) throws {
        // A NAK returns a Type-2 chip to HALT for the rest of the activation, so
        // every later command draws no answer at all. `handle(command:)` models
        // that; these two byte-range helpers used to skip the check, which let a
        // halted simulator keep serving memory that real silicon would not. That
        // divergence is what made a wrong password look like a clean read in CI
        // while it dead-ended the write flow on a real tag.
        if isHalted {
            throw TagError.tagLost(diagnostics: "tag halted by an earlier NAK; no answer until re-activation")
        }
        guard offset % 4 == 0, bytes.count % 4 == 0 else {
            throw TagError.protocolError("page-aligned writes only")
        }
        var page = offset / 4
        var cursor = bytes.startIndex
        while cursor < bytes.endIndex {
            // Addressing past the last page NAKs on real silicon ("Addressing a
            // memory block beyond the limits above results in a NAK response",
            // stated per-chip in every Type-2 datasheet). The simulator used to
            // index straight into `pages` and trap — harmless while nothing
            // wrote out of range, but it meant an over-long write in production
            // would have looked like a crash in CI rather than the NAK the tag
            // actually sends. `readPages` has always bounds-checked; this brings
            // the write path in line.
            guard page < pages.count else {
                throw TagError.writeOverflow(needed: (page + 1) * 4, available: pages.count * 4)
            }
            let incoming = bytes.subdata(in: cursor ..< (cursor + 4))
            switch writeBlockReason(page: page) {
            case .allowed:
                applyWrite(page: page, incoming: incoming)

            case .readOnly:
                // Real hardware NAKs the WRITE; the raw path maps that to
                // `.protocolError` ("WRITE not acknowledged"), so match it.
                throw TagError.protocolError(
                    "page \(page) is read-only (UID/serial)",
                    diagnostics: "WRITE NAK page=\(page)"
                )

            case .permanentLock:
                throw TagError.lockedPermanent(diagnostics: "page=\(page) permanently locked")

            case .staticLock:
                throw TagError.lockedPermanent(diagnostics: "page=\(page) static lock bit set")

            case .dynamicLock:
                throw TagError.lockedPermanent(diagnostics: "page=\(page) dynamic lock byte set")

            case .authRequired:
                throw TagError.authFailed(
                    diagnostics: "page=\(page) requires authentication"
                )
            }
            page += 1
            cursor += 4
        }
    }

    /// Commit a 4-byte page write, modelling the one-way (OTP) cells real silicon
    /// has so the simulator can't "succeed" at clearing a bit hardware can only
    /// set:
    ///  * page 02h — UID/internal bytes 0–1 are immutable; lock bytes 2–3 are
    ///    bitwise-OR, irreversible (NXP §8.5.2).
    ///  * the CC page (03h on NTAG) / OTP page (03h on UL EV1) and the dynamic
    ///    lock page — bitwise-OR, irreversible (NXP §8.5.4 / §8.5.3).
    /// Every other page is ordinary read/write EEPROM (plain overwrite).
    private func applyWrite(page: Int, incoming: Data) {
        let start = pages[page].startIndex
        let inStart = incoming.startIndex
        let staticLockPage = Type2ConfigLayout.for(variant)?.staticLockPage ?? 2
        if page == staticLockPage {
            var p = pages[page]
            // Bytes 0–1 (BCC1 / internal) unaffected; lock bytes 2–3 OR-only.
            p[start + 2] |= incoming[inStart + 2]
            p[start + 3] |= incoming[inStart + 3]
            pages[page] = p
        } else if isOneWayPage(page) {
            var p = pages[page]
            for i in 0 ..< 4 {
                p[start + i] |= incoming[inStart + i]
            }
            pages[page] = p
        } else {
            pages[page] = incoming
        }
    }

    /// Pages whose bits can only be set, never cleared: the CC/OTP page (03h) and
    /// the chip's dynamic-lock page.
    private func isOneWayPage(_ page: Int) -> Bool {
        if page == 3 {
            return true
        }
        if let dyn = profile?.memoryLayout.dynamicLockPage, page == dyn {
            return true
        }
        return false
    }

    /// Whether the Capability Container page carries the NDEF magic (`0xE1`).
    /// A blank page means the tag was never formatted — the factory state of a
    /// MIFARE Ultralight EV1, whose CC page ships empty.
    func isCapabilityContainerFormatted(_ ccPage: Int) -> Bool {
        guard ccPage < pages.count else { return false }
        return pages[ccPage].first == 0xE1
    }

    /// The TLV tags the NFC Forum defines for a Type-2 data area: NULL, Lock
    /// Control, Memory Control, NDEF Message, Proprietary, Terminator. Everything
    /// else in 04h to FCh is reserved.
    static let definedTLVTags: Set<UInt8> = [0x00, 0x01, 0x02, 0x03, 0xFD, 0xFE]

    public func readNDEF() throws -> Data {
        // A halted chip answers nothing, and that includes the reader's NDEF
        // probe. Without this, a caller that had already been refused once could
        // still read the tag here, and the whole point of modelling HALT is that
        // it is the *next* command which pays for the refusal.
        if isHalted {
            throw TagError.tagLost(diagnostics: "chip is halted; a refused command ended the activation")
        }
        // A read-protected tag (PROT=1, AUTH0 covering the NDEF region) NAKs
        // reads until authenticated — so reading its NDEF fails exactly as a
        // real chip does. This is what routes the scan flow to its unlock prompt.
        let ndefStartPage = profile?.memoryLayout.ndefRange?.lowerBound ?? 4
        if let auth0 = currentAUTH0(), ndefStartPage >= Int(auth0), readProtected(), !isAuthenticated {
            throw TagError.authFailed(
                diagnostics: "NDEF region read-protected (AUTH0=\(auth0))"
            )
        }
        // A tag whose Capability Container is still blank is not NDEF-formatted.
        // CoreNFC's `queryNDEFStatus` reports `.notSupported` for it, which
        // `CoreNFCConnectedTag.readNDEF` turns into `capabilityUnsupported`. A
        // virgin MIFARE Ultralight EV1 is exactly that state (its CC page ships
        // empty), so model the refusal — otherwise a virgin simulator would serve
        // NDEF that the real chip's reader path never returns.
        if let ccPage = profile?.memoryLayout.ccPage, !isCapabilityContainerFormatted(ccPage) {
            throw TagError.capabilityUnsupported(
                .ndefRead,
                diagnostics: "no Capability Container at page \(ccPage) — tag is not NDEF-formatted"
            )
        }
        let allMemory = pages.reduce(Data()) { $0 + $1 }
        let ndefStart = (profile?.memoryLayout.ndefRange?.lowerBound ?? 4) * 4
        let userMemory = allMemory.subdata(in: ndefStart ..< allMemory.endIndex)
        // The second way a Type-2 tag refuses the reader's probe, and the one
        // that had never been modelled: the Capability Container is perfect and
        // the data area begins with a byte that is not a TLV tag at all.
        //
        // Scoped to exactly what a trace showed, per the rule about inventing
        // refusals. NTAG213 `04:5D:E5:FA:2A:14:90` (2026-09-09) read page 3 as
        // `E1 10 12 00` and page 4 as `04 03 A0 0C`, where its peel-sheet
        // sibling read `01 03 A0 0C` and scanned cleanly on the same phone.
        // `04` is reserved, and iOS answered `.notSupported`. Nothing here
        // claims to know what nfcd does with a *well-formed* structure it
        // dislikes, so the gate is the first byte and nothing more.
        if let first = userMemory.first, !Self.definedTLVTags.contains(first) {
            throw TagError.capabilityUnsupported(
                .ndefRead,
                diagnostics: "data area at page \(ndefStart / 4) begins \(String(format: "%02X", first)), "
                    + "which is not an NFC Forum TLV tag"
            )
        }
        // Tick the NFC counter on every read attempt — real chips tick on
        // every successful read of the NFC counter register; we model it on
        // the readNDEF entrypoint because that's the test-observable surface.
        // Per NXP NT2H1311 §8.6: the 24-bit counter **saturates** at
        // `0xFFFFFF` — it does not wrap. Skipped on EV1, whose counters
        // change only via INCR_CNT.
        if ticksCounterOnRead, !nfcCounters.isEmpty,
           nfcCounters[0] < 0x00FF_FFFF
        {
            nfcCounters[0] &+= 1
        }
        do {
            return try NDEFEnvelope.unwrap(userMemory)
        } catch NDEFEnvelope.ParseError.noNDEFTLV {
            return Data()
        }
    }

    public func writeNDEF(_ envelope: Data) throws {
        try writeNDEFRegion(envelope)
    }

    private func writeNDEFRegion(_ envelope: Data) throws {
        guard let layout = profile?.memoryLayout,
              let ndefRange = layout.ndefRange
        else {
            throw TagError.protocolError("no ndef range in chip layout")
        }
        let capacity = (ndefRange.upperBound - ndefRange.lowerBound + 1) * layout.pageSize
        guard envelope.count <= capacity else {
            throw TagError.writeOverflow(needed: envelope.count, available: capacity)
        }
        // Pad to a multiple of 4 with zeros, then write page by page.
        var padded = envelope
        while padded.count % 4 != 0 {
            padded.append(0x00)
        }
        // Exactly the pages the envelope occupies, and not one more.
        //
        // This used to zero the rest of the region afterwards, which is the
        // opposite of what production does: `CoreNFCSession.writeNDEFViaPages`
        // writes `padded.count / 4` pages from `ndefRange.lowerBound` and touches
        // nothing else. So an erase here produced a swept-clean region while an
        // erase on silicon left the old message sitting behind the terminator,
        // and the 2026-09-09 HG-1 sweep read it back off Type-2 tags. A simulator
        // that is tidier than the chip hides exactly the residue a user meets.
        try writeMemory(at: ndefRange.lowerBound * 4, bytes: padded)
    }

    /// A refused `PWD_AUTH` is a NAK: one nibble, no payload. No command in the
    /// NTAG21x set discloses the negative-attempt counter either, so this
    /// simulator must not answer with one. It used to: a private helper computed
    /// `limit - failedAuthAttempts` and handed the difference to
    /// `TagError.authFailed`, which made a field no real tag can fill look
    /// supportable, and it is the "a simulator must not be more forthcoming than
    /// silicon" defect in miniature.
    ///
    /// `failedAuthAttempts` and `isAuthLocked` stay. They model chip behaviour
    /// rather than a readout, and they matter more once a tag can arrive with a
    /// limit somebody set.
    ///
    /// **Both semantics below were measured on NTAG213** and were uncited before
    /// that; the datasheet passage that states them is quoted in
    /// `docs/internal/chip-config-pages.md` (rev 3.2 §8.8.2, cited 2026-09-15).
    /// `Type2AttemptLimitSemanticsTests` replays the captures. The rest of the
    /// family shares this code and was not measured.
    ///
    /// - The reset on success (`failedAuthAttempts = 0`): tag B
    ///   `04:8F:DB:3A:D6:1F:90` at `AUTH_LIM = 4` accepted the correct password
    ///   twice, each time after two refusals, the second where a count that never
    ///   resets would have stood at six (2026-09-10). A count reset only by an
    ///   ACCESS write is excluded only through the refusal form; the test's header
    ///   says how. The datasheet promises the reset only "before reaching the
    ///   limit"; this resets on every success, including one at the limit, and
    ///   silicon agreed on 2026-09-19: tag C at `AUTH_LIM = 1` took wrong, right,
    ///   wrong, right and accepted the last, where tag A had locked on two wrong
    ///   passwords with nothing between them. At a limit of 1 a reset to zero and
    ///   a step back by one cannot be told apart, and it is one chip at one limit.
    /// - The lock comes **one past the limit**, which is what §8.8.2 says: once
    ///   the counter "reaches the number specified in AUTHLIM, any further
    ///   negative password verification" locks. Tag C `04:D4:B1:52:7C:16:90` at
    ///   `AUTH_LIM = 1` took one wrong password and then accepted the right one
    ///   (2026-09-14, 23:03:15 and 23:03:38). Tag A at the same limit refused the
    ///   right one only after two wrong attempts, the second being the
    ///   factory-default offer, and tag B after five at a limit of 4. This used
    ///   to lock on reaching the limit, from a reading of tag A that counted one
    ///   wrong attempt where there were two.
    ///
    /// What is still divergent is the *form* of the refusal. This throws
    /// `.authFailed`, the payload NAK, for every refusal. On silicon the form
    /// follows the chip's state: a tag that has not locked answers a wrong
    /// password with a transport error (every observation, limit set or not),
    /// and a locked tag answers every password, right or wrong, with a 1-byte NAK
    /// (ten of ten on 2026-09-14). That is recorded in
    /// `unverified-behaviour.md` T2-3 and not encoded here.
    public func authenticate(password: Data) throws -> Data {
        guard password.count == 4 else {
            throw TagError.protocolError("PWD must be 4 bytes")
        }
        guard let configPages = ConfigLayout.configPages(for: variant) else {
            throw TagError.capabilityUnsupported(.passwordAuth)
        }
        // Once AUTH_LIM is exhausted the chip refuses every PWD_AUTH — including
        // one carrying the correct password — until/forever. Model that here so
        // the protected region becomes permanently unreachable (auth can never
        // succeed again) without pretending the whole tag is bricked.
        if isAuthLocked {
            throw TagError.authFailed(
                diagnostics: "AUTH_LIM exhausted — authentication permanently disabled"
            )
        }
        let storedPWD = pages[configPages.pwd]
        let storedPACK = pages[configPages.pack].prefix(2)
        if storedPWD == password {
            isAuthenticated = true
            failedAuthAttempts = 0
            return Data(storedPACK)
        } else {
            failedAuthAttempts += 1
            let limit = authLimit()
            if limit != 0, failedAuthAttempts > limit {
                // One past the limit, as NTAG213 silicon showed. AUTH_LIM
                // exhausted: permanently disable authentication (NOT a
                // lock-byte brick). The protected region stays intact but can no
                // longer be unlocked; unprotected pages are unaffected.
                isAuthLocked = true
            }
            throw TagError.authFailed(
                diagnostics: "expected=\(storedPWD.hexString) got=\(password.hexString)"
            )
        }
    }

    public func setPassword(_ password: Data, pack: Data) throws {
        guard password.count == 4, pack.count == 2 else {
            throw TagError.protocolError("PWD=4B PACK=2B required")
        }
        guard let configPages = ConfigLayout.configPages(for: variant) else {
            throw TagError.capabilityUnsupported(.passwordAuth)
        }
        try writeMemory(at: configPages.pwd * 4, bytes: password)
        var packPage = Data(pack)
        while packPage.count < 4 {
            packPage.append(0x00)
        }
        try writeMemory(at: configPages.pack * 4, bytes: packPage)
    }

    public func permanentLock() throws {
        // Only chips advertising the capability accept this. EM Microelectronic
        // and similar bare-bones Type-2 silicon don't expose Type-2-style
        // permanent lock at all.
        guard profile?.capabilities.contains(.permanentLock) == true else {
            throw TagError.capabilityUnsupported(.permanentLock)
        }
        // Lock-byte page numbers come from the chip's `ChipMemoryLayout`,
        // mirroring `CoreNFCSession.permanentLock` exactly — locks and passwords
        // are independent features, and a chip can have lock bytes with no
        // password block at all (NTAG 210µ). Sourcing these from
        // `Type2ConfigLayout` would make such a chip fall back to a hardcoded
        // default here while production threw, which is precisely the kind of
        // sim-vs-silicon divergence the harness exists to catch.
        let staticLockPage = profile?.memoryLayout.lockPages.first ?? 2
        let dynamicLock = profile?.memoryLayout.dynamicLockPage
        // Flip every bit in the static lock bytes (page 2, bytes 2–3). Real
        // chips flip specific BL* bits; 0xFF everywhere is semantically
        // equivalent — and irreversible — for simulator purposes.
        var lockPage = pages[staticLockPage]
        lockPage[lockPage.startIndex + 2] = 0xFF
        lockPage[lockPage.startIndex + 3] = 0xFF
        pages[staticLockPage] = lockPage
        // Dynamic lock bytes, on the larger chips only (MF0UL11 and NTAG 210µ
        // have none). This assigned `Data([0xFF, 0xFF, 0xFF, 0x00])` for every
        // chip, which is wrong in all four bytes: it set 6 RFUI bits on an
        // NTAG213, 3 on an NTAG216 and 9 on a UL EV1 128 that no real die holds,
        // and it cleared byte 3, which reads back as the chip's own BDh whatever
        // is written to it. HG-1 read the answer off three locked dies on
        // 2026-09-09: NTAG216 FF 3F 7F BD, UL EV1 128 FF 03 1F BD, NTAG213
        // FF 0F 3F BD. Bytes 0-2 are exactly `Type2LockWrite.lockBitMask(for:)`,
        // which is what production writes.
        //
        // OR the payload in rather than assigning it, for the same reason
        // `applyWrite` does: the page is one-way, and the delivery byte 3 seeded
        // by `makeInitialPages` has to survive a lock exactly as it does on
        // silicon. That is a seeded byte surviving an OR, not a model of an RFUI
        // discard, which the sweep does not license.
        if let profile, let dynamicLockPage = dynamicLock, dynamicLockPage < pages.count {
            let payload = Type2LockWrite.dynamicLockPayload(
                for: profile.family, pageSize: pages[dynamicLockPage].count
            )
            var page = pages[dynamicLockPage]
            for index in 0 ..< min(payload.count, page.count) {
                page[page.startIndex + index] |= payload[payload.startIndex + index]
            }
            pages[dynamicLockPage] = page
        }
        isLockedPermanent = true
    }

    /// Re-derive `isLockedPermanent` from the lock bytes themselves.
    ///
    /// Real silicon has no such flag: a tag is locked because its lock bits are
    /// set, and nothing else. The simulator used to set the flag only from its
    /// own `permanentLock()` helper, so a lock applied the way production
    /// applies it (page writes to the lock pages, through `Type2LockDriver`)
    /// left a tag whose bytes said locked and whose flag said otherwise. That is
    /// the same class of divergence as answering a credential command from a
    /// parallel model: the frames were right and the simulator disagreed with
    /// them.
    private func refreshPermanentLockFlag() {
        let staticLockPage = profile?.memoryLayout.lockPages.first ?? 2
        guard staticLockPage < pages.count else { return }
        let page = pages[staticLockPage]
        guard page.count >= 4 else { return }
        if page[page.startIndex + 2] == 0xFF, page[page.startIndex + 3] == 0xFF {
            isLockedPermanent = true
        }
    }

    /// Program PWD/PACK then enable protection — ACCESS (config1) before AUTH0
    /// (config0), so protection activates only once the credential is in place.
    /// Unlike `setPassword`, this actually gates subsequent reads/writes.
    public func enablePasswordProtection(
        password: Data,
        pack: Data,
        protectFromPage: Int,
        readProtect: Bool,
        authLimit: Int
    ) throws {
        guard password.count == 4 else { throw TagError.protocolError("PWD must be 4 bytes") }
        guard pack.count == 2 else { throw TagError.protocolError("PACK must be 2 bytes") }
        guard let configPages = ConfigLayout.configPages(for: variant) else {
            throw TagError.capabilityUnsupported(.passwordAuth)
        }
        guard (0 ... 0xFF).contains(protectFromPage) else {
            throw TagError.protocolError("protectFromPage out of range")
        }
        guard (0 ... 7).contains(authLimit) else {
            throw TagError.protocolError("authLimit must be 0…7")
        }

        // PWD → PACK → ACCESS → AUTH0 last (mirrors the real command order).
        try writeMemory(at: configPages.pwd * 4, bytes: password)
        var packPage = Data(pack)
        while packPage.count < 4 {
            packPage.append(0x00)
        }
        try writeMemory(at: configPages.pack * 4, bytes: packPage)

        var config1 = pages[configPages.config1]
        let accessIdx = config1.startIndex + Int(Type2ConfigLayout.accessByteOffset)
        var access = config1[accessIdx]
        access &= ~(Type2ConfigLayout.protBitMask | Type2ConfigLayout.authLimMask)
        if readProtect {
            access |= Type2ConfigLayout.protBitMask
        }
        access |= UInt8(authLimit) & Type2ConfigLayout.authLimMask
        config1[accessIdx] = access
        try writeMemory(at: configPages.config1 * 4, bytes: config1)

        var config0 = pages[configPages.config0]
        config0[config0.startIndex + Int(Type2ConfigLayout.auth0ByteOffset)] = UInt8(protectFromPage)
        try writeMemory(at: configPages.config0 * 4, bytes: config0)
    }

    /// Authenticate, then clear protection: AUTH0 = 0xFF first (so the rest of
    /// the writes are unguarded), then PROT/AUTH_LIM and PWD/PACK to defaults.
    public func disablePasswordProtection(currentPassword: Data) throws {
        guard let configPages = ConfigLayout.configPages(for: variant) else {
            throw TagError.capabilityUnsupported(.passwordAuth)
        }
        _ = try authenticate(password: currentPassword)

        var config0 = pages[configPages.config0]
        config0[config0.startIndex + Int(Type2ConfigLayout.auth0ByteOffset)] = 0xFF
        try writeMemory(at: configPages.config0 * 4, bytes: config0)

        var config1 = pages[configPages.config1]
        let accessIdx = config1.startIndex + Int(Type2ConfigLayout.accessByteOffset)
        config1[accessIdx] &= ~(Type2ConfigLayout.protBitMask | Type2ConfigLayout.authLimMask)
        try writeMemory(at: configPages.config1 * 4, bytes: config1)

        try writeMemory(at: configPages.pwd * 4, bytes: Data([0xFF, 0xFF, 0xFF, 0xFF]))
        try writeMemory(at: configPages.pack * 4, bytes: Data([0x00, 0x00, 0x00, 0x00]))
    }

    /// Report the on-chip protection state by inspecting AUTH0 / ACCESS — the
    /// same bytes the production `CoreNFCConnectedTag` reads from a real tag.
    /// Returns `.none` for an unprotected chip (AUTH0 past the last page) and
    /// nil for chips without NTAG21x-style protection. `hasStoredCredential`
    /// is always false — the PWD is never reported back out of a tag.
    public func readProtectionState() throws -> TagProtection? {
        guard profile?.capabilities.contains(.passwordAuth) == true,
              let auth0 = currentAUTH0(),
              let layout = Type2ConfigLayout.for(variant) else { return nil }
        // A fully read-protected tag (PROT=1) also NAKs READs of its config pages,
        // which sit at/above AUTH0 — so a real reader can't recover the protection
        // state without authenticating first (the production
        // `CoreNFCConnectedTag.readProtectionState` hits the same NAK on its
        // config-page READ). Surface that as a thrown error rather than leaking the
        // state out of simulator memory. The scan flow authenticates before this
        // call on the unlock re-tap, so the post-auth path still reports the state.
        if readProtected(), !isAuthenticated, layout.config0Page >= Int(auth0) {
            // …and the refusal **halts the tag**, exactly as `nak()` does for
            // every other refused command. On silicon this is a plain `READ`
            // of the config page, so the NAK returns the chip to HALT for the
            // rest of the activation and nothing sent afterwards is answered.
            //
            // Throwing without halting is what let this ship: the callers wrap
            // the call in `try?`, the simulator let the *next* command through,
            // and both the scan and the write flow looked like they recovered.
            // On a real NTAG213 they did not (live trace, 2026-08-14: `30 29` →
            // `00`, then silence for the rest of the session).
            isHalted = true
            throw TagError.authFailed(
                diagnostics: "config pages read-protected (AUTH0=\(auth0)); tag halted by the NAK"
            )
        }
        guard Int(auth0) <= layout.packPage else { return TagProtection.none }
        return TagProtection(
            passwordProtect: true,
            protectFromPage: Int(auth0),
            readProtect: readProtected(),
            authLimit: authLimit(),
            hasStoredCredential: false
        )
    }

    // MARK: - Raw transceive

    public func handle(command: Data) -> Data {
        // Two-frame opcodes (`SECTOR_SELECT`, `COMPATIBILITY_WRITE`) are
        // dispatched here from the previous call's leftover state. Real
        // chips signal this transparently across two physical frames; the
        // simulator's surface stays per-`handle(command:)` so each test
        // can step through the protocol explicitly.
        if let pending = pendingMultiFrame {
            pendingMultiFrame = nil
            return handleMultiFrameContinuation(pending, command: command)
        }
        guard let opcode = command.first else { return nak() }
        // After HALT, the chip is asleep until the next anticollision —
        // we model this by NAKing every command. Tests can call
        // `wakeUp()` to clear the flag without a full re-init.
        if isHalted {
            return nak()
        }
        switch opcode {
        case 0x30: // READ — 16 bytes (4 pages) starting at <page>
            guard command.count >= 2 else { return nak() }
            let startPage = Int(command[command.startIndex + 1])
            return readPages(startPage: startPage, count: 4)

        case 0x3A: // FAST_READ — bytes from <start>..<end> inclusive
            // Not universal across Type-2: the NTAG 210µ omits FAST_READ
            // entirely (NT2L1001_NT2H1001 rev 3.0 Table 5), so a chip that
            // doesn't advertise it must NAK here — otherwise the simulator is
            // more capable than the silicon and the harness step passes in CI
            // while failing on a real tag.
            guard profile?.capabilities.contains(.fastRead) == true else { return nak() }
            guard command.count >= 3 else { return nak() }
            let startPage = Int(command[command.startIndex + 1])
            let endPage = Int(command[command.startIndex + 2])
            guard endPage >= startPage else { return nak() }
            let count = endPage - startPage + 1
            return readPages(startPage: startPage, count: count)

        case 0xA2: // WRITE — 4 bytes at <page>
            guard command.count >= 6 else { return nak() }
            let page = Int(command[command.startIndex + 1])
            let data = command.subdata(in: (command.startIndex + 2) ..< (command.startIndex + 6))
            do {
                try writeMemory(at: page * 4, bytes: data)
                refreshPermanentLockFlag()
                return Data([0x0A]) // ACK
            } catch {
                return nak()
            }

        case 0xA0: // COMPATIBILITY_WRITE — legacy 16-byte two-frame write
            guard command.count >= 2 else { return nak() }
            let page = Int(command[command.startIndex + 1])
            // Frame 1 ACKs and parks until frame 2 arrives with 16 bytes.
            pendingMultiFrame = .compatibilityWrite(page: page)
            return Data([0x0A])

        case 0x50: // HALT — silence the chip until next anticollision
            isHalted = true
            return Data() // real chips return no response; simulator emits empty

        case 0x60: // GET_VERSION
            return versionBlock()

        case 0x3C: // READ_SIG — 32-byte ECC signature
            // Guarded like FAST_READ and READ_CNT above, and for the same
            // reason: a chip that doesn't advertise `.signatureRead` NAKs this
            // opcode on real silicon. Without the guard the simulator answered
            // for every Type-2 chip, so `t2.signature` passed in CI and failed
            // live on any chip lacking the command.
            guard profile?.capabilities.contains(.signatureRead) == true else { return nak() }
            return signature

        case 0x39: // READ_CNT — 24-bit NFC counter. NTAG: arg=0x02 selects
            // the NFC counter (the only counter that's user-readable). EV1:
            // arg in [0..2] selects one of CNT0/1/2. The NTAG 210/212/210µ have
            // no counter hardware at all and NAK the opcode.
            guard profile?.capabilities.contains(.counterRead) == true else { return nak() }
            guard command.count >= 2 else { return nak() }
            let index: Int = isMifareUltralightEV1 ? Int(command[command.startIndex + 1]) : 0
            guard index < nfcCounters.count else { return nak() }
            let cnt = nfcCounters[index]
            return Data([
                UInt8(cnt & 0xFF),
                UInt8((cnt >> 8) & 0xFF),
                UInt8((cnt >> 16) & 0xFF),
            ])

        case 0x1B: // PWD_AUTH — 4-byte password → 2-byte PACK
            guard command.count >= 5 else { return nak() }
            let pwd = command.subdata(in: (command.startIndex + 1) ..< (command.startIndex + 5))
            do {
                return try authenticate(password: pwd)
            } catch {
                return nak()
            }

        case 0xA4:
            // NTAG213 TT `READ_TT_STATUS` per NT2H1311TT Rev 1.1: returns
            // 4 bytes. Intact → `00 00 00 00`. Broken → the customer's
            // TT_MESSAGE page bytes. Chips without `.tamperStatus`
            // capability NAK.
            guard profile?.capabilities.contains(.tamperStatus) == true else { return nak() }
            return tamperStatus == 0x55
                ? Data([0x00, 0x00, 0x00, 0x00])
                : tamperMessage

        case 0xA5:
            // MIFARE Ultralight EV1 `INCR_CNT <index> <3B value LE>`. No
            // NTAG21x variant uses this opcode — earlier revisions of this
            // sim mapped it to TT status, but that conflicts with the
            // NT2H1311TT datasheet (TT uses 0xA4).
            guard isMifareUltralightEV1 else { return nak() }
            return handleIncrCnt(command)

        case 0x3E:
            // MIFARE Ultralight EV1 `CHECK_TEARING_EVENT <index>` (MF0ULx1
            // §10.7): 1 byte, `0xBD` when no tearing event occurred on that
            // counter. NTAG21x has no such opcode and NAKs it.
            guard isMifareUltralightEV1, command.count >= 2 else { return nak() }
            let index = Int(command[command.startIndex + 1])
            guard index < tearingEvents.count else { return nak() }
            return Data([tearingEvents[index] ? 0x00 : 0xBD])

        case 0xA9:
            // `WRITE_SIG <block 00h–07h> <4 bytes>` — reprogram one block of the
            // 32-byte originality signature (NT2L1001_NT2H1001 rev 3.0 §11.6,
            // Table 20 + Fig 15; note the table lists CRC before Data but the
            // figure — which is authoritative — frames it Cmd|Addr|Data|CRC).
            //
            // Block 00h holds the MSByte end (Table 22), i.e. blocks map onto
            // READ_SIG's output in order.
            guard supportsSignatureLock, command.count >= 6 else { return nak() }
            // The 210µ datasheet omits this, but the sibling MF0UN(H)00 rev 3.1
            // §10.6 states it outright: a locked or permanently locked signature
            // NAKs WRITE_SIG. Since the factory state is locked, this is the
            // out-of-the-box behaviour.
            guard signatureLock == .unlocked else { return nak() }
            let block = Int(command[command.startIndex + 1])
            guard (0x00 ... 0x07).contains(block) else { return nak() }
            var newSignature = signature
            let chunk = command.subdata(in: (command.startIndex + 2) ..< (command.startIndex + 6))
            let start = newSignature.startIndex + block * 4
            newSignature.replaceSubrange(start ..< (start + 4), with: chunk)
            signature = newSignature
            return Data([0x0A]) // ACK

        case 0xAC:
            // `LOCK_SIG <action>` — 00h unlock, 01h lock, 02h permanently lock
            // (rev 3.0 §11.7 Table 23). Two bytes before CRC.
            //
            // ⚠️ Rev 3.0's Table 23 misprints the opcode as A9h, colliding with
            // WRITE_SIG. Table 5 (command overview), the MF0UN(H)00 rev 3.1
            // equivalent table, and Proxmark3's MIFARE_ULNANO_LOCKSIG all agree
            // on ACh. ACh is correct; the table is a known Rev 3.0 typo.
            guard supportsSignatureLock, command.count >= 2 else { return nak() }
            // "...can only be unlocked if the originality signature memory is
            // not permanently locked." Permanent lock is terminal: every further
            // state change NAKs.
            guard signatureLock != .permanentlyLocked else { return nak() }
            switch command[command.startIndex + 1] {
            case 0x00: signatureLock = .unlocked
            case 0x01: signatureLock = .locked
            case 0x02: signatureLock = .permanentlyLocked
            default: return nak() // 03h–FFh undefined in the datasheet
            }
            return Data([0x0A]) // ACK

        case 0x1A:
            // EV1 legacy 3DES authenticate. We don't implement the cipher
            // — return a canned NAK so command-replay tests can observe
            // "auth never succeeds on this skeleton" deterministically.
            guard isMifareUltralightEV1 else { return nak() }
            return nak()

        default:
            return nak()
        }
    }

    private func handleMultiFrameContinuation(_ pending: MultiFrame, command: Data) -> Data {
        switch pending {
        case .compatibilityWrite(let page):
            // Frame 2: 16-byte payload. Real chips write only the first 4
            // and discard the rest; the simulator does the same so a
            // datasheet-following caller gets the same observable result.
            guard command.count >= 16 else { return nak() }
            let payload = command.subdata(in: command.startIndex ..< (command.startIndex + 4))
            do {
                try writeMemory(at: page * 4, bytes: payload)
                return Data([0x0A])
            } catch {
                return nak()
            }
        }
    }

    /// Clear `isHalted` so subsequent commands are honoured again. Real
    /// readers achieve this by issuing a REQA / WUPA; tests just call this.
    public func wakeUp() {
        isHalted = false
    }

    /// Re-selected from IDLE: awake and unauthenticated, whatever the previous
    /// session did. See `ChipSimulator.beginActivation`.
    public func beginActivation() {
        isHalted = false
        isAuthenticated = false
    }

    /// Put the chip to sleep without going through a refused command, so a test
    /// can model a tag that answers identification and then nothing else, the
    /// way a tag lifted mid-session does.
    public func halt() {
        isHalted = true
    }

    /// EV1 `INCR_CNT <index> <3B LE value>` — atomically add `value` to
    /// counter `index`. Saturating overflow returns NAK; otherwise ACK.
    private func handleIncrCnt(_ command: Data) -> Data {
        // 0xA5 idx v0 v1 v2 — total 5 bytes.
        guard command.count >= 5 else { return nak() }
        let index = Int(command[command.startIndex + 1])
        guard index < nfcCounters.count else { return nak() }
        let v0 = UInt32(command[command.startIndex + 2])
        let v1 = UInt32(command[command.startIndex + 3]) << 8
        let v2 = UInt32(command[command.startIndex + 4]) << 16
        let value = v0 | v1 | v2
        let next = UInt64(nfcCounters[index]) + UInt64(value)
        if next > 0x00FF_FFFF {
            return nak()
        }
        nfcCounters[index] = UInt32(next)
        return Data([0x0A])
    }

    /// Test-only: seed the 24-bit NFC counter to a specific value so
    /// overflow / threshold behaviour can be asserted without having to
    /// issue 16 million reads first.
    public func seedNfcCounter(_ value: UInt32) {
        // Clamp to 24-bit semantics (real counter is 24 bits wide).
        nfcCounter = value & 0x00FF_FFFF
    }

    /// A NAK, **and the end of the activation**.
    ///
    /// ISO/IEC 14443-3: a Type-2 tag that refuses a command returns to HALT and
    /// answers nothing more until the next anticollision. Modelling the refusal
    /// without the HALT makes the simulator more forgiving than any real Type-2
    /// chip, so a flow can send a frame it expects to be refused, read the
    /// refusal, carry on, and pass in CI while dying on silicon.
    ///
    /// That is not hypothetical. It shipped twice: `ulc.identify` probing
    /// GET_VERSION, and `lockSignature` reading the signature back *after* its
    /// unlock probe. Both were green here and both died live with "tag
    /// connection lost". `MifareUltralightCSimulator` was corrected on
    /// 2026-08-07; this is the same fix for the rest of the Type-2 family.
    ///
    /// Tests that deliberately probe a refusal and then keep going must call
    /// `wakeUp()`, which is what a real re-tap does.
    private func nak() -> Data {
        isHalted = true
        return Data([0x00])
    }

    private func readPages(startPage: Int, count: Int) -> Data {
        guard let served = servedPages(startPage: startPage, count: count) else { return nak() }
        return served.reduce(into: Data()) { $0.append(servedBytes(forPage: $1)) }
    }

    /// What a READ of `page` actually returns, as opposed to what the page holds.
    ///
    /// **The PWD page reads back as all zeros and the PACK page zeros its two
    /// credential bytes** (NTAG213/215/216 rev 3.2 section 8.8: the password and
    /// the acknowledge are never disclosed by the chip). The simulator had been
    /// serving the real bytes since it was written, and nothing noticed because
    /// nothing read those pages.
    ///
    /// That stopped being harmless the moment the credential path moved onto the
    /// wire: the configuration block is the last four pages on every chip in the
    /// catalogue, so the driver's single `30 <config0Page>` now returns CFG0,
    /// CFG1, PWD and PACK in one frame. A simulator that answers the real
    /// password there invites an implementer to "verify" a credential by reading
    /// it back, which would pass in CI and fail on every real tag.
    private func servedBytes(forPage page: Int) -> Data {
        guard let configPages = ConfigLayout.configPages(for: variant) else { return pages[page] }
        if page == configPages.pwd {
            return Data(repeating: 0x00, count: 4)
        }
        if page == configPages.pack {
            var masked = pages[page]
            masked[masked.startIndex] = 0x00
            masked[masked.startIndex + 1] = 0x00
            return masked
        }
        return pages[page]
    }

    /// Which pages a READ starting at `startPage` actually serves, or `nil` when
    /// the chip would NAK the frame outright.
    ///
    /// Two things decide this, and the simulator used to model only the first:
    ///
    /// 1. **End-of-memory roll-over.** A READ past the last page continues at
    ///    page 0, so a FAST_READ off the end returns 16 bytes rather than short.
    ///
    /// 2. **Read protection moves that boundary down.** Password protection ends
    ///    the *accessible* memory at `AUTH0 - 1`, and the chip rolls over there
    ///    for the same reason — it does not refuse the frame. Only the addressed
    ///    page can NAK. Verified on a live NTAG213 (2026-08-14): with `AUTH0 = 04`
    ///    and `PROT = 1`, `30 03` answered
    ///    `E1 10 12 00 | 04 BA 4A 7C | 92 1B 21 90 | 38 48 00 00` — page 3, then
    ///    **pages 0, 1, 2** — against `E1 10 12 00 | 03 11 D1 01 | …` from the
    ///    same tag unprotected.
    ///
    /// Modelling the refusal instead of the roll-over made the simulator stricter
    /// than the silicon, and that gap is load-bearing: the roll-over is the one
    /// *positive* signal that a tag is read-protected, as opposed to absent, and
    /// no test could exercise a probe built on it while the chip threw here.
    private func servedPages(startPage: Int, count: Int) -> [Int]? {
        guard startPage >= 0, startPage < pages.count, canRead(page: startPage) else { return nil }
        var served: [Int] = []
        var next = startPage
        var wrapped = false
        for _ in 0 ..< count {
            if next >= pages.count || !canRead(page: next) {
                // One wrap only: a chip that can't serve page 0 either has
                // nothing left to give, so the frame is refused rather than
                // looping.
                guard !wrapped else { return nil }
                wrapped = true
                next = 0
                guard canRead(page: next) else { return nil }
            }
            served.append(next)
            next += 1
        }
        return served
    }

    /// 8-byte version block. Variant-specific subclass overrides change the
    /// subType / storage size bytes.
    open func versionBlock() -> Data {
        // Defaults to NTAG215. Subclasses override.
        Data([0x00, 0x04, 0x04, 0x02, 0x01, 0x00, 0x11, 0x03])
    }
}

// MARK: - Config-page lookup per variant

enum ConfigLayout {
    struct Pages { let config0: Int
        let config1: Int
        let pwd: Int
        let pack: Int
    }

    /// Delegates to the canonical `Type2ConfigLayout` in HexNFCKit so the
    /// simulator and the production `CoreNFCConnectedTag` can never drift.
    static func configPages(for variant: Type2Variant) -> Pages? {
        guard let layout = Type2ConfigLayout.for(variant) else { return nil }
        return Pages(
            config0: layout.config0Page,
            config1: layout.config1Page,
            pwd: layout.pwdPage,
            pack: layout.packPage
        )
    }
}

// MARK: - Concrete NTAG215

public final class NTAG215Simulator: NTAG21xSimulator, @unchecked Sendable {
    public init(uid: Data = NTAG215Simulator.defaultUID, ndefMessage: Data? = nil) {
        super.init(
            variant: .ntag215,
            profile: ChipCatalog.require(.ntag215),
            uid: uid,
            ndefMessage: ndefMessage,
            signature: NTAG215Simulator.defaultSignature
        )
    }

    override public func versionBlock() -> Data {
        Data([0x00, 0x04, 0x04, 0x02, 0x01, 0x00, 0x11, 0x03])
    }

    public static let defaultUID: Data = .init([0x04, 0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6])

    /// Fixed-but-arbitrary signature so READ_SIG returns something stable in
    /// snapshot/unit tests. Real signatures are NXP-issued ECC.
    public static let defaultSignature: Data = .init((0 ..< 32).map { UInt8($0 ^ 0x5A) })
}
