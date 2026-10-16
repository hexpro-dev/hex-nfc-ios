import Foundation

/// Which lock unit a finding is about. Named for the write that sets it, so the
/// read and the write share one vocabulary.
public enum TagLockRegion: String, Hashable, Sendable, CaseIterable {
    /// The static lock bytes, page 2 bytes 2-3 on every catalogued Type-2 chip.
    /// They cover pages 3 to 15.
    case staticLock
    /// The dynamic lock page (40 / 130 / 226 / 36). Covers page 16 upward, and
    /// is absent on NTAG 210u and Ultralight EV1 48b, whose user area the static
    /// bytes fully cover.
    case dynamicLock
    /// ISO 15693 per-block locks. Only ever produced by an operation's outcome:
    /// nothing reads them at scan time.
    case blocks
}

/// What one lock unit is known to hold.
///
/// Every case is an answer, and the two silences are kept apart on purpose:
/// `notPresent` is a fact about the chip, `notRead` is an absence of evidence.
/// Collapsing the second into "not locked" is the defect this whole type exists
/// to prevent.
public enum TagLockFinding: Hashable, Sendable {
    /// Every bit a completed permanent lock would set reads back set.
    case allSet
    /// Some of those bits read back set and some read back clear.
    case someSet
    /// None of them is set.
    case noneSet
    /// This app wrote the bits and the chip acknowledged, and nothing has read
    /// them back. An acknowledgement is not proof, so this is not `allSet`.
    case setNotWitnessed
    /// This chip has no such lock unit.
    case notPresent
    /// Nothing was established. Never treated as "clear".
    case notRead(reason: String)

    /// `true` for the findings that say at least one irreversible bit is, or is
    /// very likely, burned.
    var impliesBurnedBits: Bool {
        switch self {
        case .allSet, .someSet, .setNotWitnessed: true
        case .noneSet, .notPresent, .notRead: false
        }
    }

    var isUnread: Bool {
        if case .notRead = self {
            return true
        }
        return false
    }
}

/// The evidence behind a lock verdict, region by region, so a chip with two
/// independent lock units cannot be flattened into one Bool.
///
/// A `Bool` cannot describe an NTAG213. The static bytes cover pages 3 to 15 and
/// the dynamic page covers 16 upward, they are two separate writes with two
/// separate verdicts, and this repo has produced the half-burned result on real
/// silicon (2026-09-04, see the trace in `Type2LockDriver`'s header).
///
/// Deliberately **not** `Codable`, following `TagDiagnostics`: a lock verdict is
/// a fact about a tag in the field right now, and giving it a persistence path
/// is how a stale "not locked" ends up presented as a finding. `TagProtection`
/// says the same thing about itself for the same reason.
public struct TagLockReading: Hashable, Sendable {
    public var regions: [TagLockRegion: TagLockFinding]
    /// The regions this chip has, in the order a permanent lock attempts them.
    public var order: [TagLockRegion]
    /// Free text for the long-press bug-report path. Never carries key bytes.
    public var diagnostics: String

    public init(
        regions: [TagLockRegion: TagLockFinding] = [:],
        order: [TagLockRegion] = [],
        diagnostics: String = ""
    ) {
        self.regions = regions
        self.order = order
        self.diagnostics = diagnostics
    }

    /// Nothing established at all. The default everywhere, and the only honest
    /// answer for a history row, a preset, or a blank build.
    public static let notRead = TagLockReading()

    public mutating func record(_ region: TagLockRegion, _ finding: TagLockFinding) {
        regions[region] = finding
        if !order.contains(region) {
            order.append(region)
        }
    }

    /// The whole-tag verdict.
    ///
    /// Half the evidence never yields a whole-tag verdict, with one exception:
    /// an irreversible burn is reported even when the other unit is unknown,
    /// because "it is not locked" is the one report that is certainly wrong
    /// about a tag that has already burned half its lock bits.
    public var state: TagLockState {
        let present = order.compactMap { regions[$0] }.filter { $0 != .notPresent }
        guard !present.isEmpty else { return .unknown }

        if present.contains(where: \.isUnread) {
            return present.contains(where: \.impliesBurnedBits) ? .partlyLocked : .unknown
        }
        if present.allSatisfy({ $0 == .noneSet }) {
            return .open
        }
        if present.allSatisfy({ $0 == .allSet }) {
            return .locked
        }
        if present.allSatisfy({ $0 == .allSet || $0 == .setNotWitnessed }) {
            return .writtenNotWitnessed
        }
        return .partlyLocked
    }
}

/// The five-way verdict the UI branches on.
public enum TagLockState: Hashable, Sendable {
    /// Not read, or this chip gives no lock evidence this app knows how to take.
    /// Never rendered as "not locked".
    case unknown
    /// Read back, and no lock bit a permanent lock would set is set.
    case open
    /// A lock was written and acknowledged, and could not be witnessed in that
    /// activation. MIFARE Ultralight C lock bits are "valid upon the next REQA
    /// or WUPA command" (MF0ICU2 rev 3.3 §7.5.3), so the next tap is the
    /// earliest anything can read them back.
    case writtenNotWitnessed
    /// Some of this tag's memory is read-only for good and some of it is not.
    /// Irreversible, and no retry can undo or complete it.
    case partlyLocked
    /// Every lock unit this chip has reports every masked bit set.
    case locked
}

public extension TagLockReading {
    /// What a permanent lock's own outcome established, region by region.
    ///
    /// - Parameter staticRegionWitnessed: `true` only when a behavioural probe
    ///   observed the tag refusing a write to a page the **static** lock bytes
    ///   cover. `OperationsFlowModel.verifyPermanentLock` rewrites page 4, which
    ///   sits inside pages 3 to 15, so it proves the static region and says
    ///   nothing whatever about the dynamic lock page. A whole-tag verdict drawn
    ///   from it would be exactly the claim this type exists to prevent.
    ///
    /// Deliberately never consults `PermanentLockOutcome.isPartial`. That
    /// property folds `.committedUnverified` into `committed`, so an outcome
    /// whose static stage is `.inconclusive` and whose dynamic stage committed
    /// reports `isPartial == false` while describing a half-burned tag. Mapping
    /// region by region is the only shape that cannot make that mistake.
    init(_ outcome: PermanentLockOutcome, staticRegionWitnessed: Bool) {
        var reading = TagLockReading(diagnostics: outcome.diagnostics)
        for stage in outcome.order {
            let region: TagLockRegion = switch stage {
            case .dynamicLock: .dynamicLock
            case .staticLock: .staticLock
            case .blocks: .blocks
            }
            var finding = Self.finding(for: outcome.stages[stage])
            if region == .staticLock, staticRegionWitnessed, finding == .setNotWitnessed {
                finding = .allSet
            }
            reading.record(region, finding)
        }
        self = reading
    }

    private static func finding(for result: PermanentLockOutcome.StageResult?) -> TagLockFinding {
        switch result {
        case .committedVerified: .allSet
        case .committedUnverified: .setNotWitnessed
        case .partiallyCommitted: .someSet

        // A refusal says **this stage burned nothing**. It does not say the
        // region was clear to begin with, and a lock write is refused precisely
        // when the chip will not discuss the page. Mapping it to `.noneSet`
        // would turn "we were told no" into the positive claim "we read it and
        // no bit is set", which is this branch's whole defect class: the tag
        // whose static bytes an earlier partial lock had already burned would
        // have its card flipped back to Off by a later refusal.
        case .refused(let diagnostics): .notRead(reason: "refused, bits not read (\(diagnostics))")
        case .inconclusive(let diagnostics): .notRead(reason: diagnostics)
        case .notAttempted: .notRead(reason: "not attempted")
        case .none: .notPresent
        }
    }
}
