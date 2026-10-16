import Foundation

/// Sets a Type-2 chip's lock bytes, permanently.
///
/// Extracted from `CoreNFCSession.permanentLock()` so the frames it puts on the
/// wire are reachable from tests. `SimulatedSession.permanentLock()` satisfies
/// the `ConnectedTag` protocol by calling the simulator's own lock model, so
/// nothing that went through that path ever exercised the frame construction —
/// which is how a dynamic-lock payload that set reserved bits on every NTAG21x
/// survived to a live run on 2026-08-07. Driving this struct against a simulator
/// closes that hole the same way `UltralightCProtectionDriver` and
/// `NTAG424ProtectionDriver` already do for their families.
///
/// ## Order is load-bearing, and it is now dynamic-first
///
/// It used to be static-first, on the reasoning that the static bytes cover
/// pages 3-15 and the dynamic page always sits above them, so static-first
/// cannot make the dynamic page unwritable. That reasoning is sound about lock
/// bits and silent about the *password gate*, which is what actually decides
/// whether a write is accepted.
///
/// **Live evidence, 2026-09-04 (NTAG213, AUTH0 = 0x04):**
///
///     static lock  WRITE p2   A2 02 9F 48 FF FF  -> 0A   page 2 is BELOW AUTH0
///     dynamic lock WRITE p40  A2 28 FF 0F 3F 00  -> 00   page 0x28 is ABOVE AUTH0
///
/// The static write was accepted because page 2 sits below AUTH0 on every chip
/// in the catalogue, and the dynamic write was NAKed because the dynamic-lock
/// page sits above it. So static-first burns pages 3-15 irreversibly and *then*
/// discovers the tag was gated.
///
/// Dynamic-first inverts that: the page the gate protects is attempted first, so
/// a gated tag refuses before a single irreversible bit is set. Verified safe
/// against the catalogue: every `dynamicLockPage` is 36 or higher while every
/// `lockPages.first` is 2, so the static write can never gate the dynamic one.
///
/// A pre-flight AUTH0 read refuses earlier still. The order is the belt; the
/// pre-flight is the braces. Both, because every lock bit is OR-only and there
/// is no second attempt to discover you were wrong.
public struct Type2LockDriver: Sendable {
    /// Raw command channel: production wires `CoreNFCConnectedTag.transceive`,
    /// tests wire the simulator. Responses include the leading status byte.
    public let transceive: @Sendable (RawCommand) async throws -> Data
    /// The tag's UID, used only so the pre-flight can recognise a read
    /// roll-over. `nil` costs the pre-flight its page number and nothing else.
    public let uid: Data?

    public init(
        uid: Data? = nil,
        transceive: @escaping @Sendable (RawCommand) async throws -> Data
    ) {
        self.uid = uid
        self.transceive = transceive
    }

    static let read: UInt8 = 0x30
    static let write: UInt8 = 0xA2
    static let ack: UInt8 = 0x0A
    static let pageSize = 4

    /// Byte offsets of the two static lock bytes within their page. Bytes 0–1
    /// are BCC1 and the internal byte and must survive untouched, which is why
    /// this is a read-modify-write rather than a blind page write.
    static let staticLockByteRange = 2 ..< 4

    /// Set every lock bit the chip has: static lock bytes, then the dynamic-lock
    /// page if it has one.
    ///
    /// - Parameters:
    ///   - layout: supplies the lock page numbers. Deliberately not
    ///     `Type2ConfigLayout`, which maps the NTAG21x password block and is
    ///     `nil` for chips that have lock bytes but no password hardware.
    ///   - family: selects the dynamic-lock bit mask. See `Type2LockWrite`.
    /// - Parameter configLayout: the chip's password block, used for the
    ///   pre-flight AUTH0 read. `nil` for a chip with no password hardware
    ///   (NTAG 210µ, EM), where there is no gate to check and none to trip.
    @discardableResult
    public func permanentLock(
        layout: ChipMemoryLayout,
        family: TagFamily,
        configLayout: Type2ConfigLayout?
    ) async throws -> PermanentLockOutcome {
        guard let staticLockPage = layout.lockPages.first else {
            throw TagError.capabilityUnsupported(
                .permanentLock, diagnostics: "chip declares no Type-2 lock pages"
            )
        }
        var outcome = PermanentLockOutcome()

        // Pre-flight. An irreversible operation does not start against a state
        // it has not established. A gated tag is refused here, before any bit is
        // set, with a message that tells the user what to do about it.
        if let configLayout {
            try await refuseIfGated(configLayout)
        }

        // Dynamic lock bytes first: see "Order is load-bearing" above. Absent on
        // MF0UL11 and NTAG 210µ, whose user area the static bytes fully cover,
        // which is why this is optional rather than assumed.
        if let dynamicLockPage = layout.dynamicLockPage {
            let payload = Type2LockWrite.dynamicLockPayload(for: family, pageSize: Self.pageSize)
            switch try await attemptWrite(dynamicLockPage, bytes: payload, label: "dynamic lock") {
            case .acknowledged:
                await outcome.record(.dynamicLock, verifyDynamicLock(dynamicLockPage, payload: payload))

            case .statedRefusal(let diagnostics):
                // The chip answered, and the answer was no. Nothing burned, and
                // that is known rather than assumed.
                outcome.record(.dynamicLock, .refused(diagnostics: diagnostics))
                outcome.record(.staticLock, .notAttempted)
                throw TagError.permanentLockIncomplete(outcome)

            case .noAnswer(let diagnostics):
                // A refusal may be a lost ACK, so consult the chip rather than
                // declaring the write unapplied. This is the one lock stage that
                // can be asked: `docs/internal/chip-config-pages.md` carries a
                // live NTAG213 capture of the dynamic-lock page read straight
                // back after the write, and the static page has no such capture.
                switch await readDynamicLockBits(dynamicLockPage, payload: payload) {
                case .allSet:
                    // The bits are set: the write landed and only its
                    // acknowledgement was lost. Carry on to the static bytes.
                    outcome.record(.dynamicLock, .committedVerified)

                case .notAllSet(let reason):
                    outcome.record(.dynamicLock, .refused(
                        diagnostics: "\(diagnostics); a read-back shows the lock bits still clear (\(reason))"
                    ))
                    outcome.record(.staticLock, .notAttempted)
                    throw TagError.permanentLockIncomplete(outcome)

                case .unreadable:
                    outcome.record(.dynamicLock, .inconclusive(
                        diagnostics: "\(diagnostics); the chip would not answer a read-back either, so "
                            + "whether the lock bits burned is not known"
                    ))
                    outcome.record(.staticLock, .notAttempted)
                    throw TagError.permanentLockIncomplete(outcome)
                }
            }
        }

        // Static lock bytes: page 2, bytes 2-3 -> 0xFF (covers pages 3...15).
        //
        // This read is inside a `do` because of what now sits above it. The
        // dynamic-lock stage runs FIRST on this branch, so by the time control
        // reaches here every dynamic bit is already burned and recorded. A bare
        // `try` would carry a lost frame straight past `outcome`, and a tag whose
        // lock bits are set for good would be reported as "The tag responded
        // outside the expected protocol." That is the one report CLAUDE.md calls
        // certainly wrong about a tag that has already burned half its lock bits,
        // and inverting the order is what made it reachable: before, this read
        // was the first statement in the method and a throw here burned nothing.
        let existing: Data
        do {
            existing = try await readPage(staticLockPage)
        } catch {
            // `.notAttempted`, not `.inconclusive`: the write is a read-modify-
            // write and the read is what failed, so no static lock frame ever
            // went out. What burned is whatever the dynamic stage already
            // recorded, which is why the outcome has to survive this throw.
            outcome.record(.staticLock, .notAttempted)
            throw TagError.permanentLockIncomplete(outcome)
        }
        var newLock = existing
        for offset in Self.staticLockByteRange {
            newLock[newLock.startIndex + offset] = 0xFF
        }
        switch try await attemptWrite(staticLockPage, bytes: newLock, label: "static lock") {
        case .acknowledged:
            // No read-back verdict for the static page yet. No capture in this
            // repo shows a `30 02` taken immediately after a static lock write,
            // so a chip that returns its pre-write value would fail a correct
            // lock, and a false alarm on an irreversible operation is worse than
            // an unproven one. Promote this to a verified verdict once a bench
            // capture exists.
            outcome.record(
                .staticLock, .committedUnverified(reason: "no bench capture of a page-2 read-back yet")
            )

        case .statedRefusal(let diagnostics):
            outcome.record(.staticLock, .refused(diagnostics: diagnostics))
            throw TagError.permanentLockIncomplete(outcome)

        case .noAnswer(let diagnostics):
            // Deliberately not resolved by a read-back: the same missing capture
            // that keeps the acknowledged path unverified would make a read of
            // clear bits unusable as proof, and inventing one on the operation
            // with no undo is the wrong place to start.
            outcome.record(.staticLock, .inconclusive(
                diagnostics: "\(diagnostics); this page has no trusted read-back, so whether the "
                    + "lock bytes burned is not known"
            ))
            throw TagError.permanentLockIncomplete(outcome)
        }
        return outcome
    }

    /// Refuse a permanent lock on a tag whose password gate is armed.
    ///
    /// This used to take CFG0 off the wire itself and read AUTH0 out of byte 3,
    /// which is sound only for an answer that really is CFG0. A read-protected
    /// Type-2 tag answers a READ with a **roll-over**: the 2026-08-14 NTAG213
    /// capture in `NTAG21xSimulator.servedPages` shows `30 03` returning page 3
    /// and then pages 0, 1 and 2. The four bytes at the front of a rolled-over
    /// answer are page 0, whose byte 3 is BCC0, a checksum of the UID, and
    /// nothing on the wire distinguishes the two answers by shape. What that
    /// costs depends on silicon this repo has not captured: where the chip
    /// refuses a READ whose *addressed* page is gated, as the simulator models,
    /// the old code threw `malformedResponse` and the user was told the tag had
    /// answered out of protocol; where it rolls the addressed page over too, a
    /// UID byte was read as AUTH0 and the residue named it as the page a gate
    /// starts from.
    ///
    /// Going through `Type2PasswordDriver.readState` removes the question rather
    /// than betting on the answer: it recognises the roll-over positively, by
    /// signature, and reports read protection as itself. The write order is
    /// still the belt for either case, since the dynamic-lock page sits above
    /// AUTH0 and is attempted first.
    private func refuseIfGated(_ configLayout: Type2ConfigLayout) async throws {
        // Without a 7-byte UID there is no signature to compare, so a page
        // number out of CFG0 cannot be told from one out of a rolled-over page 0.
        // The refusal still stands; only the page it names is withheld.
        let rolloverIsDetectable = uid.flatMap(Type2Rollover.signature(forUID:)) != nil
        let prober = Type2PasswordDriver(layout: configLayout, uid: uid, transceive: transceive)
        switch try await prober.readState() {
        case .read(let config) where config.isGateArmed:
            throw TagError.permanentLockRefusedByGate(
                // `.setCredential`, not `.enable`. Nothing here is arming a
                // gate; this refuses a permanent lock because one is already up.
                // Filed as `.enable` the residue printed `intent=enable
                // goal=not-met` into a bug report about a lock, which sends the
                // next reader looking for a protection write that never happened.
                ProtectionResidue(
                    family: .type2,
                    intent: .setCredential,
                    gate: rolloverIsDetectable ? .provenArmed(fromPage: Int(config.auth0)) : .unknown,
                    completed: [.stateRead]
                ),
                diagnostics: "permanent lock refused: AUTH0=\(String(config.auth0, radix: 16)) gates "
                    + "the dynamic lock page. Remove the password first."
            )

        case .gatedByReadProtection:
            // The pages above the Capability Container are gated, which is proof
            // the gate is armed and no proof at all of where it starts.
            throw TagError.permanentLockRefusedByGate(
                ProtectionResidue(
                    family: .type2,
                    intent: .enable,
                    gate: .unknown,
                    completed: [.stateRead]
                ),
                diagnostics: "permanent lock refused: the pages above the Capability Container are "
                    + "read-gated, so AUTH0 could not be read. Remove the password first."
            )

        case .read:
            return
        }
    }

    /// What the dynamic lock page says about itself after a write.
    ///
    /// Three answers, because the write has three: the same read-back settles an
    /// acknowledged write's *verdict* and an unacknowledged write's *fact*, and
    /// only one of the two may treat "bits still clear" as harmless.
    private enum DynamicLockReadback {
        case allSet
        case notAllSet(reason: String)
        case unreadable
    }

    /// Read the dynamic lock page back and check every masked bit.
    ///
    /// The one stage with live evidence behind it: an NTAG213 written
    /// `A2 28 FF 0F 3F 00` reads back `FF 0F 3F BD` (see
    /// `docs/internal/chip-config-pages.md`), so byte 3 is the chip's own `BDh`
    /// and only the masked bits may be compared.
    private func readDynamicLockBits(_ page: Int, payload: Data) async -> DynamicLockReadback {
        guard let readBack = try? await readPage(page) else {
            return .unreadable
        }
        for offset in 0 ..< min(payload.count, readBack.count) {
            let mask = payload[payload.startIndex + offset]
            let got = readBack[readBack.startIndex + offset]
            if got & mask != mask {
                return .notAllSet(
                    reason: "byte \(offset) reads \(String(got, radix: 16)) with mask \(String(mask, radix: 16)) unset"
                )
            }
        }
        return .allSet
    }

    /// The verdict for a dynamic lock write the chip **acknowledged**. A
    /// read-back that disagrees does not turn an ACKed irreversible write into a
    /// failure; it withholds the proof and says why.
    private func verifyDynamicLock(_ page: Int, payload: Data) async -> PermanentLockOutcome.StageResult {
        switch await readDynamicLockBits(page, payload: payload) {
        case .allSet: .committedVerified
        case .notAllSet(let reason): .committedUnverified(reason: reason)
        case .unreadable: .committedUnverified(reason: "read-back could not be taken")
        }
    }

    // MARK: - Frames

    /// READ returns four pages; a lock write only ever needs the first.
    private func readPage(_ page: Int) async throws -> Data {
        let response = try await transceive(
            RawCommand(bytes: Data([Self.read, UInt8(page)]), name: "READ p\(page)")
        )
        guard response.count >= Self.pageSize else {
            throw TagError.malformedResponse(
                response, diagnostics: "READ p\(page) returned \(response.count)B"
            )
        }
        return Data(response.prefix(Self.pageSize))
    }

    /// What a lock write's answer established.
    ///
    /// A page write has three answers and only two of them are the chip's: an
    /// ACK, a stated refusal, and nothing at all. Collapsing the third into the
    /// second is what printed "Nothing was locked." over an irreversible write
    /// whose acknowledgement may simply have been dropped.
    private enum LockWriteAnswer {
        case acknowledged
        /// The chip answered, and the answer was not an ACK.
        case statedRefusal(diagnostics: String)
        /// No answer reached the reader.
        case noAnswer(diagnostics: String)
    }

    /// Send one lock write and classify the answer. Throws only on a caller
    /// error, which happens before a single byte reaches the transport.
    private func attemptWrite(_ page: Int, bytes: Data, label: String) async throws -> LockWriteAnswer {
        guard bytes.count == Self.pageSize else {
            throw TagError.protocolError(
                "\(label): page write must be 4 bytes", diagnostics: "len=\(bytes.count)"
            )
        }
        let response: Data
        do {
            response = try await transceive(
                RawCommand(bytes: Data([Self.write, UInt8(page)]) + bytes, name: "\(label) WRITE p\(page)")
            )
        } catch {
            // Three things look like this from here: a dropped frame, a tag that
            // left the field, and a NAK that this iOS version chose to surface as
            // a transport error rather than as a 1-byte payload (`CoreNFCSession`
            // documents both forms). The first two leave the write's fate open
            // and the third does not, and the caller is the one that decides how
            // to find out.
            return .noAnswer(diagnostics: "\(label) page=\(page): \(error)")
        }
        guard response.first == Self.ack else {
            return .statedRefusal(
                diagnostics: "WRITE not acknowledged \(label) page=\(page) resp=\(response.hexString)"
            )
        }
        return .acknowledged
    }

    // MARK: - Reading

    /// Read every lock unit this chip has and say what each one holds.
    ///
    /// Non-throwing on purpose: a lock verdict is never worth failing a scan
    /// for, so a tag that goes quiet yields `.notRead` rather than an error.
    ///
    /// - Parameter provenReadablePage: the highest page a READ has **already
    ///   been answered for on this activation**, or `nil` when nothing has been
    ///   proven. No frame is built for a page above it. Type-2 read gating is a
    ///   single monotone threshold (pages at or above AUTH0 are gated once PROT
    ///   is set), so a page at or below one this tag has just served cannot be
    ///   gated and the read cannot earn a NAK. A NAK halts the chip for the rest
    ///   of the activation, which is why the limit is structural here rather
    ///   than a rule every caller has to remember.
    ///
    /// The page numbers come from `ChipMemoryLayout` and the dynamic mask from
    /// `Type2LockWrite`, so the read compares against exactly what the write
    /// sets. Nothing here is a literal.
    public func readLockState(
        layout: ChipMemoryLayout,
        family: TagFamily,
        provenReadablePage: Int?
    ) async -> TagLockReading {
        var reading = TagLockReading()
        var notes: [String] = []

        // Dynamic first, matching the order `permanentLock` attempts them, so a
        // reading and an outcome read in the same sequence.
        if let dynamicPage = layout.dynamicLockPage {
            // The lock bits only. A block-locking bit locks a lock *bit*, not a
            // page, so a tag whose L bits are all set refuses every write
            // whether or not its BL bits were ever touched, and scoring an
            // encoder-locked tag against the full write mask reported a
            // completely write-protected tag as merely partly locked.
            let mask = Data(Type2LockWrite.dynamicLockBitsOnlyMask(for: family))
            await reading.record(.dynamicLock, readDynamicRegion(
                dynamicPage, mask: mask, provenReadablePage: provenReadablePage, notes: &notes
            ))
        } else {
            reading.record(.dynamicLock, .notPresent)
        }

        if let staticPage = layout.lockPages.first {
            await reading.record(.staticLock, readStaticRegion(
                staticPage, provenReadablePage: provenReadablePage, notes: &notes
            ))
        }

        reading.diagnostics = notes.joined(separator: "; ")
        return reading
    }

    /// The static lock bytes. A completed lock writes `FF FF` into
    /// `staticLockByteRange`, the same range the write uses, so the read and the
    /// write cannot disagree about which bytes are lock bits.
    private func readStaticRegion(
        _ page: Int,
        provenReadablePage: Int?,
        notes: inout [String]
    ) async -> TagLockFinding {
        guard let proven = provenReadablePage, page <= proven else {
            return .notRead(reason: "page \(page) is not proven readable on this activation")
        }
        guard let bytes = try? await readPage(page) else {
            notes.append("static lock page \(page): no answer")
            return .notRead(reason: "READ p\(page) went unanswered")
        }
        // Page 2 byte 0 is BCC1, a checksum of the second half of the UID, so a
        // reply that really is page 2 identifies itself. A read-protected chip
        // answers with a roll-over to page 0 instead, and nothing about the
        // shape of the frame distinguishes the two. Confirmed against the live
        // 2026-09-07 NTAG213 capture: UID 04:37:2E:12:6B:67:81 gives
        // BCC1 = 12^6B^67^81 = 9F, and page 2 read back `9F 48 FF FF`.
        if let signature = uid.flatMap(Type2Rollover.signature(forUID:)) {
            let bcc1 = signature[signature.startIndex + 8]
            guard bytes[bytes.startIndex] == bcc1 else {
                notes.append("static lock page \(page): reply does not carry BCC1, treating as a roll-over")
                return .notRead(reason: "READ p\(page) did not answer with page \(page)")
            }
        }
        let lock = Array(bytes[
            (bytes.startIndex + Self.staticLockByteRange.lowerBound) ..<
                (bytes.startIndex + Self.staticLockByteRange.upperBound)
        ])
        notes.append("static lock page \(page): \(Data(lock).hexString)")
        // Masked for the same reason the dynamic page is: bits 0-2 of LOCK0 are
        // block-locking bits, and a tag with every L bit set refuses every write
        // whether or not they were ever touched.
        return Self.score(Data(lock), against: Data(Type2LockWrite.staticLockBitsOnlyMask))
    }

    /// Compare a region's bytes against the bits a lock sets, and say how much
    /// of it is set.
    ///
    /// Bit-for-bit rather than by value, because on the dynamic page byte 3
    /// reads back as the chip's own `BDh` and NTAG215's second mask byte is
    /// entirely reserved: an equality test reports every correctly locked
    /// NTAG21x as unlocked.
    private static func score(_ bytes: Data, against mask: Data) -> TagLockFinding {
        var set = 0
        var clear = 0
        for offset in 0 ..< min(mask.count, bytes.count) {
            let bits = mask[mask.startIndex + offset]
            guard bits != 0 else { continue }
            let got = bytes[bytes.startIndex + offset] & bits
            if got == bits {
                set += 1
            } else if got == 0 {
                clear += 1
            } else {
                return .someSet
            }
        }
        if set == 0, clear == 0 {
            // A family whose mask is entirely zero has no lock bits this app
            // knows how to read, which is not the same as none being set.
            return .notRead(reason: "no lock-bit mask for this chip")
        }
        if clear == 0 {
            return .allSet
        }
        if set == 0 {
            return .noneSet
        }
        return .someSet
    }

    /// The dynamic lock page, compared **through the mask**.
    ///
    /// An equality test would report every correctly locked NTAG21x as unlocked:
    /// byte 3 is RFUI and reads back as the chip's own `BDh` without ever being
    /// written, and NTAG215's mask byte 1 is `0x00`. Only the bits a lock
    /// actually sets may be compared, which is why the mask is the write's own.
    private func readDynamicRegion(
        _ page: Int,
        mask: Data,
        provenReadablePage: Int?,
        notes: inout [String]
    ) async -> TagLockFinding {
        guard let proven = provenReadablePage, page <= proven else {
            return .notRead(reason: "page \(page) is not proven readable on this activation")
        }
        guard let bytes = try? await readPage(page) else {
            notes.append("dynamic lock page \(page): no answer")
            return .notRead(reason: "READ p\(page) went unanswered")
        }
        // No self-identifying byte on this page, so the roll-over check has to
        // be the negative one: a rolled-over reply starts with page 0.
        if let signature = uid.flatMap(Type2Rollover.signature(forUID:)),
           bytes.prefix(4) == signature.prefix(4)
        {
            notes.append("dynamic lock page \(page): reply is page 0, treating as a roll-over")
            return .notRead(reason: "READ p\(page) did not answer with page \(page)")
        }
        notes.append("dynamic lock page \(page): \(bytes.hexString) mask \(mask.hexString)")
        return Self.score(bytes, against: mask)
    }
}
