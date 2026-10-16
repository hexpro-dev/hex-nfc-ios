import Foundation
import HexNFCKit
import HexNFCRecords

/// Everything a tap does to a tag before it changes anything: the safe
/// pre-read, the family-ordered gate read, the one authentication attempt, the
/// two guards that refuse a change this chip cannot carry, and the decision
/// about whether the gated region is in the way.
///
/// Lifted out of `WriteFlowModel` whole, because the write flow is not the only
/// route that has to do it. Operations opens its own session per operation and
/// today either authenticates by accident or not at all; it cannot run the
/// write flow's state machine until the part that is about the *tag* is
/// separable from the part that is about the *flow*.
///
/// So the split is exactly that. This type takes a `ConnectedTag` and a
/// statement of intent and hands back a reading. It never sees a `TagSession`,
/// never ends one, and sets no field on anybody: a caller that needs a
/// credential is told so and decides for itself what that means on screen.
///
/// It lives in `FlowModels` rather than in `HexNFCKit` because it depends on
/// `ProtectionProbe`, which is internal to this module, and not in `Screens`
/// because every file there is `#if os(iOS)` and `swift test` on macOS skips it
/// whole. `TagAccessIntent` and `ProtectionCardSeed` state the same placement
/// rule.
enum TagPreamble {
    /// What the caller is about to do to this tag, and what it holds for it.
    struct Request: Sendable {
        /// What this tap is going to touch. Decides, against what the gate read
        /// says, whether the tag's credential is needed before the work starts.
        var intent: TagAccessIntent

        /// The credential the caller already holds for this tag, if any. It is
        /// presented at most once, and only to a tag whose own configuration
        /// says something is gated.
        var heldCredential: TagCredential?

        /// The protection this tap is about to arm, or `nil` when it is arming
        /// none. **Non-nil is exactly "this tap will protect the tag"**: the two
        /// chip guards below turn on that and nothing else, so a caller with
        /// settings staged but protection switched off passes `nil` here.
        var stagedStyle: ProtectionStyle?

        /// False on an identify tap. On a SLIX2 the protection read is a write
        /// probe, and a tap that told the user it is reading the tag must not
        /// put a write on the air.
        var writesAllowed: Bool
    }

    /// What one activation established about the tag, for a caller that is now
    /// free to do the work it came for.
    struct Established: Sendable {
        /// Whether a credential was presented and accepted on this activation.
        /// A caller must not present another one: a refused `PWD_AUTH` NAKs and
        /// the NAK halts the chip, so the second attempt is a second *tap*.
        var authenticatedUpFront: Bool

        /// What the gate READ said on this activation, never what the caller
        /// staged. The apply step needs it to decide whether the credential it
        /// holds is one the tag is answering to now.
        var state: TagProtection?

        /// What the safe pre-read found, updated to `.answered` when the
        /// authentication above went through.
        var presence: TagPresence

        /// The highest page a READ was actually answered for while establishing
        /// this, or `nil` when nothing was proven. A later read can address it
        /// without risking a NAK. See `ProtectionProbe.read`.
        var provenReadablePage: Int?

        /// The style of the gate this tag is holding, or `nil` when the reading
        /// found no gate. It is what an unlock prompt would have to ask for, so
        /// it comes from the chip's backend where there is one and falls back to
        /// the settings the tag reported.
        var style: ProtectionStyle?

        /// The first page of the chip's NDEF data area, when it has one.
        var firstDataPage: Int?

        /// The Capability Container page as the safe pre-read served it, or
        /// `nil` when nothing proved those four bytes were page 3.
        ///
        /// Carried because it costs no frame: the pre-read already reads pages 3
        /// to 6 and used to throw everything but the verdict away. A caller that
        /// has to decide whether a tag's CC is the one its chip ships with can
        /// now do so without a second read, and without inventing one from the
        /// catalogue. `ProtectionProbe.preread` withholds the bytes unless the
        /// roll-over check proved they are not page 0 wearing page 3's address,
        /// which is the mistake that would point a user at a Format on a tag
        /// whose page 3 is OTP.
        var capabilityContainer: Data?

        /// Whether the reading found the tag gated. Read off `state`, so a
        /// caller cannot end up asserting protection nothing read.
        var tagWasProtected: Bool {
            state?.passwordProtect ?? false
        }
    }

    /// The tag is gated over the region this tap needs and the caller holds
    /// nothing that opens it, or held something the tag refused.
    struct CredentialRequest: Sendable {
        /// Which kind of credential to ask for: a 4-byte password for
        /// Type-2/SLIX, a 16-byte AES key for an NTAG424.
        var style: ProtectionStyle?

        /// `true` when a credential was presented on this activation and the tag
        /// did not accept it, so the prompt can say so rather than repeating its
        /// first-run copy.
        var offeredCredentialFailed: Bool

        /// The refusal behind that, kept only when the prompt has to say
        /// something its own copy cannot: that the tag has an attempt limit, on
        /// which the chip refuses the *correct* password. See
        /// `TagError.unlockPromptCopy`.
        var refusal: TagError?
    }

    /// What the preamble established, or that it cannot go on without a
    /// credential.
    ///
    /// `throws` cannot carry the second outcome. Four exits below end the run
    /// and ask for a credential, and none of them is an error: thrown, they
    /// would land in the caller's catch and replace the unlock prompt with an
    /// error card, which is the dead end `ProtectionProbe` exists to prevent.
    enum Outcome: Sendable {
        case established(Established)
        case needsCredential(CredentialRequest)
    }

    /// Run the preamble against one activation of `tag`.
    ///
    /// Shared so that the identify tap, the write tap and Operations cannot
    /// diverge, and so a second tap re-establishes state rather than trusting
    /// what the first one saw.
    static func establish(on tag: ConnectedTag, _ request: Request) async throws -> Outcome {
        // If the tag is already password-protected over the area we need to
        // write, the write will be NAK'd unless we authenticate first. Detect it
        // up front (the high-level NDEF write reports a protection NAK as a
        // generic tag-lost, so we can't rely on the write error to tell us) and
        // either authenticate (when we hold the password) or stop and ask.
        // Reads still work on a write-only-protected tag, so this detection
        // succeeds for the common case.
        //
        // Authenticate first whenever we already hold the credential. The
        // config pages sit at or above AUTH0, so on a *read*-protected tag
        // the detection read is itself refused, and a refusal halts a Type-2
        // tag for the rest of the activation. Spending the tag's one
        // pre-auth command on a page it is certain to refuse cost us the
        // whole session.
        // Take the safe pre-read before anything that could be refused, so a
        // later failure can be attributed on evidence. See `ProtectionProbe`.
        // The whole pre-read, not just its verdict: the Capability Container
        // rides out on `Established` for a caller that would otherwise read
        // page 3 a second time.
        let preread = await ProtectionProbe.preread(of: tag)
        let presence = preread.presence

        // **Read the gate before authenticating on a chip whose read ends the
        // session.** Measured on an NTAG424 on 2026-09-20 (bench T4-1): a plain
        // GetFileSettings is refused `91 7E` inside a live EV2 session and
        // answered `91 00` immediately after an ISO SELECT, in the same
        // activation, so the SELECT ends the session. The protection probe
        // SELECTs (`NTAG424ProtectionDriver.readProtectionState`), so running it
        // after the authentication below left every later frame outside the
        // session: a protected 424 answered `WriteData` with `91 AE` and the
        // user was told "Wrong password." about the key that had just worked.
        // The app could neither rewrite nor unprotect a tag it had armed.
        //
        // The order that fixes it is the order Type-2 cannot use. A Type-2 chip
        // halts on a refused read, which is why that family authenticates first
        // (c52ace5); a Type-4 answers a refusal with a status word and stays
        // activated, so the read costs nothing there.
        // The name says which way round it is: true means read the gate
        // first. The rule itself is a silicon fact and lives on TagFamily,
        // where the Operations preflight can reach the same one.
        let readsGateFirst = TagFamily.gateIsSafeToReadBeforeAuthenticating(tag.chip?.family)
        var preAuthState: TagProtection?
        var preAuthRefusedTheRead = false
        // Carried out of whichever read establishes the state, rather than
        // recomputed: the two would drift, and the caller that needs it is the
        // one deciding which pages it may address next.
        var provenReadablePage: Int?
        if readsGateFirst {
            switch await ProtectionProbe.read(from: tag, presence: presence, allowWriteProbe: request.writesAllowed) {
            case .state(let state, let provenPage):
                preAuthState = state
                provenReadablePage = provenPage

            case .refused:
                // A gated read is a reading of the gate, not a lost tag: this
                // chip answers plain commands unless its file is key-gated. The
                // credential below is what opens it.
                preAuthRefusedTheRead = true

            case .lost(let error):
                throw error
            }
        }

        // A tag whose own configuration says nothing is gated is never sent a
        // credential. Type-2 has had this rule inside its driver since the
        // 2026-09-04 incident (`openGate` reads state first and answers
        // `.alreadyOpen` without a frame); the other families present whatever
        // they are handed, and the editor hands this flow the credential it is
        // about to WRITE. So protecting a fresh SLIX2 or Ultralight C sent its
        // not-yet-written password to a tag that had never held it: the refusal
        // stops a SLIX2 answering until an RF reset (SL2S2602 §9.5.3.2) and
        // halts an Ultralight C, and the feature dead-ended at "didn't unlock"
        // on a tag with nothing to unlock. Simulator-confirmed on both families
        // 2026-09-19, and the reason neither had ever armed a tag through the
        // shipping UI.
        let readingSaysOpen = preAuthState.map { !$0.passwordProtect } ?? false
        var authenticatedUpFront = false
        if let heldCredential = request.heldCredential, !readingSaysOpen {
            do {
                _ = try await tag.authenticate(heldCredential)
                authenticatedUpFront = true
            } catch let error as TagError where error.spentTheActivation {
                // A credential frame went out and nothing accepted it:
                // refused, or its answer lost. Either way the tag is protected
                // and the activation is spent, because a refused PWD_AUTH
                // halts the chip and everything after it is answered by
                // silence. Stop here and keep the refusal for the prompt.
                //
                // This used to ask `limitReading != .notRead`, which is a
                // different question and the wrong one. ProtectionSpec.make
                // forces authLimit 0 on every tag this app arms, so the
                // refusal came back .notRead, the exit never fired, and the
                // flow sent two more reads at a halted chip: measured
                // 2026-09-21 at 13:35:00.793, 13:35:01.105 and 13:35:01.418,
                // all failing, 626 ms of a tap the user was holding a tag
                // still for. Also measured on 2026-09-10, 11:57:45 to
                // 11:58:33, on the limited tag the old predicate did catch.
                //
                // `offeredCredentialFailed` is set for both forms, unlike
                // `ScanFlowModel`, which leaves it clear for the transport form.
                // The write prompt already said "didn't unlock" for that form on
                // silicon (through the `.refused` route below), and on a limited
                // tag the transport form is what an unlocked chip gives a wrong
                // password (2026-09-14), so taking the feedback away would be
                // the regression.
                //
                // The boundary the predicate must not cross is
                // `TagError.readProtected`, which wears `.authFailed` so the
                // existing classification keeps matching but is thrown before
                // any authentication. It carries `presentedACredential: false`
                // and keeps the state-read route below, as it did.
                //
                // Type-4 and Type-5 also keep that route. They answer a
                // refusal with a status word and stay activated, so nothing is
                // spent, and the editor hands this flow the key it is about to
                // write: on a blank NTAG424 a refused handshake says nothing
                // about protection and the state read below is what decides.
                return .needsCredential(CredentialRequest(
                    style: tag.protectionStyle,
                    offeredCredentialFailed: true,
                    refusal: error
                ))
            } catch {
                // Left to the state read below, as before.
            }
        }

        let existingState: TagProtection?
        // Authenticating past the lock invalidates what the pre-read saw: the
        // pages it found gated are ours now, so the config read below will
        // answer. Without this a tag we had just unlocked would be sent
        // straight back to the password prompt.
        let effectivePresence: TagPresence = authenticatedUpFront ? .answered : presence
        if readsGateFirst {
            // The reading is already in hand, from before the session existed,
            // and asking again would end it.
            if let preAuthState {
                existingState = preAuthState
            } else if preAuthRefusedTheRead {
                guard tag.protectionStyle != nil else {
                    throw TagError.readProtected(
                        diagnostics: "the file settings are gated on a chip with no protection backend"
                    )
                }
                guard authenticatedUpFront else {
                    // The gate is armed and nothing here can open it.
                    return .needsCredential(CredentialRequest(
                        style: tag.protectionStyle,
                        offeredCredentialFailed: request.heldCredential != nil,
                        refusal: nil
                    ))
                }
                // The read was refused and the credential then opened the tag.
                // Both halves are readings of this activation, so the tag is
                // protected and the app holds what opens it. The style comes
                // from the chip rather than from a guess about its settings.
                var gated = TagProtection()
                gated.passwordProtect = true
                gated.style = tag.protectionStyle
                existingState = gated
            } else {
                existingState = nil
            }
        } else {
            switch await ProtectionProbe.read(
                from: tag,
                presence: effectivePresence,
                allowWriteProbe: request.writesAllowed,
                credentialAlreadyProven: authenticatedUpFront
            ) {
            case .state(let state, let provenPage):
                existingState = state
                provenReadablePage = provenPage

            case .refused(let error):
                // The refusal *is* the answer, but only once the tag has been
                // shown to refuse rather than to have wandered off. On a chip
                // with a protection backend, a config-page read that gets NAK'd
                // means the tag is read-protected and we are not authenticated
                // for it, so this is the unlock prompt's cue.
                //
                // `try?` used to swallow this into `nil`, which read as "no
                // protection": the flow went on to write at a tag that had
                // already halted, and the user got a dead end where the unlock
                // prompt belonged. The fix for that then claimed protection from
                // *any* failed read, which is how an unprotected tag came to ask
                // for a password it never had.
                guard tag.protectionStyle != nil else { throw error }
                // No refusal to report: the only route that files one is the
                // authentication above, and it returns rather than falling
                // through to here. What the caller must not do is invent one.
                // On 2026-09-21 the driver's own words for a refusal were
                // thrown away on the way to this prompt and it fell back to
                // "That password didn't unlock the tag." about a tap where
                // nothing had established that.
                return .needsCredential(CredentialRequest(
                    style: tag.protectionStyle,
                    offeredCredentialFailed: request.heldCredential != nil,
                    refusal: nil
                ))

            case .lost(let error):
                // The tag stopped answering. Say so, and never dress a lost tag up
                // as a locked one.
                throw error
            }
        }

        // Both guards run before the credential exits below, so a change this
        // chip cannot carry fails on the identify tap, before the user is asked
        // for a password or for fourteen typed characters.
        if let staged = request.stagedStyle {
            // `protectionStyle` is the whole gate. It must not be anded with
            // `.passwordAuth`: an Ultralight C drives its backend off
            // `.tripleDESAuth`, so the extra check rejected the one chip whose
            // key the editor had just collected, after the records were
            // already written, which is the strand this guard exists to
            // prevent.
            guard let backend = tag.protectionStyle else {
                throw TagError.capabilityUnsupported(
                    .passwordAuth,
                    diagnostics: "no protection backend for \(tag.chip?.family.shortName ?? "unknown")"
                )
            }
            // The same rule one notch finer: a backend exists, but it is not the
            // one these settings were built for. The Protection card has no chip
            // to key off on a build with no tag behind it and resolves to Type-2,
            // and "Save as preset" stores that for replay across a stack, so a
            // 4-byte PWD can arrive at a tag that wants a 16-byte AES key.
            // Without this the mismatch surfaces at driver dispatch, which is
            // after the records are on the tag and after a credential record has
            // been filed against its UID.
            //
            // Families, not whole styles: a chip answers with its backend's
            // default settings while the staged style carries the user's AUTH0
            // and PROT, so `==` would refuse every configured arm.
            if staged.family != backend.family {
                throw TagError.capabilityUnsupported(
                    .passwordAuth,
                    diagnostics: "staged \(staged.family.rawValue) protection against a "
                        + "\(backend.family.rawValue) chip (\(tag.chip?.family.shortName ?? "unknown"))"
                )
            }
        }

        var gateStyle: ProtectionStyle?
        if let existing = existingState, existing.passwordProtect {
            // Capture the family so the unlock prompt asks for the right kind
            // of credential (a 424 needs its 16-byte key, not a 4-byte PWD).
            gateStyle = tag.protectionStyle ?? existing.effectiveStyle
            let ndefUpper = tag.chip?.memoryLayout.ndefRange?.upperBound ?? Int.max
            // The editor spelled this inline as "AUTH0 is at or below the end of
            // the data area, or we are removing protection". Stated as an intent
            // it also covers the case that spelling missed: a tap that writes a
            // configuration page needs the credential wherever AUTH0 sits,
            // because AUTH0 itself is above it.
            if request.intent.needsCredential(given: existing, ndefUpperBound: ndefUpper) {
                guard let heldCredential = request.heldCredential else {
                    // No credential in hand, so stop and ask. The re-tap
                    // authenticates up front.
                    return .needsCredential(CredentialRequest(
                        style: gateStyle,
                        offeredCredentialFailed: false,
                        refusal: nil
                    ))
                }
                // Already done above unless it failed, in which case retrying
                // it here is what surfaces the wrong-password error.
                // One credential frame per activation, and
                // `authenticatedUpFront` is the whole record of whether one has
                // gone out: every route that sent one either set it or returned
                // above. So this arm is only for the case where the up-front
                // attempt threw before sending anything: a state read that did
                // not complete, a length rejection, a family that never got
                // that far. Bench finding 25 was this arm firing a second
                // frame, and `spentTheActivation` is what now stops it.
                if !authenticatedUpFront {
                    do {
                        _ = try await tag.authenticate(heldCredential)
                    } catch {
                        // This is the first frame of the activation, so
                        // whatever it says about the tag is worth keeping.
                        return .needsCredential(CredentialRequest(
                            style: gateStyle,
                            offeredCredentialFailed: true,
                            refusal: error as? TagError
                        ))
                    }
                }
            }
        }

        return .established(Established(
            authenticatedUpFront: authenticatedUpFront,
            state: existingState,
            presence: effectivePresence,
            provenReadablePage: provenReadablePage,
            style: gateStyle,
            firstDataPage: tag.chip?.memoryLayout.ndefRange?.lowerBound,
            capabilityContainer: preread.capabilityContainer
        ))
    }
}
