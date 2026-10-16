import Foundation
import HexNFCRecords
import Security

/// Reader-side NTAG424 DNA (Type-4) protection driver. Speaks the DESFire EV2
/// secure-messaging protocol over a `transceive` closure, so the same code drives
/// a real chip (via `CoreNFCConnectedTag.transceive`) and the simulator (via
/// `SimulatedConnectedTag.transceive` → `handle(command:)`) — letting the whole
/// flow be tested without hardware.
///
/// Protection model (write-only by default): gate the NDEF file's *write* access
/// behind an AES key in a key slot, leaving reads free. With `readProtect`, gate
/// reads too. The secret is the 16-byte AES key; only `TagProtection` settings
/// persist (Keychain holds the key — never this driver, never a log).
///
/// References: NXP NT4H2421Gx datasheet rev 3.2, AN12196 §3 (auth) / §6 (commands).
final class NTAG424ProtectionDriver: @unchecked Sendable {
    typealias Transceive = @Sendable (RawCommand) async throws -> Data

    private let transceive: Transceive
    private let makeRandom: @Sendable (Int) -> Data

    // Live secure-messaging session — populated by `authenticate`.
    private var ti = Data(count: 4)
    private var cmdCtr: UInt16 = 0
    private var encKey = Data(count: 16)
    private var macKey = Data(count: 16)
    private var authedKeyNo: UInt8 = 0
    private(set) var isAuthenticated = false
    /// NDEF file comm mode, probed (plain GetFileSettings) just before the session
    /// goes live and cached for the secure NDEF I/O — so we never issue a plain
    /// GetFileSettings inside the session (which the chip rejects with `91 7E`).
    private var ndefCommModeFull = false

    /// DESFire file number of the NDEF file on an NTAG424 DNA.
    static let ndefFileNo: UInt8 = 0x02
    /// "Free" access-rights nibble (`0xE`): no key required.
    static let freeNibble: UInt16 = 0x0E
    /// Factory NDEF-file access rights: ReadWrite / Read / Write free (0xE), but the
    /// **Change** access stays key 0 (0x0) — matching a fresh tag's `E0 EE`. NOT
    /// `0xEEEE`: freeing the Change nibble makes the file accept ONLY a *plain*
    /// ChangeFileSettings, so a later re-protect (Full-mode CFS) fails `91 9E`.
    static let factoryAccessRights: UInt16 = 0xE0EE

    init(
        transceive: @escaping Transceive,
        makeRandom: @escaping @Sendable (Int) -> Data = NTAG424ProtectionDriver.secureRandom
    ) {
        self.transceive = transceive
        self.makeRandom = makeRandom
    }

    /// The published all-zero AES-128 key every slot holds at delivery
    /// (NT4H2421Gx rev 3.2 §9), and the key this app's own `disable` writes
    /// back. It is therefore always the last candidate a recovery tap tries:
    /// a tag left half-way through a removal is holding exactly this.
    static let factoryKey = Data(count: 16)

    /// How many keys `resolveKey` will offer in one activation.
    ///
    /// Capped rather than unbounded because **whether this chip carries a
    /// failed-authentication counter is not established in this repo**. If it
    /// does, an unbounded walk could spend a tag's attempts. Three covers every
    /// candidate list this driver builds today.
    static let maxAuthAttempts = 3

    // MARK: - High-level operations

    /// Protect the NDEF file: gate writes (and optionally reads) behind `aesKey`
    /// in `keySlot`.
    ///
    /// ## The order is inverted from what shipped, and this is why
    ///
    /// It used to be ChangeFileSettings **first**, ChangeKey last, on the
    /// reasoning that a mid-sequence drop would leave the file gated by the
    /// still-known current key. That reasoning is wrong, and the wrongness is
    /// the worst kind: it is only wrong at one abort point, and that abort point
    /// bricks the tag for this app for ever.
    ///
    /// Under the old order, a tag lifted off the phone between the two commands
    /// was left with the NDEF file gated behind key 0 while key 0 **still held
    /// the factory all-zero key** (NT4H2421Gx rev 3.2 §9). The app, believing
    /// the sequence had failed, then presented the key the user had configured,
    /// which the chip had never been given. Every retry failed. The tag was
    /// gated behind a key the app was no longer willing to try, and there is no
    /// factory reset.
    ///
    /// ChangeKey first inverts that. The gate is armed **last**, and only behind
    /// a credential the tag has already proven it holds by authenticating with
    /// it. Every abort point leaves the file free, which is to say recoverable:
    ///
    /// | # | Abort after | Tag state | Recovery |
    /// |---|---|---|---|
    /// | E0 | before SELECT | gate and key as found | re-run; `readState` sees no change |
    /// | E1 | the free-Change re-gate | Change = key 0, R/W free | re-run; the step is skipped |
    /// | E2 | AuthenticateEV2First/Continue | unchanged | re-run |
    /// | E3 | **ChangeKey** | key = the new one, gate **down** | re-run; `resolveKey` opens with |
    /// | | | | the new key, ChangeKey is skipped, |
    /// | | | | ChangeFileSettings arms the gate |
    /// | E4 | the proof re-authentication | as E3 | as E3 |
    /// | E5 | **ChangeFileSettings** | gate **up**, behind the new key | complete; a re-run reads back armed |
    /// | E6 | the read-back | complete | n/a |
    ///
    /// The trade: at E3 and E4 the tag holds the user's key with no gate, so a
    /// device that lost its Keychain record could not re-key it (it stays fully
    /// readable and writable). The old order's equivalent window instead left
    /// the tag gated behind the *published* zero key while telling the user it
    /// was locked with theirs, which is both unrecoverable and a silent security
    /// downgrade.
    ///
    /// `currentKeys` are the keys that might open the tag now, most likely
    /// first. The factory key and `aesKey` itself are always appended, because
    /// the first is what a half-finished removal leaves behind and the second is
    /// what an abort at E3 leaves behind, and refusing to try either is what
    /// made both states permanent.
    @discardableResult
    func enable(
        aesKey: Data,
        keySlot: Int,
        readProtect: Bool,
        currentKeys: [Data] = []
    ) async throws -> ProtectionResidue {
        guard aesKey.count == 16 else { throw TagError.protocolError(
            "AES key must be 16 bytes",
            diagnostics: "len=\(aesKey.count)"
        ) }
        let keyNo = UInt8(keySlot & 0x0F)
        var residue = ProtectionResidue(family: .type4, intent: .enable)
        try await selectNDEFApp()

        // State first: nothing authenticates before the tag has said what it is
        // gating and which key version it reports.
        let state = try await readState(keySlot: keySlot)
        residue.record(.stateRead)

        // Recover a file whose "Change" access was left free (0xE) — e.g. by an
        // older disable that over-freed it: a free-Change file accepts ONLY a
        // *plain* ChangeFileSettings, so the Full-mode CFS below would fail
        // 91 9E. Re-gate Change to key 0 in plain mode first (no auth needed
        // while it's free). Factory tags have Change=key0, so this is skipped
        // for them. Driven off the state read rather than a second probe.
        if state.changeNibbleIsFree {
            try await plainChangeFileSettings(
                fileNo: Self.ndefFileNo,
                fileOption: 0x00,
                accessRights: Self.factoryAccessRights
            )
        }

        let candidates = Self.candidatesForEnable(state: state, intended: aesKey, supplied: currentKeys)
        let resolved = try await resolveKey(keyNo: keyNo, candidates: candidates)
        residue.record(.gateOpened)
        residue.authenticatedWithFactoryDefault = (resolved == Self.factoryKey && candidates.first != Self.factoryKey)

        if resolved == aesKey {
            // Idempotent: the key is already the one asked for, and the
            // handshake that just succeeded is the proof. This is what makes
            // "hold the tag again to finish" work after an E3 abort.
            residue.credential = .callerSupplied
            residue.record(.credentialProven)
        } else {
            var applied: Bool
            do {
                try await changeKey(
                    keyNo: keyNo, newKey: aesKey, oldKey: resolved,
                    keyVersion: NTAG424KeyVersion.appProgrammed
                )
                applied = true
            } catch {
                // CLAUDE.md lesson 4: a refusal may be a lost ACK, so consult
                // the chip rather than declaring the key unapplied. On an AES
                // key that distinction is the difference between a live tag and
                // a dead one, and the message this used to print
                // ("protection key not fully applied") told the user the
                // opposite of what may well have happened.
                applied = try await keyThatTheTagNowHolds(
                    keyNo: keyNo, newKey: aesKey, oldKey: resolved,
                    residue: residue, arrivedGated: state.isGated, cause: error
                )
            }
            residue.record(.credentialWritten)
            residue.credential = .callerSupplied

            // ChangeKey on the authenticated slot kills the session (AN12196),
            // so this re-authentication is required anyway. It is also the
            // proof: the gate below is never armed behind a key the tag has not
            // demonstrated it holds.
            await endSecureSession()
            do {
                try await authenticate(keyNo: keyNo, key: aesKey)
            } catch {
                // The gate verdict turns on how the tag *arrived*, and it used to
                // ignore that. `provenOpen` holds for a tag whose access rights
                // read "free" at `readState`: the only command since that could
                // move them is the free-Change recovery above, and the rights it
                // writes are themselves un-gated, so the file is free whichever
                // way that went. It is a fabrication on a re-key, where the tag
                // arrived gated and nothing has re-read the rights since. Same
                // rule, and the same reason, as `Type2PasswordDriver.enable`.
                residue.gate = state.isGated ? .unknown : .provenOpen
                residue.record(
                    failure: .credentialProven,
                    "the tag would not authenticate with the new key after ChangeKey"
                        + (applied ? " reported success" : " was recovered from an ambiguous answer")
                )
                throw TagError.protectionIncomplete(
                    residue,
                    diagnostics: state.isGated
                        ? "this tag arrived with its NDEF file gated and the access rights have not "
                        + "been re-read, so nothing is known about the gate now. Keep every key "
                        + "involved: the tag may hold either of them. \(error)"
                        : "the NDEF file is still free, so nothing is gated. Keep every key "
                        + "involved: the tag may hold either of them. \(error)"
                )
            }
            residue.record(.credentialProven)
        }

        // The gate, armed last, behind a credential already proven.
        let ar = Self.accessRights(keySlot: keySlot, readProtect: readProtect)
        let fileOption: UInt8 = readProtect ? 0x03 : 0x00 // .full when read-gated, else .plain
        do {
            try await changeFileSettings(fileNo: Self.ndefFileNo, fileOption: fileOption, accessRights: ar)
        } catch {
            // **`.unknown`, whichever way the tag arrived.** This is the one
            // abort point downstream of an attempt to change the very thing the
            // verdict describes, and a refusal may be a lost ACK: the rights may
            // be the ones read at the top, or the ones this command just wrote.
            // `provenOpen` used to be set here unconditionally, which was a
            // fabrication twice over. It said the file was free on a re-key,
            // where the tag arrived gated and nothing re-read the rights; and it
            // said the arming had not happened on any tag, which is precisely
            // what a lost acknowledgement looks like from here.
            //
            // Nothing is lost by saying so. `enable` is idempotent, so the tap
            // this reports asks for finishes the job in either world.
            residue.gate = .unknown
            residue.record(failure: .gateArmed, "ChangeFileSettings refused or lost: \(error)")
            throw TagError.protectionIncomplete(
                residue,
                diagnostics: "the key is on the tag and the tag proved it holds it. Whether the "
                    + "access rights took is unconfirmed: the command that arms them neither "
                    + "acknowledged nor stated a refusal. Hold the tag against the phone again to "
                    + "finish or confirm it."
            )
        }
        residue.record(.gateArmed)

        // The read-back. It ships: there is no `#if DEBUG` around any of this,
        // because a verification worth running on the bench is worth running for
        // the user.
        await endSecureSession()
        if let after = try? await readState(keySlot: keySlot), after.isGated {
            // Type-4 gates a *file*, not a page range, so there is no page to
            // name here. The key slot is the nearest true number: it is what the
            // access-rights nibbles now point at.
            residue.gate = .provenArmed(fromPage: keySlot)
            residue.record(.gateProven)
        } else {
            // Not a throw. The gate was ACKed by a MAC'd command; what failed is
            // the confirmation, and reporting an armed tag as a failure is the
            // mistake this whole residue type exists to stop.
            residue.record(
                failure: .gateProven,
                "the access-rights read-back did not confirm the gate. A plain GetFileSettings is "
                    + "refused while an EV2 session is live, so this can also mean the re-SELECT "
                    + "did not end the session on this silicon."
            )
        }
        return residue
    }

    /// Remove protection: restore free access, then reset the key to factory
    /// zero.
    ///
    /// Order unchanged, and deliberately so: ChangeFileSettings first, ChangeKey
    /// last. Removing protection promises exactly one thing, that the gate comes
    /// down, so the gate is what goes first and the access-rights read-back is
    /// the success criterion. What has changed is everything after that point.
    ///
    /// The key reset is now **best effort**. It used to throw, which meant an
    /// abort between the two commands was reported as a total failure while the
    /// tag was in fact wide open and holding the user's key. The app then
    /// discarded nothing and re-tried nothing useful, and because a later
    /// `enable` assumed the factory key, that tag could never be protected
    /// again. Now the same state returns a residue whose credential verdict says
    /// the key was not reset, which is the caller's instruction to keep it.
    ///
    /// | # | Abort after | Tag state | Recovery |
    /// |---|---|---|---|
    /// | D0 | before SELECT | gate up, key = the user's | re-run |
    /// | D1 | authenticate | unchanged | re-run |
    /// | D2 | **ChangeFileSettings** | gate **down**, key still the user's | the removal has succeeded. Re-running
    /// skips the CFS, authenticates and resets the key |
    /// | D3 | **ChangeKey** | gate down, key = factory zero | nothing to do |
    /// | D4 | the read-back | complete | n/a |
    @discardableResult
    func disable(currentKey: Data, keySlot: Int) async throws -> ProtectionResidue {
        let keyNo = UInt8(keySlot & 0x0F)
        var residue = ProtectionResidue(family: .type4, intent: .disable)
        try await selectNDEFApp()

        let state = try await readState(keySlot: keySlot)
        residue.record(.stateRead)

        let candidates = Self.candidatesForDisable(state: state, supplied: [currentKey])
        var resolved: Data?
        do {
            resolved = try await resolveKey(keyNo: keyNo, candidates: candidates)
            residue.record(.gateOpened)
            residue.authenticatedWithFactoryDefault =
                (resolved == Self.factoryKey && candidates.first != Self.factoryKey)
        } catch {
            // No candidate opened the tag. If the gate is up, that is a genuine
            // failure and the caller must keep the credential. If the gate is
            // already down, the removal's goal is met and only the tidy-up is
            // out of reach.
            guard !state.isGated else { throw error }
            residue.gate = .provenOpen
            residue.record(.gateProven)
            residue.credential = .unknown(
                reason: "no candidate key opened the tag, so the stored key could not be reset"
            )
            residue.record(failure: .credentialWritten, "no candidate key authenticated: \(error)")
            return residue
        }

        if state.isGated {
            do {
                try await changeFileSettings(
                    fileNo: Self.ndefFileNo, fileOption: 0x00, accessRights: Self.factoryAccessRights
                )
            } catch {
                residue.record(failure: .gateDisarmed, "ChangeFileSettings refused or lost: \(error)")
                throw TagError.protectionIncomplete(
                    residue,
                    diagnostics: "removal stopped before the gate came down; the credential is untouched"
                )
            }
            residue.record(.gateDisarmed)
        }

        // Best effort from here. The gate is down; a failure below cannot turn
        // that into a reported failure, only into residue.
        if let resolved, resolved != Self.factoryKey {
            do {
                try await changeKey(
                    keyNo: keyNo, newKey: Self.factoryKey, oldKey: resolved,
                    keyVersion: NTAG424KeyVersion.factory
                )
                residue.record(.credentialWritten)
                residue.credential = .factoryDefault
            } catch {
                residue.credential = .unknown(
                    reason: "the key reset did not complete, so the tag may still hold the key "
                        + "you configured"
                )
                residue.record(failure: .credentialWritten, "ChangeKey to the factory key failed: \(error)")
            }
        } else {
            // The tag already answered to the published factory key, which is a
            // positive proof rather than an assumption.
            residue.credential = .factoryDefault
            residue.record(.credentialProven)
        }

        await endSecureSession()
        guard let after = try? await readState(keySlot: keySlot) else {
            residue.record(
                failure: .gateProven,
                "the access-rights read-back could not be performed, so the gate is unconfirmed"
            )
            return residue
        }
        guard !after.isGated else {
            // Read back, still gated, so the reading is filed. `enable` above files
            // the same verdict off the same read, with the same rationale for the
            // number it carries: a Type-4 gate covers a file rather than a page
            // range, and the key slot is the nearest true value.
            //
            // Unlike the other two families, the key reset above this line has
            // already run, so this branch can carry `.provenArmed` together with
            // `credential == .factoryDefault`. That combination is correct and
            // recoverable: `candidatesForDisable` puts the factory key back in the
            // list for the next tap, and `WriteFlowModel` keeps every stored
            // candidate while the gate is not `.provenOpen`.
            residue.gate = .provenArmed(fromPage: keySlot)
            residue.record(failure: .gateProven, "access rights still gate the NDEF file after removal")
            throw TagError.protectionIncomplete(
                residue,
                diagnostics: "removal did not open the gate; do not discard the credential"
            )
        }
        residue.gate = .provenOpen
        residue.record(.gateProven)
        if residue.credential == .factoryDefault,
           let version = after.keyVersion,
           version != NTAG424KeyVersion.factory
        {
            residue.credential = .unknown(
                reason: "the key reset was acknowledged but the key version still reads "
                    + String(format: "%02X", version)
            )
        }
        return residue
    }

    /// Finish a protection change that tore part way through, without the caller
    /// having to know which half landed.
    ///
    /// There is no separate sequence: `enable` is idempotent by construction
    /// (`resolveKey` finds whichever key the tag actually holds, ChangeKey is
    /// skipped when the key already matches, and the gate is armed and read back
    /// every time), so recovery is that same call with the candidate list
    /// widened. This entry point exists to name the states it repairs and to
    /// make a caller's intent legible:
    ///
    /// - **The old order's half-applied state.** Gate up, slot still holding the
    ///   factory zero key, app demanding the user's. Opened by the factory key,
    ///   which the candidate list always ends with, then re-keyed and re-armed.
    /// - **An E3 abort.** Gate down, slot holding the intended key. Opened by
    ///   the intended key, ChangeKey skipped, gate armed.
    /// - **A D2 abort.** Gate down, slot holding a key the caller supplies.
    ///   Opened by that key, re-keyed to the intended one, gate armed.
    @discardableResult
    func recoverProtection(
        intendedKey: Data,
        keySlot: Int,
        readProtect: Bool,
        currentKeys: [Data] = []
    ) async throws -> ProtectionResidue {
        try await enable(
            aesKey: intendedKey,
            keySlot: keySlot,
            readProtect: readProtect,
            currentKeys: currentKeys
        )
    }

    // MARK: - State, before anything is offered

    /// The plain, unauthenticated state read every operation starts from:
    /// GetFileSettings for the access rights, GetKeyVersion for the slot.
    ///
    /// Both commands are non-mutating, and neither can halt a Type-4 tag the way
    /// a Type-2 NAK does, so this costs nothing but a round trip. The caller is
    /// expected to have run `selectNDEFApp()` already: native file commands are
    /// refused at PICC level until the NDEF application is selected
    /// (live-observed 2026-07-01, `90 F5` → `91 9D`).
    func readState(keySlot: Int) async throws -> NTAG424ProtectionState {
        let settings: FileSettingsReadout
        do {
            settings = try await getFileSettings(fileNo: Self.ndefFileNo)
        } catch {
            // A live EV2 session makes the chip refuse a plain GetFileSettings
            // with `91 7E` (the reason `authenticate` caches the comm mode
            // before the session goes live). Drop the session by re-selecting
            // the application, then ask once more. If the re-SELECT does not end
            // the session on this silicon, the second attempt fails the same way
            // and the caller reports the state as unread rather than guessing.
            await endSecureSession()
            settings = try await getFileSettings(fileNo: Self.ndefFileNo)
        }
        return await NTAG424ProtectionState(
            accessRights: settings.accessRights,
            commMode: settings.commMode,
            keyVersion: getKeyVersion(keyNo: UInt8(keySlot & 0x0F))
        )
    }

    /// GetKeyVersion (`90 64 00 00 01 <keyNo> 00`).
    ///
    /// Returns `nil` for any status but `91 00`, and **never throws**: a chip
    /// that will not answer is a chip we know less about, not a failed
    /// operation. Whether an NTAG424 DNA answers this unauthenticated is not
    /// established in this repo, which is exactly why the `nil` path has to be
    /// as ordinary as the value path.
    func getKeyVersion(keyNo: UInt8) async -> UInt8? {
        let apdu = Data([0x90, 0x64, 0x00, 0x00, 0x01, keyNo & 0x0F, 0x00])
        guard let answer = try? await send(apdu, name: "GetKeyVersion"),
              answer.sw == 0x9100,
              let version = answer.body.first
        else { return nil }
        return version
    }

    /// Drop a live EV2 session without ending the tag activation, by re-issuing
    /// the ISO SELECT of the NDEF application.
    ///
    /// Required before any plain command, because while a session is live the
    /// chip answers a plain GetFileSettings `91 7E`. Best effort and never
    /// throwing: every caller has a defined behaviour for "the plain read did
    /// not work", and none of them is helped by a second error type.
    ///
    /// ⚠️ **That an ISO SELECT terminates an EV2 session is standard DESFire
    /// behaviour and is not confirmed by any capture in this repo.** If it turns
    /// out to be false on this silicon, the read-backs report the gate as
    /// unconfirmed (they never assert it), which is a loss of confirmation
    /// rather than a loss of a tag.
    func endSecureSession() async {
        isAuthenticated = false
        try? await selectNDEFApp()
    }

    /// Authenticate with the first candidate that works, re-SELECTing between
    /// attempts because a refused AuthenticateEV2First leaves the chip expecting
    /// the `AF` continuation. Returns the key that opened the tag.
    ///
    /// ⚠️ Two assumptions here need real silicon. Whether this chip carries a
    /// failed-authentication counter is not established, which is why the walk
    /// is capped at `maxAuthAttempts` rather than running the whole list; and
    /// whether a re-SELECT restores a usable state after a refused handshake is
    /// likewise unconfirmed. Neither can lose a tag: the worst case is that the
    /// second candidate is never really tried and the operation reports the same
    /// failure the single-candidate version would have.
    func resolveKey(keyNo: UInt8, candidates: [Data]) async throws -> Data {
        let list = Array(candidates.prefix(Self.maxAuthAttempts))
        guard !list.isEmpty else {
            throw TagError.authFailed(
                diagnostics: "no candidate key was offered for slot \(keyNo)"
            )
        }
        var lastDiagnostics = ""
        for (index, key) in list.enumerated() {
            if index > 0 {
                await endSecureSession()
            }
            do {
                try await authenticate(keyNo: keyNo, key: key)
                return key
            } catch let error as TagError {
                lastDiagnostics = error.diagnostics
            }
        }
        // Never names a key byte: the count is the whole of what can be said.
        throw TagError.authFailed(
            diagnostics: "none of the \(list.count) candidate key(s) opened slot \(keyNo). "
                + "last: \(lastDiagnostics)"
        )
    }

    /// After a ChangeKey whose answer was ambiguous, ask the tag which key it
    /// now holds. Returns `true` when the new key is on the tag.
    ///
    /// This is CLAUDE.md lesson 4 applied where it matters most. A ChangeKey
    /// that is refused and a ChangeKey whose acknowledgement was lost look
    /// identical from here, and the old code called both a failure with a
    /// message that told the user the key had **not** been applied. On an AES
    /// key that is the difference between a tag the app can still open and one
    /// nobody can.
    ///
    /// `arrivedGated` is the caller's own `readState` verdict, and it is what
    /// decides whether "the file is free" may be said at all. A tag whose rights
    /// read free is free here: the arming ChangeFileSettings has not run, and
    /// the free-Change recovery that may have run writes un-gated rights itself.
    /// A tag that arrived gated is a different matter, since nothing has re-read
    /// its rights, and saying the file was never gated would assert a protection
    /// state nothing read.
    private func keyThatTheTagNowHolds(
        keyNo: UInt8,
        newKey: Data,
        oldKey: Data,
        residue: ProtectionResidue,
        arrivedGated: Bool,
        cause: Error
    ) async throws -> Bool {
        await endSecureSession()
        if await (try? authenticate(keyNo: keyNo, key: newKey)) != nil {
            // The acknowledgement was lost; the key did apply. Carry on and arm
            // the gate. Note this leaves the caller authenticated with the new
            // key, which is exactly what the next step needs.
            NFCTrace.shared.note(
                "ChangeKey answer was lost, not refused: the tag holds the new key",
                label: "NTAG424.changeKey"
            )
            return true
        }
        await endSecureSession()
        var residue = residue
        if await (try? authenticate(keyNo: keyNo, key: oldKey)) != nil {
            residue.gate = arrivedGated ? .unknown : .provenOpen
            residue.credential = .unchanged
            residue.record(failure: .credentialWritten, "ChangeKey was refused: \(cause)")
            throw TagError.protectionIncomplete(
                residue,
                diagnostics: arrivedGated
                    ? "the new key was not applied and nothing on the tag changed; this tag arrived "
                    + "with its NDEF file gated, so it is still gated behind the key it came in with"
                    : "the new key was not applied and nothing on the tag changed, so this "
                    + "can be retried safely"
            )
        }
        residue.gate = arrivedGated ? .unknown : .provenOpen
        residue.credential = .unknown(
            reason: "the tag answered neither the old key nor the new one after ChangeKey"
        )
        residue.record(failure: .credentialWritten, "ChangeKey outcome unknown: \(cause)")
        throw TagError.protectionIncomplete(
            residue,
            diagnostics: arrivedGated
                ? "the tag may hold either key. Keep both: this tag arrived with its NDEF file "
                + "gated and the access rights have not been re-read."
                : "the tag may hold either key. Keep both: whichever it is, the NDEF file "
                + "was never gated, so the tag is still usable."
        )
    }

    // MARK: - Candidate ordering

    /// Ordered, deduplicated, most-likely-first, and never empty.
    ///
    /// The key version only orders the list; it never decides anything. A tag
    /// reporting `appProgrammed` is probably already carrying the intended key
    /// (an E3 abort), so try that first; anything else is probably at delivery,
    /// so try the factory key first. Both lists contain both keys, so a wrong
    /// guess costs one round trip.
    static func candidatesForEnable(
        state: NTAG424ProtectionState,
        intended: Data,
        supplied: [Data]
    ) -> [Data] {
        let ordered: [Data] = if state.keyVersion == NTAG424KeyVersion.appProgrammed {
            [intended] + supplied + [factoryKey]
        } else {
            supplied + [factoryKey, intended]
        }
        return deduplicated(ordered)
    }

    /// Same, for a removal. `supplied` is the credential the caller believes the
    /// tag holds; the factory key goes on the end because a removal that tore
    /// between its two commands left exactly that.
    static func candidatesForDisable(state: NTAG424ProtectionState, supplied: [Data]) -> [Data] {
        let ordered: [Data] = if state.keyVersion == NTAG424KeyVersion.factory {
            [factoryKey] + supplied
        } else {
            supplied + [factoryKey]
        }
        return deduplicated(ordered)
    }

    private static func deduplicated(_ keys: [Data]) -> [Data] {
        var seen = Set<Data>()
        return keys.filter { $0.count == 16 && seen.insert($0).inserted }
    }

    /// Read the NDEF file's access rights (plain, no auth) and map to settings.
    func readProtectionState() async throws -> TagProtection {
        try await selectNDEFApp()
        let settings = try await getFileSettings(fileNo: Self.ndefFileNo)
        let state = Self.interpret(accessRights: settings.accessRights)
        // Diagnostic (no secrets): confirms the read reached GetFileSettings and
        // what it decided — so a "protected tag reads as Off" is debuggable.
        NFCTrace.shared.note(
            String(format: "readState comm=%d AR=%04X → protected=%@",
                   Int(settings.commMode), Int(settings.accessRights),
                   state.passwordProtect ? "yes" : "no"),
            label: "NTAG424.readState"
        )
        return state
    }

    // MARK: - Authenticated NDEF file I/O

    //
    // Once `authenticate` has established the session, the NDEF file can be
    // written/read inside it. The NDEF file is framed `NLEN(2, big-endian) ||
    // NDEF message`; the comm mode follows the file's setting (plain when the
    // file is only write-gated, full/encrypted when read-gated too), read live
    // via GetFileSettings so we always match what the chip expects.

    /// Write `records` to the NDEF file within the live session.
    func writeNDEFFile(_ records: [NDEFRecord]) async throws {
        try requireSession()
        let message = try NDEFCodec.encode(records)
        guard message.count <= 0xFFFF else {
            throw TagError.protocolError("NDEF message too large for file", diagnostics: "len=\(message.count)")
        }
        var file = Data([UInt8((message.count >> 8) & 0xFF), UInt8(message.count & 0xFF)])
        file.append(message)
        try await writeData(fileNo: Self.ndefFileNo, offset: 0, data: file, full: ndefCommModeFull)
    }

    /// Read and de-frame the NDEF file within the live session, returning the
    /// NDEF *message* bytes (NLEN stripped) — the same shape `readNDEF` returns
    /// elsewhere, so a write/verify round-trip compares cleanly.
    func readNDEFFile() async throws -> Data {
        try requireSession()
        // Read the 2-byte NLEN, then exactly NLEN bytes — ReadData honours
        // offset/length in both plain and full comm mode.
        let header = try await readData(fileNo: Self.ndefFileNo, offset: 0, length: 2, full: ndefCommModeFull)
        guard header.count >= 2 else { return Data() }
        let nlen = (Int(header[header.startIndex]) << 8) | Int(header[header.startIndex + 1])
        guard nlen > 0 else { return Data() }
        return try await readData(fileNo: Self.ndefFileNo, offset: 2, length: nlen, full: ndefCommModeFull)
    }

    // MARK: - APDU steps

    /// SELECT the NDEF Tag Application by AID. Required before DESFire commands.
    ///
    /// The `GetVersion` used to *identify* an NTAG424 is a 3-frame command; we
    /// read only the first frame, which leaves the chip expecting `0xAF`
    /// continuations. The next SELECT then returns `69 85` ("conditions of use not
    /// satisfied"). That failed SELECT itself clears the pending-frame state, so a
    /// single retry succeeds — without it, `readProtectionState` (one SELECT) gives
    /// up and a protected tag reads as unprotected.
    func selectNDEFApp() async throws {
        let aid = Data([0xD2, 0x76, 0x00, 0x00, 0x85, 0x01, 0x01])
        var apdu = Data([0x00, 0xA4, 0x04, 0x00, UInt8(aid.count)])
        apdu.append(aid)
        apdu.append(0x00) // Le
        var (_, sw) = try await send(apdu, name: "SELECT NDEF app")
        // Retry on **any** non-success status, not just `69 85`.
        //
        // `69 85` is the status this recovery was written for, but it comes
        // from a code comment rather than a logged capture — no trace in
        // `docs/internal/` records it, and no simulator can produce the
        // pending-frame state that triggers it, so the narrow branch has never
        // executed anywhere. If the real chip answers anything else, the retry
        // silently never fires, SELECT throws, and `readProtectionState`'s
        // `try?` callers report a protected tag as unprotected.
        //
        // A SELECT is idempotent and cheap, so retrying once on any failure is
        // strictly safer than guessing the code correctly. The success check
        // below is unchanged, so a genuinely broken SELECT still fails loudly.
        if !Self.isSelectSuccess(sw) {
            (_, sw) = try await send(apdu, name: "SELECT NDEF app (retry)")
        }
        guard Self.isSelectSuccess(sw) else {
            throw TagError.protocolError("SELECT NDEF app failed", diagnostics: "sw=\(String(sw, radix: 16))")
        }
    }

    /// Both spellings of "SELECT succeeded": ISO 7816 `90 00` and the
    /// DESFire-wrapped `91 00`. Real tags have been seen using either.
    static func isSelectSuccess(_ sw: UInt16) -> Bool {
        sw == 0x9000 || sw == 0x9100
    }

    /// AuthenticateEV2First (`0x71` → `0xAF`): mutual challenge/response that
    /// derives the session ENC/MAC keys, TI and resets CmdCtr.
    func authenticate(keyNo: UInt8, key: Data) async throws {
        guard key.count == 16 else { throw TagError.protocolError(
            "AES key must be 16 bytes",
            diagnostics: "len=\(key.count)"
        ) }
        // Probe the NDEF file's comm mode while still unauthenticated. A plain
        // GetFileSettings works here; once the EV2 session is live the chip
        // requires it to be MAC'd (sw=917E otherwise), so the secure NDEF I/O
        // relies on this cached value instead of re-reading in-session.
        ndefCommModeFull = await ((try? getFileSettings(fileNo: Self.ndefFileNo))?.commMode ?? 0) == 0x03
        isAuthenticated = false

        // Frame 1: 90 71 00 00 02 KeyNo 00 00  → E(RndB) || 91 AF
        let frame1 = Data([0x90, 0x71, 0x00, 0x00, 0x02, keyNo, 0x00, 0x00])
        let (body1, sw1) = try await send(frame1, name: "AuthEV2First", secret: true)
        guard sw1 == 0x91AF, body1.count == 16 else {
            throw TagError.authFailed(diagnostics: "AuthEV2First sw=\(String(sw1, radix: 16))")
        }
        let zeroIV = Data(count: 16)
        let randB = NTAG424Crypto.aesCBCDecrypt(key: key, iv: zeroIV, data: body1)

        // Frame 2: 90 AF 00 00 20 E(RndA || RndB') 00  → E(TI || RndA' || caps) || 91 00
        let randA = makeRandom(16)
        let randBPrime = NTAG424Crypto.rotateLeftByOne(randB)
        let cipher = NTAG424Crypto.aesCBCEncrypt(key: key, iv: zeroIV, data: randA + randBPrime)
        var frame2 = Data([0x90, 0xAF, 0x00, 0x00, 0x20])
        frame2.append(cipher)
        frame2.append(0x00)
        let (body2, sw2) = try await send(frame2, name: "AuthEV2Continue", secret: true)
        guard sw2 == 0x9100, body2.count == 32 else {
            throw TagError.authFailed(
                diagnostics: "AuthEV2Continue sw=\(String(sw2, radix: 16))"
            )
        }
        let plain = NTAG424Crypto.aesCBCDecrypt(key: key, iv: zeroIV, data: body2)
        let receivedTI = plain.subdata(in: plain.startIndex ..< (plain.startIndex + 4))
        let randAPrime = plain.subdata(in: (plain.startIndex + 4) ..< (plain.startIndex + 20))
        guard randAPrime == NTAG424Crypto.rotateLeftByOne(randA) else {
            throw TagError.authFailed(diagnostics: "RndA' mismatch")
        }

        ti = receivedTI
        encKey = NTAG424Crypto.deriveENCKey(appKey: key, randA: randA, randB: randB)
        macKey = NTAG424Crypto.deriveMACKey(appKey: key, randA: randA, randB: randB)
        cmdCtr = 0
        authedKeyNo = keyNo
        isAuthenticated = true
        // Marker so the device trace confirms how far the handshake got (no
        // secrets — TI is a per-session transaction id, not key material).
        NFCTrace.shared.note(
            String(
                format: "EV2 session established key=%d TI=%@ ndefFull=%@",
                Int(keyNo),
                ti.hexString,
                ndefCommModeFull ? "yes" : "no"
            ),
            label: "NTAG424.auth"
        )
    }

    struct FileSettingsReadout { let commMode: UInt8
        let accessRights: UInt16
    }

    /// GetFileSettings (`0xF5`) — plain, no session required. Response is
    /// `FileType(1) || FileOption(1) || AccessRights(2) || …`, where the
    /// AccessRights bytes are sent **(ReadWrite|Change) first, then (Read|Write)**
    /// — i.e. big-endian for our `RW|Change|R|W` word.
    func getFileSettings(fileNo: UInt8) async throws -> FileSettingsReadout {
        let apdu = Data([0x90, 0xF5, 0x00, 0x00, 0x01, fileNo, 0x00])
        let (body, sw) = try await send(apdu, name: "GetFileSettings")
        guard sw == 0x9100, body.count >= 4 else {
            throw TagError.protocolError(
                "GetFileSettings failed",
                diagnostics: "sw=\(String(sw, radix: 16)) len=\(body.count)"
            )
        }
        let commByte = body[body.startIndex + 1]
        let arHigh = body[body.startIndex + 2] // (ReadWrite | Change)
        let arLow = body[body.startIndex + 3] // (Read | Write)
        return FileSettingsReadout(commMode: commByte & 0x03, accessRights: (UInt16(arHigh) << 8) | UInt16(arLow))
    }

    /// ChangeFileSettings (`0x5F`) in Full secure-messaging mode (AN12196 §6.5):
    /// CmdData = `FileOption(1) || AccessRights(2)`, ISO-9797 padded, AES-CBC
    /// encrypted under IVc, with a command MAC. The AccessRights bytes go on the
    /// wire **(ReadWrite|Change) first, then (Read|Write)** — big-endian for our
    /// `RW|Change|R|W` word. (Real silicon rejects the reversed order with
    /// PARAMETER_ERROR `91 9E`; the simulator can't catch it without this layout.)
    func changeFileSettings(fileNo: UInt8, fileOption: UInt8, accessRights: UInt16) async throws {
        try requireSession()
        // Diagnostic: surface the exact CmdData *plaintext* (FileOption +
        // AccessRights) we're about to encrypt. These are not secrets — only the
        // AES key is. AccessRights nibble layout: RW | Change | R | W.
        NFCTrace.shared.note(
            String(
                format: "CFS file=%02X opt=%02X AR=%04X ctr=%d",
                Int(fileNo),
                Int(fileOption),
                Int(accessRights),
                Int(cmdCtr)
            ),
            label: "ChangeFileSettings"
        )
        let plain = Data([fileOption, UInt8((accessRights >> 8) & 0xFF), UInt8(accessRights & 0xFF)])
        let padded = NTAG424Crypto.iso9797Pad(plain)
        let iv = NTAG424Crypto.commandIV(sesAuthENCKey: encKey, ti: ti, cmdCtr: cmdCtr)
        let enc = NTAG424Crypto.aesCBCEncrypt(key: encKey, iv: iv, data: padded)
        let mac = NTAG424Crypto.commandMAC(
            sesAuthMACKey: macKey, cmdINS: 0x5F, cmdCtr: cmdCtr, ti: ti,
            cmdHeader: Data([fileNo]), encCmdData: enc
        )
        let data = Data([fileNo]) + enc + mac
        var apdu = Data([0x90, 0x5F, 0x00, 0x00, UInt8(data.count)])
        apdu.append(data)
        apdu.append(0x00)
        let (_, sw) = try await send(apdu, name: "ChangeFileSettings", secret: true)
        try expectDESFireOK(sw, step: "ChangeFileSettings")
        cmdCtr &+= 1
    }

    /// ChangeFileSettings (`0x5F`) in **Plain** comm mode — used only to re-gate a
    /// file whose "Change" access right is currently free (0xE), the one state that
    /// *requires* a plain (unencrypted, unauthenticated) CFS. CmdData =
    /// `FileNo || FileOption || AccessRights(RW|Change first, then R|W)`, no MAC,
    /// no session (so it must run before `authenticate`). Not a secret (access
    /// rights, not key material).
    func plainChangeFileSettings(fileNo: UInt8, fileOption: UInt8, accessRights: UInt16) async throws {
        let cmdData = Data([fileNo, fileOption, UInt8((accessRights >> 8) & 0xFF), UInt8(accessRights & 0xFF)])
        var apdu = Data([0x90, 0x5F, 0x00, 0x00, UInt8(cmdData.count)])
        apdu.append(cmdData)
        apdu.append(0x00)
        NFCTrace.shared.note(
            String(format: "CFS(plain) file=%02X opt=%02X AR=%04X", Int(fileNo), Int(fileOption), Int(accessRights)),
            label: "ChangeFileSettings"
        )
        let (_, sw) = try await send(apdu, name: "ChangeFileSettings(plain)")
        try expectDESFireOK(sw, step: "ChangeFileSettings(plain)")
    }

    /// ChangeKey (`0xC4`) per AN12196 §6.16. We only ever change the slot we
    /// authenticated with (same-key case): `CmdData = NewKey(16) || KeyVer(1) ||
    /// 0x80 || 0x00×14`, encrypted under IVc with a command MAC over `[KeyNo]`.
    func changeKey(keyNo: UInt8, newKey: Data, oldKey: Data, keyVersion: UInt8) async throws {
        try requireSession()
        guard newKey.count == 16 else { throw TagError.protocolError(
            "new key must be 16 bytes",
            diagnostics: "len=\(newKey.count)"
        ) }
        let plain: Data
        if keyNo == authedKeyNo {
            // Same-key: no XOR, no CRC.
            var p = newKey
            p.append(keyVersion)
            p.append(0x80)
            p.append(Data(count: 14))
            plain = p
        } else {
            // Different-key: (NewKey XOR OldKey) || KeyVer || CRC32_LE(NewKey) || 0x80 || 0x00×10.
            guard oldKey.count == 16 else { throw TagError.protocolError(
                "old key must be 16 bytes",
                diagnostics: "len=\(oldKey.count)"
            ) }
            var p = NTAG424Crypto.xor(newKey, oldKey)
            p.append(keyVersion)
            p.append(NTAG424Crypto.crc32Jam(newKey))
            p.append(0x80)
            p.append(Data(count: 10))
            plain = p
        }
        let iv = NTAG424Crypto.commandIV(sesAuthENCKey: encKey, ti: ti, cmdCtr: cmdCtr)
        let enc = NTAG424Crypto.aesCBCEncrypt(key: encKey, iv: iv, data: plain)
        let header = Data([keyNo & 0x0F])
        let mac = NTAG424Crypto.commandMAC(
            sesAuthMACKey: macKey, cmdINS: 0xC4, cmdCtr: cmdCtr, ti: ti,
            cmdHeader: header, encCmdData: enc
        )
        let data = header + enc + mac
        var apdu = Data([0x90, 0xC4, 0x00, 0x00, UInt8(data.count)])
        apdu.append(data)
        apdu.append(0x00)
        let (_, sw) = try await send(apdu, name: "ChangeKey", secret: true)
        try expectDESFireOK(sw, step: "ChangeKey")
        cmdCtr &+= 1
        // Changing the authenticated key invalidates the session per AN12196.
        if keyNo == authedKeyNo {
            isAuthenticated = false
        }
    }

    /// WriteData (`0x8D`). CmdHeader is **always** `FileNo || Offset(3 LE) ||
    /// Length(3 LE)` (7 bytes). Plain comm mode appends the data as-is, no MAC;
    /// full comm mode appends IV-encrypted, MAC'd data. Every in-session command
    /// advances `CmdCtr` (AN12196 §8.2.3 / reference `nxpPlainCommand`). A single
    /// short APDU caps the payload at 255 bytes; larger NDEF would need chunking
    /// (a follow-up — real NDEF payloads here are well under that).
    func writeData(fileNo: UInt8, offset: Int, data: Data, full: Bool) async throws {
        try requireSession()
        var cmdHeader = Data([fileNo])
        cmdHeader.append(Self.uint24LE(offset))
        cmdHeader.append(Self.uint24LE(data.count))
        let payload: Data
        if full {
            let padded = NTAG424Crypto.iso9797Pad(data)
            let iv = NTAG424Crypto.commandIV(sesAuthENCKey: encKey, ti: ti, cmdCtr: cmdCtr)
            let enc = NTAG424Crypto.aesCBCEncrypt(key: encKey, iv: iv, data: padded)
            let mac = NTAG424Crypto.commandMAC(
                sesAuthMACKey: macKey, cmdINS: 0x8D, cmdCtr: cmdCtr, ti: ti,
                cmdHeader: cmdHeader, encCmdData: enc
            )
            payload = cmdHeader + enc + mac
        } else {
            payload = cmdHeader + data
        }
        guard payload.count <= 0xFF else {
            throw TagError.protocolError(
                "authenticated NDEF write too large for one frame",
                diagnostics: "len=\(payload.count)"
            )
        }
        var apdu = Data([0x90, 0x8D, 0x00, 0x00, UInt8(payload.count)])
        apdu.append(payload)
        apdu.append(0x00)
        let (_, sw) = try await send(apdu, name: "WriteData")
        try expectDESFireOK(sw, step: "WriteData")
        cmdCtr &+= 1
    }

    /// ReadData (`0xAD`). CmdHeader is **always** `FileNo || Offset(3 LE) ||
    /// Length(3 LE)`. Plain comm mode sends no MAC and the response is the raw
    /// `length` bytes; full comm mode MAC's the request and the response is
    /// IV-encrypted + MAC'd (verified, decrypted, unpadded to `length`). Every
    /// in-session command advances `CmdCtr`.
    func readData(fileNo: UInt8, offset: Int, length: Int, full: Bool) async throws -> Data {
        try requireSession()
        var cmdHeader = Data([fileNo])
        cmdHeader.append(Self.uint24LE(offset))
        cmdHeader.append(Self.uint24LE(length))
        var apdu = Data([0x90, 0xAD, 0x00, 0x00])
        if full {
            let mac = NTAG424Crypto.commandMAC(
                sesAuthMACKey: macKey, cmdINS: 0xAD, cmdCtr: cmdCtr, ti: ti,
                cmdHeader: cmdHeader, encCmdData: Data()
            )
            apdu.append(UInt8((cmdHeader.count + mac.count) & 0xFF))
            apdu.append(cmdHeader)
            apdu.append(mac)
        } else {
            apdu.append(UInt8(cmdHeader.count))
            apdu.append(cmdHeader)
        }
        apdu.append(0x00)
        let (body, sw) = try await send(apdu, name: "ReadData")
        try expectDESFireOK(sw, step: "ReadData")
        defer { cmdCtr &+= 1 }
        guard full else { return body } // plain: response is the raw data
        guard body.count >= 8, (body.count - 8) % 16 == 0 else {
            throw TagError.malformedResponse(body, diagnostics: "ReadData full: bad length \(body.count)")
        }
        let enc = Data(body.prefix(body.count - 8))
        let receivedMAC = Data(body.suffix(8))
        let expectedMAC = NTAG424Crypto.responseMAC(
            sesAuthMACKey: macKey, cmdCtr: cmdCtr, ti: ti, encResponseData: enc
        )
        guard receivedMAC == expectedMAC else {
            throw TagError.protocolError("ReadData response MAC mismatch", diagnostics: "len=\(body.count)")
        }
        let iv = NTAG424Crypto.responseIV(sesAuthENCKey: encKey, ti: ti, cmdCtr: cmdCtr)
        let padded = NTAG424Crypto.aesCBCDecrypt(key: encKey, iv: iv, data: enc)
        guard let plain = NTAG424Crypto.stripIso9797(padded, plaintextLength: length) else {
            throw TagError.malformedResponse(padded, diagnostics: "ReadData full: unpad failed")
        }
        return plain
    }

    private static func uint24LE(_ value: Int) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF)])
    }

    // MARK: - Access-rights helpers

    /// Build the NDEF file's access-rights word for protection with `keySlot`.
    /// Nibble layout `RW | Change | R | W` (free = `0xE`). Write-only leaves Read
    /// free; read-protect gates Read too. ReadWrite + Change are set to the key so
    /// no free bypass remains and only the key-holder can revert.
    static func accessRights(keySlot: Int, readProtect: Bool) -> UInt16 {
        let n = UInt16(keySlot & 0x0F)
        let w = n
        let r: UInt16 = readProtect ? n : freeNibble
        let rw = n
        let change = n
        return (rw << 12) | (change << 8) | (r << 4) | w
    }

    /// Map an NDEF file's access-rights word to the family-agnostic settings.
    static func interpret(accessRights ar: UInt16) -> TagProtection {
        let w = ar & 0x0F
        let r = (ar >> 4) & 0x0F
        let writeGated = (w != freeNibble)
        let readGated = (r != freeNibble)
        guard writeGated || readGated else { return .none }
        return TagProtection(
            passwordProtect: true,
            style: .type4(.init(keySlot: 0, readProtect: readGated)),
            hasStoredCredential: false
        )
    }

    // MARK: - Transport

    private func requireSession() throws {
        guard isAuthenticated else {
            throw TagError.authFailed(diagnostics: "no EV2 session. Authenticate first")
        }
    }

    private func expectDESFireOK(_ sw: UInt16, step: String) throws {
        switch sw {
        case 0x9100: return

        case 0x919D, 0x91AE: throw TagError.authFailed(
                diagnostics: "\(step) sw=\(String(sw, radix: 16))"
            )

        default: throw TagError.protocolError("\(step) failed", diagnostics: "sw=\(String(sw, radix: 16))")
        }
    }

    /// Send an APDU and split off the trailing 2-byte status word. The transceive
    /// boundary returns `response ‖ SW1 ‖ SW2` (CoreNFC's `.iso7816` case appends
    /// the status word; the simulator returns the same shape).
    private func send(_ bytes: Data, name: String, secret: Bool = false) async throws -> (body: Data, sw: UInt16) {
        let command = RawCommand(bytes: bytes, name: name, family: .type4(.ntag424DNA))
        let response = try await transceive(command)
        guard response.count >= 2 else {
            throw TagError.malformedResponse(response, diagnostics: "\(name): short response")
        }
        let sw = (UInt16(response[response.endIndex - 2]) << 8) | UInt16(response[response.endIndex - 1])
        let body = response.prefix(response.count - 2)
        return (Data(body), sw)
    }

    /// CSPRNG for RndA. Falls back to a fixed pattern only if `SecRandomCopyBytes`
    /// fails (which it effectively never does) — never a weak default for a secret,
    /// since RndA is a nonce, not the key.
    @Sendable static func secureRandom(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        if status != errSecSuccess {
            for i in 0 ..< count {
                bytes[i] = UInt8((i &* 31 &+ 17) & 0xFF)
            }
        }
        return Data(bytes)
    }
}
