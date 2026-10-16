import Foundation
import HexNFCKit
import HexNFCRecords

/// What the identify tap asks the tag, and what it refuses before the user is
/// asked to type fourteen characters of UID.
///
/// Split from `OperationsFlowModel` because the file outgrew its limit, and
/// split **here** because this is the seam that already existed: everything
/// below runs on tap 1 only, reads only, and throws only with the tag exactly as
/// it was. Nothing in it touches the state machine.
///
/// The standing rule for every read here is that the shared preamble has to have
/// proved it safe. On a Type-2 chip a refused READ NAKs and the NAK halts the
/// chip for the rest of the activation, so a preflight that addresses a page
/// above AUTH0 spends the tap it exists to save.
/// `TagPreamble.Established.provenReadablePage` is the record of what was
/// actually answered, and `TagFamily.gateIsSafeToReadBeforeAuthenticating` is
/// the ordering rule; neither is restated here.
extension OperationsFlowModel {
    /// What tap 1 established about the tag's gate, in the two shapes the
    /// preamble can answer in.
    ///
    /// Kept apart because they are different claims. `state` is configuration
    /// bytes the tag served; `isUpOverThisOperationsRegion` is the preamble
    /// having stopped to ask for a credential, which it does only when the tag's
    /// own configuration reported a gate over the region this operation needs,
    /// or when the tag refused the read that would have described one. The
    /// second says the gate is up and nothing about where it starts.
    struct GateReading {
        var state: TagProtection?
        var isUpOverThisOperationsRegion = false

        /// `true` only where the tag positively said so. An unread gate is never
        /// this, which is what keeps a removal reachable on a tag whose state
        /// could not be established.
        var provenOpen: Bool {
            state.map { !$0.passwordProtect } ?? false
        }

        /// `true` where either shape says a gate is up.
        var provenArmed: Bool {
            isUpOverThisOperationsRegion || (state?.passwordProtect ?? false)
        }
    }

    /// What tap 1 learned beyond the preamble, from the reads one operation is
    /// entitled to make.
    struct PreflightFindings {
        var lock: TagLockReading?
        var attemptLimit: Int?
    }

    /// The protection this run is about to arm, or `nil` when it is arming none.
    ///
    /// Non-nil is exactly "this tap will protect the tag", which is what the
    /// preamble's two chip guards turn on. `WriteFlowModel` states the same rule
    /// at its own call site.
    var armingStyle: ProtectionStyle? {
        guard case .enableProtection(let pending) = operation, pending.settings.passwordProtect else {
            return nil
        }
        return pending.settings.effectiveStyle
    }

    /// What tap 1 has to establish before the typed-UID gate is even offered.
    ///
    /// Reads only. Anything it throws happens with the tag untouched, and the
    /// caller turns it into the same `.error` phase a failed identify produces.
    ///
    /// Every read here is one the preamble proved safe. On a Type-2 chip a
    /// refused READ NAKs and the NAK halts the chip for the rest of the
    /// activation, so a preflight that addresses a page above AUTH0 spends the
    /// tap it exists to save. `Established.provenReadablePage` is the record of
    /// what was actually answered, and `TagFamily.gateIsSafeToReadBeforeAuthenticating`
    /// is the ordering rule; neither is restated here.
    func preflight(
        _ operation: Operation,
        on tag: ConnectedTag,
        _ established: TagPreamble.Established,
        _ gate: GateReading
    ) async throws -> PreflightFindings {
        var findings = PreflightFindings()
        switch operation {
        case .erase:
            // The capability, and deliberately nothing else. An erase rewrites
            // the data area, so the lock state is what decides whether it can
            // land, and reading lock bytes costs frames on the one operation
            // here that is recoverable if it fails. Tap 2's own write is the
            // cheaper answer.
            try tag.require(.ndefWrite)

        case .format:
            try preflightFormat(on: tag, established)

        case .permanentLock:
            findings.lock = try await preflightPermanentLock(on: tag, established, gate)

        case .enableProtection:
            try requireAProtectionBackend(on: tag)

        case .disableProtection:
            try requireAProtectionBackend(on: tag)
            // Only on a reading that positively says so. A reading that could
            // not be taken is not a refusal: it proceeds, and tap 2 decides.
            // Refusing on an absent reading is how a torn removal, which leaves
            // a tag open and holding the factory password, becomes
            // unrecoverable from this screen.
            if gate.provenOpen {
                throw TagError.nothingToRemove(
                    diagnostics: "the gate read says this tag is not protected, so a removal has "
                        + "nothing to remove. Nothing written."
                )
            }

        case .setAttemptLimit:
            let driver = try requireType2PasswordDriver(on: tag)
            switch try await driver.readState() {
            case .read(let config):
                // The whole configuration is in hand here, and until now only
                // `authLimit` survived the branch. `config.protection` is the
                // same read expressed the way the editor speaks, and on the
                // refusal below it is the more useful half: the reason for the
                // refusal is that the gate is open, which is exactly what a card
                // still claiming a password is wrong about.
                publish(uid: tag.uid, protection: config.protection)
                guard config.isGateArmed else {
                    throw TagError.gateNotArmed(
                        diagnostics: "AUTH0=\(config.auth0) is past page \(config.lastAddressablePage), "
                            + "so nothing on this tag is gated. An attempt limit with the gate open "
                            + "guards nothing and only takes the tag's password away later."
                    )
                }
                findings.attemptLimit = config.authLimit

            case .gatedByReadProtection:
                // Reads are gated, which is itself proof the gate is armed. The
                // ACCESS byte is out of reach until a password is presented, so
                // nothing is claimed about the limit the tag already carries.
                findings.attemptLimit = nil
            }

        case .memoryDump:
            // Single tap, so there is no tap 1 to refuse on.
            break
        }
        return findings
    }

    /// The three refusals `formatCC` makes, made again here so they can also
    /// fire with nothing written.
    ///
    /// **Duplicated rather than hoisted**, and `formatCC` keeps every check it
    /// has, the page-3 read and the read-back included. The differing-CC refusal
    /// is the only thing standing between tap 2 and an irreversible OR into page
    /// 3, and a check that ran one activation ago cannot stand in for one that
    /// runs against the tag being written.
    ///
    /// There is deliberately no fourth refusal for a read-gated tag. Page 3 sits
    /// below every AUTH0 this app is able to write, so the read below is
    /// answered on a gated tag exactly as it is on an open one, and a simulator
    /// taught to refuse it would be a simulator taught behaviour no trace has
    /// shown.
    func preflightFormat(on tag: ConnectedTag, _ established: TagPreamble.Established) throws {
        switch tag.chip?.family {
        case .type2:
            guard let cc = tag.chip?.factoryCC else {
                throw TagError.capabilityUnsupported(
                    .formatCC,
                    diagnostics: "Type-2 CC needs a known chip profile; this tag identified as "
                        + "\(tag.chip?.displayName ?? "unidentified") with no factory CC. "
                        + "Page 3 is OTP, so a guessed size byte cannot be undone."
                )
            }
            // The Capability Container as the preamble's own safe pre-read
            // served it. No extra frame, and no frame this tap was not already
            // sending.
            guard let existingCC = established.capabilityContainer else { return }
            guard !Type2CC.isFormatted(existingCC) || existingCC == cc else {
                throw TagError.protocolError(
                    String(localized: "This tag already has a different Capability Container."),
                    diagnostics: "page 3 = \(existingCC.hexString), would OR \(cc.hexString) into it: "
                        + "OTP bits cannot be cleared, so this would corrupt the CC permanently"
                )
            }

        case .type5:
            guard tag.chip?.factoryType5CC != nil else {
                throw TagError.capabilityUnsupported(
                    .formatCC,
                    diagnostics: "Type-5 CC needs known block geometry; profile reports "
                        + "\(tag.chip?.memoryLayout.pageCount ?? 0) × \(tag.chip?.memoryLayout.pageSize ?? 0) B"
                )
            }

        default:
            throw TagError.capabilityUnsupported(
                .formatCC,
                diagnostics: "CC format unsupported on chip family \(tag.chip?.family.shortName ?? "unknown")"
            )
        }
    }

    /// The refusals a permanent lock earns before a single irreversible bit is
    /// set, and the one lock read this flow takes on tap 1.
    ///
    /// The gate refusal is `Type2LockDriver.refuseIfGated`'s, composed here from
    /// the reading the preamble already has rather than from a second state
    /// read. The driver keeps its own: this is the belt and that is the braces,
    /// which is the standing rule for a write with no undo.
    func preflightPermanentLock(
        on tag: ConnectedTag,
        _ established: TagPreamble.Established,
        _ gate: GateReading
    ) async throws -> TagLockReading? {
        try tag.require(.permanentLock)
        guard tag.chip?.memoryLayout.lockPages.first != nil else {
            throw TagError.capabilityUnsupported(
                .permanentLock,
                diagnostics: "chip declares no Type-2 lock pages"
            )
        }
        if gate.provenArmed {
            throw TagError.permanentLockRefusedByGate(
                // `.setCredential`, not `.enable`, for the reason the driver
                // gives: nothing here is arming a gate, and a residue filed as
                // an arm sends the next reader of a bug report looking for a
                // protection write that never happened.
                // `.type2` because that is what the driver files, and the point
                // of this refusal is to be the same refusal one tap earlier.
                // The lock pages this guards are Type-2 pages: `lockPages` is
                // what the check above requires and what `Type2LockDriver`
                // writes.
                ProtectionResidue(
                    family: .type2,
                    intent: .setCredential,
                    gate: gate.state?.protectFromPage.map { .provenArmed(fromPage: $0) } ?? .unknown,
                    completed: [.stateRead]
                ),
                diagnostics: "permanent lock refused on the identify tap: this tag reported a gate "
                    + "over the pages a lock has to write, and the dynamic lock page sits above "
                    + "AUTH0. Remove the password first."
            )
        }
        // The one read this operation is entitled to, and only now: the gate is
        // proven open, so the lock pages are addressable. A gated tag has
        // already been refused above, and an unread gate takes this branch
        // nowhere rather than sending a frame at a page that may be above AUTH0.
        guard gate.provenOpen else { return nil }
        let lock = await tag.readLockState(provenReadablePage: established.provenReadablePage)
        // Published here rather than by the caller, because the refusal below
        // throws and takes the reading with it. A tag that tap 1 finds already
        // permanently locked is the case that most needs to reach the editor:
        // it is what turns the Write button off, and without it the user is told
        // the tag is locked, returns to a card that still offers Write, and
        // finds out again at the tag.
        if lock.state != .unknown {
            publish(uid: tag.uid, lock: lock)
        }
        guard lock.state != .locked else {
            throw TagError.lockedPermanent(
                diagnostics: "lock read on the identify tap: \(lock.diagnostics)"
            )
        }
        return lock
    }

    /// A chip with no protection backend can neither be armed nor unarmed, and
    /// saying so on tap 1 costs the user nothing.
    func requireAProtectionBackend(on tag: ConnectedTag) throws {
        guard tag.protectionStyle == nil else { return }
        throw TagError.capabilityUnsupported(
            .passwordAuth,
            diagnostics: "no protection backend for \(tag.chip?.family.shortName ?? "unknown")"
        )
    }

    func requireType2PasswordDriver(on tag: ConnectedTag) throws -> Type2PasswordDriver {
        guard let driver = tag.type2PasswordDriver else {
            throw TagError.capabilityUnsupported(
                .passwordAuth,
                diagnostics: "the attempt limit is an NTAG21x / Ultralight EV1 ACCESS-byte field; "
                    + "chip=\(tag.chip?.id.description ?? "unidentified") has no Type-2 password hardware"
            )
        }
        return driver
    }
}

/// The record of what the identify tap asked the tag, kept beside the reads that
/// fill it. `OperationsFlowModel.swift` is at its length limit.
public extension OperationsFlowModel {
    /// What the identify tap actually asked the tag.
    ///
    /// Tap 1's whole contract used to be "learn the UID". Measured 2026-09-21:
    /// it logged "resolved ntag213" at 13:35:26 and then asked the tag nothing,
    /// with the tag's AUTH0 and ACCESS one `30 29` away, so every refusal this
    /// flow can make arrived on tap 2, after the user had typed fourteen
    /// characters of UID against a change that was never going to happen.
    ///
    /// Every field here is read off the chip on that tap, or left `nil`. None of
    /// it is inferred from the operation, from a catalogue entry, or from what a
    /// previous run saw.
    struct TagReading: Equatable, Sendable {
        public var uid: Data
        public var chip: ChipID?
        public var chipName: String?
        /// The gate the tag is holding, as the reading found it, or `nil` when
        /// the chip has no protection backend.
        public var style: ProtectionStyle?
        public var firstDataPage: Int?
        /// What the gate read said. `nil` is "not read", never "not protected".
        public var protection: TagProtection?
        /// `true` when the tap ended without establishing the protection state:
        /// the tag asked for a credential tap 1 deliberately does not hold, or
        /// its family cannot be read without writing. A SLIX2 is always this.
        public var protectionIsUnknown: Bool
        /// Only ever read by the permanent lock, which is the one operation
        /// entitled to ask, and only when the gate was proven open.
        public var lock: TagLockReading?
        /// The attempt limit the tag was already carrying, from the ACCESS byte.
        /// `nil` means "not read", never "none": on a read-protected tag the
        /// configuration pages are out of reach until a password is presented,
        /// so there is nothing to report and 0 would be an invention.
        ///
        /// Only ever the *configured limit*. How many attempts a tag has already
        /// spent is not readable: a refused `PWD_AUTH` is a payload-free NAK and
        /// no NTAG21x command discloses the counter, so nothing here may imply
        /// it.
        public var attemptLimit: Int?

        public init(
            uid: Data,
            chip: ChipID? = nil,
            chipName: String? = nil,
            style: ProtectionStyle? = nil,
            firstDataPage: Int? = nil,
            protection: TagProtection? = nil,
            protectionIsUnknown: Bool = false,
            lock: TagLockReading? = nil,
            attemptLimit: Int? = nil
        ) {
            self.uid = uid
            self.chip = chip
            self.chipName = chipName
            self.style = style
            self.firstDataPage = firstDataPage
            self.protection = protection
            self.protectionIsUnknown = protectionIsUnknown
            self.lock = lock
            self.attemptLimit = attemptLimit
        }
    }
}
