import Foundation
import HexNFCKit
import HexNFCRecords
import HexNFCStorage
import Observation

/// State machine for "scan one tag and read its NDEF message". Drives the
/// `ScanSheet` UI; the sheet observes `phase` and the moment composer fires
/// on every transition.
@Observable
@MainActor
public final class ScanFlowModel {
    public enum Phase: Equatable, Sendable {
        case idle
        case polling
        case connected
        case reading
        case ready
        /// The tag is (likely) password-protected and couldn't be read. The UI
        /// collects a password and calls `unlock(with:)`, which re-scans and
        /// authenticates before reading. We can't prompt mid-session — the NFC
        /// sheet owns the screen — so the user re-taps with the password.
        case locked
        /// The tapped chip is an electronic passport. We can't read it until the
        /// holder supplies the MRZ access key, and we can't prompt mid-session
        /// (the NFC sheet owns the screen), so — exactly like `.locked` — the UI
        /// collects the key and `readPassport(with:)` re-taps to authenticate.
        case needsPassportKey
        /// The user closed the system sheet before any tag was in play, and no
        /// earlier session of this flow had one either. Nothing was read, so
        /// nothing is reported: the sheet closes and the user is back where they
        /// were before they asked to scan. See `TagContact`.
        case cancelled
        /// The session reached its time limit with nothing in the field, on a
        /// flow that has never had a tag. Not a failure, so it carries no error
        /// and no diagnostics: the sheet says no tag was found and offers
        /// another go.
        case noTagFound
        case error(message: String, diagnostics: String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var connectedTag: ConnectedTag?
    public private(set) var records: [NDEFRecord] = []

    /// Set when the scanned tag is a decodable transit card (Suica family).
    /// When non-nil the scan routes to the read-only transit view rather than
    /// the record editor.
    public private(set) var transitCard: TransitCard?

    /// Set when an electronic passport was read. **Session-only**: held here for
    /// the result view and dropped on `reset()` — never persisted anywhere.
    public private(set) var passportData: PassportData?

    /// Live progress (0...1) of the in-flight passport read, driven by the
    /// reader's stage callbacks. The scan screen's unlock reveal follows this so
    /// the shader builds *during* the read (behind iOS's NFC card) and bursts as
    /// it completes. Monotonic (never steps backward); `0` when no read is in
    /// flight, so it doubles as the "a passport is being read now" flag.
    public private(set) var passportReadProgress: Double = 0

    /// The MRZ access key for a passport read, set by `readPassport(with:)` and
    /// used on the re-tap. Held in memory for the session only; never persisted.
    private var passportKey: PassportMRZ?

    /// `true` when the last passport read attempt failed (wrong details / read
    /// error), so the prompt can say "couldn't read — check the details".
    public private(set) var passportReadFailed = false

    /// What the scan established about the tag's NDEF structure, and which
    /// repair that calls for.
    ///
    /// It costs nothing to know. `queryNDEFStatus` already answers
    /// `.notSupported` for a tag no reader can see a message on, which reaches
    /// us as `capabilityUnsupported(.ndefRead)`, while a blank-but-formatted one
    /// returns empty data without throwing. The two were collapsed into the same
    /// "zero records" outcome and the distinction thrown away.
    ///
    /// Worth surfacing because the flow otherwise dead-ends: a factory MIFARE
    /// Ultralight C ships with page 3 blank (MF0ICU2 rev 3.3 Table 13), so the
    /// user scans it, sees an ordinary empty tag, adds a record, writes, and the
    /// verify read fails with "This tag does not support that operation" on a tag
    /// that supports it perfectly well and just needs formatting first.
    ///
    /// It was a `Bool` until 2026-09-09, and the `Bool` was inferred rather than
    /// read: any catalogued Type-2 chip whose NDEF read was refused got labelled
    /// unformatted, whatever page 3 held. `TagFormatState` carries the two
    /// states apart and each one is a reading. See its doc comment for the tag
    /// that made the difference matter.
    public private(set) var formatState: TagFormatState = .unknown

    /// Read-only silicon facts collected after the NDEF read: originality
    /// signature, tap counter, tamper loop. Empty for chips that expose none.
    ///
    /// **Always read last, and never allowed to affect the scan result.** These
    /// probes are the ones that can be legitimately refused (a factory NTAG's
    /// counter is disabled and NAKs `READ_CNT`), and a refusal halts a Type-2 tag
    /// for the rest of the activation. Running them after the records are read
    /// and persisted means the worst case is that a diagnostic is missing, never
    /// that the user's scan fails.
    public private(set) var diagnostics = TagDiagnostics()

    /// Live password-protection state read off the tag during the scan (Type-2
    /// only). Seeds the editor's Protection card so a tag locked elsewhere —
    /// or by a previous Hex session — shows its real state instead of "Off".
    /// Best-effort: a read failure or a non-Type-2 chip leaves this nil.
    public private(set) var detectedProtection: TagProtection?

    /// What the tag's lock bytes said on this activation.
    ///
    /// Separate from `detectedProtection` because they are separate facts about
    /// separate silicon: a password gate is reversible and a lock bit is not,
    /// and a tag can be both, either, or neither. `.notRead` is the default and
    /// renders as nothing at all, never as "not locked".
    public private(set) var detectedLock: TagLockReading = .notRead

    /// The highest page a READ has been answered for on this activation, from
    /// the protection read. `nil` sends no lock frames at all.
    private var provenReadablePage: Int?

    /// Credential to authenticate with after connecting, set by `unlock(with:)`
    /// when a read-protected tag is re-scanned. `nil` on the first attempt.
    /// Family-tagged so a read-protected NTAG424 (16-byte key) or SLIX unlocks
    /// through its own backend, not just the Type-2 PWD path.
    ///
    /// It deliberately survives `begin()`, because the whole point of it is that
    /// it is supplied between taps with no session open. `unlockCredentialFor`
    /// is what keeps that from becoming a credential presented to a stranger.
    private var unlockCredential: TagCredential?
    /// The UID of the tag whose refusal produced `unlockCredential`, taken from
    /// the tag itself and never from anything typed.
    ///
    /// Without it, "Unlock and scan again" presented tag A's password to
    /// whatever tag was next in the field. On a Type-2 chip that is a counted
    /// attempt against the wrong tag, and on a limited one it can be the attempt
    /// that takes the tag's password away for good. The write and operations
    /// flows already refuse to act on a tag they did not read; this one had no
    /// comparison anywhere.
    private var unlockCredentialFor: Data?
    /// `true` when the tag answered a safe read on this activation, so a read
    /// that fails afterwards can be attributed to protection rather than to the
    /// tag having left the field. See `ProtectionProbe`.
    private var tagAnsweredBeforeRead = false
    /// The full verdict behind `tagAnsweredBeforeRead`, carried to the protection
    /// read so it can tell a refusal from a tag that went away.
    private var presence: TagPresence = .unknown
    /// What the session's one safe pre-read returned. Read once, and the only
    /// source for the Capability Container and the data area's opening bytes:
    /// neither is ever inferred.
    private var preread = TagPreread(presence: .unknown)
    /// `true` when the protection read was attempted and refused, as opposed to
    /// returning "this chip has no protection backend".
    ///
    /// `readProtectionState()` returns `nil` for a chip that cannot be protected
    /// and *throws* when the read itself failed, and `try?` collapsed the two
    /// into one `nil`. The editor then seeded `protection ?? .none` and showed
    /// "Off" for a tag whose state we never learned. Seen live on 2026-08-14
    /// when a tag slipped between the two config-page reads: `30 29` answered,
    /// `30 2A` dropped, and the card said Off.
    ///
    /// Nothing unsafe followed from it (the write flow reads protection again
    /// and prompts), but reporting a state we failed to read is the same
    /// mistake as trusting an ACK, and it is worth exactly as little.
    public private(set) var protectionReadFailed = false
    /// `true` when the last unlock attempt was made with a password that still
    /// failed to read the tag, so the prompt can say "incorrect password".
    public private(set) var unlockFailed = false
    /// The refusal behind the last failed unlock, for the prompt to show when it
    /// knows the tag has an attempt limit. See `WriteFlowModel.unlockRefusal`.
    ///
    /// Reachable here, not only on read-protected tags: a write-only-protected
    /// tag lifted mid-read, whose message runs past page 6, still gets the prompt,
    /// and on the re-tap the driver reads its configuration pages and the limit
    /// with them.
    public private(set) var unlockRefusal: TagError?

    /// Display name of the identified chip, if any (e.g. "NTAG215",
    /// "MIFARE DESFire"). `nil` until a tag is connected and identified.
    public var detectedChipName: String? {
        connectedTag?.chip?.displayName
    }

    /// Colon-delimited hex UID of the connected tag, if available.
    public var detectedUIDHex: String? {
        guard let uid = connectedTag?.uid, !uid.isEmpty else { return nil }
        return uid.hexString
    }

    /// Display-ready snapshot of the connected tag's identity, for the editor's
    /// "Tag" meta section. `nil` until a tag is connected.
    public var scannedTagInfo: ScannedTagInfo? {
        guard let tag = connectedTag else { return nil }
        let bytes = tag.chip?.memoryLayout.byteCount ?? 0
        let ndef = tag.chip?.ndefByteCapacity ?? 0
        return ScannedTagInfo(
            chipName: tag.chip?.displayName,
            familyName: tag.chip?.family.shortName,
            manufacturer: tag.chip?.manufacturer,
            uidHex: tag.uid.isEmpty ? nil : tag.uid.hexString,
            totalBytes: bytes > 0 ? bytes : nil,
            ndefBytes: ndef > 0 ? ndef : nil,
            capabilitySummary: ScannedTagInfo.capabilitySummary(fromRaw: tag.capabilities.rawValue),
            supportsPasswordProtection: Self.supportsPasswordProtection(tag),
            protectionStyle: tag.protectionStyle,
            unidentifiedSummary: tag.unidentifiedReport?.summary,
            unidentifiedVersionHex: tag.unidentifiedReport?.versionHex,
            featureSummary: ScannedTagInfo.featureSummary(fromRaw: tag.capabilities.rawValue),
            formatState: formatState,
            diagnostics: diagnostics,
            lock: detectedLock
        )
    }

    /// Monotonically increasing — used by `.hexHero` modifiers to fire the
    /// moment composer exactly once per transition into the same Phase.
    public private(set) var transitionCount: Int = 0

    private let factory: TagSessionFactory
    private let library: LibraryRepository?
    private var currentSession: TagSession?
    /// Whether any session of this scan has had a tag. Survives `reset()` and
    /// the unlock and passport re-taps on purpose: once a tag has been in play,
    /// a cancel or a timeout is reported as it always has been.
    private var contact = TagContact()

    public init(factory: TagSessionFactory, library: LibraryRepository? = nil) {
        self.factory = factory
        self.library = library
    }

    public func begin(alert: String = NFCPrompt.holdTag) async {
        guard case .idle = phase else { return }
        let session = factory.makeSession()
        currentSession = session
        connectedTag = nil
        detectedProtection = nil
        detectedLock = .notRead
        provenReadablePage = nil
        formatState = .unknown
        tagAnsweredBeforeRead = false
        presence = .unknown
        preread = TagPreread(presence: .unknown)
        protectionReadFailed = false
        diagnostics = TagDiagnostics()
        transition(to: .polling)

        do {
            let tag = try await session.start(alert: alert)
            contact.tagArrived()
            connectedTag = tag
            transition(to: .connected)
            transition(to: .reading)

            // Electronic passports need the MRZ access key before any data can be
            // read. On the first tap we just identify it and prompt; on the
            // re-tap (with the key set) we authenticate and read. Nothing about
            // the passport — key or data — is ever persisted.
            if tag.capabilities.contains(.epassportRead),
               let passport = tag as? EPassportReadable
            {
                if let key = passportKey {
                    // Advance the reveal on every APDU exchange. A passport read is
                    // hundreds of commands (the DG2 photo alone is a long run of
                    // READ BINARY chunks), all flowing through `NFCTrace`, so the
                    // build creeps smoothly between the reader's coarse stage
                    // milestones instead of stepping. The stage callback still
                    // floors progress to each milestone; the creep fills the gaps.
                    let creepTask = Task { @MainActor [weak self] in
                        for await event in NFCTrace.shared.events() {
                            guard let self else { break }
                            if event.direction == .tx {
                                creepPassportProgress()
                            }
                        }
                    }
                    do {
                        let reader = EPassportReader()
                        // Seed a small nonzero progress so the scan-screen reveal
                        // switches on the moment the read starts (before the first
                        // stage callback lands).
                        passportReadProgress = 0.02
                        let data = try await reader.read(passport, mrz: key) { [weak self] fraction, stage in
                            Task { @MainActor in
                                self?.advancePassportProgress(fraction)
                                await session.updateAlert(Self.passportProgress(stage))
                            }
                        }
                        creepTask.cancel()
                        passportData = data
                        passportReadProgress = 1.0
                        records = []
                        // Session-only: deliberately NOT persisted to history.
                        transition(to: .ready)
                        await session.invalidate(error: nil)
                        currentSession = nil
                        return
                    } catch {
                        // Wrong details or a read error — offer another attempt.
                        creepTask.cancel()
                        passportReadProgress = 0
                        passportReadFailed = true
                        await session.invalidate(error: nil)
                        currentSession = nil
                        transition(to: .needsPassportKey)
                        return
                    }
                } else {
                    // First tap: it's a passport; collect the key, then re-tap.
                    await session.invalidate(error: nil)
                    currentSession = nil
                    transition(to: .needsPassportKey)
                    return
                }
            }

            // Transit cards (Suica/PASMO family) carry no NDEF — read their
            // history service instead and route to the read-only transit view.
            if tag.capabilities.contains(.transitRead),
               let felica = tag as? FeliCaReadable,
               let card = try await TransitReader().read(felica)
            {
                transitCard = card
                records = []
                persistScan(tag, records: [], transitCard: card)
                transition(to: .ready)
                await session.invalidate(error: nil)
                currentSession = nil
                return
            }

            // Re-scanning to unlock a protected tag: authenticate first so the
            // protection read and NDEF read below succeed.
            //
            // A refusal here is **not** harmless, which is what this branch used
            // to assume when it dropped the result into a `try?`. A wrong Type-2
            // password NAKs, and a NAK returns the chip to HALT for the rest of
            // the activation, so every read below it drew silence and the flow
            // blamed a lost tag for a password the chip had just told us it
            // rejected. The user got "Lost the tag mid-read" and no way back to
            // the prompt.
            //
            // A *stated* refusal is the strongest evidence there is, so act on
            // it: back to the prompt, marked failed.
            //
            // A check that did not complete used to be left to the reads below,
            // on the reasoning that the tag may genuinely have gone and those
            // reads are what can tell. On silicon they cannot. A refused Type-2
            // PWD_AUTH arrives as the transport form, the NAK has already
            // returned the chip to HALT, so `ProtectionProbe.preread` draws
            // silence, `tagAnsweredBeforeRead` goes false, and the recovery at
            // the bottom of this method cannot fire because it requires that
            // flag. The flow ended at "Lost the tag mid-read" with the unlock
            // prompt gone entirely: the same dead end this branch was written to
            // remove, reached by the other door (bench 2026-09-09, finding 3).
            //
            // So both outcomes end the activation and go back to the prompt. They
            // differ in `unlockFailed`, which only the stated refusal sets, and
            // that flag chooses the prompt's words only on a tag whose limit was
            // not read: when the driver read one, the refusal carries the copy
            // for both forms (`TagError.unlockPromptCopy`).
            //
            // Before any of that: is this even the tag the credential belongs
            // to? It was supplied between taps, against a tag that is no longer
            // in the field, and nothing made the user put the same one back.
            // Presenting it to a stranger costs that tag an attempt it did not
            // owe, and on a tag with a limit it can be the attempt that ends
            // authentication on it permanently. So the held credential is
            // dropped and this tap carries on unauthenticated, which is exactly
            // what a first scan of this tag would have done.
            if unlockCredential != nil, let heldFor = unlockCredentialFor, heldFor != tag.uid {
                NFCTrace.shared.note(
                    "a different tag arrived; the held unlock credential is not for it, so it was dropped",
                    label: "unlock"
                )
                unlockCredential = nil
                unlockCredentialFor = nil
            }
            if let unlockCredential {
                do {
                    _ = try await tag.authenticate(unlockCredential)
                } catch let error as TagError {
                    switch error.kind {
                    case .authFailed:
                        // The chip said no. This is the one place a password may
                        // be accused.
                        unlockFailed = true
                        unlockRefusal = error
                        await session.invalidate(error: nil)
                        currentSession = nil
                        transition(to: .locked)
                        return

                    case .authInconclusive:
                        // The activation is over and the tag is still the
                        // protected one this tap came back for: `openGate` read
                        // that gate milliseconds ago, so "still protected" is a
                        // reading rather than a guess. The check did not
                        // complete, so `unlockFailed` stays false and nothing
                        // here calls the password wrong.
                        //
                        // What the prompt shows turns on whether the driver read
                        // a limit. Without one it comes back with its own
                        // first-run copy. With one, the refusal's hedged copy
                        // replaces it (`TagError.unlockPromptCopy`): the password
                        // didn't open the tag, a wrong try counts, check it
                        // before trying again. On a limited tag this form is what
                        // an unlocked chip gives a wrong password (2026-09-14),
                        // and that owner is the one a warning can still save.
                        unlockRefusal = error
                        await session.invalidate(error: nil)
                        currentSession = nil
                        transition(to: .locked)
                        return

                    default:
                        // Not an authentication outcome at all: leave it to the
                        // reads below, which is where this branch was already right.
                        break
                    }
                } catch {
                    // Same. Nothing here says the credential was wrong.
                }
            }

            // Establish that the tag is actually answering, before any later
            // failure gets blamed on a password.
            //
            // A failed NDEF read has two very different causes that look
            // identical from the error alone: the tag is read-protected, or the
            // tag left the field. Page 3 is the Capability Container, which sits
            // below any AUTH0 this app will write (the minimum is page 4) and is
            // the page CoreNFC's own NDEF query reads first anyway. If it comes
            // back, the tag was present and talking a few milliseconds ago, so a
            // read that fails straight after is the protection speaking. If it
            // does not, we have no business claiming anything about a password.
            //
            // Without this the unlock prompt was a guess: a tag lifted mid-scan
            // asked the user for a password it did not have and did not need
            // (live NTAG213, 2026-08-14, on a tag whose protection had just been
            // removed and verified removed).
            preread = await ProtectionProbe.preread(of: tag)
            presence = preread.presence
            // Pages 3 to 6 came back in that one frame. Page 3 is what decides,
            // a few lines below, whether a refused NDEF read means "no
            // Capability Container" or "the data area is the problem"; pages 4
            // and 5 are what the diagnostics row shows when it is the latter.
            tagAnsweredBeforeRead = (presence != .silent)

            let message = try await tag.readNDEF()
            let parsed = (try? NDEFCodec.decode(message)) ?? []
            records = parsed
            // The read came back, so the Capability Container and the data area
            // are both sound. Zero records is still readable.
            formatState = .readable
            // Read the live protection state only once the NDEF read has proven
            // the tag answers us, and never before it.
            //
            // This used to run first, so that a blank tag still reported its
            // protection. On a **read-protected** tag it was fatal: the config
            // pages sit at or above AUTH0, so the READ is NAK'd, and on this
            // transport a NAK returns a Type-2 tag to HALT for the rest of the
            // activation. The `try?` hid the refusal and every command after it
            // was shouting at a chip that had stopped listening, so the scan
            // died with a generic error and no way to unlock. Live NTAG213,
            // 2026-08-14: `30 29` → `00`, then nothing for the rest of the
            // session. The blank-tag case is handled where blank tags actually
            // land, in the `capabilityUnsupported(.ndefRead)` branch below.
            await readProtection(from: tag)
            persistScan(tag, records: parsed, protection: detectedProtection)
            await readLock(from: tag)
            await readDiagnostics(from: tag)
            transition(to: .ready)
            await session.invalidate(error: nil)
            currentSession = nil
        } catch let error as TagError where error.kind == .capabilityUnsupported(.ndefRead) {
            // The tag connected fine but carries no NDEF message — transit
            // cards (Myki, etc.), key-locked DESFire applications, and blank or
            // unformatted chips all land here. That's a successful scan of zero
            // records, not a failure: keep the identified tag so the UI can show
            // the chip and UID, and don't surface a scary error.
            records = []
            if let tag = connectedTag {
                // …but they are not all the same "zero records", and two of
                // them are actionable in opposite directions. Which one this is
                // turns on page 3, which the pre-read above already fetched:
                // no Capability Container means format it, a Capability
                // Container that is present and refused anyway means the data
                // area is what needs rewriting. Gated on a chip we hold a
                // datasheet CC for, so the UI only ever names a repair it could
                // actually perform.
                formatState = Self.formatState(for: tag, capabilityContainer: preread.capabilityContainer)
                // A blank or unformatted tag never halted: `queryNDEFStatus`
                // answered cleanly with "not supported". So the config read is
                // safe here, which is what keeps the editor reporting protection
                // on a tag that carries no records.
                await readProtection(from: tag)
                persistScan(tag, records: [], protection: detectedProtection)
                // A blank tag can be a locked one: erasing a tag does not clear
                // its lock bits. Missing this branch is how a locked-then-erased
                // tag would still have read "Off".
                await readLock(from: tag)
                // An unformatted chip still has a signature and a counter, and
                // this is the scan most in need of detail: the user is holding
                // something the app can't yet read.
                await readDiagnostics(from: tag)
                // Last, because `readDiagnostics` replaces the whole struct.
                //
                // Only for the one state where these bytes are the finding. On
                // a tag that reads they are ordinary content and the row would
                // be noise, and on a tag with no Capability Container the fault
                // is page 3 and the data area is beside the point.
                if formatState == .unreadableDataArea {
                    diagnostics.dataAreaPrologue = preread.dataAreaPrologue
                }
            }
            transition(to: .ready)
            await session.invalidate(error: nil)
            currentSession = nil
        } catch let error as TagError {
            // A read failure on a Type-2 chip that supports password auth most
            // likely means the tag is read-protected: the chip NAKs the read,
            // which the high-level NDEF read surfaces as a tag-lost rather than a
            // clean authFailed. Offer the unlock path instead of a dead end.
            if let tag = connectedTag,
               Self.supportsPasswordProtection(tag),
               tagAnsweredBeforeRead,
               Self.isLikelyProtectionFailure(error),
               !Self.prereadDisprovesGating(preread, for: error)
            {
                unlockFailed = (unlockCredential != nil)
                unlockRefusal = nil
                await session.invalidate(error: nil)
                currentSession = nil
                transition(to: .locked)
                return
            }
            // An empty sheet the user closed, or one iOS timed out, on a scan
            // that has never had a tag. The session has already torn down, so
            // this invalidate returns at once, and it carries no message
            // because there is no failure to put in one.
            if let ending = contact.quietEnding(for: error) {
                await session.invalidate(error: nil)
                currentSession = nil
                transition(to: ending == .cancelled ? .cancelled : .noTagFound)
                return
            }
            await session.invalidate(error: String(localized: error.userMessage))
            currentSession = nil
            transition(to: .error(
                message: String(localized: error.userMessage),
                diagnostics: error.diagnostics
            ))
        } catch {
            _ = contact.quietEnding(for: error)
            await session.invalidate(error: nil)
            currentSession = nil
            transition(to: .error(
                message: "Something unexpected went wrong.",
                diagnostics: "\(error)"
            ))
        }
    }

    /// Supply the credential for a read-protected tag (from the `.locked` prompt)
    /// and re-scan — the new session authenticates before reading. Family-tagged
    /// so a 424 (16-byte key) or SLIX unlocks via its own backend.
    public func unlock(with credential: TagCredential) async {
        guard case .locked = phase else { return }
        unlockCredential = credential
        // The tag the refusal came from is still the connected one: every route
        // into `.locked` ends the activation without clearing it. An empty UID
        // identifies nothing, so it is filed as "no tag recorded" rather than as
        // a value the next tap could accidentally match.
        unlockCredentialFor = connectedTag.map(\.uid).flatMap { $0.isEmpty ? nil : $0 }
        unlockFailed = false
        unlockRefusal = nil
        transition(to: .idle)
        await begin()
    }

    /// Supply the MRZ key for a detected passport (from the `.needsPassportKey`
    /// prompt) and re-tap: the new session identifies the passport again and, now
    /// that a key is set, authenticates and reads. Mirrors `unlock(with:)`.
    public func readPassport(with mrz: PassportMRZ) async {
        guard case .needsPassportKey = phase else { return }
        passportKey = mrz
        passportReadFailed = false
        transition(to: .idle)
        await begin()
    }

    public func reset() {
        Task { await currentSession?.invalidate(error: nil) }
        currentSession = nil
        connectedTag = nil
        records = []
        transitCard = nil
        passportData = nil
        passportReadProgress = 0
        passportKey = nil
        passportReadFailed = false
        detectedProtection = nil
        detectedLock = .notRead
        provenReadablePage = nil
        formatState = .unknown
        tagAnsweredBeforeRead = false
        presence = .unknown
        preread = TagPreread(presence: .unknown)
        protectionReadFailed = false
        diagnostics = TagDiagnostics()
        unlockCredential = nil
        unlockCredentialFor = nil
        unlockFailed = false
        unlockRefusal = nil
        transition(to: .idle)
    }

    /// Advance the live passport-read progress, clamped monotonic so an
    /// out-of-order stage callback (the reader fires each on its own Task) can't
    /// make the reveal step backward.
    private func advancePassportProgress(_ fraction: Double) {
        passportReadProgress = min(1.0, max(passportReadProgress, fraction))
    }

    /// The reader's coarse stage fractions. Used only to cap the per-command
    /// creep so it eases toward (but never past) the next stage milestone; the
    /// stage callback does the crossing. Kept in sync with `EPassportReader`.
    private static let readMilestones: [Double] = [0.05, 0.15, 0.35, 0.55, 0.70, 0.75, 0.85, 0.95, 1.0]

    /// Nudge the read progress forward a touch on each APDU, easing toward the
    /// next stage milestone without reaching it. Gives command-granular
    /// smoothness across the long DG2 photo read where the coarse stages sit
    /// still. Monotonic; no-op outside an active read.
    private func creepPassportProgress() {
        guard passportReadProgress > 0, passportReadProgress < 1 else { return }
        let cap = Self.readMilestones.first { $0 > passportReadProgress + 1e-6 } ?? 1.0
        let eased = passportReadProgress + (cap - passportReadProgress) * 0.02
        passportReadProgress = min(cap - 0.004, max(passportReadProgress, eased))
    }

    /// Localised progress copy for the NFC sheet while a passport reads.
    static func passportProgress(_ stage: EPassportReader.Stage) -> String {
        switch stage {
        case .selecting: String(localized: "Connecting to your passport…")
        case .authenticating: String(localized: "Unlocking with your details…")
        case .reading: String(localized: "Reading passport data…")
        case .decoding: String(localized: "Almost done…")
        }
    }

    /// Save a full snapshot of this tap to the scan history. Best-effort — a
    /// corrupt-DB error must never break the scan loop, so failures are dropped.
    /// `recordScan` dedupes exact duplicates and caps the list at the 50 most
    /// recent.
    private func persistScan(
        _ tag: ConnectedTag,
        records: [NDEFRecord],
        transitCard: TransitCard? = nil,
        protection: TagProtection? = nil
    ) {
        guard let library else { return }
        _ = try? library.recordScan(
            chipFamily: tag.chip?.family.shortName ?? (transitCard != nil ? "FeliCa" : "Unknown"),
            uidHex: tag.uid.hexString,
            records: records,
            chipName: tag.chip?.displayName,
            manufacturer: tag.chip?.manufacturer,
            totalBytes: tag.chip?.memoryLayout.byteCount ?? 0,
            capabilitiesRaw: tag.capabilities.rawValue,
            transitCard: transitCard,
            protection: protection
        )
    }

    private func transition(to newPhase: Phase) {
        phase = newPhase
        transitionCount &+= 1
    }

    /// `true` when a protection backend exists for this chip: the single gate
    /// for every protection affordance in the app.
    ///
    /// `protectionStyle` is the whole test, and the `.passwordAuth` check that
    /// used to sit in front of it was not merely redundant but wrong.
    /// `ProtectionStyle.backendStyle` already requires `.passwordAuth` for every
    /// family it answers *except* MIFARE Ultralight C, which authenticates with a
    /// 3DES key and therefore declares `.tripleDESAuth` instead. The two are
    /// kept deliberately distinct (see `TagCapability.tripleDESAuth`). Anding the
    /// capability in here re-excluded exactly the one chip the exception exists
    /// for, so a scanned Ultralight C reported "no protection support": the
    /// editor's Protection card never appeared, the 3DES key sheet behind it was
    /// unreachable, and a read-protected one dead-ended in an error instead of
    /// the unlock prompt.
    static func supportsPasswordProtection(_ tag: ConnectedTag) -> Bool {
        tag.protectionStyle != nil
    }

    /// Read the live protection state, keeping "there is nothing to report" and
    /// "we could not find out" apart. See `protectionReadFailed`.
    ///
    /// A dropped frame no longer costs the user the answer: `ProtectionProbe`
    /// establishes whether the tag actually refused before giving up, and retries
    /// when it did not.
    private func readProtection(from tag: ConnectedTag) async {
        switch await ProtectionProbe.read(from: tag, presence: presence) {
        case .state(let state, let proven):
            detectedProtection = state
            protectionReadFailed = false
            provenReadablePage = proven

        case .refused, .lost:
            detectedProtection = nil
            protectionReadFailed = true
            // No page is proven readable, so the lock read sends no frames at
            // all. A refused protection read means the tag has very likely
            // halted, and a lock frame after that would be shouting at a chip
            // that has stopped listening.
            provenReadablePage = nil
        }
    }

    /// Read the tag's lock bytes.
    ///
    /// Placed after `persistScan` and before `readDiagnostics` on purpose. The
    /// records are already saved by the time this runs, so the worst a refusal
    /// here can cost is the lock verdict and the signature/counter facts, never
    /// the scan itself. It cannot run *after* the diagnostics either: a factory
    /// NTAG21x with `NFC_CNT_EN = 0` NAKs `READ_CNT` routinely, and that NAK
    /// halts the chip for the rest of the activation.
    ///
    /// Addresses no page the protection read has not already had answered, which
    /// is what `provenReadablePage` carries. See `Type2LockDriver.readLockState`.
    private func readLock(from tag: ConnectedTag) async {
        detectedLock = await tag.readLockState(provenReadablePage: provenReadablePage)
    }

    /// Collect the chip's read-only silicon facts. Best-effort and last in the
    /// session, by construction. See `diagnostics`.
    private func readDiagnostics(from tag: ConnectedTag) async {
        let reader = Type2DiagnosticsReader(transceive: { try await tag.transceive($0) })
        diagnostics = await reader.read(chip: tag.chip)
    }

    /// What a refused NDEF read establishes about a tag's NDEF structure, given
    /// the Capability Container page **as the tag served it**.
    ///
    /// Two gates, and they answer different questions.
    ///
    /// The chip gate is narrow on purpose. Only Type-2 keeps its CC in a page we
    /// know the factory bytes for, and only then can the app offer a format that
    /// is safe to perform: page 3 is OTP, so suggesting one at a chip whose CC
    /// we'd have to guess is worse than saying nothing. DESFire and FeliCa reach
    /// the same catch and must not be labelled anything: they have no NDEF area
    /// at all, which no amount of formatting changes.
    ///
    /// The bytes gate is the one this used to be missing. Without page 3 there
    /// is no reading, and the honest answer is `.unknown` rather than the
    /// likelier of the two guesses.
    static func formatState(for tag: ConnectedTag, capabilityContainer page3: Data?) -> TagFormatState {
        guard let chip = tag.chip, case .type2 = chip.family,
              chip.capabilities.contains(.formatCC), chip.factoryCC != nil
        else { return .unknown }
        return .afterRefusedNDEFRead(capabilityContainer: page3)
    }

    /// Read failures that, on a password-capable Type-2 chip, most plausibly
    /// indicate the tag is locked rather than genuinely lost: a NAK'd protected
    /// read surfaces as `.tagLost`, an authenticated-read path as `.authFailed`.
    static func isLikelyProtectionFailure(_ error: TagError) -> Bool {
        switch error.kind {
        case .authFailed, .tagLost: true
        default: false
        }
    }

    /// Whether this session's own pre-read already disproved gating, making the
    /// unlock prompt a claim about the tag that nothing read supports.
    ///
    /// Measured 2026-09-10 (`docs/internal/bench-traces/2026-09-10-t2-1-ntag213.log`,
    /// 11:36:24). An unprotected NTAG213 was lifted twelve milliseconds into the
    /// NDEF read. The `30 03` had already come back with a real Capability
    /// Container and a complete TLV chain, and the app still told the owner the
    /// tag needed a password. `AUTH0` read `FF` sixty seconds earlier and again
    /// afterwards.
    ///
    /// Narrow on purpose, and it only ever narrows `.tagLost`:
    ///
    ///  * `.authFailed` is a **stated** refusal. The chip said no, and the prompt
    ///    is the correct answer to that whatever the pre-read saw. It is also the
    ///    kind `TagError.readProtected` carries, which is the read-protected
    ///    tag's only route back. Bench fix plan section 5 item 11 is the mirror
    ///    of this rule and both directions matter.
    ///  * The disproof needs the whole chain, terminator included, inside pages
    ///    proven not to have wrapped. A longer message whose terminator sits past
    ///    page 6 still gets the prompt, because that read may genuinely have been
    ///    cut short by a gate further up. Blank and short-message tags are what
    ///    this covers, and they are what the capture showed.
    static func prereadDisprovesGating(_ preread: TagPreread, for error: TagError) -> Bool {
        guard error.kind == .tagLost else { return false }
        return preread.provesTheNDEFChainWasNotGated
    }
}
