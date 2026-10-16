#if DEBUG
import Foundation
import HexNFCDesign
import HexNFCKit
import HexNFCTestKit
import Observation

/// DEBUG-only state machine for the gated, one-at-a-time irreversible-ops flow.
/// Kept separate from the shipping `OperationsFlowModel`/`ConnectedTag` surface so
/// the app binary never grows destroy / one-way-change-key primitives. The
/// typed-UID confirmation happens IN-APP *before* the NFC session opens (the
/// system NFC sheet would otherwise block typing), then a single tap on the same
/// tag executes exactly one operation.
@MainActor
@Observable
public final class IrreversibleOpsFlowModel {
    public enum Operation: String, CaseIterable, Identifiable, Sendable {
        case permanentLock
        case formatVirginCC
        case lockSignature
        case slixPasswordLatch
        case slixDestroy
        case desfireChangeKey

        public var id: String {
            rawValue
        }

        public var title: String {
            switch self {
            case .permanentLock: "Permanent lock"
            case .formatVirginCC: "Write Capability Container"
            case .lockSignature: "Permanently lock signature"
            case .slixPasswordLatch: "SLIX write-password check"
            case .slixDestroy: "SLIX DESTROY"
            case .desfireChangeKey: "DESFire ChangeKey"
            }
        }

        /// Operations that need the tag presented twice: arm on the first tap,
        /// then prove enforcement on a *fresh* activation and clean up. A SLIX2
        /// unlocks its write gate for the rest of the tap that set the password,
        /// so a single session can never observe the gate.
        public var needsSecondTap: Bool {
            self == .slixPasswordLatch
        }

        public var warning: String {
            switch self {
            case .permanentLock:
                "Sets the tag's lock bytes. This is IRREVERSIBLE. The tag can never be written again."

            case .formatVirginCC:
                "Writes the NDEF Capability Container to the OTP page. Page 3 is one-time-programmable. Bits can be set but never cleared, so this happens ONCE per tag and the declared NDEF size can never be corrected. Only offered on a tag whose CC is still blank."

            case .slixPasswordLatch:
                "Sets the SLIX2 write password, re-reads the tag to prove the gate is enforced, then returns the access conditions to Public and resets the password to the value a delivered IC carries, 00 00 00 00. The password itself can never be cleared (only DESTROY does that), so resetting it to the factory value is what leaves the tag protectable again. Needs two taps."

            case .lockSignature:
                "Issues LOCK_SIG (AC 02) on an NTAG 210µ, permanently freezing the chip's NXP originality signature so it can never be unlocked or overwritten. This is IRREVERSIBLE. The signature stays readable. This only removes the ability to replace it. Note the tag already ships with the signature locked (but reversibly); this makes that permanent. The op then verifies by attempting an unlock, which must be refused."

            case .slixDestroy:
                "Issues the ICODE SLIX DESTROY command. This BRICKS the tag permanently and cannot be undone."

            case .desfireChangeKey:
                "Rotates a DESFire AES key without retaining it. If the new key is lost the application is unrecoverable."
            }
        }

        /// Permanent lock, the OTP CC write and the SLIX password check have
        /// hardware-verified `ConnectedTag` primitives. DESTROY and ChangeKey
        /// stay gated placeholders until each gets a dedicated,
        /// on-hardware-verified primitive (per the "highly intentional"
        /// requirement).
        /// `slixPasswordLatch` completed clean on real silicon on 2026-08-07,
        /// after `Iso15693ProtectionClient` moved to Selected mode: the chip
        /// honours its password commands only in Addressed or Selected mode
        /// (SL2S2602 §9.5.3.2/3.3) and silently ignores them otherwise, and
        /// nfcd refuses the Address flag, so SELECT + Select-flagged frames is
        /// the one transmissible route. See
        /// `docs/internal/chip-config-pages.md` §ICODE SLIX2.
        public var isImplemented: Bool {
            self == .permanentLock || self == .formatVirginCC
                || self == .slixPasswordLatch || self == .lockSignature
        }

        /// Whether this operation should be offered for a tag whose capability
        /// container is known to be blank (`true`), known to be written
        /// (`false`), or unknown (`nil`, when `t2.ccVerify` did not run).
        ///
        /// Only `formatVirginCC` cares. Page 3 is OTP, so on a tag that already
        /// has a CC the op can only ever refuse — and a factory NTAG21x arrives
        /// pre-formatted, which made this a button that could never work on the
        /// most common chip in the catalog. `applies(to:)` cannot see it because
        /// a written CC is a fact about the tag, not the chip.
        ///
        /// Unknown stays offered: the execute-time guard still refuses a
        /// non-blank page 3, so the failure mode is a clear error rather than a
        /// corrupted OTP page.
        public func appliesToTag(capabilityContainerIsBlank: Bool?) -> Bool {
            guard self == .formatVirginCC else { return true }
            return capabilityContainerIsBlank ?? true
        }

        /// Which chips this operation is offered for.
        ///
        /// Deliberately here rather than in `IrreversibleOpsView`: the view is
        /// `#if DEBUG && os(iOS)`, so `swift test` can never reach it, and this
        /// is the predicate that decides whether a one-way command is put in
        /// front of a given tag. It is the last thing that should be untestable.
        public func applies(to profile: ChipProfile) -> Bool {
            switch self {
            case .permanentLock:
                // Capability-driven on purpose, so a chip cannot quietly gain
                // this by being added to the catalog: `.permanentLock` has to
                // be written into its profile deliberately, and the profile is
                // where the datasheet reasoning lives. MIFARE Ultralight C
                // declares it (static lock bytes at page 2, lock bytes 2–3 at
                // page 28h) and reaches the same Type-2 lock path.
                return profile.capabilities.contains(.permanentLock)

            case .formatVirginCC:
                // Type-2 only: the OTP CC write. Type-5 keeps its CC in a
                // rewritable block, so that format is an ordinary operation and
                // doesn't belong behind this gate.
                //
                // MIFARE Ultralight C qualifies, and is the only chip in our
                // stock that genuinely needs it: it ships with page 3 blank
                // (rev 3.3 Table 13), where NTAG21x and NTAG 210µ arrive
                // pre-formatted and the page-3 guard correctly refuses them.
                guard case .type2 = profile.family else { return false }
                return profile.capabilities.contains(.formatCC) && profile.factoryCC != nil

            case .lockSignature:
                // WRITE_SIG / LOCK_SIG are specific to the customisable-signature
                // dies (NTAG 210µ, Ultralight Nano). Plain NTAG21x and UL EV1
                // carry a fixed NXP signature and NAK both opcodes, so this must
                // not be offered family-wide off `.signatureRead` alone.
                return profile.id == .ntag210Micro && profile.capabilities.contains(.signatureRead)

            case .slixPasswordLatch:
                guard case .type5 = profile.family else { return false }
                return profile.capabilities.contains(.passwordAuth)

            case .slixDestroy:
                if case .type5 = profile.family {
                    return true
                } else {
                    return false
                }

            case .desfireChangeKey:
                if case .type4(let v) = profile.family {
                    return v != .ntag424DNA
                } else {
                    return false
                }
            }
        }
    }

    public enum Phase {
        case idle
        case confirming(uidTail: String)
        case executing
        case done(String)
        case error(String, diagnostics: String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var operation: Operation = .permanentLock

    private let factory: TagSessionFactory
    /// The UID that passed the non-destructive suite — the op must run on the same tag.
    private let expectedUID: Data
    /// From the suite's `t2.ccVerify`. See `Operation.appliesToTag(capabilityContainerIsBlank:)`.
    public let capabilityContainerIsBlank: Bool?
    private var task: Task<Void, Never>?

    /// iOS keeps the NFC sheet animating out and imposes an opaque inter-session
    /// cooldown with no "ready" event, so a fixed floor is unavoidable between
    /// taps. Anchored to real teardown (`invalidate` awaits it), not guessed from
    /// the call site. Matches `EnforcementCheckFlowModel.interSessionCooldown`.
    /// Injectable so tests can drive the two-tap flow without the wall-clock wait.
    private let interSessionCooldown: Duration

    public init(
        factory: TagSessionFactory,
        expectedUID: Data,
        capabilityContainerIsBlank: Bool? = nil,
        interSessionCooldown: Duration = .milliseconds(2500)
    ) {
        self.factory = factory
        self.expectedUID = expectedUID
        self.capabilityContainerIsBlank = capabilityContainerIsBlank
        self.interSessionCooldown = interSessionCooldown
    }

    /// The **whole** UID, hex, no separators, for the typed gate.
    ///
    /// This used to be the last 4 characters, on the assumption that a UID tail
    /// identifies a tag. It does not, in general. Two Ultralight C tags from our
    /// own stock (live-dumped 2026-08-07) share SN3–SN6 exactly:
    ///
    ///     04 B8 EC · CA 79 77 80
    ///     04 AB 51 · CA 79 77 80
    ///
    /// so every tag in that batch displayed the same `7780` and the gate could
    /// not tell one from another. Which end of a UID carries the entropy is a
    /// property of the manufacturer's numbering, not something we can assume, so
    /// the only correct answer is to use all of it.
    ///
    /// The value is shown next to the input, so this is transcription rather
    /// than recall, and the extra characters cost little. The scan-time
    /// `tag.uid == expectedUID` check is what actually prevents acting on the
    /// wrong tag; this gate is the deliberate speed bump in front of it, and a
    /// speed bump that reads identically for ten tags is not one.
    public var uidTail: String {
        expectedUID.hexString.replacingOccurrences(of: ":", with: "")
    }

    /// Select an operation → move to the in-app typed-UID confirmation.
    public func select(_ operation: Operation) {
        self.operation = operation
        guard operation.isImplemented else {
            phase = .error(
                "\(operation.title) is not implemented in this build.",
                diagnostics: "Gated placeholder: needs a dedicated, on-hardware-verified primitive before it can be issued safely."
            )
            return
        }
        phase = .confirming(uidTail: uidTail)
    }

    /// Called by `DestructiveConfirmationView` once the UID tail matches — opens
    /// the session and executes the single operation.
    public func confirmAndExecute() {
        guard case .confirming = phase else { return }
        phase = .executing
        task = Task { await run() }
    }

    public func cancel() {
        task?.cancel()
        phase = .idle
    }

    private func run() async {
        if operation.needsSecondTap {
            await runSlixPasswordLatch()
            return
        }
        let session = factory.makeSession()
        do {
            let tag = try await session.start(alert: operation.title)
            guard tag.uid == expectedUID else {
                await session.invalidate(error: "Different tag")
                phase = .error(
                    "This is a different tag than the one that passed the suite.",
                    diagnostics: "expected uid=\(expectedUID.hexString) got uid=\(tag.uid.hexString)"
                )
                return
            }
            try await execute(operation, on: tag)
            await session.invalidate(error: nil)
            phase = .done("\(operation.title) applied to \(tag.uid.hexString).")
        } catch let error as TagError {
            await session.invalidate(error: nil)
            phase = .error(String(localized: error.userMessage), diagnostics: error.diagnostics)
        } catch {
            await session.invalidate(error: nil)
            phase = .error("\(error)", diagnostics: "")
        }
    }

    // MARK: - SLIX write-password check (two taps)

    /// The one thing that verifies `Iso15693ProtectionClient` against real
    /// silicon. Deliberately NOT in the batch: it rewrites a *persistent*
    /// credential (the write password survives the run — a SLIX2 password can
    /// be reset but never cleared), and it needs two sessions, neither of
    /// which fits the batch's single-session, leave-no-trace shape. The
    /// access conditions themselves ARE returned to Public on tap 2
    /// (`PROTECT PAGE` status 00h — the gate does not latch, see
    /// docs/internal/chip-config-pages.md §ICODE SLIX2).
    ///
    /// Arm on tap 1, then prove the gate on a **fresh activation** — a SLIX2
    /// leaves the write gate open for the remainder of the tap that set the
    /// password, so a single session can never observe enforcement. Tap 2 probes,
    /// then resets the password to the documented default.
    private func runSlixPasswordLatch() async {
        let password = TagTestCredentials().type5Password
        let credential = TagCredential.type5(password: password, kind: .write)

        // --- Tap 1: arm ---
        let armSession = factory.makeSession()
        do {
            let tag = try await armSession.start(alert: "Tap 1 of 2. Set the write password")
            guard tag.uid == expectedUID else {
                await armSession.invalidate(error: "Different tag")
                phase = .error(
                    "This is a different tag than the one that passed the suite.",
                    diagnostics: "expected uid=\(expectedUID.hexString) got uid=\(tag.uid.hexString)"
                )
                return
            }
            try await tag.enableProtection(.type5(write: password, read: nil, kind: .write))
            await armSession.invalidate(error: nil)
        } catch let error as TagError {
            await armSession.invalidate(error: nil)
            phase = .error("Arming failed: \(String(localized: error.userMessage))", diagnostics: error.diagnostics)
            return
        } catch {
            await armSession.invalidate(error: nil)
            phase = .error("Arming failed: \(error)", diagnostics: "")
            return
        }

        try? await Task.sleep(for: interSessionCooldown)

        // --- Tap 2: probe on a fresh activation, then reset ---
        let probeSession = factory.makeSession()
        var verdict = "inconclusive"
        do {
            let tag = try await probeSession.start(alert: "Tap 2 of 2. Verify and reset")
            guard tag.uid == expectedUID else {
                await probeSession.invalidate(error: "Different tag")
                phase = .error(
                    "This is a different tag than the one that was armed.",
                    diagnostics: "expected uid=\(expectedUID.hexString) got uid=\(tag.uid.hexString)"
                )
                return
            }
            // Write a user block its own current bytes — an accepted write is a
            // no-op, so this probe can't damage anything either way.
            let probeBlock: UInt8 = 2
            let readBack = try await tag.transceive(RawCommand(
                bytes: Data([0x02, Iso15693Opcode.readSingleBlock, probeBlock]), name: "READ_SINGLE_BLOCK"
            ))
            guard readBack.first == 0x00, readBack.count >= 5 else {
                throw TagError.malformedResponse(readBack, diagnostics: "probe read failed: \(readBack.hexString)")
            }
            let current = readBack.subdata(in: (readBack.startIndex + 1) ..< (readBack.startIndex + 5))
            let unauth = try await tag.transceive(RawCommand(
                bytes: Data([
                    0x02,
                    Iso15693Opcode.writeSingleBlock,
                    probeBlock,
                ]) + current, name: "WRITE_SINGLE_BLOCK (unauth)"
            ))
            verdict = unauth.first == 0x00
                ? "NOT ENFORCED: the unauthenticated write was accepted"
                : "ENFORCED: the unauthenticated write was refused (\(unauth.hexString))"

            // Present the password; the same write must now be accepted.
            _ = try await tag.authenticate(credential)
            let authed = try await tag.transceive(RawCommand(
                bytes: Data([
                    0x02,
                    Iso15693Opcode.writeSingleBlock,
                    probeBlock,
                ]) + current, name: "WRITE_SINGLE_BLOCK (authed)"
            ))
            let authedOK = authed.first == 0x00

            // Return the access conditions to Public and reset the password to
            // the documented default. The password value itself is the one
            // thing that cannot be cleared, only reset.
            try await tag.disableProtection(using: credential)
            await probeSession.invalidate(error: nil)

            phase = .done("""
            \(verdict)
            Authenticated write \(authedOK ? "succeeded" : "FAILED")
            Access conditions returned to Public; password reset to the delivered-IC value 00 00 00 00 (a SLIX2 password can never be cleared, only reset).
            """)
        } catch let error as TagError {
            await probeSession.invalidate(error: nil)
            phase = .error(
                "Probe/reset failed: \(String(localized: error.userMessage)). The tag may still hold the test password.",
                diagnostics: "verdict=\(verdict) :: \(error.diagnostics)"
            )
        } catch {
            await probeSession.invalidate(error: nil)
            phase = .error("Probe/reset failed: \(error)", diagnostics: "verdict=\(verdict)")
        }
    }

    private func execute(_ operation: Operation, on tag: any ConnectedTag) async throws {
        switch operation {
        case .permanentLock:
            try await tag.permanentLock()
            // Prove the lock behaviourally, the way `lockSignature` below does.
            // Type-2 lock bytes are OR-only and have no status command, so an
            // ACK on the lock write proves the frame was accepted, not that the
            // chip now refuses writes. The first live run (2026-08-07) reported
            // success purely from the ACKs.
            //
            // Type-2 only: `permanentLock` returns early for Type-5, whose
            // per-block LOCK_BLOCK path needs its own proof.
            // ⚠️ Lock timing is NOT uniform across the Type-2 family. MIFARE
            // Ultralight C lock bytes are "valid upon the next REQA or WUPA
            // command" (MF0ICU2 rev 3.3 §7.5.3), so this in-session probe would
            // see the write ACCEPTED on a tag that really is locked, and report
            // a false "NOT permanently locked" about an irreversible operation
            // that in fact succeeded. NTAG21x and Ultralight EV1 latch
            // immediately (MF0ULX1 §8.5.2 "Setting a lock bit to 1 immediately
            // prevents write access"), so only they can be judged this tap.
            //
            // This has never fired on Ultralight C silicon: the probe was added
            // after the one UL-C tag was locked, so the gap was latent.
            if case .type2(let variant)? = tag.chip?.family, variant != .mifareUltralightC {
                let pageSize = tag.chip?.memoryLayout.pageSize ?? 4
                // Page 4 is inside the static lock bytes' range (3–15) on every
                // Type-2 chip in the catalog, and unlike page 3 it is not OTP.
                let offset = 4 * pageSize
                let original = try await tag.readMemory(range: offset ..< offset + pageSize)
                var writeWasAccepted = false
                do {
                    // The original bytes, so an accepted write changes nothing.
                    try await tag.writeMemory(at: offset, bytes: original)
                    writeWasAccepted = true
                } catch {
                    // Any refusal is the proof. Deliberately not narrowed to a
                    // clean NAK: a refusal returns an Ultralight C to HALT, and
                    // iOS surfaces that inconsistently as either a protocol
                    // error or a dropped tag. Only an *accepted* write is
                    // unambiguous, and that is the failure case.
                }
                if writeWasAccepted {
                    throw TagError.verificationFailed(
                        diff: original,
                        diagnostics: "page 4 write was ACKed after the lock bytes were set: "
                            + "the tag is NOT permanently locked (clone silicon?)"
                    )
                }
            }
            // Type-5: the client already read the security status back, so the
            // chip *reported* every lockable block locked; this is the
            // behavioural half — a locked block must refuse a write of its own
            // bytes (SLIX2 answers its generic `01 0F`).
            if case .type5? = tag.chip?.family {
                let probeBlock: UInt8 = 2
                let read = try await tag.transceive(RawCommand(
                    bytes: Data([0x02, 0x20, probeBlock]), name: "READ_SINGLE_BLOCK (lock probe)"
                ))
                guard read.first == 0x00, read.count >= 5 else {
                    throw TagError.malformedResponse(read, diagnostics: "lock probe read failed: \(read.hexString)")
                }
                let original = read.subdata(in: (read.startIndex + 1) ..< (read.startIndex + 5))
                let write = try await tag.transceive(RawCommand(
                    bytes: Data([0x02, 0x21, probeBlock]) + original, name: "WRITE_SINGLE_BLOCK (lock probe)"
                ))
                if write.first == 0x00 {
                    throw TagError.verificationFailed(
                        diff: original,
                        diagnostics: "block \(probeBlock) accepted a write after LOCK_BLOCK: "
                            + "the tag is NOT permanently locked"
                    )
                }
            }

        case .formatVirginCC:
            // The one path that exercises `formatCC` on real silicon. Page 3 is
            // OTP, so refuse outright unless the CC really is still blank — a
            // rewrite over an existing CC can only OR bits in and corrupt it.
            guard let profile = tag.chip, let ccPage = profile.memoryLayout.ccPage else {
                throw TagError.capabilityUnsupported(
                    .formatCC, diagnostics: "chip has no Type-2 Capability Container page"
                )
            }
            guard let cc = profile.factoryCC else {
                throw TagError.capabilityUnsupported(
                    .formatCC, diagnostics: "no datasheet CC known for \(profile.id)"
                )
            }
            let offset = ccPage * profile.memoryLayout.pageSize
            let existing = try await tag.readMemory(range: offset ..< offset + 4)
            guard !Type2CC.isFormatted(existing) else {
                throw TagError.protocolError(
                    "Tag already has a Capability Container",
                    diagnostics: "page \(ccPage) = \(existing.hexString). OTP, refusing to rewrite"
                )
            }
            try await tag.writeMemory(at: offset, bytes: cc)
            // Read back: the whole point is proving the constant we ship is what
            // the silicon ends up holding.
            let written = try await tag.readMemory(range: offset ..< offset + 4)
            guard written == cc else {
                throw TagError.verificationFailed(
                    diff: written,
                    diagnostics: "CC read-back \(written.hexString) != written \(cc.hexString)"
                )
            }

        case .lockSignature:
            // `LOCK_SIG 02h` — permanently lock the originality signature.
            // Issued via raw transceive rather than a `ConnectedTag` method on
            // purpose: this file exists so the shipping tag surface never grows
            // one-way primitives.
            //
            // Opcode note: NT2L1001_NT2H1001 rev 3.0 Table 23 prints the Cmd as
            // A9h, which collides with WRITE_SIG. Table 5, the MF0UN(H)00 rev 3.1
            // equivalent, and Proxmark3 all give ACh. ACh is correct.
            let signatureBefore = try await tag.transceive(
                RawCommand(bytes: Data([0x3C, 0x00]), name: "READ_SIG (before)")
            )
            guard signatureBefore.count == 32 else {
                throw TagError.malformedResponse(
                    signatureBefore,
                    diagnostics: "READ_SIG returned \(signatureBefore.count)B, expected 32: refusing to lock a signature we can't verify"
                )
            }
            let lock = try await tag.transceive(
                RawCommand(bytes: Data([0xAC, 0x02]), name: "LOCK_SIG (permanent)")
            )
            guard lock.first == 0x0A else {
                throw TagError.protocolError(
                    "LOCK_SIG not acknowledged",
                    diagnostics: "AC 02 -> \(lock.hexString)"
                )
            }
            // Reading the signature must still work; permanent lock removes only
            // the ability to *change* it.
            //
            // **This has to run before the unlock probe below.** That probe
            // exists to be refused, and ISO/IEC 14443-3 says a Type-2 tag that
            // refuses a command returns to HALT and answers nothing more that
            // activation. Reading afterwards asks a halted tag a question: the
            // first live run (2026-08-07, NTAG 210µ) locked the signature
            // correctly, saw the refusal, then died on READ_SIG with "Tag
            // connection lost" and reported failure for an operation that had
            // entirely succeeded.
            let signatureAfter = try await tag.transceive(
                RawCommand(bytes: Data([0x3C, 0x00]), name: "READ_SIG (after)")
            )
            guard signatureAfter == signatureBefore else {
                throw TagError.verificationFailed(
                    diff: signatureAfter,
                    diagnostics: "READ_SIG changed across LOCK_SIG: \(signatureBefore.hexString) -> \(signatureAfter.hexString)"
                )
            }

            // There is no command that reports the lock state — not in the
            // command table, not in GET_VERSION, nowhere. The only proof
            // available is behavioural: a permanently locked signature must
            // refuse the unlock action. It goes last precisely because the
            // refusal ends the activation.
            let unlockAttempt = try await tag.transceive(
                RawCommand(bytes: Data([0xAC, 0x00]), name: "LOCK_SIG unlock (must be refused)")
            )
            if unlockAttempt.first == 0x0A {
                // The permanent lock didn't take AND we've just unlocked the
                // signature. Put it back to the reversible locked state so the
                // tag isn't left open to WRITE_SIG. An *accepted* command does
                // not halt the tag, so this recovery is still reachable.
                _ = try? await tag.transceive(
                    RawCommand(bytes: Data([0xAC, 0x01]), name: "LOCK_SIG re-lock (recovery)")
                )
                throw TagError.verificationFailed(
                    diff: unlockAttempt,
                    diagnostics: "AC 00 was ACKed after AC 02: signature is NOT permanently locked (clone silicon?); re-locked reversibly"
                )
            }

        case .slixPasswordLatch:
            // Handled by `runSlixPasswordLatch()` — it needs two sessions, so it
            // never reaches the single-session path.
            throw TagError.unexpected("slixPasswordLatch must run via runSlixPasswordLatch()")

        case .slixDestroy, .desfireChangeKey:
            throw TagError.capabilityUnsupported(
                .permanentLock,
                diagnostics: "\(operation.title) is a gated placeholder and was not issued."
            )
        }
    }
}
#endif
