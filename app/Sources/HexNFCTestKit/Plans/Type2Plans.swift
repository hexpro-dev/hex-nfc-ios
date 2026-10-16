import Foundation
import HexNFCKit
import HexNFCRecords

// MARK: - Type-2 (NTAG213/213TT/215/216, MIFARE Ultralight EV1)

func type2Plan(_ profile: ChipProfile, _ credentials: TagTestCredentials) -> TagTestPlan {
    let isUltralightEV1 = profile.id == .mifareUltralightEV1_48 || profile.id == .mifareUltralightEV1_128
    var steps: [TagTestStep] = []

    // 0. Pre-flight: a tag can arrive already protected — e.g. left write-gated by
    //    an aborted enforcement run (see EnforcementCheckFlowModel). Clear it with
    //    the known harness test credential up front so a leftover gate doesn't fail
    //    the NDEF/password steps mid-suite. A tag protected with some OTHER
    //    credential can't be cleared here and halts with a clear message instead of
    //    a confusing "Connection Closed" at the NDEF step.
    if profile.capabilities.contains(.passwordAuth), profile.type2ConfigLayout != nil {
        steps
            .append(TagTestStep("t2.preflight", "Pre-flight: ensure unprotected",
                                safety: .reversibleWrite)
            { tag, ctx in
                let protectedOnArrival = await ((try? tag.readProtectionState()) ?? nil)?.passwordProtect ?? false
                guard protectedOnArrival else { return .pass("not protected on arrival") }
                let credential = TagCredential.type2(
                    password: ctx.credentials.type2Password,
                    pack: ctx.credentials.type2Pack
                )
                do {
                    try await tag.disableProtection(using: credential)
                } catch {
                    return .require(
                        "cleared prior protection: arrived protected with a non-harness password; remove it manually",
                        false
                    )
                }
                let stillProtected = await ((try? tag.readProtectionState()) ?? nil)?.passwordProtect ?? false
                return .require("prior protection removed (was armed on arrival)", stillProtected == false)
                })
    }

    // 1. Identify via GET_VERSION and confirm the session's own identification.
    steps
        .append(TagTestStep("t2.identify", "Identify (GET_VERSION)", safety: .readOnly,
                            requires: .rawTransceive)
        { tag, ctx in
            let version = try await tag.transceive(mifareCommand([0x60], "GET_VERSION"))
            let decoded = ChipCatalog.identify(getVersion: version)?.id
            return .all([
                .expect("GET_VERSION decode", decoded?.description ?? "nil", equals: ctx.profile.id.description),
                .expect("session chip id", tag.chip?.id.description ?? "nil", equals: ctx.profile.id.description),
                .require("capabilities match", tag.capabilities == ctx.profile.capabilities),
            ])
            })

    // 2. UID + BCC integrity, cross-checked against the identified UID.
    steps.append(TagTestStep("t2.uidBcc", "UID + BCC integrity", safety: .readOnly, requires: .memoryRead) { tag, _ in
        let m = try await tag.readMemory(range: 0 ..< 12)
        guard m.count >= 12 else { throw TagError.malformedResponse(m, diagnostics: "short header read") }
        let b = [UInt8](m)
        let bcc0Expected = 0x88 ^ b[0] ^ b[1] ^ b[2]
        let bcc1Expected = b[4] ^ b[5] ^ b[6] ^ b[7]
        let reconstructedUID = Data([b[0], b[1], b[2], b[4], b[5], b[6], b[7]])
        return .all([
            .expect("BCC0", b[3], equals: bcc0Expected),
            .expect("BCC1", b[8], equals: bcc1Expected),
            .expectHex("UID matches header", reconstructedUID, equals: tag.uid),
        ])
    })

    // 3. Capability Container magic + version.
    if let ccPage = profile.memoryLayout.ccPage {
        let ccOffset = ccPage * profile.memoryLayout.pageSize
        // 3. Capability Container — asserted byte-for-byte against the chip's
        //    canonical `factoryCC`, not just the E1 10 magic. Page 3 is OTP, so
        //    the app's `format` gets exactly one attempt per tag: if the live CC
        //    and `factoryCC` disagree, either the constant is wrong (and format
        //    would corrupt a virgin tag of this type) or this tag was formatted
        //    by something that disagreed. Both are worth failing loudly for. A
        //    weaker magic-only check is what let NTAG213 ship declaring 48 B
        //    against a hardware-confirmed 144 B.
        steps
            .append(TagTestStep("t2.ccVerify", "Capability Container", safety: .readOnly,
                                requires: .memoryRead)
            { tag, ctx in
                let cc = try await tag.readMemory(range: ccOffset ..< ccOffset + 4)
                let b = [UInt8](cc)
                guard b.count >= 4 else { throw TagError.malformedResponse(cc, diagnostics: "short CC read") }
                // NXP ships NTAG21x NDEF-preformatted, but the MIFARE Ultralight EV1
                // CC lives in the OTP page and ships blank (00 00 00 00). A virgin
                // EV1 is a valid factory state, not a fault — surface it and pass.
                // (The gated `formatVirginCC` op is what exercises the write.)
                if isUltralightEV1, b[0] != 0xE1 {
                    // Record it so the NDEF step reports honestly instead of failing:
                    // without a CC the reader path returns `capabilityUnsupported`.
                    ctx.scratch[TagTestContext.unformattedCCKey] = Data([0x01])
                    return .pass(
                        "CC unformatted (page 3 OTP blank). EV1 ships without an NDEF CC; run the gated format op to write one"
                    )
                }
                var checks: [TagStepCheck] = [
                    .expect("CC magic", b[0], equals: 0xE1),
                    .expect("CC version", b[1], equals: 0x10),
                ]
                if let expected = ctx.profile.factoryCC {
                    checks.append(.expectHex(
                        "CC matches factoryCC (OTP. Format writes this)",
                        cc,
                        equals: expected
                    ))
                    let declared = Int(b[2]) * 8
                    checks.append(.require(
                        "declared NDEF area \(declared)B fits the chip's \(ctx.profile.ndefByteCapacity)B",
                        declared <= ctx.profile.ndefByteCapacity
                    ))
                }
                return .all(checks)
                })

        // 4. FAST_READ agrees with READ on the CC page. Gated on `.fastRead`,
        //    not on the CC page alone: the NTAG 210µ has an ordinary CC but no
        //    FAST_READ opcode, so keying off `ccPage` sent a command real
        //    silicon NAKs and failed an otherwise clean run — which in turn
        //    withheld the clean pass the gated irreversible ops depend on.
        steps.append(TagTestStep(
            "t2.fastRead",
            "FAST_READ vs READ",
            safety: .readOnly,
            requires: [.rawTransceive, .fastRead]
        ) { tag, _ in
            let fast = try await tag.transceive(mifareCommand([0x3A, UInt8(ccPage), UInt8(ccPage)], "FAST_READ"))
            let read = try await readType2Page(tag, ccPage)
            return .all([
                .expect("FAST_READ length", fast.count, equals: 4),
                .expectHex("FAST_READ == READ", fast.prefix(4), equals: read),
            ])
        })
    }

    // 5. ECC signature is readable (32 bytes on genuine NXP silicon).
    steps
        .append(TagTestStep("t2.signature", "Read ECC signature", safety: .readOnly,
                            requires: .signatureRead)
        { tag, _ in
            let sig = try await tag.transceive(mifareCommand([0x3C, 0x00], "READ_SIG"))
            // A short/odd-length reply is a non-genuine (clone/compatible) chip that
            // stubs READ_SIG. Surface it as a note instead of halting the suite, so the
            // NDEF + password steps still run and the divergence stays visible.
            if sig.count != 32 {
                return .pass("signature \(sig.count)B, not 32: non-genuine chip? (READ_SIG not fully implemented)")
            }
            return .expect("signature length", sig.count, equals: 32)
            })

    // 6. NFC counter readable (and monotonic across an NDEF read on NTAG).
    //    The one-way counter ships disabled (NFC_CNT_EN=0) on factory NTAG, and a
    //    disabled counter NAKs READ_CNT (a 1-byte frame, not 3). That's a valid
    //    state, not a fault, so we surface it and pass rather than fail the suite.
    steps.append(TagTestStep("t2.counters", "NFC counter", safety: .readOnly, requires: .counterRead) { tag, _ in
        // Decode a 24-bit little-endian counter frame, or nil for a NAK/short frame.
        func decode(_ frame: Data) -> Int? {
            guard frame.count >= 3 else { return nil }
            let b = [UInt8](frame)
            return Int(b[0]) | Int(b[1]) << 8 | Int(b[2]) << 16
        }

        // MIFARE Ultralight EV1 has THREE independent 24-bit one-way counters
        // (MF0ULx1 §8.7), not NTAG's single NFC counter. They tick only on
        // INCR_CNT (0xA5), never on a read, and ship at 0 — so the assertion is
        // readability and range, not movement. INCR_CNT itself is a genuinely
        // one-way write and is deliberately kept out of the batch.
        if isUltralightEV1 {
            var checks: [TagStepCheck] = []
            var readable = 0
            for index: UInt8 in 0 ... 2 {
                let frame = try await tag.transceive(mifareCommand([0x39, index], "READ_CNT \(index)"))
                guard let value = decode(frame) else {
                    checks.append(.pass("counter \(index) not readable (NAK). Valid on a never-incremented EV1"))
                    continue
                }
                readable += 1
                checks.append(.require("counter \(index) = \(value) within 24 bits", value <= 0xFFFFFF))
            }
            checks.append(.pass("\(readable)/3 EV1 counters readable"))
            return .all(checks)
        }

        // NTAG21x: one counter, disabled at the factory (NFC_CNT_EN=0), which
        // NAKs READ_CNT with a 1-byte frame. That's a valid state, not a fault.
        let first = try await tag.transceive(mifareCommand([0x39, 0x02], "READ_CNT"))
        guard let c0 = decode(first) else {
            return .pass("counter disabled (NFC_CNT_EN=0). Factory default, not read")
        }
        // NTAG ticks counter 0 on a successful NDEF read; verify it never regresses.
        _ = try? await tag.readNDEF()
        let second = try await tag.transceive(mifareCommand([0x39, 0x02], "READ_CNT"))
        guard let c1 = decode(second) else {
            return .pass("counter readable once, then disabled between reads")
        }
        return .require("counter monotonic (c1=\(c1) >= c0=\(c0))", c1 >= c0 && c1 <= 0xFFFFFF)
    })

    // 7b. Tearing-event status — Ultralight EV1 only (MF0ULx1 §10.7). A healthy
    //     counter answers 0xBD ("no tearing event"). NTAG21x has no such opcode.
    if isUltralightEV1 {
        steps.append(TagTestStep(
            "t2.tearing",
            "Counter tearing status",
            safety: .readOnly,
            requires: [.rawTransceive, .counterRead]
        ) { tag, _ in
            var checks: [TagStepCheck] = []
            for index: UInt8 in 0 ... 2 {
                let frame = try await tag.transceive(mifareCommand([0x3E, index], "CHECK_TEARING_EVENT \(index)"))
                guard let flag = frame.first, frame.count == 1 else {
                    checks.append(.pass("counter \(index): no tearing status (resp=\(frame.hexString))"))
                    continue
                }
                checks.append(.require(
                    "counter \(index) intact (0xBD), got 0x\(String(format: "%02X", flag))",
                    flag == 0xBD
                ))
            }
            return .all(checks)
        })
    }

    // 7. Tamper-loop status (NTAG213 TT only).
    steps.append(TagTestStep("t2.tamper", "Tamper-loop status", safety: .readOnly, requires: .tamperStatus) { tag, _ in
        let status = try await tag.transceive(mifareCommand([0xA4], "READ_TT_STATUS"))
        return .expect("TT status length", status.count, equals: 4)
    })

    // 8. NDEF write → read-back → verify → restore (reversible).
    steps.append(TagTestStep("t2.ndef", "NDEF round-trip", safety: .reversibleWrite, requires: [
        .ndefRead,
        .ndefWrite,
    ]) { tag, ctx in
        // An unformatted tag has no NDEF to round-trip: the reader path refuses
        // it (`queryNDEFStatus` → `.notSupported`). Writing the CC is a one-shot
        // OTP operation, so the batch never does it — the gated `formatVirginCC`
        // op does, and a re-run then exercises this step for real.
        if ctx.scratch[TagTestContext.unformattedCCKey] != nil {
            return .pass("skipped: tag has no Capability Container; format it (gated op) and re-run")
        }
        ctx.scratch["t2.ndef.original"] = try await tag.readNDEF()
        try await tag.writeNDEF([.text(TextRecord(text: "HEXNFC", languageCode: "en"))])
        let readBack = try await tag.readNDEF()
        let records = try NDEFCodec.decode(readBack)
        var text = "<none>"
        if case .text(let r)? = records.first {
            text = r.text
        }
        let check = TagStepCheck.expect("NDEF text", text, equals: "HEXNFC")
        try await restoreNDEF(tag, from: "t2.ndef.original", ctx: ctx)
        return check
    })

    // 9 to 11. Password protect, authenticate, remove, and prove across taps
    // what the tag holds afterwards. See `type2PasswordSteps`.
    steps.append(contentsOf: type2PasswordSteps(profile))

    return TagTestPlan(profile: profile, credentials: credentials, steps: steps, cleanup: CleanupSteps.type2(profile))
}

/// Steps 9 to 11: the credential sequence, which spans three taps.
///
/// Lifted out of `type2Plan` when the multi-tap steps landed. The reason is
/// mechanical (`type2Plan` went past SwiftLint's 250-line function body, which
/// CI runs with `--strict`), but the seam is the honest one: everything here is
/// gated on `.passwordAuth` plus a `Type2ConfigLayout`, and a chip without both
/// contributes nothing to the plan.
private func type2PasswordSteps(_ profile: ChipProfile) -> [TagTestStep] {
    guard profile.capabilities.contains(.passwordAuth), profile.type2ConfigLayout != nil,
          let ndef = profile.memoryLayout.ndefRange
    else { return [] }

    var steps: [TagTestStep] = []
    let protectFromPage = ndef.upperBound
    let pageOffset = protectFromPage * profile.memoryLayout.pageSize
    steps.append(TagTestStep(
        "t2.password",
        "Password protect → auth → remove",
        safety: .reversibleWrite,
        requires: .passwordAuth
    ) { tag, ctx in
        let pwd = ctx.credentials.type2Password
        let pack = ctx.credentials.type2Pack
        let original = try await tag.readMemory(range: pageOffset ..< pageOffset + 4)

        let spec = ProtectionSpec.type2(
            password: pwd,
            pack: pack,
            protectFromPage: protectFromPage,
            readProtect: false,
            authLimit: 0
        )
        let armResidue = try await tag.enableProtection(spec)
        ctx.armedProtection = (spec, .type2(password: pwd, pack: pack))

        var checks: [TagStepCheck] = [
            .require("protect met its goal (gate read back armed, credential proven)", armResidue.metItsGoal),
        ]
        // Unauthenticated write to a page at/above AUTH0. We do NOT hard-fail on
        // an ACK here: on real silicon the memory-access restriction can latch at
        // the next tag ACTIVATION rather than mid-session, and non-genuine/clone
        // Type-2 tags often don't enforce AUTH0 at all, and a single-tap harness
        // can't force the RF power-cycle that would make in-session enforcement
        // observable. Protection-armed is instead proven below by the PACK
        // round-trip and the config read-back (the load-bearing assertions). We
        // write the ORIGINAL bytes back, so an accepted write is a no-op.
        do {
            try await tag.writeMemory(at: pageOffset, bytes: original)
            checks
                .append(
                    .pass(
                        "unauth write ACKed. AUTH0 enforced at next activation, or non-genuine tag; verified via PACK + state"
                    )
                )
        } catch is TagError {
            checks.append(.pass("unauth write blocked: protection enforced in-session"))
        }
        // Correct password returns our PACK, then writes are allowed again.
        let gotPack = try await tag.authenticate(password: pwd)
        checks.append(.expectHex("PACK", gotPack, equals: pack))
        try await tag.writeMemory(at: pageOffset, bytes: original)
        checks.append(.pass("authed write ok"))
        // Config read-back is the real proof protection was programmed: it fails
        // loudly if enableProtection didn't actually set AUTH0/ACCESS.
        let state = try await tag.readProtectionState()
        checks.append(.require("protection state readable", state != nil))
        if let state {
            checks.append(.require("state reports protection", state.passwordProtect))
            checks.append(.expect("protectFromPage", state.protectFromPage ?? -1, equals: protectFromPage))
            checks.append(.require("reads stay open", state.readProtect == false))
        }
        // Remove protection and confirm. The residue is the frame-level
        // truth: `metItsGoal` is the AUTH0 read-back, not a count of ACKs.
        let residue = try await tag.disableProtection(using: .type2(password: pwd, pack: pack))
        ctx.armedProtection = nil
        checks.append(.require("removal met its goal (gate read back open)", residue.metItsGoal))
        // Tidy-up is NOT a `require`. A removal that proved the gate open and
        // then failed to reset the credential is a success with residue: the
        // tag is unlocked either way. Reporting that as a failure is exactly
        // what stranded a real NTAG213 on 2026-09-04.
        checks.append(.pass("credential tidy-up: \(residue.credential)"))
        checks.append(.pass(residue.diagnostics))
        if let state = try await tag.readProtectionState() {
            checks.append(.require("unprotected after remove", state.passwordProtect == false))
            recordProtectionReading(state.passwordProtect, into: &ctx)
        }
        // What this step does NOT establish, and cannot: whether the tag now
        // holds the factory credential. AUTH0 latches at the next activation,
        // so the read above reads back what was just written rather than what
        // the tag will enforce; and PWD/PACK read back as zeros by design
        // (NTAG213 rev 3.2 section 8.8), so the only way to ask what the tag
        // holds is to present a password, which a NAK would then halt. Both
        // questions belong to the next tap, and are asked there.
        return .all(checks)
    })

    // TAP 1 - the removal is only proven on a re-selected tag.
    steps.append(TagTestStep(
        "t2.password.credentialReverts",
        "After removal: config clean, credential reverted",
        safety: .reversibleWrite,
        requires: .passwordAuth,
        tap: 1,
        endsActivation: true
    ) { tag, ctx in
        guard let driver = tag.type2PasswordDriver else {
            return .require("Type-2 password driver available on this tag", false)
        }
        // The RAW configuration, never `readProtectionState()`. That
        // projection returns `TagProtection.none` whenever the gate is open,
        // whatever the ACCESS byte holds, so an assertion on it tests the
        // model's early return rather than the tag - and the stand-down
        // below, which decides whether it is safe to spend an authentication
        // attempt, would then always fail open.
        guard case .read(let config) = try await driver.readState() else {
            return .require(
                "configuration pages readable after removal (a read gate here means it did not hold)",
                false
            )
        }
        var checks: [TagStepCheck] = [
            .require("gate open on a fresh activation (AUTH0 past the last page)", !config.isGateArmed),
            .require("read gate clear (ACCESS PROT bit)", !config.readProtect),
            .require("no attempt limit left armed (ACCESS AUTH_LIM)", config.authLimit == 0),
        ]
        recordProtectionReading(config.isGateArmed, into: &ctx)

        // The credential question. RECORDED, not required, and for a reason
        // that has not changed: nothing in this repo establishes whether an
        // NTAG21x answers PWD_AUTH at all once AUTH0 points past its last
        // page. A refusal here is therefore not evidence of anything, and
        // asserting one is how a step passes in CI and fails on silicon. An
        // *answer* is evidence, and it is the proof the 2026-09-04 incident
        // wanted: the tag reverted to the factory credential.
        //
        // Ordered last in its tap because a refusal NAKs, and a NAK returns
        // the chip to HALT for the rest of the activation.
        guard config.authLimit == 0 else {
            checks.append(.pass(
                "credential not established: AUTH_LIM is armed, and a speculative "
                    + "PWD_AUTH would spend one of a finite number of attempts"
            ))
            return .all(checks)
        }
        if let pack = try? await tag.authenticate(password: Type2Credential.factoryPassword) {
            // The PACK bytes stay out of the report. Whether they match is
            // the whole of what a reader needs, and this string is meant for
            // pasting into a bug report.
            checks.append(.require(
                "tag answered the factory password, and the PACK is the factory default",
                pack == Type2Credential.factoryPack
            ))
        } else {
            checks.append(.pass(
                "credential not established: the tag did not answer the factory password. "
                    + "Expected if PWD_AUTH is refused while AUTH0 is open; the next tap asks the other half"
            ))
        }
        return .all(checks)
    })

    // TAP 2 - the credential the suite armed must be gone.
    steps.append(TagTestStep(
        "t2.password.oldCredentialRefused",
        "The password the suite armed no longer authenticates",
        safety: .reversibleWrite,
        requires: .passwordAuth,
        tap: 2,
        endsActivation: true
    ) { tag, ctx in
        guard let driver = tag.type2PasswordDriver else {
            return .require("Type-2 password driver available on this tag", false)
        }
        // State first: read what the tag gates before presenting anything.
        // Raw config again, for the reason the tap-1 step gives.
        guard case .read(let config) = try await driver.readState() else {
            return .require("configuration pages readable before presenting a credential", false)
        }
        recordProtectionReading(config.isGateArmed, into: &ctx)
        guard !config.isGateArmed else {
            return .require("the gate is open two taps after the removal", false)
        }
        guard config.authLimit == 0 else {
            return .pass(
                "not established: AUTH_LIM is armed, and this probe would spend one of a "
                    + "finite number of attempts"
            )
        }

        // One authentication attempt, and it is the last frame of the tap.
        //
        // A success is the failure. If the password the suite armed still
        // opens this tag then the removal did not revert the credential, and
        // the tag is holding one the app believes is gone. That is the shape
        // of the 2026-09-04 desync, and it is a failure whatever PACK comes
        // back.
        do {
            _ = try await tag.authenticate(password: ctx.credentials.type2Password)
            return .require(
                "the password the suite armed must no longer authenticate (it still does)",
                false
            )
        } catch let error as TagError where error.kind == .authFailed {
            // A refusal the chip actually stated.
            return .pass("the armed password was refused, which is the answer a reverted tag gives")
        } catch let error as TagError where error.kind == .authInconclusive {
            // A lost frame, not a stated refusal. `Type2PasswordDriver` keeps
            // the two apart on purpose and this step may not collapse them:
            // scoring a lost tag as proof is what the distinction exists to
            // prevent.
            return .pass(
                "not established: PWD_AUTH did not complete, so a refusal and a lost tag "
                    + "cannot be told apart here"
            )
        }
    })
    return steps
}

// MARK: - EM Microelectronic (V10 / V11 / V16)

func emPlan(_ profile: ChipProfile, _ credentials: TagTestCredentials) -> TagTestPlan {
    var steps: [TagTestStep] = []

    // What we can verify on real silicon: EM Microelectronic-Marin tags carry
    // manufacturer byte 0x16 at UID SN0 (ISO/IEC 7816-6). The simulator instead
    // seeds a fabricated "PVM" fixture at page 0 (see the EMSimulators sourcing
    // caveat) that ChipCatalog.identify(emSignature:) recognises — so accept
    // either as "this is an EM tag". The specific variant (V10/V11/V16) cannot be
    // told apart from a page-0 read on real silicon; it comes from the user-
    // confirmed plan (ctx.profile). REACHABILITY CAVEAT: production identifies via
    // GET_VERSION (0x60), which real EM silicon may NAK — so tag.chip can be nil
    // on a live tap, and the EM plan may not even be reachable until EM
    // identification is verified on-device (see the harness notes).
    steps
        .append(TagTestStep("em.identify", "Identify (manufacturer)", safety: .readOnly,
                            requires: .memoryRead)
        { tag, ctx in
            let page0 = try await tag.readMemory(range: 0 ..< 2)
            let sn0 = page0.first ?? 0x00
            let looksLikeEM = sn0 == 0x16 || ChipCatalog.identify(emSignature: page0) != nil
            var checks: [TagStepCheck] = [
                .require("EM manufacturer (SN0=\(String(format: "%02X", Int(sn0))))", looksLikeEM),
            ]
            if let liveID = tag.chip?.id {
                checks.append(.expect("session chip id", liveID.description, equals: ctx.profile.id.description))
            } else {
                checks.append(.pass("variant unresolved on live tap (EM may NAK GET_VERSION)"))
            }
            return .all(checks)
            })

    if let ccPage = profile.memoryLayout.ccPage {
        let ccOffset = ccPage * profile.memoryLayout.pageSize
        steps
            .append(TagTestStep("em.ccRead", "Capability Container", safety: .readOnly,
                                requires: .memoryRead)
            { tag, _ in
                let cc = try await tag.readMemory(range: ccOffset ..< ccOffset + 2)
                let b = [UInt8](cc)
                guard b.count >= 2 else { throw TagError.malformedResponse(cc, diagnostics: "short CC read") }
                // A virgin/unformatted Type-2 CC page reads all-zero until NDEF-
                // formatted. On a factory-blank EM tag that's expected, not a fault
                // (the em.ndef step formats it); only assert the magic once present.
                if b[0] == 0x00, b[1] == 0x00 {
                    return .pass("CC unformatted (virgin factory state): 00 00")
                }
                return .all([
                    .expect("CC magic", b[0], equals: 0xE1),
                    .expect("CC version", b[1], equals: 0x10),
                ])
                })
    }

    steps.append(TagTestStep("em.ndef", "NDEF round-trip", safety: .reversibleWrite, requires: [
        .ndefRead,
        .ndefWrite,
    ]) { tag, ctx in
        ctx.scratch["em.ndef.original"] = try await tag.readNDEF()
        try await tag.writeNDEF([.text(TextRecord(text: "HEXNFC", languageCode: "en"))])
        let records = try await NDEFCodec.decode(tag.readNDEF())
        var text = "<none>"
        if case .text(let r)? = records.first {
            text = r.text
        }
        let check = TagStepCheck.expect("NDEF text", text, equals: "HEXNFC")
        try await restoreNDEF(tag, from: "em.ndef.original", ctx: ctx)
        return check
    })

    return TagTestPlan(profile: profile, credentials: credentials, steps: steps, cleanup: CleanupSteps.type2(profile))
}
