@testable import HexNFCKit
@testable import HexNFCRecords
@testable import HexNFCTagSim
import XCTest

/// Coverage for the family-agnostic protection surface added in Phase 2: the
/// `backendStyle` gate, the `ProtectionSpec.make` builder, and the default
/// `enableProtection`/`disableProtection` forwarding to the existing Type-2 path
/// (no Type-2 logic is duplicated).
final class ProtectionSpecTests: XCTestCase {
    // MARK: backendStyle gate

    func test_backendStyle_offeredForType2WithLayoutAndPasswordAuth() {
        guard case .type2? = ProtectionStyle.backendStyle(for: .type2(.ntag215), capabilities: [.passwordAuth]) else {
            return XCTFail("Type-2 + passwordAuth should offer .type2")
        }
    }

    func test_backendStyle_nilWithoutPasswordAuth() {
        XCTAssertNil(ProtectionStyle.backendStyle(for: .type2(.ntag215), capabilities: [.ndefWrite]))
    }

    func test_backendStyle_nilForType2VariantWithoutLayout() {
        // EM variants are Type-2 but have no NTAG21x-style config layout.
        XCTAssertNil(ProtectionStyle.backendStyle(for: .type2(.emV10), capabilities: [.passwordAuth]))
    }

    /// Type-4 (NTAG424 DNA) and Type-5 (ICODE SLIX) backends are both wired now.
    /// SLIX is matched on the *family* (`.type5(.icodeSlix)`), not on the
    /// `.passwordAuth` capability alone — that's what keeps the SLIX gotcha closed
    /// (a stray Type-5 chip advertising `.passwordAuth` still gates to nil).
    func test_backendStyle_type4AndType5Wired_othersGated() {
        guard case .type4? = ProtectionStyle.backendStyle(for: .type4(.ntag424DNA), capabilities: [.passwordAuth])
        else {
            return XCTFail("Type-4 backend should be wired")
        }
        guard case .type5? = ProtectionStyle.backendStyle(for: .type5(.icodeSlix2), capabilities: [.passwordAuth])
        else {
            return XCTFail("Type-5 (ICODE SLIX2) backend should be wired")
        }
        // ...and the 28-block group must NOT be, even if something hands it the
        // capability. `.icodeSlix` covers SLI, SLIX, SLIX-S and SLIX-L
        // indistinguishably, and only the 80-block SLIX2 is both identifiable
        // and known to carry the password machinery. Offering the affordance to
        // the whole group offered password protection to silicon that has none,
        // and a plain SLI refuses by going silent rather than by erroring
        // (SL2S2602 section 9.5.3.2), which the app reads as a lost tag.
        XCTAssertNil(
            ProtectionStyle.backendStyle(for: .type5(.icodeSlix), capabilities: [.passwordAuth]),
            "a 28-block ICODE cannot be told apart from silicon with no password hardware"
        )
        // DESFire-generic Type-4 is not the 424 driver's target — stays gated.
        XCTAssertNil(ProtectionStyle.backendStyle(for: .type4(.desfireEV1), capabilities: [.passwordAuth]))
    }

    // MARK: ProtectionSpec.make

    func test_make_type2_resolvesAuth0FromDefaultWhenNil() {
        let settings = TagProtection(passwordProtect: true) // protectFromPage nil
        let cred = TagCredential.type2(password: Data([1, 2, 3, 4]), pack: Data([5, 6]))
        guard case .type2(_, _, let page, _, _)? = ProtectionSpec.make(
            settings: settings,
            credential: cred,
            defaultFirstDataPage: 4
        ) else {
            return XCTFail("expected a .type2 spec")
        }
        XCTAssertEqual(page, 4, "nil AUTH0 must resolve to the chip's first data page")
    }

    func test_make_type2_keepsExplicitAuth0() {
        let settings = TagProtection(passwordProtect: true, protectFromPage: 9, readProtect: false)
        let cred = TagCredential.type2(password: Data([1, 2, 3, 4]), pack: Data([5, 6]))
        guard case .type2(_, _, let page, let readProtect, _)? = ProtectionSpec.make(
            settings: settings,
            credential: cred,
            defaultFirstDataPage: 4
        ) else {
            return XCTFail("expected a .type2 spec")
        }
        XCTAssertEqual(page, 9)
        XCTAssertFalse(readProtect)
    }

    /// A read gate starts at the first data page or the tag is lost to this app.
    ///
    /// `Type2PasswordDriver` recognises a read-gated tag by the roll-over in one
    /// `30 03`: a gated chip serves pages 0 and 1 again in place of the pages
    /// above the Capability Container. That signature is only inside the sixteen
    /// bytes the driver compares when AUTH0 is the first data page. One or two
    /// pages higher the wrap lands later in the frame, unseen; higher still
    /// there is no wrap at all. From any other start page `readState` gets a NAK,
    /// throws `readProtected` before presenting anything, and every unlock,
    /// rewrite, re-key and removal tells the owner that their correct password
    /// did not open the tag, without ever sending it.
    ///
    /// The editor does not offer the combination. This is the funnel that covers
    /// the rows which never passed through it: a preset replayed over a stack,
    /// an imported `.hexnfc`, a row saved from a scanned tag, iCloud sync.
    func test_make_type2_pinsAReadGateToTheFirstDataPage_whateverTheSettingsCarry() {
        let cred = TagCredential.type2(password: Data([1, 2, 3, 4]), pack: Data([5, 6]))
        for carried in [3, 5, 6, 7, 9, 0xFE] {
            let settings = TagProtection(passwordProtect: true, protectFromPage: carried, readProtect: true)
            guard case .type2(_, _, let page, let readProtect, _)? = ProtectionSpec.make(
                settings: settings,
                credential: cred,
                defaultFirstDataPage: 4
            ) else {
                return XCTFail("expected a .type2 spec")
            }
            XCTAssertEqual(
                page, 4,
                "a read gate carried at page \(carried) must arm at the first data page: any other "
                    + "start page is a tag this app can never unlock again"
            )
            XCTAssertTrue(readProtect, "the gate itself is what the user asked for, and it stands")
        }
    }

    /// The pin follows the chip, not the number 4.
    func test_make_type2_pinsAReadGateToTheChipsOwnFirstDataPage() {
        let settings = TagProtection(passwordProtect: true, protectFromPage: 12, readProtect: true)
        let cred = TagCredential.type2(password: Data([1, 2, 3, 4]), pack: Data([5, 6]))
        guard case .type2(_, _, let page, _, _)? = ProtectionSpec.make(
            settings: settings,
            credential: cred,
            defaultFirstDataPage: 6
        ) else {
            return XCTFail("expected a .type2 spec")
        }
        XCTAssertEqual(page, 6)
    }

    /// The choke point. Every batchable write reaches the silicon through
    /// `make`, so this is where "an attempt limit is never applied by a preset"
    /// stops being a rule someone has to remember.
    ///
    /// Removing the editor's stepper does not cover it. A settings object can
    /// carry a limit nobody chose here: a scan reads AUTH_LIM off a tag whose
    /// previous owner set one, "Save as preset" stores that verbatim without the
    /// Protection card ever being opened, an imported `.hexnfc` carries
    /// `TagProtection` whole, and a row saved before the stepper was removed
    /// still holds whatever it held. All four end up here.
    func test_make_type2_neverAppliesAnAttemptLimit_whateverTheSettingsCarry() {
        let cred = TagCredential.type2(password: Data([1, 2, 3, 4]), pack: Data([5, 6]))
        for carried in 1 ... 7 {
            var settings = TagProtection(passwordProtect: true, protectFromPage: 4)
            settings.authLimit = carried
            guard case .type2(_, _, _, _, let applied)? = ProtectionSpec.make(
                settings: settings,
                credential: cred,
                defaultFirstDataPage: 4
            ) else {
                return XCTFail("expected a .type2 spec")
            }
            XCTAssertEqual(
                applied, 0,
                "a preset carrying AUTH_LIM=\(carried) must apply 0: setting one is a per-tag, "
                    + "UID-confirmed operation and a preset is not pinned to a tag"
            )
        }
    }

    func test_make_familyMismatch_returnsNil() {
        let settings = TagProtection(passwordProtect: true) // resolves to .type2
        let cred = TagCredential.type4(aesKey: Data(repeating: 0, count: 16), keySlot: 0)
        XCTAssertNil(ProtectionSpec.make(settings: settings, credential: cred, defaultFirstDataPage: 4))
    }

    func test_make_type5_expandsKindToWriteAndRead() {
        let settings = TagProtection(passwordProtect: true, style: .type5(.init(kind: .readWrite)))
        let cred = TagCredential.type5(password: Data([9, 9, 9, 9]), kind: .readWrite)
        guard case .type5(let write, let read, _)? = ProtectionSpec.make(
            settings: settings,
            credential: cred,
            defaultFirstDataPage: 4
        ) else {
            return XCTFail("expected a .type5 spec")
        }
        XCTAssertEqual(write, Data([9, 9, 9, 9]))
        XCTAssertEqual(read, Data([9, 9, 9, 9]))
    }

    // MARK: protectionStyle on a real simulator

    func test_protectionStyle_type2Simulator_isType2() async throws {
        let tag = try await SimulatedSession(chip: NTAG215Simulator()).start(alert: "")
        guard case .type2? = tag.protectionStyle else {
            return XCTFail("NTAG215 simulator should report a .type2 protectionStyle")
        }
    }

    // MARK: enableProtection forwarding (no Type-2 duplication)

    func test_enableProtection_type2Spec_forwardsToLegacyPath() async throws {
        let simulator = NTAG215Simulator()
        let tag = try await SimulatedSession(chip: simulator).start(alert: "")
        let pwd = Data([0xCA, 0xFE, 0xBA, 0xBE])
        let spec = ProtectionSpec.type2(
            password: pwd,
            pack: Data([0x12, 0x34]),
            protectFromPage: 4,
            readProtect: false,
            authLimit: 0
        )

        try await tag.enableProtection(spec)
        // Arming protection proves the credential with one PWD_AUTH, so the tag
        // is authenticated when the call returns and stays that way until the
        // next activation, exactly as silicon does. Enforcement is therefore
        // asserted across the tap boundary a real re-tap provides.
        simulator.beginActivation()

        // Same observable outcome as enablePasswordProtection: unauth write blocked…
        await assertAuthFails {
            try await tag.writeMemory(at: 5 * 4, bytes: Data([0x01, 0x02, 0x03, 0x04]))
        }
        // …auth then write succeeds; and disableProtection via credential restores it.
        _ = try await tag.authenticate(TagCredential.type2(password: pwd, pack: Data([0x12, 0x34])))
        try await tag.writeMemory(at: 5 * 4, bytes: Data([0x01, 0x02, 0x03, 0x04]))

        try await tag.disableProtection(using: .type2(password: pwd, pack: Data([0x12, 0x34])))
        try await tag.writeMemory(at: 6 * 4, bytes: Data([0x09, 0x09, 0x09, 0x09])) // no auth needed now
    }

    /// Local helper — `TagProtectionTests`' assertion is private to that file.
    private func assertAuthFails(
        _ body: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("expected an authFailed TagError", file: file, line: line)
        } catch let error as TagError {
            if case .authFailed = error.kind {
                return
            }
            XCTFail("expected .authFailed, got \(error.kind)", file: file, line: line)
        } catch {
            XCTFail("expected a TagError, got \(error)", file: file, line: line)
        }
    }
}
