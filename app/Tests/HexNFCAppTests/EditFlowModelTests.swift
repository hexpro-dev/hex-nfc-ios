@testable import HexNFCApp
import HexNFCKit
import HexNFCRecords
import HexNFCStorage
import HexNFCTagSim
import XCTest

/// What the editor asks a write to do to the tag's data area.
///
/// The write used to rewrite it unconditionally, above both protection
/// branches, with no records-changed guard. So switching a password on in the
/// editor read the message off the tag and put the same bytes straight back:
/// on 2026-09-21 a `READ p3` at 13:34:32.288 returned the message and the write
/// landed 22 ms later. Harmless on that tag, and not harmless in general, since
/// the bytes going back are the editor's copy rather than the tag's.
@MainActor
final class EditFlowModelTests: XCTestCase {
    private let password = Data([0x2A, 0x3B, 0x4C, 0x5D])
    private let pack = Data([0x6E, 0x7F])

    private func armedEditor(records: [NDEFRecord]) -> EditFlowModel {
        let editor = EditFlowModel(records: records, origin: .build)
        editor.protection = TagProtection(
            passwordProtect: true, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        editor.protectionCredential = .type2(password: password, pack: pack)
        return editor
    }

    private func write(
        _ dataArea: DataAreaChange,
        to chip: ChipSimulator,
        protection: PendingProtection? = nil,
        unlockCredential: TagCredential? = nil
    ) -> WriteFlowModel {
        WriteFlowModel(
            factory: SimulatedSessionFactory(chip: chip),
            dataArea: dataArea,
            credentials: InMemoryTagCredentialStore(),
            protection: protection,
            unlockCredential: unlockCredential,
            // The single-tap shape, so the subject of each test is the data
            // area rather than the typed-UID gate, which has its own suite.
            uidConfirmation: .notRequired
        )
    }

    /// The bytes on the tag and the bytes in the editor are deliberately
    /// different, and that is the whole assertion mechanism.
    ///
    /// A frame-level "no `A2` reached the data area" is not computable here:
    /// `SimulatedConnectedTag.writeNDEF` does not go through `transceive`, so
    /// no data-area write ever reaches the fault-injection recorder and the
    /// assertion would have passed before this change just as happily. A
    /// read-back can only tell the two apart if they differ.
    func test_aProtectionOnlyChangeLeavesTheDataAreaUntouched() async throws {
        let onTheTag = try NDEFCodec.encode([.text(TextRecord(text: "what the tag holds"))])
        let chip = NTAG213Simulator(ndefMessage: onTheTag)
        let editor = armedEditor(records: [.text(TextRecord(text: "what the editor holds"))])

        XCTAssertEqual(
            editor.dataAreaChange, .untouched,
            "an unedited editor with only a protection change staged writes no records"
        )

        let model = write(
            editor.dataAreaChange,
            to: chip,
            protection: editor.pendingProtection(),
            unlockCredential: editor.protectionCredential
        )
        await model.begin()

        XCTAssertEqual(model.phase, .done, "expected .done, got \(model.phase)")
        XCTAssertEqual(try chip.readNDEF(), onTheTag, "the tag's own message must still be the one on it")
        XCTAssertEqual(try chip.authenticate(password: password), pack, "and the protection change did run")
    }

    /// The `!hasProtectionChange` half of `dataAreaChange`, which `isDirty`
    /// alone would get wrong.
    ///
    /// A history row nobody has edited is not dirty, and its Write button is
    /// still offered, because putting stored content onto a tag is what it is
    /// for. An unedited *live scan* is not offered Write at all (2026-09-25), so
    /// this is the history editor's press.
    func test_pressingWriteOnAnUneditedTagWithNothingStagedStillRewritesIt() async throws {
        let chip = try NTAG213Simulator(
            ndefMessage: NDEFCodec.encode([.text(TextRecord(text: "what the tag holds"))])
        )
        let editor = EditFlowModel(records: [.text(TextRecord(text: "as scanned"))], origin: .history)

        XCTAssertFalse(editor.isDirty, "nothing was edited")
        XCTAssertFalse(editor.hasProtectionChange, "and nothing is staged")
        XCTAssertEqual(editor.dataAreaChange, .replace(editor.records), "so the write is still a write")

        let model = write(editor.dataAreaChange, to: chip)
        await model.begin()

        XCTAssertEqual(model.phase, .done, "expected .done, got \(model.phase)")
        XCTAssertEqual(
            try chip.readNDEF(), try NDEFCodec.encode(editor.records),
            "the records in hand must reach the tag"
        )
    }

    /// A protection-only change never read the data area, so it may not publish
    /// a verdict about it.
    ///
    /// The flag it would have published is optimistic, and a `try?`-guarded
    /// read whose only output is an optimistic flag is "an ACK is not proof"
    /// inverted. The mirror of the same rule is that an unformatted data area
    /// must not fail a change that never promised to repair it.
    func test_aProtectionOnlyWriteClaimsNoNDEFReadability() async throws {
        let chip = try NTAG213Simulator(
            ndefMessage: NDEFCodec.encode([.text(TextRecord(text: "held"))])
        )
        let editor = armedEditor(records: [.text(TextRecord(text: "held"))])
        let model = write(
            editor.dataAreaChange,
            to: chip,
            protection: editor.pendingProtection(),
            unlockCredential: editor.protectionCredential
        )

        await model.begin()

        XCTAssertEqual(model.phase, .done, "expected .done, got \(model.phase)")
        XCTAssertNotNil(
            model.observation?.protection,
            "the protection change is read back, and that reading is published"
        )
        XCTAssertNil(
            model.observation?.ndefReadable,
            "nothing read the data area on this tap, so nothing may claim it is readable"
        )
    }
}
