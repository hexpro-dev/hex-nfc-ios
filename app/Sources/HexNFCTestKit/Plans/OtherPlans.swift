import Foundation
import HexNFCKit
import HexNFCRecords

// MARK: - NTAG424 DNA (Type-4)

/// Run the wrapped Type-4 `GET_VERSION` to completion and return its **first
/// frame** (7 bytes of NXP hardware info + the `91 AF` / `91 00` status), which
/// is what `ChipCatalog.identify(type4Version:)` decodes.
///
/// `GET_VERSION` is a 3-frame chained command on real silicon: the first frame
/// ends `91 AF` ("additional frame follows"). Draining the `90 AF …`
/// continuations leaves the card idle so the following native `90-xx` steps
/// don't hit `91 CA` (COMMAND_ABORTED = chain still open). Also recovers if the
/// chain was somehow left open coming in — an incoming `91 CA` means our command
/// aborted a stale chain, so re-issuing once returns the real first frame. The
/// chip simulator answers in one frame ending `91 00`, so both the retry and the
/// drain are no-ops there.
private func type4GetVersion(_ tag: any ConnectedTag) async throws -> Data {
    func endsWith(_ resp: Data, _ a: UInt8, _ b: UInt8) -> Bool {
        let tail = resp.suffix(2)
        return tail.count == 2 && Array(tail) == [a, b]
    }
    let get = RawCommand(bytes: Data([0x90, 0x60, 0x00, 0x00, 0x00]), name: "GET_VERSION")
    var first = try await tag.transceive(get)
    if endsWith(first, 0x91, 0xCA) {
        first = try await tag.transceive(get)
    }
    var frame = first
    var frames = 0
    while endsWith(frame, 0x91, 0xAF), frames < 4 {
        frame = try await tag.transceive(RawCommand(
            bytes: Data([0x90, 0xAF, 0x00, 0x00, 0x00]),
            name: "GET_VERSION (cont.)"
        ))
        frames += 1
    }
    return first
}

/// ISO SELECT of the NTAG424 NDEF application (AID `D2760000850101`). Native file
/// commands (GetFileSettings, ReadData…) are `PERMISSION_DENIED` (`91 9D`) at the
/// PICC level until the app is selected — the production driver
/// (`NTAG424ProtectionDriver.selectNDEFApp`) does this before every plain probe,
/// so the harness must too. A still-open GET_VERSION frame can make the first
/// SELECT return `69 85` ("conditions of use not satisfied"); that failed SELECT
/// itself clears the pending-frame state, so one retry succeeds. The simulator
/// accepts the same SELECT (`swOK`), so this is a no-op divergence there.
private func selectType4NDEFApp(_ tag: any ConnectedTag) async throws {
    let apdu = RawCommand(
        bytes: Data([0x00, 0xA4, 0x04, 0x00, 0x07, 0xD2, 0x76, 0x00, 0x00, 0x85, 0x01, 0x01, 0x00]),
        name: "SELECT NDEF app"
    )
    func statusWord(_ resp: Data) -> UInt16 {
        let tail = Array(resp.suffix(2))
        guard tail.count == 2 else { return 0 }
        return (UInt16(tail[0]) << 8) | UInt16(tail[1])
    }
    var resp = try await tag.transceive(apdu)
    if statusWord(resp) == 0x6985 {
        resp = try await tag.transceive(apdu)
    }
    let sw = statusWord(resp)
    guard sw == 0x9000 || sw == 0x9100 else {
        throw TagError.protocolError("SELECT NDEF app failed", diagnostics: "sw=\(String(sw, radix: 16))")
    }
}

/// Best-effort removal of NTAG424 protection for the pre-flight / cleanup. A tag
/// left armed by an aborted enforcement run is gated behind either the harness
/// enforcement key (if its ChangeKey landed) or the factory-zero key (if only
/// ChangeFileSettings did), so try both. Returns whether the tag ends unprotected.
private func type4ClearProtection(_ tag: any ConnectedTag, _ credentials: TagTestCredentials) async -> Bool {
    func unprotected() async -> Bool {
        await ((try? tag.readProtectionState()) ?? nil)?.passwordProtect == false
    }
    for key in [credentials.type4EnforcementKey, credentials.type4AESKey] {
        if await unprotected() {
            return true
        }
        _ = try? await tag.disableProtection(using: .type4(aesKey: key, keySlot: 0))
    }
    return await unprotected()
}

func ntag424Plan(_ profile: ChipProfile, _ credentials: TagTestCredentials) -> TagTestPlan {
    var steps: [TagTestStep] = []

    steps.append(TagTestStep(
        "t4.identify",
        "Identify (wrapped GET_VERSION)",
        safety: .readOnly,
        requires: .rawTransceive
    ) { tag, ctx in
        let version = try await type4GetVersion(tag)
        let decoded = ChipCatalog.identify(type4Version: version)?.id
        return .all([
            .expect("version decode", decoded?.description ?? "nil", equals: ChipID.ntag424DNA.description),
            .expect("session chip id", tag.chip?.id.description ?? "nil", equals: ctx.profile.id.description),
        ])
    })

    // Pre-flight: a tag can arrive already armed (e.g. an aborted enforcement run
    // left the NDEF file write-gated behind the harness key) — the plain NDEF
    // round-trip below would then fail "Connection Closed", and the Type-4 cleanup
    // can't blank a protected file. Clear it up front with the harness keys so the
    // suite (and a stuck tag) recover. A tag gated by an unknown key fails loudly.
    steps.append(TagTestStep("t4.preflight", "Pre-flight: ensure unprotected", safety: .reversibleWrite) { tag, ctx in
        let protectedOnArrival = await ((try? tag.readProtectionState()) ?? nil)?.passwordProtect ?? false
        guard protectedOnArrival else { return .pass("not protected on arrival") }
        guard await type4ClearProtection(tag, ctx.credentials) else {
            return .require(
                "cleared prior protection: arrived protected with a non-harness key; remove it manually",
                false
            )
        }
        return .pass("prior protection removed (was armed on arrival)")
    })

    // GetFileSettings for the NDEF file — factory is plain comm mode, SUN off.
    // Select the NDEF app first (native file commands are 91 9D at PICC level).
    steps
        .append(TagTestStep("t4.fileSettings", "NDEF file settings", safety: .readOnly,
                            requires: .rawTransceive)
        { tag, _ in
            try await selectType4NDEFApp(tag)
            let resp = try await tag.transceive(RawCommand(
                bytes: Data([0x90, 0xF5, 0x00, 0x00, 0x01, 0x02, 0x00]),
                name: "GetFileSettings"
            ))
            let sw = Array(resp.suffix(2))
            // Some factory tags still gate a plain GetFileSettings behind auth
            // (91 9D PERMISSION_DENIED) or reject it once a session is live
            // (91 7E LENGTH_ERROR). Note it and keep going — the meaningful NDEF
            // steps (plain round-trip, AES EV2 auth) follow and shouldn't be skipped.
            guard sw == [0x91, 0x00] else {
                return .pass(
                    "GetFileSettings gated on factory silicon (sw=\(Data(sw).hexString)): plain probe not permitted, needs AuthenticateEV2First"
                )
            }
            guard resp.count >= 4
            else { throw TagError.malformedResponse(resp, diagnostics: "short GetFileSettings") }
            // FileType(1) ‖ FileOption/commMode(1) ‖ AccessRights(2) ‖ … ; low 2 bits
            // of FileOption are the comm mode (0 = plain, 3 = full/encrypted).
            let commMode = resp[resp.startIndex + 1] & 0x03
            return .expect("commMode plain", commMode, equals: 0x00)
            })

    // Plain NDEF round-trip (factory free access).
    steps.append(TagTestStep(
        "t4.ndef",
        "NDEF round-trip (plain)",
        safety: .reversibleWrite,
        requires: [.ndefRead, .ndefWrite]
    ) { tag, ctx in
        ctx.scratch["t4.ndef.original"] = try await tag.readNDEF()
        try await tag.writeNDEF([.uri(URIRecord(uri: "https://hex.pro"))])
        let records = try await NDEFCodec.decode(tag.readNDEF())
        var uri = "<none>"
        if case .uri(let r)? = records.first {
            uri = r.uri
        }
        let check = TagStepCheck.expect("NDEF uri", uri, equals: "https://hex.pro")
        try await restoreNDEF(tag, from: "t4.ndef.original", ctx: ctx)
        return check
    })

    // AES EV2 authenticate with the factory key, then round-trip NDEF through the
    // secure-messaging session (fully reversible — no ChangeKey / ChangeFileSettings).
    steps.append(TagTestStep(
        "t4.aesAuth",
        "AES EV2 auth + secure NDEF",
        safety: .reversibleWrite,
        requires: .passwordAuth
    ) { tag, ctx in
        _ = try await tag.authenticate(.type4(aesKey: ctx.credentials.type4AESKey, keySlot: 0))
        let original = try await tag.readNDEF()
        try await tag.writeNDEF([.text(TextRecord(text: "HEX424", languageCode: "en"))])
        let records = try await NDEFCodec.decode(tag.readNDEF())
        var text = "<none>"
        if case .text(let r)? = records.first {
            text = r.text
        }
        let check = TagStepCheck.expect("secure NDEF text", text, equals: "HEX424")
        // Restore whatever was there before this step.
        if NDEFCodec.isEmptyMessage(original) {
            try await tag.writeNDEF([])
        } else if let restore = try? NDEFCodec.decode(original) {
            try await tag.writeNDEF(restore)
        }
        return check
    })

    // **T4-1: does an ISO SELECT end a live EV2 session? ANSWERED 2026-09-20: it
    // does.** Kept as a regression probe, and rewritten because its first
    // version scored the wrong frames.
    //
    // The shipping write route for a protected 424 authenticates, then probes
    // protection through a fresh driver that re-SELECTs the NDEF app, then
    // writes the records through the session the first step established. This
    // step is that sequence on a tag with nothing armed.
    //
    // **The verdict comes from the control pair, not from the write.** On a
    // factory tag the NDEF file is free access (AR=E0EE), so ReadData and
    // WriteData succeed with or without a session, and the first version of
    // this step read their `91 00` as proof the session had survived. It is not.
    // What discriminates is the same plain GetFileSettings sent twice in one
    // activation: a live session refuses it `91 7E`, because the command must
    // carry a MAC inside a session and a plain one is the wrong length. On
    // 2026-09-20, UID 04:89:37:CA:9C:17:90, it answered `91 7E` before the
    // SELECT and `91 00` after it. The only thing between them was the SELECT,
    // so the SELECT ended the session.
    //
    // That also answers T4-2 in the affirmative: a plain GetFileSettings **is**
    // refused inside a live session, and `91 7E` is the status word for it.
    steps.append(TagTestStep(
        "t4.sessionAcrossSelect",
        "EV2 session across the protection probe",
        safety: .reversibleWrite,
        requires: .passwordAuth
    ) { tag, ctx in
        func plainFileSettings() async -> Data? {
            try? await tag.transceive(RawCommand(
                bytes: Data([0x90, 0xF5, 0x00, 0x00, 0x01, 0x02, 0x00]),
                name: "GetFileSettings (plain probe)"
            ))
        }
        func statusWord(_ response: Data?) -> String {
            response.map { Data($0.suffix(2)).hexString } ?? "no answer"
        }

        _ = try await tag.authenticate(.type4(aesKey: ctx.credentials.type4AESKey, keySlot: 0))
        let insideSession = await plainFileSettings()
        // The probe the write route runs next. It re-SELECTs.
        _ = try? await tag.readProtectionState()
        let afterSelect = await plainFileSettings()

        let refusedInSession = Data(insideSession?.suffix(2) ?? Data()) == Data([0x91, 0x7E])
        let acceptedAfter = Data(afterSelect?.suffix(2) ?? Data()) == Data([0x91, 0x00])
        return .all([
            .pass("plain GetFileSettings inside the session: \(statusWord(insideSession))"),
            .pass("the same frame after the SELECT: \(statusWord(afterSelect))"),
            // A tag that answers the plain probe the same way on both sides has
            // said nothing, and must not be scored either way.
            .require(
                "the two answers differ, so the SELECT's effect is observable",
                refusedInSession != acceptedAfter || insideSession != afterSelect
            ),
            .require(
                "the EV2 session did NOT survive the probe's SELECT, as measured on 2026-09-20 "
                    + "(refused in session: \(refusedInSession), accepted after: \(acceptedAfter))",
                refusedInSession && acceptedAfter
            ),
        ])
    })

    // Cleanup: disable any AES protection FIRST (the shared Type-2 cleanup skips
    // Type-4, so a protected file would otherwise fail the erase), then reuse the
    // Type-2 cleanup which for 424 degrades to erase-NDEF + verify — the
    // factory-blank target.
    let cleanup = [
        TagTestStep("cleanup.t4unprotect", "Remove any AES protection", safety: .reversibleWrite) { tag, ctx in
            let protectedNow = await ((try? tag.readProtectionState()) ?? nil)?.passwordProtect ?? false
            guard protectedNow else { return .pass("already unprotected") }
            guard await type4ClearProtection(tag, ctx.credentials) else {
                return .require(
                    "protection still present after disable. Clear it via the enforcement check's Disable button",
                    false
                )
            }
            return .pass("protection removed")
        },
    ] + CleanupSteps.type2(profile)
    return TagTestPlan(profile: profile, credentials: credentials, steps: steps, cleanup: cleanup)
}

// MARK: - ISO 15693 / ICODE SLIX (Type-5)

/// ISO 15693 "high data rate, no addressing" — the flag every preset, the
/// protection client and the simulator use.
private let t5Flag: UInt8 = 0x02

/// Send a `[flag, opcode, params…]` Type-5 frame and return the payload after the
/// leading status byte, or throw on the `01 ‖ code` error frame. Both the live
/// transport and the simulator produce this shape, which is what makes a
/// divergence here meaningful.
private func t5Send(_ tag: any ConnectedTag, _ bytes: [UInt8], _ name: String) async throws -> Data {
    let response = try await tag.transceive(RawCommand(bytes: Data(bytes), name: name))
    guard response.first == 0x00 else {
        throw TagError.protocolError(
            "\(name) refused",
            diagnostics: "cmd=\(Data(bytes).hexString) resp=\(response.hexString)"
        )
    }
    return response.dropFirst()
}

private func t5ReadBlock(_ tag: any ConnectedTag, _ block: UInt8) async throws -> Data {
    let payload = try await t5Send(tag, [t5Flag, Iso15693Opcode.readSingleBlock, block], "READ_SINGLE_BLOCK b\(block)")
    guard payload.count >= 4 else {
        throw TagError.malformedResponse(payload, diagnostics: "short block read b\(block)")
    }
    return payload.prefix(4)
}

private func t5WriteBlock(_ tag: any ConnectedTag, _ block: UInt8, _ bytes: Data) async throws {
    _ = try await t5Send(
        tag,
        [t5Flag, Iso15693Opcode.writeSingleBlock, block] + [UInt8](bytes),
        "WRITE_SINGLE_BLOCK b\(block)"
    )
}

/// Decoded `GET_SYSTEM_INFORMATION` payload (everything after the status byte):
/// `infoFlags(1) ‖ UID(8) ‖ DSFID(1) ‖ AFI(1) ‖ blocks-1(1) ‖ blockSize-1(1) ‖ ICRef(1)`.
/// Both the live transport (`CoreNFCSession.encodeSystemInfo`) and the simulator
/// emit exactly this, which is what makes the field checks below meaningful.
private struct T5SystemInfo {
    let infoFlags: UInt8
    let uid: Data
    let dsfid: UInt8
    let afi: UInt8
    let blockCount: Int
    let blockSize: Int
    let icReference: UInt8

    init(payload: Data) throws {
        let b = [UInt8](payload)
        guard b.count >= 14 else {
            throw TagError.malformedResponse(payload, diagnostics: "short system info: \(payload.hexString)")
        }
        infoFlags = b[0]
        uid = Data(b[1 ... 8])
        dsfid = b[9]
        afi = b[10]
        blockCount = Int(b[11]) + 1
        blockSize = Int(b[12]) + 1
        icReference = b[13]
    }

    /// Bit 2 of the info flags — memory size present.
    var hasMemorySize: Bool {
        infoFlags & 0x04 != 0
    }
}

private func t5SystemInfo(_ tag: any ConnectedTag) async throws -> T5SystemInfo {
    try await T5SystemInfo(payload: t5Send(
        tag,
        [t5Flag, Iso15693Opcode.getSystemInformation],
        "GET_SYSTEM_INFORMATION"
    ))
}

func iso15693Plan(_ profile: ChipProfile, _ credentials: TagTestCredentials) -> TagTestPlan {
    var steps: [TagTestStep] = []

    steps.append(TagTestStep("t5.identify", "Identify (system info)", safety: .readOnly) { tag, ctx in
        let familyIsType5 = if case .type5 = tag.chip?.family {
            true
        } else {
            false
        }
        let layout = tag.chip?.memoryLayout
        return .all([
            .expect("session chip id", tag.chip?.id.description ?? "nil", equals: ctx.profile.id.description),
            .require("family is Type-5", familyIsType5),
            // Geometry comes from the tag's own GET_SYSTEM_INFORMATION when the
            // read succeeds, so this reports what the silicon claims rather than
            // the datasheet estimate. A SLIX2 should report ~80 blocks where a
            // plain SLIX reports 28.
            .pass("geometry \(layout?.pageCount ?? 0) blocks × \(layout?.pageSize ?? 0)B"),
        ])
    })

    // GET_SYSTEM_INFORMATION over the raw transport. This throws
    // `capabilityUnsupported` on any build whose ISO 15693 mapping is incomplete,
    // and cross-checks the decoded geometry against the profile the identifier
    // built from the same command. The IC-reference byte is surfaced because the
    // catalog deliberately does not yet assert a SLIX/SLIX2/SLIX-S/SLIX-L variant
    // — no datasheet-verified value lives in the repo, and a live tap is what
    // supplies the first one.
    steps
        .append(TagTestStep("t5.systemInfo", "System information", safety: .readOnly,
                            requires: .rawTransceive)
        { tag, ctx in
            let info = try await t5SystemInfo(tag)
            var checks: [TagStepCheck] = [
                .require(
                    "memory-size field present (infoFlags=0x\(String(format: "%02X", info.infoFlags)))",
                    info.hasMemorySize
                ),
                .expect("block size", info.blockSize, equals: ctx.profile.memoryLayout.pageSize),
                .pass(
                    "IC reference 0x\(String(format: "%02X", info.icReference)). Record this to pin the ICODE variant"
                ),
                .pass("DSFID 0x\(String(format: "%02X", info.dsfid)) · AFI 0x\(String(format: "%02X", info.afi))"),
            ]
            // The identifier builds the profile from this same command, so the two
            // must agree — a mismatch means the decode paths have drifted.
            if ctx.profile.memoryLayout.pageCount > 0 {
                checks.append(.expect(
                    "block count agrees with profile",
                    info.blockCount,
                    equals: ctx.profile.memoryLayout.pageCount
                ))
            }
            return .all(checks)
            })

    // Capability Container. A factory ICODE ships with block 0 all-zero and is
    // NOT NDEF-formatted — CoreNFC refuses every content NDEF write against it.
    // Record which state we're in so the following steps behave accordingly.
    steps
        .append(TagTestStep("t5.ccVerify", "Capability Container", safety: .readOnly,
                            requires: .rawTransceive)
        { tag, ctx in
            let cc = try await t5ReadBlock(tag, 0)
            guard Type5CC.isFormatted(cc) else {
                ctx.scratch["t5.cc.virgin"] = Data([0x01])
                return .pass("block 0 blank (\(cc.hexString)). Factory-unformatted, the t5.format step writes a CC")
            }
            var checks: [TagStepCheck] = [.expect("CC magic", cc[cc.startIndex], equals: Type5CC.magic)]
            if let expected = ctx.profile.factoryType5CC {
                // Unlike Type-2, block 0 is rewritable, so a mismatch is a warning
                // about how the tag was formatted, not an unfixable corruption.
                if cc == expected {
                    checks.append(.pass("CC matches this geometry's canonical \(expected.hexString)"))
                } else {
                    checks
                        .append(
                            .pass(
                                "CC \(cc.hexString) differs from canonical \(expected.hexString). Formatted elsewhere, still valid"
                            )
                        )
                }
            }
            return .all(checks)
            })

    // Format a virgin tag, then restore block 0. Type-5 blocks are rewritable
    // (unlike the Type-2 OTP page), so this is genuinely reversible and belongs
    // in the batch — it is the only automated coverage the Type-5 formatter gets.
    steps.append(TagTestStep(
        "t5.format",
        "Write Capability Container",
        safety: .reversibleWrite,
        requires: [.rawTransceive, .formatCC]
    ) { tag, ctx in
        guard let cc = ctx.profile.factoryType5CC else {
            return .pass("geometry unknown. No canonical CC to write")
        }
        let original = try await t5ReadBlock(tag, 0)
        let originalBlock1 = try await t5ReadBlock(tag, 1)
        let wasVirgin = ctx.scratch["t5.cc.virgin"] != nil

        try await Type5Formatter(transceive: { try await tag.transceive($0) }).format(cc: cc)
        let readBack = try await t5ReadBlock(tag, 0)
        var checks: [TagStepCheck] = [.expectHex("CC written", readBack, equals: cc)]

        // An NDEF read must now succeed where a virgin tag refused it.
        if wasVirgin {
            let message = try await tag.readNDEF()
            checks.append(.require("NDEF readable once formatted", NDEFCodec.isEmptyMessage(message)))
            // Leave it formatted: that IS the reusable blank state for Type-5,
            // and the NDEF steps below need it.
            checks.append(.pass("left formatted: the reusable blank state for Type-5"))
        } else {
            // Tag arrived formatted: put back exactly what was there.
            try await t5WriteBlock(tag, 0, original)
            try await t5WriteBlock(tag, 1, originalBlock1)
            checks.append(.pass("original CC restored"))
        }
        return .all(checks)
    })

    // The app's core feature, and until now completely untested on Type-5: the
    // suite only ever erased NDEF in cleanup, which is the one write CoreNFC
    // forgives on an unformatted tag.
    steps.append(TagTestStep("t5.ndef", "NDEF round-trip", safety: .reversibleWrite, requires: [
        .ndefRead,
        .ndefWrite,
    ]) { tag, ctx in
        ctx.scratch["t5.ndef.original"] = try await tag.readNDEF()
        try await tag.writeNDEF([.text(TextRecord(text: "HEXNFC", languageCode: "en"))])
        let records = try await NDEFCodec.decode(tag.readNDEF())
        var text = "<none>"
        if case .text(let r)? = records.first {
            text = r.text
        }
        let check = TagStepCheck.expect("NDEF text", text, equals: "HEXNFC")
        try await restoreNDEF(tag, from: "t5.ndef.original", ctx: ctx)
        return check
    })

    // Single-block read/write round-trip on a user block (block 2), then restore.
    // ISO 15693 addresses memory by 4-byte block via READ/WRITE_SINGLE_BLOCK
    // (0x20/0x21). The Type-2 readMemory/writeMemory page path does NOT work on a
    // real .iso15693 tag — it routes through the MIFARE transport and throws — so
    // we speak the block commands directly, using the [flag, opcode, block, …]
    // framing (flag 0x02 = high data rate, no addressing) the SLIX protection
    // client uses live and the simulator mirrors. Response is [0x00] ‖ data.
    if profile.capabilities.contains(.memoryWrite) {
        let block: UInt8 = 2 // a free user block (block 0 is the CC)
        steps.append(TagTestStep(
            "t5.block",
            "Block read/write round-trip",
            safety: .reversibleWrite,
            requires: [.memoryRead, .memoryWrite]
        ) { tag, _ in
            // NOTE: the Type-2 `readMemory`/`writeMemory` page path does NOT work
            // on a real .iso15693 tag — it routes through the MIFARE transport and
            // throws — so speak the block commands directly, exactly as the SLIX
            // protection client does live and the simulator mirrors.
            let original = try await t5ReadBlock(tag, block)
            let probe = Data([0xDE, 0xAD, 0xBE, 0xEF])
            try await t5WriteBlock(tag, block, probe)
            let readBack = try await t5ReadBlock(tag, block)
            try await t5WriteBlock(tag, block, original) // restore
            return .expectHex("block round-trip", readBack, equals: probe)
        })
    }

    // READ_MULTIPLE_BLOCKS must agree with the equivalent single reads. This is
    // one of the opcodes that had no live transport mapping at all, so it worked
    // against the simulator and threw `capabilityUnsupported` on a real tag.
    steps.append(TagTestStep(
        "t5.multiBlock",
        "Multi-block read",
        safety: .readOnly,
        requires: [.rawTransceive, .memoryRead]
    ) { tag, ctx in
        let count = min(4, max(2, ctx.profile.memoryLayout.pageCount))
        let payload = try await t5Send(
            tag, [t5Flag, Iso15693Opcode.readMultipleBlocks, 0x00, UInt8(count - 1)], "READ_MULTIPLE_BLOCKS"
        )
        guard payload.count >= count * 4 else {
            throw TagError.malformedResponse(payload, diagnostics: "expected \(count * 4)B, got \(payload.count)B")
        }
        var singles = Data()
        for block in 0 ..< count {
            try await singles.append(t5ReadBlock(tag, UInt8(block)))
        }
        return .expectHex("multi-block == singles", payload.prefix(count * 4), equals: singles)
    })

    // Per-block lock status. A tag that reports blocks already locked can't be
    // restored by the reversible steps above, so this is worth knowing early.
    steps
        .append(TagTestStep("t5.securityStatus", "Block security status", safety: .readOnly,
                            requires: .rawTransceive)
        { tag, ctx in
            let count = min(4, max(2, ctx.profile.memoryLayout.pageCount))
            let payload = try await t5Send(
                tag, [t5Flag, Iso15693Opcode.getMultipleBlockSecurityStatus, 0x00, UInt8(count - 1)],
                "GET_MULTIPLE_BLOCK_SECURITY_STATUS"
            )
            guard payload.count >= count else {
                throw TagError.malformedResponse(
                    payload,
                    diagnostics: "expected \(count) status bytes, got \(payload.count)"
                )
            }
            let locked = [UInt8](payload.prefix(count)).enumerated().filter { $0.element & 0x01 != 0 }.map(\.offset)
            return .require("blocks 0..<\(count) unlocked (locked: \(locked))", locked.isEmpty)
            })

    // CAPTURE ONLY, and last of the read-only steps.
    //
    // It asserts nothing and cannot: every check is a `.pass`, and its one frame
    // goes out under `try?`. A step that records a first observation has no
    // business failing a suite over what it finds, and this one runs on chips
    // whose answer is not known in advance.
    //
    // What it is for. `GET NXP SYSTEM INFORMATION` (ABh, SL2S2602 §9.5.3.18)
    // carries the entire Type-5 protection read-back verdict:
    // `Iso15693ProtectionClient.verifyPageProtection` decides from its Table-71
    // answer whether a `PROTECT PAGE` took, and `readProtectionState` answers
    // from it before falling back to a behavioural probe that puts a write on
    // the air. No capture in this repo shows a real SLIX2 answering ABh, and the
    // production parser and `Iso15693Simulator` were written from the same
    // reading of Table 71, so their agreeing in CI is evidence about the reading
    // rather than about silicon. One live tap that records the raw bytes settles
    // it. See `docs/internal/unverified-behaviour.md` T5-1.
    //
    // Why the placement is safe. The frame is the production frame: the same
    // opcode constant, sent with the plain non-addressed flag, because ABh is
    // not in `Iso15693Opcode.requiresAddressedOrSelectedMode` and the client
    // sends it unaddressed. No `SELECT` goes out, so the activation state the
    // following steps meet is the state they met before this step existed and
    // the hardware-validated Type-5 baselines still describe this run. It is
    // still ordered last among the read-only steps, because a first observation
    // is the step most likely to be wrong about what it costs.
    steps.append(TagTestStep(
        "t5.gateState",
        "NXP system information (capture only)",
        safety: .readOnly,
        requires: .rawTransceive
    ) { tag, _ in
        guard let payload = try? await t5Send(
            tag,
            [t5Flag, Iso15693Opcode.getNXPSystemInformation],
            "GET_NXP_SYSTEM_INFORMATION"
        ) else {
            return .pass(
                "not witnessed: no Table-71 answer to ABh. Expected on any Type-5 that is not a SLIX2, "
                    + "and the state production treats as a lost read-back rather than a fault"
            )
        }
        let bytes = [UInt8](payload)
        var checks: [TagStepCheck] = [
            .pass("ABh answered \(payload.count)B after the status byte: \(payload.hexString)"),
            .pass("Table 71 predicts 7B here (PP pointer · PP conditions · lock bits · 4 feature-flag bytes)"),
        ]
        if bytes.count >= 3 {
            // The three fields production reads, spelled out so a report can be
            // compared against the datasheet without decoding hex by hand. None
            // of them is a secret: a pointer, an access-condition byte and the
            // lock bits.
            checks.append(.pass(
                "read as Table 71: PP pointer 0x\(String(format: "%02X", bytes[0])) "
                    + "· PP conditions 0x\(String(format: "%02X", bytes[1])) "
                    + "· lock bits 0x\(String(format: "%02X", bytes[2]))"
            ))
        } else {
            checks.append(.pass(
                "shorter than Table 71's three fixed fields, so the shape this app parses does not hold"
            ))
        }
        return .all(checks)
    })

    // AFI / DSFID round-trip. Both are single writable bytes with their own
    // irreversible LOCK commands (0x28 / 0x2A) — those are never batched.
    steps.append(TagTestStep(
        "t5.afiDsfid",
        "AFI + DSFID round-trip",
        safety: .reversibleWrite,
        requires: .rawTransceive
    ) { tag, _ in
        let before = try await t5SystemInfo(tag)

        _ = try await t5Send(tag, [t5Flag, Iso15693Opcode.writeAFI, 0x5A], "WRITE_AFI")
        _ = try await t5Send(tag, [t5Flag, Iso15693Opcode.writeDSFID, 0xA5], "WRITE_DSFID")
        let after = try await t5SystemInfo(tag)
        var checks: [TagStepCheck] = [
            .expect("AFI", String(format: "%02X", after.afi), equals: "5A"),
            .expect("DSFID", String(format: "%02X", after.dsfid), equals: "A5"),
        ]
        // Restore whatever the tag arrived with.
        _ = try await t5Send(tag, [t5Flag, Iso15693Opcode.writeAFI, before.afi], "WRITE_AFI (restore)")
        _ = try await t5Send(tag, [t5Flag, Iso15693Opcode.writeDSFID, before.dsfid], "WRITE_DSFID (restore)")
        checks.append(.pass("AFI/DSFID restored to \(String(format: "%02X/%02X", before.afi, before.dsfid))"))
        return .all(checks)
    })

    // SLIX write-password protection is intentionally EXCLUDED from the
    // non-destructive batch, but NOT for the reason this comment used to give.
    //
    // The old claim was that the gate latches. It does not: `PROTECT PAGE` (B6h)
    // with status 00h returns the tag to Public, and stays available until
    // `LOCK PAGE PROTECTION CONDITION` (B7h), which this app never sends. That
    // was corrected on 2026-08-07; see CLAUDE.md and
    // `docs/internal/chip-config-pages.md` section ICODE SLIX2.
    //
    // The real reason is that the *password* is unclearable without DESTROY, so
    // the tag leaves the run carrying a credential rather than none. Removal now
    // resets it to the delivered-IC value (00 00 00 00) so the tag stays
    // protectable, and the gate read-back proves the access conditions really
    // did return to Public. It stays out of the batch because it needs two taps
    // and a persistent credential, so it lives in the gated, one-at-a-time flow
    // instead (`IrreversibleOpsFlowModel.slixPasswordLatch`).

    var cleanup: [TagTestStep] = []
    // Undo any still-armed protection (mid-suite abort safety net).
    cleanup
        .append(TagTestStep("cleanup.unprotect", "Clear any programmed password",
                            safety: .reversibleWrite)
        { tag, ctx in
            guard let armed = ctx.armedProtection else { return .pass("nothing armed") }
            try await tag.disableProtection(using: armed.credential)
            ctx.armedProtection = nil
            return .pass("password reset")
            })
    if profile.capabilities.contains(.ndefWrite) {
        cleanup.append(TagTestStep(
            "cleanup.eraseNDEF",
            "Erase NDEF to blank",
            safety: .reversibleWrite,
            requires: .ndefWrite
        ) { tag, _ in
            try await tag.writeNDEF([])
            return .pass("NDEF erased")
        })
    }
    cleanup.append(TagTestStep("cleanup.verify", "Verify blank", safety: .readOnly) { tag, _ in
        guard tag.capabilities.contains(.ndefRead),
              let msg = try? await tag.readNDEF() else { return .pass("nothing to verify") }
        return .require("blank NDEF", NDEFCodec.isEmptyMessage(msg))
    })

    return TagTestPlan(profile: profile, credentials: credentials, steps: steps, cleanup: cleanup)
}

// MARK: - FeliCa / Suica (transit, read-only)

func felicaPlan(_ profile: ChipProfile, _ credentials: TagTestCredentials) -> TagTestPlan {
    var steps: [TagTestStep] = []

    steps
        .append(TagTestStep("fc.systemCode", "System code + IDm", safety: .readOnly, requires: .transitRead) { tag, _ in
            guard let felica = tag as? FeliCaReadable else {
                throw TagError.capabilityUnsupported(.transitRead, diagnostics: "tag is not FeliCaReadable")
            }
            return .all([
                .expect("system code", String(format: "%04X", felica.systemCode), equals: "0003"),
                .expect("IDm length", felica.idm.count, equals: 8),
            ])
        })

    steps.append(TagTestStep("fc.history", "Read history blocks", safety: .readOnly, requires: .transitRead) { tag, _ in
        guard let felica = tag as? FeliCaReadable else {
            throw TagError.capabilityUnsupported(.transitRead, diagnostics: "tag is not FeliCaReadable")
        }
        // Read the first chunk only — real cards intermittently fail on > 10 blocks.
        let blocks = try await felica.readWithoutEncryption(serviceCode: 0x090F, blocks: 0 ..< 10)
        return .all([
            .expect("block count", blocks.count, equals: 10),
            .require("16-byte blocks", blocks.allSatisfy { $0.count == 16 }),
        ])
    })

    steps.append(TagTestStep("fc.decode", "Decode transit card", safety: .readOnly, requires: .transitRead) { tag, _ in
        guard let felica = tag as? FeliCaReadable else {
            throw TagError.capabilityUnsupported(.transitRead, diagnostics: "tag is not FeliCaReadable")
        }
        guard let card = try await TransitReader().read(felica) else {
            return .require("decodable transit card", false)
        }
        return .all([
            .require("balance non-negative (\(card.balanceYen)¥)", card.balanceYen >= 0),
            // Reporting, not asserting: a card with no journey history is a
            // perfectly good card, so there is no count to require here. This
            // was written as `.require(..., count >= 0)`, which is the same
            // always-true check said in a way `empty_count` mistook for a
            // real one and "fixed" to `isEmpty`, failing every Suica with a
            // history.
            .pass("transactions parsed (\(card.transactions.count))"),
        ])
    })

    // Nothing was written — no cleanup needed.
    return TagTestPlan(profile: profile, credentials: credentials, steps: steps, cleanup: [])
}

// MARK: - MIFARE DESFire (Type-4, identification only)

/// The app's whole DESFire surface is identification plus raw transceive —
/// DESFire keeps data in key-protected applications, not a blind-readable NDEF
/// area, so `ChipProfile` advertises only `.rawTransceive`. This suite is
/// therefore **entirely read-only with no cleanup**, which is the correct shape
/// for the feature set rather than a shortcut: there is nothing to write back.
///
/// Native (unwrapped) command forms throughout — that is what iOS's
/// `sendMiFareCommand` puts on the wire for a DESFire, and what
/// `MiFareTagIdentifier` uses. The status byte leads (`AF …`), unlike the
/// wrapped APDU form used for NTAG424 (`… 91 AF`).
func desfirePlan(_ profile: ChipProfile, _ credentials: TagTestCredentials) -> TagTestPlan {
    var steps: [TagTestStep] = []

    steps.append(TagTestStep("df.identify", "Identify (generation)", safety: .readOnly) { tag, ctx in
        let isDESFire: Bool = {
            if case .type4(let v) = tag.chip?.family {
                return v == .desfireEV1 || v == .desfireEV2 || v == .desfireEV3 || v == .desfireGeneric
            }
            return false
        }()
        return .all([
            .expect("session chip id", tag.chip?.id.description ?? "nil", equals: ctx.profile.id.description),
            .require("family is DESFire", isDESFire),
            .pass("storage \(tag.chip?.memoryLayout.byteCount ?? 0) B"),
            .require("only rawTransceive advertised", tag.capabilities == [.rawTransceive]),
        ])
    })

    // The full 3-frame chain. This is the step that proves the drain logic in
    // `MiFareTagIdentifier.getVersion` works against real chaining: an undrained
    // chain makes the *next* native command answer COMMAND_ABORTED, which is how
    // a re-scan or an authenticate straight after identify breaks.
    steps
        .append(TagTestStep("df.version", "GET_VERSION chain (3 frames)", safety: .readOnly,
                            requires: .rawTransceive)
        { tag, ctx in
            let first = try await tag.transceive(RawCommand(bytes: Data([0x60]), name: "GET_VERSION"))
            guard first.count >= 8 else {
                throw TagError.malformedResponse(first, diagnostics: "short GET_VERSION frame 1")
            }
            var checks: [TagStepCheck] = [
                .expect("frame 1 status", String(format: "%02X", first[first.startIndex]), equals: "AF"),
                .expect(
                    "decodes to this chip",
                    ChipCatalog.identify(desFireVersion: first)?.id.description ?? "nil",
                    equals: ctx.profile.id.description
                ),
            ]
            // Drain the chain, exactly as production does, and confirm it terminates.
            var frame = first
            var continuations = 0
            while frame.first == 0xAF, continuations < 4 {
                frame = try await tag.transceive(RawCommand(bytes: Data([0xAF]), name: "GET_VERSION (cont.)"))
                continuations += 1
            }
            checks.append(.require("chain drained in \(continuations) continuation(s)", continuations >= 1))
            checks.append(.expect("final frame status", String(format: "%02X", frame.first ?? 0xFF), equals: "00"))
            // The last frame carries UID ‖ batch ‖ production date; the UID must be
            // the tag we're talking to.
            if frame.count >= 8 {
                checks.append(.expectHex(
                    "UID from GET_VERSION",
                    frame.subdata(in: (frame.startIndex + 1) ..< (frame.startIndex + 8)),
                    equals: tag.uid
                ))
            }
            // With the chain closed, a following native command must NOT answer
            // COMMAND_ABORTED — that is the whole point of draining.
            let after = try await tag.transceive(RawCommand(
                bytes: Data([0x6E]),
                name: "GetFreeMemory (post-chain)"
            ))
            checks.append(.require(
                "next command not aborted (got \(after.prefix(1).hexString))",
                after.first != 0xCA
            ))
            return .all(checks)
            })

    // Does this card host an NDEF application? A factory EV3 does not (`6A 82`);
    // a personalised one may. Both are valid — the point is a clean answer.
    steps.append(TagTestStep(
        "df.selectNDEFApp",
        "SELECT NDEF application",
        safety: .readOnly,
        requires: .rawTransceive
    ) { tag, _ in
        let response = try await tag.transceive(RawCommand(
            bytes: Data([0x00, 0xA4, 0x04, 0x00, 0x07, 0xD2, 0x76, 0x00, 0x00, 0x85, 0x01, 0x01, 0x00]),
            name: "SELECT NDEF app"
        ))
        let sw = Array(response.suffix(2))
        guard sw.count == 2 else {
            throw TagError.malformedResponse(response, diagnostics: "no status word: \(response.hexString)")
        }
        switch (sw[0], sw[1]) {
        case (0x90, 0x00), (0x91, 0x00):
            return .pass("NDEF application present. This card is NDEF-capable")

        case (0x6A, 0x82), (0x91, 0xA0):
            return .pass("no NDEF application (sw=\(Data(sw).hexString)). Expected on a factory or transit card")

        default:
            return .require("SELECT answered a recognised status word (got \(Data(sw).hexString))", false)
        }
    })

    steps
        .append(TagTestStep("df.appIDs", "List applications", safety: .readOnly, requires: .rawTransceive) { tag, ctx in
            let response = try await tag.transceive(RawCommand(bytes: Data([0x6A]), name: "GetApplicationIDs"))
            guard let status = response.first else {
                throw TagError.malformedResponse(response, diagnostics: "empty GetApplicationIDs")
            }
            // A card whose master application requires authentication refuses the
            // plain listing — valid, and worth recording rather than failing.
            guard status == 0x00 || status == 0xAF else {
                return .pass(
                    "listing refused (status \(String(format: "%02X", status))). Master application is key-gated"
                )
            }
            let payload = response.dropFirst()
            guard payload.count % 3 == 0 else {
                throw TagError.malformedResponse(response, diagnostics: "AID list is not a multiple of 3 bytes")
            }
            let aids = stride(from: 0, to: payload.count, by: 3).map { offset -> String in
                payload.dropFirst(offset).prefix(3).hexString
            }
            // Stash the count so the free-memory step can report a number that means
            // something — free EEPROM is only interpretable against how much has been
            // allocated to applications.
            ctx.scratch["df.appCount"] = Data([UInt8(min(aids.count, 255))])
            return .pass("\(aids.count) application(s)\(aids.isEmpty ? "" : ": \(aids.joined(separator: ", "))")")
        })

    // `GetFreeMemory` reports the card's free EEPROM **pool**, which is NOT
    // bounded by the GET_VERSION storage size — that byte is the advertised
    // product tier (`0x18` → 2^12 = "4K"), not a ceiling on the pool.
    //
    // Live-verified 2026-08-05 across three DESFire EV3 4K cards:
    //
    //   | card            | applications | free   |
    //   |-----------------|--------------|--------|
    //   | blank ×2        | 0            | 5120 B |
    //   | Myki (transit)  | 2            | 3200 B |
    //
    // The blank cards show the untouched pool (above the 4096 B tier); the Myki
    // shows the same pool minus 1920 B of application allocations (below it). An
    // earlier version asserted `free <= capacity`, which the Myki passed only
    // incidentally and both blank cards failed — and the simulator's fabricated
    // 3808 B satisfied it in CI. So assert only what is sourceable, and report
    // the figure against the application count, without which it means nothing.
    steps.append(TagTestStep("df.freeMemory", "Free memory", safety: .readOnly, requires: .rawTransceive) { tag, ctx in
        let response = try await tag.transceive(RawCommand(bytes: Data([0x6E]), name: "GetFreeMemory"))
        guard let status = response.first else {
            throw TagError.malformedResponse(response, diagnostics: "empty GetFreeMemory")
        }
        guard status == 0x00, response.count >= 4 else {
            return .pass(
                "GetFreeMemory unavailable (status \(String(format: "%02X", status))). Not on every generation"
            )
        }
        let b = [UInt8](response.dropFirst())
        let free = Int(b[0]) | Int(b[1]) << 8 | Int(b[2]) << 16
        let capacity = ctx.profile.memoryLayout.byteCount
        let apps = ctx.scratch["df.appCount"]?.first.map(Int.init)
        var checks: [TagStepCheck] = [
            .require("free memory is non-zero (\(free) B)", free > 0),
            .pass(
                "free \(free) B · \(apps.map { "\($0) application(s)" } ?? "app count unknown") · \(capacity) B advertised tier"
            ),
        ]
        // DESFire allocates in 32-byte blocks, so a free-byte count should land on
        // a 32-byte boundary (5120 = 160 blocks, 3200 = 100). A value that doesn't
        // is the signature of a byte-order or framing mistake in the decode above,
        // but only two cards have been measured — note it rather than fail on it.
        if free % 32 != 0 {
            checks
                .append(
                    .pass(
                        "free memory is not a multiple of 32 B: unexpected for DESFire's 32-byte allocation; check the LE decode"
                    )
                )
        }
        return .all(checks)
    })

    // The app's opportunistic behaviour: `readNDEF()` is attempted on any tag.
    // On a DESFire without an NDEF application it must fail *cleanly* as
    // `capabilityUnsupported` (CoreNFC's `queryNDEFStatus` → `.notSupported`),
    // never as a transport error that would look like tag loss to the scan flow.
    steps.append(TagTestStep("df.ndefProbe", "Opportunistic NDEF probe", safety: .readOnly) { tag, _ in
        do {
            let message = try await tag.readNDEF()
            if NDEFCodec.isEmptyMessage(message) {
                return .pass("NDEF readable, zero records")
            }
            let records = try NDEFCodec.decode(message)
            return .require("NDEF message decodes (\(records.count) record(s))", !records.isEmpty)
        } catch let error as TagError {
            if case .capabilityUnsupported = error.kind {
                return .pass("no NDEF application: refused cleanly as capabilityUnsupported")
            }
            return .require("NDEF probe failed with \(error.kind) rather than capabilityUnsupported", false)
        }
    })

    // Nothing was written — no cleanup.
    return TagTestPlan(profile: profile, credentials: credentials, steps: steps, cleanup: [])
}

// MARK: - ePassport (eMRTD, Type-4, read-only)

/// Read-only passport plan: confirm identification, then run the full BAC read
/// against the specimen access key. On the simulator this exercises SELECT →
/// BAC → secure messaging → DG decode end to end (the anti-drift guard). Live,
/// the specimen key only unlocks the specimen chip — real passports are read
/// through the app with the holder's own MRZ, not this shared plan.
func ePassportPlan(_ profile: ChipProfile, _ credentials: TagTestCredentials) -> TagTestPlan {
    var steps: [TagTestStep] = []

    steps
        .append(TagTestStep("mrtd.identify", "Identify ePassport", safety: .readOnly,
                            requires: .epassportRead)
        { tag, ctx in
            .all([
                .expect("session chip id", tag.chip?.id.description ?? "nil", equals: ctx.profile.id.description),
                .require("advertises epassportRead", tag.capabilities.contains(.epassportRead)),
                .require("is EPassportReadable", tag is EPassportReadable),
            ])
            })

    steps.append(TagTestStep("mrtd.read", "BAC read DG1 + DG2", safety: .readOnly, requires: .epassportRead) { tag, _ in
        guard let passport = tag as? EPassportReadable else {
            throw TagError.capabilityUnsupported(.epassportRead, diagnostics: "tag is not EPassportReadable")
        }
        // Specimen access key (ICAO Doc 9303 "Anna Eriksson"); matches the sim.
        let mrz = PassportMRZ(documentNumber: "L898902C", dateOfBirth: "690806", dateOfExpiry: "940623")
        let data = try await EPassportReader().read(passport, mrz: mrz)
        return .all([
            .expect("document number", data.documentNumber, equals: "L898902C"),
            .expect("surname", data.primaryIdentifier, equals: "ERIKSSON"),
            .require("face image present", data.faceImage != nil),
        ])
    })

    // Read-only — no cleanup.
    return TagTestPlan(profile: profile, credentials: credentials, steps: steps, cleanup: [])
}
