import Foundation
import HexNFCKit
import HexNFCRecords

/// What a safe pre-read established about a tag, before any flow asks it for
/// something it might refuse.
enum TagPresence: Equatable, Sendable {
    /// Not a page-addressed chip, so there is no cheap safe read to make. The
    /// caller keeps whatever behaviour it had before the probe existed.
    case unknown
    /// The tag served the pages just above the Capability Container.
    case answered
    /// The tag rolled a READ over to page 0 instead of serving them: the pages
    /// above the CC are gated. This is the one *positive* proof of read
    /// protection the transport offers.
    case readProtected
    /// Nothing came back.
    case silent
}

/// What one safe pre-read returned: the verdict, and the bytes behind it.
///
/// `pages3to6` is non-`nil` only for `.answered`, because that is the only
/// verdict under which the bytes are what they claim to be. A roll-over serves
/// pages 0 and 1 at page 3's address, and a silent tag serves nothing.
struct TagPreread: Equatable, Sendable {
    let presence: TagPresence
    let pages3to6: Data?
    /// No roll-over occurred anywhere in the served frame, so pages 4, 5 and 6
    /// are those pages and not page 0 wearing their addresses.
    ///
    /// Stronger than "the eight-byte signature did not match at page 4", which is
    /// all the presence verdict checks and which only detects `AUTH0 == 4`. The
    /// chip wraps at whatever page is first unreadable, so `AUTH0 = 5` serves
    /// pages 3, 4, 0, 1 and `AUTH0 = 6` serves 3, 4, 5, 0. Each of those leaves
    /// page 0 at a different offset, and each has to be looked for separately.
    ///
    /// `false` whenever nothing established it, including every tag without a
    /// 7-byte UID, because a roll-over cannot be recognised without one.
    let dataAreaProvenContiguous: Bool

    init(presence: TagPresence, pages3to6: Data? = nil, dataAreaProvenContiguous: Bool = false) {
        self.presence = presence
        self.pages3to6 = pages3to6
        self.dataAreaProvenContiguous = dataAreaProvenContiguous
    }

    /// The whole NDEF chain, terminator included, was served inside pages 4 to 6
    /// **and** those pages are proven to be themselves.
    ///
    /// This is the only combination that disproves gating: it says a reader had
    /// everything it needed before anything went wrong, so a failure afterwards
    /// is not the tag refusing pages it had not served. A longer message whose
    /// terminator sits past page 6 answers `false`, and so it should: that read
    /// really might have been cut short by a gate at page 7 or beyond.
    var provesTheNDEFChainWasNotGated: Bool {
        guard dataAreaProvenContiguous, let pages3to6, pages3to6.count >= 16 else { return false }
        return Type2NDEF.chainCompletes(within: Data(pages3to6[4 ..< 16]))
    }

    /// The Capability Container page as the tag served it, or `nil` when nothing
    /// proved it was that page.
    var capabilityContainer: Data? {
        guard let pages3to6, pages3to6.count >= 4 else { return nil }
        return Data(pages3to6.prefix(4))
    }

    /// Pages 4 and 5, the start of the NDEF data area. Eight bytes because that
    /// is where a Type-2 tag's whole opening TLV chain lives on the chips this
    /// app writes: a factory NTAG213 reads `01 03 A0 0C 34 03 00 FE`, a Lock
    /// Control TLV followed by an empty NDEF message and the terminator.
    var dataAreaPrologue: Data? {
        guard let pages3to6, pages3to6.count >= 12 else { return nil }
        return Data(pages3to6[4 ..< 12])
    }
}

/// The evidence behind a protection-state read, keeping the three answers apart
/// that a plain `try?` collapses into one.
enum ProtectionReading {
    /// The read succeeded. `nil` means the chip has no protection backend, which
    /// is a fact about the chip, not a failure.
    ///
    /// `provenReadablePage` is the highest page a READ was actually answered for
    /// while establishing this, or `nil` when nothing was proven. It is what
    /// lets a later read know which pages it may address without risking a NAK,
    /// and it travels with the reading rather than being recomputed, because the
    /// two would drift.
    case state(TagProtection?, provenReadablePage: Int?)
    /// The tag refused, and went quiet the way a refusal makes it go quiet.
    case refused(TagError)
    /// The tag stopped answering. Nothing about protection was established.
    case lost(TagError)
}

/// Reads a tag's protection state and says how much the answer is worth.
///
/// The rule this type exists to enforce is the mirror of the project's "an ACK
/// is not proof": **a refusal is not proof either.** A config-page read that
/// fails can mean the tag is read-protected — or that it slipped out of the
/// field for a moment. Both arrive as the same `.tagLost`, and both flows used
/// to guess, in opposite directions: the scan flow reported "Unknown", and the
/// write flow told the user their tag was password-protected and asked for a
/// password it never had. The second is the harmful one. It reads as "the app
/// silently locked my tag".
///
/// So separate the two with behaviour rather than a guess:
///
/// - Page 3 (the Capability Container) sits below every AUTH0 this app writes,
///   so asking for it can never trip protection.
/// - A refused command NAKs, and a NAK returns a Type-2 tag to HALT for the rest
///   of the activation. A tag that still answers page 3 after a failed read
///   therefore never refused anything, and the failure was transport: retry it.
/// - A tag that has gone quiet either halted (it refused) or left the field. The
///   pre-read tells us which was more likely, and the roll-over signature settles
///   it outright when it is present.
enum ProtectionProbe {
    /// Read the four pages a Type-2 READ serves from page 3 and classify what
    /// came back. Costs one frame and cannot halt the tag.
    static func presence(of tag: ConnectedTag) async -> TagPresence {
        await preread(of: tag).presence
    }

    /// The same single `30 03`, handing back the bytes as well as the verdict.
    ///
    /// The verdict needs only pages 4 and 5, so `presence(of:)` used to discard
    /// the other eight bytes, page 3 among them. Page 3 is the Capability
    /// Container, and it is the one page that says whether a refused NDEF read
    /// means "format this tag" or "the data area is the problem". The scan was
    /// answering that question from the chip's catalogue entry instead, one
    /// statement after having the real bytes in hand. Carrying them costs
    /// nothing: it is the same frame either way. See `TagFormatState`.
    static func preread(of tag: ConnectedTag) async -> TagPreread {
        guard let chip = tag.chip, case .type2 = chip.family,
              chip.capabilities.contains(.memoryRead) else { return TagPreread(presence: .unknown) }
        // Four pages from the Capability Container: a single `30 <ccPage>`.
        //
        // The page number comes from the chip's own layout rather than a `12`
        // spelled here. It is 3 on every Type-2 profile in the catalogue, so
        // this changes no frame today; it stops the number being spelled twice
        // in a file that now decides a user-visible verdict from what comes back.
        // `nil` means this chip keeps no Capability Container in a page, so
        // there is no cheap safe read to make and nothing to classify.
        let layout = chip.memoryLayout
        guard let ccPage = layout.ccPage else { return TagPreread(presence: .unknown) }
        let start = ccPage * layout.pageSize
        let span = 4 * layout.pageSize
        guard let bytes = try? await tag.readMemory(range: start ..< (start + span)),
              bytes.count == span
        else {
            return TagPreread(presence: .silent)
        }
        // The bytes travel only when the roll-over check could actually run.
        //
        // `rolloverSignature(forUID:)` needs a 7-byte UID to derive what a rolled-over
        // read would look like, and answers `nil` for anything else. Before the
        // Capability Container rode out of here that cost only the protection
        // verdict. Now it would cost more: a cloned NTAG21x with a short UID,
        // read-protected so a READ of page 3 rolls over, would hand page 0 on as
        // its Capability Container, `E1` would be absent from `SN0 SN1 SN2 BCC0`,
        // and the scan would report "no Capability Container" and point the user
        // at a Format. Page 3 is OTP. That is the one wrong answer here that
        // cannot be taken back.
        //
        // So the presence verdict stands either way, and the bytes are withheld
        // unless something proved they are page 3.
        guard let rolled = rolloverSignature(forUID: tag.uid) else {
            return TagPreread(presence: .answered)
        }
        let afterCC = bytes.startIndex + layout.pageSize
        if Data(bytes[afterCC ..< (afterCC + 2 * layout.pageSize)]) == rolled {
            // A roll-over, so these are pages 0 and 1 wearing page 3's address.
            // Handing them on as a Capability Container is exactly the mistake
            // this whole probe exists to stop.
            return TagPreread(presence: .readProtected)
        }
        // That check finds a wrap only where it starts at page 4, which is the
        // one `AUTH0` value it was written for. A gate at page 5 or 6 wraps later
        // in the same frame and leaves page 0 at a different offset, so look for
        // it at each one before claiming these pages are themselves.
        let page0 = Data(rolled.prefix(layout.pageSize))
        let contiguous = !stride(
            from: layout.pageSize,
            to: 4 * layout.pageSize,
            by: layout.pageSize
        ).contains { offset in
            let start = bytes.startIndex + offset
            return Data(bytes[start ..< (start + layout.pageSize)]) == page0
        }
        return TagPreread(presence: .answered, pages3to6: bytes, dataAreaProvenContiguous: contiguous)
    }

    /// Read the protection state, retrying or refusing on evidence rather than
    /// on assumption. `presence` is the verdict from `presence(of:)`, taken at
    /// the top of the session and before any command that could be refused.
    ///
    /// `allowWriteProbe` is passed through to `readProtectionState`: on a SLIX2
    /// the state is established by attempting a write, and the identify tap of a
    /// confirmed write has told the user it is only reading.
    /// - Parameter credentialAlreadyProven: the tag accepted a credential earlier
    ///   in this same activation. Only the caller that sent it knows, and it
    ///   rules a refusal out: a chip that answered `PWD_AUTH` with a PACK is
    ///   authenticated, so it cannot then refuse its own configuration pages for
    ///   want of authentication. Whatever stopped the read, it was not the gate.
    static func read(
        from tag: ConnectedTag,
        presence: TagPresence,
        allowWriteProbe: Bool = true,
        credentialAlreadyProven: Bool = false
    ) async -> ProtectionReading {
        // The roll-over already proved the pages above the CC are gated, and the
        // config pages sit above them. Sending the read anyway would only earn a
        // NAK and halt the tag for the rest of the activation.
        if presence == .readProtected {
            return .refused(TagError.authFailed(
                diagnostics: "READ rolled over to page 0: pages above the CC are read-protected"
            ))
        }
        do {
            let state = try await tag.readProtectionState(allowWriteProbe: allowWriteProbe)
            return .state(state, provenReadablePage: provenReadablePage(for: tag, presence: presence, state: state))
        } catch {
            let failure = (error as? TagError) ?? .tagLost(diagnostics: "\(error)")
            switch await Self.presence(of: tag) {
            case .readProtected:
                // It refused because it is protected — now demonstrated.
                return .refused(failure)

            case .answered:
                // Still serving the pages it never gates, so it did not halt, so
                // nothing refused us. The read is owed a second attempt.
                if let state = try? await tag.readProtectionState(allowWriteProbe: allowWriteProbe) {
                    return .state(
                        state,
                        provenReadablePage: provenReadablePage(for: tag, presence: .answered, state: state)
                    )
                }
                return .lost(failure)

            case .unknown:
                // No page-addressed memory, so no safe read, so no evidence to
                // weigh. A second attempt still costs nothing; past that, keep
                // the reading these families (Type-4, Type-5) had before this
                // type existed and let the refusal stand. The improvement here
                // is Type-2's, because Type-2 is where the proof lives.
                if let state = try? await tag.readProtectionState(allowWriteProbe: allowWriteProbe) {
                    return .state(state, provenReadablePage: nil)
                }
                return .refused(failure)

            case .silent:
                // Halted, or gone. A tag that was answering a moment ago and has
                // stopped is most likely halted by its own NAK; one that was
                // never answering tells us nothing.
                //
                // Unless a credential was already accepted on this activation,
                // which settles it the other way. The gate cannot refuse a chip
                // that is authenticated to it, so "halted by its own NAK" is not
                // on the table and the tag has simply gone. Measured on an
                // NTAG213 on 2026-09-22: `PWD_AUTH` returned a PACK, the very
                // next `READ p41` came back "Tag connection lost", and the owner
                // was told to re-enter a password the chip had just accepted.
                // That is the invitation to spend another try against `AUTH_LIM`,
                // on a counter the app cannot see.
                if credentialAlreadyProven {
                    return .lost(failure)
                }
                return presence == .silent ? .lost(failure) : .refused(failure)
            }
        }
    }

    /// The highest page a READ has been answered for on this activation.
    ///
    /// Computed from the reading that came back, never from `presence` alone.
    /// `Type2PasswordDriver.readState()` synthesises a `TagProtection` for a
    /// read-gated tag **without reading the configuration pages**, so a
    /// `.state(...)` on its own is not proof that any page above the Capability
    /// Container answered. Getting that backwards is how a later read would send
    /// a frame at a gated page, earn a NAK, and halt the chip for the rest of
    /// the tap.
    ///
    /// The one page every branch here can vouch for is page 3: the presence
    /// probe served it a moment ago, and it sits below every AUTH0 this app
    /// writes. Anything higher has to have been read for real.
    private static func provenReadablePage(
        for tag: ConnectedTag, presence: TagPresence, state: TagProtection?
    ) -> Int? {
        guard presence == .answered else { return nil }
        guard let chip = tag.chip, case .type2(let variant) = chip.family else { return nil }
        let ccPage = 3
        // A read-gated answer is synthesised, so the configuration read never
        // went out and nothing above the CC is proven.
        guard state?.effectiveReadProtect != true else { return ccPage }
        if variant == .mifareUltralightC {
            // `UltralightCProtectionDriver.readConfiguration()` sends `30 28`,
            // and page 28h *is* this chip's dynamic lock page, so a
            // configuration that came back is proof that exact page was served.
            return state == nil ? ccPage : UltralightCLayout.lockBytes23Page
        }
        // `30 <config0Page>` only went out if a password driver existed to send
        // it; a nil state means it did not, so no frame was answered.
        if state != nil, tag.capabilities.contains(.passwordAuth),
           let config = chip.type2ConfigLayout
        {
            return config.config0Page
        }
        return ccPage
    }

    /// Pages 0 and 1 of a 7-byte-UID Type-2 tag, rebuilt from the UID alone:
    /// page 0 is `SN0 SN1 SN2 BCC0` where `BCC0 = 0x88 ^ SN0 ^ SN1 ^ SN2`, and
    /// page 1 is `SN3 SN4 SN5 SN6` (NTAG213 rev 3.2 §8.5.1, ISO 14443-3 cascade
    /// level 1). Checked against the live 2026-08-14 capture: UID
    /// `04 BA 4A 92 1B 21 90` gives `BCC0 = 0x88 ^ 04 ^ BA ^ 4A = 7C`, and the
    /// rolled-over frame carried `04 BA 4A 7C | 92 1B 21 90`.
    ///
    /// Deriving them costs nothing and makes the match eight bytes wide, so
    /// ordinary record data landing on the signature is not a practical concern.
    /// `nil` for any tag without a 7-byte UID, which simply skips the check.
    static func rolloverSignature(forUID uid: Data) -> Data? {
        guard uid.count == 7 else { return nil }
        let sn = [UInt8](uid)
        let bcc0 = 0x88 ^ sn[0] ^ sn[1] ^ sn[2]
        return Data([sn[0], sn[1], sn[2], bcc0, sn[3], sn[4], sn[5], sn[6]])
    }
}
