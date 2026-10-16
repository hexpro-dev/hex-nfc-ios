import Foundation
@testable import HexNFCKit
@testable import HexNFCRecords

/// NXP ICODE SLIX2 (SL2S2602 rev 4.2) + generic ISO/IEC 15693-3 (NFC
/// Forum Type 5) simulator. ISO 15693 is block-addressed (28 × 4-byte
/// blocks for SLIX2) rather than page-addressed, and every command is
/// **Flag-prefixed** (`flag` is the leading byte before the opcode). All
/// presets in `CommandPresetCatalog.type5Iso15693` use flag `0x02` —
/// "high data rate, no addressing".
///
/// **Why SLIX2 rather than plain SLIX**: the plain ICODE SLIX (SL2S2002)
/// only supports a single EAS/AFI password — no privacy mode, no destroy.
/// SLIX2 adds Read, Write, Privacy, and Destroy passwords plus the
/// `ENABLE_PRIVACY` / `DESTROY` opcodes. Since this simulator exposes
/// that wider feature surface, the right reference chip is SLIX2.
///
/// Implemented opcodes:
///
/// **ISO 15693-3 core (§9.3):**
///   - `0x20 READ_SINGLE_BLOCK`
///   - `0x21 WRITE_SINGLE_BLOCK`
///   - `0x22 LOCK_BLOCK`
///   - `0x23 READ_MULTIPLE_BLOCKS`
///   - `0x27 WRITE_AFI`        / `0x28 LOCK_AFI`
///   - `0x29 WRITE_DSFID`      / `0x2A LOCK_DSFID`
///   - `0x2B GET_SYSTEM_INFORMATION`
///   - `0x2C GET_MULTIPLE_BLOCK_SECURITY_STATUS`
///
/// **ICODE SLIX2 manufacturer-specific (CLA `0xE0` in the wire format —
/// the simulator accepts them with or without the 0xE0 prefix to keep
/// command syntax tractable from the advanced console):**
///   - `0xB2 GET_RANDOM_NUMBER`              (§9.5.3.1)
///   - `0xB3 SET_PASSWORD`                   (§9.5.3.2)
///   - `0xB4 WRITE_PASSWORD`                 (§9.5.3.3)
///   - `0xB5 LOCK_PASSWORD`                  (§9.5.3.4)
///   - `0xBA ENABLE_PRIVACY`                 (§9.5.3.9) — XOR'd Privacy
///                                            password supplied inline
///   - `0xB9 DESTROY`                        (§9.5.3.8) — XOR'd Destroy
///                                            password supplied inline,
///                                            terminal once accepted
///
/// **Password protection is intentionally NOT exposed via the high-level
/// `enablePasswordProtection` / `disablePasswordProtection` protocol methods.**
/// Those model the NTAG21x (Type-2) scheme — a single 4-byte PWD + 2-byte PACK
/// gated by an AUTH0 page threshold and a PROT bit. SLIX2 is a different world:
/// up to five independent passwords (read / write / privacy / destroy / EAS-AFI),
/// a challenge-response handshake (`GET_RANDOM_NUMBER` → XOR-masked `SET_PASSWORD`),
/// and block-level security status — none of which maps onto the Type-2 signature.
/// This simulator therefore inherits the default protocol implementation (which
/// throws `.capabilityUnsupported(.passwordAuth)`), and the app gates the
/// protection UI on the **Type-2 family**, not the `.passwordAuth` capability
/// alone (which ICODE SLIX also advertises). Drive SLIX privacy/auth via the
/// `SET_PASSWORD` / `ENABLE_PRIVACY` opcodes above, or the `authenticate` /
/// `setPassword` convenience methods, which map onto that handshake.
public final class Iso15693Simulator: ChipSimulator, @unchecked Sendable {
    public let uid: Data
    public let profile: ChipProfile?

    public private(set) var blocks: [Data]
    public private(set) var blockLocks: [Bool]
    public private(set) var afi: UInt8 = 0x00
    public private(set) var afiLocked = false
    public private(set) var dsfid: UInt8 = 0x00
    public private(set) var dsfidLocked = false
    /// **Every password exists from delivery** (SL2S2602 §9.2.3): `00` bytes for
    /// read/write/EAS-AFI, `0F` bytes for privacy/destroy. There is no "unset"
    /// state, and modelling one is what let `enable` ship a `SET_PASSWORD` that
    /// assigned rather than authenticated — green here, refused on silicon.
    public private(set) var passwords: [PasswordKind: Data] = [
        .read: Data(repeating: 0x00, count: 4),
        .write: Data(repeating: 0x00, count: 4),
        .easAfi: Data(repeating: 0x00, count: 4),
        .privacy: Data(repeating: 0x0F, count: 4),
        .destroy: Data(repeating: 0x0F, count: 4),
    ]

    /// Protection pointer and access conditions, set by `PROTECT PAGE` (B6h).
    /// **This is the gate**, not the presence of a password. Delivered ICs are
    /// Public: pointer 0, status 0.
    public private(set) var protectionPointer: UInt8 = 0
    public private(set) var pageProtection: UInt8 = 0
    public private(set) var passwordLocked: [PasswordKind: Bool] = [:]
    public private(set) var privacyMode = false
    public private(set) var destroyed = false

    /// `LOCK PAGE PROTECTION CONDITION` (B7h, §9.5.3.7) has frozen the access
    /// conditions. **Set by tests only**: this app never sends B7h, so no
    /// command here can set it, and inventing one would be inventing silicon.
    /// It exists so the "another reader froze this tag" branch of the ABh
    /// read-back has something to read.
    public var pageProtectionConditionLocked = false

    /// `true` once a *write* password has been set — writes are then refused
    /// unless `writeUnlocked` (the SLIX2 write-protection model). `writeUnlocked`
    /// is per-tap: set when the write password is set/presented, cleared on a
    /// fresh tap (`endSession`).
    /// Count of `WRITE_SINGLE_BLOCK` frames the chip actually accepted.
    ///
    /// Test observability, not silicon behaviour: a self-write (writing a block
    /// back its own bytes) leaves memory identical, so comparing contents can
    /// never prove a run didn't write. Only a counter can.
    public private(set) var acceptedWrites = 0

    public private(set) var writePasswordSet = false
    private var writeUnlocked = false

    /// Password kinds whose current value has been presented via `SET_PASSWORD`
    /// this tap. `WRITE_PASSWORD` requires this on real silicon. Per-tap: cleared
    /// by `endSession()`.
    private var verifiedPasswords: Set<PasswordKind> = []

    /// The tag is in the Selected state (a `SELECT`, 0x25, named it). Gated
    /// commands (`Iso15693Opcode.requiresAddressedOrSelectedMode`) are processed
    /// only in Addressed or Selected mode; outside those the chip **ignores**
    /// them (§9.5.3.2/3.3) — no error frame, no NAK, nothing. That silence is
    /// what every non-addressed `SET_PASSWORD` drew on real silicon on
    /// 2026-08-07 while this simulator answered them happily. Per-tap: selection
    /// ends when the tag leaves the field (`endSession()`).
    public private(set) var isSelected = false

    /// "If the IC receives an invalid password, it will not execute any
    /// following command until a Power-On Reset (POR) (RF reset) is executed"
    /// (§9.5.3.2). Modelled as silence on every subsequent frame; cleared by
    /// `endSession()` (the POR). This is why no flow may retry a failed
    /// password in-session.
    public private(set) var poisoned = false

    /// Pending random number for the next SET_PASSWORD challenge. The
    /// simulator emits a deterministic random in `handleGetRandom`, then
    /// SET_PASSWORD XORs against it.
    private var pendingRandom: Data = .init([0x00, 0x00])

    public enum PasswordKind: Hashable, Sendable {
        case read
        case write
        case privacy
        case destroy
        case easAfi
    }

    /// - Parameters:
    ///   - blockCount: 28 (a plain ICODE SLIX) by default. A real SLIX2 reports
    ///     80 blocks; pass that to exercise the geometry path.
    ///   - virgin: `true` seeds every block zero — **the state a factory ICODE
    ///     ships in**, with no Capability Container at all. The default (`false`)
    ///     seeds an NDEF-formatted tag. Modelling only the formatted state is what
    ///     hid the missing Type-5 formatter: CoreNFC refuses a content NDEF write
    ///     to an unformatted tag, but the simulator was never in that state.
    public init(
        uid: Data = Iso15693Simulator.defaultUID,
        blockCount: Int = 28,
        virgin: Bool = false
    ) {
        precondition(uid.count == 8, "ISO 15693 UID is 8 bytes (E0 + 7)")
        precondition(blockCount >= 2, "need at least CC + 1 NDEF block")
        self.uid = uid
        // Build the profile through the **production** decode path, from the same
        // self-reported geometry this simulator serves over
        // GET_SYSTEM_INFORMATION. `ISO15693TagIdentifier` does exactly this on a
        // live tap, so an 80-block SLIX2 gets an 80-block profile here too —
        // pinning the profile to the catalog's 28-block SLIX estimate would make
        // the simulator describe a tag it isn't.
        profile = ChipCatalog.iso15693Profile(
            icManufacturerCode: 0x04,
            systemInfo: ISO15693SystemInfo(
                blockSize: 4,
                blockCount: blockCount,
                icReference: Iso15693Simulator.icReference
            )
        )
        var seed = Array(repeating: Data(repeating: 0x00, count: 4), count: blockCount)
        if !virgin {
            // NFC Forum Type 5 Capability Container at block 0, built by the
            // production helper so the simulator can never disagree with what the
            // app's own `format` writes. For a 28-block × 4-byte SLIX that is
            // E1 40 0D 09 — MLEN 13, addressing 104 of the 108 post-CC bytes.
            seed[0] = Type5CC.bytes(blockCount: blockCount, blockSize: 4)
                ?? Data(repeating: 0x00, count: 4)
            // Empty NDEF TLV + terminator at block 1 so the tag reports as
            // "Type 5 NDEF, no message" rather than "malformed".
            seed[1] = Type5CC.emptyNDEFTLV
        }
        blocks = seed
        blockLocks = Array(repeating: false, count: blockCount)
    }

    /// A protection-capable chip, said at the call site rather than left to a
    /// magic block count. 80 blocks is the only ICODE geometry that is
    /// unambiguously SLIX2, and the only one this app offers protection to:
    /// 28 blocks is shared by the SLI, SLIX, SLIX-S and SLIX-L, and the SLI has
    /// no password machinery at all.
    public static func slix2(
        uid: Data = Iso15693Simulator.defaultUID,
        virgin: Bool = false
    ) -> Iso15693Simulator {
        Iso15693Simulator(uid: uid, blockCount: 80, virgin: virgin)
    }

    /// IC-reference byte reported by GET_SYSTEM_INFORMATION.
    ///
    /// **Confirmed against real silicon (2026-08-05):** an ICODE SLIX2 reporting
    /// 80 blocks × 4 B answered IC reference `0x01` — matching the value this
    /// simulator had guessed. One capture is not a mapping, though: this byte is
    /// the SLIX / SLIX2 / SLIX-S / SLIX-L discriminator, and
    /// `ChipCatalog.iso15693Profile` still declines to assert a variant until a
    /// plain SLIX (and ideally SLIX-S/L) has been captured for comparison.
    public static let icReference: UInt8 = 0x01

    /// Capability Container size in bytes (4 = 1-byte block addressing).
    /// `0xE2` magic byte in block 0 byte 0 indicates 8-byte CC and is not
    /// emitted by SLIX; we leave the constant here for chips that use it.
    public var ccSize: Int {
        4
    }

    // MARK: - Command dispatch

    public func handle(command: Data) -> Data {
        // Once destroyed every command returns the ISO 15693 error code.
        if destroyed {
            return Self.errorResponse(.commandNotRecognized)
        }
        // Strip optional CLA byte for manufacturer-specific commands. Real
        // ISO 15693 wire format is `Flag [0xE0 manufacturer] Cmd`; we
        // accept either.
        let normalised = strippedManufacturerPrefix(command)
        guard normalised.count >= 2 else { return Self.errorResponse(.commandNotRecognized) }
        let flags = normalised[normalised.startIndex]
        let opcode = normalised[normalised.startIndex + 1]

        // Invalid password received earlier this tap → the chip executes
        // nothing until a Power-On Reset (§9.5.3.2). Silence, not an error.
        if poisoned {
            return Data()
        }

        // SL2S2602 §9.5.3.9: a label in privacy mode "does not respond to any
        // command except GET RANDOM NUMBER and SET PASSWORD", and cannot be
        // inventoried. **Silence, not an error frame**, which is the shape the
        // addressing-mode violation below already models, and the documented
        // absence of a response rather than an invented refusal code.
        //
        // This simulator used to answer SELECT, READ and every other frame in
        // privacy mode, which made a privacy tag look recoverable in CI while
        // no iPhone could reach one at all. That is the exact class of
        // divergence the 2026-08-07 campaign cost, so the gate is here rather
        // than scattered across the individual handlers.
        if privacyMode {
            let isPrivacySetPassword = opcode == 0xB3
                && normalised.count >= 3
                && normalised[normalised.startIndex + 2] == 0x04
            guard opcode == 0xB2 || isPrivacySetPassword else { return Data() }
        }

        // A Select-flagged frame names "the tag in the Selected state". If this
        // tag is not it, the frame is not for this tag: silence.
        if flags & 0x10 != 0, !isSelected, opcode != 0x25 {
            return Data()
        }

        // `SELECT` moves the tag to the Selected state. On the wire this frame
        // is *addressed* (UID present, built by nfcd via `iso.select`); the
        // abstraction here matches the transport's, where UID management is
        // invisible to the driver.
        if opcode == 0x25 {
            isSelected = true
            return Data([0x00])
        }

        // Commands the chip honours only in Addressed or Selected mode are
        // **ignored** outside those modes — the exact live failure of
        // 2026-08-07, which this simulator hid by answering them in any mode.
        let addressedOrSelected = (flags & 0x20 != 0) || (flags & 0x10 != 0 && isSelected)
        if Iso15693Opcode.requiresAddressedOrSelectedMode(
            opcode: opcode, params: [UInt8](normalised.dropFirst(2))
        ), !addressedOrSelected {
            return Data()
        }

        // Reject a manufacturer command whose parameter count is wrong, instead
        // of parsing what it can and ignoring the rest. Real silicon does not
        // answer a malformed frame at all — live-confirmed 2026-08-07, when
        // `02 B2 04` (GET_RANDOM_NUMBER takes no parameters) drew silence from
        // an ICODE SLIX while this simulator answered it happily. A simulator
        // more permissive than the chip is the exact failure this harness
        // exists to catch.
        if let expected = Iso15693Opcode.customParameterCount(for: opcode),
           normalised.count - 2 != expected
        {
            return Self.errorResponse(.invalidFormat)
        }

        switch opcode {
        case 0x20: return handleReadSingleBlock(normalised)
        case 0x21: return handleWriteSingleBlock(normalised)
        case 0x22: return handleLockBlock(normalised)
        case 0x23: return handleReadMultipleBlocks(normalised)
        case 0x27: return handleWriteAFI(normalised)
        case 0x28: return handleLockAFI(normalised)
        case 0x29: return handleWriteDSFID(normalised)
        case 0x2A: return handleLockDSFID(normalised)
        case 0x2B: return handleGetSystemInformation(normalised)
        case 0x2C: return handleGetMultipleBlockSecurityStatus(normalised)
        case 0xAB: return answersNXPSystemInformation ? handleGetNXPSystemInformation() : Data()
        case 0xB2: return handleGetRandomNumber()
        case 0xB3: return handleSetPassword(normalised)
        case 0xB4: return handleWritePassword(normalised)
        case 0xB5: return handleLockPassword(normalised)
        case 0xB6: return handleProtectPage(normalised)
        case 0xB9: return handleDestroy(normalised)
        case 0xBA: return handleEnablePrivacy(normalised)
        default: return Self.errorResponse(.commandNotRecognized)
        }
    }

    // MARK: - ISO 15693 core

    private func handleReadSingleBlock(_ cmd: Data) -> Data {
        // Flag, 0x20, blockIndex
        guard cmd.count >= 3 else { return Self.errorResponse(.invalidFormat) }
        let index = Int(cmd[cmd.startIndex + 2])
        guard index < blocks.count else { return Self.errorResponse(.blockNotAvailable) }
        var response = Data([0x00]) // success flag
        response.append(blocks[index])
        return response
    }

    private func handleWriteSingleBlock(_ cmd: Data) -> Data {
        // Flag, 0x21, blockIndex, 4 bytes
        guard cmd.count >= 7 else { return Self.errorResponse(.invalidFormat) }
        let index = Int(cmd[cmd.startIndex + 2])
        guard index < blocks.count else { return Self.errorResponse(.blockNotAvailable) }
        if blockLocks[index] {
            return Self.errorResponse(.blockLocked)
        }
        // SLIX2 gates writes on the PROTECT PAGE access conditions (§9.5.3.6),
        // not on a password existing. A tag with a password set but Public
        // access conditions accepts every write.
        if isWriteProtected(block: index), !writeUnlocked {
            return Self.errorResponse(.passwordRequired)
        }
        let payload = cmd.subdata(in: (cmd.startIndex + 3) ..< (cmd.startIndex + 7))
        blocks[index] = payload
        acceptedWrites += 1
        return Data([0x00])
    }

    private func handleLockBlock(_ cmd: Data) -> Data {
        guard cmd.count >= 3 else { return Self.errorResponse(.invalidFormat) }
        let index = Int(cmd[cmd.startIndex + 2])
        guard index < blocks.count else { return Self.errorResponse(.blockNotAvailable) }
        // "Block 79 of the user memory contains the 16-bit counter feature and
        // cannot be locked" (§9.5.2.3). Live 2026-08-07: LOCK_BLOCK 4F drew
        // `01 0F` after 00–4E all locked — and this simulator's unconditional
        // ACK is what let the production loop reach it.
        if index == Iso15693Opcode.counterBlock(for: profile?.id, blockCount: blocks.count) {
            return Self.errorResponse(.blockNotLockable)
        }
        // Re-locking a locked block is a refusal (§9.6.3.2), not a no-op —
        // and since the chip only ever says `0F`, a caller cannot tell it
        // from a real failure. Idempotency has to come from checking the
        // security status first, which is what `permanentLock` now does.
        if blockLocks[index] {
            return Self.errorResponse(.blockLocked)
        }
        blockLocks[index] = true
        return Data([0x00])
    }

    private func handleReadMultipleBlocks(_ cmd: Data) -> Data {
        // Flag, 0x23, firstBlock, countMinusOne
        guard cmd.count >= 4 else { return Self.errorResponse(.invalidFormat) }
        let start = Int(cmd[cmd.startIndex + 2])
        let count = Int(cmd[cmd.startIndex + 3]) + 1
        guard start + count <= blocks.count else { return Self.errorResponse(.blockNotAvailable) }
        var response = Data([0x00])
        for i in 0 ..< count {
            response.append(blocks[start + i])
        }
        return response
    }

    private func handleWriteAFI(_ cmd: Data) -> Data {
        guard cmd.count >= 3 else { return Self.errorResponse(.invalidFormat) }
        if afiLocked {
            return Self.errorResponse(.blockLocked)
        }
        afi = cmd[cmd.startIndex + 2]
        return Data([0x00])
    }

    private func handleLockAFI(_ cmd: Data) -> Data {
        afiLocked = true
        return Data([0x00])
    }

    private func handleWriteDSFID(_ cmd: Data) -> Data {
        guard cmd.count >= 3 else { return Self.errorResponse(.invalidFormat) }
        if dsfidLocked {
            return Self.errorResponse(.blockLocked)
        }
        dsfid = cmd[cmd.startIndex + 2]
        return Data([0x00])
    }

    private func handleLockDSFID(_ cmd: Data) -> Data {
        dsfidLocked = true
        return Data([0x00])
    }

    private func handleGetSystemInformation(_ cmd: Data) -> Data {
        // Response: flag(1) infoFlags(1) UID(8) DSFID(1) AFI(1) memSize(2) ICReference(1)
        var response = Data([0x00])
        response.append(0x0F) // bits: DSFID + AFI + memSize + ICRef all present
        response.append(uid)
        response.append(dsfid)
        response.append(afi)
        // Memory size: low byte = (blockCount-1), high byte = blockSize-1 (3 for 4-byte).
        response.append(UInt8(blocks.count - 1))
        response.append(0x03)
        response.append(Self.icReference)
        return response
    }

    private func handleGetMultipleBlockSecurityStatus(_ cmd: Data) -> Data {
        // Flag, 0x2C, firstBlock, countMinusOne — returns flag + per-block lock byte.
        guard cmd.count >= 4 else { return Self.errorResponse(.invalidFormat) }
        let start = Int(cmd[cmd.startIndex + 2])
        let count = Int(cmd[cmd.startIndex + 3]) + 1
        guard start + count <= blocks.count else { return Self.errorResponse(.blockNotAvailable) }
        var response = Data([0x00])
        for i in 0 ..< count {
            response.append(blockLocks[start + i] ? 0x01 : 0x00)
        }
        return response
    }

    // MARK: - ICODE SLIX manufacturer-specific

    /// `GET NXP SYSTEM INFORMATION` (ABh, §9.5.3.18), Table 71:
    /// `00 ‖ PP pointer ‖ PP conditions ‖ lock bits ‖ feature flags(4)`.
    ///
    /// Serves the simulator's *real* protection state, so a client that arms
    /// `PROTECT PAGE` and reads it back here is verifying something rather
    /// than being told what it wants to hear.
    /// Whether this chip answers `ABh` GET NXP SYSTEM INFORMATION at all.
    ///
    /// `false` for the 28-block geometry, and modelled because a live plain
    /// ICODE SLIX (`E0:04:01:53:16:6A:F8:A2`, 2026-09-09) answered nothing to
    /// `02 AB`: the trace recorded a transport failure with no tag-response
    /// code, not a refusal. That silence is the whole reason
    /// `readProtectionState`'s write-probe fallback existed unexercised in CI,
    /// because a simulator that answers `ABh` for every geometry can never reach
    /// it. Scoped to what the capture showed, and to nothing else: an empty
    /// reply here, never an invented error code.
    var answersNXPSystemInformation: Bool {
        blocks.count > 28
    }

    private func handleGetNXPSystemInformation() -> Data {
        // Lock-bits byte: bit 0 AFI locked, bit 1 EAS locked, bit 2 DSFID
        // locked, bit 3 PP condition locked.
        //
        // ⚠️ The bit-3 assignment is **not verified** against SL2S2602 Table 71.
        // It is modelled here so the "another reader froze the conditions" state
        // is reachable in a test, and production reads it back but deliberately
        // refuses nothing on the strength of it. See
        // `Iso15693ProtectionClient.Type5GateState.pageProtectionConditionLocked`.
        var lockBits: UInt8 = 0
        if afiLocked {
            lockBits |= 0x01
        }
        if dsfidLocked {
            lockBits |= 0x04
        }
        if pageProtectionConditionLocked {
            lockBits |= 0x08
        }
        return Data([0x00, protectionPointer, pageProtection, lockBits, 0x00, 0x00, 0x00, 0x00])
    }

    private func handleGetRandomNumber() -> Data {
        // Deterministic 16-bit "random" so tests reproduce SET_PASSWORD round-trips.
        pendingRandom = Data([0xC0, 0xDE])
        var response = Data([0x00])
        response.append(pendingRandom)
        return response
    }

    private func handleSetPassword(_ cmd: Data) -> Data {
        // Flag, 0xB3, passwordIdentifier, 4 bytes XOR (password XOR (random || random))
        guard cmd.count >= 7 else { return Self.errorResponse(.invalidFormat) }
        let kind = passwordKind(for: cmd[cmd.startIndex + 2])
        let xored = cmd.subdata(in: (cmd.startIndex + 3) ..< (cmd.startIndex + 7))
        // Real chip: password = xored XOR (random || random) — i.e. the
        // 2-byte random is doubled to 4 bytes for the XOR mask.
        let mask = Data([
            pendingRandom[pendingRandom.startIndex + 0],
            pendingRandom[pendingRandom.startIndex + 1],
            pendingRandom[pendingRandom.startIndex + 0],
            pendingRandom[pendingRandom.startIndex + 1],
        ])
        let plaintext = NTAG424Crypto.xor(xored, mask)
        // Always a comparison. A delivered IC has every password defined, so
        // there is no branch where an arbitrary value is accepted and stored.
        guard let expected = passwords[kind] else { return Self.errorResponse(.passwordRequired) }
        if plaintext == expected {
            verifiedPasswords.insert(kind)
            if kind == .privacy {
                privacyMode = false
            }
            if kind == .write {
                writeUnlocked = true
            } // presented correctly → unlock this tap
            return Data([0x00])
        }
        // "If the IC receives an invalid password, it will not execute any
        // following command until a Power-On Reset" (§9.5.3.2). The refusal
        // itself is answered (Table 14 defines the error response); everything
        // after it draws silence until `endSession()`.
        poisoned = true
        return Self.errorResponse(.passwordRequired)
    }

    private func handleWritePassword(_ cmd: Data) -> Data {
        // Flag, 0xB4, passwordIdentifier, 4-byte new password.
        guard cmd.count >= 7 else { return Self.errorResponse(.invalidFormat) }
        let kind = passwordKind(for: cmd[cmd.startIndex + 2])
        if passwordLocked[kind] == true {
            return Self.errorResponse(.blockLocked)
        }
        // Real silicon requires the current password to have been presented via
        // SET_PASSWORD **this tap** before it will accept a new one. Accepting
        // unconditionally would let `Iso15693ProtectionClient.disable` pass here
        // even if its SET_PASSWORD leg silently failed — exactly the kind of
        // false green this simulator exists to prevent.
        guard verifiedPasswords.contains(kind) else {
            return Self.errorResponse(.passwordRequired)
        }
        let newPassword = cmd.subdata(in: (cmd.startIndex + 3) ..< (cmd.startIndex + 7))
        passwords[kind] = newPassword
        // The new password has not been presented, so it must be re-verified
        // before it can be changed again.
        verifiedPasswords.remove(kind)
        if kind == .write {
            writeUnlocked = false
        }
        return Data([0x00])
    }

    /// Whether `block` falls in a page whose write access is gated.
    private func isWriteProtected(block: Int) -> Bool {
        let inPageH = UInt8(clamping: block) >= protectionPointer
        let bit: UInt8 = inPageH ? (1 << 5) : (1 << 1)
        return pageProtection & bit != 0
    }

    /// `PROTECT PAGE` (B6h, §9.5.3.6): pointer address + extended protection
    /// status. Requires the read and write passwords to have been presented.
    private func handleProtectPage(_ cmd: Data) -> Data {
        // Flag, 0xB6, pointerAddress, extendedProtectionStatus
        guard cmd.count >= 4 else { return Self.errorResponse(.invalidFormat) }
        let pointer = cmd[cmd.startIndex + 2]
        let status = cmd[cmd.startIndex + 3]
        // "block 79 ... is excluded" — the pointer tops out at 0x4E (§9.5.3.6).
        guard pointer <= 0x4E else { return Self.errorResponse(.blockNotAvailable) }
        // RFU bits must be clear (Table 29).
        guard status & 0xCC == 0 else { return Self.errorResponse(.invalidFormat) }
        guard verifiedPasswords.contains(.read), verifiedPasswords.contains(.write) else {
            return Self.errorResponse(.passwordRequired)
        }
        protectionPointer = pointer
        pageProtection = status
        // Arming does not lock the current tap out of its own writes.
        writeUnlocked = true
        return Data([0x00])
    }

    private func handleLockPassword(_ cmd: Data) -> Data {
        guard cmd.count >= 3 else { return Self.errorResponse(.invalidFormat) }
        let kind = passwordKind(for: cmd[cmd.startIndex + 2])
        passwordLocked[kind] = true
        return Data([0x00])
    }

    private func handleEnablePrivacy(_ cmd: Data) -> Data {
        // SLIX2 §9.5.3.9: ENABLE_PRIVACY carries the XOR'd Privacy
        // password inline. The IC verifies against the EEPROM-stored
        // password before flipping the privacy bit. If the Privacy
        // password has not yet been set in EEPROM (no prior SET_PASSWORD),
        // the IC rejects.
        // Wire: Flag, 0xBA, XorPwd[4]
        guard cmd.count >= 6 else { return Self.errorResponse(.invalidFormat) }
        guard let stored = passwords[.privacy] else {
            return Self.errorResponse(.passwordRequired)
        }
        let xored = cmd.subdata(in: (cmd.startIndex + 2) ..< (cmd.startIndex + 6))
        let mask = doubledRandomMask()
        let plaintext = NTAG424Crypto.xor(xored, mask)
        guard plaintext == stored else { return Self.errorResponse(.passwordRequired) }
        privacyMode = true
        return Data([0x00])
    }

    private func handleDestroy(_ cmd: Data) -> Data {
        // SLIX2 §9.5.3.8: DESTROY carries the XOR'd Destroy password
        // inline; once accepted the IC is permanently bricked.
        // Wire: Flag, 0xB9, XorPwd[4]
        guard cmd.count >= 6 else { return Self.errorResponse(.invalidFormat) }
        guard let stored = passwords[.destroy] else {
            return Self.errorResponse(.passwordRequired)
        }
        let xored = cmd.subdata(in: (cmd.startIndex + 2) ..< (cmd.startIndex + 6))
        let mask = doubledRandomMask()
        let plaintext = NTAG424Crypto.xor(xored, mask)
        guard plaintext == stored else { return Self.errorResponse(.passwordRequired) }
        destroyed = true
        return Data([0x00])
    }

    /// SLIX/SLIX2 XOR pad — the 2-byte `pendingRandom` doubled to 4
    /// bytes: `random[0], random[1], random[0], random[1]` (§9.5.3.2).
    private func doubledRandomMask() -> Data {
        Data([
            pendingRandom[pendingRandom.startIndex + 0],
            pendingRandom[pendingRandom.startIndex + 1],
            pendingRandom[pendingRandom.startIndex + 0],
            pendingRandom[pendingRandom.startIndex + 1],
        ])
    }

    // MARK: - ChipSimulator higher-level

    public func readMemory(range: Range<Int>) throws -> Data {
        if destroyed {
            throw TagError.lockedPermanent(diagnostics: "tag destroyed")
        }
        if privacyMode {
            // A privacy-mode label answers nothing at all (§9.5.3.9), and the
            // transceive bridge surfaces silence as a lost tag. `.authFailed`
            // here described a refusal the chip never sends.
            throw TagError.tagLost(diagnostics: "privacy mode: the label answers no read")
        }
        var out = Data()
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            let block = cursor / 4
            guard block < blocks.count else { throw TagError.protocolError("read past end") }
            let offsetInBlock = cursor % 4
            let remaining = min(4 - offsetInBlock, range.upperBound - cursor)
            out
                .append(blocks[block]
                    .subdata(in: (blocks[block].startIndex + offsetInBlock) ..<
                        (blocks[block].startIndex + offsetInBlock + remaining)))
            cursor += remaining
        }
        return out
    }

    public func writeMemory(at offset: Int, bytes: Data) throws {
        if destroyed {
            throw TagError.lockedPermanent(diagnostics: "tag destroyed")
        }
        guard offset % 4 == 0, bytes.count % 4 == 0 else {
            throw TagError.protocolError("block-aligned writes only")
        }
        var block = offset / 4
        var cursor = bytes.startIndex
        while cursor < bytes.endIndex {
            guard block < blocks.count else { throw TagError.protocolError("write past end") }
            if blockLocks[block] {
                throw TagError.lockedPermanent(diagnostics: "block=\(block)")
            }
            blocks[block] = bytes.subdata(in: cursor ..< (cursor + 4))
            block += 1
            cursor += 4
        }
    }

    /// Type 5 NDEF lives **after** the 4-byte Capability Container at the
    /// start of memory. NFC Forum T5T spec §5: the NDEF Message TLV
    /// (envelope identical to Type 2 — `0x03 <len> <message> 0xFE`) begins
    /// at byte 4. We skip the CC, validate the magic byte (`0xE1` for
    /// 1-byte addressing, `0xE2` for 8-byte CC with extended MLEN), then
    /// reuse the Type-2 TLV unwrapper.
    public func readNDEF() throws -> Data {
        if destroyed {
            return Data()
        }
        let all = blocks.reduce(Data(), +)
        guard all.count >= ccSize else { return Data() }
        let magic = all[all.startIndex]
        guard magic == 0xE1 || magic == 0xE2 else {
            // No CC → no T5T NDEF.
            return Data()
        }
        let ndefRegion = all.subdata(in: (all.startIndex + ccSize) ..< all.endIndex)
        do {
            return try NDEFEnvelope.unwrap(ndefRegion)
        } catch NDEFEnvelope.ParseError.noNDEFTLV {
            return Data()
        }
    }

    /// Write the `0x03 <len> <message> 0xFE` envelope starting at block 1
    /// (offset 4), preserving the CC at block 0. Per NFC Forum T5T spec
    /// §5.4, MLEN at CC byte 2 describes the *available* T5T_Area and is
    /// set at personalization — we do not rewrite it on each NDEF write.
    public func writeNDEF(_ message: Data) throws {
        if destroyed {
            throw TagError.lockedPermanent(diagnostics: "tag destroyed")
        }
        // A tag with no Capability Container is not NDEF-formatted, and real
        // silicon refuses a *content* write to it — CoreNFC surfaces that as
        // `readerTransceiveErrorTagResponseError` ("Tag Not NDEF formatted"),
        // which `CoreNFCSession` maps to `tagLost`. An *empty* write is forgiven
        // as a semantic no-op on the production path, so mirror both here.
        //
        // Without this, a virgin simulator would accept a write that a virgin
        // SLIX2 rejects — which is precisely how the missing Type-5 formatter
        // stayed invisible. Format the tag first (`Type5Formatter`) and the
        // write goes through, exactly as on hardware.
        if !Type5CC.isFormatted(blocks.first ?? Data()) {
            let isEmptyWrite = (try? NDEFEnvelope.unwrap(message)).map(NDEFCodec.isEmptyMessage) ?? false
            guard isEmptyWrite else {
                throw TagError.tagLost(
                    diagnostics: "Tag Not NDEF formatted — block 0 carries no Capability Container"
                )
            }
            return
        }
        var padded = message
        while padded.count % 4 != 0 {
            padded.append(0x00)
        }
        let capacity = blocks.count * 4 - ccSize
        guard padded.count <= capacity else {
            throw TagError.writeOverflow(needed: padded.count, available: capacity)
        }
        try writeMemory(at: ccSize, bytes: padded)
        // Zero the tail after the new envelope so a shorter write doesn't
        // leave stale TLV bytes that confuse a reader's parser.
        let writtenEnd = ccSize + padded.count
        let totalCapacity = blocks.count * 4
        if writtenEnd < totalCapacity {
            let zeros = Data(repeating: 0x00, count: totalCapacity - writtenEnd)
            try writeMemory(at: writtenEnd, bytes: zeros)
        }
    }

    public func authenticate(password: Data) throws -> Data {
        // Map the password-bytes call onto a SET_PASSWORD challenge:
        // 1. GET_RANDOM_NUMBER (refresh nonce)
        // 2. SET_PASSWORD privacy with XOR mask
        _ = handleGetRandomNumber()
        let mask = Data([
            pendingRandom[pendingRandom.startIndex + 0],
            pendingRandom[pendingRandom.startIndex + 1],
            pendingRandom[pendingRandom.startIndex + 0],
            pendingRandom[pendingRandom.startIndex + 1],
        ])
        let xored = NTAG424Crypto.xor(password, mask)
        var cmd = Data([0x02, 0xB3, Self.passwordIdentifier(for: .privacy)])
        cmd.append(xored)
        let response = handle(command: cmd)
        guard response.first == 0x00 else {
            throw TagError.authFailed(diagnostics: "password rejected")
        }
        return Data([0x00, 0x00])
    }

    public func setPassword(_ password: Data, pack: Data) throws {
        // Bootstrap the privacy password if not present; otherwise WRITE_PASSWORD it.
        if passwords[.privacy] == nil {
            passwords[.privacy] = password
            return
        }
        try authenticate(password: passwords[.privacy] ?? password).withUnsafeBytes { _ in }
        // WRITE_PASSWORD is honoured only in Addressed or Selected mode
        // (§9.5.3.3) — no privacy exemption, unlike SET_PASSWORD — so this
        // helper selects the tag and rides the Select flag, exactly as the
        // production `Iso15693ProtectionClient` does.
        guard handle(command: Data([0x02, 0x25])).first == 0x00 else {
            throw TagError.protocolError("SELECT rejected")
        }
        var cmd = Data([0x12, 0xB4, Self.passwordIdentifier(for: .privacy)])
        cmd.append(password)
        let response = handle(command: cmd)
        guard response.first == 0x00 else {
            throw TagError.protocolError("WRITE_PASSWORD rejected: \(response.hexString)")
        }
    }

    public func permanentLock() throws {
        // Lock every block + AFI + DSFID + every password — except the SLIX2
        // counter block, which "cannot be locked" (§9.5.2.3) and stays
        // unlocked on real silicon after a full lock pass.
        let counterBlock = Iso15693Opcode.counterBlock(for: profile?.id, blockCount: blocks.count)
        for i in blockLocks.indices where i != counterBlock {
            blockLocks[i] = true
        }
        afiLocked = true
        dsfidLocked = true
        for kind in PasswordKind.allCases {
            passwordLocked[kind] = true
        }
    }

    /// Live protection state: privacy mode gates reads; a set write password
    /// gates writes. Maps to the family-agnostic settings.
    public func readProtectionState() throws -> TagProtection? {
        let readGated = privacyMode
        let writeGated = pageProtection & ((1 << 1) | (1 << 5)) != 0
        guard readGated || writeGated else { return TagProtection.none }
        return TagProtection(
            passwordProtect: true,
            style: .type5(.init(kind: readGated ? .readWrite : .write)),
            hasStoredCredential: false
        )
    }

    /// See `ChipSimulator.beginActivation`. This simulator was the only one
    /// without it, so `SimulatedSession.start` handed out a Type-5 tag that was
    /// still Selected, still write-unlocked and still poisoned from the previous
    /// session. Every multi-tap Type-5 test had to remember `endSession()` by
    /// hand, and one that forgot was testing a tag more permissive than any real
    /// one. Idempotent, so an explicit `endSession()` alongside it is harmless.
    public func beginActivation() {
        endSession()
    }

    /// Test-only: model a fresh tap — clears the per-tap write unlock so a
    /// subsequent unauthenticated write is refused again, drops the Selected
    /// state (selection dies with the RF field) and performs the Power-On
    /// Reset that lifts the invalid-password lockout.
    public func endSession() {
        writeUnlocked = false
        verifiedPasswords.removeAll()
        pendingRandom = Data([0x00, 0x00])
        isSelected = false
        poisoned = false
    }

    // MARK: - Helpers

    /// ISO 15693 manufacturer commands carry an extra `E0 04` (NXP) between the
    /// opcode and the operands, which some console syntaxes include and some
    /// skip. Both spellings must mean the same thing here and on real silicon,
    /// so the rule lives in **one** place — `Iso15693Opcode` in HexNFCKit — and
    /// both this simulator and `CoreNFCSession.transceiveISO15693` apply it.
    ///
    /// This used to strip the pair locally while the transport passed it
    /// straight through to CoreNFC as parameters, so a frame that worked here
    /// was malformed on a tag.
    private func strippedManufacturerPrefix(_ command: Data) -> Data {
        guard command.count >= 2 else { return command }
        let opcode = command[command.startIndex + 1]
        let params = [UInt8](command.dropFirst(2))
        let normalised = Iso15693Opcode.normalisedCustomParameters(opcode: opcode, params: params)
        guard normalised.count != params.count else { return command }
        return Data(command.prefix(2)) + Data(normalised)
    }

    private func passwordKind(for identifier: UInt8) -> PasswordKind {
        // ICODE SLIX password identifier bitmask per datasheet §10.5.1.
        switch identifier {
        case 0x01: .read
        case 0x02: .write
        case 0x04: .privacy
        case 0x08: .destroy
        case 0x10: .easAfi
        default: .privacy
        }
    }

    static func passwordIdentifier(for kind: PasswordKind) -> UInt8 {
        switch kind {
        case .read: 0x01
        case .write: 0x02
        case .privacy: 0x04
        case .destroy: 0x08
        case .easAfi: 0x10
        }
    }

    // MARK: - Error code framing

    enum ErrorCode: UInt8 {
        case commandNotRecognized = 0x01
        case commandNotSupported = 0x02
        case invalidFormat = 0x03
        case unknownError = 0x0F
        case blockNotAvailable = 0x10
        case blockLocked = 0x12
        case blockNotProgrammed = 0x13
        case blockNotLockable = 0x14
        case passwordRequired = 0x40
    }

    /// Error flag 0x01 + 1-byte code — and the code is **always `0F`**.
    ///
    /// SL2S2602 §9.6: every refusal the chip makes is answered with "error
    /// with no information given or error code is not supported" (`0Fh`). It
    /// never emits the specific ISO 15693 codes (`0x40` password-required,
    /// `0x12` locked, `0x10` not available) this simulator used to fabricate —
    /// live-confirmed 2026-08-07, when a password-gated write AND a lock of
    /// the counter block both answered plain `01 0F`. The enum survives so
    /// call sites document *why* the chip refused, but the wire carries `0F`:
    /// a client that branches on a specific code is branching on fiction, and
    /// this simulator must not validate it (that fiction hid a
    /// `readProtectionState` that read every protected tag as unprotected).
    static func errorResponse(_ code: ErrorCode) -> Data {
        _ = code
        return Data([0x01, ErrorCode.unknownError.rawValue])
    }

    // MARK: - Constants

    /// Default UID — NXP manufacturer (0x04) sentinel-prefixed (0xE0).
    public static let defaultUID: Data = .init([0xE0, 0x04, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06])
}

extension Iso15693Simulator.PasswordKind: CaseIterable {
    public static var allCases: [Iso15693Simulator.PasswordKind] {
        [.read, .write, .privacy, .destroy, .easAfi]
    }
}
