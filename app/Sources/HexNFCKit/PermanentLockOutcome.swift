import Foundation

/// What a permanent lock actually burned.
///
/// A permanent lock is the one operation with no undo, and it is a *sequence*:
/// on a Type-2 chip the static lock bytes and the dynamic lock page are two
/// separate writes. So "it threw" is not a description of the tag, and on this
/// operation the difference matters more than anywhere else in the app.
///
/// The incident that produced this type (2026-09-04, NTAG213): a permanent lock
/// ran on a still-password-protected tag with no authentication. Page 2 sits
/// below AUTH0, so the static lock bytes were accepted and pages 3 to 15 were
/// burned forever. Page 0x28 sits above AUTH0, so the dynamic lock write was
/// NAKed. The app reported a plain failure, and the user was never told that
/// half their tag had just become read-only.
public struct PermanentLockOutcome: Hashable, Sendable {
    /// The two writes a Type-2 permanent lock makes, in the order they are now
    /// attempted. Type-5 reports a single `blocks` stage.
    public enum Stage: String, Hashable, Sendable {
        /// The dynamic lock page. Written **first**: it is the one that sits
        /// above AUTH0, so on a gated tag it is refused before anything
        /// irreversible has happened.
        case dynamicLock
        /// The static lock bytes at page 2, covering pages 3 to 15.
        case staticLock
        /// ISO 15693 `LOCK_BLOCK` across the data blocks.
        case blocks
    }

    public enum StageResult: Hashable, Sendable {
        /// Written and read back: the bits are set.
        case committedVerified
        /// Written and acknowledged, but not read back. Either the chip does not
        /// latch in this activation, or no read-back is trusted for this stage
        /// yet. Not a failure, and not a proof.
        case committedUnverified(reason: String)
        /// Part of a stage that covers many units burned and the rest did not,
        /// with the split read back from the chip. Only Type-5 can report it:
        /// `LOCK_BLOCK` is one frame per block, so a refusal partway through is
        /// a real state that no single verdict here could otherwise describe.
        ///
        /// `locked` is always at least 1. A stage that burned nothing is
        /// `.refused`, and a stage that burned everything is `.committedVerified`.
        case partiallyCommitted(locked: Int, of: Int, diagnostics: String)
        /// The chip refused, or a read-back afterwards proved the bits are still
        /// clear. Either way nothing was burned by this stage, and that is
        /// **known** rather than assumed.
        case refused(diagnostics: String)
        /// No acknowledgement, no stated refusal, and the chip could not be asked
        /// afterwards. Whether the bits burned is not known.
        ///
        /// This case exists because a transport loss used to be filed as
        /// `.refused`, which made `burnedNothing` true and printed "Nothing was
        /// locked." over an irreversible write whose acknowledgement may simply
        /// have been dropped. CLAUDE.md: a refusal may be a lost ACK, and on the
        /// one operation with no undo the difference is the whole report.
        case inconclusive(diagnostics: String)
        /// Not attempted, because an earlier stage refused or the pre-flight
        /// stopped the operation.
        case notAttempted
    }

    public var stages: [Stage: StageResult]
    /// The order stages were attempted, so a report can read chronologically.
    public var order: [Stage]

    public init(stages: [Stage: StageResult] = [:], order: [Stage] = []) {
        self.stages = stages
        self.order = order
    }

    public mutating func record(_ stage: Stage, _ result: StageResult) {
        stages[stage] = result
        if !order.contains(stage) {
            order.append(stage)
        }
    }

    /// `true` when at least one stage burned bits and at least one did not.
    /// **This is the state the user must be told about**, because the tag is now
    /// permanently part-locked and no retry can undo or complete it uniformly.
    ///
    /// A single stage that part-burned counts on its own: a Type-5 lock that got
    /// through forty blocks of eighty is exactly this state, reported by one
    /// stage rather than two.
    public var isPartial: Bool {
        if order.contains(where: {
            if case .partiallyCommitted = stages[$0] {
                return true
            }
            return false
        }) {
            return true
        }
        return !committed.isEmpty && !refused.isEmpty
    }

    /// `true` when nothing at all was burned **and that is known**. The safe
    /// outcome of a refusal.
    ///
    /// An inconclusive stage is deliberately not "nothing": its bits may have
    /// burned with the acknowledgement that never arrived, and this property is
    /// what decides whether the user is told the operation was a no-op.
    public var burnedNothing: Bool {
        committed.isEmpty && inconclusive.isEmpty
    }

    public var committed: [Stage] {
        order.filter {
            switch stages[$0] {
            case .committedVerified, .committedUnverified, .partiallyCommitted: true
            default: false
            }
        }
    }

    public var refused: [Stage] {
        order.filter {
            if case .refused = stages[$0] {
                return true
            }
            return false
        }
    }

    /// Stages whose bits may or may not have burned.
    public var inconclusive: [Stage] {
        order.filter {
            if case .inconclusive = stages[$0] {
                return true
            }
            return false
        }
    }

    public var diagnostics: String {
        var lines = ["permanentLock partial=\(isPartial) burnedNothing=\(burnedNothing)"]
        for stage in order {
            switch stages[stage] {
            case .committedVerified:
                lines.append("\(stage.rawValue): committed, read back")

            case .committedUnverified(let reason):
                lines.append("\(stage.rawValue): committed, not verified (\(reason))")

            case .partiallyCommitted(let locked, let total, let diagnostics):
                lines.append("\(stage.rawValue): committed \(locked)/\(total), read back (\(diagnostics))")

            case .refused(let diagnostics):
                lines.append("\(stage.rawValue): refused (\(diagnostics))")

            case .inconclusive(let diagnostics):
                lines.append("\(stage.rawValue): inconclusive (\(diagnostics))")

            case .notAttempted, .none:
                lines.append("\(stage.rawValue): not attempted")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// One sentence for the user. A partial burn says so plainly: it is
    /// irreversible and they need to know which half happened.
    ///
    /// The order of these branches is the order of how bad the news is, and the
    /// unknown outranks the empty: "Nothing was locked." is reserved for the case
    /// where nothing burned **and the chip said so**. A write whose answer never
    /// arrived is reported as the unknown it is, because the bits may have burned
    /// with it.
    public var userMessage: LocalizedStringResource {
        if isPartial {
            return "This tag is now partly locked, and that cannot be undone. Some of its memory is read-only for good; the rest was refused and is still writable."
        }
        if !inconclusive.isEmpty {
            return committed.isEmpty
                ? "The tag stopped answering during a lock that cannot be undone, so this app cannot say whether any of its memory is now read-only. Treat this tag as one that may be locked."
                : "Part of this tag is now read-only for good, and that cannot be undone. The tag stopped answering before the rest could be confirmed, so the rest may be locked as well."
        }
        if burnedNothing {
            return "Nothing was locked."
        }
        return "Tag permanently locked."
    }
}
