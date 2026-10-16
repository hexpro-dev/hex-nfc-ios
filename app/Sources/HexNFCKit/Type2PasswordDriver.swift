import Foundation
import HexNFCRecords

/// Factory values every NTAG21x / MIFARE Ultralight EV1 ships with, and the
/// values this app's removal path writes back.
///
/// Centralised because they were literals at four sites that had to agree:
/// the production removal, the simulator, the harness plans, and the tests.
/// Sources: NXP NTAG213/215/216 rev 3.2 Table 5 and MF0ULX1 rev 3.3 Table 8,
/// "memory content at delivery".
public enum Type2Credential {
    /// The 4-byte PWD at delivery, and what a removal writes back.
    public static let factoryPassword = Data([0xFF, 0xFF, 0xFF, 0xFF])
    /// The 2-byte PACK at delivery.
    public static let factoryPack = Data([0x00, 0x00])
    /// The full 4-byte PACK *page* image: PACK followed by two RFUI bytes.
    public static let factoryPackPage = Data([0x00, 0x00, 0x00, 0x00])
    /// AUTH0 value that gates nothing: it points past the last page every one of
    /// these chips has. The sibling of `UltralightCLayout.protectionOff`.
    public static let protectionOff: UInt8 = 0xFF
}

/// The two configuration bytes that decide what a Type-2 tag gates, decoded.
///
/// Deliberately carries **no PWD or PACK bytes**. A Type-2 chip answers a READ
/// of those pages with zeros by design (NTAG213 rev 3.2 §8.8), so a field
/// holding them could only ever hold a lie, and naming one would invite a
/// read-back comparison that passes against a simulator and fails on silicon.
public struct Type2ProtectionConfig: Hashable, Sendable {
    /// CFG0 exactly as the tag returned it. Kept whole because AUTH0 is written
    /// by read-modify-write and bytes 0-2 (MIRROR, RFUI, MIRROR_PAGE) must
    /// survive untouched.
    public let config0: Data
    /// CFG1 exactly as the tag returned it. Byte 1 reads `05h` on a factory
    /// NTAG213 where the datasheet's RFUI column says zero, so preserving it
    /// rather than normalising it is load-bearing.
    public let config1: Data
    /// The highest page this chip addresses (`Type2ConfigLayout.packPage`). An
    /// AUTH0 above it points past the end of memory and gates nothing.
    public let lastAddressablePage: Int

    public init(config0: Data, config1: Data, lastAddressablePage: Int) {
        self.config0 = config0
        self.config1 = config1
        self.lastAddressablePage = lastAddressablePage
    }

    public var auth0: UInt8 {
        config0[config0.startIndex + Type2ConfigLayout.auth0ByteOffset]
    }

    public var access: UInt8 {
        config1[config1.startIndex + Type2ConfigLayout.accessByteOffset]
    }

    /// `true` when AUTH0 names a page the chip actually has, i.e. something is
    /// gated. Compares against the last addressable page rather than testing
    /// `== 0xFF`, so any out-of-range value that also means "nothing protected"
    /// cannot be misread as armed.
    public var isGateArmed: Bool {
        Int(auth0) <= lastAddressablePage
    }

    public var readProtect: Bool {
        (access & Type2ConfigLayout.protBitMask) != 0
    }

    public var authLimit: Int {
        Int(access & Type2ConfigLayout.authLimMask)
    }

    /// Project into the app-wide settings type. `hasStoredCredential` is always
    /// false: a PWD is never recoverable from a tag.
    public var protection: TagProtection {
        guard isGateArmed else { return TagProtection.none }
        return TagProtection(
            passwordProtect: true,
            protectFromPage: Int(auth0),
            readProtect: readProtect,
            authLimit: authLimit,
            hasStoredCredential: false
        )
    }

    /// CFG0 with AUTH0 replaced, every other byte preserved.
    public func config0(settingAuth0 value: UInt8) -> Data {
        var updated = Data(config0.prefix(4))
        updated[updated.startIndex + Type2ConfigLayout.auth0ByteOffset] = value
        return updated
    }

    /// CFG1 with PROT and AUTH_LIM replaced, every other bit preserved.
    public func config1(readProtect: Bool, authLimit: Int) -> Data {
        var updated = Data(config1.prefix(4))
        let index = updated.startIndex + Type2ConfigLayout.accessByteOffset
        var access = updated[index]
        access &= ~(Type2ConfigLayout.protBitMask | Type2ConfigLayout.authLimMask)
        if readProtect {
            access |= Type2ConfigLayout.protBitMask
        }
        access |= UInt8(authLimit) & Type2ConfigLayout.authLimMask
        updated[index] = access
        return updated
    }
}

/// What a configuration read established, keeping apart the two answers a `try?`
/// used to collapse into one.
public enum Type2StateReading: Hashable, Sendable {
    /// The configuration pages were read. The only reading that carries values.
    case read(Type2ProtectionConfig)
    /// A `30 03` READ rolled over to pages 0 and 1: the pages above the
    /// Capability Container are gated, so the configuration pages cannot be read
    /// until a PWD_AUTH succeeds. **No gated frame was sent, so the tag has not
    /// halted** and an authentication may follow immediately.
    case gatedByReadProtection
}

/// Pages 0 and 1 (and BCC1) rebuilt from a 7-byte UID: the signature a
/// read-protected Type-2 tag echoes when a READ rolls over.
///
/// One definition, shared by the driver and the app's presence probe, because
/// two implementations of the same signature can drift and one cannot.
public enum Type2Rollover {
    /// `SN0 SN1 SN2 BCC0 SN3 SN4 SN5 SN6 BCC1`, or `nil` for any tag without a
    /// 7-byte UID (which simply skips the check).
    ///
    /// Nine bytes rather than eight: with roll-over the fourth served page is
    /// page 2, whose first byte is `BCC1 = SN3^SN4^SN5^SN6`. Including it costs
    /// nothing and takes an accidental match on ordinary record data from
    /// 2^-64 to 2^-72.
    public static func signature(forUID uid: Data) -> Data? {
        guard uid.count == 7 else { return nil }
        let b = [UInt8](uid)
        let bcc0 = 0x88 ^ b[0] ^ b[1] ^ b[2]
        let bcc1 = b[3] ^ b[4] ^ b[5] ^ b[6]
        return Data([b[0], b[1], b[2], bcc0, b[3], b[4], b[5], b[6], bcc1])
    }

    /// Byte range within a 16-byte `30 03` reply where the signature would land.
    public static let signatureRange: Range<Int> = 4 ..< 13
}

/// Drives a Type-2 chip's password hardware over a raw `transceive` closure.
///
/// Production wires `CoreNFCConnectedTag.transceive`; tests wire a simulator.
/// Structured like `Type2LockDriver`, `UltralightCProtectionDriver` and
/// `NTAG424ProtectionDriver`, and for the same reason: the frames this app puts
/// on the wire have to be the frames a test replays. Type-2 password was the
/// last family still on a pair of parallel implementations, one in
/// `CoreNFCConnectedTag` and one in the simulator, and it is the family that
/// failed on real silicon.
///
/// ## The rules this driver exists to enforce
///
/// 1. **State first.** Nothing authenticates before it has read what the tag
///    says it is gating. A tag whose AUTH0 already points past its last page
///    gets no PWD_AUTH at all, because a refused one NAKs and a NAK halts the
///    chip for the rest of the activation.
/// 2. **A read-back is the success criterion.** `disable` has succeeded when
///    CFG0 reads back with AUTH0 open, not when four writes have been ACKed.
/// 3. **Tidy-up cannot fail the operation.** Once the gate reads open, the PWD
///    and PACK resets are best effort: they report residue and never throw.
///    This is precisely the abort point that stranded a real tag.
/// 4. **One authentication attempt per activation.** A refused `PWD_AUTH` NAKs,
///    and a NAK halts the chip until it is re-selected, so there is no such
///    thing as a second try in the same tap. Anything that wants to present a
///    different credential has to be a new tap, and that belongs to the UI. See
///    `openGate` for why the factory-default retry is deliberately not here.
public struct Type2PasswordDriver: Sendable {
    /// Raw command channel. Responses include the leading status byte.
    public let transceive: @Sendable (RawCommand) async throws -> Data
    public let layout: Type2ConfigLayout
    /// The tag's UID, used only to recognise a read roll-over. `nil` skips that
    /// check, which costs a diagnostic and nothing else.
    public let uid: Data?

    public init(
        layout: Type2ConfigLayout,
        uid: Data? = nil,
        transceive: @escaping @Sendable (RawCommand) async throws -> Data
    ) {
        self.layout = layout
        self.uid = uid
        self.transceive = transceive
    }

    static let read: UInt8 = 0x30
    static let write: UInt8 = 0xA2
    static let pwdAuth: UInt8 = 0x1B
    static let ack: UInt8 = 0x0A
    static let pageSize = 4
    /// The Capability Container. It sits below every AUTH0 this app writes, so
    /// asking for it can never trip protection.
    static let capabilityContainerPage = 3

    // MARK: - State

    /// Read what the tag says it is gating. One frame when the configuration
    /// block is contiguous, which it is on every chip in the catalogue.
    ///
    /// Non-mutating and, on a write-only-protected tag (the common case), not
    /// gated either: the configuration pages answer a READ fine. A fully
    /// read-protected tag rolls the READ over to page 0 instead, which is a
    /// positive proof of read protection rather than a refusal, and costs no NAK.
    public func readState() async throws -> Type2StateReading {
        if let rollover = try await detectReadProtection() {
            return rollover
        }
        let config0: Data
        let config1: Data
        if layout.configBlockIsContiguous {
            let block = try await readPages(startPage: layout.config0Page)
            guard block.count >= Self.pageSize * 2 else {
                throw TagError.malformedResponse(
                    block,
                    diagnostics: "config block read returned \(block.count)B, need 8"
                )
            }
            config0 = Data(block.prefix(Self.pageSize))
            config1 = Data(block.dropFirst(Self.pageSize).prefix(Self.pageSize))
        } else {
            config0 = try await readPages(startPage: layout.config0Page).prefix(Self.pageSize)
            config1 = try await readPages(startPage: layout.config1Page).prefix(Self.pageSize)
        }
        guard config0.count == Self.pageSize, config1.count == Self.pageSize else {
            throw TagError.malformedResponse(
                config0 + config1,
                diagnostics: "config read short: cfg0=\(config0.count)B cfg1=\(config1.count)B"
            )
        }
        return .read(Type2ProtectionConfig(
            config0: config0,
            config1: config1,
            lastAddressablePage: layout.packPage
        ))
    }

    /// The verdict a caller may file about a gate it read **before** presenting a
    /// credential. It is a read-back, which is what `GateVerdict` requires.
    ///
    /// The page is withheld when a roll-over could have forged it: without a
    /// 7-byte UID `detectReadProtection` returns `nil` without reading, so a
    /// rolled-over page 0 can reach `Type2ProtectionConfig` and its byte 3 is
    /// BCC0, not AUTH0. Same guard, same reason, as `Type2LockDriver.refuseIfGated`.
    private func gateVerdictFromReading(_ config: Type2ProtectionConfig) -> ProtectionResidue.GateVerdict {
        guard uid.flatMap(Type2Rollover.signature(forUID:)) != nil else { return .unknown }
        return .provenArmed(fromPage: Int(config.auth0))
    }

    /// The attempt limit this configuration reports, or `nil` when a roll-over
    /// could have forged it.
    ///
    /// Same guard, same reason, as `gateVerdictFromReading` immediately above:
    /// without a 7-byte UID a rolled-over page 0 can reach
    /// `Type2ProtectionConfig`, and its ACCESS byte is then a UID byte rather
    /// than CFG1. A limit is about to change what the user is told about their
    /// password, so a forged one may not reach the copy.
    private func attemptLimitFromReading(_ config: Type2ProtectionConfig) -> Int? {
        guard uid.flatMap(Type2Rollover.signature(forUID:)) != nil else { return nil }
        return config.authLimit
    }

    /// One `30 03`. Returns `.gatedByReadProtection` when the tag echoes pages 0
    /// and 1 instead of serving the pages above the Capability Container, and
    /// `nil` when it served them normally.
    private func detectReadProtection() async throws -> Type2StateReading? {
        guard let uid, let signature = Type2Rollover.signature(forUID: uid) else { return nil }
        let bytes = try await readPages(
            startPage: Self.capabilityContainerPage,
            shortAnswer: .isNotAVerdict
        )
        // `readPages` answers sixteen bytes or throws, so this cannot fire. It
        // throws rather than returning `nil` because `nil` means "not read-gated",
        // and a short answer establishes no such thing.
        guard bytes.count >= Type2Rollover.signatureRange.upperBound else {
            throw TagError.malformedResponse(
                bytes,
                diagnostics: "READ p\(Self.capabilityContainerPage) answered \(bytes.count)B, "
                    + "too short to check for a roll-over"
            )
        }
        let served = Data(bytes[Type2Rollover.signatureRange])
        return served == signature ? .gatedByReadProtection : nil
    }

    /// The app-wide settings projection, or `nil` when the chip has no password
    /// hardware to report on.
    public func readProtectionState() async throws -> TagProtection? {
        switch try await readState() {
        case .read(let config):
            config.protection

        case .gatedByReadProtection:
            // The pages above the CC are gated, so the configuration pages are
            // out of reach. What that proves is that protection is on and covers
            // reads; the page it starts from cannot be known without a password.
            TagProtection(
                passwordProtect: true,
                protectFromPage: nil,
                readProtect: true,
                authLimit: 0,
                hasStoredCredential: false
            )
        }
    }

    // MARK: - Opening the gate

    /// Open the tag's gate, consulting the tag before presenting anything.
    ///
    /// Returns `.alreadyOpen` without sending a single authentication frame when
    /// the tag's own configuration says nothing is gated. That is the case the
    /// incident produced and the app could not see: a tag whose removal had
    /// already switched protection off, being asked over and over for a password
    /// it no longer had, halting on every NAK.
    ///
    /// ## Why there is no factory-default retry here
    ///
    /// "Try what we ourselves write" is a real rule, and this is the wrong place
    /// for it. **A Type-2 chip answers a wrong password with a NAK, and a NAK
    /// returns it to HALT for the rest of the activation** (the same behaviour
    /// that makes a refused password look like "Tag connection lost"). So a
    /// second `PWD_AUTH` in the same tap is answered by nothing at all: one
    /// attempt per activation is all the silicon offers. A retry with the
    /// factory default therefore has to be a *second tap*, offered by the UI.
    ///
    /// The UI that offers it is `OperationsFlowModel.retryWithFactoryDefault()`,
    /// which substitutes `Type2Credential.factoryPassword` into the operation and
    /// re-runs the whole two-tap flow, typed-UID gate included. Nothing is
    /// reported back through `GateOpening`: this driver cannot tell a recovery
    /// tap from an ordinary one, and a route for it would be a claim about a
    /// refusal that happened in some earlier activation.
    ///
    /// This was caught by the simulator's halt-on-NAK modelling after the retry
    /// had been written into this method, which is the harness doing exactly its
    /// job: the shipped frames now run in CI, so a design that only worked
    /// against an idealised chip failed before it reached silicon.
    public func openGate(password: Data) async throws -> GateOpening {
        let state = try await readState()
        if case .read(let config) = state, !config.isGateArmed {
            return GateOpening(route: .alreadyOpen)
        }
        // The reading is nine milliseconds old and is discarded one line later
        // unless it is carried. A refusal earns different copy on a tag that
        // reported a limit, because on that tag "wrong password" is a claim the
        // frame does not support: an exhausted `AUTH_LIM` refuses the correct
        // password exactly as it refuses a wrong one (measured 2026-09-10,
        // `bench-traces/2026-09-10-t2-1-ntag213.log`).
        let limit: Int? = if case .read(let config) = state {
            attemptLimitFromReading(config)
        } else {
            nil
        }
        do {
            let pack = try await authenticate(password: password)
            return GateOpening(route: .authenticated, response: pack)
        } catch let error as TagError {
            // A read-gated tag hides `AUTH_LIM` behind the password being
            // presented, so `limit` is nil here for a reason that is not "this
            // tag has no limit". Said that way, the refusal reaches the unlock
            // prompt as an ordinary one and the prompt comes back in its neutral
            // first-run copy, which is how the same wrong password gets pressed
            // a second time on the one kind of tag where the app cannot see the
            // counter move.
            if case .gatedByReadProtection = state {
                throw error.qualifiedByAHiddenAttemptLimit()
            }
            throw error.qualifiedByAttemptLimit(limit)
        }
    }

    /// The raw primitive: always sends `1B`, never consults state. Callers that
    /// want the state-first behaviour want `openGate` instead.
    ///
    /// A refusal and a lost tag are reported as different errors. Conflating
    /// them is what told a user their password was wrong when the tag had simply
    /// stopped answering.
    public func authenticate(password: Data) async throws -> Data {
        guard password.count == 4 else {
            throw TagError.protocolError("PWD must be 4 bytes", diagnostics: "len=\(password.count)")
        }
        var frame = Data([Self.pwdAuth])
        frame.append(password)
        let response: Data
        do {
            response = try await transceive(RawCommand(bytes: frame, name: "PWD_AUTH"))
        } catch let error as TagError where error.kind == .tagLost {
            // A wrong password NAKs, and a NAK returns a Type-2 chip to HALT for
            // the rest of the activation, so CoreNFC reports the whole session
            // gone. That looks identical to a tag leaving the field. The chip
            // does not tell us which, so neither do we.
            throw TagError.authInconclusive(
                diagnostics: "PWD_AUTH did not complete: \(error.diagnostics)"
            ).afterPresentingACredential()
        }
        // Success is a 2-byte PACK. A 1-byte NAK, or anything shorter, is a
        // refusal the chip actually stated.
        guard response.count >= 2 else {
            throw TagError.authFailed(
                diagnostics: "PWD_AUTH refused: resp=\(response.hexString)"
            ).afterPresentingACredential()
        }
        return Data(response.prefix(2))
    }

    /// `authenticate`, for a caller that has already read this tag as
    /// read-gated, so the refusal carries what that state costs.
    ///
    /// The gated arms cannot use `openGate`: it reads the state first, and on
    /// this tag that read is the one the chip refuses. They send the raw
    /// primitive instead, which until now meant their refusals lost the one
    /// thing worth saying about a read-protected tag, that `AUTH_LIM` sits
    /// behind the gate and a wrong try may have counted against it. The
    /// qualification lives here rather than in each caller so the reasoning
    /// stays beside the datasheet note it comes from.
    public func authenticateThroughAReadGate(password: Data) async throws -> Data {
        do {
            return try await authenticate(password: password)
        } catch let error as TagError {
            throw error.qualifiedByAHiddenAttemptLimit()
        }
    }

    /// Present the credential to a gate the caller has **already read as armed**,
    /// and record the attempt in the residue either way.
    ///
    /// ## Why the caller's own state read is the precondition
    ///
    /// `openGate` reads the state itself, which is right for a caller that has
    /// not. `enable` and `disable` have: they read the configuration block, kept
    /// it (they need `config0`/`config1` verbatim for the read-modify-write), and
    /// only reach this when `isGateArmed`. Going through `openGate` from there
    /// sent a second READ whose answer was thrown away, and made the failure
    /// ambiguous: an error out of `openGate` could be that second READ failing,
    /// with no `PWD_AUTH` sent at all. `authenticate` always sends the frame, so
    /// what this records is what happened.
    ///
    /// ## Why the attempt is recorded rather than left to the error
    ///
    /// The error cannot carry it. A stated refusal is `.authFailed` and a
    /// transport loss is `.authInconclusive`, and **which of the two a phone
    /// produces for a wrong password is still not settled in this repo**, though
    /// the evidence now leans hard one way. A NAK returns a Type-2 chip to HALT,
    /// `CoreNFCSession` says a NAK arrives "as a 1-byte payload or a transport
    /// error, depending on iOS version", and **both** live captures are the
    /// transport form: 2026-08-07 on an NTAG216 and 2026-09-09 on an NTAG213
    /// (`docs/internal/bench-traces/2026-09-09-t2-3-x-2-ntag213.log`), two chips,
    /// the same answer. The payload form has no live capture at all; the
    /// simulator produces it, which is the whole problem. So a flow that branched
    /// on the kind to decide whether a credential had been refused would be green
    /// in CI and silent on a phone, which is the failure mode CLAUDE.md names
    /// twice.
    ///
    /// The distinction stays. Two captures on two chips is not proof that no iOS
    /// version anywhere hands up the payload, and `.authFailed` is in any case
    /// live for every non-Type-2 unlock, where it comes off a status word or a
    /// payload the tag really did return.
    ///
    /// What is not in doubt is what this driver did: it consulted the tag, found
    /// the gate armed, and put exactly one `PWD_AUTH` on the wire. A failed
    /// `.gateOpened` step says that and nothing more, and it rides out on
    /// `TagError.protectionIncomplete` so a flow can offer a second tap without
    /// guessing at an error code.
    ///
    /// The user-facing message is the one `authenticate` chose. The residue's own
    /// copy is written for a sequence that tore partway, and nothing here has
    /// been written to.
    ///
    /// ## Why the caller supplies the gate verdict
    ///
    /// `gateOnFailure` is what the caller read from the tag in this same
    /// activation, moments ago. A refusal means nothing was written, so that
    /// reading is still the truth about the gate, and `GateVerdict`'s contract is
    /// satisfied because it came off a read-back rather than an assumption. A
    /// caller with nothing to file passes `.unknown`; nothing here invents one.
    ///
    /// `limitIsHidden` is for the callers that reached here through a read gate.
    /// They could not read `AUTH_LIM` at all, because the pages holding it are
    /// behind the password being presented, and "no limit was read" would tell
    /// the user the opposite of what is true: on that tag a wrong try may well
    /// have counted. See `TagError.qualifiedByAHiddenAttemptLimit`.
    private func presentCredential(
        password: Data,
        gateOnFailure: ProtectionResidue.GateVerdict,
        attemptLimit: Int? = nil,
        limitIsHidden: Bool = false,
        into residue: inout ProtectionResidue
    ) async throws {
        // Validated here rather than left to `authenticate`, because this method's
        // whole contract is "a PWD_AUTH went out and did not open the gate", and
        // the flow-level recovery offer is built on that being true. A length
        // rejection throws before a single byte reaches the transport, so letting
        // it fall into the catch below would record an attempt that never
        // happened and offer the user a second tap to recover from nothing.
        guard password.count == 4 else {
            throw TagError.protocolError("PWD must be 4 bytes", diagnostics: "len=\(password.count)")
        }
        do {
            _ = try await authenticate(password: password)
        } catch let error as TagError {
            // Filed before the rewrap: the residue is copied by value into
            // `.protectionIncomplete` below and rendered into `diagnostics` with
            // it, so a mutation after the throw is dead.
            residue.gate = gateOnFailure
            residue.record(failure: .gateOpened, "PWD_AUTH did not open the gate: \(error.diagnostics)")
            let qualified = limitIsHidden
                ? error.qualifiedByAHiddenAttemptLimit()
                : error.qualifiedByAttemptLimit(attemptLimit)
            throw TagError(
                kind: .protectionIncomplete(residue),
                userMessage: qualified.userMessage,
                diagnostics: residue.diagnostics,
                limitReading: qualified.limitReading
            )
        }
        residue.record(.gateOpened)
    }

    // MARK: - Credential

    /// Write the credential pages. Does **not** enable protection: on its own
    /// this stores a password that gates nothing.
    @discardableResult
    public func setCredential(password: Data, pack: Data) async throws -> ProtectionResidue {
        guard password.count == 4, pack.count == 2 else {
            throw TagError.protocolError(
                "PWD=4B PACK=2B required",
                diagnostics: "pwd=\(password.count) pack=\(pack.count)"
            )
        }
        var residue = ProtectionResidue(family: .type2, intent: .setCredential)
        try await writePage(layout.pwdPage, bytes: password, label: "PWD", into: &residue, step: .credentialWritten)
        try await writePage(
            layout.packPage,
            bytes: pack + Data([0x00, 0x00]),
            label: "PACK",
            into: &residue,
            step: .packWritten
        )
        residue.credential = .callerSupplied
        return residue
    }

    // MARK: - Enable

    /// Arm password protection.
    ///
    /// Order is load-bearing and unchanged in spirit from what shipped: the
    /// credential goes down before the gate goes up, so every abort point leaves
    /// a tag that is open (and therefore fixable) rather than one gated behind a
    /// password that may not have landed.
    ///
    /// What is new: an already-protected tag is authenticated first instead of
    /// having its PWD write refused, and the gate is read back and the
    /// credential proven before this reports success.
    @discardableResult
    public func enable(
        password: Data,
        pack: Data,
        protectFromPage: Int,
        readProtect: Bool,
        authLimit: Int,
        currentPassword: Data? = nil
    ) async throws -> ProtectionResidue {
        guard password.count == 4 else {
            throw TagError.protocolError("PWD must be 4 bytes", diagnostics: "len=\(password.count)")
        }
        guard pack.count == 2 else {
            throw TagError.protocolError("PACK must be 2 bytes", diagnostics: "len=\(pack.count)")
        }
        guard (0 ... 0xFF).contains(protectFromPage) else {
            throw TagError.protocolError("protectFromPage out of range", diagnostics: "\(protectFromPage)")
        }
        guard (0 ... 7).contains(authLimit) else {
            throw TagError.protocolError("authLimit must be 0…7", diagnostics: "\(authLimit)")
        }

        var residue = ProtectionResidue(family: .type2, intent: .enable)
        guard case .read(let config) = try await readState() else {
            throw TagError.readProtected(
                diagnostics: "cannot arm protection on a tag whose config pages are already read-gated"
            )
        }
        residue.record(.stateRead)

        // An armed tag refuses a PWD write. Authenticating first is what makes
        // changing a password, or finishing a half-applied one, possible at all.
        //
        // No `authenticatedWithFactoryDefault` to record. This driver only ever
        // presents the one credential it was handed, and a fallback is a second
        // tap the flow above chooses.
        let arrivedArmed = config.isGateArmed
        if arrivedArmed {
            try await presentCredential(
                password: currentPassword ?? password,
                gateOnFailure: gateVerdictFromReading(config),
                attemptLimit: attemptLimitFromReading(config),
                into: &residue
            )
        }

        do {
            try await writePage(
                layout.pwdPage, bytes: password, label: "PWD", into: &residue, step: .credentialWritten
            )
            try await writePage(
                layout.packPage,
                bytes: pack + Data([0x00, 0x00]),
                label: "PACK",
                into: &residue,
                step: .packWritten
            )
            residue.credential = .callerSupplied

            try await writePage(
                layout.config1Page,
                bytes: config.config1(readProtect: readProtect, authLimit: authLimit),
                label: "ACCESS",
                into: &residue,
                step: .accessWritten
            )
        } catch {
            // Say which half of the credential landed: a PWD that took while the
            // PACK did not is a tag whose stored credential no longer matches
            // what the caller holds. `.unchanged` would be a plain misstatement
            // there, and the copy the residue chooses is built on this verdict:
            // it would have told the owner the password they typed never
            // reached the tag, about a tag that now answers to it.
            if residue.completed.contains(.credentialWritten), !residue.completed.contains(.packWritten) {
                residue.credential = .unknown(
                    reason: "the password was written and the PACK was not, so the tag answers the "
                        + "new password and returns the PACK it had before"
                )
            }

            // The gate verdict turns on how the tag *arrived*, and it used to
            // ignore that. `residue.gate = .provenOpen` was set here
            // unconditionally, under the comment "the gate was never armed, so
            // the tag is still open". True of a tag that arrived unarmed: AUTH0
            // is written last, further down, and this abort point is above it.
            // False of a re-key, where the tag arrived armed, this driver
            // authenticated past the gate, and AUTH0 is still exactly where the
            // tag had it. Claiming `provenOpen` there asserts a protection state
            // nothing read, on the one report a user acts on.
            residue.gate = arrivedArmed ? .unknown : .provenOpen
            throw TagError.protectionIncomplete(
                residue,
                diagnostics: arrivedArmed
                    ? "protection not re-keyed; this tag arrived armed and its gate has not been re-read: \(error)"
                    : "protection not armed; the tag is still unprotected: \(error)"
            )
        }
        if authLimit > 0 {
            residue.record(.attemptLimitWritten)
        }

        // AUTH0 last: it is the activation step, and until it lands the tag is
        // simply unprotected rather than half-protected.
        do {
            try await writePage(
                layout.config0Page,
                bytes: config.config0(settingAuth0: UInt8(protectFromPage)),
                label: "AUTH0",
                into: &residue,
                step: .gateArmed
            )
        } catch {
            // AUTH0 is the write that arms the gate, which makes this the one
            // abort point where the reading taken on the way in cannot be reused.
            // A stated refusal means the tag is exactly as it arrived; a lost
            // answer means it may now be armed with the credential written a few
            // lines above. `writePage` throws for both, and the two are not
            // distinguishable from the throw.
            //
            // So ask the chip rather than reason about it, which is CLAUDE.md's
            // "a refusal may be a lost ACK" on the write that decides whether the
            // user's tag still opens. A read that answers settles it; a read that
            // does not leaves `.unknown`, and `.unknown` is what sends the user
            // back for another tap instead of telling them a possibly gated tag
            // is open.
            residue.gate = .unknown
            var followUp = "AUTH0 write failed: \(error)"
            if case .read(let after)? = try? await readState() {
                residue.gate = after.isGateArmed
                    ? .provenArmed(fromPage: Int(after.auth0))
                    : .provenOpen
                residue.record(.gateProven)
                followUp += "; a read afterwards found the gate "
                    + (after.isGateArmed ? "armed at page \(after.auth0)" : "open")
            } else {
                followUp += "; the gate could not be re-read, so whether it armed is not known"
            }
            throw TagError.protectionIncomplete(residue, diagnostics: followUp)
        }

        // Prove it, rather than believing four ACKs. The gate read-back is
        // affordable here because a write-only gate still serves reads; a
        // read-protected one does not, and PWD_AUTH is how we get back in.
        if readProtect {
            _ = try? await authenticate(password: password)
        }

        // **Nothing below this line may report a bare transport failure.** PWD,
        // PACK, ACCESS and AUTH0 have all been written and acknowledged, so the
        // tag is armed with the credential the caller handed in. A `try` here
        // threw `.tagLost` straight past the residue, and the user was told the
        // tag had been lost about a tag now holding their new password: exactly
        // the desync this driver was rewritten to stop. A read-back that cannot
        // be taken is a missing proof, and it leaves carrying the residue that
        // names every write that did land.
        do {
            switch try await readState() {
            case .read(let after) where after.isGateArmed:
                residue.gate = .provenArmed(fromPage: Int(after.auth0))
                residue.record(.gateProven)

            case .read(let after):
                // The chip answered, and what it said is that nothing is gated.
                // That is a reading, so it is reported as one.
                residue.gate = .provenOpen
                residue.record(
                    failure: .gateProven,
                    "AUTH0 read-back shows the gate open: auth0=\(after.auth0) is past page "
                        + "\(after.lastAddressablePage)"
                )

            case .gatedByReadProtection:
                // Reads above the Capability Container are gated, which is proof
                // that protection is on and covers reads. It is not proof of the
                // page it starts from, and `provenArmed` carries a page, so the
                // honest record is a missing proof rather than an invented one.
                residue.record(
                    failure: .gateProven,
                    "the configuration pages read back gated, so AUTH0 itself could not be re-read"
                )
            }
        } catch {
            residue.record(failure: .gateProven, "the AUTH0 read-back could not be taken: \(error)")
            throw TagError.protectionIncomplete(
                residue,
                diagnostics: "AUTH0 was written and acknowledged, so this tag is very likely armed "
                    + "with the new password; the read-back that would confirm it could not be "
                    + "taken. Keep the password that was just set."
            )
        }

        // Prove the credential too. PWD and PACK read back as zeros by design,
        // so the only honest proof is to present the password and see the PACK
        // the tag returns.
        //
        // Note for the caller, because it is not obvious from the shape of this
        // method: the `PWD_AUTH` sent here is also what leaves the tag open for
        // the rest of the activation, and it goes out on every arm, including
        // one where the tag arrived unarmed and was sent nothing on the way in.
        // So `.credentialProven` is the step that says this activation is
        // authenticated, and `.gateOpened` keeps its narrower meaning: a
        // credential was presented to a gate the tag already had.
        if let proven = try? await authenticate(password: password), proven == pack {
            residue.record(.credentialProven)
        } else {
            residue.credential = .unknown(reason: "PACK round-trip did not confirm the credential")
            residue.record(failure: .credentialProven, "PWD_AUTH did not return the expected PACK")
        }
        return residue
    }

    // MARK: - Disable

    /// Remove password protection.
    ///
    /// **This is the incident's fix.** The old sequence wrote AUTH0, ACCESS, PWD
    /// and PACK in a row and threw on the first refusal, so a tear after the PWD
    /// write left the tag open and holding the factory password while the app
    /// reported total failure and kept presenting the user's original one.
    ///
    /// The new sequence:
    ///  1. Read state. If the gate is already open there is nothing to
    ///     authenticate against, so no PWD_AUTH is sent.
    ///  2. Present the caller's password, once. There is no fallback here and
    ///     there cannot be: a refused `PWD_AUTH` NAKs, and the NAK halts the chip
    ///     for the rest of the activation, so a second credential in the same tap
    ///     draws silence. The refusal carries a residue naming the attempt, and
    ///     `OperationsFlowModel` turns that into an offer of a second tap.
    ///  3. ACCESS, then AUTH0 = 0xFF.
    ///  4. **Read CFG0 back.** That read-back, and nothing before it, is what
    ///     makes this a success.
    ///  5. Reset PWD and PACK to their delivery values, best effort. A failure
    ///     here is residue, never a thrown error: the tag is already open, and
    ///     telling the user otherwise is what started all this.
    @discardableResult
    public func disable(currentPassword: Data) async throws -> ProtectionResidue {
        var residue = ProtectionResidue(family: .type2, intent: .disable)
        let state = try await readState()
        residue.record(.stateRead)

        let config: Type2ProtectionConfig
        switch state {
        case .read(let read):
            config = read
            if read.isGateArmed {
                try await presentCredential(
                    password: currentPassword,
                    gateOnFailure: gateVerdictFromReading(read),
                    attemptLimit: attemptLimitFromReading(read),
                    into: &residue
                )
            }

        case .gatedByReadProtection:
            // Reads are gated, so the configuration could not be read up front.
            // Authenticate on the raw primitive and read it afterwards.
            //
            // `.unknown` rather than `.provenArmed`: gated reads prove the gate is
            // armed and prove nothing about the page it starts from, and
            // `provenArmed` carries a page. Same choice `enable` makes below.
            //
            // `limitIsHidden` for the same reason one page up: `AUTH_LIM` is in
            // the pages this tag will not serve, so a refusal here must not be
            // reported as one from a tag with no limit.
            try await presentCredential(
                password: currentPassword,
                gateOnFailure: .unknown,
                limitIsHidden: true,
                into: &residue
            )
            guard case .read(let read) = try await readState() else {
                throw TagError.protectionIncomplete(
                    residue,
                    diagnostics: "config pages still unreadable after a successful PWD_AUTH"
                )
            }
            config = read
        }

        // Both writes carry the residue out with them on failure. A caller that
        // only learns "it threw" cannot tell a tag whose credential is untouched
        // from one whose credential has moved, and that distinction is the whole
        // reason this type exists.
        do {
            let accessReset = config.config1(readProtect: false, authLimit: 0)
            if accessReset == Data(config.config1.prefix(Self.pageSize)) {
                // The page already holds exactly these bytes, read off this tag
                // in this same activation, so the write has nothing to change.
                // It is issued while the gate is still up, which makes it one
                // more abort point in a sequence that has to be recoverable at
                // every one of them, and an abort point that buys nothing is the
                // one kind worth removing. Measured on an NTAG213 (2026-09-21):
                // the read said CFG1 = 00 05 00 00 and five milliseconds later
                // the driver wrote 00 05 00 00 back.
                //
                // **The step is still recorded, and that is the part that must
                // not be got wrong.** What `.accessWritten` establishes is that
                // the ACCESS byte now holds the disarmed value, and it does.
                // Leaving it out would report a clean removal as a partial one
                // to `metItsGoal` and to every verdict built on the residue.
                residue.record(.accessWritten)
            } else {
                try await writePage(
                    layout.config1Page,
                    bytes: accessReset,
                    label: "ACCESS reset",
                    into: &residue,
                    step: .accessWritten
                )
            }
            // AUTH0 gets no such treatment. It is the gate, and its read-back a
            // few lines below is the only thing that makes this removal a
            // success. Declining to write it because the bytes in hand look
            // equal would leave the operation with nothing it had proven, on the
            // one page where proof is the whole point.
            try await writePage(
                layout.config0Page,
                bytes: config.config0(settingAuth0: Type2Credential.protectionOff),
                label: "AUTH0 reset",
                into: &residue,
                step: .gateDisarmed
            )
        } catch {
            throw TagError.protectionIncomplete(
                residue,
                diagnostics: "removal stopped before the gate came down; the credential is untouched: \(error)"
            )
        }

        // The success criterion. Everything above it can throw; nothing below it
        // may.
        //
        // A read-back that cannot be *taken* is not the same as one that says
        // the gate is still up, and neither is a lost tag. Both leave with the
        // residue naming ACCESS and AUTH0 as written, because a caller told only
        // "it threw" cannot tell a tag whose gate came down from one whose
        // credential is untouched, and that is the distinction this type exists
        // for.
        let reading: Type2StateReading
        do {
            reading = try await readState()
        } catch let first {
            // One follow-up, mirroring `enable`'s AUTH0 abort above. A READ mutates
            // nothing and cannot burn an authentication attempt, so a second one is
            // free; against a chip the previous frame halted it simply fails again.
            //
            // On 2026-09-09 an NTAG213 answered this read with a single `1F` on a
            // clean 6.5 ms callback, and one unlucky frame threw a removal that had
            // already disarmed the gate into "couldn't confirm". The tidy-up below
            // never ran and `OperationsFlowModel.verify`'s own free second read-back,
            // in the same activation, never ran either because this method threw.
            guard let second = try? await readState() else {
                residue.record(failure: .gateProven, "the AUTH0 read-back could not be taken: \(first)")
                throw TagError.protectionIncomplete(
                    residue,
                    diagnostics: "ACCESS and AUTH0 were written and acknowledged, so the gate has very "
                        + "likely come down; the read-back that would confirm it could not be taken. "
                        + "The credential has NOT been reset, so keep it."
                )
            }
            reading = second
        }
        if case .read(let after) = reading, after.isGateArmed {
            // The gate was read back, and what it said is that it is still up. That
            // is a reading, so it is filed as one. Until this branch existed, "the
            // gate could not be read" and "the gate was read and is still armed"
            // produced the same residue and the same sentence, and the string
            // written for the second had no producer in the app at all.
            //
            // `metItsGoal` is unmoved: `.disable` requires `.provenOpen`, so naming
            // the gate here cannot turn an unfinished removal into a success.
            residue.gate = gateVerdictFromReading(after)
            residue.record(
                failure: .gateProven,
                "AUTH0 read-back still shows the gate armed at page \(after.auth0)"
            )
            throw TagError.protectionIncomplete(
                residue,
                diagnostics: "removal did not open the gate; the credential has NOT been touched"
            )
        }
        guard case .read = reading else {
            // `.gatedByReadProtection`: reads above the Capability Container are
            // gated, which proves the gate is armed and proves nothing about the
            // page it starts from. `provenArmed` carries a page, so `.unknown`
            // stands rather than an invented number, the same choice `enable` makes.
            residue.record(
                failure: .gateProven,
                "the configuration pages read back gated, so AUTH0 itself could not be re-read"
            )
            throw TagError.protectionIncomplete(
                residue,
                diagnostics: "removal did not open the gate; the credential has NOT been touched"
            )
        }
        residue.gate = .provenOpen
        residue.record(.gateProven)

        // Best-effort tidy-up. The tag is unprotected from here whatever happens.
        do {
            try await writePage(
                layout.pwdPage,
                bytes: Type2Credential.factoryPassword,
                label: "PWD reset",
                into: &residue,
                step: .credentialWritten
            )
            residue.credential = .factoryDefault
        } catch {
            residue.credential = .unknown(reason: "PWD reset did not complete")
            return residue
        }
        do {
            try await writePage(
                layout.packPage,
                bytes: Type2Credential.factoryPackPage,
                label: "PACK reset",
                into: &residue,
                step: .packWritten
            )
        } catch {
            // The PACK does not gate anything: PWD_AUTH compares the password
            // and echoes whatever PACK is stored. So this leaves a tag that is
            // open, answers the factory password, and returns a stale PACK.
            // Worth recording, not worth failing.
        }
        return residue
    }

    // MARK: - Frames

    /// Bytes a READ answers with: four pages from the addressed one. Every chip
    /// this driver serves answers exactly that many, wrapping at the end of
    /// memory rather than answering fewer.
    static let readLength = 4 * pageSize

    /// What a one-byte-or-shorter first answer means at the page being addressed.
    ///
    /// It is a property of the call site, not of the frame. Above AUTH0 a short
    /// answer is the gate, and saying so is what routes the user to the unlock
    /// prompt. At the Capability Container it cannot be: page 3 sits below every
    /// AUTH0 this driver writes, "so asking for it can never trip protection".
    /// Telling the owner of an unprotected tag that it "needs its password before
    /// it will show anything" on the strength of one anomalous frame is a claim
    /// about the tag that no read established.
    ///
    /// It decides only the one-byte case. A longer answer that is still short is
    /// not the shape of a refusal at any page, and `readPages` treats it the same
    /// at both.
    enum ShortAnswer: Sendable {
        /// The page is above AUTH0, so a one-byte refusal is the gate answering.
        case isTheGate
        /// The page is below every AUTH0 this driver writes, so a short answer is
        /// an anomaly and may not be reported as a password refusal.
        case isNotAVerdict
    }

    /// One READ, judged against the sixteen bytes it asks for.
    ///
    /// Three shapes of first answer:
    ///
    /// - **All sixteen bytes.** The pages.
    /// - **One byte or less.** Treated as a refusal. At `.isTheGate` that is the
    ///   verdict and no second frame goes out: a genuine refusal has halted the
    ///   chip, and a second READ would draw silence and degrade a correct
    ///   `readProtected` into `.tagLost`. At `.isNotAVerdict` it cannot be a
    ///   verdict, so the driver asks again. This is a length rule, not a reading
    ///   of the byte: the two anomalous one-byte answers silicon has produced, `1F` to a
    ///   `30 29` on 2026-09-09 and `0F` to a `30 03` on 2026-09-10, are neither of
    ///   them a documented NTAG21x NAK, and nothing branches on either value.
    /// - **Two to fifteen bytes.** Not a refusal at any page, because a refusal
    ///   is four bits and reaches this driver as at most one byte or as a thrown
    ///   transport error. So the driver asks again at both call sites, the gated
    ///   one included. That used to be ruled out at `.isTheGate`, and the rule
    ///   was right only about one-byte answers: before this, a two-byte answer
    ///   never produced `readProtected` at all, it passed straight through as
    ///   data. An NTAG213 answered a `30 29` with `E4:0B` on 2026-09-10 and the
    ///   removal failed in `readState`'s length guard on "config block read returned 2B,
    ///   need 8" (bench finding 21).
    ///
    /// A second answer is held to the same sixteen bytes. Anything shorter is
    /// malformed, whatever its length, and never `readProtected`: the first answer
    /// already showed this frame was not refused, and nothing changes what a page
    /// gates between two READs. Silicon has never shown what a second READ gets
    /// after one of these anomalies, because every capture of one ended its
    /// activation on a build without the retry.
    private func readPages(
        startPage: Int,
        shortAnswer: ShortAnswer = .isTheGate
    ) async throws -> Data {
        let first = try await readOnce(startPage: startPage)
        guard first.count < Self.readLength else { return first }
        if first.count <= 1, case .isTheGate = shortAnswer {
            throw TagError.readProtected(
                diagnostics: "READ p\(startPage) refused: resp=\(first.hexString)"
            )
        }

        let firstAnswer = "READ p\(startPage) answered \(first.count)B of \(Self.readLength) "
            + "(resp=\(first.hexString))"
        let second: Data
        do {
            second = try await readOnce(startPage: startPage)
        } catch let error as TagError {
            // Keep the kind, and keep the anomaly that caused the second frame.
            // Without it the report would read as an ordinary lost tag.
            throw TagError(
                kind: error.kind,
                userMessage: error.userMessage,
                diagnostics: "\(firstAnswer), and asked again in the same activation: \(error.diagnostics)",
                limitReading: error.limitReading
            )
        }
        guard second.count >= Self.readLength else {
            let why = switch shortAnswer {
            case .isNotAVerdict:
                "Page \(startPage) sits below every AUTH0 this driver writes, so this is not a "
                    + "protection refusal and is not reported as one."

            case .isTheGate:
                "The first answer was not the shape of a refusal, so neither is reported as one."
            }
            throw TagError.malformedResponse(
                second,
                diagnostics: "\(firstAnswer), and \(second.count)B of \(Self.readLength) when asked "
                    + "again in the same activation. \(why)"
            )
        }
        return second
    }

    /// One `30 <page>`, with no opinion about what a short answer means.
    private func readOnce(startPage: Int) async throws -> Data {
        try await transceive(
            RawCommand(bytes: Data([Self.read, UInt8(startPage)]), name: "READ p\(startPage)")
        )
    }

    /// Write the ACCESS byte with a new AUTH_LIM, preserving every other bit.
    ///
    /// Lives here rather than in the caller because this type owns every frame
    /// that touches the Type-2 configuration block, and "the shipped frames are
    /// the tested frames" is only true while that stays so. The caller used to
    /// reach for `ConnectedTag.writeMemory`, on the reasoning that it is the
    /// protocol's own page-write primitive and lands as the same `A2` on the
    /// wire. True of production, false of the simulator, which answers
    /// `writeMemory` out of its page array without ever reaching
    /// `handle(command:)`. So the one mutating write of an irreversible
    /// operation had no frame in CI to tear, and the recovery branch that
    /// exists for a lost ACK could not be exercised at all.
    ///
    /// `readProtect` is deliberately a parameter taken from a config the caller
    /// has just read, not a stored belief: this changes the attempt limit and
    /// must not move the read gate as a side effect.
    ///
    /// Returns the residue rather than throwing on a refusal alone. A refusal
    /// may be a lost ACK, so the caller consults the tag before deciding.
    @discardableResult
    public func setAttemptLimit(
        _ limit: Int,
        readProtect: Bool,
        from config: Type2ProtectionConfig
    ) async throws -> ProtectionResidue {
        guard (0 ... 7).contains(limit) else {
            throw TagError.protocolError("authLimit must be 0…7", diagnostics: "\(limit)")
        }
        var residue = ProtectionResidue(family: .type2, intent: .setCredential)
        residue.record(.stateRead)
        try await writePage(
            layout.config1Page,
            bytes: config.config1(readProtect: readProtect, authLimit: limit),
            label: "ACCESS",
            into: &residue,
            step: .attemptLimitWritten
        )
        return residue
    }

    private func writePage(
        _ page: Int,
        bytes: Data,
        label: String,
        into residue: inout ProtectionResidue,
        step: ProtectionResidue.Step
    ) async throws {
        guard bytes.count == Self.pageSize else {
            throw TagError.protocolError(
                "\(label): page write must be 4 bytes", diagnostics: "len=\(bytes.count)"
            )
        }
        let response: Data
        do {
            response = try await transceive(
                RawCommand(bytes: Data([Self.write, UInt8(page)]) + bytes, name: "\(label) WRITE p\(page)")
            )
        } catch {
            residue.record(failure: step, "\(label): \(error)")
            throw error
        }
        guard response.first == Self.ack else {
            let diagnostics = "WRITE not acknowledged page=\(page) resp=\(response.hexString)"
            residue.record(failure: step, diagnostics)
            throw TagError.protocolError("WRITE not acknowledged", diagnostics: "\(label) \(diagnostics)")
        }
        residue.record(step)
    }
}
