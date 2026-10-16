#if DEBUG
import Foundation
import HexNFCDesign
import HexNFCKit
import HexNFCTestKit
import Observation

/// Drives the DEBUG live-hardware test harness: identify a chip, confirm, run the
/// shared `TagTestPlan` over a single CoreNFC session, and stream every step +
/// frame into a copyable console. Records a clean pass so the gated
/// irreversible-ops flow can unlock. DEBUG-only — never compiled into release.
@MainActor
@Observable
public final class TestHarnessModel {
    public enum Phase {
        case idle
        case identifying
        case confirm(ChipProfile, uid: Data)
        case running
        case finished(TagTestReport)
        case error(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var entries: [HexConsoleEntry] = []
    public private(set) var progress: Double = 0
    public private(set) var currentStep: String = ""
    /// Set while the runner is waiting for the operator to present the tag
    /// again, and cleared the moment a step in the new activation starts.
    ///
    /// A multi-tap plan asks for the *same* physical tag several times, and the
    /// only reason a run stalls here is that nobody has been told to put it
    /// back. The screen renders this instead of the ordinary busy row.
    public private(set) var tapPrompt: String?
    public private(set) var lastReport: TagTestReport?
    /// Bumped whenever a step completes, to drive `.hexHero` console pulses.
    public private(set) var pulse: Int = 0

    private let factory: TagSessionFactory
    private var task: Task<Void, Never>?

    /// Called with (profile, uid) whenever a run ends in a verified clean pass —
    /// the parent records it in the `CleanPassRegistry` to gate irreversible ops.
    public var onCleanPass: ((ChipProfile, Data) -> Void)?

    public init(factory: TagSessionFactory) {
        self.factory = factory
    }

    /// The full copyable log — every console line plus the machine footer.
    public var logText: String {
        var out = entries.map(\.plainTextLine).joined(separator: "\n")
        if let report = lastReport {
            out += "\n\n" + report.footer
        }
        return out
    }

    // MARK: - Identify

    public func identify() {
        switch phase {
        case .idle, .finished, .error: break
        default: return
        }
        entries.removeAll()
        progress = 0
        currentStep = ""
        tapPrompt = nil
        lastReport = nil
        phase = .identifying
        task = Task { await runIdentify() }
    }

    private func runIdentify() async {
        let session = factory.makeSession()
        do {
            let tag = try await session.start(alert: "Hold the tag against the top of your iPhone")
            let uid = tag.uid
            let profile = tag.chip
            await session.invalidate(error: nil)
            if let profile {
                append(.note, "Detected \(profile.displayName) · UID \(uid.hexString)")
                phase = .confirm(profile, uid: uid)
            } else {
                // An unidentified chip is the most interesting tag in the box,
                // so print everything the probe learned rather than a dead end.
                // Without this the lab says "no profile returned" and the only
                // way to find out what a mystery tag is, is to tail syslog.
                append(.error, "Could not identify this chip. No profile returned.")
                append(.note, "UID \(uid.hexString)")
                if let report = tag.unidentifiedReport {
                    if let summary = report.summary {
                        append(.note, "Reported: \(summary)")
                    }
                    append(.note, "Version bytes: \(report.versionHex)")
                }
                phase = .error("Unidentified chip")
            }
        } catch let error as TagError {
            await session.invalidate(error: nil)
            append(.error, "\(String(localized: error.userMessage)): \(error.diagnostics)")
            phase = .error(String(localized: error.userMessage))
        } catch {
            await session.invalidate(error: nil)
            append(.error, "\(error)")
            phase = .error("\(error)")
        }
    }

    // MARK: - Run

    public func startRun() {
        guard case .confirm(let profile, _) = phase else { return }
        phase = .running
        progress = 0
        task = Task { await runSuite(profile: profile) }
    }

    public func cancelConfirmation() {
        guard case .confirm = phase else { return }
        phase = .idle
    }

    /// Run only `.readOnly` steps — no writes of any kind reach the tag.
    ///
    /// For one-of-a-kind tags (a single ICODE SLIX, a transit card) where the
    /// identity capture is the point and a torn write is unrecoverable. It
    /// deliberately does **not** record a clean pass: the write path was never
    /// proven, so it must not unlock the irreversible ops.
    public var readOnlyPass: Bool = false

    private func runSuite(profile: ChipProfile) async {
        let options = TagTestRunner.Options(
            includeSafety: readOnlyPass ? [.readOnly] : [.readOnly, .reversibleWrite],
            // A read-only identity capture on a one-of-a-kind tag must never ask
            // for a second tap: the whole point is that you may only get one.
            // A full pass runs every tap the plan declares.
            maximumTaps: readOnlyPass ? 1 : .max
        )
        if readOnlyPass {
            append(.note, "READ-ONLY PASS: write steps excluded; this cannot record a clean pass.")
        }
        let runner = TagTestRunner(plan: TagTestPlan.plan(for: profile), options: options)
        // The factory, not one session: a multi-tap plan needs one session per
        // activation, and the runner opens them.
        for await event in runner.stream(using: factory) {
            handle(event)
        }
    }

    private func handle(_ event: TagTestEvent) {
        switch event {
        case .planResolved(let profile, let count):
            append(.note, "Plan: \(count) step(s) for \(profile.displayName)")

        case .tapStarted(let index, let of, let uid):
            // Tap 0 is the run beginning, and the operator is already holding the
            // tag for it. Every later tap needs them to lift the phone and put
            // the SAME tag back, so say so before the NFC sheet reopens.
            guard of > 1, index > 0 else { break }
            let prompt = "Tap \(index + 1) of \(of): lift the phone, then present the same tag again"
            tapPrompt = prompt
            currentStep = prompt
            let known = uid.map { " (UID \($0.hexString))" } ?? ""
            append(.note, "- \(prompt)\(known)")

        case .stepStarted(_, let name, let index, let of):
            tapPrompt = nil
            currentStep = name
            // `index` and `of` are global to the run, so this never goes
            // backwards at a tap boundary.
            progress = of > 0 ? Double(index) / Double(of) : 0
            append(.note, "▶ \(index)/\(of)  \(name)")

        case .stepFinished(let result):
            appendFrames(result.frames)
            appendResult(result)
            pulse &+= 1

        case .suiteFinished(let passed):
            append(.note, passed ? "Suite passed. Running cleanup…" : "Suite FAILED. Running cleanup…")

        case .cleanupStarted:
            tapPrompt = nil
            append(.note, "[ cleanup ]")

        case .cleanupStepFinished(let result):
            appendResult(result)

        case .finished(let report):
            lastReport = report
            progress = 1
            currentStep = ""
            tapPrompt = nil
            if report.plannedTaps > 1 {
                // The operator needs to know why the sheet kept reopening, and
                // whether the tap budget cut the run short before the cross-tap
                // credential steps ran.
                append(.note, "Ran across \(report.tapCount) of \(report.plannedTaps) taps.")
            }
            append(report.passed ? .note : .error, report.footer)
            phase = .finished(report)
            // A read-only pass skipped every write step, so it proves nothing
            // about the write path and must never unlock an irreversible op.
            if report.isCleanPass, !readOnlyPass {
                onCleanPass?(report.profile, report.uid)
            }
        }
    }

    // MARK: - Console helpers

    private func append(_ kind: HexConsoleEntry.Kind, _ body: String, label: String? = nil) {
        entries.append(HexConsoleEntry(kind: kind, label: label, body: body))
    }

    private func appendFrames(_ frames: [NFCTrace.Event]) {
        for frame in frames {
            let kind: HexConsoleEntry.Kind = switch frame.direction {
            case .tx: .tx
            case .rx: .rx
            case .note: .note
            case .error: .error
            }
            entries.append(HexConsoleEntry(kind: kind, label: frame.label, body: frame.body))
        }
    }

    private func appendResult(_ result: TagStepResult) {
        let kind: HexConsoleEntry.Kind = result.status == .failed ? .error : .note
        entries.append(HexConsoleEntry(kind: kind, body: result.plainTextLine))
    }
}
#endif
