import Foundation

/// What a protection operation actually left on the tag, as distinct from what
/// it set out to do.
///
/// The bug class this exists to close: a multi-command sequence mutates durable
/// credential state, tears halfway, and the app reports "failed" for the whole
/// thing. "Failed" is not a description of a tag. This is.
///
/// The incident that produced it (2026-09-04, NTAG213 `04:37:2E:12:6B:67:81`):
/// a password removal wrote AUTH0, ACCESS and PWD, then lost the tag on the PACK
/// write. The tag was unprotected and holding the factory password; the app said
/// the removal had failed and went on presenting the user's original password,
/// which the chip no longer held. Every retry earned a NAK, and a NAK halts a
/// Type-2 chip for the rest of the activation.
///
/// So a driver reports what it established, not merely whether it threw. The
/// rule that follows from it, and the reason `metItsGoal` exists: an operation's
/// success criterion is a **read-back**, and credential tidy-up performed after
/// that read-back can never turn a success into a reported failure.
public struct ProtectionResidue: Hashable, Sendable {
    public enum Family: String, Hashable, Sendable {
        case type2
        case type4
        case type5
        case ultralightC
    }

    public enum Intent: String, Hashable, Sendable {
        case enable
        case disable
        case setCredential
    }

    /// Every step a credential-mutating sequence can complete, named for what it
    /// establishes rather than for the frame that establishes it. Families that
    /// have no analogue for a step simply never record it.
    public enum Step: String, Hashable, Sendable, CaseIterable {
        case stateRead
        case gateOpened
        case gateDisarmed
        case credentialWritten
        case packWritten
        case accessWritten
        case gateArmed
        case credentialProven
        case gateProven
        case attemptLimitWritten
    }

    public struct Failure: Hashable, Sendable {
        public let step: Step
        /// Never contains a password, PACK, or key byte.
        public let diagnostics: String

        public init(step: Step, diagnostics: String) {
            self.step = step
            self.diagnostics = diagnostics
        }
    }

    /// What the gate is *known* to be doing. Only a read-back sets a `proven`
    /// case; an ACK never does.
    public enum GateVerdict: Hashable, Sendable {
        case provenOpen
        case provenArmed(fromPage: Int)
        case unknown
    }

    /// What the credential pages are known to hold. Never proven by reading: a
    /// Type-2 chip answers a READ of PWD and PACK with zeros by design (NTAG213
    /// rev 3.2 §8.8). This records what this session wrote and whether the write
    /// was acknowledged, which is the most any app can honestly claim.
    public enum CredentialVerdict: Hashable, Sendable {
        case unchanged
        case factoryDefault
        case callerSupplied
        case unknown(reason: String)
    }

    public var family: Family
    public var intent: Intent
    public var gate: GateVerdict
    public var credential: CredentialVerdict
    /// Completed steps, in the order they completed.
    public var completed: [Step]
    public var failures: [Failure]
    /// `true` when opening the gate had to fall back to the factory default this
    /// app's own removal path writes. The clearest single sign that an earlier
    /// run tore partway through.
    public var authenticatedWithFactoryDefault: Bool

    public init(
        family: Family,
        intent: Intent,
        gate: GateVerdict = .unknown,
        credential: CredentialVerdict = .unchanged,
        completed: [Step] = [],
        failures: [Failure] = [],
        authenticatedWithFactoryDefault: Bool = false
    ) {
        self.family = family
        self.intent = intent
        self.gate = gate
        self.credential = credential
        self.completed = completed
        self.failures = failures
        self.authenticatedWithFactoryDefault = authenticatedWithFactoryDefault
    }

    /// Whether the operation met its own success criterion, which is the gate
    /// read-back and nothing else. Tidy-up after that point does not count.
    ///
    /// - `.disable`: the gate reads back open.
    /// - `.enable`: the gate reads back armed **and** the credential was proven
    ///   by authenticating against it.
    /// - `.setCredential`: both credential pages were acknowledged. There is no
    ///   read-back available for this one, and saying so is the honest answer.
    ///
    /// ## The Ultralight C exception, and why it is not a loosening
    ///
    /// A re-programmed Ultralight C key does not authenticate until the next
    /// activation (MF0ICU2 rev 3.3 §7.5.7 remark), and a second handshake in one
    /// activation is refused, so `.credentialProven` is not a step that driver
    /// can ever record on the tap that wrote the key. Requiring it made
    /// `metItsGoal` permanently `false` for the family: every clean Ultralight C
    /// protect was filed by `WriteFlowModel` as `Stage.applying`, "an apply is in
    /// flight, or was interrupted", for the life of the record. An unreachable
    /// criterion is not a strict one, it is a wrong answer given every time. The
    /// gate read-back is still required, and it is still the criterion; what this
    /// family substitutes for the proof is the acknowledged key write, which is
    /// the most that activation can establish.
    public var metItsGoal: Bool {
        switch intent {
        case .disable:
            gate == .provenOpen

        case .enable:
            isProvenArmed && (
                completed.contains(.credentialProven)
                    || (family == .ultralightC && completed.contains(.credentialWritten))
            )

        case .setCredential:
            completed.contains(.credentialWritten) && completed.contains(.packWritten)
        }
    }

    /// `true` when nothing at all was refused or lost.
    public var isComplete: Bool {
        failures.isEmpty
    }

    private var isProvenArmed: Bool {
        if case .provenArmed = gate {
            return true
        }
        return false
    }

    // MARK: Builders used by the drivers

    public mutating func record(_ step: Step) {
        completed.append(step)
    }

    public mutating func record(failure step: Step, _ diagnostics: String) {
        failures.append(Failure(step: step, diagnostics: diagnostics))
    }

    // There is deliberately no `unverified(family:intent:)` placeholder. It was
    // here for a family whose driver had not been taught to report a residue,
    // and every family's driver now does, so by 2026-09-05 it had zero callers.
    // A verdict-free residue that anything can mint is one `metItsGoal == false`
    // away from being used to say "the operation did not meet its goal" about a
    // sequence nobody ran, and the plain initializer already builds one for the
    // callers that genuinely start empty and then record what they did.
}

// MARK: - Reporting

public extension ProtectionResidue {
    /// Multi-line, machine-greppable, and free of every secret byte. Suitable for
    /// `TagError.diagnostics` and for a harness report.
    var diagnostics: String {
        var lines = [
            "protection intent=\(intent.rawValue) family=\(family.rawValue) goal=\(metItsGoal ? "met" : "not-met")",
            "gate=\(gateDescription) credential=\(credentialDescription) "
                + "authFallback=\(authenticatedWithFactoryDefault ? "yes" : "no")",
            "steps=\(completed.map(\.rawValue).joined(separator: ","))",
        ]
        for failure in failures {
            lines.append("failed \(failure.step.rawValue): \(failure.diagnostics)")
        }
        return lines.joined(separator: "\n")
    }

    private var gateDescription: String {
        switch gate {
        case .provenOpen: "provenOpen"
        case .provenArmed(let page): "provenArmed(fromPage=\(page))"
        case .unknown: "unknown"
        }
    }

    private var credentialDescription: String {
        switch credential {
        case .unchanged: "unchanged"
        case .factoryDefault: "factoryDefault"
        case .callerSupplied: "callerSupplied"
        case .unknown(let reason): "unknown(\(reason))"
        }
    }

    /// One sentence for the user, chosen from `(intent, gate, credential)`. Never
    /// names a byte, a page, or a command.
    ///
    /// The distinction the copy has to carry is the one the incident lacked: a
    /// tag that is unlocked but whose stored password was not tidied away is a
    /// **success**, and a tag still holding its gate is an unfinished job the
    /// user can finish with another tap. Neither is "something went wrong".
    ///
    /// ## Why `credential` is consulted, and where it is not
    ///
    /// This used to switch on `(intent, gate)` alone. That made one sentence, the
    /// `(.enable, .provenOpen)` one, contradict the verdict sitting beside it on
    /// the same object: it said "the password was saved to the tag" at four abort
    /// points that had recorded `.unchanged` (nothing was written) or
    /// `.unknown` (the write stopped part way). On an Ultralight C or an NTAG424
    /// that is an instruction to keep a key the tag may not hold, printed on the
    /// one report a user acts on.
    ///
    /// The `.disable` arms deliberately do **not** consult it. What a removal
    /// promises is that the gate comes down, and the gate is read back; a
    /// credential left un-tidied on an open tag changes nothing the tag now
    /// enforces, and `WriteFlowModel` already keeps the stored credential for
    /// exactly that case rather than telling the user about it.
    var userMessage: LocalizedStringResource {
        switch (intent, gate) {
        case (.disable, .provenOpen):
            "Password removed."

        case (.disable, .provenArmed):
            "This tag is still protected. Nothing has been lost: hold it against the phone again to finish removing the password."

        case (.disable, .unknown):
            "Couldn't confirm whether the password was removed. Hold the tag against the phone again to check."

        case (.enable, .provenArmed):
            switch credential {
            case .callerSupplied:
                "Password set."

            default:
                "Protection is on, but this app could not confirm the password took. Keep the password you entered: it is very likely the one now on the tag."
            }

        case (.enable, .provenOpen):
            switch credential {
            case .callerSupplied:
                // The credential pages were written and acknowledged, and the
                // gate read back open. Finishing is one more tap.
                "The password was saved to the tag, but protection did not switch on. Hold the tag against the phone again to finish."

            case .unchanged, .factoryDefault:
                // Nothing of the user's reached the tag, and the gate was read.
                // Saying the password was saved would send them away holding a
                // credential the tag has never been given.
                "The tag is still unprotected, and the password you entered was not saved to it. Hold the tag against the phone again to try again."

            case .unknown:
                "The tag is still unprotected, and this app could not confirm which password it now holds. Keep both the password you entered and the one it had before, then hold the tag against the phone again."
            }

        case (.enable, .unknown):
            switch credential {
            case .unknown:
                // Neither half is settled: the gate was never re-read and the
                // credential write did not resolve. Both passwords stay in play.
                "Couldn't confirm that protection switched on, or which password the tag now holds. Keep both the password you entered and the one it had before, then hold the tag against the phone again."

            default:
                "Couldn't confirm that protection switched on. Hold the tag against the phone again to check."
            }

        case (.setCredential, _):
            "Password stored on the tag. Protection is still off."
        }
    }
}
