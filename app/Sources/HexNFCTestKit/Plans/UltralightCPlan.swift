import Foundation
import HexNFCKit
import HexNFCRecords

// MARK: - MIFARE Ultralight C (MF0ICU2)

/// Its own plan, reached by an **explicit** `case` in `TagTestPlan.plan(for:)`
/// rather than the Type-2 `default:` arm.
///
/// Falling through to `type2Plan` would open with `t2.identify`, which sends
/// `GET_VERSION`. This chip has no such command (rev 3.3 Table 14), so it NAKs,
/// and a NAK returns a Type-2 tag to HALT for the rest of the activation. Every
/// following step would then fail with a transport error, the suite would end
/// red, and the clean pass the gated irreversible ops depend on would be
/// withheld. It would look exactly like a hardware fault.
func ultralightCPlan(_ profile: ChipProfile, _ credentials: TagTestCredentials) -> TagTestPlan {
    var steps: [TagTestStep] = []

    /// The harness key, built once. A malformed key is a programming error in
    /// `TagTestCredentials`, not a tag fault, so the steps that need it report
    /// that plainly rather than throwing a protocol error at a tag.
    @Sendable func harnessKey(_ ctx: TagTestContext) -> UltralightCKey? {
        try? UltralightCKey(cipherOrder: ctx.credentials.ultralightCKey)
    }

    @Sendable func driver(_ tag: any ConnectedTag) -> UltralightCProtectionDriver {
        UltralightCProtectionDriver(transceive: { try await tag.transceive($0) })
    }

    // The key the card is currently authenticating against, which is **not**
    // necessarily the key stored in its pages.
    //
    // A newly written key only becomes the authentication key at the next
    // activation (rev 3.3 §7.5.7 remark), so within one session the active key
    // is whatever the tag powered up with. That is the factory default unless
    // pre-flight had to remove protection left by an earlier run, in which case
    // it is the harness key. Tracking it explicitly beats re-probing: probing
    // costs round trips and reads like credential guessing, and the answer is
    // fully determined by what this session has already done.
    let activeKeyScratch = "ulc.activeKey"
    @Sendable func activeKey(_ ctx: TagTestContext) -> UltralightCKey {
        if let bytes = ctx.scratch[activeKeyScratch],
           let key = try? UltralightCKey(cipherOrder: bytes)
        {
            return key
        }
        return .factoryDefault
    }

    // 0. Pre-flight. A tag can arrive protected from an aborted earlier run.
    //    Clear it with the harness key so a leftover gate doesn't fail the
    //    steps below, and say so clearly if it is protected with some other key
    //    (which we cannot recover from, and must not pretend to).
    steps.append(TagTestStep("ulc.preflight", "Pre-flight: ensure unprotected", safety: .reversibleWrite) { tag, ctx in
        let state = try? await driver(tag).readConfiguration()
        guard let state, state.isProtected else { return .pass("not protected on arrival") }
        guard let key = harnessKey(ctx) else { return .require("harness key is malformed", false) }
        do {
            // A tag left gated by an earlier run activated with the harness key,
            // so that is what opens it now, and it stays the active key for the
            // rest of this session even though `disable` writes the factory key
            // back into the pages.
            try await tag.disableProtection(using: .ultralightC(key: key))
            ctx.scratch[activeKeyScratch] = key.cipherOrder
        } catch {
            return .require(
                "cleared prior protection: arrived protected with a key this harness does not "
                    + "hold; there is no factory reset for Ultralight C, so it must be removed "
                    + "with the key it was set with", false
            )
        }
        let after = try await driver(tag).readConfiguration()
        return .require("prior protection removed (AUTH0 back to 30h)", after.isProtected == false)
    })

    // 1. Identification. Asserts what the session already resolved.
    //
    //    ⚠️ This step must NOT send GET_VERSION, however tempting it is to
    //    assert the chip's defining property directly. `60h` is refused, and a
    //    refused command returns a Type-2 tag to HALT for the rest of the
    //    activation, so the probe kills the session it is running in. Live
    //    2026-08-07: the step passed ("GET_VERSION refused"), and the very next
    //    step died with "tag connection lost" on a plain READ of page 0, taking
    //    the whole suite with it.
    //
    //    The property is proved anyway, without a frame: reaching this plan at
    //    all means identification refused `60h`, fell back to the memory-shape
    //    decoder and re-polled. A chip that answered GET_VERSION would have been
    //    identified as something else and would be running a different plan.
    steps.append(TagTestStep("ulc.identify", "Identify (no GET_VERSION)", safety: .readOnly) { tag, ctx in
        .all([
            .expect("session chip id", tag.chip?.id.description ?? "nil", equals: ctx.profile.id.description),
            .require("capabilities match", tag.capabilities == ctx.profile.capabilities),
            .pass("identified from memory shape after a refused GET_VERSION: the probe is "
                + "deliberately not repeated here, because its NAK halts the tag"),
        ])
    })

    // 2. UID + BCC integrity, identical to the Type-2 form.
    steps.append(TagTestStep("t2.uidBcc", "UID + BCC integrity", safety: .readOnly, requires: .memoryRead) { tag, _ in
        let m = try await tag.readMemory(range: 0 ..< 12)
        guard m.count >= 12 else { throw TagError.malformedResponse(m, diagnostics: "short header read") }
        let b = [UInt8](m)
        return .all([
            .expect("BCC0", b[3], equals: 0x88 ^ b[0] ^ b[1] ^ b[2]),
            .expect("BCC1", b[8], equals: b[4] ^ b[5] ^ b[6] ^ b[7]),
            .expectHex("UID matches header", Data([b[0], b[1], b[2], b[4], b[5], b[6], b[7]]), equals: tag.uid),
        ])
    })

    // 3. Capability Container. Ultralight C ships **blank** (rev 3.3 Table 13),
    //    so an unformatted tag is the expected factory state, not a fault.
    steps
        .append(TagTestStep("t2.ccVerify", "Capability Container", safety: .readOnly,
                            requires: .memoryRead)
        { tag, ctx in
            let cc = try await tag.readMemory(range: 12 ..< 16)
            let b = [UInt8](cc)
            guard b.count >= 4 else { throw TagError.malformedResponse(cc, diagnostics: "short CC read") }
            if b[0] != 0xE1 {
                ctx.scratch[TagTestContext.unformattedCCKey] = Data([0x01])
                return .pass("CC unformatted (page 3 OTP blank): the delivery state for this chip; "
                    + "run the gated format op to write one")
            }
            var checks: [TagStepCheck] = [.expect("CC magic", b[0], equals: 0xE1)]
            if let expected = ctx.profile.factoryCC {
                checks.append(.expectHex("CC matches factoryCC (OTP. Format writes this)", cc, equals: expected))
                checks.append(.require(
                    "declared NDEF area \(Int(b[2]) * 8)B fits the chip's \(ctx.profile.ndefByteCapacity)B",
                    Int(b[2]) * 8 <= ctx.profile.ndefByteCapacity
                ))
            }
            return .all(checks)
            })

    // 4. The configuration bytes read back as the delivery state.
    steps.append(TagTestStep(
        "ulc.authConfig",
        "AUTH0 / AUTH1 configuration",
        safety: .readOnly,
        requires: .rawTransceive
    ) { tag, _ in
        let config = try await driver(tag).readConfiguration()
        return .all([
            .expect("AUTH0 (page 2Ah byte 0)", config.auth0, equals: UltralightCLayout.protectionOff),
            .require("reports unprotected", config.isProtected == false),
        ])
    })

    // NOTE: there is deliberately no "confirm the key pages are unreadable"
    // step. Reads are decoded only up to page 2Bh, so `30 2C` returns a NAK
    // rather than masked zeros (live-confirmed 2026-08-07), and a NAK returns a
    // Type-2 tag to HALT for the rest of the activation. Such a step would kill
    // the session and fail every step after it, which reads as a hardware
    // fault. The clone case it was meant to catch is covered better by
    // `ulc.auth` anyway: a chip that stubs AUTHENTICATE cannot complete the
    // mutual handshake.

    // 5. The 3DES handshake with the factory key. On a virgin tag this is the
    //    single most informative step in the plan: it proves the cipher
    //    direction, the IV chaining, the rotate and the key byte order all at
    //    once, and it writes nothing.
    steps.append(TagTestStep(
        "ulc.auth",
        "3DES authenticate (factory key)",
        safety: .readOnly,
        requires: .tripleDESAuth
    ) { tag, _ in
        // Through `tag.authenticate`, not the raw driver: the ConnectedTag path
        // records the handshake in `UltralightCSessionHolder`, and a later step
        // that authenticates again in the same activation gets a NAK that halts
        // the tag. Going straight to the driver skips that bookkeeping, which is
        // exactly how the 2026-08-07 live run died at `ulc.protect`.
        let opening = try await tag.authenticate(.ultralightC(key: .factoryDefault))
        return .all([
            .expect("session material length", opening.response.count, equals: 8),
            .pass("mutual authentication completed with the published factory key"),
        ])
    })

    // 6. NDEF round-trip (reversible).
    steps.append(TagTestStep("t2.ndef", "NDEF round-trip", safety: .reversibleWrite, requires: [
        .ndefRead,
        .ndefWrite,
    ]) { tag, ctx in
        if ctx.scratch[TagTestContext.unformattedCCKey] != nil {
            return .pass("skipped: tag has no Capability Container; format it (gated op) and re-run")
        }
        ctx.scratch["t2.ndef.original"] = try await tag.readNDEF()
        try await tag.writeNDEF([.text(TextRecord(text: "HEXNFC", languageCode: "en"))])
        let readBack = try await tag.readNDEF()
        var text = "<none>"
        if case .text(let r)? = try NDEFCodec.decode(readBack).first {
            text = r.text
        }
        let check = TagStepCheck.expect("NDEF text", text, equals: "HEXNFC")
        try await restoreNDEF(tag, from: "t2.ndef.original", ctx: ctx)
        return check
    })

    // 7. Protect → verify → remove (reversible).
    //
    //    Unlike the NTAG424's factory-zero key there is no "authenticate
    //    without changing anything" state to lean on here: the factory key is
    //    published, so proving the gate exists means programming a real one.
    //    That is safe on this chip precisely because `disable` restores the
    //    factory key and clears AUTH0, which is also why Ultralight C can have
    //    an enforcement verifier where ICODE SLIX cannot.
    if let ndef = profile.memoryLayout.ndefRange {
        let protectFromPage = ndef.upperBound
        steps.append(TagTestStep(
            "ulc.protect",
            "3DES protect → auth → remove",
            safety: .reversibleWrite,
            requires: .tripleDESAuth
        ) { tag, ctx in
            guard let key = harnessKey(ctx) else { return .require("harness key is malformed", false) }
            let spec = ProtectionSpec.ultralightC(
                key: key, protectFromPage: protectFromPage, readProtect: false
            )
            // `activeKey(ctx)` is the key the tag is answering to in this
            // activation, which is not the key being written (a re-programmed key
            // only takes effect after an RF reset, rev 3.3 section 7.5.7 remark).
            // It reaches the driver through `replacing:` now that the spec has no
            // current-key field.
            try await tag.enableProtection(spec, replacing: .ultralightC(key: activeKey(ctx)))
            ctx.armedProtection = (spec, .ultralightC(key: key))

            var checks: [TagStepCheck] = []
            // Config read-back is the load-bearing proof that protection was
            // programmed. In-session enforcement is deliberately NOT asserted:
            // AUTH0 latches at the next activation on real silicon, and a
            // single-tap harness cannot force the RF power-cycle that would
            // make it observable. The enforcement verifier does that across
            // three sessions; this step proves the bytes landed.
            let config = try await driver(tag).readConfiguration()
            checks.append(.require("state reports protection", config.isProtected))
            checks.append(.expect("AUTH0", Int(config.auth0), equals: protectFromPage))
            checks.append(.expect("AUTH1 (write-only)", config.auth1, equals: 0x01))
            checks.append(.require("reads stay open", config.readProtect == false))

            // Remove it, using the key that is **still active in this session**.
            //
            // Counterintuitive but correct: "a re-programmed authentication key
            // is only valid for authentication after a RF reset or a
            // re-activation" (rev 3.3 §7.5.7 remark). The key we just wrote is
            // in memory but the card still authenticates against the one it
            // activated with, which on a factory tag is the default. Passing
            // the *new* key here fails with a bare NAK and the misleading
            // diagnostic "wrong key, or wrong byte order" — the simulator
            // models the latch precisely so this ordering error surfaces in CI
            // rather than on a tag we then cannot open.
            //
            // The next tap is where the new key takes over; that transition is
            // what `EnforcementCheckFlowModel` exercises across three sessions.
            try await tag.disableProtection(using: .ultralightC(key: activeKey(ctx)))
            ctx.armedProtection = nil
            let after = try await driver(tag).readConfiguration()
            checks.append(.require("unprotected after remove", after.isProtected == false))
            checks.append(.expect("AUTH0 restored", after.auth0, equals: UltralightCLayout.protectionOff))
            return .all(checks)
        })
    }

    return TagTestPlan(
        profile: profile, credentials: credentials,
        steps: steps, cleanup: CleanupSteps.ultralightC(profile)
    )
}

/// The key in force during cleanup, which runs in the same session as the suite.
///
/// Mirrors `ultralightCPlan`'s own `activeKey`, but cleanup is a free function on
/// `CleanupSteps` and cannot close over it. Falls back to the harness key only
/// when nothing was tracked *and* something is armed, which is the
/// aborted-earlier-run case.
private func activeKeyForCleanup(_ ctx: TagTestContext) -> UltralightCKey {
    if let bytes = ctx.scratch["ulc.activeKey"],
       let tracked = try? UltralightCKey(cipherOrder: bytes)
    {
        return tracked
    }
    return .factoryDefault
}

extension CleanupSteps {
    /// Factory-blank teardown for Ultralight C. Same ordering rule as the Type-2
    /// form: **unprotect first**, so a mid-cleanup failure never strands the tag
    /// behind a gate.
    static func ultralightC(_ profile: ChipProfile) -> [TagTestStep] {
        var steps: [TagTestStep] = []

        steps
            .append(TagTestStep("cleanup.unprotect", "Remove any 3DES protection",
                                safety: .reversibleWrite)
            { tag, ctx in
                let driver = UltralightCProtectionDriver(transceive: { try await tag.transceive($0) })
                let config = try? await driver.readConfiguration()
                guard config?.isProtected == true || ctx.armedProtection != nil else {
                    return .pass("already unprotected")
                }
                // Exactly **one** attempt, with the key this session tracked.
                //
                // Trying a list of candidates is worse than useless: a failed
                // authentication is a refusal, and a refusal returns the tag to HALT
                // for the rest of the activation, so every attempt after the first
                // talks to a tag that has stopped listening. The earlier version
                // looped over three keys and would have reported "no key opened the
                // tag" even when the second one was correct.
                //
                // One attempt suffices because the answer is determined, not
                // guessed: a newly written key does not become the authentication
                // key until the next activation (rev 3.3 §7.5.7 remark), so the key
                // in force is whatever the tag powered up with, which is exactly
                // what `ulc.activeKey` records.
                do {
                    try await tag.disableProtection(using: .ultralightC(key: activeKeyForCleanup(ctx)))
                    ctx.armedProtection = nil
                    return .pass("protection removed")
                } catch {
                    return .require(
                        "protection removed: the tag is still gated, and this session cannot retry "
                            + "because a failed authentication halts the tag. Re-run the batch: "
                            + "pre-flight clears it on a fresh activation", false
                    )
                }
                })

        if profile.capabilities.contains(.ndefWrite) {
            steps.append(TagTestStep(
                "cleanup.eraseNDEF",
                "Erase NDEF to blank",
                safety: .reversibleWrite,
                requires: .ndefWrite
            ) { tag, _ in
                // A tag whose CC is still blank has no NDEF area to erase, and
                // the write path refuses it. That is the delivery state for this
                // chip, so it is a pass, not a failure.
                //
                // The blank CC has to be a *reading*. This used to infer it
                // from the refusal instead, which reads any
                // `capabilityUnsupported` as "the CC is blank" and would report
                // a pass for a tag whose CC is fine and whose data area is what
                // the write path refused. Same defect the shipping scan carried
                // until 2026-09-09.
                //
                // Taken here rather than inherited from `t2.ccVerify`'s scratch
                // key. That key is absent in two different situations, and they
                // are not the same fact: the CC was read and is fine, or the
                // step never ran at all. `stopOnFirstFailure` is the default, so
                // any earlier failure halts the suite, skips `t2.ccVerify`, and
                // leaves cleanup with nothing. Collapsing that into "the CC is
                // fine" fails the cleanup of a virgin Ultralight C, and a failed
                // cleanup is not a clean pass, which is the gate that unlocks
                // the one op that tag needs. One safe frame at page 3 costs less
                // than the collapse.
                let ccIsBlank = await !Type2CC.isFormatted((try? tag.readMemory(range: 12 ..< 16)) ?? Data())
                do {
                    try await tag.writeNDEF([])
                    return .pass("NDEF erased")
                } catch let error as TagError {
                    if ccIsBlank, case .capabilityUnsupported = error.kind {
                        return .pass("no Capability Container: tag is unformatted, nothing to erase")
                    }
                    throw error
                }
            })
        }

        // NOTE: cleanup deliberately does not rewrite the Capability Container.
        // Page 3 is OTP, so a rewrite can only ever corrupt it. Writing a CC to
        // a genuinely blank tag is the gated `formatVirginCC` op's job.

        steps.append(TagTestStep("cleanup.verify", "Verify blank + unprotected", safety: .readOnly) { tag, _ in
            var checks: [TagStepCheck] = []
            if let state = try? await tag.readProtectionState() {
                checks.append(.require("unprotected", state.passwordProtect == false))
            }
            if tag.capabilities.contains(.ndefRead), let msg = try? await tag.readNDEF() {
                checks.append(.require("blank NDEF", NDEFCodec.isEmptyMessage(msg)))
            }
            return checks.isEmpty ? .pass("nothing to verify") : .all(checks)
        })

        return steps
    }
}
