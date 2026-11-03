import XCTest

/// Guards the hand-edited keys in `app/HexNFC/Info.plist`.
///
/// These keys cannot ride the `INFOPLIST_KEY_*` build settings the rest of the
/// plist uses: their names contain dots and their values are arrays, and there
/// is no build-setting spelling for that (`xcode-setup.md` §0). So they live in
/// a file nothing else reads, edited by hand, invisible to the type checker,
/// and they drifted: `aid-rationale.md` spent months claiming three NDEF AIDs
/// were declared and the ICAO one deliberately was not, while the plist said
/// exactly the reverse. Reviewer-facing documentation that contradicts the
/// binary is worse than no documentation.
///
/// The plist is read straight off disk rather than from a bundle, because these
/// assertions are about the repository's source of truth, not about whatever a
/// test host happened to be built with.
final class AIDDeclarationTests: XCTestCase {
    private var plist: [String: Any] {
        get throws {
            let data = try Data(contentsOf: Self.infoPlistURL)
            let parsed = try PropertyListSerialization.propertyList(
                from: data, format: nil
            ) as? [String: Any]
            return try XCTUnwrap(parsed, "Info.plist did not parse as a dictionary")
        }
    }

    /// `app/HexNFC/Info.plist`, located relative to this source file so the test
    /// works from SwiftPM, Xcode, and CI alike.
    private static var infoPlistURL: URL {
        URL(fileURLWithPath: #filePath) // …/app/Tests/HexNFCAppTests/AIDDeclarationTests.swift
            .deletingLastPathComponent() // …/HexNFCAppTests
            .deletingLastPathComponent() // …/Tests
            .deletingLastPathComponent() // …/app
            .appendingPathComponent("HexNFC/Info.plist")
    }

    // MARK: ISO 7816

    /// Exactly two AIDs, travel document first, then the NDEF Tag Application.
    ///
    /// The list is a *discovery filter*: iOS SELECTs each entry itself and only
    /// delivers a tag once one succeeds, so an undeclared ISO-DEP tag is never
    /// seen at all. The eMRTD AID is load-bearing for the passport reader.
    ///
    /// The NDEF AID is load-bearing for every Type 4 tag that is not NXP
    /// silicon. NTAG424 and DESFire arrive on `.miFare` without it, but an
    /// ST25TA, an Infineon part, Android card emulation or an NFC health device
    /// (a NovoPen) is ISO-DEP and nothing else, and without the declaration iOS
    /// never hands it over: the scan sheet just waits.
    ///
    /// **Order is asserted, not just membership.** iOS stops at the first AID
    /// that answers, and `ISO7816TagIdentifier` reads `initialSelectedAID` on
    /// the strength of the eMRTD one going first: a tag delivered on the NDEF
    /// AID has already refused it, so the passport probe is skipped.
    func test_iso7816SelectIdentifiers_declareTheEMRTDThenTheNDEFApplication() throws {
        let aids = try XCTUnwrap(
            plist["com.apple.developer.nfc.readersession.iso7816.select-identifiers"] as? [String]
        )
        XCTAssertEqual(aids, ["A0000002471001", "D2760000850101"])
    }

    /// No payment AID, ever.
    ///
    /// The app has no wallet or payment functionality and no code path that
    /// would know what to do with one. Reviewers check; keeping this list empty
    /// is the answer, and this test is what keeps it that way.
    func test_noPaymentApplicationIdentifiersAreDeclared() throws {
        // Matched on the first five bytes, the registered application provider
        // and the start of its product code, so a scheme's other products are
        // caught too.
        let forbiddenFamilies = [
            "A0000000031010", // Visa
            "A0000000041010", // Mastercard
            "A00000002501", // American Express
            "A0000000651010", // JCB
            "A000000333010101", // UnionPay
        ]
        // Matched whole. It shares its first six bytes with the NDEF Tag
        // Application, `D2760000850101`, which is declared on purpose, so a
        // prefix match here would forbid the one NFC Forum AID the app needs.
        let forbiddenExactly = [
            "D2760000850102", // Authentication Tag Application
        ]
        let aids = try (plist["com.apple.developer.nfc.readersession.iso7816.select-identifiers"]
            as? [String] ?? []).map { $0.uppercased() }
        for bad in forbiddenFamilies {
            XCTAssertFalse(
                aids.contains { $0.hasPrefix(bad.prefix(10).uppercased()) },
                "Payment AID \(bad) must never be declared"
            )
        }
        for bad in forbiddenExactly {
            XCTAssertFalse(aids.contains(bad), "Authentication AID \(bad) must never be declared")
        }
    }

    // MARK: FeliCa

    /// The transit reader is dormant without this key: `CoreNFCSession` only
    /// adds `.iso18092` to the polling set when it is present, because polling a
    /// format the app is not entitled to fails the *entire* session at
    /// `begin()` and would take ordinary 14443/15693 scanning down with it.
    func test_feliCaSystemCodes_declareTheSuicaFamilyOnly() throws {
        let codes = try XCTUnwrap(
            plist["com.apple.developer.nfc.readersession.felica.systemcodes"] as? [String]
        )
        XCTAssertEqual(codes, ["0003"])
    }

    // MARK: Release-critical plist keys

    /// iPad has no NFC radio and neither might some future cut-down iPhone.
    /// Device family alone only describes today's lineup.
    func test_nfcIsARequiredDeviceCapability() throws {
        let capabilities = try XCTUnwrap(plist["UIRequiredDeviceCapabilities"] as? [String])
        XCTAssertTrue(capabilities.contains("nfc"))
    }

    /// Both export compliance keys must be absent, and the reason is narrow.
    ///
    /// The app's encryption is not limited to the operating system, since
    /// `HexNFCKit/Passport/EC` hand-rolls the Brainpool curve arithmetic
    /// CryptoKit does not provide, so `false` would be a misdeclaration and is
    /// not the alternative here. `true` is not available either: Apple pairs it
    /// with `ITSEncryptionExportComplianceCode`, that code is only issued once
    /// compliance documentation is approved, and this app owes none. `true`
    /// alone fails App Store Connect ingest with a 409 naming the empty code.
    ///
    /// Omitting both is the supported way to answer the questions per build
    /// instead. The answers live in `docs/internal/export-compliance.md`.
    func test_exportComplianceKeysAreAbsentPendingACode() throws {
        XCTAssertNil(try plist["ITSAppUsesNonExemptEncryption"])
        XCTAssertNil(try plist["ITSEncryptionExportComplianceCode"])
    }

    /// CloudKit mirroring is push-driven; without this it never learns that
    /// anything changed remotely.
    func test_remoteNotificationBackgroundModeIsDeclaredForCloudKit() throws {
        let modes = try XCTUnwrap(plist["UIBackgroundModes"] as? [String])
        XCTAssertTrue(modes.contains("remote-notification"))
    }
}
