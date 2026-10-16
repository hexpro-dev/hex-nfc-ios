#if DEBUG
import Foundation
import HexNFCKit
import HexNFCRecords
import HexNFCTestKit

// MARK: - MIFARE Ultralight C: 3DES key + AUTH0 latching

/// Proves a MIFARE Ultralight C actually **enforces** its 3DES protection on
/// real silicon, rather than merely storing the configuration bytes.
///
/// The batch suite can only prove the bytes landed: AUTH0 latches at the next
/// tag activation, and a single-tap suite cannot force the RF power-cycle that
/// makes enforcement observable. This runs the three-session Arm → Probe →
/// Remove sequence that can.
///
/// **Why this chip can have an enforcement verifier and ICODE SLIX cannot.**
/// SLIX's gate latches: "disabling" only resets it to a default and never
/// returns the tag to a truly un-gated state, which would violate the harness's
/// "never leave a tag protected" invariant. Ultralight C's key is freely
/// rewritable while AUTH0 is `30h`, so `disable` genuinely restores the factory
/// key and an un-gated tag.
///
/// **The latch that makes the session ordering non-obvious.** A newly written
/// key only becomes the authentication key at the next activation (MF0ICU2
/// rev 3.3 §7.5.7 remark). So `arm` authenticates with the key the tag powered
/// up with (the factory default), while `probe` and `disableOnce` run in fresh
/// sessions where the harness key has taken over. Getting this backwards fails
/// with a bare NAK and a misleading "wrong key" diagnostic.
@MainActor
final class UltralightCEnforcementStrategy: EnforcementStrategy {
    let factory: TagSessionFactory
    let profile: ChipProfile
    let expectedUID: Data
    private let harnessKey: UltralightCKey?
    private var savedPage: Data?
    private var lastAuthOK: Bool?

    init(factory: TagSessionFactory, profile: ChipProfile, expectedUID: Data, credentials: TagTestCredentials) {
        self.factory = factory
        self.profile = profile
        self.expectedUID = expectedUID
        harnessKey = try? UltralightCKey(cipherOrder: credentials.ultralightCKey)
    }

    static func supports(_ profile: ChipProfile) -> Bool {
        profile.capabilities.contains(.tripleDESAuth)
            && profile.memoryLayout.ndefRange != nil
    }

    var introHeadline: String {
        "Does this tag really enforce its key?"
    }

    var introBody: String {
        "The batch suite proves the 3DES key and AUTH0 were written correctly, but not that the silicon enforces them. Ultralight C only starts blocking writes after the tag is re-activated. Tap once and keep \(profile.displayName) flat on the phone; it runs the whole check for you:"
    }

    private func driver(_ tag: any ConnectedTag) -> UltralightCProtectionDriver {
        UltralightCProtectionDriver(transceive: { try await tag.transceive($0) })
    }

    private func target() throws -> (pageOffset: Int, protectFromPage: Int) {
        guard Self.supports(profile), let ndef = profile.memoryLayout.ndefRange else {
            throw TagError.capabilityUnsupported(
                .tripleDESAuth,
                diagnostics: "enforcement check needs a 3DES-capable Ultralight C profile"
            )
        }
        let page = ndef.upperBound
        return (page * profile.memoryLayout.pageSize, page)
    }

    /// Conservative: reports unprotected ONLY when a read-back confirms it.
    private func isUnprotected(_ tag: any ConnectedTag) async -> Bool {
        guard let config = try? await driver(tag).readConfiguration() else { return false }
        return config.isProtected == false
    }

    // MARK: Arm

    func arm() async throws {
        guard let harnessKey else {
            throw EnforcementFailure(message: "Harness key is malformed.", diagnostics: "expected 16 bytes")
        }
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

            // A Retry can arrive with the tag still armed from a prior run. In
            // that case the harness key is the active one; on a clean tag it is
            // the factory key. Establish which, because `enable` has to
            // authenticate with whichever the tag powered up with.
            var activeKey = UltralightCKey.factoryDefault
            if await !isUnprotected(tag) {
                _ = try? await driver(tag).disable(currentKey: harnessKey)
                activeKey = harnessKey
            }

            let (offset, protectFromPage) = try target()
            savedPage = try await tag.readMemory(range: offset ..< offset + 4)
            let spec = ProtectionSpec.ultralightC(
                key: harnessKey, protectFromPage: protectFromPage, readProtect: false
            )
            do {
                // `activeKey` is what the tag powered up holding, established a
                // few lines above. It travels as `replacing:` now that the spec
                // no longer carries a current key of its own.
                try await tag.enableProtection(spec, replacing: .ultralightC(key: activeKey))
            } catch {
                _ = try? await driver(tag).disable(currentKey: activeKey)
                await session.invalidate(error: nil)
                throw EnforcementFailure(message: "Couldn't arm protection.", diagnostics: "\(error)")
            }

            let config = try await driver(tag).readConfiguration()
            guard config.isProtected, config.protectFromPage == protectFromPage else {
                // Still in the arming session, so the key that opens the tag is
                // the one it activated with, not the one just written.
                _ = try? await driver(tag).disable(currentKey: activeKey)
                await session.invalidate(error: nil)
                throw EnforcementFailure(
                    message: "Protection didn't take (config read-back).",
                    diagnostics: "auth0=\(String(format: "%02X", config.auth0)) auth1=\(String(format: "%02X", config.auth1))"
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

    // MARK: Probe

    func probe() async -> EnforcementProbeResult {
        guard let harnessKey else {
            return .failedTerminal(EnforcementFailure(message: "Harness key is malformed.", diagnostics: ""))
        }
        let session = factory.makeSession()
        do {
            let tag = try await session.start(alert: "Test enforcement (2 of 3)")
            guard tag.uid == expectedUID else {
                await session.invalidate(error: "Different tag")
                return .failedTerminal(EnforcementFailure(
                    message: "Different tag. Re-present the SAME tag. It's still protected with the harness test key; re-run the batch to clear it.",
                    diagnostics: "expected uid=\(expectedUID.hexString) got uid=\(tag.uid.hexString)"
                ))
            }
            let (offset, _) = try target()
            let original: Data = if let saved = savedPage {
                saved
            } else {
                try await tag.readMemory(range: offset ..< offset + 4)
            }

            // One unauthenticated write to a page at/above AUTH0, writing the
            // ORIGINAL bytes back so an accepted write is a no-op. A clean NAK
            // is a non-tagLost TagError; a dropped tag is tagLost, which is
            // inconclusive rather than proof of enforcement.
            let outcome: EnforcementOutcome
            var sessionLikelyAlive = true
            do {
                try await tag.writeMemory(at: offset, bytes: original)
                outcome = .notEnforced
            } catch let e as TagError {
                if e.kind == .tagLost {
                    outcome = .inconclusive
                } else {
                    outcome = .enforced
                }
                // Either way the session is finished: a refusal returns the tag
                // to HALT for the rest of the activation, so an authenticate +
                // disable here would be two frames sent into the void and a
                // misleading "handshake did NOT complete" line in the summary.
                // Removal happens in its own session via `disableOnce`.
                //
                // This is ISO/IEC 14443-3 behaviour for **every** Type-2 chip,
                // not something specific to Ultralight C. An earlier version of
                // this comment said the Type-2 strategy could keep going after a
                // clean NAK; it could not, and a live NTAG216 proved it on
                // 2026-08-07. `Type2EnforcementStrategy` now does the same thing.
                sessionLikelyAlive = false
            }

            if sessionLikelyAlive {
                do {
                    // Fresh session, so the harness key has latched and is now
                    // the authentication key.
                    lastAuthOK = await (try? driver(tag).authenticate(key: harnessKey)) != nil
                    try await driver(tag).disable(currentKey: harnessKey)
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

    // MARK: Remove

    func disableOnce() async -> EnforcementDisableResult {
        guard let harnessKey else {
            return .failed("Harness key is malformed.", "expected 16 bytes")
        }
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

            // Run `disable` even when the tag already reads as unprotected.
            //
            // An arm that failed between the key write and the AUTH0 write
            // leaves a tag that is not gated but no longer holds the factory
            // key. Nothing is protected, so the batch's invariant is satisfied,
            // but the tag would silently stop matching a factory-key
            // expectation later. `disable` also restores the key, so running it
            // is what actually returns the tag to delivery state.
            //
            // **One attempt only.** A failed authentication is a refusal, and a
            // refusal halts the tag for the rest of the activation, so a second
            // key tried in the same session talks to a tag that has stopped
            // listening. This method owns its session and the flow model calls
            // it again on a fresh one, which is where a retry belongs.
            let error: String
            do {
                try await driver(tag).disable(currentKey: harnessKey)
                let clean = await isUnprotected(tag)
                await session.invalidate(error: nil)
                return .done(clean)
            } catch let thrown as TagError {
                error = "\(String(localized: thrown.userMessage)): \(thrown.diagnostics)"
            }
            // The disable failed, so the tag is halted and cannot be re-probed
            // in this session. Report against what we knew before the attempt.
            await session.invalidate(error: nil)
            return .failed(
                "Couldn't remove protection: the tag may still be protected. Recover by re-running the batch (its cleanup disables protection).",
                error
            )
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
                    "✓ Enforced: after re-activation the unauthenticated write was REJECTED. 3DES protection works on this tag."
                )

        case .notEnforced:
            lines
                .append(
                    "⚠︎ NOT enforced: the unauthenticated write was ACCEPTED even after a fresh activation. This tag doesn't enforce AUTH0 (likely a clone / non-genuine Ultralight C); its protection can't be trusted."
                )

        case .inconclusive:
            lines
                .append(
                    "• Inconclusive: the tag stopped responding during the unauthenticated write. That's either weak coupling OR the enforcement refusal itself (some iOS versions report a refused write as a dropped tag), and a single probe can't tell them apart. If it's consistent across runs, the tag most likely IS enforcing."
                )

        case .skipped:
            lines.append("• Enforcement not tested (protection removed).")
        }
        if let lastAuthOK {
            lines.append(lastAuthOK
                ? "The 3DES handshake completed with the harness key."
                : "The 3DES handshake did NOT complete with the harness key.")
        }
        lines
            .append(clean ? "Protection removed and factory key restored: tag left clean." :
                "Tag still reports protection after disable: re-run the batch to clear.")
        lines.append("UID \(expectedUID.hexString)")
        return lines.joined(separator: "\n")
    }
}
#endif
