@testable import HexNFCRecords
import XCTest

/// Guards the migration-safe shape of `TagProtection`: legacy Type-2 JSON must
/// still decode, new Type-2 values must stay byte-identical to the legacy form
/// (no `style` key), and Type-4/Type-5 styles must round-trip.
final class TagProtectionCodableTests: XCTestCase {
    private func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys] // deterministic for byte comparison
        return e
    }

    // MARK: Legacy decode

    func test_decodesLegacyType2JSON_withoutStyleKey() throws {
        // Exactly the pre-families shape: five flat keys, no `style`.
        let json = Data("""
        {"passwordProtect":true,"protectFromPage":4,"readProtect":false,"authLimit":0,"hasStoredCredential":true}
        """.utf8)
        let p = try JSONDecoder().decode(TagProtection.self, from: json)
        XCTAssertNil(p.style, "legacy JSON must decode with style == nil")
        XCTAssertTrue(p.passwordProtect)
        XCTAssertEqual(p.protectFromPage, 4)
        XCTAssertEqual(p.hasStoredCredential, true)
        // effectiveStyle synthesizes Type-2 from the flat fields.
        guard case .type2(let s) = p.effectiveStyle else { return XCTFail("expected .type2") }
        XCTAssertEqual(s.protectFromPage, 4)
        XCTAssertFalse(s.readProtect)
        XCTAssertEqual(s.authLimit, 0)
    }

    func test_legacyEmptyJSON_decodesAsNone() throws {
        let json = Data("""
        {"passwordProtect":false,"readProtect":false,"authLimit":0,"hasStoredCredential":false}
        """.utf8)
        let p = try JSONDecoder().decode(TagProtection.self, from: json)
        XCTAssertFalse(p.isActive)
        XCTAssertNil(p.style)
    }

    // MARK: Type-2 byte-identical guard (cross-app interop + dedup fingerprint)

    func test_type2Value_encodesWithoutStyleKey() throws {
        // A Type-2 protection built the new way (style left nil, flat fields set)
        // must NOT emit a `style` key — keeping its JSON identical to the v2 form.
        let p = TagProtection(
            passwordProtect: true,
            protectFromPage: 4,
            readProtect: true,
            authLimit: 0,
            hasStoredCredential: true
        )
        let data = try encoder().encode(p)
        let string = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(string.contains("\"style\""), "Type-2 JSON must not contain a style key; got \(string)")
    }

    func test_type2RoundTrip_preservesFlatFields() throws {
        let p = TagProtection(
            passwordProtect: true,
            protectFromPage: 7,
            readProtect: true,
            authLimit: 3,
            hasStoredCredential: false
        )
        let back = try JSONDecoder().decode(TagProtection.self, from: encoder().encode(p))
        XCTAssertEqual(back, p)
        XCTAssertNil(back.style)
    }

    // MARK: Type-4 / Type-5 round-trip

    func test_type4Style_roundTrips() throws {
        let p = TagProtection(
            passwordProtect: true,
            style: .type4(.init(keySlot: 1, readProtect: true)),
            hasStoredCredential: true
        )
        let back = try JSONDecoder().decode(TagProtection.self, from: encoder().encode(p))
        XCTAssertEqual(back, p)
        guard case .type4(let s) = back.effectiveStyle else { return XCTFail("expected .type4") }
        XCTAssertEqual(s.keySlot, 1)
        XCTAssertTrue(s.readProtect)
        XCTAssertTrue(back.effectiveReadProtect)
    }

    func test_type5Style_roundTrips() throws {
        let p = TagProtection(
            passwordProtect: true,
            style: .type5(.init(kind: .readWrite))
        )
        let back = try JSONDecoder().decode(TagProtection.self, from: encoder().encode(p))
        XCTAssertEqual(back, p)
        guard case .type5(let s) = back.effectiveStyle else { return XCTFail("expected .type5") }
        XCTAssertEqual(s.kind, .readWrite)
        XCTAssertTrue(back.effectiveReadProtect)
    }

    func test_type5WriteOnly_isNotReadProtected() {
        let p = TagProtection(passwordProtect: true, style: .type5(.init(kind: .write)))
        XCTAssertFalse(p.effectiveReadProtect)
    }
}
