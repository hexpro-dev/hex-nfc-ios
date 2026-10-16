@testable import HexNFCRecords
@testable import HexNFCStorage
import XCTest

@MainActor
final class TagProtectionStorageTests: XCTestCase {
    private func makeRepo() throws -> (LibraryRepository, InMemoryProtectionCredentialStore) {
        let creds = InMemoryProtectionCredentialStore()
        let repo = try LibraryRepository(stack: SwiftDataStack.inMemory(), credentials: creds)
        return (repo, creds)
    }

    private let pwd = Data([0xCA, 0xFE, 0xBA, 0xBE])
    private let pack = Data([0x12, 0x34])

    // MARK: - Preset round-trip

    func test_insertProtectedPreset_roundTripsSettingsAndCredential() throws {
        let (repo, creds) = try makeRepo()
        let protection = TagProtection(
            passwordProtect: true, protectFromPage: 4, readProtect: true, authLimit: 0
        )
        let preset = try repo.insertPreset(
            name: "Locked",
            records: [.uri(URIRecord(uri: "https://hex.pro"))],
            protection: protection,
            credential: ProtectionCredential(password: pwd, pack: pack)
        )

        let saved = try XCTUnwrap(repo.fetchPresets().first)
        let decoded = try XCTUnwrap(saved.decodedProtection())
        XCTAssertTrue(decoded.passwordProtect)
        // A preset holds no start page at all; see
        // `test_insertPreset_dropsAPinnedStartPage`. Page 4 is the NTAG21x first
        // data page, so `nil` resolves to the same gate this row asked for.
        XCTAssertNil(decoded.protectFromPage)
        XCTAssertTrue(decoded.readProtect)
        XCTAssertEqual(decoded.authLimit, 0)
        XCTAssertTrue(decoded.hasStoredCredential, "storing a credential must flip hasStoredCredential")

        let credential = try XCTUnwrap(creds.load(for: preset.id))
        XCTAssertEqual(credential.password, pwd)
        XCTAssertEqual(credential.pack, pack)
    }

    func test_insertProtectedPreset_withoutCredential_hasStoredCredentialFalse() throws {
        let (repo, creds) = try makeRepo()
        let preset = try repo.insertPreset(
            name: "SettingsOnly",
            records: [],
            protection: TagProtection(passwordProtect: true, protectFromPage: 4)
        )
        XCTAssertEqual(try repo.fetchPresets().first?.decodedProtection()?.hasStoredCredential, false)
        XCTAssertNil(creds.load(for: preset.id))
    }

    func test_insertProtectionOnlyPreset_withCredential_roundTrips() throws {
        // A "lock a stack of blank tags" preset: zero records, protection on,
        // credential stashed. The write flow writes empty NDEF then applies
        // protection — so this must persist cleanly even with no records.
        let (repo, creds) = try makeRepo()
        let preset = try repo.insertPreset(
            name: "Locker", records: [],
            protection: TagProtection(passwordProtect: true, protectFromPage: 4),
            credential: ProtectionCredential(password: pwd, pack: pack)
        )
        let saved = try XCTUnwrap(repo.fetchPresets().first)
        XCTAssertTrue(saved.decodedRecords().isEmpty, "a protection-only preset carries no records")
        XCTAssertEqual(saved.decodedProtection()?.passwordProtect, true)
        XCTAssertTrue(saved.decodedProtection()?.hasStoredCredential ?? false)
        XCTAssertEqual(creds.load(for: preset.id)?.password, pwd)
    }

    func test_unprotectedPreset_hasNilProtection() throws {
        let (repo, _) = try makeRepo()
        try repo.insertPreset(name: "Plain", records: [.text(TextRecord(text: "x"))])
        XCTAssertNil(try repo.fetchPresets().first?.decodedProtection())
    }

    func test_deletePreset_dropsCredential() throws {
        let (repo, creds) = try makeRepo()
        let preset = try repo.insertPreset(
            name: "Tmp", records: [],
            protection: TagProtection(passwordProtect: true),
            credential: ProtectionCredential(password: pwd, pack: pack)
        )
        XCTAssertNotNil(creds.load(for: preset.id))
        try repo.deletePreset(preset)
        XCTAssertNil(creds.load(for: preset.id), "deleting a preset must drop its credential")
    }

    func test_duplicatePreset_copiesProtectionAndCredential() throws {
        let (repo, creds) = try makeRepo()
        let original = try repo.insertPreset(
            name: "Source", records: [.uri(URIRecord(uri: "https://hex.pro"))],
            protection: TagProtection(passwordProtect: true, protectFromPage: 4, readProtect: false),
            credential: ProtectionCredential(password: pwd, pack: pack)
        )
        let copy = try repo.duplicatePreset(original)
        XCTAssertEqual(copy.decodedProtection()?.passwordProtect, true)
        XCTAssertNil(copy.decodedProtection()?.protectFromPage, "a preset carries no pinned start page")
        let copied = try XCTUnwrap(creds.load(for: copy.id))
        XCTAssertEqual(copied.password, pwd, "duplicate must carry the credential under the new id")
    }

    // MARK: - .hexnfc export/import

    func test_export_omitsCredential_andForcesHasStoredCredentialFalse() throws {
        let (repo, _) = try makeRepo()
        let preset = try repo.insertPreset(
            name: "Shared", records: [.text(TextRecord(text: "hi"))],
            protection: TagProtection(passwordProtect: true, protectFromPage: 4),
            credential: ProtectionCredential(password: pwd, pack: pack)
        )
        let data = try repo.exportAsHexnfc(preset)
        let envelope = try JSONDecoder.preset.decode(LibraryRepository.HexnfcEnvelope.self, from: data)
        XCTAssertEqual(envelope.version, 3)
        XCTAssertEqual(envelope.protection?.passwordProtect, true)
        XCTAssertEqual(envelope.protection?.hasStoredCredential, false, "the secret must never leave the device")
        // A Type-2 export carries no `style` key — byte-identical to v2, so a
        // tag locked by Hex stays unlockable by any standard NTAG21x tool.
        XCTAssertFalse(try XCTUnwrap(String(data: data, encoding: .utf8)?.contains("\"style\"")))
    }

    func test_export_type4Preset_carriesStyle_butNoKey() throws {
        let (repo, _) = try makeRepo()
        var settings = TagProtection(passwordProtect: true)
        settings.style = .type4(.init(keySlot: 0, readProtect: true))
        let preset = try repo.insertPreset(
            name: "DNA", records: [.text(TextRecord(text: "hi"))],
            protection: settings,
            credential: ProtectionCredential(aesKey: Data(repeating: 0xAB, count: 16), keySlot: 0)
        )
        let data = try repo.exportAsHexnfc(preset)
        let envelope = try JSONDecoder.preset.decode(LibraryRepository.HexnfcEnvelope.self, from: data)
        guard case .type4(let s)? = envelope.protection?.effectiveStyle else {
            return XCTFail("Type-4 export should carry a .type4 style")
        }
        XCTAssertTrue(s.readProtect)
        // The AES key never leaves the device.
        XCTAssertFalse(try XCTUnwrap(String(data: data, encoding: .utf8)?.lowercased().contains("abababab")))
    }

    func test_importV2Envelope_restoresSettingsButNotCredential() throws {
        let (repo, creds) = try makeRepo()
        let source = try repo.insertPreset(
            name: "Origin", records: [.uri(URIRecord(uri: "https://hex.pro"))],
            protection: TagProtection(passwordProtect: true, protectFromPage: 4, readProtect: true),
            credential: ProtectionCredential(password: pwd, pack: pack)
        )
        let data = try repo.exportAsHexnfc(source)

        let (repo2, creds2) = try makeRepo()
        let imported = try repo2.importHexnfc(data)
        let decoded = try XCTUnwrap(imported.decodedProtection())
        XCTAssertTrue(decoded.passwordProtect)
        XCTAssertNil(decoded.protectFromPage, "a preset carries no pinned start page")
        XCTAssertTrue(decoded.readProtect)
        XCTAssertFalse(decoded.hasStoredCredential)
        XCTAssertNil(creds2.load(for: imported.id), "no credential should travel in a .hexnfc file")
        _ = creds // silence unused in this repo
    }

    func test_importV1Envelope_decodesWithoutProtection() throws {
        let (repo, _) = try makeRepo()
        // A pre-protection v1 file: no `protection` key at all.
        let json = Data("""
        {"version":1,"name":"Legacy","notes":"","records":[],"exportedAt":"2020-01-01T00:00:00Z"}
        """.utf8)
        let imported = try repo.importHexnfc(json)
        XCTAssertEqual(imported.name, "Legacy")
        XCTAssertNil(imported.decodedProtection(), "v1 files import as unprotected")
    }

    // MARK: - History

    func test_recordScan_storesProtectionSettings_andAffectsDedup() throws {
        let (repo, _) = try makeRepo()
        let writeOnly = TagProtection(passwordProtect: true, protectFromPage: 4, readProtect: false)
        try repo.recordScan(
            chipFamily: "NTAG215", uidHex: "04a1b2c3d4e5f6", records: [],
            capabilitiesRaw: 0xFF, protection: writeOnly
        )
        let entry = try XCTUnwrap(repo.fetchHistory().first)
        XCTAssertEqual(entry.decodedProtection()?.protectFromPage, 4)

        // A scan of the same tag with *different* protection is a distinct
        // snapshot — protection is part of the dedup fingerprint.
        let readProtect = TagProtection(passwordProtect: true, protectFromPage: 4, readProtect: true)
        try repo.recordScan(
            chipFamily: "NTAG215", uidHex: "04a1b2c3d4e5f6", records: [],
            capabilitiesRaw: 0xFF, protection: readProtect
        )
        XCTAssertEqual(try repo.fetchHistory().count, 2, "differing protection must not dedupe")
    }

    /// A row that stored no reading must say so, because the editor it re-opens
    /// seeds its padlock, its summary line and the Protection card's secret
    /// fields from this. It used to seed `?? .none` and claim "Off" about a tag
    /// nothing had read.
    func test_historyRowWithNoStoredProtection_reportsUnknown() throws {
        let (repo, _) = try makeRepo()
        try repo.recordScan(chipFamily: "NTAG215", uidHex: "04a1b2c3d4e5f6", records: [])

        let entry = try XCTUnwrap(repo.fetchHistory().first)
        XCTAssertNil(entry.decodedProtection())
        XCTAssertTrue(
            entry.protectionIsUnknown,
            "a refused read, a chip with no backend and a pre-field row are all 'we don't know'"
        )
    }

    /// The other half, and the reason this is not simply "no password means
    /// unknown": a read that found the tag unprotected stores `.none`, which is
    /// a finding, and the editor may present it as "Off".
    func test_historyRowThatReadAnUnprotectedTag_reportsAKnownState() throws {
        let (repo, _) = try makeRepo()
        try repo.recordScan(
            chipFamily: "NTAG215", uidHex: "04a1b2c3d4e5f6", records: [],
            protection: TagProtection.none
        )

        let entry = try XCTUnwrap(repo.fetchHistory().first)
        XCTAssertEqual(entry.decodedProtection(), TagProtection.none)
        XCTAssertFalse(entry.protectionIsUnknown)
    }

    // MARK: - Credential store

    func test_inMemoryCredentialStore_roundTrip() throws {
        let store = InMemoryProtectionCredentialStore()
        let id = UUID()
        XCTAssertNil(store.load(for: id))
        try store.save(ProtectionCredential(password: pwd, pack: pack), for: id)
        XCTAssertEqual(store.load(for: id)?.password, pwd)
        XCTAssertEqual(store.load(for: id)?.pack, pack)
        store.delete(for: id)
        XCTAssertNil(store.load(for: id))
    }

    // MARK: - A preset carries no pinned start page

    /// The scan-to-preset path, which is how a page nobody chose gets in.
    ///
    /// Scanning a tag somebody else armed from page 16 reads AUTH0 back as a
    /// reading, the editor rebases it into its protection on purpose, and "Save
    /// as preset" stores whatever the editor holds. The Protection card's start
    /// page control is inside a disclosure group that opens closed and the save
    /// sheet shows no page at all, so the number crosses into the preset without
    /// appearing on screen. Replayed over a stack of blank NTAG21x it would arm
    /// each one from page 16 and leave pages 4 to 15 writable, and nothing
    /// downstream disagrees: the driver reads AUTH0 back at 16, which is what it
    /// was told to write, and reports success.
    func test_insertPreset_dropsAPinnedStartPage() throws {
        let (repo, _) = try makeRepo()
        let readBack = TagProtection(
            passwordProtect: true, protectFromPage: 16, readProtect: false, authLimit: 0
        )
        _ = try repo.insertPreset(
            name: "From a scan",
            records: [.uri(URIRecord(uri: "https://hex.pro"))],
            protection: readBack,
            credential: ProtectionCredential(password: pwd, pack: pack)
        )

        let decoded = try XCTUnwrap(try repo.fetchPresets().first?.decodedProtection())
        XCTAssertTrue(decoded.passwordProtect, "the gate itself is what the preset is for, and it stands")
        XCTAssertNil(
            decoded.protectFromPage,
            "a preset replays across chips, so AUTH0 must resolve against the chip on the reader"
        )
    }

    /// Ultralight C keeps its start page inside `style` rather than in the flat
    /// field, and its read-back projection fills it the same way.
    func test_insertPreset_dropsAPinnedUltralightCStartPage() throws {
        let (repo, _) = try makeRepo()
        var readBack = TagProtection(passwordProtect: true)
        readBack.style = .ultralightC(.init(protectFromPage: 0x10, readProtect: false))
        _ = try repo.insertPreset(
            name: "UL C from a scan", records: [], protection: readBack,
            credential: ProtectionCredential(ultralightCKey: Data(repeating: 0xA5, count: 16))
        )

        let decoded = try XCTUnwrap(try repo.fetchPresets().first?.decodedProtection())
        guard case .ultralightC(let settings) = decoded.effectiveStyle else {
            return XCTFail("an Ultralight C preset must keep its style")
        }
        XCTAssertNil(settings.protectFromPage)
    }

    /// Rows already on disk, and rows arriving from another device over iCloud,
    /// were written by a build without this rule. Dropping the page only on the
    /// way in would leave every one of them pinned, so the decode drops it too.
    func test_decodedProtection_dropsAPinnedStartPageWrittenByAnEarlierBuild() throws {
        let (repo, _) = try makeRepo()
        _ = try repo.insertPreset(name: "Synced", records: [], protection: nil)
        let preset = try XCTUnwrap(repo.fetchPresets().first)
        // Written straight past the model's setters, the way a store migrated
        // from an earlier build or mirrored from CloudKit arrives.
        preset.protectionJSON = try JSONEncoder.preset.encode(
            TagProtection(passwordProtect: true, protectFromPage: 16)
        )

        XCTAssertEqual(preset.decodedProtection()?.passwordProtect, true)
        XCTAssertNil(preset.decodedProtection()?.protectFromPage)
    }

    /// A `.hexnfc` file is a preset that has left the device, so it carries the
    /// same rule. Exporting a row an earlier build pinned cleans it on the way
    /// out rather than handing the number to whoever opens the file.
    func test_export_dropsAPinnedStartPage() throws {
        let (repo, _) = try makeRepo()
        _ = try repo.insertPreset(name: "Shared", records: [], protection: nil)
        let preset = try XCTUnwrap(repo.fetchPresets().first)
        preset.protectionJSON = try JSONEncoder.preset.encode(
            TagProtection(passwordProtect: true, protectFromPage: 16)
        )

        let data = try repo.exportAsHexnfc(preset)
        let envelope = try JSONDecoder.preset.decode(LibraryRepository.HexnfcEnvelope.self, from: data)
        XCTAssertEqual(envelope.protection?.passwordProtect, true)
        XCTAssertNil(envelope.protection?.protectFromPage)
    }

    /// And the same on the way in, for a file written by an earlier build or by
    /// hand. An import is the one path that never passes a screen.
    func test_importHexnfc_dropsAPinnedStartPage() throws {
        let (repo, _) = try makeRepo()
        let incoming = LibraryRepository.HexnfcEnvelope(
            name: "Pinned elsewhere",
            records: [.text(TextRecord(text: "hi"))],
            protection: TagProtection(passwordProtect: true, protectFromPage: 16)
        )
        let data = try JSONEncoder.preset.encode(incoming)
        // The file really does carry the page: this test is about the import,
        // not about the encoder quietly dropping it.
        let onDisk = try JSONDecoder.preset.decode(LibraryRepository.HexnfcEnvelope.self, from: data)
        XCTAssertEqual(onDisk.protection?.protectFromPage, 16)

        let imported = try repo.importHexnfc(data)
        let decoded = try XCTUnwrap(imported.decodedProtection())
        XCTAssertTrue(decoded.passwordProtect)
        XCTAssertNil(decoded.protectFromPage)
    }
}
