import Foundation
import HexNFCKit
import HexNFCRecords

// MARK: - Credentials

/// Deterministic, non-secret jig credentials the reversible protection steps
/// program. Fixed so a simulator run and a live run write the *same* bytes — a
/// mismatch then means real-hardware divergence, not randomness. They are still
/// redacted in `NFCTrace` (PWD_AUTH / PWD-PACK / AES frames are masked upstream).
public struct TagTestCredentials: Sendable, Hashable {
    /// Type-2 PWD ("HEX!").
    public var type2Password: Data
    /// Type-2 PACK.
    public var type2Pack: Data
    /// NTAG424 AES key — factory-zero, so `AuthenticateEV2First` succeeds without
    /// ever changing a key (fully reversible).
    public var type4AESKey: Data
    /// NTAG424 AES key the *enforcement* verifier programs into key 0 (a fixed,
    /// non-zero test key: "HEXNFC-ENF-KEY!!") so it can prove a gated NDEF file
    /// actually refuses an unauthenticated write. Recoverable: `disableProtection`
    /// with this same key restores the factory-zero key + free access.
    public var type4EnforcementKey: Data
    /// ICODE SLIX password ("HEXP").
    public var type5Password: Data
    /// MIFARE Ultralight C test key, in cipher order ("HEXNFC-ULC-KEY!!").
    ///
    /// Unlike the NTAG424's factory-zero key, this one is genuinely programmed
    /// onto the tag, because Ultralight C has no "authenticate without changing
    /// anything" state to lean on: the factory key is published, so proving the
    /// gate works at all means replacing it. That is safe here in a way it is
    /// not on SLIX, because `disable` restores the factory key and clears AUTH0,
    /// returning the tag to a genuinely unprotected state.
    public var ultralightCKey: Data

    public init(
        type2Password: Data = Data([0x48, 0x45, 0x58, 0x21]),
        type2Pack: Data = Data([0xC0, 0xDE]),
        type4AESKey: Data = Data(repeating: 0x00, count: 16),
        type4EnforcementKey: Data = Data("HEXNFC-ENF-KEY!!".utf8),
        type5Password: Data = Data([0x48, 0x45, 0x58, 0x50]),
        ultralightCKey: Data = Data("HEXNFC-ULC-KEY!!".utf8)
    ) {
        self.type2Password = type2Password
        self.type2Pack = type2Pack
        self.type4AESKey = type4AESKey
        self.type4EnforcementKey = type4EnforcementKey
        self.type5Password = type5Password
        self.ultralightCKey = ultralightCKey
    }
}

// MARK: - Context

/// Scratch state threaded across the steps of one tap. Lets a step stash the
/// original bytes it is about to overwrite (so it can restore them) and record
/// which credential it programmed (so cleanup can always undo protection, even
/// if a later step aborts mid-suite).
public struct TagTestContext {
    public let profile: ChipProfile
    public let uid: Data
    public let credentials: TagTestCredentials
    /// Save/restore slots, keyed by a step-chosen name (e.g. `"ndef.original"`).
    public var scratch: [String: Data] = [:]

    /// Set by `t2.ccVerify` when page 3 is still blank. A named constant rather
    /// than a repeated string literal because the runner now reads it back out
    /// to populate `TagTestReport.capabilityContainerIsBlank`, so a typo in one
    /// of the three places would silently mean "formatted".
    public static let unformattedCCKey = "t2.cc.unformatted"
    /// The last thing a step read off the tag about its password gate, written
    /// **before** any frame that could halt the chip. `Data([0x01])` means the
    /// gate was armed, `Data([0x00])` that it was open.
    ///
    /// The runner's post-cleanup probe is a `try?`, so a halted chip answers it
    /// with `nil` and the "did cleanup leave the tag protected?" flag is forced
    /// false on the one path where it matters. This is the fallback that stops
    /// that: a reading taken while the tag was still answering, rather than an
    /// absence of one taken after it stopped.
    public static let lastKnownProtectionKey = "protection.lastKnownReading"
    /// Set by any reversible protect step the instant it programs protection;
    /// read by cleanup's safety net so a mid-step abort never strands the tag
    /// in a gated state.
    public var armedProtection: (spec: ProtectionSpec, credential: TagCredential)?

    public init(profile: ChipProfile, uid: Data, credentials: TagTestCredentials) {
        self.profile = profile
        self.uid = uid
        self.credentials = credentials
    }
}

// MARK: - Step check

/// The outcome of a single step's expectation. `satisfied == false` is an
/// expectation mismatch (a soft failure the report distinguishes from a thrown
/// `TagError`); both stop a fail-fast suite.
public struct TagStepCheck: Sendable {
    public var satisfied: Bool
    public var detail: String
    public var expected: String?
    public var actual: String?

    public init(satisfied: Bool, detail: String, expected: String? = nil, actual: String? = nil) {
        self.satisfied = satisfied
        self.detail = detail
        self.expected = expected
        self.actual = actual
    }

    /// An unconditional pass carrying a human note.
    public static func pass(_ detail: String) -> TagStepCheck {
        TagStepCheck(satisfied: true, detail: detail)
    }

    /// Assert a boolean, rendering expected/actual for the log on failure.
    public static func require(_ label: String, _ condition: Bool) -> TagStepCheck {
        TagStepCheck(satisfied: condition, detail: label,
                     expected: condition ? nil : "true", actual: condition ? nil : "false")
    }

    /// Assert two equatable, printable values match.
    public static func expect<T: Equatable & CustomStringConvertible>(
        _ label: String, _ actual: T, equals want: T
    ) -> TagStepCheck {
        TagStepCheck(satisfied: actual == want, detail: label,
                     expected: want.description, actual: actual.description)
    }

    /// Assert two byte strings match (colon-hex rendered).
    public static func expectHex(_ label: String, _ actual: Data, equals want: Data) -> TagStepCheck {
        TagStepCheck(satisfied: actual == want, detail: label,
                     expected: want.hexString, actual: actual.hexString)
    }

    /// Fail if any child fails; concatenate details. The first failing child's
    /// expected/actual is surfaced.
    public static func all(_ checks: [TagStepCheck]) -> TagStepCheck {
        if let failed = checks.first(where: { !$0.satisfied }) {
            return TagStepCheck(satisfied: false,
                                detail: checks.map(\.detail).joined(separator: " · "),
                                expected: failed.expected, actual: failed.actual)
        }
        return TagStepCheck(satisfied: true, detail: checks.map(\.detail).joined(separator: " · "))
    }
}

// MARK: - Step

/// One test step: an operation plus its expectation, both in the `run` body.
/// Throwing a `TagError` is a hard failure; returning an unsatisfied
/// `TagStepCheck` is an expectation mismatch. Ordering within a plan is
/// load-bearing (readOnly probes before reversible writes).
public struct TagTestStep: Sendable {
    public struct ID: Hashable, Sendable, RawRepresentable, ExpressibleByStringLiteral, CustomStringConvertible {
        public let rawValue: String
        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(stringLiteral value: String) {
            rawValue = value
        }

        public var description: String {
            rawValue
        }
    }

    /// The batch runner admits only `readOnly` + `reversibleWrite`; `.irreversible`
    /// never appears in a `TagTestPlan.steps` and is rejected by the runner.
    public enum SafetyLevel: Int, Sendable, Comparable, CaseIterable, CustomStringConvertible {
        case readOnly = 0
        case reversibleWrite = 1
        case irreversible = 2
        public static func < (a: Self, b: Self) -> Bool {
            a.rawValue < b.rawValue
        }

        public var description: String {
            switch self {
            case .readOnly: "read-only"
            case .reversibleWrite: "reversible"
            case .irreversible: "irreversible"
            }
        }
    }

    public let id: ID
    public let name: String
    public let safety: SafetyLevel
    public let requiredCapabilities: TagCapability
    /// Which activation this step needs, 0-based. Tap 0 is the only tap a
    /// single-session run opens.
    ///
    /// Some things about a tag are simply not observable inside one activation.
    /// AUTH0 latches at the *next* one, so a mid-session read of it reads back
    /// what was just written rather than what the tag will enforce; and a
    /// refused `PWD_AUTH` returns a Type-2 chip to HALT, so the question "what
    /// credential does this tag hold now?" can be asked exactly once per tap.
    public let tap: Int
    /// This step's last frame may end the activation, so **nothing may follow it
    /// in its tap**. `TagTestPlan.init` enforces that, and `cleanupTap` moves
    /// cleanup into a fresh activation when the final suite tap declares it.
    ///
    /// On Type-2 a refusal is a NAK and a NAK halts the chip for the rest of the
    /// activation. That has already cost four live rounds (`ulc.identify`,
    /// `lockSignature`, `Type2EnforcementStrategy.probe`, and `t2.password`'s own
    /// trailing `PWD_AUTH` sitting immediately before cleanup).
    public let endsActivation: Bool
    public let run: @Sendable (any ConnectedTag, inout TagTestContext) async throws -> TagStepCheck

    public init(
        _ id: ID,
        _ name: String,
        safety: SafetyLevel,
        requires: TagCapability = [],
        tap: Int = 0,
        endsActivation: Bool = false,
        run: @escaping @Sendable (any ConnectedTag, inout TagTestContext) async throws -> TagStepCheck
    ) {
        self.id = id
        self.name = name
        self.safety = safety
        requiredCapabilities = requires
        self.tap = tap
        self.endsActivation = endsActivation
        self.run = run
    }
}

// MARK: - Result

/// The recorded outcome of one step. `frames` carries the tx/rx captured from
/// `NFCTrace` while the step ran (populated on live sessions, empty on the
/// simulator, which does not trace).
public struct TagStepResult: Sendable, Identifiable {
    public enum Status: String, Sendable { case passed, failed, skipped }

    public let id: String
    public let name: String
    public let safety: TagTestStep.SafetyLevel
    public let status: Status
    public let detail: String
    public let expected: String?
    public let actual: String?
    public let skipReason: String?
    public let error: TagError?
    public let frames: [NFCTrace.Event]
    public let milliseconds: Int

    public init(
        id: String, name: String, safety: TagTestStep.SafetyLevel, status: Status,
        detail: String = "", expected: String? = nil, actual: String? = nil,
        skipReason: String? = nil, error: TagError? = nil,
        frames: [NFCTrace.Event] = [], milliseconds: Int = 0
    ) {
        self.id = id
        self.name = name
        self.safety = safety
        self.status = status
        self.detail = detail
        self.expected = expected
        self.actual = actual
        self.skipReason = skipReason
        self.error = error
        self.frames = frames
        self.milliseconds = milliseconds
    }

    /// A single glyph-prefixed summary line for the copyable log.
    public var plainTextLine: String {
        let mark = switch status {
        case .passed: "✓"
        case .failed: "✗"
        case .skipped: "-"
        }
        var line = "\(mark) \(name)"
        if milliseconds > 0 {
            line += " (\(milliseconds)ms)"
        }
        if !detail.isEmpty {
            line += ": \(detail)"
        }
        if status == .skipped, let reason = skipReason {
            line += " [skipped: \(reason)]"
        }
        if status == .failed {
            if let expected, let actual {
                line += "\n    expected \(expected)\n    actual   \(actual)"
            }
            if let error {
                line += "\n    error \(error.kind) :: \(String(localized: error.userMessage))"
                if !error.diagnostics.isEmpty {
                    line += "\n    diag  \(error.diagnostics)"
                }
            }
        }
        return line
    }
}

// MARK: - Report

/// The full result of one harness run: every suite step, every cleanup step,
/// and the hard post-cleanup invariant `cleanupLeftTagProtected`.
public struct TagTestReport: Sendable {
    public let profile: ChipProfile
    public let uid: Data
    public let results: [TagStepResult]
    public let cleanupResults: [TagStepResult]
    public let cleanupLeftTagProtected: Bool
    /// Whether page 3 was still blank when `t2.ccVerify` read it, or `nil` if
    /// the step never ran (a non-Type-2 plan, or a suite that halted first).
    ///
    /// Carried on the report because it is a fact about *this tag*, not about
    /// its chip, and it is the only thing that can tell the gated
    /// `formatVirginCC` op apart from an operation that will always be refused.
    /// A factory NTAG21x arrives pre-formatted, so offering it a one-shot OTP
    /// write is offering a button that cannot work.
    public let capabilityContainerIsBlank: Bool?
    /// Activations actually opened, cleanup's included.
    public let tapCount: Int
    /// Activations the plan needed, after the safety filter and the run's tap
    /// budget. `tapCount < plannedTaps` means the run stopped short.
    public let plannedTaps: Int

    public init(
        profile: ChipProfile, uid: Data,
        results: [TagStepResult], cleanupResults: [TagStepResult],
        cleanupLeftTagProtected: Bool,
        capabilityContainerIsBlank: Bool? = nil,
        tapCount: Int = 1,
        plannedTaps: Int = 1
    ) {
        self.profile = profile
        self.uid = uid
        self.results = results
        self.cleanupResults = cleanupResults
        self.cleanupLeftTagProtected = cleanupLeftTagProtected
        self.capabilityContainerIsBlank = capabilityContainerIsBlank
        self.tapCount = tapCount
        self.plannedTaps = plannedTaps
    }

    /// Every suite step passed or skipped — none failed.
    public var passed: Bool {
        !results.contains { $0.status == .failed }
    }

    public var firstFailure: TagStepResult? {
        results.first { $0.status == .failed }
    }

    /// The gate for the irreversible-ops flow: suite green, cleanup green, the
    /// tag verified unprotected afterwards, and every tap the plan asked for
    /// actually taken.
    ///
    /// The tap clause is the same argument that stops a read-only pass recording
    /// a clean pass. A run capped below its plan's budget skipped the cross-tap
    /// credential assertions, and those are the ones that ask what the tag holds
    /// rather than what the last write returned.
    public var isCleanPass: Bool {
        passed
            && !cleanupLeftTagProtected
            && !cleanupResults.contains { $0.status == .failed }
            && tapCount >= plannedTaps
    }

    private var counts: (pass: Int, fail: Int, skip: Int) {
        results.reduce(into: (0, 0, 0)) { acc, r in
            switch r.status {
            case .passed: acc.0 += 1
            case .failed: acc.1 += 1
            case .skipped: acc.2 += 1
            }
        }
    }

    /// Stable, greppable summary block for pasting to an agent / CI.
    public var footer: String {
        let c = counts
        let cleanupOK = !cleanupResults.contains { $0.status == .failed }
        var lines = [
            "=== HEXNFC TESTKIT REPORT ===",
            "chip=\(profile.id) uid=\(uid.hexString)",
            "result=\(passed ? "PASS" : "FAIL") steps=\(c.pass + c.skip)/\(results.count) "
                + "pass=\(c.pass) fail=\(c.fail) skip=\(c.skip) taps=\(tapCount)/\(plannedTaps)",
        ]
        if let f = firstFailure {
            let diag = f.error.map { "\($0.kind) \($0.diagnostics)" } ?? [f.expected, f.actual].compactMap { $0 }
                .joined(separator: " != ")
            lines.append("firstFail=\"\(f.name)\" \(diag)")
        }
        lines.append("cleanup=\(cleanupOK ? "OK" : "FAIL") unprotected=\(cleanupLeftTagProtected ? "no" : "yes")")
        lines.append("=== END ===")
        return lines.joined(separator: "\n")
    }

    /// The full copyable console dump — header, every step (+ its frames), the
    /// cleanup steps, and the machine footer.
    public var plainTextLog: String {
        var out = "Hex NFC live test: \(profile.displayName)  uid=\(uid.hexString)\n"
        for r in results {
            out += r.plainTextLine + "\n"
            for f in r.frames {
                out += "    \(f.direction.symbol) \(f.label.map { $0 + " " } ?? "")\(f.body)\n"
            }
        }
        if !cleanupResults.isEmpty {
            out += "[ cleanup ]\n"
            for r in cleanupResults {
                out += r.plainTextLine + "\n"
            }
        }
        out += footer + "\n"
        return out
    }
}

// MARK: - Events

/// Streamed by the runner so a SwiftUI progress bar + console render live, and
/// so an XCTest can drain to `.finished`.
public enum TagTestEvent: Sendable {
    case planResolved(profile: ChipProfile, stepCount: Int)
    /// A new activation is about to be asked for. Emitted **before** the factory
    /// is asked for the session, so the operator is told to re-present the tag
    /// before the NFC sheet reopens rather than after it.
    ///
    /// `uid` is the tag the run started on, and `nil` on the first tap.
    case tapStarted(index: Int, of: Int, uid: Data?)
    /// `index` and `of` are **global to the run**, not per tap: `index` counts
    /// every effective step in plan order and `of` is their total. A per-tap
    /// numbering would send `TestHarnessModel`'s progress bar backwards at each
    /// tap boundary.
    case stepStarted(id: String, name: String, index: Int, of: Int)
    case stepFinished(TagStepResult)
    case suiteFinished(passed: Bool)
    case cleanupStarted
    case cleanupStepFinished(TagStepResult)
    case finished(TagTestReport)
}
