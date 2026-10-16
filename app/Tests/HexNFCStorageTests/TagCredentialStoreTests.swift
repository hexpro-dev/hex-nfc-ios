@testable import HexNFCStorage
import XCTest

/// The UID-keyed credential store: blob round-trips, the two rules that make it
/// safe, and the in-memory store's ordering hook.
///
/// No Keychain access here, matching how `ProtectionCredentialBlobTests` works.
/// `KeychainTagCredentialStore` is exercised only through its pure account
/// encoding, which is the part a wrong answer would silently corrupt.
final class TagCredentialStoreTests: XCTestCase {
    private let type2 = ProtectionCredential.Material.type2(
        password: Data([0xCA, 0xFE, 0xBA, 0xBE]), pack: Data([0x12, 0x34])
    )
    private let type4 = ProtectionCredential.Material.type4(
        aesKey: Data((0 ..< 16).map { UInt8(0xA0 &+ $0) }), keySlot: 1
    )
    private let type5 = ProtectionCredential.Material.type5(
        write: Data([1, 2, 3, 4]), read: Data([5, 6, 7, 8])
    )
    private let ultralightC = ProtectionCredential.Material.ultralightC(
        key: Data((0 ..< 16).map { UInt8(0x10 &+ $0) })
    )

    private let uid = Data([0x04, 0xB8, 0xEC, 0xCA, 0x79, 0x77, 0x80])

    // MARK: - Blob

    func test_record_roundTripsThroughTheBlob() {
        for stage in [
            TagCredentialRecord.Stage.armed, .applying, .removing, .residue,
        ] {
            let record = TagCredentialRecord(
                stage: stage,
                candidates: [type4, ultralightC, type2, type5],
                // Truncated to whole seconds so the comparison is about the
                // codec rather than about double rounding.
                updatedAt: Date(timeIntervalSinceReferenceDate: 800_000_000)
            )
            let back = TagCredentialBlob.decode(TagCredentialBlob.encode(record))
            XCTAssertEqual(back, record, "stage \(stage) must round-trip")
        }
    }

    func test_aPresetBlobDoesNotDecodeAsATagRecord_andTheReverse() {
        let preset = ProtectionCredentialBlob.encode(ProtectionCredential(material: type4))
        XCTAssertNil(TagCredentialBlob.decode(preset),
                     "a preset blob read from the tag service must not decode to a plausible record")

        let tagRecord = TagCredentialBlob.encode(
            TagCredentialRecord(stage: .armed, candidates: [type4])
        )
        XCTAssertNil(ProtectionCredentialBlob.decode(tagRecord),
                     "and a tag record read from the preset service must not decode to a credential")
    }

    func test_truncatedBlobDecodesToNil_ratherThanToAShortCandidateList() {
        let blob = TagCredentialBlob.encode(
            TagCredentialRecord(stage: .applying, candidates: [type4, ultralightC])
        )
        for length in 1 ..< blob.count {
            XCTAssertNil(TagCredentialBlob.decode(Data(blob.prefix(length))),
                         "a \(length)-byte truncation must not decode")
        }
    }

    /// Pins the `encodeMaterial` split. The preset store's on-disk bytes are
    /// `version ‖ tag ‖ body` and must not have moved: a Keychain item written
    /// by a shipped build has to keep decoding.
    func test_encodeMaterial_isTheTailOfTheUnchangedPresetEncoding() {
        for material in [type2, type4, type5, ultralightC] {
            let full = ProtectionCredentialBlob.encode(ProtectionCredential(material: material))
            XCTAssertEqual(full.first, 0x01, "the preset blob's version byte is unchanged")
            XCTAssertEqual(Data(full.dropFirst()), ProtectionCredentialBlob.encodeMaterial(material))
            XCTAssertEqual(ProtectionCredentialBlob.decodeMaterial(Data(full.dropFirst())), material)
        }
        // The exact bytes for one family, written out, so a refactor that
        // reorders the fields fails here rather than on a user's device.
        XCTAssertEqual(
            ProtectionCredentialBlob.encode(ProtectionCredential(password: Data([1, 2, 3, 4]), pack: Data([5, 6]))),
            Data([0x01, 0x02, 1, 2, 3, 4, 5, 6])
        )
    }

    // MARK: - The two safety rules

    func test_emptyCandidatesIsRefused() {
        let store = InMemoryTagCredentialStore()
        let record = TagCredentialRecord(stage: .armed, candidates: [])
        XCTAssertThrowsError(try store.save(record, forUID: uid)) { error in
            XCTAssertEqual(error as? TagCredentialStoreError, .empty)
        }
        XCTAssertNil(store.record(forUID: uid),
                     "a record saying 'protected, and I hold nothing' must not exist")
    }

    func test_promoting_putsTheNewCredentialFirst_dedupesAndTrimsToFour() {
        let record = TagCredentialRecord(stage: .armed, candidates: [type2])
            .promoting(type4, stage: .applying)
        XCTAssertEqual(record.stage, .applying)
        XCTAssertEqual(record.candidates, [type4, type2],
                       "the previous credential is kept behind the new one")

        // Re-promoting an entry already in the list moves it rather than
        // duplicating it: between two frames either key may be the live one, and
        // a duplicate would waste one of the four slots.
        let moved = record.promoting(type2, stage: .armed)
        XCTAssertEqual(moved.candidates, [type2, type4])

        var deep = TagCredentialRecord(stage: .armed, candidates: [type2])
        for material in [type4, type5, ultralightC, .type2(password: Data([9, 9, 9, 9]), pack: Data([0, 1]))] {
            deep = deep.promoting(material, stage: .applying)
        }
        XCTAssertEqual(deep.candidates.count, TagCredentialRecord.maximumCandidates)
    }

    // MARK: - Stores

    func test_inMemoryStore_countsSavesSoAnOrderingCanBeAsserted() throws {
        let store = InMemoryTagCredentialStore()
        XCTAssertEqual(store.saveCount, 0)
        try store.save(TagCredentialRecord(stage: .applying, candidates: [type4]), forUID: uid)
        XCTAssertEqual(store.saveCount, 1)
        XCTAssertEqual(store.record(forUID: uid)?.stage, .applying)
        XCTAssertEqual(store.allUIDs(), [uid])

        try store.save(TagCredentialRecord(stage: .armed, candidates: [type4]), forUID: uid)
        XCTAssertEqual(store.saveCount, 2, "an upsert is still a save")
        XCTAssertEqual(store.allUIDs().count, 1)

        store.delete(forUID: uid)
        XCTAssertNil(store.record(forUID: uid))
        XCTAssertTrue(store.allUIDs().isEmpty)
    }

    func test_keychainAccount_isUppercaseHex_andRoundTrips() {
        XCTAssertEqual(KeychainTagCredentialStore.account(forUID: uid), "04B8ECCA797780")
        XCTAssertEqual(KeychainTagCredentialStore.uid(fromAccount: "04B8ECCA797780"), uid)
        // A neighbour item written by something else must be skipped, not
        // decoded into a nonsense UID.
        XCTAssertNil(KeychainTagCredentialStore.uid(fromAccount: "not-hex"))
        XCTAssertNil(KeychainTagCredentialStore.uid(fromAccount: "0AB"), "odd length is not a UID")
        XCTAssertNil(KeychainTagCredentialStore.uid(fromAccount: ""))
    }
}
