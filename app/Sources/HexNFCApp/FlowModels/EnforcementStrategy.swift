#if DEBUG
import Foundation
import HexNFCKit
import HexNFCRecords
import HexNFCTestKit

// MARK: - Shared enforcement types

/// Classified result of the single unauthenticated write in the enforcement probe.
public enum EnforcementOutcome: Sendable { case enforced, notEnforced, inconclusive, skipped }

/// A user-facing failure raised by a strategy stage (message + copyable diagnostics).
struct EnforcementFailure: Error { let message: String
    let diagnostics: String
}

/// Outcome of the probe stage: finished-in-session (clone path disabled here),
/// needs a dedicated remove session, or a terminal failure.
enum EnforcementProbeResult {
    case doneInSession(String)
    case needsCleanup(EnforcementOutcome)
    case failedTerminal(EnforcementFailure)
}

/// Outcome of a single disable attempt: done (with whether it verified clean) or failed.
enum EnforcementDisableResult { case done(Bool)
    case failed(String, String)
}

/// The chip-specific half of the enforcement check: how to *arm* protection, *probe*
/// enforcement with one unauthenticated write, and *guarantee removal*. The generic
/// arm→probe→remove coordination, retries, settle timings and the 202-teardown race
/// live in `EnforcementCheckFlowModel`; only these primitives differ per family.
///
/// Each method owns its own session (a real enforcement refusal tears the CoreNFC
/// session down, so cleanup can't share the probe's session).
@MainActor
protocol EnforcementStrategy: AnyObject {
    static func supports(_ profile: ChipProfile) -> Bool
    var expectedUID: Data { get }
    var introHeadline: String { get }
    var introBody: String { get }
    /// Arm protection in a fresh session and confirm it committed (read-back).
    /// Throws `EnforcementFailure` on any failure (already best-effort cleaned up).
    func arm() async throws
    /// One fresh-session probe: a single unauthenticated write, classified. If the
    /// session survives, it authenticates + disables here (no third session needed).
    func probe() async -> EnforcementProbeResult
    /// Remove protection in a fresh session; returns whether the tag verified clean.
    func disableOnce() async -> EnforcementDisableResult
    /// Result copy for a completed run.
    func summary(outcome: EnforcementOutcome, clean: Bool) -> String
}

// MARK: - Type-2 (NTAG21x): AUTH0 / PWD latching

/// Proves a Type-2 tag ACTUALLY enforces password protection on real silicon —
/// genuine NTAG21x only starts enforcing AUTH0 at the next tag activation (an RF
/// power-cycle), and clone/aftermarket Type-2 tags often never enforce it at all.
@MainActor
final class Type2EnforcementStrategy: EnforcementStrategy {
    let factory: TagSessionFactory
    let profile: ChipProfile
    let expectedUID: Data
    private let pwd: Data
    private let pack: Data
    private var savedPage: Data?
    private var lastPackOK: Bool?

    init(factory: TagSessionFactory, profile: ChipProfile, expectedUID: Data, credentials: TagTestCredentials) {
        self.factory = factory
        self.profile = profile
        self.expectedUID = expectedUID
        pwd = credentials.type2Password
        pack = credentials.type2Pack
    }

    static func supports(_ profile: ChipProfile) -> Bool {
        profile.capabilities.contains(.passwordAuth)
            && profile.type2ConfigLayout != nil
            && profile.memoryLayout.ndefRange != nil
    }

    var introHeadline: String {
        "Does this tag really enforce protection?"
    }

    var introBody: String {
        "The batch suite proves protection was written correctly, but not that the silicon enforces it. Genuine NTAG21x only starts blocking writes after the tag is re-activated, and clone tags often never enforce it. Tap once and keep \(profile.displayName) flat on the phone; it runs the whole check for you:"
    }

    func arm() async throws {
        let session = factory.makeSession()
        do {
            let tag = try await session.start(alert: "Arm protection (1 of 3)")
            guard tag.uid == expectedUID else {
                await session.invalidate(error: "Different tag")
                throw EnforcementFailure(
                    message: "This is a different tag than the one that passed the suite.",
                    diagnostics: "expected uid=\(expectedUID.hexString) got uid=\(tag.uid.hexString)"
                )
            }
            // Clean slate: a Retry can arrive with the tag still armed from a prior
            // run. Clear it first (our test credential) so the fresh config writes
            // aren't blocked by the existing AUTH0 gating the PWD/config pages.
            if await !isUnprotected(tag) {
                _ = try? await tag.disableProtection(using: .type2(password: pwd, pack: pack))
            }
            let (offset, protectFromPage) = try type2Target()
            savedPage = try await tag.readMemory(range: offset ..< offset + 4)
            let spec = ProtectionSpec.type2(
                password: pwd, pack: pack,
                protectFromPage: protectFromPage, readProtect: false, authLimit: 0
            )
            do {
                try await tag.enableProtection(spec)
            } catch {
                _ = try? await tag.disableProtection(using: .type2(password: pwd, pack: pack))
                await session.invalidate(error: nil)
                throw EnforcementFailure(message: "Couldn't arm protection.", diagnostics: "\(error)")
            }
            let state = try await tag.readProtectionState()
            guard let state, state.passwordProtect, state.protectFromPage == protectFromPage else {
                _ = try? await tag.disableProtection(using: .type2(password: pwd, pack: pack))
                await session.invalidate(error: nil)
                throw EnforcementFailure(
                    message: "Protection didn't take (config read-back).",
                    diagnostics: "state=\(String(describing: state))"
                )
            }
            await session.invalidate(error: nil)
        } catch let failure as EnforcementFailure {
            throw failure
        } catch let error as TagError {
            await session.invalidate(error: nil)
            throw EnforcementFailure(message: String(localized: error.userMessage), diagnostics: error.diagnostics)
        } catch {
            await session.invalidate(error: nil)
            throw EnforcementFailure(message: "\(error)", diagnostics: "")
        }
    }

    func probe() async -> EnforcementProbeResult {
        let session = factory.makeSession()
        do {
            let tag = try await session.start(alert: "Test enforcement (2 of 3)")
            guard tag.uid == expectedUID else {
                await session.invalidate(error: "Different tag")
                return .failedTerminal(EnforcementFailure(
                    message: "Different tag. Re-present the SAME tag. It's still protected with the harness test password; re-run the batch to clear it.",
                    diagnostics: "expected uid=\(expectedUID.hexString) got uid=\(tag.uid.hexString)"
                ))
            }
            let (offset, _) = try type2Target()
            let original: Data = if let saved = savedPage {
                saved
            } else {
                try await tag.readMemory(range: offset ..< offset + 4)
            }

            // One unauthenticated write to a page at/above AUTH0. Original bytes, so
            // an accepted write is a no-op. A clean NAK is a non-tagLost TagError; a
            // dropped tag is tagLost (inconclusive, NOT enforcement).
            //
            // **Either refusal ends the activation.** ISO/IEC 14443-3: a Type-2
            // tag that refuses a command returns to HALT and answers nothing
            // more until the next anticollision. This once distinguished the two
            // branches, keeping the session alive after a clean NAK on the
            // theory that only a dropped tag was terminal. A live NTAG216 run
            // (2026-08-07) disproved it: the refused write was followed by
            // `PWD_AUTH` twice, both "Tag connection lost", and `lastPackOK`
            // was left false so the summary would have claimed the password
            // handshake failed on a tag that was enforcing correctly.
            //
            // Only an *accepted* write leaves the tag listening, which is the
            // `notEnforced` branch.
            let outcome: EnforcementOutcome
            var sessionLikelyAlive = false
            do {
                try await tag.writeMemory(at: offset, bytes: original)
                outcome = .notEnforced
                sessionLikelyAlive = true
            } catch let e as TagError {
                outcome = e.kind == .tagLost ? .inconclusive : .enforced
            }

            if sessionLikelyAlive {
                do {
                    let gotPack = try? await tag.authenticate(password: pwd)
                    lastPackOK = gotPack == pack
                    try await tag.disableProtection(using: .type2(password: pwd, pack: pack))
                    let clean = await isUnprotected(tag)
                    await session.invalidate(error: nil)
                    if clean {
                        return .doneInSession(summary(outcome: outcome, clean: true))
                    }
                    return .needsCleanup(outcome)
                } catch {
                    await session.invalidate(error: nil)
                    return .needsCleanup(outcome)
                }
            }
            await session.invalidate(error: nil)
            return .needsCleanup(outcome)
        } catch {
            await session.invalidate(error: nil)
            return .needsCleanup(.inconclusive)
        }
    }

    func disableOnce() async -> EnforcementDisableResult {
        let session = factory.makeSession()
        do {
            let tag = try await session.start(alert: "Remove protection")
            guard tag.uid == expectedUID else {
                await session.invalidate(error: "Different tag")
                return .failed(
                    "Different tag. Present the armed tag to clear it. Re-running the batch also clears it.",
                    "expected uid=\(expectedUID.hexString) got uid=\(tag.uid.hexString)"
                )
            }
            if await isUnprotected(tag) {
                await session.invalidate(error: nil)
                return .done(true) // nothing to remove
            }
            try await tag.disableProtection(using: .type2(password: pwd, pack: pack))
            let clean = await isUnprotected(tag)
            await session.invalidate(error: nil)
            return .done(clean)
        } catch let error as TagError {
            await session.invalidate(error: nil)
            return .failed(
                "Couldn't remove protection: the tag may still be protected. Recover by re-running the batch (its cleanup disables protection).",
                "\(String(localized: error.userMessage)): \(error.diagnostics)"
            )
        } catch {
            await session.invalidate(error: nil)
            return .failed("\(error). Re-run the batch to clear protection.", "")
        }
    }

    func summary(outcome: EnforcementOutcome, clean: Bool) -> String {
        var lines: [String] = []
        switch outcome {
        case .enforced:
            lines
                .append(
                    "✓ Enforced: after re-activation the unauthenticated write was REJECTED. Password protection works on this tag."
                )

        case .notEnforced:
            lines
                .append(
                    "⚠︎ NOT enforced: the unauthenticated write was ACCEPTED even after a fresh activation. This tag doesn't enforce AUTH0 (likely a clone / non-genuine Type-2); its protection can't be trusted."
                )

        case .inconclusive:
            lines
                .append(
                    "• Inconclusive: the tag stopped responding during the unauthenticated write. That's either weak coupling OR the enforcement refusal itself (some iOS versions report a refused write as a dropped tag), and a single probe can't tell them apart. If it's consistent across runs, the tag most likely IS enforcing."
                )

        case .skipped:
            lines.append("• Enforcement not tested (protection removed).")
        }
        if let lastPackOK {
            lines
                .append(lastPackOK ? "PWD_AUTH returned the expected PACK." :
                    "PWD_AUTH did NOT return the expected PACK.")
        }
        lines
            .append(clean ? "Protection removed: tag left clean." :
                "Tag still reports protection after disable: re-run the batch to clear.")
        lines.append("UID \(expectedUID.hexString)")
        return lines.joined(separator: "\n")
    }

    // MARK: Helpers

    private func type2Target() throws -> (pageOffset: Int, protectFromPage: Int) {
        guard Self.supports(profile), let ndef = profile.memoryLayout.ndefRange else {
            throw TagError.capabilityUnsupported(
                .passwordAuth,
                diagnostics: "enforcement check needs a password-capable Type-2 profile"
            )
        }
        let protectFromPage = ndef.upperBound
        return (protectFromPage * profile.memoryLayout.pageSize, protectFromPage)
    }

    /// Conservative: reports unprotected ONLY when a read-back actually confirms it.
    private func isUnprotected(_ tag: any ConnectedTag) async -> Bool {
        guard let state = try? await tag.readProtectionState() else { return false }
        return state.passwordProtect == false
    }
}

// MARK: - Type-4 (NTAG424 DNA): AES EV2 file gating

/// Proves an NTAG424 DNA actually ENFORCES a programmed protection on real silicon.
/// The batch suite only authenticates with the factory (zero) key; it never proves
/// that gating the NDEF file behind a *non-factory* key makes an unauthenticated
/// write fail. This arms real protection (`ChangeFileSettings` gate + `ChangeKey`
/// to a fixed test key), re-taps, and checks that a plain NDEF write is refused.
///
/// Fully recoverable: `disableProtection` with the same fixed test key restores the
/// factory-zero key and free access. If a run is interrupted mid-way, the escape
/// "Disable tag" button (or a Retry) re-runs the removal with that key.
@MainActor
final class Type4EnforcementStrategy: EnforcementStrategy {
    let factory: TagSessionFactory
    let profile: ChipProfile
    let expectedUID: Data
    private let key: Data

    init(factory: TagSessionFactory, profile: ChipProfile, expectedUID: Data, credentials: TagTestCredentials) {
        self.factory = factory
        self.profile = profile
        self.expectedUID = expectedUID
        key = credentials.type4EnforcementKey
    }

    static func supports(_ profile: ChipProfile) -> Bool {
        if case .type4(.ntag424DNA) = profile.family {
            return true
        }
        return false
    }

    /// A DESFire-wrapped response ending in `91 00`.
    static func isSuccess(_ response: Data) -> Bool {
        Array(response.suffix(2)) == [0x91, 0x00]
    }

    /// Status words that mean "this command did not run", as opposed to "the
    /// file's access rights refused it".
    ///
    /// Treating these as enforcement is how a verifier manufactures a pass:
    /// both are live-observed on healthy, *unprotected* NTAG424s.
    /// - `91 CA` COMMAND_ABORTED — a `90 60` GET_VERSION chain left undrained.
    /// - `91 7E` LENGTH_ERROR — malformed/mis-sized command data.
    static func isNonProtectionFailure(_ sw: [UInt8]) -> Bool {
        sw == [0x91, 0xCA] || sw == [0x91, 0x7E]
    }

    var introHeadline: String {
        "Does this tag really enforce protection?"
    }

    var introBody: String {
        "The batch suite authenticates with the factory key, but doesn't prove a *programmed* protection is enforced. This gates the NDEF file behind a fixed test AES key, then checks, after a fresh activation, that an unauthenticated write is actually refused. Tap once and keep \(profile.displayName) flat on the phone; it runs the whole check and always removes protection at the end:"
    }

    func arm() async throws {
        let session = factory.makeSession()
        do {
            let tag = try await session.start(alert: "Arm protection (1 of 3)")
            guard tag.uid == expectedUID else {
                await session.invalidate(error: "Different tag")
                throw EnforcementFailure(
                    message: "This is a different tag than the one that passed the suite.",
                    diagnostics: "expected uid=\(expectedUID.hexString) got uid=\(tag.uid.hexString)"
                )
            }
            // Clean slate: a Retry can arrive with the file still gated behind our
            // test key from a prior run — clear it before re-arming.
            if await !isUnprotected(tag) {
                _ = try? await tag.disableProtection(using: .type4(aesKey: key, keySlot: 0))
            }
            do {
                try await tag.enableProtection(.type4(aesKey: key, keySlot: 0, readProtect: false))
            } catch {
                _ = try? await tag.disableProtection(using: .type4(aesKey: key, keySlot: 0))
                await session.invalidate(error: nil)
                throw EnforcementFailure(
                    message: "Couldn't arm protection. If the tag was already protected with a non-harness key, remove it first.",
                    diagnostics: "\(error)"
                )
            }
            // Best-effort read-back. `ChangeKey` runs last and ends the EV2 session,
            // so a plain GetFileSettings usually works here — but if the session
            // lingers it can answer 91 7E ("needs MAC"). So a throwing/nil read-back
            // does NOT fail the arm (the probe is the real proof of enforcement);
            // only a *definitive* "unprotected" read means the gate truly didn't take.
            if let state = try? await tag.readProtectionState(), state.passwordProtect == false {
                _ = try? await tag.disableProtection(using: .type4(aesKey: key, keySlot: 0))
                await session.invalidate(error: nil)
                throw EnforcementFailure(
                    message: "Protection didn't take: the file-settings read-back reports the NDEF file is still unprotected.",
                    diagnostics: "readProtectionState.passwordProtect==false after enableProtection; uid=\(expectedUID.hexString)"
                )
            }
            await session.invalidate(error: nil)
        } catch let failure as EnforcementFailure {
            throw failure
        } catch let error as TagError {
            await session.invalidate(error: nil)
            throw EnforcementFailure(message: String(localized: error.userMessage), diagnostics: error.diagnostics)
        } catch {
            await session.invalidate(error: nil)
            throw EnforcementFailure(message: "\(error)", diagnostics: "")
        }
    }

    func probe() async -> EnforcementProbeResult {
        let session = factory.makeSession()
        do {
            let tag = try await session.start(alert: "Test enforcement (2 of 3)")
            guard tag.uid == expectedUID else {
                await session.invalidate(error: "Different tag")
                return .failedTerminal(EnforcementFailure(
                    message: "Different tag. Re-present the SAME tag. It's still gated behind the harness test key; use Disable to clear it.",
                    diagnostics: "expected uid=\(expectedUID.hexString) got uid=\(tag.uid.hexString)"
                ))
            }
            // Two-step probe. Step 1 SELECTs the NDEF app — if we can't even reach
            // the tag here, it's a coupling/timing problem (inconclusive), not a
            // result. Step 2 does ONE unauthenticated raw plain WriteData (90 8D) to
            // the key-gated file and inspects the status word: 91 00 = accepted (not
            // enforced); an error SW (91 9D PERMISSION_DENIED / 91 AE / …) = refused
            // (enforced). A raw refusal leaves the session ALIVE (unlike high-level
            // writeNDEF). If instead the tag DROPS on the write (some silicon halts
            // on a permission error rather than returning a status), that's still the
            // write being refused — enforced — because the SELECT a moment earlier
            // proved the tag was responding. Any lasting write is erased below.
            let outcome: EnforcementOutcome
            var sessionLikelyAlive = true
            do {
                // ⚠️ The SELECT's status word is load-bearing and used to be
                // discarded. Native file commands are refused at PICC level
                // with `91 9D` until the NDEF app is selected (live-observed
                // 2026-07-01), so a SELECT that quietly failed makes the probe
                // below draw `91 9D` from *any* tag — including one that does
                // not enforce at all — and the old code read that as ENFORCED.
                // That is a false all-clear on a security check, the one
                // direction this verifier must never fail in.
                let selectResponse = try await tag.transceive(RawCommand(
                    bytes: Data([0x00, 0xA4, 0x04, 0x00, 0x07, 0xD2, 0x76, 0x00, 0x00, 0x85, 0x01, 0x01, 0x00]),
                    name: "SELECT NDEF app"
                ))
                guard Self.isSuccess(selectResponse) else {
                    // Could not select: nothing after this can be attributed to
                    // protection. Not a verdict.
                    return .needsCleanup(.inconclusive)
                }
                let write = Data([0x90, 0x8D, 0x00, 0x00, 0x08, 0x02, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00])
                do {
                    let resp = try await tag.transceive(RawCommand(bytes: write, name: "WriteData (unauth probe)"))
                    let sw = Array(resp.suffix(2))
                    if sw == [0x91, 0x00] {
                        outcome = .notEnforced
                    } else if Self.isNonProtectionFailure(sw) {
                        // `91 CA` (COMMAND_ABORTED, an undrained GET_VERSION
                        // chain) and `91 7E` (LENGTH_ERROR) are refusals that
                        // say nothing about the file's access rights. Counting
                        // them as enforcement would manufacture a pass.
                        outcome = .inconclusive
                    } else {
                        outcome = .enforced
                    }
                } catch let e as TagError {
                    outcome = .enforced
                    sessionLikelyAlive = (e.kind != .tagLost)
                }
            } catch {
                outcome = .inconclusive
                sessionLikelyAlive = false
            }

            if sessionLikelyAlive {
                do {
                    try await tag.disableProtection(using: .type4(aesKey: key, keySlot: 0))
                    // Tidy: with protection removed, erase the probe record (best-effort).
                    try? await tag.writeNDEF([])
                    let clean = await isUnprotected(tag)
                    await session.invalidate(error: nil)
                    if clean {
                        return .doneInSession(summary(outcome: outcome, clean: true))
                    }
                    return .needsCleanup(outcome)
                } catch {
                    await session.invalidate(error: nil)
                    return .needsCleanup(outcome)
                }
            }
            await session.invalidate(error: nil)
            return .needsCleanup(outcome)
        } catch {
            await session.invalidate(error: nil)
            return .needsCleanup(.inconclusive)
        }
    }

    func disableOnce() async -> EnforcementDisableResult {
        let session = factory.makeSession()
        do {
            let tag = try await session.start(alert: "Remove protection")
            guard tag.uid == expectedUID else {
                await session.invalidate(error: "Different tag")
                return .failed(
                    "Different tag. Present the armed tag to clear it.",
                    "expected uid=\(expectedUID.hexString) got uid=\(tag.uid.hexString)"
                )
            }
            if await isUnprotected(tag) {
                await session.invalidate(error: nil)
                return .done(true)
            }
            try await tag.disableProtection(using: .type4(aesKey: key, keySlot: 0))
            try? await tag.writeNDEF([])
            let clean = await isUnprotected(tag)
            await session.invalidate(error: nil)
            return .done(clean)
        } catch let error as TagError {
            await session.invalidate(error: nil)
            return .failed(
                "Couldn't remove protection: the NDEF file may still be gated behind the harness test key. Re-run the enforcement check and tap Disable.",
                "\(String(localized: error.userMessage)): \(error.diagnostics)"
            )
        } catch {
            await session.invalidate(error: nil)
            return .failed("\(error). Re-run the enforcement check and tap Disable.", "")
        }
    }

    func summary(outcome: EnforcementOutcome, clean: Bool) -> String {
        var lines: [String] = []
        switch outcome {
        case .enforced:
            lines
                .append(
                    "✓ Enforced: the unauthenticated write to the key-gated NDEF file was REJECTED. AES EV2 file protection works on this tag."
                )

        case .notEnforced:
            lines
                .append(
                    "⚠︎ NOT enforced: the unauthenticated write was ACCEPTED even though the NDEF file was gated behind a key. This tag doesn't enforce ChangeFileSettings access rights; its protection can't be trusted."
                )

        case .inconclusive:
            lines
                .append(
                    "• Inconclusive: couldn't reach the tag to run the write probe (it dropped before the write completed). That's a coupling/timing issue, not a verdict, so keep the tag flat on the phone and run it again."
                )

        case .skipped:
            lines.append("• Enforcement not tested (protection removed).")
        }
        lines
            .append(clean ? "Protection removed: key reset to factory zero, tag left clean." :
                "Tag still reports protection after disable: re-run and tap Disable to clear.")
        lines.append("UID \(expectedUID.hexString)")
        return lines.joined(separator: "\n")
    }

    /// Conservative: reports unprotected ONLY when a read-back actually confirms it.
    private func isUnprotected(_ tag: any ConnectedTag) async -> Bool {
        guard let state = try? await tag.readProtectionState() else { return false }
        return state.passwordProtect == false
    }
}
#endif
