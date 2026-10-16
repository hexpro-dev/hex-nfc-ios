@testable import HexNFCApp
@testable import HexNFCKit
@testable import HexNFCRecords
@testable import HexNFCTagSim
import XCTest

/// The product the two routes are supposed to agree over, and the cells they
/// are not asked to.
///
/// The app offers three operations twice. Erase, protect and remove protection
/// each have a standalone verb on the Operations sheet (`OperationsFlowModel`)
/// and a counterpart on the editor's Write (`WriteFlowModel`), and the
/// requirement behind eighteen commits of this branch is that a tag cannot tell
/// which one the user picked. Nothing in the repo could check that: every suite
/// here drives one route or the other, so "the two behave the same" was a habit
/// rather than a property. This file declares the property's domain; the
/// harness runs it and `RouteParityTests` asserts it.
///
/// The domain is {erase, arm, remove} x {unprotected, writeGated, readGated} x
/// {NTAG213, NTAG424 DNA, ICODE SLIX2, Ultralight C}, which is 36 cells. Ten of
/// them are excluded and each exclusion carries its reason below. A cell may
/// move from `included` to `excluded`, but only with a reason attached: the
/// census test pins all three counts, so a suite that quietly shrinks fails
/// instead of passing with less to say.
enum RouteParity {
    /// The four chips with a protection backend, one per family the app can arm.
    enum Chip: String, CaseIterable, Sendable {
        case ntag213
        case ntag424
        case icodeSlix2
        case ultralightC

        var label: String {
            switch self {
            case .ntag213: "NTAG213"
            case .ntag424: "NTAG424 DNA"
            case .icodeSlix2: "ICODE SLIX2"
            case .ultralightC: "Ultralight C"
            }
        }
    }

    /// What the tag is holding when the run starts.
    ///
    /// Seeded by running the shipped arm against the simulator, so every gated
    /// cell starts from a state a real arm produces rather than one a test poked
    /// into the pages.
    enum TagState: String, CaseIterable, Sendable {
        case unprotected
        case writeGated
        case readGated

        var label: String {
            switch self {
            case .unprotected: "unprotected"
            case .writeGated: "write-gated"
            case .readGated: "read-gated"
            }
        }
    }

    /// The three operations both routes offer.
    ///
    /// The attempt limit, the permanent lock, the format and the memory dump are
    /// deliberately absent: CLAUDE.md makes the first two standalone Operations
    /// verbs that the editor may never batch, and the other two have no editor
    /// counterpart at all. Asserting parity over an operation only one route has
    /// would be asserting that the other route is missing something.
    enum Operation: String, CaseIterable, Sendable {
        case erase
        case arm
        case remove

        var label: String {
            switch self {
            case .erase: "erase"
            case .arm: "arm"
            case .remove: "remove"
            }
        }
    }

    struct Cell: Hashable, Sendable, CustomStringConvertible {
        let operation: Operation
        let state: TagState
        let chip: Chip

        var description: String {
            "\(operation.label) on a \(state.label) \(chip.label)"
        }
    }

    /// A cell the matrix does not assert, and why.
    ///
    /// The reason is required rather than optional because it is the only thing
    /// standing between an honest exclusion and a quiet one, and every reason
    /// here names where it comes from: a datasheet clause, a bench finding, a
    /// symbol in this repo, or a measurement with its date.
    struct Exclusion: Sendable {
        let cell: Cell
        let reason: String
    }

    static let allCells: [Cell] = Operation.allCases.flatMap { operation in
        TagState.allCases.flatMap { state in
            Chip.allCases.map { Cell(operation: operation, state: state, chip: $0) }
        }
    }

    // MARK: - Exclusions

    /// A read-gated Ultralight C never arrives identified, so no route can act
    /// on one.
    ///
    /// The reasoning is the doc comment on
    /// `TagFamily.gateIsSafeToReadBeforeAuthenticating`: an Ultralight C keeps
    /// AUTH0 and AUTH1 at pages 2Ah/2Bh, and a read gate hides the very pages
    /// `ChipCatalog` identifies the chip from, so the tag never reaches a flow as
    /// an Ultralight C (bench finding 14). The app refuses to create the state at
    /// all: `UltralightCProtectionDriver.enable` throws without an explicit
    /// `armReadGateUnrecoverably` opt-in that nothing passes, which is what
    /// seeding these three cells runs into first.
    private static let readGatedUltralightCReason = """
    a read-gated Ultralight C hides pages 28h-2Bh, which are the only pages the \
    chip is identified from, so it never arrives identified and no route can act \
    on it. See the doc comment on TagFamily.gateIsSafeToReadBeforeAuthenticating \
    (bench finding 14). Seeding the state is refused by \
    UltralightCProtectionDriver.enable without armReadGateUnrecoverably, which \
    nothing passes.
    """

    /// A SLIX2 read gate is privacy mode, and a privacy-mode label is gone.
    ///
    /// SL2S2602 §9.5.3.9: a tag in privacy mode answers no inventory. CoreNFC
    /// only ever vends inventoried tags, so the tag stops being discoverable, and
    /// `Iso15693Simulator` models that silence. The app no longer offers
    /// "Read + write" for the family at all, and `Iso15693ProtectionClient.enable`
    /// refuses a read password without `armPrivacyIrreversibly`.
    private static let readGatedSlix2Reason = """
    a SLIX2 read gate is privacy mode, a privacy-mode label answers no inventory \
    (SL2S2602 §9.5.3.9), and CoreNFC only ever vends inventoried tags, so no route \
    can reach the tag again. The app no longer offers "Read + write" for this \
    family and Iso15693ProtectionClient.enable refuses a read password without \
    armPrivacyIrreversibly; Iso15693Simulator already models the silence.
    """

    /// A removal against a tag with no gate is not the same request on the two
    /// routes, and the matrix is not the place to decide which one is right.
    ///
    /// Measured on 2026-09-21 at 86f3666, on all four chips: Operations refuses
    /// it on the identify tap with `TagError.nothingToRemove`
    /// (`OperationsPreflight`, `case .disableProtection`), while the editor
    /// completes it as a no-op, because `WriteFlowModel`'s removal branch is
    /// `else if removeProtection, let unlockCredential` and an open tag is never
    /// asked for one. Neither route writes anything, so no tag is harmed either
    /// way.
    ///
    /// They differ because the two are not asked the same question.
    /// `EditFlowModel.wantsProtectionRemoved` is
    /// `originalProtection.passwordProtect && !protection.passwordProtect`, so the
    /// editor can only be told to remove protection from a tag it read as
    /// protected; reaching this cell there means the tag changed between the scan
    /// and the write. Operations' Remove is a verb the user chose against the
    /// reading on screen, and refusing it there is the honest answer. In the
    /// editor the removal is a rider on a write that still has records to put
    /// down, and failing the whole write over a moot rider would be the wrong
    /// answer.
    ///
    /// Settled 2026-09-21: the difference stands, and the editor's side is now
    /// stated at the branch rather than left to a nil binding that reads like an
    /// oversight. The cell stays excluded because the two routes are answering
    /// different questions, not because nobody has decided.
    private static let removalWithNothingToRemoveReason = """
    the two routes are not asked the same question here. Operations refuses a \
    removal on a proven-open tag on the identify tap (TagError.nothingToRemove, \
    OperationsPreflight case .disableProtection); the editor completes it as a \
    no-op, because EditFlowModel.wantsProtectionRemoved can only stage a removal \
    against a tag the editor read as protected, so this cell is only reachable \
    there when the tag changed between the scan and the write. Neither route \
    writes anything. Measured on all four chips on 2026-09-21 at 86f3666 and \
    settled the same day: the difference stands because the two screens ask \
    different questions, and WriteFlowModel's removal branch now says so.
    """

    static let exclusions: [Exclusion] = {
        var excluded: [Exclusion] = []
        for operation in Operation.allCases {
            excluded.append(Exclusion(
                cell: Cell(operation: operation, state: .readGated, chip: .ultralightC),
                reason: readGatedUltralightCReason
            ))
            excluded.append(Exclusion(
                cell: Cell(operation: operation, state: .readGated, chip: .icodeSlix2),
                reason: readGatedSlix2Reason
            ))
        }
        for chip in Chip.allCases {
            excluded.append(Exclusion(
                cell: Cell(operation: .remove, state: .unprotected, chip: chip),
                reason: removalWithNothingToRemoveReason
            ))
        }
        return excluded
    }()

    static let included: [Cell] = {
        let refused = Set(exclusions.map(\.cell))
        return allCells.filter { !refused.contains($0) }
    }()

    static func cells(for operation: Operation) -> [Cell] {
        included.filter { $0.operation == operation }
    }

    // MARK: - The census

    /// What the matrix covered when it was written. A cell may leave `included`,
    /// but only by arriving in `exclusions` with a reason, and only by moving
    /// these numbers deliberately.
    static let cellCount = 36
    static let excludedCount = 10
    static let includedCount = 26
}

// MARK: - What a cell is made of

extension RouteParity {
    /// The message every cell's tag starts out carrying.
    ///
    /// Deliberately not the bytes any operation in the matrix would write. An
    /// erase writes an empty message and an arm or a removal writes nothing at
    /// all, so a data area seeded with either would be unable to tell "left
    /// alone" from "rewritten with the same thing". `SimulatedConnectedTag`'s
    /// `writeNDEF` does not go through `transceive`, so no data-area frame ever
    /// reaches the recorder and the read-back is the only evidence there is.
    static let seedText = "parity-seed"

    /// A tag of this family, formatted and carrying `seedText`.
    ///
    /// Seeded through the production write rather than a per-chip constructor
    /// argument, so all four carry the same message by the same route. A SLIX2
    /// built with `Iso15693Simulator.slix2()` otherwise starts with an empty NDEF
    /// TLV, which is exactly the state an erase would leave it in.
    static func makeChip(_ chip: Chip) async throws -> ChipSimulator {
        let simulator: ChipSimulator = switch chip {
        case .ntag213: NTAG213Simulator()
        case .ntag424: NTAG424DNASimulator()
        case .icodeSlix2: Iso15693Simulator.slix2()
        case .ultralightC: MifareUltralightCSimulator(ndefMessage: Data([0xD0, 0x00, 0x00]))
        }
        simulator.beginActivation()
        try await SimulatedConnectedTag(simulator: simulator)
            .writeNDEF([.text(TextRecord(text: seedText))])
        simulator.beginActivation()
        return simulator
    }

    /// The credential the tag is holding when the run starts, and the one the
    /// harness hands over when a route asks for one.
    static func heldCredential(_ chip: Chip) throws -> TagCredential {
        switch chip {
        case .ntag213:
            .type2(password: Data([0x0A, 0x0B, 0x0C, 0x0D]), pack: Data([0x1E, 0x2F]))

        case .ntag424:
            .type4(aesKey: Data((0 ..< 16).map { UInt8(0x30 + $0) }), keySlot: 0)

        case .icodeSlix2:
            .type5(password: Data([0x11, 0x22, 0x33, 0x44]), kind: .write)

        case .ultralightC:
            try .ultralightC(key: UltralightCKey(cipherOrder: Data((0 ..< 16).map { UInt8(0x50 + $0) })))
        }
    }

    /// The credential an arm puts on the tag. Deliberately not the one the tag
    /// already holds: a re-key that writes back the same secret cannot tell a
    /// route that dropped the caller's credential from one that carried it.
    static func armCredential(_ chip: Chip) throws -> TagCredential {
        switch chip {
        case .ntag213:
            .type2(password: Data([0xC0, 0xC1, 0xC2, 0xC3]), pack: Data([0xD0, 0xD1]))

        case .ntag424:
            .type4(aesKey: Data((0 ..< 16).map { UInt8(0x60 + $0) }), keySlot: 0)

        case .icodeSlix2:
            .type5(password: Data([0x55, 0x66, 0x77, 0x88]), kind: .write)

        case .ultralightC:
            try .ultralightC(key: UltralightCKey(cipherOrder: Data((0 ..< 16).map { UInt8(0x70 + $0) })))
        }
    }

    /// Family-shaped protection settings.
    ///
    /// `readProtect` is false for every arm the matrix runs, on all four
    /// families, because two of them cannot carry a read gate at all and a
    /// per-family arm would stop the four cells of a row being the same request.
    static func settings(_ chip: Chip, readProtect: Bool) -> TagProtection {
        var settings = TagProtection(passwordProtect: true, hasStoredCredential: true)
        switch chip {
        case .ntag213:
            settings.readProtect = readProtect

        case .ntag424:
            settings.style = .type4(.init(keySlot: 0, readProtect: readProtect))

        case .icodeSlix2:
            settings.style = .type5(.init(kind: readProtect ? .readWrite : .write))

        case .ultralightC:
            settings.style = .ultralightC(.init(protectFromPage: nil, readProtect: readProtect))
        }
        return settings
    }

    /// What an arm in this matrix stages, on either route.
    static func stagedArm(_ chip: Chip) throws -> PendingProtection {
        try PendingProtection(settings: settings(chip, readProtect: false), credential: armCredential(chip))
    }

    /// Put the cell's starting gate on the tag by running the shipped arm.
    ///
    /// The simulators have no seed helper for three of the four families, and the
    /// one that does (`NTAG21xSimulator.enablePasswordProtection`) is a
    /// second implementation of the sequence rather than the sequence itself.
    /// Arming through `ConnectedTag.enableProtection` gives all four cells of a
    /// row the same provenance and guarantees the state is one the app can
    /// actually produce, which is what refuses the two read-gated families here
    /// rather than three assertions later.
    static func seedGate(on simulator: ChipSimulator, _ cell: Cell) async throws {
        guard cell.state != .unprotected else { return }
        simulator.beginActivation()
        let tag = SimulatedConnectedTag(simulator: simulator)
        let firstDataPage = tag.chip?.memoryLayout.ndefRange?.lowerBound ?? 4
        guard let spec = try ProtectionSpec.make(
            settings: settings(cell.chip, readProtect: cell.state == .readGated),
            credential: heldCredential(cell.chip),
            defaultFirstDataPage: firstDataPage
        ) else {
            throw TagError.capabilityUnsupported(
                .passwordAuth,
                diagnostics: "no protection spec for \(cell)"
            )
        }
        _ = try await tag.enableProtection(spec, replacing: nil)
        simulator.beginActivation()
    }
}

// MARK: - What a cell is supposed to do

extension RouteParity {
    /// The class of ending, which is as far as the two routes can be compared.
    ///
    /// The wording below it cannot: Operations names the verb it refused and the
    /// editor names the write, and both are right. What must match is whether the
    /// tag ended up changed or untouched.
    enum Outcome: Equatable, Sendable {
        case completed
        case refused
    }

    /// The gate a read-back found, coarse enough to state as an expectation.
    ///
    /// The routes are compared on the whole `TagProtection` they read back, AUTH0
    /// included; this is only the shape the pin is written in.
    enum GateClass: Equatable, Sendable {
        case open
        case writeGated
        case readGated
        /// The tag would not say, and the harness ran out of credentials to ask
        /// with. Never expected by a cell in this matrix, and a value rather than
        /// a fatal error so a failure can print what it found.
        case unreadable
    }

    /// Every included cell is one both routes carry out.
    ///
    /// Stated as a rule rather than a table because a refusal in this matrix is
    /// either a difference between the routes or a chip that cannot carry the
    /// operation, and both of those are exclusions rather than expectations.
    static func expectedOutcome(_: Cell) -> Outcome {
        .completed
    }

    /// What the tag's gate has to look like afterwards.
    ///
    /// An erase leaves the gate exactly as it found it: it writes the data area
    /// and nothing above it, on either route. An arm ends write-gated, which is
    /// what every arm in this matrix stages. A removal ends open, which is the
    /// read-back `TagCredentialLedger` settles a removal against.
    static func expectedGate(_ cell: Cell) -> GateClass {
        switch cell.operation {
        case .erase:
            switch cell.state {
            case .unprotected: .open
            case .writeGated: .writeGated
            case .readGated: .readGated
            }

        case .arm:
            .writeGated

        case .remove:
            .open
        }
    }

    /// How many credential-bearing frames the work tap is expected to put on the
    /// wire, per `NFCTraceRedaction.isSecretFrame`.
    ///
    /// Derived from that one rule rather than from a list restated here: it is
    /// already the single source for which frames carry a secret, it is
    /// chip-dependent in the way this matrix needs (the PWD page is 43 on an
    /// NTAG213 and user memory on an NTAG216), and it already carries the SLIX
    /// privacy and destroy opcodes a hand-written list would forget.
    ///
    /// **This is a count, not a bound, and the count is above one.** An arm on a
    /// read-gated NTAG213 puts three `PWD_AUTH` frames on one activation: the
    /// preamble's, `Type2PasswordDriver.enable`'s own, and the one its read-back
    /// takes afterwards. CLAUDE.md's "one authentication attempt per activation"
    /// is about never re-presenting a *refused* credential, because the NAK halts
    /// the chip; it does not say an accepted credential is presented once. So the
    /// honest assertion is that the two routes spend the same frames, and that
    /// the number has not moved since it was measured, which is what this pins.
    /// Measured on 2026-09-21 at 86f3666.
    static func expectedCredentialFrames(_ cell: Cell) -> Int {
        switch (cell.operation, cell.state) {
        case (.erase, .unprotected):
            0

        case (.erase, .writeGated), (.erase, .readGated):
            switch cell.chip {
            case .ntag213, .icodeSlix2: 1
            case .ntag424, .ultralightC: 2
            }

        case (.arm, .unprotected):
            switch cell.chip {
            case .ntag213: 3
            case .ntag424: 5
            case .icodeSlix2, .ultralightC: 4
            }

        case (.arm, .writeGated), (.arm, .readGated):
            switch cell.chip {
            case .ntag213, .icodeSlix2: 5
            case .ntag424: 9
            case .ultralightC: 6
            }

        case (.remove, .writeGated), (.remove, .readGated):
            switch cell.chip {
            case .ntag213: 4
            case .ntag424, .icodeSlix2: 5
            case .ultralightC: 6
            }

        case (.remove, .unprotected):
            0
        }
    }
}
