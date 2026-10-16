#if canImport(CoreNFC) && os(iOS)
import CoreNFC
import Foundation
import HexNFCRecords

/// Production `TagSession` backed by CoreNFC.
///
/// This is the only file in the entire codebase that imports CoreNFC. The
/// invariant in `CLAUDE.md` is checked by a grep in CI.
///
/// The wiring is intentionally minimal: `start(alert:)` opens an
/// `NFCTagReaderSession` polling for `.iso14443` + `.iso15693` + `.iso18092`.
/// On first tag detection the session calls `tagReaderSession(_:didDetect:)`,
/// the tag is connected, NDEF status is queried, and the call returns a
/// `CoreNFCConnectedTag` adapter.
public final class CoreNFCSession: NSObject, TagSession, @unchecked Sendable {
    /// Hand the tag up **without** running identification.
    ///
    /// Identification costs a `GET_VERSION`, and a chip that doesn't implement
    /// it NAKs — which returns a Type-2 tag to HALT and makes every later
    /// command in the session fail. `restartPolling()` recovers that, but this
    /// is the escape hatch that cannot hit the problem at all, because the
    /// offending command is never sent. `chip` is `nil`, so callers get the
    /// generic command set and no page map is assumed.
    public var skipIdentification = false

    override public init() {}

    public init(skipIdentification: Bool) {
        self.skipIdentification = skipIdentification
        super.init()
    }

    private var session: NFCTagReaderSession?
    private var continuation: CheckedContinuation<ConnectedTag, Error>?
    /// Fires when CoreNFC reports the session has actually torn down, so
    /// `invalidate(error:)` can await real teardown instead of guessing. Set and
    /// resumed only on `queue`.
    private var invalidationContinuation: CheckedContinuation<Void, Never>?
    /// Set once `didInvalidateWithError` has fired (normal end, tag lost, or user
    /// cancel). Lets a later `invalidate()` return immediately — the teardown
    /// callback already happened, so there's nothing left to await.
    private var didTearDown = false
    /// Whether `start` got as far as beginning a reader session, so
    /// `awaitTeardown` can tell "never began" from "not torn down yet".
    private var hasBegun = false
    /// When `invalidate(error:)` actually ended the reader session, so the
    /// teardown report can say how long it took.
    private var invalidatedAt: ContinuousClock.Instant?
    /// Callers of `awaitTeardown`, keyed so a timeout can resume its own entry.
    /// Touched only on `queue`.
    private var teardownWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// Set the first time `didDetect` fires, and never cleared: a re-poll after
    /// a refused probe detects the same tag again, and it had already answered
    /// frames the first time. An invalidation that arrives while this is still
    /// false ended with nothing ever in the field, which is what
    /// `TagError.endedBeforeAnyTag` reports. Touched only on `queue`.
    private var detectedATag = false
    private var queue = DispatchQueue(label: "pro.hex.nfc.session")

    public func start(alert: String) async throws -> ConnectedTag {
        // Honour the iOS inter-session cooldown before asking for a new session.
        // `invalidate` already waits for real teardown; this waits out the opaque
        // window *after* it, which has no event to observe. Anchored to the last
        // recorded teardown, so it's free on a first scan and free again on any
        // flow with a human step in it — it only bites on a genuine back-to-back
        // re-tap (scan retry, unlock, passport re-tap, write retry), which is
        // exactly where iOS otherwise drops the tag or returns error 202.
        //
        // Placed here rather than at the call sites so a flow added later cannot
        // forget it. The caller has already shown its "hold the tag" state by
        // now, so the wait reads as the poll starting, not as a stall.
        await NFCSessionClock.awaitCooldown()
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            guard NFCTagReaderSession.readingAvailable else {
                continuation.resume(throwing: TagError(
                    kind: .sessionUnavailable,
                    userMessage: "This device does not support NFC.",
                    diagnostics: "NFCTagReaderSession.readingAvailable == false"
                ))
                return
            }
            // .iso18092 (FeliCa) is only added when the app actually carries the
            // com.apple.developer.nfc.readersession.felica.systemcodes Info.plist
            // key (with a matching App ID registration in the portal). Polling a
            // format the app isn't entitled to makes CoreNFC fail the *entire*
            // session with securityViolation at begin() — which would break
            // ordinary ISO 14443/15693 scanning too. Gating on the declared key
            // means FeliCa self-activates once the entitlement is added, and
            // never regresses other scanning while it's absent. See
            // docs/internal/xcode-setup.md §3.
            var pollingOptions: NFCTagReaderSession.PollingOption = [.iso14443, .iso15693]
            if Self.feliCaSystemCodesDeclared {
                pollingOptions.insert(.iso18092)
            }
            let session = NFCTagReaderSession(
                pollingOption: pollingOptions,
                delegate: self,
                queue: queue
            )
            session?.alertMessage = alert
            self.session = session
            self.hasBegun = session != nil
            session?.begin()
        }
    }

    public func updateAlert(_ alert: String) async {
        session?.alertMessage = alert
    }

    /// Ends the session and returns **once it has fully torn down**. CoreNFC calls
    /// `didInvalidateWithError` when the reader session and its RF field are
    /// actually released; awaiting that here means the *next* session never races a
    /// half-torn-down predecessor (which otherwise surfaces as a dropped tag or
    /// error 202). Returns immediately if the session was already ended (by iOS, a
    /// lost tag, or a prior call). Idempotent. A bounded timeout guards against a
    /// missing callback so this can never hang.
    public func invalidate(error: String?) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                // Already torn down (abnormal end / tag lost / user cancel) or
                // never started — the callback already fired; nothing to await.
                guard self.session != nil, !self.didTearDown else {
                    self.session = nil
                    continuation.resume()
                    return
                }
                self.invalidationContinuation = continuation
                self.invalidatedAt = .now
                if let error {
                    self.session?.invalidate(errorMessage: error)
                } else {
                    self.session?.invalidate()
                }
                self.session = nil
                // Safety net: `didInvalidateWithError` is contractually guaranteed
                // after `invalidate()`, but never hang if it somehow doesn't fire.
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    self.finishInvalidation()
                }
            }
        }
    }

    /// Waits for `didInvalidateWithError` itself, which `invalidate(error:)` may
    /// have stopped waiting for. After an app-side invalidate CoreNFC reports the
    /// teardown only once its sheet is gone, about 2.7 s later on 2026-09-19,
    /// which is past the 2 s safety net above.
    public func awaitTeardown(timeout: Duration) async {
        let id = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                guard self.hasBegun, !self.didTearDown else {
                    continuation.resume()
                    return
                }
                self.teardownWaiters[id] = continuation
                Task {
                    try? await Task.sleep(for: timeout)
                    self.queue.async { self.teardownWaiters.removeValue(forKey: id)?.resume() }
                }
            }
        }
    }

    /// Resume the pending invalidation continuation exactly once. The teardown
    /// callback and the timeout both funnel here (via `queue`); the nil-check makes
    /// it single-shot.
    private func finishInvalidation() {
        queue.async {
            guard let continuation = self.invalidationContinuation else { return }
            self.invalidationContinuation = nil
            continuation.resume()
        }
    }

    /// What the next `didDetect` should do, set when a probe did not land and
    /// the polling loop was restarted. `nil` means an ordinary first pass.
    private var pendingStep: Type2ProbeNextStep?
    /// How many passes of each kind this tap has spent. The ceiling is
    /// `Type2ProbePolicy`'s, not this file's, so it can be tested on macOS.
    private var probeAttempts = Type2ProbePolicy.Attempts()
    /// What an unlanded probe managed to decode, carried across the re-poll so
    /// the second pass doesn't have to ask the chip again.
    private var carriedReport: UnidentifiedChipReport?
    /// Which tag the counters above are about. A re-poll can surface a
    /// different tag (a stack of blanks is easy to mix up), and a budget spent
    /// on one tag must not be charged to another.
    private var probedUID: Data?

    fileprivate func resume(with tag: ConnectedTag) {
        continuation?.resume(returning: tag)
        continuation = nil
    }

    fileprivate func resume(throwing error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    /// Whether the app bundle declares the FeliCa system-codes key with at least
    /// one entry. CoreNFC requires this (plus portal registration) before
    /// `.iso18092` may be polled; we read it from the bundle so polling can be
    /// gated without a compile-time flag.
    static let feliCaSystemCodesDeclared: Bool = {
        let key = "com.apple.developer.nfc.readersession.felica.systemcodes"
        guard let codes = Bundle.main.object(forInfoDictionaryKey: key) as? [String] else {
            return false
        }
        return !codes.isEmpty
    }()
}

// MARK: - NFCTagReaderSessionDelegate

extension CoreNFCSession: NFCTagReaderSessionDelegate {
    public func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
        // Intentionally empty — start() returns when a tag is detected, not
        // when the session becomes active.
    }

    public func tagReaderSession(
        _ session: NFCTagReaderSession,
        didInvalidateWithError error: Error
    ) {
        var translated = Self.translate(error)
        // Whether a tag was ever in the field is known here and nowhere above
        // this file. A cancel or timeout that ends a session which detected
        // nothing is the user backing out of an empty sheet; the same kinds
        // arriving mid-identification are about a tag that has already answered
        // frames, and they keep the report they have always had.
        if !detectedATag {
            translated = translated.endingBeforeAnyTag()
        }
        // A *pre-connect* invalidation is the interesting case: if the
        // continuation is already gone we delivered a tag and this is normal
        // teardown. Tracing the still-pending case surfaces failures that never
        // reach identification — a session that dies before any tag appears, or
        // a tag iOS detects and then drops. User-cancel is benign, not a fault.
        if continuation != nil, translated.kind != .sessionCancelled {
            NFCTrace.shared.failure(translated.diagnostics, label: "session")
        }
        resume(throwing: translated)
        // Teardown is now complete — let any awaiting `invalidate(error:)` return,
        // and record it so a later `invalidate()` no-ops instead of awaiting a
        // callback that already fired. (Delivered on `queue`, so this is ordered
        // with `invalidate`/`finishInvalidation`.)
        didTearDown = true
        invalidationContinuation?.resume()
        invalidationContinuation = nil
        // Start the inter-session cooldown from the moment teardown really
        // completed — including the teardowns nobody awaited (a lost tag, a user
        // cancel, a fire-and-forget `reset()`), which are precisely the ones a
        // caller-side sleep would have missed.
        NFCSessionClock.recordTeardown()
        // How long the report took after our own invalidate. Nothing else
        // measures it, and both `invalidate`'s safety net and the write sheet's
        // "Locked in" hold are sized against it.
        if let invalidatedAt {
            let elapsed = invalidatedAt.duration(to: .now).components
            let milliseconds = elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000
            NFCTrace.shared.note("teardown reported \(milliseconds) ms after invalidate", label: "session")
        }
        let waiters = teardownWaiters.values
        teardownWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    public func tagReaderSession(
        _ session: NFCTagReaderSession,
        didDetect tags: [NFCTag]
    ) {
        // Before the guard, so even an empty delivery counts: nothing may be
        // reported as "no tag" once CoreNFC has said it saw one.
        detectedATag = true
        guard let first = tags.first else {
            NFCTrace.shared.failure("didDetect delivered no tags", label: "detect")
            session.invalidate(errorMessage: "No tag detected")
            return
        }
        // Trace the detected tag *before* connecting. This is the earliest
        // observable point and the only one reached when a tag is detected but
        // then refuses to connect — e.g. MIFARE Classic, which iOS surfaces as
        // miFare/family=unknown and cannot authenticate (no CRYPTO1 exposed).
        NFCTrace.shared.note(Self.detectionSummary(first), label: "detect")
        session.connect(to: first) { [weak self] error in
            guard let self else { return }
            if let error {
                NFCTrace.shared.failure(error.localizedDescription, label: "connect")
                resume(throwing: Self.connectError(for: first, underlying: error))
                return
            }
            NFCTrace.shared.note("connected", label: "connect")
            // Second pass after a refused probe: the chip has already told us it
            // doesn't answer GET_VERSION, so re-running identification would
            // just HALT it again. Hand up the freshly-polled tag with whatever
            // the first pass decoded.
            if skipIdentification {
                NFCTrace.shared.note("identification skipped by request", label: "connect")
                resume(with: CoreNFCConnectedTag(tag: first, chip: nil, unidentifiedReport: nil))
                return
            }
            // A re-poll can surface a tag other than the one whose budget we
            // are holding. Start that one over rather than spending the first
            // tag's remaining attempts on it.
            if let probedUID, case .miFare(let mifare) = first, mifare.identifier != probedUID {
                NFCTrace.shared.note("re-polled a different tag: identifying from the top", label: "connect")
                pendingStep = nil
                probeAttempts = Type2ProbePolicy.Attempts()
                carriedReport = nil
                self.probedUID = nil
            }
            if pendingStep == .repollAndDecodeShape {
                // The tag is awake again. Do NOT re-send GET_VERSION (that is
                // what halted it), but a chip with no GET_VERSION is not
                // necessarily unidentifiable — MIFARE Ultralight C is exactly
                // that case, and can be pinned from its memory shape with reads
                // it always answers. This is the only place that probe can run:
                // before the re-poll the tag is halted, and after handing up a
                // `chip: nil` tag the caller has already lost the layout.
                //
                // Reached only from `.chipRefused`. That is what keeps an
                // NTAG21x out of a decoder that can only answer "Ultralight C":
                // an NTAG21x answers `60`, so it never earns this step.
                NFCTrace.shared.note("re-polled: identifying without GET_VERSION", label: "connect")
                probeAttempts.shape += 1
                guard case .miFare(let mifare) = first else {
                    resume(with: CoreNFCConnectedTag(
                        tag: first, chip: nil, unidentifiedReport: carriedReport
                    ))
                    return
                }
                Task {
                    let identified = await MiFareTagIdentifier().identifyWithoutGetVersion(
                        mifare, report: self.carriedReport
                    )
                    self.resume(with: CoreNFCConnectedTag(
                        tag: first,
                        chip: identified.profile,
                        unidentifiedReport: identified.profile == nil ? identified.report : nil
                    ))
                }
                return
            }
            if pendingStep == .repollAndRetryGetVersion {
                // The chip refused nothing; the send did not complete. The tag
                // is freshly selected now, so ask it again exactly as the first
                // pass did. This is the path an NTAG213 took on 2026-09-21,
                // where the old code sent it to the shape decoder instead and
                // the removal was refused as "This tag does not support that
                // operation." with no protection frame on the wire.
                NFCTrace.shared.note("re-polled: asking for GET_VERSION again", label: "connect")
            }
            // Identify the chip (GET_VERSION on NTAG/Ultralight, mifareFamily
            // on DESFire, etc.) before handing the tag up, so callers receive a
            // fully-identified ConnectedTag. The family-specific probes live in
            // Identification/ — see TagIdentifier — not in this session file.
            Task {
                let identified = await TagIdentifier().identify(first)
                self.probeAttempts.getVersion += 1
                let step = Type2ProbePolicy.nextStep(
                    after: identified.verdict, attempts: self.probeAttempts
                )
                guard step != .handUp else {
                    self.resume(with: CoreNFCConnectedTag(
                        tag: first,
                        chip: identified.profile,
                        unidentifiedReport: identified.report
                    ))
                    return
                }
                // The probe was refused, which returns a Type-2 tag to HALT: it
                // answers nothing more on this activation, so the caller gets
                // "tag connection lost" for even a READ of page 0.
                //
                // `connect(to:)` does NOT recover it — verified on hardware
                // 2026-08-06: the re-select reported success and the very next
                // READ still failed. It rebinds the existing handle rather than
                // re-activating the chip. Restarting the polling loop does work,
                // because polling issues WUPA, and WUPA (unlike REQA) wakes a
                // HALTed tag. `didDetect` fires again with a fresh tag, and the
                // branch above skips the probe that caused this.
                //
                // Without this, every chip that lacks GET_VERSION — original
                // MIFARE Ultralight, Ultralight C, NTAG203, EM — is unusable
                // through the app, not merely unidentified.
                //
                // The same restart serves a transport failure, where the tag is
                // not halted at all and the handle is simply dead. WUPA gets us
                // a live one either way; what differs is what the next pass
                // sends, which is `pendingStep`'s job.
                NFCTrace.shared.note(
                    identified.verdict == .chipRefused
                        ? "probe refused: restarting polling"
                        : "probe lost at the transport: restarting polling",
                    label: "connect"
                )
                self.pendingStep = step
                self.carriedReport = identified.report
                if case .miFare(let mifare) = first {
                    self.probedUID = mifare.identifier
                }
                session.restartPolling()
            }
        }
    }

    private static func translate(_ error: Error) -> TagError {
        let nsError = error as NSError
        if nsError.domain == NFCErrorDomain {
            switch NFCReaderError.Code(rawValue: nsError.code) {
            case .readerSessionInvalidationErrorUserCanceled:
                return TagError.sessionCancelled(diagnostics: nsError.localizedDescription)

            case .readerSessionInvalidationErrorSessionTimeout:
                return TagError.sessionTimeout(diagnostics: nsError.localizedDescription)

            case .readerTransceiveErrorTagConnectionLost,
                 .readerTransceiveErrorTagResponseError:
                return TagError.tagLost(diagnostics: nsError.localizedDescription)

            case .readerErrorSecurityViolation:
                // Reached only if the FeliCa key is declared but the App ID
                // isn't registered for it in the portal (see xcode-setup.md §3).
                return TagError(
                    kind: .sessionUnavailable,
                    userMessage: "This build isn't authorised for that tag type yet.",
                    diagnostics: "securityViolation: felica.systemcodes declared but "
                        + "App ID not registered? \(nsError.localizedDescription)"
                )

            default:
                return TagError.protocolError(
                    "NFC error \(nsError.code)",
                    diagnostics: nsError.localizedDescription
                )
            }
        }
        return TagError.unexpected("\(error)")
    }

    /// One-line summary of a freshly-detected tag for the trace — the earliest
    /// fingerprint, logged before connect so it survives a connect failure.
    private static func detectionSummary(_ tag: NFCTag) -> String {
        switch tag {
        case .miFare(let mifare):
            return "miFare family=\(MiFareTagIdentifier.familyName(mifare.mifareFamily)) "
                + "uid=\(mifare.identifier.hexString)"

        case .iso15693(let iso):
            return "iso15693 uid=\(iso.identifier.hexString)"

        case .feliCa(let felica):
            return "feliCa idm=\(felica.currentIDm.hexString) "
                + "system=\(felica.currentSystemCode.hexString)"

        case .iso7816(let iso):
            return "iso7816 uid=\(iso.identifier.hexString)"

        @unknown default:
            return "unknown CoreNFC tag family"
        }
    }

    /// Map a CoreNFC `connect` failure to a `TagError`. A connect failure on a
    /// miFare tag whose family is `.unknown` is the signature of MIFARE Classic:
    /// iOS detects it but exposes no CRYPTO1 sector authentication, so an app
    /// can read the UID but never the encrypted data. Say so honestly — and via
    /// `.protocolError`, not `.capabilityUnsupported(.ndefRead)`, so the scan
    /// flow surfaces the explanation instead of silently reporting zero records.
    private static func connectError(for tag: NFCTag, underlying: Error) -> TagError {
        if case .miFare(let mifare) = tag, mifare.mifareFamily == .unknown {
            return TagError(
                kind: .protocolError,
                userMessage: "This looks like a MIFARE Classic tag. iPhone can detect it but can't read its encrypted memory. IOS doesn't expose the MIFARE Classic keys any app would need.",
                diagnostics: "connect failed on miFare/family=unknown "
                    + "(MIFARE Classic CRYPTO1 not available on iOS): \(underlying.localizedDescription)"
            )
        }
        return TagError.protocolError("connect failed", diagnostics: "\(underlying)")
    }
}

// MARK: - CoreNFCConnectedTag

/// Adapter that lets every CoreNFC tag flavour (`.miFare`, `.iso15693`,
/// `.iso7816`, `.felica`) present the same `ConnectedTag` surface.
public final class CoreNFCConnectedTag: ConnectedTag, @unchecked Sendable {
    public let nfcTag: NFCTag
    public let uid: Data
    public let chip: ChipProfile?
    public let unidentifiedReport: UnidentifiedChipReport?
    public let capabilities: TagCapability

    /// Set once a `PWD_AUTH` has succeeded this session. While authenticated,
    /// Type-2 NDEF reads go through raw page commands rather than the
    /// high-level CoreNFC NDEF path, which doesn't carry the authentication.
    ///
    /// **Stored here on purpose.** `ConnectedTag` gives `type2Session` a default
    /// that vends a throwaway holder, for conformers with no Type-2 credential
    /// path, and this tag used to take it: the three `isAuthenticated = true`
    /// writes in `TagSession` each landed on an instance that was discarded on
    /// the next line, so a read-protected tag this session had unlocked still
    /// took the high-level read path and nfcd answered it with the gate still
    /// shut. That was invisible to the suite, because everything in this file is
    /// `#if os(iOS)` and never compiles on the test host.
    public let type2Session = Type2SessionHolder()

    /// Live NTAG424 EV2 session (Type-4). Populated by `authenticate(.type4)` and
    /// consumed by `writeNDEF`/`readNDEF` so a protected 424's NDEF I/O runs
    /// inside secure messaging: the Type-4 analogue of `type2Session`.
    public let ev2Session = EV2SessionHolder()
    public let ultralightCSession = UltralightCSessionHolder()

    public init(tag: NFCTag, chip: ChipProfile? = nil, unidentifiedReport: UnidentifiedChipReport? = nil) {
        nfcTag = tag
        self.unidentifiedReport = unidentifiedReport
        let identifier: Data = switch tag {
        case .miFare(let mifare):
            mifare.identifier

        case .iso15693(let iso):
            iso.identifier

        case .iso7816(let iso):
            iso.identifier

        case .feliCa(let felica):
            felica.currentIDm

        @unknown default:
            Data()
        }
        uid = identifier
        self.chip = chip
        // Capabilities come from the identified profile. An unidentified tag
        // falls back to NDEF read/write + raw, which every supported family can
        // at least attempt.
        capabilities = chip?.capabilities ?? [.ndefRead, .ndefWrite, .rawTransceive]
    }

    /// CoreNFC reports a *formatted-but-empty* NDEF tag — a factory-fresh
    /// NTAG213, a just-erased ICODE, any tag whose NDEF TLV is present but holds
    /// zero records — as `ndefReaderSessionErrorZeroLengthMessage` (NFCError
    /// 403, "NDEF tag does not contain any NDEF message"). That is a successful
    /// read of **zero records**, not a failure: returning empty `Data` lets a
    /// blank tag scan cleanly, an erase verify, and an empty write round-trip.
    /// The chip simulators already model this by returning empty `Data` for a
    /// tag with no NDEF TLV (see `NTAG21xSimulator.readNDEF`) — this keeps the
    /// real CoreNFC session in step with that contract across *every* family.
    private static func isZeroLengthNDEF(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NFCErrorDomain
            && nsError.code == NFCReaderError.Code.ndefReaderSessionErrorZeroLengthMessage.rawValue
    }

    /// An *unformatted* tag — one with no NDEF Capability Container at all (a
    /// factory ICODE SLIX/SLIX2, a blank Type-5 / Type-4 chip) — surfaces not as
    /// the zero-length code above but as a transceive `tagResponseError`
    /// (NFCError 102) whose description reads "Tag Not NDEF formatted". The tag
    /// answered fine; it simply carries no NDEF structure. On the high-level NDEF
    /// path that is a successful read of **zero records**, exactly like a blank
    /// NTAG (which the Type-2 path already reports as zero records via
    /// `queryNDEFStatus == .notSupported`). Genuine tag-loss surfaces instead as
    /// `tagConnectionLost` / `retryExceeded` / `tagNotConnected`, which stay hard
    /// errors. The chip simulators model the same contract — `Iso15693Simulator`
    /// returns empty `Data` for a tag with no CC magic byte (see its `readNDEF`).
    ///
    /// **Only honoured on the non-Type-2 `readNDEFViaNDEFTag` path.** On a miFare
    /// tag a NAK'd read *also* arrives as `tagResponseError`, and there it must
    /// stay a failure so a read-protected tag still routes to the unlock prompt
    /// (see `ScanFlowModel.isLikelyProtectionFailure`). ISO 15693 / 7816 / FeliCa
    /// have no such Type-2 password path, so the benign reading is safe there.
    private static func isUnformattedNDEF(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NFCErrorDomain
            && nsError.code == NFCReaderError.Code.readerTransceiveErrorTagResponseError.rawValue
    }

    public func readNDEF() async throws -> Data {
        // A protected NTAG424 we've authenticated past reads via the live EV2
        // session (secure messaging), not the high-level NDEF path (which can't
        // carry the session). Only engaged once a 424 session exists.
        if chip?.id == .ntag424DNA, let driver = ev2Session.driver, driver.isAuthenticated {
            return try await driver.readNDEFFile()
        }
        // Once authenticated, read NDEF via raw page commands — the high-level
        // path can't read a read-protected tag we've unlocked, and mixing it with
        // the raw auth state risks a stack error. Gated on a page-based NDEF range
        // (same invariant the write path enforces): only Type-2 has one, and only
        // Type-2 authenticates with `PWD_AUTH` today — but stating it here keeps
        // a future .miFare Type-4 that authenticates from mis-routing to the page
        // reader (which would throw "no NDEF range").
        if case .miFare = nfcTag, type2Session.isAuthenticated, chip?.memoryLayout.ndefRange != nil {
            return try await readNDEFViaPages()
        }
        guard case .miFare(let mifare) = nfcTag else {
            // Fallback for non-Type-2 tags — let CoreNFC's NDEF query do it.
            return try await readNDEFViaNDEFTag()
        }
        return try await withCheckedThrowingContinuation { continuation in
            // The high-level path runs inside nfcd, so none of its frames reach
            // `transceive` and none of them are traced. A capture of a scan that
            // failed here showed the session identify the tag and then go
            // silent, with nothing to say which read failed or why. Note the
            // outcome so the next one is readable.
            //
            // CoreNFC's tag types carry no Sendable annotations, yet Swift
            // imports their completion handlers as `@Sendable` (the methods are
            // async-eligible), so reaching the tag again from inside one is
            // flagged. The two calls are strictly
            // sequential: `readNDEF` is only issued once `queryNDEFStatus` has
            // answered.
            nonisolated(unsafe) let mifare = mifare
            NFCTrace.shared.note("queryNDEFStatus", label: "NDEF read")
            mifare.queryNDEFStatus { status, _, error in
                if let error {
                    NFCTrace.shared.failure("queryNDEFStatus: \(error.localizedDescription)", label: "NDEF read")
                    // `.tagLost`, not `.protocolError`. A Type-2 tag that will
                    // not answer the CC probe has stopped answering, and the two
                    // ways that happens are a tag pulled out of the field and a
                    // tag halted by an earlier refusal. Both are recoverable by
                    // the caller, and one of them is a password-protected tag
                    // the user can unlock.
                    //
                    // The old kind was a dead end by construction:
                    // `ScanFlowModel.isLikelyProtectionFailure` matches
                    // `.authFailed` and `.tagLost`, so a `.protocolError` never
                    // reached the unlock prompt. A read-protected NTAG213 landed
                    // on a generic error with no way forward.
                    continuation.resume(throwing: TagError.tagLost(
                        diagnostics: "queryNDEFStatus failed: \(error)"
                    ))
                    return
                }
                guard status != .notSupported else {
                    // Says what nfcd answered, and nothing about why. The old
                    // note read "(no Capability Container)", which is an
                    // inference and, on a real NTAG213 seen on 2026-09-09, a
                    // wrong one: its Capability Container was byte-perfect and
                    // the fault was one corrupt byte of the data area. That
                    // wording is where the scan's "unformatted" verdict came
                    // from. See `TagFormatState`.
                    NFCTrace.shared.note("status=notSupported (no NDEF this phone can read)", label: "NDEF read")
                    continuation.resume(throwing: TagError.capabilityUnsupported(.ndefRead))
                    return
                }
                mifare.readNDEF { message, error in
                    if let error {
                        // A blank-but-formatted tag is zero records, not a loss.
                        if CoreNFCConnectedTag.isZeroLengthNDEF(error) {
                            NFCTrace.shared.note("zero-length message (blank tag)", label: "NDEF read")
                            continuation.resume(returning: Data())
                            return
                        }
                        NFCTrace.shared.failure("readNDEF: \(error.localizedDescription)", label: "NDEF read")
                        continuation.resume(throwing: TagError.tagLost(diagnostics: "\(error)"))
                        return
                    }
                    let payloads = (message?.records ?? []).map { CoreNFCSession.payload(from: $0) }
                    let data = NDEFCodec.encodePayloads(payloads)
                    NFCTrace.shared.note("\(payloads.count) record(s), \(data.count) B", label: "NDEF read")
                    continuation.resume(returning: data)
                }
            }
        }
    }

    private func readNDEFViaNDEFTag() async throws -> Data {
        // ISO 15693 / FeliCa / ISO 7816 also conform to NFCNDEFTag.
        let ndefTag: NFCNDEFTag? = switch nfcTag {
        case .iso15693(let iso): iso
        case .iso7816(let iso): iso
        case .feliCa(let felica): felica
        default: nil
        }
        guard let tag = ndefTag else { throw TagError.capabilityUnsupported(.ndefRead) }
        return try await withCheckedThrowingContinuation { continuation in
            tag.readNDEF { message, error in
                if let error {
                    // Same as the Type-2 path: a blank-but-formatted ICODE /
                    // Type-4 reports a zero-length message — zero records, not a
                    // failure. An *unformatted* tag (no Capability Container, e.g.
                    // a factory ICODE SLIX2) instead reports "Tag Not NDEF
                    // formatted" (tagResponseError); on this non-Type-2 path that
                    // is also a clean read of zero records, so the scan shows the
                    // tag rather than dead-ending on an error.
                    if CoreNFCConnectedTag.isZeroLengthNDEF(error)
                        || CoreNFCConnectedTag.isUnformattedNDEF(error)
                    {
                        continuation.resume(returning: Data())
                        return
                    }
                    continuation.resume(throwing: TagError.tagLost(diagnostics: "\(error)"))
                    return
                }
                let payloads = (message?.records ?? []).map { CoreNFCSession.payload(from: $0) }
                let data = NDEFCodec.encodePayloads(payloads)
                continuation.resume(returning: data)
            }
        }
    }

    public func writeNDEF(_ records: [NDEFRecord]) async throws {
        // A protected NTAG424 we've authenticated past is written via the live
        // EV2 session (secure messaging) — the high-level NDEF write can't carry
        // it. Only engaged once a 424 session exists.
        if chip?.id == .ntag424DNA, let driver = ev2Session.driver, driver.isAuthenticated {
            try await driver.writeNDEFFile(records)
            return
        }
        // Type-2 (NTAG21x / UL EV1): ALWAYS write via raw page WRITEs, never nfcd's
        // high-level NDEF write. That path re-runs its own read-modify-write
        // sequence which dead-ends with "Stack Error / Connection Closed" on two
        // real, common cases: (a) tags we've authenticated past (the PWD_AUTH state
        // isn't carried), and (b) pre-formatted tags carrying a Lock Control TLV.
        // Worse, on failure it CLOSES the tag connection, so it can't even serve as
        // a first attempt with a raw fallback — the fallback would hit a dead
        // connection. Our page writer speaks WRITE (0xA2) on the same transport the
        // auth lives on and handles both the authenticated and plain cases; an empty
        // `records` writes an empty NDEF TLV envelope (a blank, i.e. erase). Reads
        // still use the high-level path (it works; only writes are affected).
        //
        // Gate on a page-based NDEF range: NTAG424 DNA *also* arrives on the
        // .miFare transport but is Type-4 (no page ndefRange), so it must NOT take
        // the page path — its plain NDEF writes go through the high-level path
        // below (nfcd does the ISO 7816 SELECT + UPDATE BINARY), like the other
        // non-Type-2 families. (An authenticated 424 was already handled above.)
        if case .miFare = nfcTag, chip?.memoryLayout.ndefRange != nil {
            try await writeNDEFViaPages(records)
            return
        }
        // Other families (ISO 15693 / SLIX, ISO 7816, FeliCa) and Type-4 on the
        // .miFare transport (NTAG424 plain NDEF) keep the high-level NDEF write,
        // with the read path's empty-write forgiveness for unformatted tags (e.g.
        // erasing a factory ICODE SLIX2 reports "not NDEF formatted").
        let payloads = try records.map(NDEFCodec.payload(from:))
        let nfcRecords = payloads.map(CoreNFCSession.nfcPayload(from:))
        let message = NFCNDEFMessage(records: nfcRecords)
        let target: NFCNDEFTag? = switch nfcTag {
        case .iso15693(let iso): iso
        case .iso7816(let iso): iso
        case .feliCa(let felica): felica
        case .miFare(let mifare): mifare
        @unknown default: nil
        }
        guard let tag = target else { throw TagError.capabilityUnsupported(.ndefWrite) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            tag.writeNDEF(message) { error in
                if let error {
                    // An *empty* write to an unformatted tag (no CC) is a semantic
                    // no-op — mirror the read path's forgiveness instead of
                    // dead-ending on tagLost. A content write still fails loudly.
                    if records.isEmpty, CoreNFCConnectedTag.isUnformattedNDEF(error) {
                        continuation.resume()
                        return
                    }
                    continuation.resume(throwing: TagError.tagLost(diagnostics: "\(error)"))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    public func transceive(_ command: RawCommand) async throws -> Data {
        // Frames carrying credential material are masked in the trace (opcode
        // kept, payload redacted) across all three families.
        let secret = isSecretFrame(command.bytes)
        NFCTrace.shared.tx(command.name ?? "transceive", command.bytes, secret: secret)
        do {
            let response = try await transceiveRaw(command)
            NFCTrace.shared.rx(
                command.name ?? "transceive", response,
                secret: secret && Self.responseCarriesSecret(command.bytes)
            )
            return response
        } catch let error as TagError {
            NFCTrace.shared.failure(error.diagnostics, label: command.name ?? "transceive")
            throw error
        }
    }

    /// Whether a frame carries credential material that must be redacted in
    /// the trace. The rule itself lives in `NFCTraceRedaction`, which is not
    /// `#if os(iOS)` and therefore has tests: `swift test` on the macOS host
    /// skips this entire file, so while the rule lived here nothing in CI ever
    /// evaluated it. A masking rule for secrets is a poor thing to take on
    /// faith.
    private func isSecretFrame(_ bytes: Data) -> Bool {
        NFCTraceRedaction.isSecretFrame(bytes, chip: chip)
    }

    /// Whether the **response** to a secret-carrying command is itself secret.
    ///
    /// Redaction is per-direction because the two are not the same question. A
    /// command may carry a password while its answer is a bare status byte, and
    /// masking that answer throws away the only diagnostic there is.
    ///
    /// That cost a live debugging cycle on 2026-08-07: a SLIX2 `SET_PASSWORD`
    /// was refused, and the trace showed `‹redacted 2 B›` where `01 <errorCode>`
    /// would have named the reason. ISO 15693 password responses are a status
    /// flag plus an error code and never contain key material.
    ///
    /// Kept masked: `PWD_AUTH` (answers with the secret PACK), the Ultralight C
    /// and NTAG424 authentication legs (cryptograms computed under the key, i.e.
    /// offline-attack input), and the eMRTD access-control responses.
    private static func responseCarriesSecret(_ command: Data) -> Bool {
        guard let first = command.first else { return false }
        if first == 0x1B {
            return true
        } // PWD_AUTH → PACK
        if first == UltralightCProtectionDriver.authenticateCommand {
            return true
        }
        if first == UltralightCProtectionDriver.continueCommand {
            return true
        }
        // A Type-2 WRITE is answered with a bare ACK/NAK whatever it carried.
        if first == 0xA2 {
            return false
        }
        guard command.count >= 2 else { return true }
        let second = command[command.startIndex + 1]
        // ISO 15693 SLIX password commands: `00`, or `01 <errorCode>`.
        if [0xB3, 0xB4, 0xB9, 0xBA].contains(second) {
            return false
        }
        // NTAG424 ChangeKey is answered with a status word only.
        if first == 0x90, second == 0xC4 {
            return false
        }
        return true
    }

    private func transceiveRaw(_ command: RawCommand) async throws -> Data {
        switch nfcTag {
        case .miFare(let mifare):
            return try await withCheckedThrowingContinuation { continuation in
                mifare.sendMiFareCommand(commandPacket: command.bytes) { data, error in
                    if let error {
                        continuation.resume(throwing: TagError.tagLost(diagnostics: "\(error)"))
                    } else {
                        continuation.resume(returning: data)
                    }
                }
            }

        case .iso7816(let iso):
            // For ISO 7816 callers should ideally hand us an NFCISO7816APDU;
            // raw-bytes path falls back to manual APDU construction.
            return try await withCheckedThrowingContinuation { continuation in
                let apdu = NFCISO7816APDU(data: command.bytes)
                guard let apdu else {
                    continuation.resume(throwing: TagError.protocolError(
                        "invalid APDU bytes",
                        diagnostics: command.bytes.hexString
                    ))
                    return
                }
                iso.sendCommand(apdu: apdu) { response, sw1, sw2, error in
                    if let error {
                        continuation.resume(throwing: TagError.tagLost(diagnostics: "\(error)"))
                    } else {
                        var combined = response
                        combined.append(sw1)
                        combined.append(sw2)
                        continuation.resume(returning: combined)
                    }
                }
            }

        case .feliCa(let felica):
            return try await withCheckedThrowingContinuation { continuation in
                felica.sendFeliCaCommand(commandPacket: command.bytes) { data, error in
                    if let error {
                        continuation.resume(throwing: TagError.tagLost(diagnostics: "\(error)"))
                    } else {
                        continuation.resume(returning: data)
                    }
                }
            }

        case .iso15693(let iso):
            return try await transceiveISO15693(iso, command: command)

        @unknown default:
            throw TagError.capabilityUnsupported(.rawTransceive)
        }
    }

    /// Map a raw `[flag, opcode, params…]` ISO 15693 frame onto CoreNFC's typed /
    /// custom-command API, synthesising the simulator's leading-status-byte shape
    /// (`0x00 ‖ data` success, `0x01 ‖ code` error) so the `Iso15693ProtectionClient`,
    /// the console presets and the harness plan run identically against this and
    /// the simulator.
    ///
    /// Every opcode `Iso15693Simulator` implements is mapped here. That parity is
    /// load-bearing: it is what makes a live failure a *divergence* signal rather
    /// than a missing-case artefact. It is also what the console's Type-5 preset
    /// library needs — 7 of its 10 presets (`0x23`, `0x27`–`0x2A`, `0x2B`, `0x2C`)
    /// used to fall through to `capabilityUnsupported` on real silicon while
    /// working perfectly against the simulator.
    private func transceiveISO15693(_ iso: NFCISO15693Tag, command: RawCommand) async throws -> Data {
        let bytes = [UInt8](command.bytes)
        guard bytes.count >= 2 else {
            throw TagError.protocolError("ISO15693 frame too short", diagnostics: command.bytes.hexString)
        }
        let flags = NFCISO15693RequestFlag(rawValue: bytes[0])
        let opcode = bytes[1]
        let params = Array(bytes.dropFirst(2))
        // `[firstBlock, countMinusOne]` → an `NSRange`, the shape CoreNFC's
        // multi-block calls take. ISO 15693 encodes "one less than the count".
        func blockRange() throws -> NSRange {
            guard params.count >= 2 else {
                throw TagError.protocolError("missing block range", diagnostics: command.bytes.hexString)
            }
            return NSRange(location: Int(params[0]), length: Int(params[1]) + 1)
        }
        do {
            switch opcode {
            case 0xAB, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB9, 0xBA:
                // Manufacturer custom command — CoreNFC injects the NXP (0x04)
                // code, so everything passed here is a *parameter*. Accept the
                // `E0 04` console spelling by normalising it away, exactly as
                // the simulator does, so one frame means one thing on both.
                let custom = Iso15693Opcode.normalisedCustomParameters(opcode: opcode, params: params)
                // Reject a wrong parameter count outright rather than putting a
                // malformed frame on the air. A tag that doesn't understand a
                // frame usually stays silent, which surfaces as a ~300 ms
                // timeout and a generic `01 0F` — indistinguishable from "this
                // chip refuses the command", and it cost a live debugging cycle.
                if let expected = Iso15693Opcode.customParameterCount(for: opcode),
                   custom.count != expected
                {
                    throw TagError.protocolError(
                        "Wrong parameter count for this command",
                        diagnostics: "opcode \(String(format: "%02X", opcode)) expects \(expected) "
                            + "parameter byte(s), got \(custom.count): \(command.bytes.hexString)"
                    )
                }
                // Commands the chip honours only in Addressed or Selected mode
                // (`Iso15693Opcode.requiresAddressedOrSelectedMode`) arrive
                // here with the Select flag already in the frame — the driver
                // SELECTs the tag first and flags each gated command 0x12.
                // That is the one transmissible route: nfcd refuses an
                // explicit Address flag on BOTH `customCommand` ("Invalid
                // Parameter", 2 ms) and `sendRequest` (NFCError 102, 4 ms)
                // before the frame reaches the air, live-confirmed 2026-08-07.
                //
                // `customCommand` goes first — it injects the manufacturer
                // code itself. If a select-flagged frame fails with *no tag
                // response code* (tag silence, or nfcd refusing the Select
                // flag locally — the two are indistinguishable by error code),
                // the identical frame is retried once through `sendRequest`,
                // which builds the frame verbatim: manufacturer code ours to
                // supply, and no UID field in selected mode. A genuine tag
                // error frame is an answer, not a transport failure, and must
                // never trigger the retry.
                do {
                    let data = try await iso.customCommand(
                        requestFlags: flags,
                        customCommandCode: Int(opcode),
                        customRequestParameters: Data(custom)
                    )
                    return Data([0x00]) + data
                } catch let error where flags.contains(.select) {
                    if case .success(let frame) = Self.iso15693Failure(error) {
                        return frame
                    }
                    NFCTrace.shared.note(
                        "selected-mode customCommand \(String(format: "%02X", opcode)) drew no reply; retrying via sendRequest"
                    )
                    let (responseFlag, responseData) = try await iso.sendRequest(
                        requestFlags: Int(flags.rawValue),
                        commandCode: Int(opcode),
                        data: Data([Self.nxpManufacturerCode]) + Data(custom)
                    )
                    if responseFlag.contains(.error) {
                        return Data([0x01]) + (responseData ?? Data())
                    }
                    return Data([0x00]) + (responseData ?? Data())
                }

            case 0x20: // READ_SINGLE_BLOCK
                guard let block = params.first else { throw TagError.protocolError("missing block", diagnostics: "") }
                let data = try await iso.readSingleBlock(requestFlags: flags, blockNumber: block)
                return Data([0x00]) + data

            case 0x21: // WRITE_SINGLE_BLOCK
                guard params.count >= 5 else { throw TagError.protocolError("missing block/data", diagnostics: "") }
                try await iso.writeSingleBlock(
                    requestFlags: flags,
                    blockNumber: params[0],
                    dataBlock: Data(params[1...])
                )
                return Data([0x00])

            case 0x22: // LOCK_BLOCK
                guard let block = params.first else { throw TagError.protocolError("missing block", diagnostics: "") }
                try await iso.lockBlock(requestFlags: flags, blockNumber: block)
                return Data([0x00])

            case 0x25: // SELECT: move the tag to the Selected state
                // The SELECT frame itself is *addressed* (UID present) and is
                // built entirely by nfcd, which is what makes it transmissible
                // where our own Address flag is refused. After it succeeds the
                // driver's gated commands ride the Select flag, UID-free.
                try await iso.select(requestFlags: flags)
                return Data([0x00])

            case 0x23: // READ_MULTIPLE_BLOCKS
                // No async variant on this one — CoreNFC ships only the
                // `resultHandler` form, so bridge it by hand.
                let range = try blockRange()
                let blocks: [Data] = try await withCheckedThrowingContinuation { continuation in
                    iso.readMultipleBlocks(requestFlags: flags, blockRange: range) { result in
                        continuation.resume(with: result)
                    }
                }
                return Data([0x00]) + blocks.reduce(into: Data()) { $0.append($1) }

            case 0x27: // WRITE_AFI
                guard let afi = params.first else { throw TagError.protocolError("missing AFI", diagnostics: "") }
                try await iso.writeAFI(requestFlags: flags, afi: afi)
                return Data([0x00])

            case 0x28: // LOCK_AFI (irreversible)
                try await iso.lockAFI(requestFlags: flags)
                return Data([0x00])

            case 0x29: // WRITE_DSFID
                guard let dsfid = params.first else { throw TagError.protocolError("missing DSFID", diagnostics: "") }
                try await iso.writeDSFID(requestFlags: flags, dsfid: dsfid)
                return Data([0x00])

            case 0x2A: // LOCK_DSFID (irreversible)
                try await iso.lockDSFID(requestFlags: flags)
                return Data([0x00])

            case 0x2B: // GET_SYSTEM_INFORMATION
                let info = try await iso.systemInfo(requestFlags: flags)
                return Self.encodeSystemInfo(info, uid: iso.identifier)

            case 0x2C: // GET_MULTIPLE_BLOCK_SECURITY_STATUS
                let status = try await iso.getMultipleBlockSecurityStatus(requestFlags: flags, blockRange: blockRange())
                return Data([0x00]) + Data(status.map { UInt8(truncatingIfNeeded: $0.intValue) })

            default:
                throw TagError.capabilityUnsupported(
                    .rawTransceive,
                    diagnostics: "unsupported ISO15693 opcode \(String(opcode, radix: 16))"
                )
            }
        } catch let error as TagError {
            throw error
        } catch {
            switch Self.iso15693Failure(error) {
            case .success(let frame): return frame
            case .failure(let tagError): throw tagError
            }
        }
    }

    /// Re-encode CoreNFC's decoded *Get System Information* tuple back into the
    /// ISO 15693 wire layout the simulator emits, so both sides of the harness
    /// parse one shape:
    /// `00 ‖ infoFlags ‖ UID(8) ‖ DSFID ‖ AFI ‖ (blockCount-1) ‖ (blockSize-1) ‖ ICRef`.
    ///
    /// CoreNFC returns `-1` for any field the tag omitted; those clear their
    /// info-flag bit and are emitted as `00`, mirroring a tag that didn't send
    /// them. NOTE: `iso.identifier`'s byte order is CoreNFC's, which has not been
    /// confirmed against the wire order on real silicon — the harness therefore
    /// asserts on the decoded geometry, not on these UID bytes.
    private static func encodeSystemInfo(_ info: NFCISO15693SystemInfo, uid: Data) -> Data {
        let dsfid = info.dataStorageFormatIdentifier
        let afi = info.applicationFamilyIdentifier
        var infoFlags: UInt8 = 0
        if dsfid >= 0 {
            infoFlags |= 0x01
        }
        if afi >= 0 {
            infoFlags |= 0x02
        }
        if info.blockSize >= 0, info.totalBlocks >= 0 {
            infoFlags |= 0x04
        }
        if info.icReference >= 0 {
            infoFlags |= 0x08
        }

        var response = Data([0x00, infoFlags])
        response.append(uid)
        response.append(UInt8(truncatingIfNeeded: max(dsfid, 0)))
        response.append(UInt8(truncatingIfNeeded: max(afi, 0)))
        // Memory size: low byte = blockCount-1, high byte = blockSize-1.
        response.append(UInt8(truncatingIfNeeded: max(info.totalBlocks - 1, 0)))
        response.append(UInt8(truncatingIfNeeded: max(info.blockSize - 1, 0)))
        response.append(UInt8(truncatingIfNeeded: max(info.icReference, 0)))
        return response
    }

    /// Turn a CoreNFC ISO 15693 failure into the `0x01 ‖ code` error frame the
    /// simulator returns — but **only when the tag actually answered.**
    ///
    /// CoreNFC carries the tag's own response byte in `NFCISO15693TagResponseErrorKey`,
    /// which is what lets `Iso15693ProtectionClient.readProtectionState` tell
    /// `0x40` (password required) from `0x12` (block locked).
    ///
    /// When that key is **absent** the tag said nothing: a timeout, a dropped
    /// frame, a command it does not accept in this mode. This used to fabricate
    /// `01 0F` ("unknown error") for that case, which is indistinguishable from
    /// a tag that answered with a generic refusal — and every caller then
    /// reasoned about a reply that never existed. It produced two wrong
    /// diagnoses in one session on 2026-08-07: a SLIX2 `SET_PASSWORD` that got
    /// no answer was reported as "wrong password", and a dropped
    /// `READ_SINGLE_BLOCK` was reported as `refused … resp=01:0F` when the tag
    /// was healthy and served the very next command.
    ///
    /// Silence is now `tagLost`, which is what it is. Callers that classify tag
    /// errors keep working on real ones; callers that treat `tagLost` as
    /// inconclusive (the enforcement probes) now get the right answer.
    private static func iso15693Failure(_ error: Error) -> Result<Data, TagError> {
        let nsError = error as NSError
        if let code = nsError.userInfo[NFCISO15693TagResponseErrorKey] as? NSNumber {
            return .success(Data([0x01, UInt8(truncatingIfNeeded: code.intValue)]))
        }
        return .failure(TagError.tagLost(
            diagnostics: "ISO 15693: no response from the tag (no tag-response code in \(nsError.domain) "
                + "\(nsError.code)). Transport failure, not a refusal."
        ))
    }

    // MARK: - Type-2 memory, auth & protection

    //
    // NTAG21x / MIFARE Ultralight EV1 speak page-addressed commands over the
    // `.miFare` transport. Page numbers and byte offsets come from the canonical
    // `Type2ConfigLayout` so this never drifts from the chip simulators.

    /// NXP's IC manufacturer code, the first byte of every ICODE custom-command
    /// payload (SL2S2602 Table 12). `customCommand` injects this itself;
    /// `sendRequest` does not, so the selected-mode fallback supplies it.
    static let nxpManufacturerCode: UInt8 = 0x04

    private enum T2 {
        static let read: UInt8 = 0x30 // READ → 16 bytes (4 pages)
        static let write: UInt8 = 0xA2 // WRITE one 4-byte page → ACK 0x0A
        static let pwdAuth: UInt8 = 0x1B // PWD_AUTH → 2-byte PACK
        static let ack: UInt8 = 0x0A
        static let pageSize = 4
    }

    /// Send one raw MIFARE frame, returning the tag's response bytes. A CoreNFC
    /// transport error maps to `.tagLost`; NAK interpretation (a refused write
    /// or wrong password often arrives as a 1-byte payload *or* a transport
    /// error, depending on iOS version) is left to the caller.
    /// Whether a `sendMiFare` label names a frame whose *payload* is secret —
    /// the password on a `PWD_AUTH`, or a write to the PWD/PACK pages.
    private static func labelCarriesSecretPayload(_ label: String) -> Bool {
        let upper = label.uppercased()
        return upper.contains("PWD") || upper.contains("PACK")
    }

    /// Whether a `sendMiFare` label names a frame whose *response* is secret —
    /// only `PWD_AUTH`, which returns the 2-byte PACK.
    private static func labelHasSecretResponse(_ label: String) -> Bool {
        label.uppercased().contains("PWD_AUTH")
    }

    private func sendMiFare(_ bytes: Data, label: String) async throws -> Data {
        guard case .miFare(let mifare) = nfcTag else {
            throw TagError.capabilityUnsupported(.rawTransceive, diagnostics: "\(label): not a Type-2/MIFARE tag")
        }
        let txSecret = Self.labelCarriesSecretPayload(label)
        let rxSecret = Self.labelHasSecretResponse(label)
        NFCTrace.shared.tx(label, bytes, secret: txSecret)
        return try await withCheckedThrowingContinuation { continuation in
            mifare.sendMiFareCommand(commandPacket: bytes) { data, error in
                if let error {
                    NFCTrace.shared.failure(error.localizedDescription, label: label)
                    // Never echo a secret payload into a diagnostics string — it
                    // surfaces in the error UI and pasted bug reports.
                    let shownCmd = txSecret ? "‹redacted›" : bytes.hexString
                    continuation.resume(throwing: TagError.tagLost(
                        diagnostics: "\(label) cmd=\(shownCmd): \(error.localizedDescription)"
                    ))
                } else {
                    NFCTrace.shared.rx(label, data, secret: rxSecret)
                    continuation.resume(returning: data)
                }
            }
        }
    }

    /// Read `count` pages starting at `startPage` using READ (0x30, 16B/4 pages
    /// per frame). Returns exactly `count * 4` bytes.
    private func readType2Pages(startPage: Int, count: Int) async throws -> Data {
        var out = Data()
        var page = startPage
        let lastPage = startPage + count - 1
        while page <= lastPage {
            let resp = try await sendMiFare(Data([T2.read, UInt8(page)]), label: "READ p\(page)")
            guard resp.count >= T2.pageSize else {
                throw TagError.malformedResponse(resp, diagnostics: "READ p\(page) returned \(resp.count)B")
            }
            let pagesReturned = min(resp.count / T2.pageSize, 4)
            let usable = min(pagesReturned, lastPage - page + 1)
            guard usable > 0 else { break }
            out.append(resp.prefix(usable * T2.pageSize))
            page += usable
        }
        return out
    }

    /// Write one 4-byte page via WRITE (0xA2). Throws if the chip does not ACK
    /// with 0x0A — the usual cause is the page being protected or locked.
    private func writeType2Page(_ page: Int, bytes: Data, label: String) async throws {
        guard bytes.count == T2.pageSize else {
            throw TagError.protocolError("\(label): page write must be 4 bytes", diagnostics: "len=\(bytes.count)")
        }
        var frame = Data([T2.write, UInt8(page)])
        frame.append(bytes)
        let resp = try await sendMiFare(frame, label: "\(label) WRITE p\(page)")
        guard resp.first == T2.ack else {
            throw TagError.protocolError(
                "WRITE not acknowledged",
                diagnostics: "\(label) page=\(page) resp=\(resp.hexString)"
            )
        }
    }

    /// Write the records into the Type-2 NDEF region via raw page WRITEs — the
    /// authenticated-tag path. Wraps the message in the TLV envelope, checks it
    /// fits the chip's NDEF region, and writes page by page so the active
    /// `PWD_AUTH` covers each write.
    private func writeNDEFViaPages(_ records: [NDEFRecord]) async throws {
        guard let layout = chip?.memoryLayout, let ndef = layout.ndefRange else {
            throw TagError.capabilityUnsupported(
                .ndefWrite,
                diagnostics: "no NDEF range for chip=\(chip?.id.description ?? "unknown")"
            )
        }
        let message = try NDEFCodec.encode(records)
        let envelope = Type2NDEF.wrap(message: message)
        let capacity = (ndef.upperBound - ndef.lowerBound + 1) * T2.pageSize
        guard envelope.count <= capacity else {
            throw TagError.writeOverflow(needed: envelope.count, available: capacity)
        }
        // Pad the final page. Only `padded.count / 4` pages are written, so
        // everything past the new envelope keeps whatever it held.
        //
        // Harmless to a *reader*: a TLV reader stops at the message length, so
        // the tag presents exactly the new message. Not harmless in general, and
        // this comment used to read as a blanket. An erase encodes to 03 00 FE
        // padded to one page, so on an NTAG216 whose NDEF region is pages 4 to
        // 225 it rewrites page 4 and leaves 5 to 225 exactly as they were. The
        // 2026-09-09 HG-1 sweep read the old message back out of the pages behind
        // the terminator on Type-2 tags that had been erased. The Erase screen's
        // copy says so; a whole-area wipe would be a different operation with a
        // different cost, and is not what this does.
        var padded = envelope
        while padded.count % T2.pageSize != 0 {
            padded.append(0x00)
        }
        for i in 0 ..< (padded.count / T2.pageSize) {
            let start = padded.startIndex + i * T2.pageSize
            let chunk = padded.subdata(in: start ..< (start + T2.pageSize))
            try await writeType2Page(ndef.lowerBound + i, bytes: chunk, label: "NDEF")
        }
    }

    /// Read the Type-2 NDEF region via raw page READs and unwrap the TLV — the
    /// authenticated-tag path, mirroring the high-level read's contract (empty
    /// `Data` for a blank/cleared tag).
    private func readNDEFViaPages() async throws -> Data {
        guard let layout = chip?.memoryLayout, let ndef = layout.ndefRange else {
            throw TagError.capabilityUnsupported(
                .ndefRead,
                diagnostics: "no NDEF range for chip=\(chip?.id.description ?? "unknown")"
            )
        }
        let count = ndef.upperBound - ndef.lowerBound + 1
        let raw = try await readType2Pages(startPage: ndef.lowerBound, count: count)
        do {
            return try Type2NDEF.unwrap(raw)
        } catch {
            // Still an empty read, because that is what this path has always
            // returned and a blank tag is by far the common cause. But a region
            // the parser could not walk is not the same fact as a region holding
            // no message, and the trace is where that difference has to show up:
            // without this line a damaged data area reads as "blank tag" with
            // nothing to distinguish it. The first bytes are the whole diagnosis.
            NFCTrace.shared.note(
                "TLV unwrap failed (\(error)); region starts \(raw.prefix(8).hexString)",
                label: "NDEF read"
            )
            return Data()
        }
    }

    /// Resolve the canonical Type-2 config layout for the connected chip.
    private func requireType2Layout(_ capability: TagCapability) throws -> Type2ConfigLayout {
        guard let layout = chip?.type2ConfigLayout else {
            throw TagError.capabilityUnsupported(
                capability,
                diagnostics: "no Type-2 config layout for chip=\(chip?.id.description ?? "unknown")"
            )
        }
        return layout
    }

    public func readMemory(range: Range<Int>) async throws -> Data {
        try require(.memoryRead)
        guard range.lowerBound >= 0, range.lowerBound < range.upperBound else {
            throw TagError.protocolError("invalid read range", diagnostics: "\(range)")
        }
        let firstPage = range.lowerBound / T2.pageSize
        let lastPage = (range.upperBound - 1) / T2.pageSize
        let pages = try await readType2Pages(startPage: firstPage, count: lastPage - firstPage + 1)
        let offset = range.lowerBound - firstPage * T2.pageSize
        let length = range.upperBound - range.lowerBound
        guard offset + length <= pages.count else {
            throw TagError.malformedResponse(pages, diagnostics: "read \(range) past returned \(pages.count)B")
        }
        return pages.subdata(in: offset ..< (offset + length))
    }

    public func writeMemory(at offset: Int, bytes: Data) async throws {
        try require(.memoryWrite)
        guard offset >= 0, offset % T2.pageSize == 0 else {
            throw TagError.protocolError("write offset must be page-aligned", diagnostics: "offset=\(offset)")
        }
        guard !bytes.isEmpty, bytes.count % T2.pageSize == 0 else {
            throw TagError.protocolError(
                "write length must be a multiple of \(T2.pageSize)",
                diagnostics: "len=\(bytes.count)"
            )
        }
        let firstPage = offset / T2.pageSize
        for i in 0 ..< (bytes.count / T2.pageSize) {
            let start = bytes.startIndex + i * T2.pageSize
            let chunk = bytes.subdata(in: start ..< (start + T2.pageSize))
            try await writeType2Page(firstPage + i, bytes: chunk, label: "writeMemory")
        }
    }

    /// `true` when the connected chip is a MIFARE Ultralight C. Gates the
    /// key-page trace redaction and the protection-state fan-out below, both of
    /// which would be wrong for any other Type-2 chip.
    var isUltralightC: Bool {
        if case .type2(.mifareUltralightC) = chip?.family {
            return true
        }
        return false
    }
}

// MARK: - FeliCa transit reads

extension CoreNFCConnectedTag: EPassportReadable {
    /// Send one ISO 7816 command APDU to a passport chip. Routes through the
    /// traced `transceive` path (so credential frames are masked) and returns
    /// `data ‖ SW1 ‖ SW2`.
    public func sendAPDU(_ command: Data) async throws -> Data {
        try await transceive(
            RawCommand(bytes: command, name: "passport", family: .type4(.ePassport))
        )
    }
}

extension CoreNFCConnectedTag: FeliCaReadable {
    /// FeliCa system code selected at polling (2 bytes, big-endian → UInt16).
    /// `0` for any non-FeliCa tag (the transit reader never calls into those).
    public var systemCode: UInt16 {
        guard case .feliCa(let felica) = nfcTag else { return 0 }
        let bytes = [UInt8](felica.currentSystemCode)
        guard bytes.count == 2 else { return 0 }
        return (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
    }

    /// The card's 8-byte manufacture ID (IDm), or the generic UID otherwise.
    public var idm: Data {
        guard case .feliCa(let felica) = nfcTag else { return uid }
        return felica.currentIDm
    }

    public func readWithoutEncryption(
        serviceCode: UInt16,
        blocks: Range<Int>
    ) async throws -> [Data] {
        guard case .feliCa(let felica) = nfcTag else {
            throw TagError.capabilityUnsupported(.transitRead)
        }
        // Service-code list element: 2 bytes, little-endian.
        let serviceList = [Data([UInt8(serviceCode & 0xFF), UInt8(serviceCode >> 8)])]
        // Block-list element: 0x80 (2-byte form, service index 0) + block number.
        let blockList = blocks.map { Data([0x80, UInt8($0)]) }

        // Trace the frame the way `transceive` traces every other family, so a
        // transit read shows up in the "All NFC traffic" tab and in an
        // `idevicesyslog -m HEXNFC` capture instead of leaving a hole between
        // the identify note and whatever failed next.
        //
        // nfcd builds the actual on-air frame, so what we log is the request as
        // we specified it: the reconstructed FeliCa command packet body (opcode
        // `06` = Read Without Encryption, service list, block list). No masking
        // is needed: Read Without Encryption carries no key material, and the
        // IDm is already public in the identify note.
        let label = "felica.readWithoutEncryption"
        var frame = Data([0x06])
        frame.append(UInt8(serviceList.count))
        for service in serviceList {
            frame.append(service)
        }
        frame.append(UInt8(blockList.count))
        for block in blockList {
            frame.append(block)
        }
        NFCTrace.shared.tx(label, frame)

        return try await withCheckedThrowingContinuation { continuation in
            felica.readWithoutEncryption(
                serviceCodeList: serviceList,
                blockList: blockList
            ) { statusFlag1, statusFlag2, blockData, error in
                if let error {
                    let failure = TagError.tagLost(diagnostics: "\(error)")
                    NFCTrace.shared.failure(
                        "service=\(String(format: "%04X", serviceCode)) "
                            + "blocks=\(blocks.lowerBound)..<\(blocks.upperBound) "
                            + "transport error: \(error)",
                        label: label
                    )
                    continuation.resume(throwing: failure)
                    return
                }
                // FeliCa success is both status flags == 0x00; a non-zero flag
                // means the service/blocks were unavailable even when error is nil.
                guard statusFlag1 == 0x00, statusFlag2 == 0x00 else {
                    let diagnostics = "service=\(String(format: "%04X", serviceCode)) "
                        + "sf1=\(String(format: "%02X", statusFlag1)) "
                        + "sf2=\(String(format: "%02X", statusFlag2))"
                    NFCTrace.shared.failure(
                        diagnostics + " blocks=\(blocks.lowerBound)..<\(blocks.upperBound)",
                        label: label
                    )
                    continuation.resume(throwing: TagError.protocolError(
                        "FeliCa read failed",
                        diagnostics: diagnostics
                    ))
                    return
                }
                // Response body: status flags then the returned blocks, so a
                // capture can be diffed byte-for-byte against the card. The
                // status flags arrive as `Int` from CoreNFC even though they are
                // single bytes on the wire, and the block count is bounded by
                // `maxBlocksPerRead`, but both are narrowed defensively so a
                // surprise value cannot trap in a logging path.
                var response = Data([
                    UInt8(truncatingIfNeeded: statusFlag1),
                    UInt8(truncatingIfNeeded: statusFlag2),
                    UInt8(truncatingIfNeeded: blockData.count),
                ])
                for block in blockData {
                    response.append(block)
                }
                NFCTrace.shared.rx(label, response)
                continuation.resume(returning: blockData)
            }
        }
    }
}

// MARK: - Bridge: NDEFPayload ↔ NFCNDEFPayload

extension CoreNFCSession {
    static func payload(from nfc: NFCNDEFPayload) -> NDEFPayload {
        NDEFPayload(
            tnf: UInt8(nfc.typeNameFormat.rawValue),
            type: nfc.type,
            id: nfc.identifier,
            payload: nfc.payload
        )
    }

    static func nfcPayload(from payload: NDEFPayload) -> NFCNDEFPayload {
        let tnf = NFCTypeNameFormat(rawValue: UInt8(payload.tnf)) ?? .unchanged
        return NFCNDEFPayload(
            format: tnf,
            type: payload.type,
            identifier: payload.id,
            payload: payload.payload
        )
    }
}

// MARK: - Factory

public final class CoreNFCSessionFactory: TagSessionFactory, @unchecked Sendable {
    /// When set, sessions from this factory skip the identification probe —
    /// see `CoreNFCSession.skipIdentification`. Lab use: it is the only way to
    /// reach a chip whose refusal of `GET_VERSION` halts it.
    public var skipIdentification = false

    public init() {}
    public func makeSession() -> TagSession {
        CoreNFCSession(skipIdentification: skipIdentification)
    }
}

#endif
