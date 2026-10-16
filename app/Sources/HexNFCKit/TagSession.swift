import Foundation
import HexNFCRecords

/// One end-to-end NFC interaction. A session is opened, polls for a tag,
/// surfaces a `ConnectedTag`, and is invalidated when the interaction ends.
///
/// Production wires `CoreNFCSession` (iOS-only); tests wire `SimulatedSession`
/// from the `HexNFCTagSim` target. Anything outside `HexNFCKit` works through
/// this protocol — *never* `import CoreNFC` elsewhere.
public protocol TagSession: AnyObject, Sendable {
    /// Begin polling for a tag. The alert is shown by CoreNFC inside the
    /// system NFC sheet on iOS, or surfaced as a label by simulated sessions.
    /// Returns once a tag is detected and identified.
    func start(alert: String) async throws -> ConnectedTag

    /// Update the alert label shown inside the system NFC sheet mid-session.
    /// No-op for simulated sessions.
    func updateAlert(_ alert: String) async

    /// End the session, optionally surfacing an error string to the user, and
    /// return **once it has fully torn down** (or immediately if it already has) —
    /// so a caller can open the next session without racing the teardown. Idempotent.
    /// Simulated/mock sessions have nothing to tear down and return at once.
    func invalidate(error: String?) async
    /// After `invalidate(error:)`, wait until the platform reports the session
    /// gone, or until `timeout` passes. Returns at once if it already has, or if
    /// the session never began.
    ///
    /// `invalidate` is bounded by a safety net, and a caller that wants to act
    /// once the system NFC sheet has left the screen needs the report itself:
    /// on 2026-09-19 CoreNFC logged the sheet's removal about 2.7 s after a
    /// successful write invalidated its session. Sessions with no system UI
    /// have nothing to wait for, which is the default.
    func awaitTeardown(timeout: Duration) async
}

public extension TagSession {
    func awaitTeardown(timeout _: Duration) async {}
}

/// The one place the inter-session timing figures live.
///
/// `TagSession.invalidate(error:)` already awaits real teardown, which removed
/// the race where a half-dead predecessor dropped the next tag. What it cannot
/// remove is the *second* wait: after the teardown callback iOS keeps the NFC
/// sheet animating out and imposes an opaque cooldown before another session may
/// open, and emits no "ready" event to observe. So a floor is unavoidable, and the
/// only question is whether it is anchored to something real, and here it is
/// anchored to the moment teardown actually completed.
///
/// Live-derived on the enforcement verifier's three-session Arm → Probe → Remove
/// flow (2026-08-07); the same figure doubles as the disable-retry backoff,
/// because iOS can still report a fresh session as error 202 shortly after an
/// abnormal teardown.
public enum NFCSessionTiming {
    /// Minimum quiet time between one session's teardown and the next opening.
    public static let interSessionCooldown: Duration = .milliseconds(2500)
}

/// Process-wide record of when the last real NFC session finished tearing down,
/// so the next one can honour `NFCSessionTiming.interSessionCooldown`.
///
/// It lives at the session layer rather than in each flow model deliberately.
/// Every back-to-back flow in the app is affected (scan retry, the unlock
/// re-tap, the passport re-tap, write retry, the console's Identify-then-Run)
/// and patching them one at a time is how a flow added later ends up without the
/// wait. Simulated sessions never register a teardown, so tests and CI stay
/// instant and nothing here needs injecting.
public enum NFCSessionClock {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var lastTeardown: ContinuousClock.Instant?

    /// Called by a real session once CoreNFC reports teardown is complete.
    public static func recordTeardown() {
        lock.withLock { lastTeardown = ContinuousClock.now }
    }

    /// Sleep until the cooldown has elapsed since the last recorded teardown.
    /// Returns at once when no session has torn down yet (the first scan of a
    /// launch) or when enough real time has already passed, which is the normal
    /// case, since any flow with a human step in it takes far longer than this.
    public static func awaitCooldown() async {
        guard let last = lock.withLock({ lastTeardown }) else { return }
        let ready = last.advanced(by: NFCSessionTiming.interSessionCooldown)
        let remaining = ContinuousClock.now.duration(to: ready)
        guard remaining > .zero else { return }
        try? await Task.sleep(for: remaining)
    }

    /// Forget the last teardown. Test hook only, so one test's timing can't
    /// leak into the next.
    public static func reset() {
        lock.withLock { lastTeardown = nil }
    }
}

/// Holds a live NTAG424 EV2 secure-messaging session across the separate
/// `authenticate` → `writeNDEF`/`readNDEF` calls of a single tap. A reference
/// type so the `ConnectedTag.ev2Session` requirement can stay `{ get }` while the
/// protocol extension still mutates the live session. The session is bound to the
/// tag instance, so it's discarded automatically when the tap ends (a fresh tag
/// starts with `driver == nil`). The Type-4 analogue of Type-2's `type2Session`
/// flag — without it the EV2 session would be lost before the protected NDEF write.
public final class EV2SessionHolder: @unchecked Sendable {
    var driver: NTAG424ProtectionDriver?
    public init() {}
}

/// Tracks whether a MIFARE Ultralight C 3DES handshake has already run in this
/// activation.
///
/// **A second `AUTHENTICATE` (`1Ah`) in one activation is refused**, and on a
/// Type-2 chip a refusal returns the tag to HALT, so the tag stops answering
/// entirely. Live-confirmed 2026-08-07: `ulc.auth` completed the handshake, the
/// very next step issued `1A 00` again, got a one-byte NAK, and every remaining
/// command failed with "tag connection lost".
///
/// The card offers no way to ask whether it is already authenticated, so the
/// reader has to remember. A reference type bound to the tag instance, so it is
/// discarded when the tap ends: the Ultralight C analogue of `EV2SessionHolder`
/// and of Type-2's `type2Session`.
///
/// This is not only a harness concern. In the app, unlocking a protected tag and
/// then writing with protection applied would authenticate twice in one tap and
/// dead-end the same way.
public final class UltralightCSessionHolder: @unchecked Sendable {
    /// `true` once a 3DES handshake has succeeded during this activation.
    public var isAuthenticated = false
    public init() {}
}

/// Tracks whether a Type-2 `PWD_AUTH` has already succeeded in this activation.
///
/// This is the storage that used to be `CoreNFCConnectedTag.didAuthenticate`, a
/// private field on the production tag only. Moving it to a holder bound to the
/// tag instance is what lets the whole Type-2 credential path live in one
/// protocol extension, so the simulator cannot answer a password command any
/// differently from the shipped code.
///
/// **A conformer with a credential path must store one.** The protocol's default
/// returns a fresh holder per access, which is correct only for a conformer that
/// never authenticates: a write to it is discarded. `CoreNFCConnectedTag` took
/// that default from the move (fe4c5bd) until 2026-09-16, so on device the flag
/// was always false and a read-protected tag the session had just unlocked was
/// read through the high-level path with the gate still shut.
///
/// The Type-2 sibling of `EV2SessionHolder` and `UltralightCSessionHolder`, and
/// discarded with the tag when the tap ends.
public final class Type2SessionHolder: @unchecked Sendable {
    /// `true` once a `PWD_AUTH` has been accepted during this activation. While
    /// it holds, writes to gated pages are allowed and the raw page path is the
    /// one to use.
    public var isAuthenticated = false
    public init() {}
}

/// An identified, in-progress tag. The protocol is intentionally narrow —
/// the chip family's *capabilities* gate every method, so callers should
/// consult `capabilities` before calling write/auth/lock methods.
public protocol ConnectedTag: AnyObject, Sendable {
    /// Backing store for a live Type-4 EV2 secure session, shared across
    /// `authenticate`/`writeNDEF`/`readNDEF` within one tap. The two real tags
    /// (CoreNFC + simulator) satisfy this with a stored `let`; other conformers
    /// inherit the extension default (a throwaway holder — they never run a 424
    /// EV2 handshake, so nothing is lost).
    var ev2Session: EV2SessionHolder { get }

    /// Per-tap MIFARE Ultralight C authentication state. Same storage contract
    /// as `ev2Session`: the two real tags provide a stored `let`, everything
    /// else inherits the throwaway default.
    var ultralightCSession: UltralightCSessionHolder { get }
    /// Unique chip identifier as written at manufacture. 7 bytes on most
    /// Type-2 chips, 8 bytes on Type-5. Used as the source for `??`
    /// placeholders in `RawCommandSequence`.
    var uid: Data { get }

    /// Detected chip profile. `nil` if identification did not run or the
    /// chip is unknown — callers fall back to a generic command set.
    var chip: ChipProfile? { get }

    /// What identification could decode when it could *not* name the chip —
    /// populated only when `chip` is `nil`. Display-only: it carries no page map
    /// (see `UnidentifiedChipReport`), so no operation may branch on it.
    /// Conformers that never probe a version block inherit the `nil` default.
    var unidentifiedReport: UnidentifiedChipReport? { get }

    var capabilities: TagCapability { get }

    // MARK: NDEF

    /// Read the NDEF message stored on the tag. The result is the raw
    /// concatenated payload of every record, suitable for passing to
    /// `NDEFCodec.decode`.
    func readNDEF() async throws -> Data

    /// Encode the records into the binary NDEF format and write them to the
    /// tag. Throws if the records exceed the chip's NDEF capacity, or if the
    /// chip has been permanently locked.
    func writeNDEF(_ records: [NDEFRecord]) async throws

    // MARK: Raw I/O

    /// Send a single raw command and receive the tag's response.
    func transceive(_ command: RawCommand) async throws -> Data

    /// Send an ordered chain of raw commands, returning each response in
    /// order. Aborts on the first failure.
    func transceive(sequence: [RawCommand]) async throws -> [Data]

    // MARK: Memory

    /// Read a range of bytes (page-aligned on Type-2 chips).
    func readMemory(range: Range<Int>) async throws -> Data

    /// Write bytes at a byte-offset (page-aligned on Type-2 chips).
    func writeMemory(at offset: Int, bytes: Data) async throws

    // MARK: Auth / lock

    /// Live Type-2 `PWD_AUTH` state for this activation.
    var type2Session: Type2SessionHolder { get }

    // MARK: Family-agnostic protection

    /// The protection model this connected tag's backend can drive, or `nil` if
    /// no backend exists for its family. The capability-driven UI offers the
    /// Protection affordance iff this is non-nil. Solves the "ICODE SLIX is
    /// Type-5 but advertises `.passwordAuth`" gotcha without the App switching on
    /// family — the gate lives in `ProtectionStyle.backendStyle(for:capabilities:)`.
    var protectionStyle: ProtectionStyle? { get }

    /// Apply protection (credential + activation) in one family-agnostic
    /// operation. The spec is family-tagged; the backend asserts its family
    /// matches `protectionStyle`. `replacing` carries the credential the tag
    /// holds *now*, which an already-protected tag needs before it will accept a
    /// new one.
    ///
    /// Returns what the operation actually established. A caller that ignores it
    /// is choosing not to know whether the gate was proven armed.
    @discardableResult
    func enableProtection(_ spec: ProtectionSpec, replacing currentCredential: TagCredential?) async throws
        -> ProtectionResidue

    /// Remove protection, authenticating with the supplied credential first.
    ///
    /// Returns what the operation actually established. Crucially, a removal
    /// that proved the gate open and then failed to tidy the credential away
    /// **returns** rather than throwing: the tag is unlocked either way, and
    /// reporting that as a failure is what stranded a real tag.
    @discardableResult
    func disableProtection(using credential: TagCredential) async throws -> ProtectionResidue

    /// Authenticate past existing protection with a family-tagged credential
    /// (the generalised unlock primitive).
    ///
    /// Consults the tag's own state first where the family allows it, so a tag
    /// that is not gated is never sent a credential at all. The returned
    /// `GateOpening` says which of those happened.
    @discardableResult
    func authenticate(_ credential: TagCredential) async throws -> GateOpening
}

public extension ConnectedTag {
    /// Default holder for conformers that don't store one. Returns a fresh
    /// throwaway each access — harmless because only the two real tags (which
    /// provide a stored `let`) ever run a Type-4 EV2 handshake.
    var ev2Session: EV2SessionHolder {
        EV2SessionHolder()
    }

    /// Default holder for conformers that don't store one. A fresh throwaway
    /// each access, which is harmless because only the two real tags (which
    /// provide a stored `let`) ever run a 3DES handshake.
    var ultralightCSession: UltralightCSessionHolder {
        UltralightCSessionHolder()
    }

    /// Conformers that never probe a version block (simulators, test doubles)
    /// have nothing to report.
    var unidentifiedReport: UnidentifiedChipReport? {
        nil
    }

    /// Default implementation chains single-command `transceive` calls. Real
    /// implementations may override for efficiency.
    func transceive(sequence: [RawCommand]) async throws -> [Data] {
        var responses: [Data] = []
        responses.reserveCapacity(sequence.count)
        for command in sequence {
            try await responses.append(transceive(command))
        }
        return responses
    }

    /// Guard helper. Throws `.capabilityUnsupported` synchronously if the
    /// connected tag does not declare the required capability.
    func require(_ capability: TagCapability) throws {
        guard capabilities.contains(capability) else {
            throw TagError.capabilityUnsupported(
                capability,
                diagnostics: "uid=\(uid.hexString) chip=\(chip?.id.description ?? "unknown")"
            )
        }
    }

    /// Throwaway default for conformers that store no Type-2 session. Harmless
    /// because only a tag that actually authenticates needs the flag to persist,
    /// and those provide a stored `let`.
    var type2Session: Type2SessionHolder {
        Type2SessionHolder()
    }

    /// The one construction site for the Type-2 credential driver in the whole
    /// app. `nil` for any chip without password hardware, which is how "this
    /// chip has no password block" is modelled rather than guessed.
    ///
    /// Everything below is built on it, and **nothing overrides these methods**.
    /// That is the point: Type-2 password was the last family where production
    /// and the simulator each had their own implementation, so the frames that
    /// shipped were never the frames any test replayed. The bug that reached a
    /// user's tag lived in the half CI could not see.
    var type2PasswordDriver: Type2PasswordDriver? {
        guard capabilities.contains(.passwordAuth), let layout = chip?.type2ConfigLayout else {
            return nil
        }
        return Type2PasswordDriver(layout: layout, uid: uid) { [self] in try await transceive($0) }
    }

    private func requireType2Driver(_ operation: String) throws -> Type2PasswordDriver {
        guard let driver = type2PasswordDriver else {
            throw TagError.capabilityUnsupported(
                .passwordAuth,
                diagnostics: "\(operation) unsupported uid=\(uid.hexString) chip=\(chip?.id.description ?? "unknown")"
            )
        }
        return driver
    }

    /// Write the chip's lock bits. **Irreversible.**
    ///
    /// Refuses outright on a tag whose password gate is armed, rather than
    /// burning what it can reach and reporting the refusal of the rest as a
    /// plain failure. That is what happened to a real NTAG213 on 2026-09-04:
    /// page 2 sits below AUTH0 so the static lock bytes burned, page 0x28 sits
    /// above it so the dynamic lock was NAKed, and the user was told only that
    /// the operation had failed.
    ///
    /// The caller is still responsible for the destructive-confirmation flow.
    @discardableResult
    func permanentLock() async throws -> PermanentLockOutcome {
        try require(.permanentLock)
        // Type-5 (ICODE SLIX): LOCK_BLOCK across the data blocks, not Type-2
        // lock bytes.
        if case .type5? = chip?.family {
            let client = Iso15693ProtectionClient(transceive: { [self] in try await transceive($0) })
            // The outcome comes from the client, which reads the block security
            // status back and can therefore say how many blocks this run burned.
            // Minting one here instead meant every failure path produced none at
            // all, and a half-locked SLIX2 was reported as a protocol error.
            return try await client.permanentLock(
                chip: chip?.id, blockCount: chip?.memoryLayout.pageCount ?? 28
            )
        }
        // Lock pages come from the chip's *memory* layout, deliberately NOT from
        // `Type2ConfigLayout`. That type maps the NTAG21x password block and is
        // `nil` for any chip without one, but lock bytes and passwords are
        // independent features: the NTAG 210µ has perfectly ordinary static lock
        // bytes at page 02h and no password hardware at all.
        guard let layout = chip?.memoryLayout, let family = chip?.family else {
            throw TagError.capabilityUnsupported(
                .permanentLock,
                diagnostics: "no chip profile for \(chip?.id.description ?? "unidentified"): "
                    + "a permanent lock needs known lock pages and a known lock-bit mask"
            )
        }
        // The UID goes in so the pre-flight can tell a configuration page from a
        // read roll-over, which serves page 0 and would otherwise have its BCC0
        // byte read as AUTH0.
        let driver = Type2LockDriver(uid: uid) { [self] in try await transceive($0) }
        return try await driver.permanentLock(
            layout: layout, family: family, configLayout: chip?.type2ConfigLayout
        )
    }

    /// Provide a 4-byte password; the chip answers with its 2-byte PACK.
    ///
    /// The raw primitive: it always sends `1B` and never consults state. Callers
    /// that should not present a credential to an ungated tag want
    /// `authenticate(_ credential:)`, which reads the tag first.
    func authenticate(password: Data) async throws -> Data {
        let pack = try await requireType2Driver("authenticate").authenticate(password: password)
        type2Session.isAuthenticated = true
        return pack
    }

    /// Configure the chip's PWD and PACK pages *only*: the credential
    /// primitive. This does **not** enable protection on its own; nothing is
    /// gated until AUTH0/ACCESS are set.
    @discardableResult
    func setPassword(_ password: Data, pack: Data) async throws -> ProtectionResidue {
        try await requireType2Driver("setPassword").setCredential(password: password, pack: pack)
    }

    /// Program the password/PACK **and** turn protection on in one operation.
    ///
    /// - Note: `authLimit` of `0` means unlimited attempts (never auto-bricks).
    ///   A non-zero limit is the number of wrong `PWD_AUTH`s the tag allows; the
    ///   next one permanently locks password verification, right password or
    ///   wrong (NTAG21x rev 3.2 §8.8.2, MF0ULx1 rev 3.3 §8.6.2), and a tag that
    ///   can no longer authenticate can no longer have its protection removed.
    ///   The reset on success is promised only below the limit, so do not
    ///   describe the count as consecutive. The caller must warn loudly and gate
    ///   the choice.
    @discardableResult
    func enablePasswordProtection(
        password: Data,
        pack: Data,
        protectFromPage: Int,
        readProtect: Bool,
        authLimit: Int,
        currentPassword: Data? = nil
    ) async throws -> ProtectionResidue {
        let residue = try await requireType2Driver("enablePasswordProtection").enable(
            password: password,
            pack: pack,
            protectFromPage: protectFromPage,
            readProtect: readProtect,
            authLimit: authLimit,
            currentPassword: currentPassword
        )
        // Only claim a handshake that actually happened, which is the rule the
        // Ultralight C arm of `enableProtection` and `authenticate(_:)` both
        // already follow.
        //
        // The step to read is `.credentialProven`, not `.gateOpened`. `enable`
        // closes by presenting the password and checking the PACK that comes
        // back, and that frame is what leaves the tag open; it goes out on every
        // arm, including one where the tag arrived unarmed and was sent nothing
        // beforehand. `.gateOpened` is only recorded when a credential was
        // presented to a gate the tag already had, so a first-time protect would
        // read as unauthenticated through it while the tag sits open.
        //
        // What it may not do is assert the flag unconditionally. `enable`
        // returns rather than throws when that closing PWD_AUTH is refused or
        // lost, so the old line told the rest of the activation the tag was open
        // on the strength of four acknowledged writes, which is an
        // authentication recorded from a reading rather than from an exchange.
        type2Session.isAuthenticated =
            type2Session.isAuthenticated || residue.completed.contains(.credentialProven)
        return residue
    }

    /// Remove protection: ACCESS cleared, AUTH0 back to `0xFF`, then PWD/PACK
    /// reset to the delivery values. The AUTH0 read-back is the success
    /// criterion; the credential reset that follows it is best effort and
    /// cannot fail the operation.
    @discardableResult
    func disablePasswordProtection(currentPassword: Data) async throws -> ProtectionResidue {
        try await requireType2Driver("disablePasswordProtection").disable(currentPassword: currentPassword)
    }

    /// Read the live protection state, fanning out per family.
    ///
    /// Moved here from `CoreNFCConnectedTag` so a simulator reports state the
    /// same way production does. Best-effort: callers should treat a throw as
    /// "couldn't determine", which `ProtectionProbe` is built to do.
    ///
    /// `allowWriteProbe` is the one knob a read-only caller needs. Every family
    /// here reads, except SLIX2, whose password state is not reported by any
    /// command and is established by attempting a write (`Iso15693ProtectionClient`,
    /// `mayProbeByWriting`). A caller that has told the user it is only
    /// identifying the tag passes `false` and accepts the thinner answer.
    func readProtectionState(allowWriteProbe: Bool = true) async throws -> TagProtection? {
        // MIFARE Ultralight C: AUTH0/AUTH1 at pages 2Ah/2Bh, byte 0, with AUTH1's
        // polarity inverted relative to the NTAG21x ACCESS byte. Checked before
        // the Type-2 path because this chip *is* Type-2 by transport and would
        // otherwise fall through to a `type2ConfigLayout` that is deliberately
        // nil, reporting "no detectable protection" on a tag that may well be
        // protected.
        if case .type2(.mifareUltralightC)? = chip?.family {
            let driver = UltralightCProtectionDriver(transceive: { [self] in try await transceive($0) })
            return try await driver.readProtectionState()
        }
        // Type-4 (NTAG424 DNA): the protection lives in the NDEF file's access
        // rights, read via the EV2 driver's plain GetFileSettings probe.
        if case .type4(.ntag424DNA)? = chip?.family {
            let driver = NTAG424ProtectionDriver(transceive: { [self] in try await transceive($0) })
            return try await driver.readProtectionState()
        }
        // Type-5 (ICODE SLIX): the chip's own account first, and a behavioural
        // probe only where the app could act on the answer. The probe writes,
        // and `.passwordAuth` is the capability that says this chip's password
        // state is something this app offers to change: among Type-5 profiles
        // only `.icodeSlix2` carries it.
        if case .type5? = chip?.family {
            let client = Iso15693ProtectionClient(
                transceive: { [self] in try await transceive($0) },
                mayProbeByWriting: allowWriteProbe && capabilities.contains(.passwordAuth)
            )
            return try await client.readProtectionState()
        }
        // NTAG21x / Ultralight EV1. Everything else has no password block and
        // reports nil so the caller falls back to "no detectable protection".
        return try await type2PasswordDriver?.readProtectionState()
    }

    /// What this tag's lock bytes say, read on this activation.
    ///
    /// Best-effort by construction: it returns `.notRead` rather than throwing,
    /// because a lock verdict is never worth failing a scan for. `.notRead` is
    /// also the honest answer for every family this cannot ask, and it renders
    /// as nothing at all rather than as "not locked".
    ///
    /// Gated on `.permanentLock` rather than on `.passwordAuth`: NTAG 210u and
    /// Ultralight C both lock and neither advertises an NTAG21x password block,
    /// while NTAG424 DNA advertises one and has no lock concept at all.
    ///
    /// Type-5 is deliberately out of scope for now.
    /// `GET_MULTIPLE_BLOCK_SECURITY_STATUS` is several frames on an 80-block
    /// SLIX2 over a transport this repo records as unreliable in the field, and
    /// a naive comparison against the whole block count reports a correctly
    /// locked SLIX2 as partial. A Type-5 tag gets a lock verdict only from an
    /// operation that pushed one.
    ///
    /// - Parameter provenReadablePage: see `Type2LockDriver.readLockState`. Pass
    ///   `nil` when nothing has been established, which sends no frames at all.
    func readLockState(provenReadablePage: Int?) async -> TagLockReading {
        guard capabilities.contains(.permanentLock),
              capabilities.contains(.rawTransceive),
              let chip, case .type2 = chip.family,
              !chip.memoryLayout.lockPages.isEmpty || chip.memoryLayout.dynamicLockPage != nil
        else { return .notRead }
        let driver = Type2LockDriver(uid: uid) { [self] in try await transceive($0) }
        return await driver.readLockState(
            layout: chip.memoryLayout,
            family: chip.family,
            provenReadablePage: provenReadablePage
        )
    }

    /// Default: computed purely from family + capabilities, so every conformer
    /// (production and simulator) reports the right style without overriding.
    /// The single gate is `ProtectionStyle.backendStyle`.
    var protectionStyle: ProtectionStyle? {
        ProtectionStyle.backendStyle(for: chip?.family, capabilities: capabilities)
    }

    /// Default: forward a `.type2` spec to the existing datasheet-verified Type-2
    /// path; Type-4/Type-5 backends override. This means no Type-2 code is
    /// duplicated — `enableProtection(.type2(...))` *is* `enablePasswordProtection`.
    @discardableResult
    func enableProtection(
        _ spec: ProtectionSpec,
        replacing currentCredential: TagCredential? = nil
    ) async throws -> ProtectionResidue {
        switch spec {
        case .type2(let password, let pack, let protectFromPage, let readProtect, let authLimit):
            var currentPassword: Data?
            if case .type2(let held, _)? = currentCredential {
                currentPassword = held
            }
            return try await enablePasswordProtection(
                password: password,
                pack: pack,
                protectFromPage: protectFromPage,
                readProtect: readProtect,
                authLimit: authLimit,
                currentPassword: currentPassword
            )

        case .type4(let aesKey, let keySlot, let readProtect):
            // Driven over `transceive`, so the same path works for the real chip
            // and the simulator.
            //
            // The held credential is threaded in as a candidate. Without it a tag
            // an earlier run had already re-keyed could never be opened again:
            // the driver would only ever present the factory key, and the one
            // key that would have worked is the one the app is holding.
            var currentKeys: [Data] = []
            if case .type4(let held, _)? = currentCredential {
                currentKeys = [held]
            }
            let driver = NTAG424ProtectionDriver(transceive: { [self] in try await transceive($0) })
            return try await driver.enable(
                aesKey: aesKey, keySlot: keySlot, readProtect: readProtect, currentKeys: currentKeys
            )

        case .type5(let write, let read, _):
            // Thread the credential the tag holds now. Without it `enable`
            // always presented the factory password, so a tag that had once been
            // protected could never be protected again: the refusal stops the
            // chip answering for the rest of the tap (SL2S2602 section 9.5.3.2).
            var currentWrite: Data?
            if case .type5(let held, _)? = currentCredential {
                currentWrite = held
            }
            let client = Iso15693ProtectionClient(transceive: { [self] in try await transceive($0) })
            return try await client.enable(
                writePassword: write, readPassword: read, currentWritePassword: currentWrite
            )

        case .ultralightC(let key, let protectFromPage, let readProtect):
            // Thread the credential the tag holds now, the same way the Type-4
            // and Type-5 arms above do. This arm used to read a `currentKey`
            // baked into the spec and drop `replacing:` on the floor, so the
            // credential the caller had already resolved never reached the
            // driver.
            //
            // What this fixes is a channel, not a live incident, and the
            // distinction is worth stating because the obvious claim is wrong.
            // "A personalised tag could never be re-keyed" does not survive
            // reading `UltralightCProtectionDriver.enable`, which is state-first:
            // it reads the configuration pages before presenting anything, and
            // skips the handshake when the caller says this activation is
            // `alreadyAuthenticated`. On the write flow the unlock prompt sets
            // exactly that, so wherever the app held the right key the baked-in
            // factory key was never sent.
            //
            // The defect was that two places claimed to answer "what opens this
            // tag now" and the loser was the one the caller had resolved. Two
            // sources for one fact is a desync waiting for the day they differ,
            // which is the whole lesson of 2026-09-04. One channel, and the
            // other three families already used it.
            var currentKey = UltralightCKey.factoryDefault
            if case .ultralightC(let held)? = currentCredential {
                currentKey = held
            }
            let driver = UltralightCProtectionDriver(transceive: { [self] in try await transceive($0) })
            let residue = try await driver.enable(
                key: key, protectFromPage: protectFromPage,
                readProtect: readProtect, currentKey: currentKey,
                alreadyAuthenticated: ultralightCSession.isAuthenticated
            )
            // Only claim a handshake that actually happened. `enable` no longer
            // sends `AUTHENTICATE` to an unprotected tag, so asserting it here
            // unconditionally would tell a later step in the same tap that it is
            // already authenticated when it is not, and a second handshake in one
            // activation is refused (the refusal halts the chip).
            ultralightCSession.isAuthenticated =
                ultralightCSession.isAuthenticated || residue.completed.contains(.gateOpened)
            return residue
        }
    }

    /// Default: forward a `.type2` credential to `disablePasswordProtection`;
    /// `.type4` runs the NTAG424 disable over `transceive`.
    @discardableResult
    func disableProtection(using credential: TagCredential) async throws -> ProtectionResidue {
        switch credential {
        case .type2(let password, _):
            return try await disablePasswordProtection(currentPassword: password)

        case .type4(let aesKey, let keySlot):
            let driver = NTAG424ProtectionDriver(transceive: { [self] in try await transceive($0) })
            return try await driver.disable(currentKey: aesKey, keySlot: keySlot)

        case .type5(let password, let kind):
            // Return the driver's own verdict rather than a placeholder. The
            // client proves the gate is down by reading the page-protection
            // conditions back; discarding that here would leave the App
            // reporting a removal from ACKs alone, which is the exact shape of
            // the Type-2 incident this work exists to close.
            let client = Iso15693ProtectionClient(transceive: { [self] in try await transceive($0) })
            return try await client.disable(
                currentWritePassword: password,
                hadReadProtect: kind == .read || kind == .readWrite
            )

        case .ultralightC(let key):
            // This path always handshakes (the chip offers no safe unauthenticated
            // probe: its configuration pages sit above AUTH0 on a read-protected
            // tag, and a refused READ is a NAK that halts the activation), so the
            // session flag is accurate here.
            let driver = UltralightCProtectionDriver(transceive: { [self] in try await transceive($0) })
            let residue = try await driver.disable(
                currentKey: key, alreadyAuthenticated: ultralightCSession.isAuthenticated
            )
            ultralightCSession.isAuthenticated = true
            return residue
        }
    }

    /// Default: forward a `.type2` credential to `authenticate(password:)`;
    /// `.type4` validates the AES key via an EV2 handshake (returns empty — the
    /// 424 has no PACK).
    @discardableResult
    func authenticate(_ credential: TagCredential) async throws -> GateOpening {
        switch credential {
        case .type2(let password, _):
            // State first. A tag whose own AUTH0 says nothing is gated is never
            // sent a password, because a refused PWD_AUTH NAKs and a NAK halts a
            // Type-2 chip for the rest of the activation. Firing a stale
            // credential at an already-open tag is what turned a working tag
            // into a dead session, over and over, in the 2026-09-04 incident.
            let opening = try await requireType2Driver("authenticate").openGate(password: password)
            if opening.route != .alreadyOpen {
                type2Session.isAuthenticated = true
            }
            return opening

        case .type4(let aesKey, let keySlot):
            let driver = NTAG424ProtectionDriver(transceive: { [self] in try await transceive($0) })
            try await driver.selectNDEFApp()
            try await driver.authenticate(keyNo: UInt8(keySlot & 0x0F), key: aesKey)
            // Persist the live EV2 session so a following `writeNDEF`/`readNDEF`
            // on this same tag runs inside it (the secure-messaging path) — the
            // Type-4 analogue of Type-2's `type2Session`.
            ev2Session.driver = driver
            return GateOpening(route: .authenticated)

        case .type5(let password, _):
            let client = Iso15693ProtectionClient(transceive: { [self] in try await transceive($0) })
            try await client.authenticate(password: password, kind: .write)
            return GateOpening(route: .authenticated)

        case .ultralightC(let key):
            let driver = UltralightCProtectionDriver(transceive: { [self] in try await transceive($0) })
            // Returns RndA, the session material. Unlike Type-2's PACK this is
            // not a value the caller compares against anything: the driver has
            // already verified the card's half of the handshake, and a mismatch
            // threw rather than returning.
            //
            // A repeat handshake in the same activation is refused by the card,
            // so remember that one has run. Re-authenticating is a no-op rather
            // than an error: the caller asked to be authenticated, and it is.
            if ultralightCSession.isAuthenticated {
                return GateOpening(route: .alreadyOpen)
            }
            let rndA = try await driver.authenticate(key: key)
            ultralightCSession.isAuthenticated = true
            return GateOpening(route: .authenticated, response: rndA)
        }
    }
}

extension ChipID: CustomStringConvertible {
    public var description: String {
        switch self {
        case .ntag210Micro: "ntag210Micro"
        case .ntag213: "ntag213"
        case .ntag213TT: "ntag213TT"
        case .ntag215: "ntag215"
        case .ntag216: "ntag216"
        case .ntag424DNA: "ntag424DNA"
        case .mifareUltralightEV1_48: "mifareUltralightEV1_48"
        case .mifareUltralightEV1_128: "mifareUltralightEV1_128"
        case .mifareUltralightC: "mifareUltralightC"
        case .emV10: "emV10"
        case .emV11: "emV11"
        case .emV16: "emV16"
        case .icodeSlix: "icodeSlix"
        case .icodeSlix2: "icodeSlix2"
        case .genericIso15693: "iso15693"
        case .genericFeliCa: "felica"
        case .genericMifareDESFire: "mifareDESFire"
        case .mifareDESFireEV1: "mifareDESFireEV1"
        case .mifareDESFireEV2: "mifareDESFireEV2"
        case .mifareDESFireEV3: "mifareDESFireEV3"
        case .ePassport: "ePassport"
        case .unknown: "unknown"
        }
    }
}

/// A way of constructing a `TagSession`. The app root holds one factory
/// (CoreNFC in production, simulated in UI tests gated by `--useSimulatedNFC`).
public protocol TagSessionFactory: Sendable {
    func makeSession() -> TagSession
}
