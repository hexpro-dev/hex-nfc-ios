import Foundation
import HexNFCKit
import HexNFCRecords

/// What an `Operation` *is*, as opposed to what a run of one does.
///
/// Four questions the flow asks of the verb and never of the tag: what it is
/// going to touch, whether it is irreversible enough to need a typed UID,
/// whether it proves its own outcome by reading it back, and what it is called.
/// Split out of `OperationsFlowModel` when that file outgrew its length limit,
/// which is the same reason `OperationsPreflight` was split out of it; these
/// belong together because each is exhaustive with no `default:` arm, so adding
/// an operation breaks this build rather than inheriting an answer about a tag.
extension OperationsFlowModel.Operation {
    /// What this operation is going to touch on the tag, which is what decides
    /// whether it needs the tag's credential first.
    ///
    /// Exhaustive with no `default:` arm, like the two properties below it, so
    /// adding an `Operation` breaks this build rather than inheriting an answer
    /// about a tag.
    var accessIntent: TagAccessIntent {
        switch self {
        case .erase:
            .writesDataArea

        // Format writes page 3 and reads it back, and page 3 sits below every
        // AUTH0 this app is able to write (`ProtectionSpec.make` pins a read
        // gate to the chip's first data page, and the editor's start-page
        // stepper starts there too). So a format needs no credential, by a
        // fact about where the Capability Container lives rather than by
        // anything about protection. The day `formatCC` writes anything above
        // page 3, this line moves.
        case .format:
            []

        case .permanentLock, .enableProtection, .disableProtection, .setAttemptLimit:
            .writesConfigPages

        case .memoryDump:
            .readsGatedPages
        }
    }
}

public extension OperationsFlowModel.Operation {
    /// `true` when the operation is irreversible and must run through the
    /// typed-UID confirmation gate.
    var requiresUIDConfirmation: Bool {
        switch self {
        case .erase, .format, .permanentLock, .enableProtection, .disableProtection, .setAttemptLimit:
            true

        case .memoryDump:
            false
        }
    }

    /// `true` when the operation runs a read-back verification.
    ///
    /// Everything that changes protection or lock state verifies. An ACK proves
    /// the chip accepted the frame, not that the state changed — a distinction
    /// real silicon has made twice (SLIX2 `LOCK_BLOCK`, see
    /// `docs/internal/chip-config-pages.md`). Until this was widened, the
    /// read-backs and behavioural probes that lesson produced all lived in
    /// `#if DEBUG` code, so the shipping app said "Tag permanently locked." and
    /// "Password set." on ACKs alone.
    ///
    /// `.memoryDump` is a pure read, so there is nothing to verify.
    var verifies: Bool {
        switch self {
        case .erase, .format, .permanentLock, .enableProtection, .disableProtection, .setAttemptLimit:
            true

        case .memoryDump:
            false
        }
    }

    var localizedTitle: String {
        switch self {
        case .erase: String(localized: "Erase tag")
        case .format: String(localized: "Format tag")
        case .permanentLock: String(localized: "Permanently lock")
        case .enableProtection: String(localized: "Protect with password")
        case .disableProtection: String(localized: "Remove password")
        case .setAttemptLimit: String(localized: "Attempt limit")
        case .memoryDump: String(localized: "Memory dump")
        }
    }
}
