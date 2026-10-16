import Foundation

/// Every failure in the NFC layer carries two payloads: a `userMessage` suited
/// to a polite UI explainer, and a `diagnostics` string carrying UID, command
/// bytes, raw response — anything an experienced user could paste into a bug
/// report. The error UI surfaces `userMessage` by default; long-press reveals
/// `diagnostics`.
public struct TagError: Error, Sendable {
    public let kind: Kind
    public let userMessage: LocalizedStringResource
    public let diagnostics: String
    /// The attempt limit (`AUTH_LIM`) the tag reported, read in the **same
    /// activation** as this failure, or `nil` when no number was read.
    ///
    /// Not a count of attempts used or left: no chip in this catalogue discloses
    /// one, and `Kind.authFailed` says so at length. This is the configured byte,
    /// read back off the tag; a tag reporting `0` has no limit and is filed as
    /// `.notRead`, because there is nothing to warn anyone about.
    ///
    /// `nil` covers two different tags, which is why `limitReading` exists and
    /// this is derived from it. Ask that one before deciding what to tell a
    /// user: one tag has no limit, the other would not say.
    ///
    /// It is here because a surface that composes its own copy, rather than
    /// rendering `userMessage`, cannot otherwise know. `WriteSheet`'s unlock
    /// prompt is that surface.
    ///
    /// Deliberately outside `==` and `hash`, which stay on `kind` plus
    /// `diagnostics`: an error's identity is what happened, not what was known
    /// about the tag when it happened.
    public var attemptLimit: Int? {
        if case .set(let limit) = limitReading {
            limit
        } else {
            nil
        }
    }

    /// What was established about `AUTH_LIM` before this failure.
    ///
    /// `attemptLimit` answers "how many", and there are three states rather than
    /// two: a limit was read, no limit was read, or the tag would not say. The
    /// third is not a variant of the second. A **read-protected** Type-2 tag
    /// gates its own configuration pages, so `AUTH_LIM` cannot be read until
    /// after a password is accepted, and the app is asking for that password.
    /// Reporting that as "no limit" is what let the scan prompt come back in its
    /// neutral first-run copy after a refusal on such a tag: nothing on screen
    /// said a try may just have been spent, and pressing the same button again
    /// spent another. At a limit of 1 that is two presses to a tag that will never
    /// accept its password again.
    public let limitReading: AttemptLimitReading

    /// What a failure knows about the tag's attempt limit.
    public enum AttemptLimitReading: Hashable, Sendable {
        /// Nothing read one, or the tag reported none. The tag is not known to
        /// count this try.
        case notRead
        /// The tag's own `ACCESS` byte, read in this activation.
        case set(Int)
        /// The tag would not say, because its configuration pages are gated by
        /// the very password being presented. If a limit is set, this try may
        /// have counted against it: a stated refusal certainly did, and a
        /// transport-form one cannot be told apart from a tag that left the
        /// field before the chip ever evaluated the password.
        case hidden
    }

    public init(
        kind: Kind,
        userMessage: LocalizedStringResource,
        diagnostics: String,
        attemptLimit: Int? = nil
    ) {
        self.init(
            kind: kind,
            userMessage: userMessage,
            diagnostics: diagnostics,
            // A tag that reports `0` has no limit, which is nothing to warn
            // anyone about, so it files as `.notRead` rather than `.set(0)`.
            // `qualifiedByAttemptLimit` already refuses to qualify on a zero;
            // this keeps the value from arriving by the other door.
            limitReading: attemptLimit.flatMap { $0 > 0 ? .set($0) : AttemptLimitReading.notRead } ?? .notRead
        )
    }

    public init(
        kind: Kind,
        userMessage: LocalizedStringResource,
        diagnostics: String,
        limitReading: AttemptLimitReading,
        presentedACredential: Bool = false
    ) {
        self.kind = kind
        self.userMessage = userMessage
        self.diagnostics = diagnostics
        self.limitReading = limitReading
        self.presentedACredential = presentedACredential
    }

    /// Whether a credential frame actually went out before this failure.
    ///
    /// Defaults to `false` and is set only by the code that sent the frame, so
    /// a refusal nobody can vouch for keeps the careful answer. It is not
    /// inferable from `kind`: `TagError.readProtected` is thrown before any
    /// authentication and wears `.authFailed` so the existing classification
    /// keeps matching, and a Type-4 "no EV2 session, authenticate first" is
    /// `.authFailed` about a frame that was never composed.
    ///
    /// Deliberately outside `==` and `hash`, like `limitReading`, and for the
    /// same reason: an error's identity is what happened, not what was known
    /// about the tap when it happened.
    public private(set) var presentedACredential = false

    /// Whether this failure ended the tag's usefulness for the rest of the
    /// activation.
    ///
    /// A refused `PWD_AUTH` NAKs, and a NAK returns a Type-2 chip to HALT, so
    /// every frame after it in the same activation is answered by silence. An
    /// Ultralight C `AUTHENTICATE` behaves the same way. Whatever a flow was
    /// going to do next, it is not going to happen on this tap.
    ///
    /// `WriteFlowModel` used to ask this question as `limitReading != .notRead`
    /// and get the wrong answer on every tag this app arms.
    /// `ProtectionSpec.make` forces `authLimit: 0`, and `qualifiedByAttemptLimit`
    /// refuses to qualify on a zero, so the refusal came back `.notRead`, the
    /// early exit never fired, and the flow sent two more reads at a halted
    /// chip. Measured on 2026-09-21: `PWD_AUTH` failed at 13:35:00.792, then
    /// `READ p3` at .793, 1.105 and 1.418, all of them failing, 626 ms of a tap
    /// the user was holding a tag still for.
    public var spentTheActivation: Bool {
        presentedACredential || limitReading != .notRead
    }

    /// Whether the session that raised this ended before any tag was detected.
    ///
    /// The only thing that can say so is the session itself: `CoreNFCSession`
    /// sets it when `didDetect` never fired, and a simulated session sets it on
    /// the behaviours that throw before any tag is in play. It is not
    /// inferable from `kind`. A user cancel or a timeout can also land while
    /// identification is running on a tag that has already answered frames,
    /// and that reaches the caller as the same kind with this left false.
    ///
    /// Defaults to `false`, so a cancel nobody can vouch for keeps the report it
    /// has always had. The app reads it to decide whether a session that ended
    /// with nothing in the field is a failure at all (`TagContact`).
    ///
    /// Deliberately outside `==` and `hash`, like `presentedACredential`: an
    /// error's identity is what happened, not what was known about the tap.
    public private(set) var endedBeforeAnyTag = false

    /// Record that the session ended before any tag was detected.
    ///
    /// Called only by the session code that would have seen one.
    func endingBeforeAnyTag() -> TagError {
        var copy = self
        copy.endedBeforeAnyTag = true
        return copy
    }

    /// Record that a credential frame went out before this refusal.
    ///
    /// Called by the driver that sent it, at the site that sent it, which is
    /// the only place that knows.
    func afterPresentingACredential() -> TagError {
        var copy = self
        copy.presentedACredential = true
        return copy
    }

    public enum Kind: Hashable, Sendable {
        case sessionTimeout
        case sessionCancelled
        case sessionUnavailable
        case tagLost
        /// A **proven** refusal: the chip answered a password check with a NAK
        /// or a short reply. Never a transport loss, which is `.authInconclusive`.
        ///
        /// Carries no attempt count, and that is a finding rather than an
        /// omission. Nothing this app talks to reports one:
        ///  * **NTAG21x / UL EV1**: a refused `PWD_AUTH` is a payload-free NAK
        ///    (`Type2PasswordDriver.authenticate` treats a reply shorter than the
        ///    2-byte PACK as the refusal), so there is nowhere for a count to
        ///    arrive on the one command that could carry it. `AUTH_LIM`, ACCESS
        ///    bits 2-0, is the *configured* limit, not attempts used.
        ///  * **Ultralight C** has no attempt limit at all
        ///    (`docs/internal/chip-config-pages.md` § MF0ICU2).
        ///  * **ICODE SLIX2** answers the generic `0F` to every refusal (§9.6).
        ///  * **NTAG424 DNA** answers `91 9D` / `91 AE`, neither of which
        ///    encodes a counter.
        ///
        /// The field this case used to carry was `nil` at every production site
        /// and the only thing that ever filled it was a simulator computing a
        /// number no chip discloses, which is the "a simulator must not be more
        /// forthcoming than silicon" defect exactly. The one standard that does
        /// define a retry counter is an eMRTD's ISO 7816-4 `63 CX` status word;
        /// `EPassportReader.performBAC` has the SW in scope and does not parse
        /// it. If a genuine readout is ever wanted, it belongs there, on a
        /// parsed SW, and not as a general field every other family passes `nil`
        /// to.
        case authFailed
        /// A password check that did not complete. The tag stopped answering, so
        /// nothing at all was established about the credential. Distinguished
        /// from `.authFailed` because telling a user their password is wrong
        /// when it was never checked is what kept the 2026-09-04 NTAG213
        /// incident going: the app remapped every transport loss into "Wrong
        /// password.", so the one message that would have said "look at the tag"
        /// never appeared.
        case authInconclusive
        /// A credential-mutating sequence tore partway. The residue says what
        /// the tag actually holds.
        case protectionIncomplete(ProtectionResidue)
        /// A permanent lock burned some of its stages and was refused others.
        /// Irreversible and part-applied, which is the one outcome the user must
        /// never be told was "nothing".
        case permanentLockIncomplete(PermanentLockOutcome)
        case lockedPermanent
        /// The tag's password gate is open, and the operation asked for needs it
        /// armed. Kept apart from `.capabilityUnsupported`, which says what the
        /// chip can never do: this says what this tag is not currently holding,
        /// and it is refused **before** anything is written.
        case gateNotArmed
        case capabilityUnsupported(TagCapability)
        case malformedResponse
        case verificationFailed
        case writeOverflow(needed: Int, available: Int)
        case protocolError
        case unexpected
    }
}

extension TagError: LocalizedError {
    public var errorDescription: String? {
        String(localized: userMessage)
    }
}

/// Equatable + Hashable on `kind` + `diagnostics`. Two errors with different
/// `userMessage` localisations but the same kind/diagnostics compare equal —
/// load-bearing because tests assert on errors thrown across locale changes.
extension TagError: Hashable {
    public static func == (lhs: TagError, rhs: TagError) -> Bool {
        lhs.kind == rhs.kind && lhs.diagnostics == rhs.diagnostics
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(diagnostics)
    }
}

// MARK: - Constructor convenience

public extension TagError {
    static func sessionTimeout(diagnostics: String = "") -> TagError {
        TagError(
            kind: .sessionTimeout,
            userMessage: "The scan timed out. Hold the tag steady against the top of the phone and try again. If one particular tag times out every time, it may be a MIFARE Classic, which iPhone can't read (an iOS limitation, not a fault in the tag).",
            diagnostics: diagnostics
        )
    }

    static func sessionCancelled(diagnostics: String = "") -> TagError {
        TagError(
            kind: .sessionCancelled,
            userMessage: "Scan cancelled.",
            diagnostics: diagnostics
        )
    }

    static func tagLost(diagnostics: String = "") -> TagError {
        TagError(
            kind: .tagLost,
            userMessage: "Lost the tag mid-read. Keep it pressed against the top of the phone and try again.",
            diagnostics: diagnostics
        )
    }

    static func authFailed(diagnostics: String = "") -> TagError {
        TagError(
            kind: .authFailed,
            userMessage: "Wrong password.",
            diagnostics: diagnostics
        )
    }

    /// A refusal on a tag that reported an attempt limit, where "wrong password"
    /// is a claim the frame does not support.
    ///
    /// Measured 2026-09-10 (`bench-traces/2026-09-10-t2-1-ntag213.log`): an
    /// NTAG213 whose `AUTH_LIM` was exhausted refused the **correct** password,
    /// twelve milliseconds after the app read the ACCESS byte that said a limit
    /// was set. The old copy told the owner of a locked-out tag that the password
    /// they held was wrong, and it was not.
    ///
    /// The copy does not say the tag *is* locked out, because no chip here
    /// discloses attempts used and no read established it. It says a limit exists
    /// and that the refusal is therefore ambiguous, which is the whole of what
    /// was read.
    ///
    /// `limit` must already have been validated against a roll-over: a
    /// configuration read on a tag with no 7-byte UID may be page 0 wearing
    /// CFG1's clothes, and `Type2Rollover` is the guard. `nil` and `0` both fall
    /// through to the plain wording.
    static func authRefused(attemptLimit limit: Int?, diagnostics: String = "") -> TagError {
        guard let limit, limit > 0 else { return authFailed(diagnostics: diagnostics) }
        return TagError(
            kind: .authFailed,
            userMessage: """
            The tag refused that password. This tag has an attempt limit set, so it may be locked out \
            even if the password is right.
            """,
            diagnostics: diagnostics,
            attemptLimit: limit
        )
    }

    /// The transport form of the same refusal, on a tag that reported a limit.
    ///
    /// On a limited tag this form is the ordinary wrong password. The 2026-09-14
    /// bench run showed the form follows the chip's lock state: a locked NTAG213
    /// answered every password with the one-byte payload, and an unlocked one
    /// answered a wrong password with silence that CoreNFC reports as a lost
    /// connection (tag C at 23:03:15, 313 ms, after a limit of 1 was read back).
    /// The copy this replaced opened "Couldn't check the password: the tag
    /// stopped answering", which told that user the password was never checked
    /// and invited the same one again, and closed "a wrong attempt that reaches
    /// it counts", which is the lock-at-the-limit reading the datasheet does not
    /// support (rev 3.2 §8.8.2: the try past the limit locks).
    ///
    /// The lead hedges rather than asserting a refusal, because a lift in the
    /// milliseconds before `PWD_AUTH` produces the same frame: "didn't open the
    /// tag" is true of both. It says which tries count, because `AUTH_LIM` counts
    /// **failed** verifications only (`Type2AttemptLimitSemanticsTests`), and it
    /// says to check the password first, because on this tag a try is not free.
    /// "Open" because the string is shared. It reaches the Operations screens
    /// through `openGate` on the attempt-limit tap and `presentCredential` on
    /// protect and remove, where "opened this tag" is the idiom and nothing says
    /// "unlock". The unlock prompts show it in place of their own
    /// (`TagError.unlockPromptCopy`), under a button that says "Unlock" whatever
    /// this sentence says; that mix is accepted rather than paid for with two
    /// more keys.
    static func authInconclusive(attemptLimit limit: Int?, diagnostics: String = "") -> TagError {
        guard let limit, limit > 0 else { return authInconclusive(diagnostics: diagnostics) }
        return TagError(
            kind: .authInconclusive,
            userMessage: """
            That password didn't open the tag. This tag has an attempt limit set, and every wrong try \
            counts against it. Check the password before trying again.
            """,
            diagnostics: diagnostics,
            attemptLimit: limit
        )
    }

    /// A refusal from a tag that will not disclose its attempt limit, because
    /// the pages holding `AUTH_LIM` are behind the very gate being opened.
    ///
    /// Keeps the kind it was given, so every existing classification (the unlock
    /// prompts, `ProtectionProbe`, `ScanFlowModel`) keeps matching, and replaces
    /// only what the user is told. See `qualifiedByAHiddenAttemptLimit`.
    static func authRefusedWithAHiddenLimit(kind: Kind, diagnostics: String = "") -> TagError {
        TagError(
            kind: kind,
            userMessage: """
            That password didn't open the tag. This tag keeps its settings behind the password, so if \
            an attempt limit is set, that try may have counted against it. Check the password before \
            trying again.
            """,
            diagnostics: diagnostics,
            limitReading: .hidden
        )
    }

    /// The tag's own configuration says nothing is gated, and the caller needed
    /// it gated. Raised before a single byte is written, so the tag is exactly
    /// as it was.
    static func gateNotArmed(diagnostics: String = "") -> TagError {
        TagError(
            kind: .gateNotArmed,
            userMessage: "This tag has no password set, so there is nothing for an attempt limit to guard.",
            diagnostics: diagnostics
        )
    }

    /// A removal asked of a tag the reading found open.
    ///
    /// Shares `gateNotArmed`'s kind, because it is the same fact about the tag,
    /// and carries its own copy, because "there is nothing for an attempt limit
    /// to guard" describes an operation this user did not ask for.
    ///
    /// Raised only on a reading that positively says the gate is open. A reading
    /// that could not be taken is not this: a tag left open and holding the
    /// factory password by a torn removal is exactly the tag that has to be able
    /// to run a removal again.
    static func nothingToRemove(diagnostics: String = "") -> TagError {
        TagError(
            kind: .gateNotArmed,
            userMessage: "This tag has no password set, so there is nothing to remove.",
            diagnostics: diagnostics
        )
    }

    /// A password check that never completed: the tag stopped answering before
    /// it said yes or no. Routes to the unlock prompt exactly as `authFailed`
    /// does, but tells the truth about what was learned, which is nothing.
    static func authInconclusive(diagnostics: String = "") -> TagError {
        TagError(
            kind: .authInconclusive,
            userMessage: "Couldn't check the password: the tag stopped answering. Hold it steady against the top of the phone and try again.",
            diagnostics: diagnostics
        )
    }

    /// The pages above the Capability Container are gated, so nothing could be
    /// read. Keeps `authFailed`'s kind so the existing protection-failure
    /// classification in `ScanFlowModel` and `ProtectionProbe` keeps matching,
    /// while replacing "Wrong password." with copy that does not accuse a
    /// password nobody presented.
    static func readProtected(diagnostics: String = "") -> TagError {
        TagError(
            kind: .authFailed,
            userMessage: "This tag needs its password before it will show anything.",
            diagnostics: diagnostics
        )
    }

    /// A credential-mutating sequence tore partway through. The residue carries
    /// both halves of the report: what the user is told, and what a bug report
    /// needs.
    static func protectionIncomplete(_ residue: ProtectionResidue, diagnostics: String = "") -> TagError {
        let extra = diagnostics.isEmpty ? "" : "\n\(diagnostics)"
        return TagError(
            kind: .protectionIncomplete(residue),
            userMessage: residue.userMessage,
            diagnostics: residue.diagnostics + extra
        )
    }

    /// A permanent lock refused before it started, because the tag's password
    /// gate is armed.
    ///
    /// Carries the residue, so a bug report keeps the gate verdict and the
    /// factory-default recovery keeps its one classification rule, but replaces
    /// the residue's own copy. `ProtectionResidue.userMessage` is written for a
    /// protection change the user asked for, and this user asked to lock a tag:
    /// on `(.enable, .provenArmed)` it would say "Protection is on, but this app
    /// could not confirm the password took", which describes an operation that
    /// never ran.
    static func permanentLockRefusedByGate(
        _ residue: ProtectionResidue,
        diagnostics: String
    ) -> TagError {
        TagError(
            kind: .protectionIncomplete(residue),
            userMessage: "This tag is password protected, so it cannot be permanently locked. Remove the password first, then lock it.",
            diagnostics: residue.diagnostics + "\n" + diagnostics
        )
    }

    /// A permanent lock that part-applied. Carries the stage-by-stage truth,
    /// because on an operation with no undo "it failed" is the one report that
    /// is certainly wrong.
    static func permanentLockIncomplete(_ outcome: PermanentLockOutcome, diagnostics: String = "") -> TagError {
        let extra = diagnostics.isEmpty ? "" : "\n\(diagnostics)"
        return TagError(
            kind: .permanentLockIncomplete(outcome),
            userMessage: outcome.userMessage,
            diagnostics: outcome.diagnostics + extra
        )
    }

    static func lockedPermanent(diagnostics: String = "") -> TagError {
        TagError(
            kind: .lockedPermanent,
            userMessage: "This tag is permanently locked. Writes are no longer possible.",
            diagnostics: diagnostics
        )
    }

    static func capabilityUnsupported(
        _ capability: TagCapability,
        diagnostics: String = ""
    ) -> TagError {
        TagError(
            kind: .capabilityUnsupported(capability),
            userMessage: "This tag does not support that operation.",
            diagnostics: diagnostics
        )
    }

    static func malformedResponse(_ response: Data, diagnostics: String = "") -> TagError {
        let prefix = diagnostics.isEmpty ? "" : "\(diagnostics)\n"
        return TagError(
            kind: .malformedResponse,
            userMessage: "The tag responded with data this app could not parse.",
            diagnostics: "\(prefix)response=\(response.hexString)"
        )
    }

    static func verificationFailed(diff: Data, diagnostics: String = "") -> TagError {
        let prefix = diagnostics.isEmpty ? "" : "\(diagnostics)\n"
        return TagError(
            kind: .verificationFailed,
            userMessage: "The tag wrote back something different from what was sent. Try the write again.",
            diagnostics: "\(prefix)diff=\(diff.hexString)"
        )
    }

    static func writeOverflow(needed: Int, available: Int, diagnostics: String = "") -> TagError {
        TagError(
            kind: .writeOverflow(needed: needed, available: available),
            userMessage: "These records are too large for this tag.",
            diagnostics: "needed=\(needed)B available=\(available)B \(diagnostics)"
        )
    }

    /// The tag presented is not the one the confirmation was given against.
    ///
    /// Kept apart from `protocolError`, whose first argument is diagnostics and
    /// whose user message blames the chip. Here the tag answered correctly and
    /// the *app* refused, so "The tag responded outside the expected protocol."
    /// is both wrong and useless: the typed-UID gates were built to say this one
    /// sentence, and until now it reached only the diagnostics disclosure.
    static func differentTag(expected: Data, presented: Data, diagnostics: String = "") -> TagError {
        let suffix = diagnostics.isEmpty ? "" : " \(diagnostics)"
        return TagError(
            kind: .protocolError,
            userMessage: "That's a different tag.",
            diagnostics: "expected uid=\(expected.hexString) presented uid=\(presented.hexString)\(suffix)"
        )
    }

    static func protocolError(_ message: String, diagnostics: String = "") -> TagError {
        TagError(
            kind: .protocolError,
            userMessage: "The tag responded outside the expected protocol.",
            diagnostics: "\(message) \(diagnostics)"
        )
    }

    static func unexpected(_ message: String) -> TagError {
        TagError(
            kind: .unexpected,
            userMessage: "Something unexpected happened. Try again.",
            diagnostics: message
        )
    }
}

public extension Data {
    /// Uppercased, colon-delimited hex, matching the syntax the advanced console
    /// accepts on input, so a diagnostics string can be replayed as a command.
    /// The format string below is `%02X`; this comment said "Lowercased" for long
    /// enough that a test was written against the wrong case.
    var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

extension TagError {
    /// Re-file an authentication refusal with the attempt limit the caller read
    /// off the tag in the same activation.
    ///
    /// Only the two authentication kinds are touched, and only when a limit was
    /// actually read and is non-zero. Everything else is returned unchanged, so
    /// a length rejection, a protocol error or a lost session cannot pick up copy
    /// about a limit that has nothing to do with them.
    /// Re-filing must carry `presentedACredential` across. It is a fact about
    /// what went on the wire, and rebuilding the error from its kind and copy
    /// would drop the one thing the early exit in `WriteFlowModel` turns on.
    func qualifiedByAttemptLimit(_ limit: Int?) -> TagError {
        guard let limit, limit > 0 else { return self }
        let sent = presentedACredential
        switch kind {
        case .authFailed:
            let qualified = TagError.authRefused(attemptLimit: limit, diagnostics: diagnostics)
            return sent ? qualified.afterPresentingACredential() : qualified

        case .authInconclusive:
            let qualified = TagError.authInconclusive(attemptLimit: limit, diagnostics: diagnostics)
            return sent ? qualified.afterPresentingACredential() : qualified

        default:
            return self
        }
    }

    /// Re-file an authentication refusal on a tag whose `AUTH_LIM` is gated by
    /// the password being presented.
    ///
    /// The sibling of `qualifiedByAttemptLimit`, for the case where the number
    /// cannot be had at all. On a read-protected Type-2 tag the configuration
    /// pages sit above `AUTH0`, so the app reads the limit only *after* a
    /// password is accepted, and the password is the thing in doubt. Without
    /// this the refusal is indistinguishable from "nothing was read", and the
    /// unlock prompt keeps its neutral first-run copy: nothing tells the owner a
    /// try was spent, and the same button spends another.
    ///
    /// The copy hedges twice over, because both unknowns are real. The transport
    /// form of a refusal is also what a tag leaving the field looks like
    /// (2026-09-14), so it does not say the password is wrong; and no limit was
    /// read, so it does not say one is set. What it does say is the part the
    /// owner can act on: check the password before pressing again.
    func qualifiedByAHiddenAttemptLimit() -> TagError {
        switch kind {
        case .authFailed, .authInconclusive:
            let qualified = TagError.authRefusedWithAHiddenLimit(kind: kind, diagnostics: diagnostics)
            return presentedACredential ? qualified.afterPresentingACredential() : qualified

        default:
            return self
        }
    }
}
