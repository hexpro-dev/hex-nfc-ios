import Foundation
@testable import HexNFCKit
@testable import HexNFCRecords

/// MIFARE Ultralight C (MF0ICU2) simulator.
///
/// **Deliberately standalone rather than a subclass of `NTAG21xSimulator`.**
/// The two chips share a transport and a page size and almost nothing else that
/// matters here. Inheriting would silently grant this chip `GET_VERSION`,
/// `FAST_READ`, `READ_CNT`, `READ_SIG` and `PWD_AUTH`, and a simulator more
/// capable than its silicon is the exact failure this test suite exists to
/// prevent: the step passes in CI and fails on a tag. `GET_VERSION` is the
/// sharpest case, because its absence is *the* distinguishing property of this
/// chip and the reason a stack of these sat unidentified.
///
/// The whole command set is READ (`30h`), WRITE (`A2h`), COMPATIBILITY_WRITE
/// (`A0h`), AUTHENTICATE (`1Ah`) and HALT (`50h`) (rev 3.3 Table 14). Anything
/// else NAKs.
///
/// Reference: NXP MF0ICU2 rev 3.3. Page map §7.5 Table 5, delivery state
/// §7.5.10 Table 13, 3DES handshake §7.5.5 Table 8, key programming §7.5.7,
/// access configuration §7.5.8 Table 12. See `docs/internal/chip-config-pages.md`.
public final class MifareUltralightCSimulator: ChipSimulator, @unchecked Sendable {
    public let uid: Data
    public let profile: ChipProfile?

    /// Page-major memory, 48 pages of 4 bytes.
    public private(set) var pages: [Data]

    /// `true` once the 3DES handshake has completed this session. Cleared by
    /// `endSession()`, which is what makes protection latching observable
    /// across taps.
    public private(set) var isAuthenticated = false
    public private(set) var isLockedPermanent = false

    /// Counts completed handshakes, so a test can prove authentication actually
    /// happened rather than inferring it from a side effect.
    public private(set) var successfulAuthentications = 0
    public private(set) var failedAuthentications = 0

    /// The key the chip will actually authenticate against.
    ///
    /// Held separately from the key bytes in pages 2Ch–2Fh because the datasheet
    /// is explicit that "a re-programmed authentication key is only valid for
    /// authentication after a RF reset or a re-activation" (rev 3.3 §7.5.7
    /// remark). Modelling that is worth the extra field: without it a test could
    /// write a new key and authenticate with it in the same session, which real
    /// silicon refuses, and the harness would encode an ordering that only works
    /// in CI.
    private var activeKey: UltralightCKey

    /// Randomness for `RndB`. Injectable so a test can replay the datasheet's
    /// numerical example exactly.
    private let makeRandom: @Sendable (Int) -> Data

    /// In-flight handshake state between leg 1 and leg 2.
    private var pendingAuth: (rndB: Data, ekRndB: Data)?
    /// COMPATIBILITY_WRITE parks here between its two frames.
    private var pendingCompatibilityWrite: Int?

    public private(set) var isHalted = false

    public init(
        // A real UID from our stock (live capture 2026-08-07). Note it excludes
        // BCC0: the 7 UID bytes are SN0–SN2 then SN3–SN6, and page 0 byte 3 is
        // the check byte, which `deliveryState` computes.
        uid: Data = Data([0x04, 0xB8, 0xEC, 0xCA, 0x79, 0x77, 0x80]),
        key: UltralightCKey = .factoryDefault,
        ndefMessage: Data? = nil,
        makeRandom: @escaping @Sendable (Int) -> Data = { count in
            Data((0 ..< count).map { _ in UInt8.random(in: 0 ... 255) })
        }
    ) {
        precondition(uid.count == 7, "Ultralight C UID is 7 bytes")
        self.uid = uid
        profile = ChipCatalog.profile(for: .mifareUltralightC)
        activeKey = key
        self.makeRandom = makeRandom
        pages = Self.deliveryState(uid: uid, key: key)
        if let message = ndefMessage {
            // Seeding a message implies a formatted tag, which this chip is not
            // at delivery. Write the CC first so the fixture is coherent.
            pages[Self.ccPage] = profile?.factoryCC ?? Data([0xE1, 0x10, 0x12, 0x00])
            try? writeNDEF(NDEFEnvelope.wrap(message: message))
        }
    }

    // MARK: - Layout constants

    static let pageCount = 48
    static let ccPage = 3
    static let staticLockPage = 2
    static let lockBytes23Page = 40 // 0x28
    static let counterPage = 41 // 0x29

    // MARK: - Delivery state (rev 3.3 Table 13)

    /// The **factory state**, byte for byte. Getting this right is most of the
    /// simulator's value: our live captures on 2026-08-06 matched it on every
    /// readable page, so a future divergence is a real signal.
    static func deliveryState(uid: Data, key: UltralightCKey) -> [Data] {
        var pages = [Data](repeating: Data(repeating: 0x00, count: 4), count: pageCount)
        let sn = [UInt8](uid)
        let bcc0: UInt8 = 0x88 ^ sn[0] ^ sn[1] ^ sn[2]
        let bcc1: UInt8 = sn[3] ^ sn[4] ^ sn[5] ^ sn[6]
        pages[0] = Data([sn[0], sn[1], sn[2], bcc0])
        pages[1] = Data([sn[3], sn[4], sn[5], sn[6]])
        // Byte 1 is the "internal" byte; 48h on the real tags we captured.
        pages[2] = Data([bcc1, 0x48, 0x00, 0x00])
        // Page 3 (OTP / Capability Container) ships **blank**. Unlike NTAG21x,
        // Ultralight C is not NDEF-preformatted, which is what makes it the one
        // genuine `formatVirginCC` candidate in our stock.
        pages[ccPage] = Data([0x00, 0x00, 0x00, 0x00])
        // Pages 04h–27h: the datasheet says the delivery content is "not
        // defined" (§7.5.9), so zeros are a fixture choice, not a claim.
        pages[lockBytes23Page] = Data([0x00, 0x00, 0x00, 0x00])
        pages[counterPage] = Data([0x00, 0x00, 0x00, 0x00])
        pages[UltralightCLayout.auth0Page] = Data([UltralightCLayout.protectionOff, 0x00, 0x00, 0x00])
        pages[UltralightCLayout.auth1Page] = Data([0x00, 0x00, 0x00, 0x00])
        let keyBytes = [UInt8](key.memoryOrder)
        for (index, page) in UltralightCLayout.keyPages.enumerated() {
            pages[page] = Data(keyBytes[(index * 4) ..< (index * 4 + 4)])
        }
        return pages
    }

    // MARK: - Configuration

    public var configuration: UltralightCConfiguration {
        UltralightCConfiguration(
            auth0: pages[UltralightCLayout.auth0Page][pages[UltralightCLayout.auth0Page].startIndex],
            auth1: pages[UltralightCLayout.auth1Page][pages[UltralightCLayout.auth1Page].startIndex]
        )
    }

    /// The key currently stored in pages 2Ch–2Fh, which may differ from the one
    /// the chip authenticates against until the next activation.
    var storedKey: UltralightCKey? {
        var bytes = Data()
        for page in UltralightCLayout.keyPages {
            bytes += pages[page]
        }
        return try? UltralightCKey(memoryOrder: bytes)
    }

    /// End the RF session: drop authentication and latch any newly written key.
    /// Real readers achieve this by dropping the field; tests call it directly.
    /// A new activation is exactly this chip's existing end-of-session reset.
    /// See `ChipSimulator.beginActivation`.
    public func beginActivation() {
        endSession()
    }

    public func endSession() {
        isAuthenticated = false
        pendingAuth = nil
        pendingCompatibilityWrite = nil
        isHalted = false
        if let stored = storedKey {
            activeKey = stored
        }
    }

    // MARK: - Access control

    private func requiresAuth(page: Int) -> Bool {
        let config = configuration
        return config.isProtected && page >= Int(config.auth0)
    }

    private func canRead(page: Int) -> Bool {
        guard requiresAuth(page: page), configuration.readProtect else { return true }
        return isAuthenticated
    }

    private func canWrite(page: Int) -> Bool {
        guard !isLockedPermanent else { return false }
        if page < 2 {
            return false
        } // UID pages are read-only
        if isStaticLocked(page: page) {
            return false
        }
        if isDynamicLocked(page: page) {
            return false
        }
        guard requiresAuth(page: page) else { return true }
        return isAuthenticated
    }

    /// Static lock bytes at page 2 (bytes 2–3) cover pages 03h–0Fh
    /// (rev 3.3 §7.5.2 Table 6).
    private func isStaticLocked(page: Int) -> Bool {
        guard (3 ... 15).contains(page) else { return false }
        let lock = pages[Self.staticLockPage]
        let bits = (UInt16(lock[lock.startIndex + 3]) << 8) | UInt16(lock[lock.startIndex + 2])
        return (bits & (1 << UInt16(page))) != 0
    }

    /// Lock bytes 2–3 at page 28h cover 10h–27h in 4-page granularity plus the
    /// configuration area (rev 3.3 §7.5.3 Table 7). Modelled as "any bit set
    /// locks the region", which is enough for a lock to be observable without
    /// claiming per-bit fidelity we have not verified on silicon.
    private func isDynamicLocked(page: Int) -> Bool {
        guard page >= 16 else { return false }
        let lock = pages[Self.lockBytes23Page]
        return lock.prefix(2).contains { $0 != 0 }
    }

    // MARK: - ChipSimulator surface

    public func readMemory(range: Range<Int>) throws -> Data {
        guard range.lowerBound >= 0, range.upperBound <= Self.pageCount * 4 else {
            throw TagError.protocolError("read out of range \(range)")
        }
        var output = Data()
        let firstPage = range.lowerBound / 4
        let lastPage = (range.upperBound - 1) / 4
        for page in firstPage ... lastPage {
            guard isReadDecoded(page) else {
                throw TagError.protocolError(
                    "The tag refused a read",
                    diagnostics: "page=\(page) is not decoded for reads (key pages 2Ch–2Fh); "
                        + "real silicon NAKs this and the tag then HALTs"
                )
            }
            guard canRead(page: page) else {
                throw TagError.authFailed(
                    diagnostics: "page=\(page) requires 3DES authentication"
                )
            }
            output.append(pages[page])
        }
        let offset = range.lowerBound - firstPage * 4
        return output.subdata(in: offset ..< (offset + range.count))
    }

    /// Whether a plain READ may address this page at all.
    ///
    /// The key pages are not merely unreadable, they are **not decoded**: reads
    /// are decoded only up to page 2Bh, so `30 2C` returns a NAK rather than
    /// masked zeros. Live-confirmed 2026-08-07 (`30 2C` → `00`); the simulator
    /// originally modelled zeros, which understated the consequence, because a
    /// NAK returns a Type-2 tag to HALT for the rest of the activation. Any
    /// caller that walks to the end of memory therefore kills the session
    /// rather than coming up four pages short.
    private func isReadDecoded(_ page: Int) -> Bool {
        page < UltralightCLayout.readDecodedPageCount
    }

    public func writeMemory(at offset: Int, bytes: Data) throws {
        guard offset % 4 == 0, bytes.count % 4 == 0 else {
            throw TagError.protocolError("page-aligned writes only")
        }
        var page = offset / 4
        var cursor = bytes.startIndex
        while cursor < bytes.endIndex {
            guard page < Self.pageCount else {
                throw TagError.writeOverflow(needed: (page + 1) * 4, available: Self.pageCount * 4)
            }
            let incoming = bytes.subdata(in: cursor ..< (cursor + 4))
            guard canWrite(page: page) else {
                if isLockedPermanent || isStaticLocked(page: page) || isDynamicLocked(page: page) {
                    throw TagError.lockedPermanent(diagnostics: "page=\(page) locked")
                }
                if page < 2 {
                    throw TagError.protocolError(
                        "page \(page) is read-only (UID/serial)",
                        diagnostics: "WRITE NAK page=\(page)"
                    )
                }
                throw TagError.authFailed(
                    diagnostics: "page=\(page) requires 3DES authentication"
                )
            }
            applyWrite(page: page, incoming: incoming)
            page += 1
            cursor += 4
        }
    }

    /// One-way (OTP) cells behave as bitwise OR on real silicon, so the
    /// simulator must not "succeed" at clearing a bit hardware can only set.
    private func applyWrite(page: Int, incoming: Data) {
        let start = pages[page].startIndex
        let inStart = incoming.startIndex
        switch page {
        case Self.staticLockPage:
            // Bytes 0–1 (BCC1 / internal) are unaffected by a write; lock bytes
            // 2–3 are OR-only and irreversible (rev 3.3 §7.5.2).
            var p = pages[page]
            p[start + 2] |= incoming[inStart + 2]
            p[start + 3] |= incoming[inStart + 3]
            pages[page] = p

        case Self.ccPage:
            // OTP: bits OR in and can never be cleared (rev 3.3 §7.5.4).
            var p = pages[page]
            for i in 0 ..< 4 {
                p[start + i] |= incoming[inStart + i]
            }
            pages[page] = p

        case Self.lockBytes23Page:
            // Bytes 0–1 are lock bits (OR-only); bytes 2–3 are RFU and ignored.
            var p = pages[page]
            p[start] |= incoming[inStart]
            p[start + 1] |= incoming[inStart + 1]
            pages[page] = p

        default:
            pages[page] = incoming
        }
    }

    public func readNDEF() throws -> Data {
        let ndefStartPage = profile?.memoryLayout.ndefRange?.lowerBound ?? 4
        guard canRead(page: ndefStartPage) else {
            throw TagError.authFailed(
                diagnostics: "NDEF region is read-protected (AUTH0/AUTH1)"
            )
        }
        guard pages[Self.ccPage].first == 0xE1 else {
            throw TagError.capabilityUnsupported(
                .ndefRead,
                diagnostics: "no Capability Container at page \(Self.ccPage) — Ultralight C ships "
                    + "unformatted (rev 3.3 Table 13), so this is a valid factory state"
            )
        }
        let all = pages.reduce(Data()) { $0 + $1 }
        let userMemory = all.subdata(in: (ndefStartPage * 4) ..< all.endIndex)
        do {
            return try NDEFEnvelope.unwrap(userMemory)
        } catch NDEFEnvelope.ParseError.noNDEFTLV {
            return Data()
        }
    }

    public func writeNDEF(_ envelope: Data) throws {
        guard let range = profile?.memoryLayout.ndefRange else {
            throw TagError.protocolError("no ndef range in chip layout")
        }
        let capacity = (range.upperBound - range.lowerBound + 1) * 4
        guard envelope.count <= capacity else {
            throw TagError.writeOverflow(needed: envelope.count, available: capacity)
        }
        var padded = envelope
        while padded.count % 4 != 0 {
            padded.append(0x00)
        }
        // Exactly the pages the envelope occupies. This used to zero the rest of
        // the region, which is the opposite of what `writeNDEFViaPages` does on
        // the wire, so an erase here swept the region clean while an erase on
        // silicon left the old message behind the terminator. Same correction,
        // same reason, as `NTAG21xSimulator.writeNDEFRegion`.
        try writeMemory(at: range.lowerBound * 4, bytes: padded)
    }

    /// This chip has no `PWD_AUTH` (`1Bh`). Refusing rather than inheriting a
    /// working implementation is the point.
    public func authenticate(password: Data) throws -> Data {
        throw TagError.capabilityUnsupported(
            .passwordAuth,
            diagnostics: "Ultralight C has no PWD_AUTH (1Bh); it authenticates with a 16-byte "
                + "3DES key via AUTHENTICATE (1Ah). See rev 3.3 Table 14."
        )
    }

    public func setPassword(_ password: Data, pack: Data) throws {
        throw TagError.capabilityUnsupported(
            .passwordAuth,
            diagnostics: "Ultralight C has no PWD/PACK pages; use the 3DES key at 2Ch–2Fh."
        )
    }

    public func permanentLock() throws {
        guard !isLockedPermanent else { return }
        // Set every static lock bit and both lock bytes 2–3, mirroring what a
        // real LOCK write does. Irreversible by construction.
        var page2 = pages[Self.staticLockPage]
        page2[page2.startIndex + 2] = 0xFF
        page2[page2.startIndex + 3] = 0xFF
        pages[Self.staticLockPage] = page2
        var lock23 = pages[Self.lockBytes23Page]
        lock23[lock23.startIndex] = 0xFF
        lock23[lock23.startIndex + 1] = 0xFF
        pages[Self.lockBytes23Page] = lock23
        isLockedPermanent = true
    }

    /// Re-derive `isLockedPermanent` from the static lock bytes. See the sibling
    /// on `NTAG21xSimulator`: lock state is a consequence of the bytes, not a
    /// flag a helper sets.
    func refreshPermanentLockFlag() {
        let page = pages[Self.staticLockPage]
        guard page.count >= 4 else { return }
        if page[page.startIndex + 2] == 0xFF, page[page.startIndex + 3] == 0xFF {
            isLockedPermanent = true
        }
    }

    public func readProtectionState() throws -> TagProtection? {
        configuration.protection
    }

    // MARK: - Wire protocol

    /// Every command frame this simulator has been handed, in order.
    ///
    /// Exists so a test can assert what a plan *did not* send. On this chip the
    /// dangerous frames are the ones that get refused, and a refusal halts the
    /// tag, so "which commands were issued" is a safety property rather than a
    /// curiosity.
    public private(set) var receivedCommands: [Data] = []

    public func handle(command: Data) -> Data {
        receivedCommands.append(command)
        if let page = pendingCompatibilityWrite {
            pendingCompatibilityWrite = nil
            guard command.count >= 16 else { return nak() }
            let payload = command.subdata(in: command.startIndex ..< (command.startIndex + 4))
            do {
                try writeMemory(at: page * 4, bytes: payload)
                return Data([0x0A])
            } catch {
                return nak()
            }
        }
        guard let opcode = command.first else { return nak() }
        if isHalted {
            return nak()
        }

        switch opcode {
        case 0x30: // READ — 4 pages
            guard command.count >= 2 else { return nak() }
            return readPages(startPage: Int(command[command.startIndex + 1]))

        case 0xA2: // WRITE — one page
            guard command.count >= 6 else { return nak() }
            let page = Int(command[command.startIndex + 1])
            let data = command.subdata(in: (command.startIndex + 2) ..< (command.startIndex + 6))
            do {
                try writeMemory(at: page * 4, bytes: data)
                refreshPermanentLockFlag()
                return Data([0x0A])
            } catch {
                return nak()
            }

        case 0xA0: // COMPATIBILITY_WRITE — two frames
            guard command.count >= 2 else { return nak() }
            pendingCompatibilityWrite = Int(command[command.startIndex + 1])
            return Data([0x0A])

        case 0x50: // HALT
            isHalted = true
            return Data()

        case 0x1A: // AUTHENTICATE, leg 1
            return beginAuthentication()

        case UltralightCProtectionDriver.continueCommand: // AF — leg 2
            return completeAuthentication(command)

        default:
            // Everything else NAKs, and the list of what lands here is the
            // point of this chip: GET_VERSION (60h), FAST_READ (3Ah),
            // READ_SIG (3Ch), READ_CNT (39h), PWD_AUTH (1Bh).
            return nak()
        }
    }

    /// READ returns four pages and **rolls over** past the last one, the
    /// documented Ultralight-family behaviour.
    ///
    /// Roll-over specifically at 2Fh is inherited family behaviour rather than
    /// something we have confirmed on this die; it is on the live-validation
    /// checklist. Nothing in the app depends on it.
    /// A read whose **start address** is undecoded NAKs, and that NAK halts the
    /// tag. Modelling the halt is the point: the memory dump and an earlier
    /// version of the harness plan both walked into it.
    ///
    /// Roll-over is modelled within the *decoded* region (00h–2Bh), which is the
    /// Ultralight family's documented wrap applied to the addresses this chip
    /// actually decodes. **Not separately verified on silicon** — the live
    /// capture only established that a read *starting* at 2Ch NAKs. Nothing in
    /// the app depends on it: every read we issue stays inside the decoded
    /// region by construction, which is why `readConfiguration` starts at 28h
    /// rather than at AUTH0.
    private func readPages(startPage: Int) -> Data {
        guard isReadDecoded(startPage) else { return nak() }
        var output = Data()
        for offset in 0 ..< 4 {
            let page = (startPage + offset) % UltralightCLayout.readDecodedPageCount
            guard canRead(page: page) else { return nak() }
            output.append(pages[page])
        }
        return output
    }

    // MARK: - 3DES handshake (rev 3.3 §7.5.5)

    private func beginAuthentication() -> Data {
        // A second handshake in one activation is refused. The card has no way
        // to report "already authenticated", so this is a plain NAK, and the NAK
        // halts the tag. Live-confirmed 2026-08-07: after a successful
        // `ulc.auth`, the next step's `1A 00` returned one byte and every
        // command after that failed with "tag connection lost".
        //
        // Callers avoid this by remembering, via `UltralightCSessionHolder`.
        guard !isAuthenticated else { return nak() }
        let rndB = makeRandom(8)
        let zeroIV = Data(repeating: 0, count: 8)
        guard let ekRndB = try? EMRTDCrypto.tripleDESCBCEncrypt(
            key: activeKey.cipherOrder, iv: zeroIV, data: rndB
        ) else { return nak() }
        pendingAuth = (rndB: rndB, ekRndB: ekRndB)
        return Data([UltralightCProtectionDriver.continueCommand]) + ekRndB
    }

    private func completeAuthentication(_ command: Data) -> Data {
        guard let pending = pendingAuth else { return nak() }
        pendingAuth = nil
        guard command.count >= 17 else { return nak() }
        let token = Data(command.dropFirst().prefix(16))

        guard let plain = try? EMRTDCrypto.tripleDESCBCDecrypt(
            key: activeKey.cipherOrder, iv: pending.ekRndB, data: token
        ) else {
            failedAuthentications += 1
            return nak()
        }
        let rndA = Data(plain.prefix(8))
        let rndBPrime = Data(plain.suffix(8))

        // The card verifies the reader knows RndB before it reveals anything.
        guard rndBPrime == NTAG424Crypto.rotateLeftByOne(pending.rndB) else {
            failedAuthentications += 1
            return nak()
        }

        // IV chains from the last ciphertext block the reader sent.
        let chainIV = Data(token.suffix(8))
        guard let ekRndAPrime = try? EMRTDCrypto.tripleDESCBCEncrypt(
            key: activeKey.cipherOrder, iv: chainIV,
            data: NTAG424Crypto.rotateLeftByOne(rndA)
        ) else { return nak() }

        isAuthenticated = true
        successfulAuthentications += 1
        return Data([0x00]) + ekRndAPrime
    }

    /// **Every NAK halts the tag.** ISO/IEC 14443-3: a Type-2 tag that refuses a
    /// command returns to HALT and answers nothing else on that activation,
    /// until a WUPA re-activates it.
    ///
    /// This was originally a bare `Data([0x00])` with no state change, which
    /// made the simulator strictly more permissive than the silicon: a plan
    /// could send an unsupported command, see a NAK, carry on, and pass in CI —
    /// while on a real tag every following step failed with "tag connection
    /// lost". That is exactly what happened on 2026-08-07: `ulc.identify` sent
    /// GET_VERSION to *assert* that this chip refuses it, CI was happy, and the
    /// live run died at the very next step.
    ///
    /// Modelling the halt is what makes "the simulator proves protocol shape"
    /// mean anything for this chip, because refusing commands is most of what
    /// it does.
    private func nak() -> Data {
        isHalted = true
        return Data([0x00])
    }
}
