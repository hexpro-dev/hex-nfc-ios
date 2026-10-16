@testable import HexNFCApp
@testable import HexNFCKit
@testable import HexNFCRecords
import XCTest

/// What the editor's Protection card may put in its own fields.
///
/// ## The shape of the defect this guards
///
/// Twice now the card has opened on a tag that already holds a credential, with
/// a credential of the card's own choosing already in the field and the save
/// button live. The user presses the only affirmative button on the sheet, the
/// write goes out, and the tag ends up holding the sheet's value instead of
/// theirs.
///
/// The first time it was the Type-2 password, seeded as `FF:FF:FF:FF`, and the
/// tag came back holding the delivery password while the app reported success.
/// The second was found on 2026-09-19: the Ultralight C key field seeded a
/// random 16 bytes on any tag whose key the app did not hold, including one that
/// had just been scanned as protected. That one is worse. The write refuses with
/// the tag's real key, the user supplies it at the unlock prompt, the write
/// re-keys the tag to the random value on the way past, and Ultralight C has no
/// factory reset: nobody can rewrite the protected memory again, and the app
/// never shows that key a second time.
///
/// The rule is therefore the same for every family: a default is only safe where
/// there is nothing to overwrite.
final class ProtectionCardSeedTests: XCTestCase {
    private let password = Data([0xA1, 0xB2, 0xC3, 0xD4])
    private let pack = Data([0x56, 0x78])

    // MARK: - A tag that already reports protection

    /// The Ultralight C case, which is the one found on silicon's behalf.
    func test_aProtectedUltralightCWithNoKeyInHand_seedsNothing() {
        let seed = ProtectionCardSeed.seed(
            family: .ultralightC, credential: nil, tagReportsProtection: true
        )

        XCTAssertEqual(
            seed.keyHex, "",
            "the key field must wait for the key the tag actually holds"
        )
        XCTAssertFalse(
            seed.generatesUltralightCKey,
            "a generated key here is a re-key of a tag whose key the user has not been asked for"
        )
    }

    /// The Type-2 case, which is the same rule and already held. Kept because it
    /// is the precedent the Ultralight C branch was measured against, and a
    /// regression to `FF:FF:FF:FF` here is the original defect returning.
    func test_aProtectedType2TagWithNoPasswordInHand_seedsNoPassword() {
        let seed = ProtectionCardSeed.seed(
            family: .type2, credential: nil, tagReportsProtection: true
        )

        XCTAssertEqual(seed.passwordHex, "", "the delivery password is not a thing to offer a live gate")
    }

    /// Type-4 and Type-5 have always started empty, for the same reason. Pinned
    /// so the four families cannot drift apart again.
    func test_everyFamilyOnAProtectedTagLeavesItsSecretFieldEmpty() {
        for family in ProtectionStyle.Family.allCases {
            let seed = ProtectionCardSeed.seed(
                family: family, credential: nil, tagReportsProtection: true
            )
            let field = family == .type4 || family == .ultralightC ? seed.keyHex : seed.passwordHex
            XCTAssertEqual(field, "", "\(family) seeded a credential onto a tag that already holds one")
            XCTAssertFalse(seed.generatesUltralightCKey, "\(family) generated a key for a protected tag")
        }
    }

    // MARK: - A tag with nothing to overwrite

    /// The affordance the generated key exists for survives: on a fresh tag the
    /// card is valid the moment it opens, and the safe option is the one already
    /// chosen.
    func test_anUnprotectedUltralightC_stillOpensOnAGeneratedKey() {
        let seed = ProtectionCardSeed.seed(
            family: .ultralightC, credential: nil, tagReportsProtection: false
        )

        XCTAssertTrue(seed.generatesUltralightCKey)
    }

    /// An unprotected Type-2 tag keeps the delivery values in view, which is what
    /// they are: the bytes the tag is holding right now.
    func test_anUnprotectedType2Tag_keepsTheDeliveryValues() {
        let seed = ProtectionCardSeed.seed(
            family: .type2, credential: nil, tagReportsProtection: false
        )

        XCTAssertEqual(seed.passwordHex, "FF:FF:FF:FF")
        XCTAssertEqual(seed.packHex, "00:00")
    }

    // MARK: - A credential in hand

    /// Holding the credential is the other case entirely: these bytes are the
    /// tag's, so showing them overwrites nothing and withholding them would stop
    /// the user turning protection off.
    func test_aCredentialInHandFillsItsOwnField_protectedOrNot() throws {
        for protected in [true, false] {
            let type2 = ProtectionCardSeed.seed(
                family: .type2,
                credential: .type2(password: password, pack: pack),
                tagReportsProtection: protected
            )
            XCTAssertEqual(type2.passwordHex, password.hexString)
            XCTAssertEqual(type2.packHex, pack.hexString)

            let key = try UltralightCKey(cipherOrder: Data((0 ..< 16).map { UInt8(0xA0 + $0) }))
            let ulc = ProtectionCardSeed.seed(
                family: .ultralightC,
                credential: .ultralightC(key: key),
                tagReportsProtection: protected
            )
            XCTAssertEqual(ulc.keyHex, key.cipherOrder.hexString)
            XCTAssertFalse(
                ulc.generatesUltralightCKey,
                "a key in hand is never replaced by a generated one"
            )
        }
    }

    // MARK: - The card is wired to this rule

    /// A tag whose protection could not be read is not a tag proven bare.
    func test_anUnreadProtectionStateIsTreatedAsATagThatMayHoldAKey() {
        let seed = ProtectionCardSeed.seed(
            family: .ultralightC, credential: nil, tagReportsProtection: true
        )

        XCTAssertFalse(seed.generatesUltralightCKey)
    }

    /// `ProtectionConfigSheet.swift` is `#if os(iOS)`, so nothing above compiles
    /// it. This is the line that joins the two: the card must take its fields
    /// from `ProtectionCardSeed` and must not re-derive a key of its own.
    ///
    /// The arguments are pinned as tightly as the body, because the first
    /// version of this fix passed the rule the wrong one. It took
    /// `editModel.protection`, the user's *staged intent*, where the tag's
    /// reading is `originalProtection`: staging a removal on a protected
    /// Ultralight C and reopening the card then seeded a fresh key again, and
    /// the whole defect came back through a guard that was green because the
    /// call was still there. A source-text guard over a file no test can
    /// compile has to be brittle to be worth anything.
    func test_theCardSeedsItsFieldsFromThisRuleAlone() throws {
        let text = try cardSource()
        let flattened = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")

        for fragment in [
            "ProtectionCardSeed.seed(",
            "credential: editModel.protectionCredential,",
            "tagReportsProtection: editModel.originalProtection.passwordProtect "
                + "|| editModel.protectionIsUnknown || p.passwordProtect",
            "_passwordHex = State(initialValue: seed.passwordHex)",
            "_packHex = State(initialValue: seed.packHex)",
        ] {
            XCTAssertTrue(
                flattened.contains(fragment),
                "the card must seed itself from the rule, on the tag's reading: missing \(fragment)"
            )
        }
        let generators = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("randomHex(") && !$0.hasPrefix("//") && !$0.hasPrefix("///") }
        XCTAssertEqual(
            generators,
            [
                "_keyHex = State(initialValue: seed.generatesUltralightCKey ? Self.randomHex(16) : seed.keyHex)",
                // The Type-4 card's own button, and the Ultralight C one.
                "Button(\"Generate random key\") { keyHex = Self.randomHex(16) }",
                "Button(\"Generate a new key\") { keyHex = Self.randomHex(16) }",
                "private static func randomHex(_ count: Int) -> String {",
            ],
            "a key may be generated where the rule says so, or where the user presses a button "
                + "asking for one, and nowhere else"
        )
    }

    /// Finding 22's other half, which lives in the same uncompiled file: the
    /// card may not offer a start page while the read toggle is on, and may not
    /// commit one.
    ///
    /// `ProtectionSpec.make` pins the outcome for every row that reaches a tag,
    /// which is where the rule is structural. This guards the affordance, so a
    /// user is not offered a choice the write is going to overrule.
    func test_theCardOffersNoStartPageWhileAReadGateIsOn() throws {
        let text = try cardSource()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        XCTAssertTrue(
            lines.contains("settings.protectFromPage = customStartPage && !readProtect ? startPage : nil"),
            "a read-gated row must commit no start page of its own"
        )
        let stepper = try XCTUnwrap(
            lines.firstIndex(where: { $0.hasPrefix("Stepper(value: $startPage") }),
            "the start-page stepper moved; re-point this guard"
        )
        let guardLine = lines[..<stepper].lastIndex(of: "if !readProtect {")
        XCTAssertNotNil(
            guardLine,
            "the stepper must sit inside `if !readProtect`: a start page other than the chip's "
                + "first data page makes a read-gated tag unopenable by this app (finding 22)"
        )
    }

    private func cardSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath) // …/app/Tests/HexNFCAppTests/…
            .deletingLastPathComponent() // …/HexNFCAppTests
            .deletingLastPathComponent() // …/Tests
            .deletingLastPathComponent() // …/app
            .appendingPathComponent("Sources/HexNFCApp/Screens/ProtectionConfigSheet.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
