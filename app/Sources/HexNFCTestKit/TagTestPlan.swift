import Foundation
import HexNFCKit
import HexNFCRecords

/// A capability-gated, ordered suite for one chip, plus a factory-blank cleanup
/// that always runs. Built once by `plan(for:)` and consumed identically by the
/// live harness and the simulator XCTest.
public struct TagTestPlan: Sendable {
    public let profile: ChipProfile
    public let credentials: TagTestCredentials
    /// Non-destructive steps, ordered read-only → reversible.
    public let steps: [TagTestStep]
    /// Best-effort teardown to a reusable blank state.
    public let cleanup: [TagTestStep]

    public init(
        profile: ChipProfile,
        credentials: TagTestCredentials = .init(),
        steps: [TagTestStep],
        cleanup: [TagTestStep]
    ) {
        precondition(
            zip(steps, steps.dropFirst()).allSatisfy { $0.tap <= $1.tap },
            "Plan steps must be ordered by tap: the runner opens taps in order and never goes back."
        )
        precondition(
            zip(steps, steps.dropFirst()).allSatisfy { !($0.endsActivation && $0.tap == $1.tap) },
            "A step marked endsActivation must be last in its tap. Its final frame may NAK, and a "
                + "NAK returns a Type-2 chip to HALT, so everything after it in that activation "
                + "fails with a transport error that reads as a hardware fault."
        )
        self.profile = profile
        self.credentials = credentials
        self.steps = steps
        self.cleanup = cleanup
    }

    /// The activation cleanup runs in.
    ///
    /// One past the last suite tap whenever that tap ends its activation,
    /// because cleanup would otherwise run against a chip that has already
    /// halted and answers nothing. Cleanup steps carry no tap of their own; the
    /// runner opens this one and runs them all there.
    public var cleanupTap: Int {
        Self.cleanupTap(after: steps)
    }

    /// `cleanupTap` for an arbitrary step list. The runner passes the steps that
    /// survived the safety filter, so a read-only pass plans the taps it will
    /// actually take rather than the ones the full plan declares.
    public static func cleanupTap(after steps: [TagTestStep]) -> Int {
        let last = steps.map(\.tap).max() ?? 0
        return steps.contains { $0.tap == last && $0.endsActivation } ? last + 1 : last
    }

    /// The single entry point both consumers call — family/variant specialised.
    public static func plan(for profile: ChipProfile, credentials: TagTestCredentials = .init()) -> TagTestPlan {
        switch profile.family {
        case .type2(let variant):
            switch variant {
            case .emV10, .emV11, .emV16:
                emPlan(profile, credentials)

            // Explicit, never the `default:` arm below. `type2Plan` opens with
            // GET_VERSION, which this chip has no command for; the NAK HALTs the
            // tag and every following step fails with a transport error, which
            // reads as a hardware fault and withholds the clean pass.
            case .mifareUltralightC:
                ultralightCPlan(profile, credentials)

            default:
                type2Plan(profile, credentials)
            }

        case .type4(let variant):
            switch variant {
            case .ntag424DNA:
                ntag424Plan(profile, credentials)

            case .ePassport:
                ePassportPlan(profile, credentials)

            default:
                desfirePlan(profile, credentials)
            }

        case .type5:
            iso15693Plan(profile, credentials)

        case .felica:
            felicaPlan(profile, credentials)

        case .unknown:
            TagTestPlan(profile: profile, credentials: credentials, steps: [], cleanup: [])
        }
    }
}

// MARK: - Shared helpers

/// Build a Type-2 / MIFARE raw command. On live these bytes are sent verbatim
/// via `sendMiFareCommand`; on the simulator they hit `handle(command:)` — the
/// two agree byte-for-byte, which is what makes the anti-drift check meaningful.
func mifareCommand(_ bytes: [UInt8], _ name: String) -> RawCommand {
    RawCommand(bytes: Data(bytes), name: name)
}

/// Read one Type-2 page (4 bytes) via a raw `READ` (`0x30`), returning only the
/// addressed page (the command returns 4 pages / 16 bytes).
func readType2Page(_ tag: any ConnectedTag, _ page: Int) async throws -> Data {
    let resp = try await tag.transceive(mifareCommand([0x30, UInt8(page & 0xFF)], "READ p\(page)"))
    guard resp.count >= 4 else {
        throw TagError.malformedResponse(resp, diagnostics: "READ p\(page) short response")
    }
    return resp.prefix(4)
}

enum CleanupSteps {
    /// Factory-blank teardown for Type-2 (NTAG / UL) and EM chips. Order is
    /// load-bearing: unprotect FIRST (removes the write-gate) before touching
    /// data, so even a mid-cleanup failure never strands the tag protected.
    static func type2(_ profile: ChipProfile) -> [TagTestStep] {
        var steps: [TagTestStep] = []

        if profile.capabilities.contains(.passwordAuth), profile.type2ConfigLayout != nil {
            steps
                .append(TagTestStep("cleanup.unprotect", "Remove any password protection",
                                    safety: .reversibleWrite)
                { tag, ctx in
                    // A reading that did not happen is not a reading. This used to
                    // be `?? false`, which turned a failed read into "the tag says
                    // it is open" and then fed that into the last-known-state
                    // fallback the runner leans on when its own probe comes back
                    // empty. The one moment that matters, a cleanup tap whose first
                    // read is refused on a tag that really is gated, is exactly the
                    // moment it would have reported a clean pass.
                    let reading = await (try? tag.readProtectionState()) ?? nil
                    if let reading {
                        recordProtectionReading(reading.passwordProtect, into: &ctx)
                    }
                    // `armedProtection` is the corroborant when the read says
                    // nothing: this suite armed the protection itself, so it knows
                    // what it left behind even when the tag will not say.
                    let believedProtected = reading?.passwordProtect ?? (ctx.armedProtection != nil)
                    guard believedProtected || ctx.armedProtection != nil else {
                        return .pass("already unprotected")
                    }
                    let credential = ctx.armedProtection?.credential
                        ?? .type2(password: ctx.credentials.type2Password, pack: ctx.credentials.type2Pack)
                    try await tag.disableProtection(using: credential)
                    ctx.armedProtection = nil
                    // Re-record, or a halt anywhere after this point makes the
                    // runner fall back to the PRE-removal reading and deny a clean
                    // pass on a tag that is fine. `disableProtection` proves the
                    // gate open by reading CFG0 back, so this is a read-back's
                    // verdict rather than an ACK's.
                    recordProtectionReading(false, into: &ctx)
                    return .pass("protection removed")
                    })
        }

        if profile.capabilities.contains(.ndefWrite) {
            steps.append(TagTestStep(
                "cleanup.eraseNDEF",
                "Erase NDEF to blank",
                safety: .reversibleWrite,
                requires: .ndefWrite
            ) { tag, _ in
                try await tag.writeNDEF([])
                return .pass("NDEF erased")
            })
        }

        // NOTE: cleanup deliberately does NOT rewrite the Capability Container.
        // The Type-2 CC is one-time-programmable (writes OR bits, never clear), so
        // an identified tag's factory CC is already correct and immutable — a
        // rewrite could only corrupt it. (Re-writing CC belongs to the app's
        // explicit `format` op, on a chip whose CC is genuinely blank.)

        steps.append(TagTestStep("cleanup.verify", "Verify blank + unprotected", safety: .readOnly) { tag, ctx in
            var checks: [TagStepCheck] = []
            if let state = try? await tag.readProtectionState() {
                checks.append(.require("unprotected", state.passwordProtect == false))
                recordProtectionReading(state.passwordProtect, into: &ctx)
            }
            if tag.capabilities.contains(.ndefRead), let msg = try? await tag.readNDEF() {
                checks.append(.require("blank NDEF", NDEFCodec.isEmptyMessage(msg)))
            }
            return checks.isEmpty ? .pass("nothing to verify") : .all(checks)
        })

        return steps
    }
}

/// Stash what the tag just said about its password gate, so the runner has a
/// reading taken while the chip was still answering.
///
/// Call it with a state read **before** anything that could halt the chip. The
/// runner's own post-cleanup probe is a `try?` and cannot tell a halted chip
/// from an unprotected one, so without this the one path that matters (a
/// refusal, late in cleanup, on a tag that is still gated) reports "unprotected"
/// on the strength of a read that never happened.
func recordProtectionReading(_ isProtected: Bool, into ctx: inout TagTestContext) {
    ctx.scratch[TagTestContext.lastKnownProtectionKey] = Data([isProtected ? 0x01 : 0x00])
}

/// Restore an NDEF message captured in `ctx.scratch[key]`, decoding it back into
/// records (empty message → erase). Best-effort; used by reversible NDEF steps.
func restoreNDEF(_ tag: any ConnectedTag, from key: String, ctx: TagTestContext) async throws {
    guard let original = ctx.scratch[key] else { return }
    if NDEFCodec.isEmptyMessage(original) {
        try await tag.writeNDEF([])
    } else if let records = try? NDEFCodec.decode(original) {
        try await tag.writeNDEF(records)
    }
}
