import Foundation
import HexNFCRecords

/// The ISO 15693 opcodes `CoreNFCSession.transceiveISO15693` can put on the wire.
///
/// CoreNFC has no generic "send these bytes" call for Type-5 — every opcode has
/// to be mapped onto a typed API (or the manufacturer custom-command path), so an
/// unmapped opcode throws `capabilityUnsupported` on real silicon while working
/// perfectly against `Iso15693Simulator`, which parses raw bytes. That asymmetry
/// once left 7 of the 10 built-in Type-5 console presets dead on hardware and
/// green in tests.
///
/// This set is the contract between the three: the transport switch implements
/// it, the simulator handles it, and `Iso15693OpcodeCoverageTests` asserts every
/// built-in Type-5 preset stays inside it. **Add the transport mapping before
/// adding a preset.**
public enum Iso15693Opcode {
    /// ISO 15693-3 core commands.
    public static let readSingleBlock: UInt8 = 0x20
    public static let writeSingleBlock: UInt8 = 0x21
    public static let lockBlock: UInt8 = 0x22
    public static let readMultipleBlocks: UInt8 = 0x23
    /// Moves the tag into the Selected state (ISO 15693-3 §7). The frame that
    /// commands it is *addressed* (UID present, built by nfcd via
    /// `NFCISO15693Tag.select`); every frame *after* it may carry the Select
    /// flag instead of a UID, which is the one route to the SLIX2's
    /// "Addressed or Selected mode only" password commands that iOS can
    /// actually transmit (nfcd refuses an explicit Address flag on both
    /// `customCommand` and `sendRequest`, live-confirmed 2026-08-07).
    public static let select: UInt8 = 0x25
    public static let writeAFI: UInt8 = 0x27
    public static let lockAFI: UInt8 = 0x28
    public static let writeDSFID: UInt8 = 0x29
    public static let lockDSFID: UInt8 = 0x2A
    public static let getSystemInformation: UInt8 = 0x2B
    public static let getMultipleBlockSecurityStatus: UInt8 = 0x2C

    /// ICODE SLIX2 manufacturer-specific commands (NXP custom-command path).
    public static let getRandomNumber: UInt8 = 0xB2
    public static let setPassword: UInt8 = 0xB3
    public static let writePassword: UInt8 = 0xB4
    public static let lockPassword: UInt8 = 0xB5
    /// Defines the protection pointer and the two pages' access conditions
    /// (§9.5.3.6). **This is what actually arms protection** — setting a
    /// password does not.
    public static let protectPage: UInt8 = 0xB6
    public static let destroy: UInt8 = 0xB9
    public static let enablePrivacy: UInt8 = 0xBA
    /// `GET NXP SYSTEM INFORMATION` (§9.5.3.18) — returns the **actual**
    /// protection pointer, protection conditions, lock bits and feature flags.
    ///
    /// This is the read-back for `PROTECT PAGE`: §9.5.3.6 says outright that
    /// "the information about the stored settings of the protection pointer
    /// address and access conditions can be read with the GET NXP SYSTEM
    /// INFORMATION command". It was never mapped, which is why arming SLIX2
    /// protection had to be taken on trust — the one family where a lost ACK
    /// has actually been observed.
    public static let getNXPSystemInformation: UInt8 = 0xAB

    /// Every opcode the production transport can send.
    public static let supported: Set<UInt8> = [
        readSingleBlock, writeSingleBlock, lockBlock, readMultipleBlocks,
        select, writeAFI, lockAFI, writeDSFID, lockDSFID,
        getSystemInformation, getMultipleBlockSecurityStatus,
        getRandomNumber, setPassword, writePassword, lockPassword,
        protectPage, destroy, enablePrivacy, getNXPSystemInformation,
    ]

    /// How many parameter bytes each manufacturer command carries **after** the
    /// manufacturer code. `nil` for the ISO core commands, which are shaped by
    /// their own typed CoreNFC calls.
    ///
    /// Sourced from the shapes `Iso15693ProtectionClient` sends and the
    /// simulator's datasheet-cited handlers, which agree.
    public static func customParameterCount(for opcode: UInt8) -> Int? {
        switch opcode {
        case getRandomNumber: 0
        case getNXPSystemInformation: 0
        case setPassword, writePassword: 5 // identifier + 4-byte password
        case lockPassword: 1 // identifier
        case protectPage: 2 // pointer + protection status
        case destroy, enablePrivacy: 4 // XOR-masked password
        default: nil
        }
    }

    /// Commands the SLIX2 only honours in Addressed or Selected mode:
    /// `SET_PASSWORD` (§9.5.3.2), `WRITE_PASSWORD` (§9.5.3.3), `LOCK_PASSWORD`,
    /// `PROTECT PAGE` and `DESTROY` (§9.5.3.8). Outside those modes the tag does
    /// not refuse the command, it **ignores** it, so the symptom is a ~320 ms
    /// timeout with no reply — which is exactly what every non-addressed
    /// `SET_PASSWORD` drew on real silicon (2026-08-07) while the same frames
    /// passed CI, because neither the transport nor the simulator modelled the
    /// mode requirement. Addressed mode is closed on iOS (nfcd refuses the
    /// Address flag before transmission), so the production route is **Selected
    /// mode**: a `SELECT` (0x25) first, then these frames with the Select flag
    /// (0x10) instead of a UID.
    ///
    /// **The privacy password is the documented exception.** A tag in privacy
    /// mode answers nothing but `GET_RANDOM_NUMBER` and `SET_PASSWORD` and
    /// cannot be inventoried, so the one route out of privacy mode has to work
    /// unaddressed — hence the parameter check rather than a plain opcode set.
    public static func requiresAddressedOrSelectedMode(opcode: UInt8, params: [UInt8]) -> Bool {
        switch opcode {
        case setPassword:
            params.first != 0x04 // privacy identifier

        case writePassword, lockPassword, protectPage, destroy:
            true

        default:
            false
        }
    }

    /// The block that can never be locked, for a given chip.
    ///
    /// SL2S2602 §9.5.2.3: "Block 79 of the user memory contains the 16-bit
    /// counter feature and cannot be locked" — it is likewise excluded from
    /// the `PROTECT PAGE` pointer range (§9.5.3.6, pointer max 4Eh).
    /// Live-confirmed 2026-08-07: `LOCK_BLOCK 4F` answered `01 0F` after
    /// blocks 00–4E all locked cleanly.
    ///
    /// **Keyed on chip identity, not geometry.** The counter is an ICODE SLIX2
    /// feature, not a property of being 80 blocks long; another vendor's
    /// 80-block Type-5 tag would have block 79 skipped and left writable by a
    /// "permanent" lock. `chip` is `nil` only when the family is unidentified,
    /// where declining to guess is right for the same reason.
    ///
    /// Both `Iso15693ProtectionClient.permanentLock` and the simulator's
    /// `LOCK_BLOCK` handler take this from here, so they cannot drift.
    public static func counterBlock(for chip: ChipID?, blockCount: Int) -> Int? {
        guard chip == .icodeSlix2, blockCount > 79 else { return nil }
        return 79
    }

    /// Normalise the parameter bytes of a hand-written manufacturer-command
    /// frame so the transport and the simulator agree on what a frame means.
    ///
    /// CoreNFC's `customCommand` **injects the manufacturer code itself**, so
    /// everything handed to it is a parameter. A console frame written in the
    /// `Flag Cmd E0 04 …` spelling would otherwise reach the tag as two junk
    /// leading parameters — live-confirmed 2026-08-07: `02 B2 04` went out as
    /// `02 B2 04 04`, and the tag simply ignored it (a ~324 ms timeout, then a
    /// generic `01 0F`, which reads exactly like a chip that refuses the
    /// command). The simulator stripped the pair and answered happily, so the
    /// divergence was invisible in CI.
    ///
    /// A **bare `0x04` is deliberately not stripped**: `SET_PASSWORD`'s privacy
    /// identifier is exactly `0x04`, so `02 B3 04 …` is a legitimate frame
    /// whose first parameter is `04`. Only the unambiguous `E0 04` pair goes.
    public static func normalisedCustomParameters(opcode: UInt8, params: [UInt8]) -> [UInt8] {
        guard customParameterCount(for: opcode) != nil else { return params }
        guard params.count >= 2, params[0] == 0xE0, params[1] == 0x04 else { return params }
        return Array(params.dropFirst(2))
    }
}

/// Factory password values on a delivered ICODE SLIX2.
///
/// **SL2S2602 rev 4.2 §9.2.3, "Configuration of delivered ICs":**
///
/// > All password bytes are 00h for the read and write protection password and
/// > the EAS/AFI password […] All password bytes are 0Fh for the Privacy and
/// > Destroy passwords
///
/// Every password exists from delivery; there is no "unset" state.
///
/// **These replace an invented `FF FF FF FF` "documented neutral default".**
/// Removal used to write that value while `enable` presented `00 00 00 00`, so
/// protect, remove, protect could never close: the second protect presented a
/// password the tag no longer held, and §9.5.3.2 stops the IC executing any
/// following command until a power-on reset, so one wrong guess took the whole
/// tap with it. The removal path now restores the datasheet value, which is
/// also the value `enable` presents by default, so the loop closes.
public enum Iso15693Passwords {
    /// Read, write and EAS/AFI protection passwords at delivery (§9.2.3).
    public static let factoryReadWrite = Data(repeating: 0x00, count: 4)
    /// Privacy and Destroy passwords at delivery (§9.2.3).
    public static let factoryPrivacyDestroy = Data(repeating: 0x0F, count: 4)
}

/// Reader-side ICODE SLIX2 (Type-5 / ISO 15693) protection client. Speaks the
/// SLIX2 password handshake over a `transceive` closure, so the same path drives
/// a real chip (`CoreNFCConnectedTag.transceive` to `customCommand`) and the
/// simulator (`SimulatedConnectedTag.transceive` to `handle(command:)`) and the
/// flow is testable without hardware.
///
/// SLIX2 differs fundamentally from the Type-2/Type-4 models: protection is a set
/// of independent 4-byte passwords (read / write / privacy / …) presented via a
/// `GET_RANDOM_NUMBER` to XOR-masked `SET_PASSWORD` challenge. The **write**
/// password gates writes (the common "protect with password"). Privacy mode also
/// gates reads, and is a one-way door on iOS: see `armPrivacy`.
///
/// Wire framing (no manufacturer byte, CoreNFC injects `0x04` for custom
/// commands and the simulator parses the same shape): commands are `[flag, opcode,
/// params…]`; responses are `[0x00] ‖ data` (success) or `[0x01, errorCode]`.
///
/// ## The rules this driver enforces
///
/// 1. **State first.** Every mutating sequence reads `GET NXP SYSTEM
///    INFORMATION` (ABh) before it presents a password, because a wrong
///    password does not merely fail: §9.5.3.2 stops the IC executing anything
///    further until a power-on reset, so it costs the whole activation. A tag
///    the chip itself reports as Public is never sent a credential at all.
/// 2. **A read-back is the success criterion.** `disable` has succeeded when the
///    chip reports the access conditions Public, not when `PROTECT PAGE` was
///    acknowledged. `enable` has succeeded when the conditions read back armed
///    **and** the new password was proven by re-presenting it.
/// 3. **Tidy-up cannot fail the operation.** Once the gate reads open, the
///    password reset is best effort: it reports residue and never throws.
/// 4. **One authentication attempt per activation.** §9.5.3.2 again. Nothing
///    here ever presents a second candidate in the same tap, and no error path
///    retries a password.
///
/// Reference: NXP SL2S2602 (ICODE SLIX2) datasheet rev 4.2, §9.5.3.
struct Iso15693ProtectionClient {
    typealias Transceive = @Sendable (RawCommand) async throws -> Data
    let transceive: Transceive

    /// Whether `readProtectionState` may fall back to a behavioural **write**
    /// probe on a chip that will not answer `ABh`.
    ///
    /// Default deny, because the probe writes. It reads block 1 and writes the
    /// block back its own bytes, which is content-neutral and still a write, on
    /// a call whose contract is to read. That is defensible on a chip whose
    /// password state the app can actually offer to change, and pure cost on one
    /// where it cannot.
    ///
    /// The gate the caller should pass is `.passwordAuth`, the same capability
    /// the Type-2 path gates protection on. Among Type-5 profiles only
    /// `.icodeSlix2` carries it, and deliberately so: 28 blocks is SLI, SLIX,
    /// SLIX-S or SLIX-L indistinguishably, and only the 80-block SLIX2 is both
    /// identifiable and known to carry the password machinery
    /// (`ChipCatalog.swift`, and CLAUDE.md's "Protection is offered for
    /// `.icodeSlix2` only").
    ///
    /// Found in a live capture on 2026-09-09: a plain 28-block ICODE SLIX left
    /// `ABh` unanswered during an ordinary scan, so the fallback ran and put
    /// `21h` on the air, spending a write cycle to answer a question about a
    /// feature this app will never offer that chip.
    let mayProbeByWriting: Bool

    init(transceive: @escaping Transceive, mayProbeByWriting: Bool = false) {
        self.transceive = transceive
        self.mayProbeByWriting = mayProbeByWriting
    }

    /// ISO 15693 "high data rate, no addressing" flag, matching every preset.
    static let flag: UInt8 = 0x02

    /// High data rate + Select flag (0x10): the frame carries no UID and only
    /// the tag in the Selected state answers it. Every command
    /// `Iso15693Opcode.requiresAddressedOrSelectedMode` gates goes out with
    /// this flag, after `select()` has run. The tag *ignores* those frames in
    /// non-addressed mode (§9.5.3.2), and iOS cannot transmit the Address flag.
    static let selectedFlag: UInt8 = 0x12

    enum PasswordKind: UInt8 { case read = 0x01, write = 0x02, privacy = 0x04 }

    /// The value a delivered IC holds for each password (§9.2.3). One source,
    /// shared with the App layer through `Iso15693Passwords`.
    ///
    /// Getting this wrong is what broke `enable`: it presented the *new*
    /// password to `SET_PASSWORD`, which authenticates rather than assigns, so
    /// a factory tag compared it against `00 00 00 00` and refused.
    static func factoryPassword(for kind: PasswordKind) -> Data {
        switch kind {
        case .read, .write: Iso15693Passwords.factoryReadWrite
        case .privacy: Iso15693Passwords.factoryPrivacyDestroy
        }
    }

    // MARK: - Chip-reported state

    /// Protection-status bits for `PROTECT PAGE` (§9.5.3.6 Table 29). Page L is
    /// everything below the protection pointer, Page H everything at or above.
    /// Bits 2-3 and 6-7 are RFU and must stay clear.
    struct PageProtection: OptionSet {
        let rawValue: UInt8
        static let readPageL = PageProtection(rawValue: 1 << 0)
        static let writePageL = PageProtection(rawValue: 1 << 1)
        static let readPageH = PageProtection(rawValue: 1 << 4)
        static let writePageH = PageProtection(rawValue: 1 << 5)
        /// Public: no gate at all. What `disable` restores.
        static let none: PageProtection = []

        var gatesReads: Bool {
            contains(.readPageL) || contains(.readPageH)
        }

        var gatesWrites: Bool {
            contains(.writePageL) || contains(.writePageH)
        }
    }

    /// What the chip says about its own gate, from `GET NXP SYSTEM INFORMATION`
    /// (ABh, §9.5.3.18, Table 71). The only account of the protection state that
    /// is not a guess: the passwords themselves can never be read back, and a
    /// behavioural write probe inside an authenticated activation is accepted
    /// whether or not the gate is down, so it is a false green.
    struct Type5GateState: Hashable, Sendable {
        let protectionPointer: UInt8
        let conditions: UInt8
        /// The lock-bits byte, raw. See `pageProtectionConditionLocked`.
        let lockBits: UInt8

        var protection: PageProtection {
            PageProtection(rawValue: conditions)
        }

        /// No page is gated for read or for write.
        var isPublic: Bool {
            conditions == 0
        }

        /// Whether `LOCK PAGE PROTECTION CONDITION` (B7h, §9.5.3.7) has frozen
        /// the access conditions, after which no `PROTECT PAGE` can ever change
        /// them again. This app never sends B7h, but another reader may have.
        ///
        /// **Bit 3 of the lock-bits byte is not verified against the datasheet.**
        /// The assignment is carried over from the simulator's own comment, not
        /// from a read of SL2S2602 Table 71 and not from a capture. It is
        /// therefore reported and recorded, and deliberately **not** used to
        /// refuse an operation: refusing on a bit that might mean something else
        /// would deny a legitimate protect on a perfectly healthy tag.
        var pageProtectionConditionLocked: Bool {
            lockBits & 0x08 != 0
        }
    }

    /// Read the live protection conditions with `GET NXP SYSTEM INFORMATION`
    /// (ABh, §9.5.3.18).
    ///
    /// Response (Table 71): `00 ‖ PP pointer ‖ PP conditions ‖ lock bits ‖
    /// feature flags(4)`.
    ///
    /// Returns `nil`, rather than throwing, when the tag answers an error frame,
    /// a short response, or nothing at all. Two reasons: a non-SLIX2 Type-5 tag
    /// simply does not implement the command, and **no capture in this repo
    /// shows a real SLIX2 answering ABh either**. Treating silence as a fault
    /// would fail a protection run that otherwise succeeded, on an assumption
    /// this project has not yet earned. A `nil` costs the caller its read-back
    /// proof and nothing else, which is exactly what it should cost.
    func readGateState() async throws -> Type5GateState? {
        let resp = try? await send([Self.flag, Iso15693Opcode.getNXPSystemInformation])
        guard let resp, resp.first == 0x00, resp.count >= 4 else { return nil }
        return Type5GateState(
            protectionPointer: resp[resp.startIndex + 1],
            conditions: resp[resp.startIndex + 2],
            lockBits: resp[resp.startIndex + 3]
        )
    }

    // MARK: - High-level operations

    /// Pointer value that puts the **entire** user memory in Page H: "If the
    /// protection pointer address is set to block 0, the entire user memory
    /// (block 0 to block 78) is defined as Page H" (§9.5.3.6).
    static let wholeMemoryPointer: UInt8 = 0x00

    /// Gate writes behind `writePassword`.
    ///
    /// **Three things this has to get right, all of which it once got wrong.**
    ///
    /// 1. `SET_PASSWORD` (§9.5.3.2) *authenticates*; it does not assign. It
    ///    carries the password the tag holds **now**, which is `00 00 00 00` for
    ///    read/write on a delivered IC and `0F 0F 0F 0F` for privacy (§9.2.3).
    /// 2. `WRITE_PASSWORD` (§9.5.3.3) assigns, and only after a successful
    ///    `SET_PASSWORD`. "The new password takes effect immediately", so using
    ///    it afterwards needs a further `SET_PASSWORD`, which is also the only
    ///    read-back this chip offers.
    /// 3. **Setting a password protects nothing.** `PROTECT PAGE` (§9.5.3.6)
    ///    arms it, and changing access conditions needs both the read and write
    ///    passwords transmitted first.
    ///
    /// Ordering follows the house rule: **disarm the gate before rewriting a
    /// credential, and arm it only once the credential is in place and proven.**
    /// An abort between the two therefore leaves a tag that is Public and holds
    /// one of two known passwords, which any later tap can fix. The old order
    /// left a tag gated behind a password whose value nothing could establish.
    ///
    /// - Parameters:
    ///   - writePassword: the value to leave on the tag, or `nil` to arm nothing.
    ///   - readPassword: the **privacy** password. Ignored unless
    ///     `armPrivacyIrreversibly` is `true`; see that parameter.
    ///   - currentWritePassword: what the tag holds now. Defaults to the factory
    ///     value; pass the held credential to re-protect an armed tag. There is
    ///     exactly one attempt per tap (§9.5.3.2), so this is a decision, not a
    ///     ladder.
    ///   - armPrivacyIrreversibly: opt-in required before privacy mode is armed.
    ///     Without it a `readPassword` is refused outright rather than silently
    ///     arming a door this app cannot open. See `armPrivacy` for why.
    ///   - currentPrivacyPassword: what the tag's privacy slot holds now.
    ///     Defaults to the factory `0F 0F 0F 0F` (§9.2.3).
    @discardableResult
    func enable(
        writePassword: Data?,
        readPassword: Data?,
        currentWritePassword: Data? = nil,
        armPrivacyIrreversibly: Bool = false,
        currentPrivacyPassword: Data? = nil
    ) async throws -> ProtectionResidue {
        guard writePassword != nil || readPassword != nil else {
            throw TagError.protocolError("nothing to protect", diagnostics: "no SLIX password supplied")
        }
        // A privacy-mode ISO 15693 label answers nothing but GET_RANDOM_NUMBER
        // and SET_PASSWORD and cannot be inventoried (§9.5.3.9). iOS only ever
        // hands an app a tag nfcd has inventoried, so once such a tag leaves the
        // field no iPhone can find it again. Arming that is a deliberate act,
        // never a settings-card default.
        guard readPassword == nil || armPrivacyIrreversibly else {
            throw TagError.capabilityUnsupported(
                .passwordAuth,
                diagnostics: "ICODE privacy mode is not reachable from ordinary protection: "
                    + "a privacy-mode tag cannot be inventoried (SL2S2602 §9.5.3.9) and iOS only "
                    + "vends inventoried tags, so no iPhone can find it again. "
                    + "Pass armPrivacyIrreversibly from a UID-confirmed Dangerous Action."
            )
        }

        var residue = ProtectionResidue(family: .type5, intent: .enable)

        if let newWrite = writePassword {
            try requireFourBytes(newWrite, "write password")
            let current = currentWritePassword ?? Self.factoryPassword(for: .write)
            try requireFourBytes(current, "current write password")

            // A0. Non-mutating, and sent before anything is presented, so a tag
            // whose conditions are already what we want costs nothing to find
            // out about.
            let before = try await readGateState()
            if before != nil {
                residue.record(.stateRead)
            }
            if let before, before.pageProtectionConditionLocked {
                // Recorded, not refused: the bit assignment is unverified. See
                // `Type5GateState.pageProtectionConditionLocked`.
                residue.record(
                    failure: .stateRead,
                    "chip reports lock bits \(hex(before.lockBits)); if bit 3 is the page-protection "
                        + "condition lock (B7h, §9.5.3.7, unverified) PROTECT PAGE can no longer change anything"
                )
            }

            try await select()
            try await setPassword(.write, current)
            residue.record(.gateOpened)
            residue.authenticatedWithFactoryDefault = current == Iso15693Passwords.factoryReadWrite

            // `PROTECT PAGE` needs the read password too (§9.5.3.6). This app
            // never changes it, so the factory value stands.
            try await setPassword(.read, Self.factoryPassword(for: .read))

            // Disarm before touching the credential. If the next frames tear,
            // the tag is Public and holds either the old or the new password,
            // and a tag anyone can write is a tag anyone can repair.
            if newWrite != current, before?.isPublic == false {
                try await protectPage(
                    pointer: before?.protectionPointer ?? Self.wholeMemoryPointer,
                    protection: .none
                )
                residue.record(.gateDisarmed)
            }

            if newWrite == current {
                // The tag already holds what the caller asked for, and the
                // SET_PASSWORD above is the proof: the chip compares.
                residue.record(.credentialProven)
                residue.credential = .callerSupplied
            } else {
                // `.provenOpen` only where the chip *said* so. An acknowledged
                // disarm is not a read-back, and neither is an unanswered ABh.
                if before?.isPublic == true {
                    residue.gate = .provenOpen
                }
                let outcome: Type5AssignOutcome
                do {
                    outcome = try await assignPassword(.write, to: newWrite, presenting: current)
                } catch {
                    residue.credential = .unknown(reason: "the password change did not complete")
                    residue.record(failure: .credentialWritten, "WRITE_PASSWORD sequence did not complete")
                    throw TagError.protectionIncomplete(
                        residue,
                        diagnostics: "nothing was armed, and the tag holds either the old write password "
                            + "or the new one: \(error)"
                    )
                }
                switch outcome {
                case .assigned:
                    residue.record(.credentialWritten)
                    residue.record(.credentialProven)
                    residue.credential = .callerSupplied

                case .notAssigned:
                    residue.record(failure: .credentialWritten, "WRITE_PASSWORD(write) refused twice")
                    throw TagError.protectionIncomplete(
                        residue,
                        diagnostics: "the write password was not changed and nothing was armed; "
                            + "the tag still holds the password it held before"
                    )

                case .probablyAssignedTapPoisoned:
                    residue.credential = .unknown(
                        reason: "WRITE_PASSWORD was refused but the old password no longer authenticates"
                    )
                    residue.record(failure: .credentialProven, "lost ACK on WRITE_PASSWORD(write)")
                    throw TagError.protectionIncomplete(
                        residue,
                        diagnostics: "nothing was armed and the tag probably holds the new write password; "
                            + "hold it against the phone again to finish"
                    )
                }
            }

            // Arm last. `readPageH` is deliberately not set even when reads are
            // meant to be gated: this app never changes the *read* password, so
            // an armed RH bit would gate reads behind the factory `00 00 00 00`,
            // which gates nothing while looking like protection. Reads are gated
            // by privacy mode or not at all.
            let armed: PageProtection = .writePageH
            do {
                try await protectPage(pointer: Self.wholeMemoryPointer, protection: armed)
            } catch {
                // The Type-5 twin of the Type-2 and Ultralight C AUTH0 aborts.
                // This is the command that arms the gate, and the write password
                // has already landed above it, so a bare throw here reached the
                // user as a transport error over a residue saying the credential
                // is theirs. The pre-arm reading is spent the moment the command
                // goes out, refused or not, so the verdict is `.unknown` unless
                // the chip itself says otherwise.
                residue.gate = .unknown
                residue.record(failure: .gateArmed, "PROTECT PAGE did not complete: \(error)")
                if let state = try? await readGateState() {
                    residue.gate = state.isPublic
                        ? .provenOpen
                        : .provenArmed(fromPage: Int(state.protectionPointer))
                    residue.record(.gateProven)
                }
                throw TagError.protectionIncomplete(
                    residue,
                    diagnostics: "the write password is on the tag and PROTECT PAGE did not complete; "
                        + "hold it against the phone again to finish: \(error)"
                )
            }
            residue.record(.gateArmed)

            // The pre-arm reading is spent from here. `gate` may still be holding
            // the `.provenOpen` set further up from the state read taken *before*
            // `PROTECT PAGE` went out, and a tag that will not answer ABh below
            // leaves `verifyPageProtection` with nothing to say, so that stale
            // verdict used to survive into the final residue and tell the user
            // protection had not switched on. A reading that a later command
            // invalidated is not a reading.
            residue.gate = .unknown

            // `PROTECT PAGE` is the command that actually arms the gate, on the
            // family where a lost ACK has been observed on silicon, so read the
            // conditions back from the chip rather than trusting the `00`.
            try await verifyPageProtection(matches: armed, into: &residue)
        }

        if let readPassword {
            try requireFourBytes(readPassword, "privacy password")
            try await armPrivacy(
                newPassword: readPassword,
                currentPrivacyPassword: currentPrivacyPassword
            )
        }
        return residue
    }

    /// Present the password to unlock the matching operation for this session.
    func authenticate(password: Data, kind: PasswordKind = .write) async throws {
        try requireFourBytes(password, "password")
        try await select()
        try await setPassword(kind, password)
    }

    /// "Remove protection": read the gate, authenticate, clear the page access
    /// conditions, **read the gate back**, and only then reset the password to
    /// its delivered-IC value.
    ///
    /// **The gate does not latch.** `PROTECT PAGE` with a status of `00h`
    /// returns the tag to Public, and stays available until `LOCK PAGE
    /// PROTECTION CONDITION` (B7h, §9.5.3.7) is issued, which this app never
    /// sends. Only the *password* is unclearable without `DESTROY`, which is why
    /// removal resets it to the factory value rather than pretending it is gone.
    ///
    /// **The read-back at step B6 is the success criterion, and nothing after it
    /// may report failure.** A tag whose gate came down but whose password was
    /// not tidied away is a success with residue; calling that a failure is what
    /// sent a user back to re-enter a password the chip no longer held.
    ///
    /// - Parameters:
    ///   - currentWritePassword: the write password the tag holds now.
    ///   - hadReadProtect: the app believes this tag's privacy password was
    ///     changed from the factory value. Only meaningful together with
    ///     `currentPrivacyPassword`.
    ///   - currentPrivacyPassword: the privacy password the tag holds now.
    ///     **Never defaulted to the write password.** The two are different
    ///     values by construction (§9.2.3 gives them different factory values),
    ///     and presenting the wrong one ends the activation (§9.5.3.2). With no
    ///     privacy password in hand the privacy slot is left alone and recorded
    ///     as residue, which is strictly better than a guaranteed wrong guess.
    @discardableResult
    func disable(
        currentWritePassword: Data,
        hadReadProtect: Bool = false,
        currentPrivacyPassword: Data? = nil
    ) async throws -> ProtectionResidue {
        try requireFourBytes(currentWritePassword, "current write password")
        var residue = ProtectionResidue(family: .type5, intent: .disable)

        // B1. Ask the chip before presenting anything. A tag that is not gated
        // is never sent a credential, because a wrong one costs the whole
        // activation (§9.5.3.2) and there was nothing to remove anyway.
        let before = try await readGateState()
        if let before {
            residue.record(.stateRead)
            if before.isPublic {
                residue.gate = .provenOpen
                residue.record(.gateProven)
                residue.credential = .unchanged
                return residue
            }
        }

        try await select()
        try await setPassword(.write, currentWritePassword)
        residue.record(.gateOpened)
        residue.authenticatedWithFactoryDefault = currentWritePassword == Iso15693Passwords.factoryReadWrite
        try await setPassword(.read, Self.factoryPassword(for: .read))
        try await protectPage(pointer: Self.wholeMemoryPointer, protection: .none)
        residue.record(.gateDisarmed)

        // B6. The success criterion, and the last line that may throw.
        if let after = try await readGateState() {
            guard after.isPublic else {
                residue.record(
                    failure: .gateProven,
                    "chip still reports conditions \(hex(after.conditions)) after PROTECT PAGE 00h"
                )
                throw TagError.protectionIncomplete(
                    residue,
                    diagnostics: "removal did not open the gate; the password has NOT been touched, "
                        + "so keep the credential"
                )
            }
            residue.gate = .provenOpen
            residue.record(.gateProven)
        } else {
            // The chip does not answer its own status command, so this
            // activation cannot witness the change. Not a failure and not a
            // proof: `residue.gate` stays `.unknown`, which is the honest word.
            residue.record(
                failure: .gateProven,
                "GET NXP SYSTEM INFORMATION (ABh) unanswered, so PROTECT PAGE 00h could not be witnessed"
            )
        }

        // Best effort from here, whichever way the read-back went. Where the chip
        // answered, the gate is proven open; where it did not, the residue says
        // exactly that and `gate` stays `.unknown`, because an unanswered ABh
        // proves nothing. What holds either way is that `PROTECT PAGE 00h` has
        // gone out and nothing below re-arms anything, so no failure under this
        // line may be reported as a failed removal.
        await resetWritePasswordToFactory(from: currentWritePassword, into: &residue)
        if hadReadProtect {
            await resetPrivacyPasswordToFactory(from: currentPrivacyPassword, into: &residue)
        }
        return residue
    }

    /// Best-effort restore of the delivered-IC write password (§9.2.3). Never
    /// throws: it runs only after the gate has been proven open.
    private func resetWritePasswordToFactory(
        from current: Data,
        into residue: inout ProtectionResidue
    ) async {
        guard current != Iso15693Passwords.factoryReadWrite else {
            residue.credential = .factoryDefault
            return
        }
        do {
            switch try await assignPassword(
                .write, to: Iso15693Passwords.factoryReadWrite, presenting: current
            ) {
            case .assigned:
                residue.record(.credentialWritten)
                residue.credential = .factoryDefault

            case .notAssigned:
                residue.credential = .unchanged
                residue.record(
                    failure: .credentialWritten,
                    "the write password could not be reset; the tag still answers the old one"
                )

            case .probablyAssignedTapPoisoned:
                residue.credential = .unknown(
                    reason: "the write password reset was refused but the old value no longer authenticates"
                )
                residue.record(failure: .credentialWritten, "lost ACK on the write password reset")
            }
        } catch {
            residue.credential = .unknown(reason: "the write password reset did not complete")
            residue.record(failure: .credentialWritten, "write password reset: \(error)")
        }
    }

    /// Best-effort restore of the delivered-IC privacy password (§9.2.3).
    ///
    /// Presenting the privacy password also clears privacy mode (§9.5.3.9), so
    /// this runs in the safe order: the gate comes down first (the presentation),
    /// then the credential is rewritten. An abort between the two leaves a tag
    /// that is out of privacy and can still be found.
    private func resetPrivacyPasswordToFactory(
        from current: Data?,
        into residue: inout ProtectionResidue
    ) async {
        guard let current, current.count == 4 else {
            residue.record(
                failure: .credentialWritten,
                "no privacy password supplied, so the privacy slot was left untouched. "
                    + "Presenting the write password here would be a guaranteed wrong password "
                    + "(§9.2.3 gives the two slots different factory values) and §9.5.3.2 would "
                    + "end the activation"
            )
            return
        }
        guard current != Iso15693Passwords.factoryPrivacyDestroy else { return }
        do {
            try await setPassword(.privacy, current)
            switch try await assignPassword(
                .privacy, to: Iso15693Passwords.factoryPrivacyDestroy, presenting: current
            ) {
            case .assigned:
                residue.record(.credentialWritten)

            case .notAssigned, .probablyAssignedTapPoisoned:
                residue.record(failure: .credentialWritten, "the privacy password could not be reset")
            }
        } catch {
            residue.record(failure: .credentialWritten, "privacy password reset: \(error)")
        }
    }

    // MARK: - Privacy mode

    /// Take a tag **out** of privacy mode.
    ///
    /// § 9.5.3.9: a privacy-mode label "does not respond to any command except
    /// GET RANDOM NUMBER and SET PASSWORD", and cannot be inventoried.
    /// Presenting the privacy password clears the bit. Both frames therefore go
    /// out **unaddressed** (flag `0x02`), which is what
    /// `Iso15693Opcode.requiresAddressedOrSelectedMode`'s privacy carve-out
    /// exists for: `SELECT` is not one of the two commands a privacy tag
    /// answers, so there is no Selected state to ride.
    ///
    /// ## ⚠️ This routine is UNVERIFIABLE ON iOS, by construction
    ///
    /// CoreNFC only ever hands an app an `NFCISO15693Tag` that nfcd has already
    /// **inventoried**, and a privacy-mode tag answers no inventory. So iOS can
    /// never discover such a tag and this app can never send it anything. The
    /// only window in which this code can run at all is the activation that
    /// armed privacy in the first place, before the tag leaves the field.
    ///
    /// It is here because it costs nothing, it is the right thing to have if a
    /// route ever opens, and `armPrivacy` uses it to prove the way back on the
    /// one tag it is about to arm. Nothing in this repo has run it against
    /// silicon, and no claim is made that it recovers a tag in the field.
    func exitPrivacy(password: Data) async throws {
        try requireFourBytes(password, "privacy password")
        // Unaddressed, and before any `select()`: a privacy tag would ignore a
        // SELECT, and the two frames below are the only ones it answers.
        try await setPassword(.privacy, password, flag: Self.flag)
        // An ACK is not proof. Prove the bit is down by reading a block, which
        // a privacy-mode tag would not answer at all.
        guard let resp = try? await send([Self.flag, Iso15693Opcode.readSingleBlock, 0x00]),
              resp.first == 0x00, resp.count >= 2
        else {
            throw TagError.verificationFailed(
                diff: Data(),
                diagnostics: "SET_PASSWORD(privacy) was accepted but the tag still will not serve a block, "
                    + "so it is still in privacy mode"
            )
        }
    }

    /// Put a tag **into** privacy mode.
    ///
    /// ## ⚠️ A one-way door on iOS
    ///
    /// A privacy-mode label answers nothing but `GET_RANDOM_NUMBER` and
    /// `SET_PASSWORD` and cannot be inventoried (§9.5.3.9). iOS only vends a tag
    /// nfcd has inventoried. So the moment this tag leaves the field, **no
    /// iPhone can find it again, this app included.** Only a reader that can
    /// send an unaddressed frame to a tag it never inventoried can get it back.
    ///
    /// Because of that this refuses to arm until it has demonstrated, on this
    /// exact tag and in this activation, that the way back is transmissible and
    /// accepted:
    ///
    /// 1. present the current privacy password (§9.5.3.2),
    /// 2. assign the new one and prove it by re-presenting it (§9.5.3.3),
    /// 3. send the **unaddressed** privacy `SET_PASSWORD` while the tag is still
    ///    ordinary. If that draws silence, refuse to arm anything,
    /// 4. arm, and prove it by a read that must draw silence,
    /// 5. walk back out with `exitPrivacy`, prove the tag answers again,
    /// 6. arm once more.
    ///
    /// Step 3 is reasoned from §9.5.3.2's privacy carve-out and is **not
    /// verified**: the exception is worded around a privacy tag's inability to
    /// be inventoried, and whether the chip accepts a privacy-identifier
    /// `SET_PASSWORD` outside Addressed or Selected mode while it is *not* in
    /// privacy mode has never been observed here. If it does not, this refuses,
    /// which is the safe direction.
    func armPrivacy(newPassword: Data, currentPrivacyPassword: Data? = nil) async throws {
        try requireFourBytes(newPassword, "privacy password")
        let current = currentPrivacyPassword ?? Self.factoryPassword(for: .privacy)
        try requireFourBytes(current, "current privacy password")

        try await select()
        try await setPassword(.privacy, current)
        if newPassword != current {
            switch try await assignPassword(.privacy, to: newPassword, presenting: current) {
            case .assigned:
                break

            case .notAssigned, .probablyAssignedTapPoisoned:
                throw TagError.protocolError(
                    "the privacy password could not be changed",
                    diagnostics: "refusing to arm privacy mode without a proven privacy password"
                )
            }
        }

        // The way back, rehearsed before the door closes.
        guard let probe = try? await setPasswordRaw(.privacy, newPassword, flag: Self.flag),
              probe.first == 0x00
        else {
            throw TagError.capabilityUnsupported(
                .passwordAuth,
                diagnostics: "the unaddressed privacy SET_PASSWORD drew no answer on this tag, so the "
                    + "only route out of privacy mode is not available. Refusing to arm."
            )
        }

        try await enablePrivacy(newPassword)
        guard await !tagAnswersAread() else {
            throw TagError.verificationFailed(
                diff: Data(),
                diagnostics: "ENABLE_PRIVACY was acknowledged but the tag still serves reads, "
                    + "so privacy mode did not take"
            )
        }
        // Walk back out for real, on this tag, so "the way back works" is an
        // observation rather than a belief.
        try await exitPrivacy(password: newPassword)
        // And arm again, which is what the caller asked for.
        try await enablePrivacy(newPassword)
        guard await !tagAnswersAread() else {
            throw TagError.verificationFailed(
                diff: Data(),
                diagnostics: "the tag came out of privacy mode and would not go back in"
            )
        }
    }

    /// Whether a plain block read is answered. A privacy-mode tag answers
    /// nothing (§9.5.3.9), which the transport surfaces as a lost tag.
    private func tagAnswersAread() async -> Bool {
        guard let resp = try? await send([Self.flag, Iso15693Opcode.readSingleBlock, 0x00]) else {
            return false
        }
        return resp.first == 0x00 && resp.count >= 2
    }

    // MARK: - Live state

    /// The chip's own account of what it gates, with the old behavioural probe
    /// kept only as the fallback for a tag that will not answer ABh.
    ///
    /// **Why the probe is the fallback and not the answer.** It reads a block
    /// and writes it back its own bytes; inside an activation that has already
    /// authenticated, that write is accepted whether or not the gate is down, so
    /// the probe reads an armed tag as unprotected. It also puts a write on the
    /// air during what the caller asked to be a read.
    ///
    /// **The SLIX2 answers the generic `0F` to every refusal** (§9.6: "error
    /// with no information given or error code is not supported"), never the
    /// specific ISO codes (`0x40` password-required, `0x12` locked) this used
    /// to match on, so a genuinely protected tag read back as *unprotected*.
    /// Live-confirmed 2026-08-07: an armed tag refused the unauthenticated
    /// write probe with plain `01 0F`. Since the error code cannot separate
    /// "password-gated" from "permanently locked", the block's security-status
    /// bit does: a refused write on an **unlocked** block is the password gate.
    func readProtectionState() async throws -> TagProtection? {
        if let state = try await readGateState() {
            guard !state.isPublic else { return TagProtection.none }
            return TagProtection(
                passwordProtect: true,
                style: .type5(.init(kind: state.protection.gatesReads ? .readWrite : .write)),
                hasStoredCredential: false
            )
        }
        // The chip would not account for itself, and the only other way to ask
        // costs a write. `nil`, not `TagProtection.none`: nothing was probed, so
        // the honest answer is "I cannot tell you", and the two are load-bearingly
        // different here (see the comment below on the clean-pass gate).
        guard mayProbeByWriting else { return nil }
        let probeBlock: UInt8 = 1 // NDEF area, not the CC at block 0
        let readResp = try await send([Self.flag, 0x20, probeBlock])
        let readGated = isError(readResp, code: nil)
        var writeGated = false
        if readResp.first == 0x00, readResp.count >= 5 {
            // Write the block back its own value, a no-op if allowed.
            let current = readResp.subdata(in: (readResp.startIndex + 1) ..< (readResp.startIndex + 5))
            let writeResp = try await send([Self.flag, 0x21, probeBlock] + current)
            if isError(writeResp, code: nil) {
                writeGated = try await !isBlockLocked(probeBlock)
            }
        }
        // `TagProtection.none`, NOT `nil`. The two mean different things across
        // this codebase: `nil` is "this chip doesn't model protection state, so
        // I can't tell you", while `TagProtection.none` is "I probed, and it is
        // not protected". Both probes above ran, so this is the latter.
        //
        // `return .none` here inferred `Optional.none` (a compiler warning), so
        // Type-5 answered "don't know" for every unprotected tag. That silently
        // skipped `cleanup.verify`'s `if let state` unprotected assertion and
        // made the runner's `cleanupLeftTagProtected` an assumption rather than
        // a determination, weakening the very clean-pass gate that unlocks the
        // irreversible ops.
        guard readGated || writeGated else { return TagProtection.none }
        return TagProtection(
            passwordProtect: true,
            style: .type5(.init(kind: readGated ? .readWrite : .write)),
            hasStoredCredential: false
        )
    }

    /// Permanently lock every lockable data block (irreversible), then verify
    /// the chip itself reports them locked.
    ///
    /// Three SLIX2 realities shape this, all live-confirmed:
    ///
    /// 1. **Block 79 (the 16-bit counter) cannot be locked** (§9.5.2.3). The
    ///    first live run locked 00-4E cleanly and then failed the whole op on
    ///    the counter block's refusal. `Iso15693Opcode.counterBlock` excludes it.
    /// 2. **Every refusal is the generic `0F`** (§9.6), so the chip never sends
    ///    0x12 "already locked" and a re-lock refusal is indistinguishable from
    ///    a real failure by code. Idempotency therefore comes from *skipping*
    ///    blocks the security status already reports locked, not from
    ///    forgiving an error code the silicon does not emit.
    /// 3. **A lock error frame does not mean the lock failed** (2026-08-09,
    ///    fresh tag): `LOCK_BLOCK 49h` drew `01 0F` at 29 ms where every other
    ///    lock answered in ~11 ms, the signature of a lost ACK on a
    ///    write-alike command followed by a retransmission that hit the
    ///    now-locked block. The security-status bit is the ground truth: on an
    ///    error, locked means done, unlocked earns exactly one retry.
    ///
    /// ## Why this returns an outcome instead of throwing
    ///
    /// It used to throw partway through the loop, after earlier blocks were
    /// already locked forever, and the caller only built a `PermanentLockOutcome`
    /// on the success path. So a half-locked SLIX2 reached the user as "The tag
    /// responded outside the expected protocol", which is the one report
    /// CLAUDE.md says is certainly wrong about a tag that has already burned
    /// half its lock bits. Type-5 is also the family that can answer the
    /// question: `GET_MULTIPLE_BLOCK_SECURITY_STATUS` reports the split, so the
    /// partial burn is read back rather than inferred.
    @discardableResult
    func permanentLock(chip: ChipID?, blockCount: Int) async throws -> PermanentLockOutcome {
        let counterBlock = Iso15693Opcode.counterBlock(for: chip, blockCount: blockCount)
        let lockable = (0 ..< blockCount).filter { $0 != counterBlock }
        // Taken before a single lock frame goes out, so a throw here costs
        // nothing and the blocks a previous run left locked are never counted as
        // this run's burn.
        let already = try await lockedBlocks(blockCount: blockCount)
        let target = lockable.filter { !already.contains($0) }
        do {
            for block in target {
                let resp = try await send([Self.flag, 0x22, UInt8(block & 0xFF)])
                if resp.first == 0x00 {
                    continue
                }
                if try await isBlockLocked(UInt8(block & 0xFF)) {
                    continue
                }
                let retry = try await send([Self.flag, 0x22, UInt8(block & 0xFF)])
                if retry.first == 0x00 {
                    continue
                }
                if try await isBlockLocked(UInt8(block & 0xFF)) {
                    continue
                }
                throw TagError.protocolError(
                    "LOCK_BLOCK failed",
                    diagnostics: "block=\(block) resp=\(resp.hexString) retry=\(retry.hexString), "
                        + "security status still reports it unlocked"
                )
            }
        } catch {
            throw await TagError.permanentLockIncomplete(
                outcome(after: already, target: target, blockCount: blockCount, cause: "\(error)")
            )
        }

        // Read-back proof: an ACK on the lock write proves the frame was
        // accepted, not that the lock took. Type-5, unlike Type-2, has a
        // status command, so use it.
        //
        // `.committedVerified` here is a determination, not a hope: reaching this
        // line means every **lockable** block came back locked. Lockable excludes
        // the 16-bit counter, which a SLIX2 refuses to lock (§9.5.2.3); it is
        // never written, so it is never claimed.
        let verdict = await outcome(after: already, target: target, blockCount: blockCount, cause: nil)
        guard verdict.stages[.blocks] == .committedVerified else {
            throw TagError.permanentLockIncomplete(verdict)
        }
        return verdict
    }

    /// Ask the chip which blocks this run actually burned, and turn the answer
    /// into the one stage a Type-5 lock reports.
    ///
    /// `already` is what was locked before the first frame and `target` is what
    /// this run set out to lock, so the count is this run's burn and not the
    /// previous owner's. A status read that will not answer is reported as
    /// unknown rather than as nothing: on an operation with no undo those are
    /// different answers.
    private func outcome(
        after already: Set<Int>,
        target: [Int],
        blockCount: Int,
        cause: String?
    ) async -> PermanentLockOutcome {
        var outcome = PermanentLockOutcome()
        let prefix = cause.map { "LOCK_BLOCK stopped: \($0). " } ?? ""
        guard let after = try? await lockedBlocks(blockCount: blockCount) else {
            outcome.record(.blocks, .inconclusive(
                diagnostics: prefix + "the chip would not report its block security status, so how "
                    + "many of the \(target.count) blocks are now locked for good is not known"
            ))
            return outcome
        }
        let burned = target.filter { after.contains($0) }
        let missed = target.filter { !after.contains($0) }
        if missed.isEmpty {
            outcome.record(.blocks, .committedVerified)
        } else if burned.isEmpty {
            outcome.record(.blocks, .refused(
                diagnostics: prefix + "the security status reports none of the \(target.count) "
                    + "blocks locked, so nothing was burned"
            ))
        } else {
            outcome.record(.blocks, .partiallyCommitted(
                locked: burned.count,
                of: target.count,
                diagnostics: prefix + "blocks still unlocked: \(missed)"
            ))
        }
        return outcome
    }

    /// Require the chip's reported conditions to match what was just armed.
    ///
    /// A tag that will not answer ABh is **not** treated as a failure: this is a
    /// verification, and an unmapped or unsupported command on a non-SLIX2
    /// Type-5 tag must not fail a protection run that otherwise succeeded. It is
    /// recorded as a missing proof instead, so the residue says "armed, not
    /// witnessed" rather than "armed". Only a *definite* contradiction throws.
    private func verifyPageProtection(
        matches expected: PageProtection,
        into residue: inout ProtectionResidue
    ) async throws {
        // `try?`. A read that throws and a read that answers `nil` are the same
        // thing to this method, and the difference is not worth a transport error
        // escaping past a residue that records the password as written. The tag
        // is armed either way at this point; what is missing is only the witness.
        guard let state = try? await readGateState() else {
            residue.record(
                failure: .gateProven,
                "GET NXP SYSTEM INFORMATION (ABh) unanswered, so PROTECT PAGE could not be witnessed"
            )
            return
        }
        guard state.conditions == expected.rawValue else {
            // A definite contradiction, and it still has to carry the residue.
            // Thrown bare it reached the user as "The tag wrote back something
            // different from what was sent. Try the write again." on a tag whose
            // password had already landed, which is the report that tells someone
            // to discard a credential their tag is holding.
            residue.record(
                failure: .gateProven,
                "PROTECT PAGE read-back mismatch: armed \(hex(expected.rawValue)), "
                    + "chip reports \(hex(state.conditions))"
            )
            throw TagError.protectionIncomplete(
                residue,
                diagnostics: "PROTECT PAGE read-back mismatch: armed \(hex(expected.rawValue)), "
                    + "chip reports \(hex(state.conditions)) (GET NXP SYSTEM INFORMATION)"
            )
        }
        residue.gate = .provenArmed(fromPage: Int(state.protectionPointer))
        residue.record(.gateProven)
    }

    /// One block's lock bit from `GET_MULTIPLE_BLOCK_SECURITY_STATUS`, the
    /// chip's own account, used wherever an `0F` refusal is ambiguous.
    private func isBlockLocked(_ block: UInt8) async throws -> Bool {
        let status = try await send([Self.flag, 0x2C, block, 0x00])
        return status.first == 0x00 && status.count >= 2
            && status[status.startIndex + 1] & 0x01 != 0
    }

    /// The blocks `GET_MULTIPLE_BLOCK_SECURITY_STATUS` reports locked.
    /// Chunked (16 blocks per frame) so an 80-block SLIX2 never needs one
    /// oversized response frame.
    private func lockedBlocks(blockCount: Int) async throws -> Set<Int> {
        var locked: Set<Int> = []
        var start = 0
        while start < blockCount {
            let count = min(16, blockCount - start)
            let resp = try await send([Self.flag, 0x2C, UInt8(start), UInt8(count - 1)])
            guard resp.first == 0x00, resp.count >= 1 + count else {
                throw TagError.malformedResponse(
                    resp, diagnostics: "security status \(start)..<\(start + count): \(resp.hexString)"
                )
            }
            for i in 0 ..< count where resp[resp.startIndex + 1 + i] & 0x01 != 0 {
                locked.insert(start + i)
            }
            start += count
        }
        return locked
    }

    // MARK: - Credential mutation

    /// What a `WRITE_PASSWORD` actually left behind. A SLIX2 password can never
    /// be read out, so these are the only three answers that exist.
    enum Type5AssignOutcome: Hashable, Sendable {
        /// Proven: the chip accepted a `SET_PASSWORD` carrying the new value.
        case assigned
        /// Proven not: the chip still answers the old value.
        case notAssigned
        /// The write was refused but the old value no longer authenticates, so
        /// the write almost certainly landed and the error frame was a lost ACK.
        /// The tap is spent either way (§9.5.3.2).
        case probablyAssignedTapPoisoned
    }

    /// The single credential-mutation primitive: assign `new`, then prove it.
    ///
    /// **Precondition:** `current` has already been presented successfully this
    /// activation. §9.5.3.3 requires it before `WRITE_PASSWORD` is honoured at
    /// all, and this method deliberately does not send that frame itself, so a
    /// caller cannot accidentally spend its one password attempt here.
    ///
    /// ## The lost-ACK rule
    ///
    /// A `01 0F` on `WRITE_PASSWORD` is not proof of failure. §9.6 gives the
    /// SLIX2 one refusal code for everything, and 2026-08-09 caught a
    /// `LOCK_BLOCK` answering `01 0F` at 29 ms where every sibling answered in
    /// ~11 ms: a lost ACK on a write that had landed. The same shape has to be
    /// assumed here, so the chip is consulted instead of believed.
    ///
    /// **The probe re-presents the OLD value, never the new one.** Presenting
    /// `new` when the write did not land is an invalid password and kills the
    /// tap for nothing; presenting `current` is only invalid in the case where
    /// the write *did* land, which is the outcome that was wanted anyway.
    ///
    /// This is reasoned from §9.5.3.2 and the 2026-08-09 observation, **not**
    /// from an observed `WRITE_PASSWORD` failure. It is still strictly better
    /// than the unconditional throw it replaces, which lost the same tap *and*
    /// returned the wrong verdict.
    private func assignPassword(
        _ kind: PasswordKind,
        to new: Data,
        presenting current: Data,
        flag: UInt8 = Self.selectedFlag
    ) async throws -> Type5AssignOutcome {
        guard new != current else { return .assigned }
        if try await writePassword(kind, new, flag: flag) {
            return try await proveHolds(kind, new, flag: flag) ? .assigned : .notAssigned
        }
        // Undetermined. Ask the chip which of the two values it holds.
        guard try await proveHolds(kind, current, flag: flag) else {
            return .probablyAssignedTapPoisoned
        }
        // The tag still holds `current`, so the frame genuinely did not land and
        // the tap is still alive. Exactly one retry, then the verdict stands.
        guard try await writePassword(kind, new, flag: flag) else { return .notAssigned }
        return try await proveHolds(kind, new, flag: flag) ? .assigned : .notAssigned
    }

    /// Present `password` and report whether the chip accepted it.
    ///
    /// Only a **stated** refusal is `false`. A presentation that never completed
    /// is rethrown, because "the tag stopped talking" is not "the password is
    /// wrong", and collapsing the two is what kept the 2026-09-04 incident
    /// going: every transport loss was remapped into a wrong-password verdict.
    private func proveHolds(_ kind: PasswordKind, _ password: Data, flag: UInt8) async throws -> Bool {
        do {
            try await setPassword(kind, password, flag: flag)
            return true
        } catch let error as TagError {
            guard case .authFailed = error.kind else { throw error }
            return false
        }
    }

    // MARK: - SLIX2 command steps

    /// `SELECT (0x25)`: move the tag into the Selected state so the password
    /// commands (which the chip honours only in Addressed or Selected mode,
    /// §9.5.3.2/3.3) can be sent with the Select flag instead of a UID.
    ///
    /// Every flow that touches a gated command calls this first. The state
    /// lasts until the tag leaves the field, so once per tap is enough, and
    /// re-selecting an already-selected tag is a harmless re-acknowledgement.
    private func select() async throws {
        let resp = try await send([Self.flag, Iso15693Opcode.select])
        guard resp.first == 0x00 else {
            throw TagError.protocolError("SELECT refused", diagnostics: "resp=\(resp.hexString)")
        }
    }

    /// `GET_RANDOM_NUMBER (0xB2)` to a 2-byte nonce. Must immediately precede
    /// each SET_PASSWORD so the XOR mask matches. All-modes command, so it keeps
    /// the plain non-addressed flag (a Selected-state tag still answers those),
    /// and it is one of only two commands a privacy-mode tag answers (§9.5.3.9).
    private func getRandom() async throws -> Data {
        let resp = try await send([Self.flag, 0xB2])
        guard resp.first == 0x00, resp.count >= 3 else {
            throw TagError.protocolError("GET_RANDOM failed", diagnostics: resp.hexString)
        }
        return resp.subdata(in: (resp.startIndex + 1) ..< (resp.startIndex + 3))
    }

    /// `SET_PASSWORD (0xB3)`: presents (verifies) a password. Selected-mode
    /// frame by default; a non-addressed one is silently ignored by the chip
    /// (§9.5.3.2), **except** for the privacy identifier, which has to work
    /// unaddressed because a privacy tag cannot be inventoried or selected.
    ///
    /// ⚠️ A wrong password does worse than fail: "If the IC receives an invalid
    /// password, it will not execute any following command until a Power-On
    /// Reset", so no caller may retry in-session; the tag must leave the field
    /// first.
    private func setPassword(_ kind: PasswordKind, _ password: Data, flag: UInt8 = Self.selectedFlag) async throws {
        let resp: Data
        do {
            resp = try await setPasswordRaw(kind, password, flag: flag)
        } catch let error as TagError where error.kind == .tagLost {
            // Silence is not a refusal. It is either the lockout from an earlier
            // wrong password (§9.5.3.2), a frame the chip ignored, or a tag that
            // left the field, and none of those is "wrong password".
            throw TagError.authInconclusive(
                diagnostics: "SET_PASSWORD(\(kind)) did not complete: \(error.diagnostics)"
            )
        }
        guard resp.first == 0x00 else {
            throw TagError.authFailed(
                diagnostics: "SET_PASSWORD(\(kind)) resp=\(resp.hexString)"
            )
        }
    }

    /// The frame pair without the verdict: a fresh nonce, then the XOR-masked
    /// presentation. Used directly only where the *answer* is the observation,
    /// as in `armPrivacy`'s rehearsal of the unaddressed exit route.
    private func setPasswordRaw(_ kind: PasswordKind, _ password: Data, flag: UInt8) async throws -> Data {
        let random = try await getRandom()
        let mask = Data([random[random.startIndex], random[random.startIndex + 1],
                         random[random.startIndex], random[random.startIndex + 1]])
        let xored = NTAG424Crypto.xor(password, mask)
        return try await send([flag, 0xB3, kind.rawValue] + xored, secret: true)
    }

    /// `PROTECT PAGE (0xB6)`: the command that actually arms or clears write and
    /// read protection (§9.5.3.6). Needs the read and write passwords presented
    /// first, and refuses once the condition is locked by `B7h`. Selected-mode
    /// frame, like every gated command.
    private func protectPage(pointer: UInt8, protection: PageProtection) async throws {
        let resp = try await send([Self.selectedFlag, 0xB6, pointer, protection.rawValue])
        guard resp.first == 0x00 else {
            throw TagError.protocolError(
                "PROTECT PAGE failed",
                diagnostics: "pointer=\(hex(pointer)) status=\(hex(protection.rawValue)) resp=\(resp.hexString)"
            )
        }
    }

    /// `WRITE_PASSWORD (0xB4)`: change a password after it has been verified.
    /// Selected-mode frame; the chip ignores it non-addressed (§9.5.3.3).
    ///
    /// Returns whether the chip **acknowledged**, and throws only on a transport
    /// failure. It deliberately does not treat a refusal as a verdict: this
    /// silicon answers the generic `0F` to everything (§9.6) and has been
    /// observed answering an error frame to a write-alike command that landed
    /// (2026-08-09). `assignPassword` owns the verdict, and it reaches it by
    /// asking the chip what it holds.
    private func writePassword(
        _ kind: PasswordKind,
        _ newPassword: Data,
        flag: UInt8 = Self.selectedFlag
    ) async throws -> Bool {
        let resp = try await send([flag, 0xB4, kind.rawValue] + newPassword, secret: true)
        return resp.first == 0x00
    }

    /// `ENABLE_PRIVACY (0xBA)`: flip the privacy bit (gating reads) with the
    /// XOR-masked privacy password.
    ///
    /// Sent unaddressed. The repo's own gated-command table excludes BAh and
    /// this has been the shape since the command was written, but **that path
    /// has never run on silicon**, so whether the chip requires Addressed or
    /// Selected mode here is not verified.
    private func enablePrivacy(_ password: Data) async throws {
        let random = try await getRandom()
        let mask = Data([random[random.startIndex], random[random.startIndex + 1],
                         random[random.startIndex], random[random.startIndex + 1]])
        let xored = NTAG424Crypto.xor(password, mask)
        let resp = try await send([Self.flag, 0xBA] + xored, secret: true)
        guard resp.first == 0x00 else {
            throw TagError.protocolError("ENABLE_PRIVACY failed", diagnostics: resp.hexString)
        }
    }

    // MARK: - Transport

    private func requireFourBytes(_ data: Data, _ label: String) throws {
        guard data.count == 4 else {
            throw TagError.protocolError("\(label) must be 4 bytes", diagnostics: "len=\(data.count)")
        }
    }

    private func hex(_ byte: UInt8) -> String {
        String(format: "%02X", byte)
    }

    /// True when `response` is an ISO 15693 error frame (`0x01 ‖ code`). When
    /// `code` is non-nil, also requires that specific error code.
    private func isError(_ response: Data, code: UInt8?) -> Bool {
        guard response.first == 0x01, response.count >= 2 else { return false }
        guard let code else { return true }
        return response[response.startIndex + 1] == code
    }

    private func send(_ bytes: [UInt8], secret: Bool = false) async throws -> Data {
        let command = RawCommand(
            bytes: Data(bytes),
            name: "slix:\(String(format: "%02X", bytes.count > 1 ? bytes[1] : 0))",
            family: .type5(.icodeSlix)
        )
        return try await transceive(command)
    }
}
