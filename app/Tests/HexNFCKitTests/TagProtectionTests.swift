@testable import HexNFCKit
@testable import HexNFCRecords
@testable import HexNFCTagSim
import XCTest

/// Coverage for the real "enable password protection" path: the canonical
/// `Type2ConfigLayout` table, and `enable/disablePasswordProtection` driving
/// genuine AUTH0/ACCESS gating through the simulator (the protocol source of
/// truth). The production `CoreNFCConnectedTag` mirrors the same command order;
/// these assertions are what give us confidence before the on-device QA pass.
final class TagProtectionTests: XCTestCase {
    // MARK: - Canonical config-page table

    func test_type2ConfigLayout_matchesDatasheet() {
        func assertLayout(
            _ variant: Type2Variant,
            config0: Int, config1: Int, pwd: Int, pack: Int,
            staticLock: Int, dynamicLock: Int?,
            line: UInt = #line
        ) {
            guard let layout = Type2ConfigLayout.for(variant) else {
                return XCTFail("\(variant) should have a config layout", line: line)
            }
            XCTAssertEqual(layout.config0Page, config0, "\(variant) config0", line: line)
            XCTAssertEqual(layout.config1Page, config1, "\(variant) config1", line: line)
            XCTAssertEqual(layout.pwdPage, pwd, "\(variant) pwd", line: line)
            XCTAssertEqual(layout.packPage, pack, "\(variant) pack", line: line)
            XCTAssertEqual(layout.staticLockPage, staticLock, "\(variant) staticLock", line: line)
            XCTAssertEqual(layout.dynamicLockPage, dynamicLock, "\(variant) dynamicLock", line: line)
        }

        assertLayout(.ntag213, config0: 41, config1: 42, pwd: 43, pack: 44, staticLock: 2, dynamicLock: 40)
        assertLayout(.ntag213TT, config0: 41, config1: 42, pwd: 43, pack: 44, staticLock: 2, dynamicLock: 40)
        assertLayout(.ntag215, config0: 131, config1: 132, pwd: 133, pack: 134, staticLock: 2, dynamicLock: 130)
        assertLayout(.ntag216, config0: 227, config1: 228, pwd: 229, pack: 230, staticLock: 2, dynamicLock: 226)
        // MF0UL11: CFG0=16, CFG1=17, PWD=18, PACK=19, no dynamic lock page.
        assertLayout(
            .mifareUltralightEV1_48,
            config0: 16,
            config1: 17,
            pwd: 18,
            pack: 19,
            staticLock: 2,
            dynamicLock: nil
        )
        assertLayout(
            .mifareUltralightEV1_128,
            config0: 37,
            config1: 38,
            pwd: 39,
            pack: 40,
            staticLock: 2,
            dynamicLock: 36
        )

        // Variants without NTAG21x-style protection have no layout. NTAG 210µ
        // belongs here on hardware grounds, not for want of research: the µ die
        // deletes the four config pages (10h–13h) the plain NTAG210 carries, and
        // its memory stops at 0Fh, so there is physically nowhere to put a PWD.
        for variant in [Type2Variant.emV10, .emV11, .emV16, .ntag424DNA, .ntag210Micro, .unknown] {
            XCTAssertNil(Type2ConfigLayout.for(variant), "\(variant) must not have a Type-2 config layout")
        }
    }

    /// Permanent lock reads its page numbers from `ChipMemoryLayout.lockPages`,
    /// **not** from `Type2ConfigLayout` — locks and passwords are independent
    /// features, and NTAG 210µ has the former without the latter. Pin that every
    /// lock-capable Type-2 chip actually declares a static lock page, since a
    /// missing one now degrades to `capabilityUnsupported` at run time rather
    /// than a compile error.
    func test_everyLockCapableType2Chip_declaresAStaticLockPage() {
        for profile in ChipCatalog.all {
            guard case .type2 = profile.family,
                  profile.capabilities.contains(.permanentLock) else { continue }
            XCTAssertNotNil(
                profile.memoryLayout.lockPages.first,
                "\(profile.id) advertises .permanentLock but declares no lock page"
            )
            // Where a chip has both, the two sources must agree — otherwise
            // permanent lock and password protection would write to different
            // pages on the same silicon.
            if case .type2(let variant) = profile.family,
               let configLayout = Type2ConfigLayout.for(variant)
            {
                XCTAssertEqual(
                    profile.memoryLayout.lockPages.first, configLayout.staticLockPage,
                    "\(profile.id) static lock page disagrees between memoryLayout and Type2ConfigLayout"
                )
            }
        }
    }

    /// NTAG 210µ has no password hardware, so every protection entry point must
    /// refuse rather than silently no-op.
    func test_ntag210Micro_refusesAllPasswordOperations() async throws {
        let simulator = NTAG210MicroSimulator()
        let session = SimulatedSession(chip: simulator)
        let tag = try await session.start(alert: "")

        let protection = try await tag.readProtectionState()
        XCTAssertNil(protection)
        XCTAssertNil(ChipProfile.ntag210Micro.type2ConfigLayout)
        XCTAssertFalse(ChipProfile.ntag210Micro.capabilities.contains(.passwordAuth))

        // PWD_AUTH over the raw transport NAKs rather than returning a PACK.
        let pwdAuth = simulator.handle(command: Data([0x1B, 0x48, 0x45, 0x58, 0x21]))
        XCTAssertEqual(pwdAuth, Data([0x00]), "PWD_AUTH must NAK on a chip with no password block")
    }

    /// Regression guard for the UL-EV1-48 fix: the canonical layout and the
    /// per-chip `ChipMemoryLayout` must agree on the protection pages.
    func test_type2ConfigLayout_consistentWithChipMemoryLayout() {
        let pairs: [(ChipProfile, Type2Variant)] = [
            (.ntag213, .ntag213),
            (.ntag215, .ntag215),
            (.ntag216, .ntag216),
            (.mifareUltralightEV1_48, .mifareUltralightEV1_48),
            (.mifareUltralightEV1_128, .mifareUltralightEV1_128),
        ]
        for (profile, variant) in pairs {
            guard let layout = Type2ConfigLayout.for(variant) else {
                return XCTFail("missing layout for \(variant)")
            }
            XCTAssertEqual(profile.memoryLayout.pwdPage, layout.pwdPage, "\(variant) pwd")
            XCTAssertEqual(profile.memoryLayout.packPage, layout.packPage, "\(variant) pack")
            XCTAssertEqual(profile.memoryLayout.dynamicLockPage, layout.dynamicLockPage, "\(variant) dynamic lock")
            XCTAssertEqual(
                profile.memoryLayout.configPages,
                [layout.config0Page, layout.config1Page],
                "\(variant) config pages"
            )
        }
    }

    // MARK: - enablePasswordProtection (NTAG215)

    func test_enablePasswordProtection_writeOnly_blocksUnauthWritesAllowsReads() async throws {
        let simulator = NTAG215Simulator()
        let tag = try await SimulatedSession(chip: simulator).start(alert: "")
        let pwd = Data([0xCA, 0xFE, 0xBA, 0xBE])
        let pack = Data([0x12, 0x34])

        try await tag.enablePasswordProtection(
            password: pwd, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )

        // Cross a tap boundary before asking what the gate enforces.
        //
        // Enabling protection now proves the credential it just wrote by
        // presenting it once and checking the PACK that comes back, which is the
        // only honest proof available (PWD and PACK read back as zeros). The tag
        // is therefore authenticated when `enable` returns, exactly as a real
        // chip would be: nothing un-authenticates a Type-2 tag short of a new
        // activation. So the enforcement this test is about is only observable
        // after a re-tap, and `beginActivation()` is what a re-tap does.
        simulator.beginActivation()

        // Write-only protection: reads of protected pages still succeed.
        let read = try await tag.readMemory(range: (5 * 4) ..< (6 * 4))
        XCTAssertEqual(read.count, 4)

        // Unauthenticated write to a protected page is rejected.
        await assertThrowsTagError(.authFailedKind) {
            try await tag.writeMemory(at: 5 * 4, bytes: Data([0x01, 0x02, 0x03, 0x04]))
        }

        // After authenticating, the PACK comes back and the write goes through.
        let returnedPack = try await tag.authenticate(password: pwd)
        XCTAssertEqual(returnedPack, pack)
        try await tag.writeMemory(at: 5 * 4, bytes: Data([0x01, 0x02, 0x03, 0x04]))
    }

    func test_enablePasswordProtection_readProtect_blocksReadsUntilAuth() async throws {
        let simulator = NTAG215Simulator()
        let tag = try await SimulatedSession(chip: simulator).start(alert: "")
        let pwd = Data([0x01, 0x02, 0x03, 0x04])

        try await tag.enablePasswordProtection(
            password: pwd, pack: Data([0xAA, 0xBB]), protectFromPage: 4, readProtect: true, authLimit: 0
        )
        // Enable leaves the session authenticated (it proves the credential it
        // wrote), so the gate only bites across a tap boundary.
        simulator.beginActivation()

        await assertThrowsTagError(.authFailedKind) {
            _ = try await tag.readMemory(range: (4 * 4) ..< (5 * 4))
        }

        _ = try await tag.authenticate(password: pwd)
        let bytes = try await tag.readMemory(range: (4 * 4) ..< (5 * 4))
        XCTAssertEqual(bytes.count, 4, "page 4 should be readable after auth")
    }

    func test_enablePasswordProtection_wrongPassword_fails() async throws {
        let tag = try await SimulatedSession(chip: NTAG215Simulator()).start(alert: "")
        try await tag.enablePasswordProtection(
            password: Data([0x11, 0x22, 0x33, 0x44]), pack: Data([0xAA, 0xBB]),
            protectFromPage: 4, readProtect: false, authLimit: 0
        )
        await assertThrowsTagError(.authFailedKind) {
            _ = try await tag.authenticate(password: Data([0xDE, 0xAD, 0xBE, 0xEF]))
        }
    }

    func test_disablePasswordProtection_restoresWritableDefault() async throws {
        let tag = try await SimulatedSession(chip: NTAG215Simulator()).start(alert: "")
        let pwd = Data([0xDE, 0xAD, 0xBE, 0xEF])

        try await tag.enablePasswordProtection(
            password: pwd, pack: Data([0x5A, 0xA5]), protectFromPage: 4, readProtect: true, authLimit: 0
        )
        try await tag.disablePasswordProtection(currentPassword: pwd)

        // Writes work again without authentication…
        try await tag.writeMemory(at: 5 * 4, bytes: Data([0x09, 0x09, 0x09, 0x09]))
        let read = try await tag.readMemory(range: (5 * 4) ..< (6 * 4))
        XCTAssertEqual(read, Data([0x09, 0x09, 0x09, 0x09]))

        // …and the credential is back to the factory default FF:FF:FF:FF / 00:00.
        let pack = try await tag.authenticate(password: Data([0xFF, 0xFF, 0xFF, 0xFF]))
        XCTAssertEqual(pack, Data([0x00, 0x00]))
    }

    // MARK: - MIFARE Ultralight EV1 (exercises the corrected config table)

    func test_enablePasswordProtection_ultralightEV1_48() async throws {
        let simulator = MifareUltralightEV1_48Simulator()
        let tag = try await SimulatedSession(chip: simulator).start(alert: "")
        let pwd = Data([0x11, 0x22, 0x33, 0x44])
        let pack = Data([0x9A, 0xBC])

        try await tag.enablePasswordProtection(
            password: pwd, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        // Enable leaves the session authenticated, so the gate only bites across
        // a tap boundary.
        simulator.beginActivation()

        await assertThrowsTagError(.authFailedKind) {
            try await tag.writeMemory(at: 5 * 4, bytes: Data([0x01, 0x02, 0x03, 0x04]))
        }
        let returnedPack = try await tag.authenticate(password: pwd)
        XCTAssertEqual(returnedPack, pack, "UL-EV1-48 PACK must round-trip through the corrected config pages")
        try await tag.writeMemory(at: 5 * 4, bytes: Data([0x01, 0x02, 0x03, 0x04]))
    }

    // MARK: - readProtectionState (scan-time detection)

    /// The bug this guards: scanning a tag locked elsewhere used to always show
    /// "Off" because the scan never read AUTH0/ACCESS. `readProtectionState`
    /// reports the live state so the editor's Protection card reflects reality.
    func test_readProtectionState_reportsLiveAuth0AndAccess() async throws {
        let tag = try await SimulatedSession(chip: NTAG215Simulator()).start(alert: "")

        // Fresh tag: AUTH0 = 0xFF (past the last page) ⇒ confirmed unprotected.
        let initial = try await tag.readProtectionState()
        XCTAssertEqual(initial, TagProtection.none, "a factory tag should read as unprotected, not nil")
        XCTAssertEqual(initial?.passwordProtect, false)

        // Write-only protection from page 4.
        try await tag.enablePasswordProtection(
            password: Data([0xCA, 0xFE, 0xBA, 0xBE]), pack: Data([0x12, 0x34]),
            protectFromPage: 4, readProtect: false, authLimit: 0
        )
        let writeOnly = try await tag.readProtectionState()
        XCTAssertEqual(writeOnly?.passwordProtect, true)
        XCTAssertEqual(writeOnly?.protectFromPage, 4)
        XCTAssertEqual(writeOnly?.readProtect, false)
        XCTAssertEqual(writeOnly?.authLimit, 0)
        XCTAssertEqual(writeOnly?.hasStoredCredential, false, "the PWD is never recovered from a tag")
    }

    /// Read+write protection (PROT bit), with the config pages themselves gated.
    ///
    /// The state is still establishable before authenticating, and without
    /// spending a NAK. A READ that *starts* below AUTH0 is not refused: the chip
    /// serves what it can and then rolls over to page 0, and that roll-over is
    /// the one positive proof of read protection the transport offers (live
    /// NTAG213, 2026-08-14). So the pre-auth reading is "protected, and the
    /// protection covers reads", with no `protectFromPage`, because the page
    /// AUTH0 names cannot be known without the password. The tag is left awake,
    /// which is what makes the authentication that follows possible at all.
    ///
    /// This used to assert a throw, because the simulator answered
    /// `readProtectionState()` out of its own memory and modelled the refusal as
    /// a NAK. Production reads the pages, so the roll-over is what it sees.
    func test_readProtectionState_detectsReadProtect() async throws {
        let simulator = NTAG216Simulator()
        let tag = try await SimulatedSession(chip: simulator).start(alert: "")
        let pwd = Data([0x01, 0x02, 0x03, 0x04])
        try await tag.enablePasswordProtection(
            password: pwd, pack: Data([0xAA, 0xBB]),
            protectFromPage: 4, readProtect: true, authLimit: 0
        )
        // Enable proves the credential it wrote, so it leaves the tag
        // authenticated. Re-tap to ask what an unauthenticated reader sees.
        simulator.beginActivation()

        // Pre-auth: the config pages are out of reach, and the roll-over says so.
        let preAuth = try await tag.readProtectionState()
        XCTAssertEqual(preAuth?.passwordProtect, true)
        XCTAssertEqual(preAuth?.readProtect, true)
        XCTAssertNil(preAuth?.protectFromPage, "AUTH0 is unreadable without the password")
        XCTAssertFalse(simulator.isHalted, "the roll-over costs no NAK, so the tag is still answering")

        // Post-auth: the config pages read back and report read+write protection.
        _ = try await tag.authenticate(password: pwd)
        let state = try await tag.readProtectionState()
        XCTAssertEqual(state?.passwordProtect, true)
        XCTAssertEqual(state?.readProtect, true)
        XCTAssertEqual(state?.protectFromPage, 4, "AUTH0 reads back once the gate is open")
    }

    /// Disabling protection again reads back as unprotected.
    func test_readProtectionState_afterDisable_isUnprotected() async throws {
        let tag = try await SimulatedSession(chip: NTAG215Simulator()).start(alert: "")
        let pwd = Data([0xDE, 0xAD, 0xBE, 0xEF])
        try await tag.enablePasswordProtection(
            password: pwd, pack: Data([0x5A, 0xA5]), protectFromPage: 4, readProtect: false, authLimit: 0
        )
        try await tag.disablePasswordProtection(currentPassword: pwd)
        let state = try await tag.readProtectionState()
        XCTAssertEqual(state?.passwordProtect, false)
    }

    /// A read-protected tag does not refuse a READ that *starts* below AUTH0 —
    /// it serves the pages it can and then rolls over to page 0. That roll-over
    /// is the only positive proof of read protection the transport offers, and
    /// the app's presence probe is built on it, so the simulator has to produce
    /// it or the probe is untested.
    ///
    /// Live NTAG213, 2026-08-14, `AUTH0 = 04` / `PROT = 1`: `30 03` answered
    /// `E1 10 12 00 | 04 BA 4A 7C | 92 1B 21 90 | 38 48 00 00` — page 3, then
    /// pages 0, 1, 2, where the same tag unprotected answered
    /// `E1 10 12 00 | 03 11 D1 01 | …`.
    func test_readOfPagesAboveAUTH0_rollsOverToPageZero() async throws {
        let chip = NTAG213Simulator()
        let tag = try await SimulatedSession(chip: chip).start(alert: "")
        // Unprotected: pages 3, 4, 5, 6 — the CC followed by real user memory.
        let plain = try await tag.readMemory(range: 12 ..< 28)
        XCTAssertEqual(plain.count, 16)

        try await tag.enablePasswordProtection(
            password: Data([0xFF, 0xFF, 0xFF, 0xFF]), pack: Data([0x00, 0x00]),
            protectFromPage: 4, readProtect: true, authLimit: 0
        )
        // A new activation, so the enable's own authentication is not in play.
        let rescanned = try await SimulatedSession(chip: chip).start(alert: "")
        let rolled = try await rescanned.readMemory(range: 12 ..< 28)
        XCTAssertEqual(rolled.count, 16, "the frame must still be four pages, not a refusal")

        // Pages 0 and 1 are the UID + BCC0, which is what makes the signature
        // recognisable from the UID alone.
        let uid = [UInt8](chip.uid)
        XCTAssertEqual(uid.count, 7)
        let bcc0 = 0x88 ^ uid[0] ^ uid[1] ^ uid[2]
        XCTAssertEqual(
            Data(rolled[4 ..< 12]),
            Data([uid[0], uid[1], uid[2], bcc0, uid[3], uid[4], uid[5], uid[6]]),
            "a read-protected tag must wrap to pages 0 and 1, not serve pages 4 and 5"
        )
        XCTAssertNotEqual(Data(rolled[4 ..< 12]), Data(plain[4 ..< 12]))

        // The addressed page is the one that can still NAK.
        await assertThrowsTagError(.authFailedKind) {
            _ = try await rescanned.readMemory(range: 16 ..< 20)
        }
    }

    /// Chips without NTAG21x-style protection report nil (no detectable state),
    /// distinct from a Type-2 tag that's confirmed unprotected (`.none`).
    func test_readProtectionState_unsupportedChip_returnsNil() async throws {
        let tag = try await SimulatedSession(chip: UnknownType2Simulator()).start(alert: "")
        let state = try await tag.readProtectionState()
        XCTAssertNil(state)
    }

    // MARK: - Capability gating

    func test_enablePasswordProtection_unsupportedChip_throws() async throws {
        let tag = try await SimulatedSession(chip: UnknownType2Simulator()).start(alert: "")
        await assertThrowsTagError(.capabilityUnsupportedKind) {
            try await tag.enablePasswordProtection(
                password: Data([0x00, 0x00, 0x00, 0x00]), pack: Data([0x00, 0x00]),
                protectFromPage: 4, readProtect: false, authLimit: 0
            )
        }
    }

    // MARK: - Helpers

    private enum ExpectedKind { case authFailedKind, capabilityUnsupportedKind, lockedPermanentKind }

    private func assertThrowsTagError(
        _ expected: ExpectedKind,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected a TagError but none was thrown", file: file, line: line)
        } catch let error as TagError {
            switch (expected, error.kind) {
            case (.authFailedKind, .authFailed),
                 (.capabilityUnsupportedKind, .capabilityUnsupported),
                 (.lockedPermanentKind, .lockedPermanent):
                break

            default:
                XCTFail("expected \(expected) but got \(error.kind)", file: file, line: line)
            }
        } catch {
            XCTFail("expected a TagError but got \(error)", file: file, line: line)
        }
    }
}
