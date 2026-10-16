import XCTest

/// Source-text guards over `OperationsSheet.swift`, walked off disk through
/// `#filePath`.
///
/// That file opens with `#if os(iOS)`, so `swift test` on macOS never compiles a
/// line of it and no ordinary assertion can reach its call sites. Reading the
/// source is the only coverage the macOS job can give it, which is the same
/// reason `AttemptLimitContainmentTests` and `PromoImportContainmentTests` read
/// their sources rather than their modules. These check text, not types: the
/// `xcodebuild -destination generic/platform=iOS` job is what type-checks the
/// file, and it is deliberately independent of this one.
///
/// What they pin has changed shape. The guards used to be about a credential
/// *frozen* into a run at `launch()`: the field went on looking live while the
/// operation carried the value it had been built with, so they demanded
/// `.disabled(model != nil)` beside every field and an explicit `onRetry:` on
/// every screen that had one. Both were treatments for the same underlying
/// fault, which was that these screens collected a secret before anything had
/// looked at the tag. Nothing collects one there now, so the guards pin *that*
/// instead, which is the property the treatments were standing in for.
final class OperationsSheetAffordanceTests: XCTestCase {
    private static var sheetURL: URL {
        URL(fileURLWithPath: #filePath) // …/app/Tests/HexNFCAppTests/OperationsSheetAffordanceTests.swift
            .deletingLastPathComponent() // …/HexNFCAppTests
            .deletingLastPathComponent() // …/Tests
            .deletingLastPathComponent() // …/app
            .appendingPathComponent("Sources/HexNFCApp/Screens/OperationsSheet.swift")
    }

    private func sheetSource() throws -> String {
        let text = try String(contentsOf: Self.sheetURL, encoding: .utf8)
        XCTAssertTrue(
            text.contains("destructiveBody("),
            "read \(Self.sheetURL.lastPathComponent) but it does not contain `destructiveBody(`. "
                + "The file moved or was renamed and every guard below is inert."
        )
        return text
    }

    /// A region per `private struct`, keyed by the type name.
    ///
    /// `destructiveBody` itself is a `private func`, so it lands in the region of
    /// whichever struct precedes it. `struct HexHexField: View` is not `private`
    /// and never writes its own name with an open paren, so the tail region
    /// contributes nothing either.
    private func regions(in source: String) -> [(name: String, body: String)] {
        source.components(separatedBy: "\nprivate struct ")
            .dropFirst()
            .map { region -> (name: String, body: String) in
                let name = region.prefix { $0 != ":" && $0 != "<" && $0 != " " && $0 != "\n" }
                return (String(name), region)
            }
    }

    /// Nothing on an operation screen collects a secret before the tag has been
    /// read.
    ///
    /// This is the whole of what the adaptive screens bought. "Protect with
    /// password" used to open with a 4-byte password already in its field and a
    /// live Continue button, one whole tap before anything had looked at the
    /// chip, which is two faults in one layout: a secret was committable against
    /// a tag nobody had seen, and the arm it built could only be Type-2, so an
    /// NTAG424 DNA, an Ultralight C and an ICODE SLIX2 all dead-ended on
    /// `capabilityUnsupported` with copy blaming the chip.
    ///
    /// The rule is positional rather than a list of names, so a screen added
    /// later inherits it: inside a screen that runs `destructiveBody`, a
    /// `HexHexField(` may only appear after that screen has keyed something on
    /// `.awaitingConfirmation`, which is the first phase a reading exists in.
    func test_noSecretFieldIsRenderedBeforeTheTagHasBeenRead() throws {
        let screens = try regions(in: sheetSource()).filter { $0.body.contains("destructiveBody(") }
        XCTAssertFalse(screens.isEmpty, "no screen runs a destructive body; the parse has broken")

        var fieldsChecked = 0
        for screen in screens {
            let lines = screen.body.components(separatedBy: "\n")
            let gate = lines.firstIndex { $0.contains("awaitingConfirmation") }
            for (index, line) in lines.enumerated() where line.contains("HexHexField(") {
                fieldsChecked += 1
                guard let gate, gate < index else {
                    return XCTFail(
                        "\(screen.name) renders a `HexHexField(` at line \(index + 1) of its region with no "
                            + "`.awaitingConfirmation` branch above it. That field is on screen before the "
                            + "identify tap has read the tag, so its secret is committable against a chip "
                            + "nothing has looked at and its shape is a guess about the family."
                    )
                }
            }
        }
        XCTAssertEqual(
            fieldsChecked, 5,
            "expected five fields behind a reading: the Protect screen renders one arm per family, so "
                + "Type-2's password and PACK, Type-4's key, Type-5's password and Ultralight C's key. "
                + "Found \(fieldsChecked). A field was added or removed without this guard moving."
        )
    }

    /// The tag's own secret has one collector in this sheet.
    ///
    /// `OperationUnlockCard` is it, and it is the one consumer here of the
    /// `ProtectionStyle` vocabulary that says how many bytes a family's secret is
    /// and how to package it (`UnlockPrompt.swift`). `ScanSheet` and `WriteSheet`
    /// share that vocabulary so the three cannot drift about it, and a second
    /// field in this file answering the same three questions for itself is
    /// exactly where a fourth answer would appear. Two screens used to do
    /// precisely that, each with its own `.type2(password:pack:)` literal, which
    /// is why neither worked on a chip that takes a key.
    func test_theTagsOwnSecretHasOneCollectorInThisSheet() throws {
        let source = try sheetSource()
        XCTAssertEqual(
            source.components(separatedBy: "supplyUnlockCredential(").count - 1, 1,
            "the credential the tag is holding reaches the run through exactly one call in this sheet, "
                + "from the unlock card's own closure. A second call site is a second field for one secret."
        )
        for member in ["unlockSecretDescription", "unlockSecretByteCount", "unlockCredential(from:"] {
            let owners = regions(in: source)
                .filter { $0.body.contains(member) }
                .map(\.name)
            XCTAssertEqual(
                owners, ["OperationUnlockCard"],
                "`\(member)` is the shared unlock vocabulary and belongs to the unlock card alone. "
                    + "Found it in \(owners)."
            )
        }
    }

    /// The sheet builds no arm of its own.
    ///
    /// `ProtectionArm.pending(for:)` is the one place a `PendingProtection`
    /// is assembled for this route, and it lives outside `Screens/` for the
    /// reason `ProtectionCardSeed` does: a rule kept in an `#if os(iOS)` file can
    /// only ever be reviewed. What it decides is which secret reaches a tag and
    /// whether that tag's reads end up gated, and a read gate armed on a SLIX2 or
    /// an Ultralight C takes the tag away for good.
    func test_theSheetBuildsNoArmOfItsOwn() throws {
        let source = try sheetSource()
        XCTAssertFalse(
            source.contains("PendingProtection("),
            "an arm is built by `ProtectionArm.pending(for:)`, which is compiled and tested on macOS. "
                + "A `PendingProtection(` here is one that is not."
        )
        XCTAssertTrue(
            source.contains("operation: .enableProtection(ProtectionArm.unstaged)"),
            "the Protect screen's run starts unstaged, so the identify tap asserts no family against a "
                + "tag nothing has read yet and the typed-UID gate stays shut until stage 2 fills it in."
        )
    }

    /// The unlock card's field is the one that must stay editable, stated here
    /// so the exception is deliberate rather than an omission.
    ///
    /// The run has already started, has stopped with no session open, and is
    /// waiting for exactly this input: the typed-UID gate will not open without
    /// it and `.needsUnlock` cannot be answered without it. Disabling it would
    /// be a dead end rather than a safety property.
    func test_theUnlockCardsFieldIsTheOneThatStaysEditable() throws {
        let source = try sheetSource()
        let region = try XCTUnwrap(
            source.components(separatedBy: "\nprivate struct OperationUnlockCard").dropFirst().first,
            "OperationUnlockCard has moved or been renamed and this guard is inert"
        )
        let card = region.components(separatedBy: "\nprivate struct ")[0]
        XCTAssertEqual(
            card.components(separatedBy: "HexHexField(").count - 1, 1,
            "the unlock card collects one secret"
        )
        // `.disabled(credential == nil)` on the card's own button is fine and
        // is the point of it. What may not appear is the freeze the launch
        // screens used to carry, which keyed a field's editability off the run
        // existing at all.
        XCTAssertFalse(
            card.contains(".disabled(model"),
            "the run has stopped and is waiting on this field; freezing it on the run strands the flow"
        )
    }

    /// A model built inside a presentation carries on from the one it replaces.
    ///
    /// A flow reports an empty sheet quietly only while no session of it has
    /// had a tag (`TagContact`), and that record lives on the model. The screens
    /// here build their model once, in `init`, except Set attempt limit, whose
    /// Start over hands the stepper back by dropping the model and whose
    /// Continue builds another. Without the hand-on, a cancel on the recovery
    /// tap after an arm that slipped would go back to the stepper in silence,
    /// about a tag whose limit may have landed.
    func test_aModelRebuiltInsideAPresentationInheritsTagContact() throws {
        let source = try sheetSource()
        let rebuilds = source.components(separatedBy: "model = OperationsFlowModel(").dropFirst()
        XCTAssertFalse(rebuilds.isEmpty, "the attempt-limit screen's `launch()` moved and this guard is inert")
        for rebuild in rebuilds {
            let call = rebuild.components(separatedBy: "\n        )")[0]
            XCTAssertTrue(
                call.contains("earlierRunMayHaveTouchedATag: earlierRunMayHaveTouchedATag"),
                "a model built after the screen's first one must be told whether an earlier one had a tag"
            )
        }

        let region = try XCTUnwrap(
            regions(in: source).first { $0.name == "SetAttemptLimitOperationView" }?.body,
            "SetAttemptLimitOperationView moved or was renamed and this guard is inert"
        )
        XCTAssertEqual(
            region.components(separatedBy: "model = nil").count - 1, 1,
            "the model is dropped in one place"
        )
        let startOver = try XCTUnwrap(
            region.range(of: "private func startOver(from model: OperationsFlowModel) {"),
            "and that place is `startOver(from:)`"
        )
        let drop = try XCTUnwrap(region.range(of: "model = nil"))
        XCTAssertLessThan(startOver.upperBound, drop.lowerBound)
        XCTAssertTrue(
            region[startOver.upperBound ..< drop.lowerBound].contains("model.mayHaveTouchedATag"),
            "which records what the old model knew before dropping it"
        )
    }
}
