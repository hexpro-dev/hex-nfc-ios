import Foundation
import HexNFCRecords

/// Where MIFARE Ultralight C keeps its authentication configuration.
///
/// The single source of truth for these page numbers, playing the role
/// `Type2ConfigLayout` plays for the NTAG21x line. It is separate because
/// `Type2ConfigLayout.for(.mifareUltralightC)` deliberately returns `nil`:
/// handing this chip a Type-2 layout would route it to the PWD/PACK backend,
/// which cannot drive it. `UltralightCTests` asserts these agree with the
/// `ChipMemoryLayout` in `ChipCatalog`, the same guard `TagProtectionTests`
/// applies to the Type-2 family.
///
/// A wrong page number here bricks real tags. Verified against NXP MF0ICU2
/// rev 3.3 §7.5 Table 5; see `docs/internal/chip-config-pages.md`.
public enum UltralightCLayout {
    /// AUTH0 lives in **byte 0** of this page, not byte 3 as on NTAG21x.
    public static let auth0Page = 42 // 0x2A
    /// AUTH1 lives in **byte 0** of this page.
    public static let auth1Page = 43 // 0x2B
    /// The 16-byte key spans these four pages. **Write-only, and not decoded
    /// for reads at all**: a READ addressing them returns a NAK rather than
    /// masked zeros (live-confirmed 2026-08-07), and a NAK halts a Type-2 tag
    /// for the rest of the activation. Never read into this range.
    public static let keyPages = 44 ... 47 // 0x2C…0x2F
    /// Lock bytes 2-3. Also the safe starting page for a configuration read:
    /// `30 28` returns 28h-2Bh, entirely inside the read-decoded region.
    public static let lockBytes23Page = 40 // 0x28
    /// How many bytes of `lockBytes23Page` are actually lock bits: **two**
    /// (rev 3.3 §7.5.3). Bytes 2-3 are RFU.
    ///
    /// A permanent lock must not set them. Live-observed 2026-08-07: the chip
    /// ACKed `A2 28 FF FF FF 00` and then read back `FF FF 00 00`, so the RFU
    /// write was discarded — nothing announces the mistake either way. The
    /// payload itself lives in `Type2LockWrite`, which carries the equivalent
    /// per-chip masks for the NTAG21x family.
    public static let dynamicLockByteCount = 2
    /// Pages a plain READ may address (00h-2Bh). Reads are not decoded above
    /// this (MF0ICU2 rev 3.5 §7.5 "only addresses 00h to 2Bh are decoded for
    /// read operations").
    public static let readDecodedPageCount = 44
    /// Byte offset of AUTH0 / AUTH1 within their pages.
    public static let configByteOffset = 0

    /// AUTH0 value that disables protection entirely, and the delivery default.
    /// Also the first page address past the end of memory, which is how the
    /// chip expresses "nothing is covered".
    public static let protectionOff: UInt8 = 0x30
    /// Lowest page AUTH0 may cover (rev 3.3 §7.5.8).
    public static let minimumProtectFromPage: UInt8 = 0x03

    /// AUTH1 bit 0. **Inverted relative to the NTAG21x `PROT` bit**: here the
    /// bit being *set* means write-only, and *clear* means read+write
    /// restricted (rev 3.3 Table 12). Bits 1-7 are ignored by the chip.
    public static let auth1WriteOnlyBit: UInt8 = 0x01
    /// AUTH1 as the chip ships (rev 3.3 Table 13). Inert while AUTH0 is `30h`,
    /// and what `disable` restores so a cleared tag really is at delivery state.
    public static let auth1AtDelivery: UInt8 = 0x00
}

/// The two authentication-configuration bytes, decoded.
///
/// Exists so the AUTH1 polarity inversion is converted in exactly one place. A
/// blind port of the NTAG21x code applies the *opposite* protection level to
/// the one the user asked for, silently, and only on real silicon.
public struct UltralightCConfiguration: Hashable, Sendable {
    /// Raw AUTH0: first page (≥) requiring authentication. `0x30` = off.
    public let auth0: UInt8
    /// Raw AUTH1 byte, as read from the tag.
    public let auth1: UInt8

    public init(auth0: UInt8, auth1: UInt8) {
        self.auth0 = auth0
        self.auth1 = auth1
    }

    /// `true` when any page is actually covered. AUTH0 values above `0x30` are
    /// out of the documented range but still mean "nothing protected", so this
    /// compares `>=` rather than `==` and cannot be fooled by an odd value.
    public var isProtected: Bool {
        auth0 < UltralightCLayout.protectionOff
    }

    /// `true` when reads are gated as well as writes. Only meaningful while
    /// `isProtected`, since AUTH1 is ignored by the chip when AUTH0 is `0x30`.
    public var readProtect: Bool {
        isProtected && (auth1 & UltralightCLayout.auth1WriteOnlyBit) == 0
    }

    /// First protected page, or `nil` when protection is off.
    public var protectFromPage: Int? {
        isProtected ? Int(auth0) : nil
    }

    /// Encode the requested access level into an AUTH1 byte. The inversion
    /// lives here and nowhere else.
    public static func auth1(readProtect: Bool) -> UInt8 {
        readProtect ? 0x00 : UltralightCLayout.auth1WriteOnlyBit
    }

    /// Project into the app-wide settings type.
    public var protection: TagProtection {
        TagProtection(
            passwordProtect: isProtected,
            style: .ultralightC(.init(protectFromPage: protectFromPage, readProtect: readProtect))
        )
    }
}

/// Drives MIFARE Ultralight C's 3DES mutual authentication and its AUTH0/AUTH1
/// configuration over a raw `transceive` closure.
///
/// Structured like `NTAG424ProtectionDriver` rather than the Type-2 path: one
/// `transceive`-driven struct, so production (`CoreNFCConnectedTag`) and the
/// simulator run the *same* code and a divergence is a real signal rather than
/// a difference between two implementations.
///
/// Protocol (NXP MF0ICU2 rev 3.3 §7.5.5, Table 8):
///
///     PCD  → 1A 00
///     PICC → AF ‖ ek(RndB)                     8 bytes
///     PCD  → AF ‖ ek(RndA ‖ RndB′)             16 bytes, RndB′ = RndB rotated left 1 byte
///     PICC → 00 ‖ ek(RndA′)                    8 bytes, RndA′ = RndA rotated left 1 byte
///
/// `ek()` is 2-key 3DES in **CBC encrypt** mode. First IV is the all-zero
/// block; each subsequent operation chains from the previous ciphertext block.
/// Note this is *not* the DESFire "legacy" convention where the reader
/// deciphers to send, and getting that backwards makes every authentication
/// fail with no useful diagnostic. Verified numerically against the datasheet's
/// own §7.5.6 Table 9 vector in `UltralightCCryptoTests`.
public struct UltralightCProtectionDriver: Sendable {
    /// Raw command channel: production wires `CoreNFCConnectedTag.transceive`,
    /// tests wire the simulator. Responses include the leading status byte.
    public let transceive: @Sendable (RawCommand) async throws -> Data
    /// Injectable randomness so a test can pin RndA and reproduce a datasheet
    /// vector exactly.
    public let makeRandom: @Sendable (Int) -> Data

    public init(
        transceive: @escaping @Sendable (RawCommand) async throws -> Data,
        makeRandom: @escaping @Sendable (Int) -> Data = { count in
            Data((0 ..< count).map { _ in UInt8.random(in: 0 ... 255) })
        }
    ) {
        self.transceive = transceive
        self.makeRandom = makeRandom
    }

    static let authenticateCommand: UInt8 = 0x1A
    static let continueCommand: UInt8 = 0xAF
    static let successStatus: UInt8 = 0x00
    static let blockSize = 8

    // MARK: - Authentication

    /// Run the full 3DES mutual handshake. Returns the 8-byte `RndA` on
    /// success, which is the session's shared secret material and is what
    /// proves *the card* holds the key (the second half of "mutual").
    ///
    /// Throws `.authFailed` when the card rejects our token or when its final
    /// cryptogram doesn't verify. The latter matters: a card that answers but
    /// fails verification is either keyed differently or not a genuine MF0ICU2,
    /// and accepting it would mean trusting an unauthenticated tag.
    @discardableResult
    public func authenticate(key: UltralightCKey) async throws -> Data {
        // Leg 1: ask for the challenge.
        let challenge = try await transceive(
            RawCommand(bytes: Data([Self.authenticateCommand, 0x00]), name: "AUTHENTICATE")
        )
        guard challenge.count >= 1 + Self.blockSize,
              challenge[challenge.startIndex] == Self.continueCommand
        else {
            throw TagError.authFailed(
                diagnostics: "AUTHENTICATE (1A 00) expected AF + 8 bytes, got \(challenge.count) "
                    + "byte(s): \(challenge.hexString). A bare NAK here means the chip has no "
                    + "3DES authentication, so it is not an Ultralight C."
            ).afterPresentingACredential()
        }
        let ekRndB = Data(challenge.dropFirst().prefix(Self.blockSize))

        let zeroIV = Data(repeating: 0, count: Self.blockSize)
        let rndB = try EMRTDCrypto.tripleDESCBCDecrypt(key: key.cipherOrder, iv: zeroIV, data: ekRndB)
        let rndBPrime = NTAG424Crypto.rotateLeftByOne(rndB)

        let rndA = makeRandom(Self.blockSize)
        // IV chains from the ciphertext we just received, per ISO/IEC 10116.
        let token = try EMRTDCrypto.tripleDESCBCEncrypt(
            key: key.cipherOrder, iv: ekRndB, data: rndA + rndBPrime
        )

        // Leg 2: prove we hold the key, and challenge the card in the same frame.
        let response = try await transceive(
            RawCommand(bytes: Data([Self.continueCommand]) + token, name: "AUTHENTICATE part 2")
        )
        guard response.count >= 1 + Self.blockSize,
              response[response.startIndex] == Self.successStatus
        else {
            throw TagError.authFailed(
                diagnostics: "card rejected the authentication token (response "
                    + "\(response.hexString)). Wrong key, or the key was written to pages "
                    + "2Ch-2Fh in the wrong byte order."
            ).afterPresentingACredential()
        }

        // Verify the card's half of the handshake.
        let ekRndAPrime = Data(response.dropFirst().prefix(Self.blockSize))
        let chainIV = Data(token.suffix(Self.blockSize))
        let rndAPrime = try EMRTDCrypto.tripleDESCBCDecrypt(
            key: key.cipherOrder, iv: chainIV, data: ekRndAPrime
        )
        guard rndAPrime == NTAG424Crypto.rotateLeftByOne(rndA) else {
            throw TagError.authFailed(
                diagnostics: "card's final cryptogram did not verify: it answered the handshake "
                    + "but does not hold the same key. Not a genuine MF0ICU2, or a clone that "
                    + "stubs AUTHENTICATE."
            ).afterPresentingACredential()
        }
        return rndA
    }

    // MARK: - Configuration

    /// Read AUTH0 and AUTH1. Read-only, and safe on an unprotected tag.
    ///
    /// Both bytes sit in pages the chip lets anyone read while AUTH0 is above
    /// them, which is the normal case; once read-protection is armed this needs
    /// a prior `authenticate`.
    public func readConfiguration() async throws -> UltralightCConfiguration {
        // Read from page 28h, **not** from AUTH0 at 2Ah.
        //
        // One READ returns four pages, so starting at 2Ah would span 2Ah-2Dh and
        // reach into the key pages, which this chip does not decode for reads at
        // all (live-confirmed 2026-08-07: `30 2C` → `00`, a NAK). Whether a read
        // that *starts* in decoded space and runs past 2Bh rolls over or NAKs is
        // not something we have established on silicon, and a NAK would HALT the
        // tag for the rest of the activation. Starting at 28h covers
        // 28h-2Bh, entirely inside the decoded region, so the question never
        // arises. That exact frame is the one the live capture used.
        let start = UInt8(UltralightCLayout.lockBytes23Page)
        let response = try await transceive(
            RawCommand(bytes: Data([0x30, start]), name: "READ AUTH0/AUTH1")
        )
        guard response.count >= 16 else {
            throw TagError.malformedResponse(
                response,
                diagnostics: "READ of page \(start) returned \(response.count) bytes, expected 16"
            )
        }
        // Pages returned are 28h, 29h, 2Ah, 2Bh — AUTH0 and AUTH1 are the third
        // and fourth, at byte 0 of each.
        let bytes = [UInt8](response)
        let auth0Offset = (UltralightCLayout.auth0Page - UltralightCLayout.lockBytes23Page) * 4
        let auth1Offset = (UltralightCLayout.auth1Page - UltralightCLayout.lockBytes23Page) * 4
        return UltralightCConfiguration(
            auth0: bytes[auth0Offset + UltralightCLayout.configByteOffset],
            auth1: bytes[auth1Offset + UltralightCLayout.configByteOffset]
        )
    }

    /// Current protection state as the app-wide settings type, or `nil` if the
    /// configuration could not be read.
    public func readProtectionState() async throws -> TagProtection? {
        try await readConfiguration().protection
    }

    // MARK: - Enable / disable

    /// Personalise the tag: disarm AUTH0, write `key`, set the access mode, then
    /// arm AUTH0.
    ///
    /// ## Why AUTH0 comes **down** before the key is written
    ///
    /// The 16-byte key is four independent page WRITEs (2Ch, 2Dh, 2Eh, 2Fh) and
    /// this chip has no factory reset. The previous order wrote those four pages
    /// while the *old* AUTH0 was still armed, so a tag lifted off the phone
    /// between two of them left `old[0..7] ‖ new[8..15]` behind a live gate: a
    /// key nobody holds, on a tag nobody can ever open again. There is no
    /// recovery from that state, because the key pages are not decoded for reads
    /// at all (MF0ICU2 rev 3.5 §7.5, live-confirmed 2026-08-07: `30 2C` → NAK),
    /// so the scramble cannot even be observed, let alone undone.
    ///
    /// Clearing AUTH0 first turns that same abort into an **unprotected** tag
    /// carrying a scrambled key, which the next tap simply overwrites. The
    /// window where the tag is unprotected is the price, and it is the right
    /// price: an unprotected tag is a recoverable tag.
    ///
    /// ## Why an unprotected tag is never sent an `AUTHENTICATE`
    ///
    /// State first, exactly as `Type2PasswordDriver` does it. A refused `1A 00`
    /// answers with a bare NAK, and a NAK returns a Type-2 tag to HALT for the
    /// rest of the activation (docs/internal/chip-config-pages.md, live
    /// 2026-08-07). The mid-key abort above leaves a key nobody knows, so
    /// authenticating on the recovery tap would halt the very session that was
    /// going to fix it. A tag whose own AUTH0 reads `30h` gates nothing, so
    /// there is nothing to authenticate past, and the handshake is skipped.
    ///
    /// ## Abort points
    ///
    /// `AUTH0'` is the requested value; `K` is the new key. Every row's state is
    /// what the *next* activation sees.
    ///
    /// | # | Abort after | Tag state | Recovery |
    /// |---|---|---|---|
    /// | U0 | before anything | AUTH0 = old, key = old | re-run; the state read finds it |
    /// | | | | protected and authenticates as before |
    /// | U1 | AUTHENTICATE | unchanged | as U0 |
    /// | U2 | `A2 2A 30` (gate down) | **unprotected**, key = old | re-run; sends **no** AUTHENTICATE, |
    /// | | | | writes the key and arms |
    /// | U3 | 1-3 of the 4 key pages | unprotected, key = a scramble | re-run; sends no AUTHENTICATE and |
    /// | | | nobody holds | rewrites all four key pages over the |
    /// | | | | scramble |
    /// | U4 | the 4th key page | unprotected, key = `K` | re-run; the tag is open, so any |
    /// | | | (in force from the next activation) | `currentKey` gets there |
    /// | U5 | `A2 2B <AUTH1>` | unprotected, key = `K`, AUTH1 inert | as U4 |
    /// | U6 | `A2 2A AUTH0'` | protected by `K` | complete; the read-back proves it |
    /// | U7 | the read-back | complete | n/a |
    ///
    /// U3 is the row the reorder exists for. Under the old order that same abort
    /// left the scramble behind a live gate, permanently.
    ///
    /// At no point is the tag gated behind a credential nobody holds. That is
    /// the property the old order could not state, and it is the whole reason
    /// this method looks the way it does.
    ///
    /// ## What this cannot prove, and why
    ///
    /// The key is never proven in this activation. The key pages cannot be read
    /// back at all, and the two ways to prove a key by using it are both closed:
    /// a second `AUTHENTICATE` in one activation is refused (live 2026-08-07),
    /// and a re-programmed key "is only valid for authentication after a RF
    /// reset or a re-activation" (MF0ICU2 rev 3.3 §7.5.7 remark), so even the
    /// first handshake could not use it. The residue therefore reports the
    /// credential as `.callerSupplied` (written, and every page acknowledged)
    /// with a recorded failure against `.credentialProven` naming the reason.
    /// Proving it needs a second tap, which is a caller-level flow, not a
    /// driver-level one.
    ///
    /// Pass `alreadyAuthenticated` when this activation has already completed a
    /// handshake. **A second `AUTHENTICATE` is refused and the refusal halts the
    /// tag**, so getting this wrong does not merely waste a frame, it ends the
    /// session. Callers that go through `ConnectedTag.enableProtection` get it
    /// from `UltralightCSessionHolder` automatically.
    ///
    /// ## The read gate is refused without `armReadGateUnrecoverably`
    ///
    /// `readProtect` clears AUTH1 bit 0, which puts the gate over pages 28h-2Bh
    /// whenever AUTH0 sits at or below 28h. Those are the pages
    /// `ChipCatalog.identify(preEV1PageZero:configPages:)` reads to recognise this
    /// chip at all, and both answers a gated tag can give lose: a NAK leaves
    /// `configPages` nil and its guard returns nil, and a roll-over echoes page 0
    /// and trips its echo guard, which also returns nil. No profile means no
    /// `protectionStyle`, and `protectionStyle != nil` is the single condition
    /// that opens the unlock route (`WriteFlowModel`), so the key the user wrote
    /// down can never be presented.
    ///
    /// The gate itself is reversible on silicon, with the key. What is lost is
    /// this app's ability to find the chip, which is why the flag says
    /// unrecoverable rather than irreversible. Nothing in the shipping app passes
    /// it, and that is the point: the same shape as
    /// `Iso15693ProtectionClient.enable`'s `armPrivacyIrreversibly`.
    @discardableResult
    public func enable(
        key: UltralightCKey,
        protectFromPage: Int,
        readProtect: Bool,
        currentKey: UltralightCKey,
        alreadyAuthenticated: Bool = false,
        armReadGateUnrecoverably: Bool = false
    ) async throws -> ProtectionResidue {
        let auth0 = UInt8(clamping: protectFromPage)
        guard auth0 >= UltralightCLayout.minimumProtectFromPage,
              auth0 < UltralightCLayout.protectionOff
        else {
            // Range-checked before a single frame goes out, so a bad request
            // cannot leave the tag part-way through the sequence.
            throw TagError.protocolError(
                "Protect-from page is out of range for this chip",
                diagnostics: "AUTH0 must be 0x03…0x2F to protect anything (0x30 disables "
                    + "protection); got 0x\(String(format: "%02X", auth0)) from page "
                    + "\(protectFromPage)"
            )
        }

        // Refused unless the caller has taken ownership of the recovery, and
        // refused before a single frame goes out for the same reason the range
        // check above is. The reason is in this method's doc comment: this app
        // cannot identify a read-gated Ultralight C, so it can never present the
        // key that opens one.
        //
        // The message is written out rather than taken from a convenience
        // constructor, because both of the obvious ones are false here.
        // `capabilityUnsupported` says "This tag does not support that
        // operation", and the tag supports it perfectly well.
        // `protocolError` says "The tag responded outside the expected
        // protocol", and the tag has not responded at all: this throws before a
        // frame goes out. The app is declining, and saying so plainly is the
        // difference between a true sentence and a convenient one.
        guard !readProtect || armReadGateUnrecoverably else {
            throw TagError(
                kind: .protocolError,
                userMessage: "Hex NFC can protect this tag against writing, but not against reading.",
                diagnostics: "an Ultralight C read gate is not reachable from ordinary protection: with "
                    + "AUTH0 at or below 28h and AUTH1 bit 0 clear, the configuration read that "
                    + "identifies this chip is gated, so nothing afterwards can identify the tag or "
                    + "present the key that opens it. Pass armReadGateUnrecoverably from a flow that "
                    + "owns the recovery."
            )
        }

        var residue = ProtectionResidue(family: .ultralightC, intent: .enable)
        let config: UltralightCConfiguration
        do {
            config = try await readConfiguration()
        } catch {
            // The only thing that gates pages 28h-2Bh is read protection, so a
            // tag that will not serve `30 28` is a read-protected tag. It cannot
            // be recovered inside this activation: the refusal is a NAK and the
            // NAK halts the chip. Say so precisely, because the fix is a
            // different tap rather than a retry of this one.
            throw TagError.readProtected(
                diagnostics: "the configuration pages would not answer, which on this chip means "
                    + "reads are gated. Unlock the tag first, then apply protection in the same "
                    + "activation (pass alreadyAuthenticated). \(error)"
            )
        }
        residue.record(.stateRead)

        var authenticatedThisActivation = alreadyAuthenticated
        if config.isProtected {
            if !alreadyAuthenticated {
                try await authenticate(key: currentKey)
                authenticatedThisActivation = true
            }
            residue.record(.gateOpened)

            // Gate down first, and read it back before anything irreversible
            // happens. If AUTH0 did not come down, the key pages are still
            // gated, so writing the key here is the mid-key brick this method
            // exists to prevent. Nothing but AUTH0 has been touched at this
            // point, so the tag is exactly as it was found.
            try await writeConfigByte(
                page: UltralightCLayout.auth0Page,
                value: UltralightCLayout.protectionOff,
                name: "AUTH0 disarm"
            )
            guard try await readConfiguration().auth0 == UltralightCLayout.protectionOff else {
                residue.record(failure: .gateDisarmed, "AUTH0 read-back still shows the gate armed")
                throw TagError.protectionIncomplete(
                    residue,
                    diagnostics: "AUTH0 did not come down, so the key was not written. The tag is "
                        + "unchanged and still holds the key it had."
                )
            }
            residue.record(.gateDisarmed)
        }

        do {
            try await writeKey(key)
        } catch {
            residue.gate = .provenOpen
            residue.credential = .unknown(
                reason: "the key write stopped part way, so the tag may hold neither key"
            )
            residue.record(failure: .credentialWritten, "key page write refused or lost: \(error)")
            throw TagError.protectionIncomplete(
                residue,
                diagnostics: "the tag is unprotected and its key may be part-written. Holding it "
                    + "against the phone again rewrites all four key pages over the top."
            )
        }
        residue.record(.credentialWritten)
        residue.credential = .callerSupplied

        do {
            try await writeConfigByte(
                page: UltralightCLayout.auth1Page,
                value: UltralightCConfiguration.auth1(readProtect: readProtect),
                name: "AUTH1"
            )
        } catch {
            residue.gate = .provenOpen
            residue.record(failure: .accessWritten, "AUTH1 write refused or lost: \(error)")
            throw TagError.protectionIncomplete(
                residue,
                diagnostics: "the key is on the tag and the tag is still unprotected; "
                    + "hold it against the phone again to finish."
            )
        }
        residue.record(.accessWritten)

        // AUTH0 last. Nothing above this line changes what the tag enforces.
        do {
            try await writeConfigByte(page: UltralightCLayout.auth0Page, value: auth0, name: "AUTH0")
        } catch {
            // The same rule the Type-2 driver applies at its own AUTH0 abort.
            // This is the write that arms the gate, so the configuration read
            // taken on the way in is a reading a later command invalidated. A
            // stated refusal leaves the tag open; a lost answer may leave it
            // armed with the key written a few lines above. Ask the chip.
            residue.gate = .unknown
            residue.record(failure: .gateArmed, "AUTH0 write refused or lost: \(error)")
            var followUp = "the key is on the tag"
            if let after = try? await readConfiguration() {
                let armed = after.auth0 != UltralightCLayout.protectionOff
                residue.gate = armed ? .provenArmed(fromPage: Int(after.auth0)) : .provenOpen
                residue.record(.gateProven)
                followUp += armed
                    ? " and a read afterwards found the gate armed at page \(after.auth0), "
                    + "so the key you entered is the one that opens it."
                    : " and the tag is still unprotected; hold it against the phone again to finish."
            } else {
                followUp += ", and whether the gate armed could not be re-read. "
                    + "Keep the key you entered: it is the one the tag holds either way."
            }
            throw TagError.protectionIncomplete(residue, diagnostics: followUp)
        }
        residue.record(.gateArmed)

        // The gate read-back, which is the success criterion. It is only safe to
        // ask for when the READ cannot be refused: a refused READ NAKs and the
        // NAK halts the tag. `readConfiguration` serves pages 28h-2Bh, so a
        // read-protected tag gates them unless AUTH0 sits above 2Bh or this
        // activation is authenticated.
        //
        // What it proves is that the **bytes committed**, not that the gate is
        // being enforced at this instant. This chip is documented to defer some
        // configuration to the next activation: lock bytes written now are
        // "valid upon the next REQA or WUPA" (MF0ICU2 rev 3.3 §7.5.3), and a
        // re-programmed key only authenticates after an RF reset (§7.5.7
        // remark). §7.5.8 says nothing either way about AUTH0's timing, so
        // enforcement is a property only a fresh activation can establish, and
        // that belongs to the enforcement verifier rather than to this driver.
        let readBackIsSafe = !readProtect
            || authenticatedThisActivation
            || Int(auth0) > UltralightCLayout.auth1Page
        if readBackIsSafe {
            // `try?`, not `try`. Everything that arms this tag has landed and been
            // acknowledged by the time control reaches here, so a slip during the
            // proof is a tag that is protected with the caller's new key and an app
            // that says it lost the tag. Nothing after the success criterion may
            // report failure, and this read is the proof, not the criterion.
            guard let after = try? await readConfiguration() else {
                residue.record(
                    failure: .gateProven,
                    "the configuration could not be read back, so the gate is armed but unproven"
                )
                return residue
            }
            if after.auth0 == auth0, after.auth1 == UltralightCConfiguration.auth1(readProtect: readProtect) {
                residue.gate = .provenArmed(fromPage: Int(after.auth0))
                residue.record(.gateProven)
            } else {
                residue.record(
                    failure: .gateProven,
                    "configuration read-back does not match the request: "
                        + "AUTH0=\(String(format: "%02X", after.auth0)) "
                        + "AUTH1=\(String(format: "%02X", after.auth1))"
                )
            }
        } else {
            residue.record(
                failure: .gateProven,
                "read protection was just armed over the configuration pages and this activation "
                    + "never authenticated, so a read-back would NAK and the NAK would halt the tag"
            )
        }

        // The credential cannot be proven here. See the doc comment: the key
        // pages are not readable, a second handshake in one activation is
        // refused, and a re-programmed key does not authenticate until the next
        // activation (rev 3.3 §7.5.7 remark).
        residue.record(
            failure: .credentialProven,
            "an Ultralight C key cannot be proven in the activation that wrote it "
                + "(rev 3.3 §7.5.7 remark); it takes a second tap"
        )
        return residue
    }

    /// Remove protection and restore the factory key.
    ///
    /// Clear AUTH0 **first**, so that if any later write fails the tag is
    /// already open rather than stranded behind a half-restored credential. This
    /// is what makes the harness's "never leave a tag protected" invariant
    /// achievable on this chip, and is why Ultralight C can have an enforcement
    /// verifier where ICODE SLIX cannot.
    ///
    /// **The AUTH0 read-back is the success criterion, and nothing after it may
    /// throw.** The AUTH1 and key restores that follow are tidy-up: they report
    /// residue. A removal that opened the tag and then failed to reset the key
    /// has still removed the protection, and telling the user otherwise is the
    /// mistake that stranded a real NTAG213 on 2026-09-04.
    ///
    /// ## Abort points
    ///
    /// | # | Abort after | Tag state | Recovery |
    /// |---|---|---|---|
    /// | R0 | before anything | protected, key = the user's | re-run |
    /// | R1 | AUTHENTICATE | unchanged | re-run |
    /// | R2 | `A2 2A 30` | **unprotected**, key = the user's | the removal has succeeded. |
    /// | | | | Re-running authenticates with the same |
    /// | | | | (untouched) key and finishes the restore |
    /// | R3 | the AUTH0 read-back | as R2 | as R2 |
    /// | R4 | `A2 2B 00` | unprotected, AUTH1 unchanged | as R2 |
    /// | R5 | mid key-restore | unprotected, key = a scramble | the gate is down and stays down. |
    /// | | | nobody holds | The key cannot be restored: a re-run's |
    /// | | | | handshake is refused and the refusal |
    /// | | | | halts the tag. The tag remains a usable |
    /// | | | | open tag this app can no longer re-key |
    /// | R6 | complete | unprotected, key = factory | n/a |
    ///
    /// Rows R2 through R5 report **success with residue**, never failure: the
    /// gate is down and read back down, which is the whole of what removing
    /// protection promises. R5's credential verdict is `.unknown`, which is the
    /// caller's instruction to keep every key it holds for this tag.
    ///
    /// R5 could be repaired if pages 2Ch-2Fh accept a WRITE with no prior
    /// handshake while AUTH0 reads `30h`. §7.5.8 defines AUTH0 as the first page
    /// requiring authentication and `30h` as past the end of memory, so nothing
    /// would be gated, but **no capture in this repo has sent that frame**,
    /// because the shipping code has always authenticated first. Until one does,
    /// this table claims no repair. `enable` reaches the same state from its own
    /// U3 row and *does* repair it, because it has a config read to tell it the
    /// tag is open and can therefore skip the handshake.
    @discardableResult
    public func disable(
        currentKey: UltralightCKey,
        alreadyAuthenticated: Bool = false
    ) async throws -> ProtectionResidue {
        var residue = ProtectionResidue(family: .ultralightC, intent: .disable)

        // **Not** state-first, and the exception is the chip's, not a
        // preference. `Type2PasswordDriver` can read a Type-2 tag's
        // configuration before offering anything because a read-protected tag
        // answers with a roll-over rather than a refusal. This chip has no such
        // answer: pages 28h-2Bh sit above AUTH0 on a read-protected tag, a
        // refused READ is a NAK, and a NAK halts the tag for the rest of the
        // activation. So a removal that probed first would work on every tag
        // except the ones whose reads are gated, and would fail on those in a
        // way no retry could fix.
        //
        // Authenticating first costs nothing on a protected tag, which is the
        // premise of calling this at all. On a tag that is already open it can
        // halt the activation, and the price of that is worth naming: the gate
        // is already down, so the removal's promise is already kept, and what is
        // lost is only the key tidy-up.
        if !alreadyAuthenticated {
            try await authenticate(key: currentKey)
        }
        residue.record(.gateOpened)

        let config = try await readConfiguration()
        residue.record(.stateRead)

        if config.isProtected {
            try await writeConfigByte(
                page: UltralightCLayout.auth0Page,
                value: UltralightCLayout.protectionOff,
                name: "AUTH0"
            )
            residue.record(.gateDisarmed)
        }

        // The success criterion. Everything above it can throw; nothing below it
        // may.
        //
        // A lost read and an armed read are different answers and are reported
        // as such. A bare `try` collapsed both into a transport error that threw
        // past the residue, so a removal whose AUTH0 write had already landed came
        // back as "lost the tag" with no record that the gate was disarmed.
        guard let after = try? await readConfiguration() else {
            residue.record(failure: .gateProven, "the configuration could not be read back")
            throw TagError.protectionIncomplete(
                residue,
                diagnostics: "the gate was disarmed but the read-back did not answer, so whether the "
                    + "tag is open is not known; the credential has NOT been touched"
            )
        }
        guard after.auth0 == UltralightCLayout.protectionOff else {
            // The gate was read back and it is still up, so that reading is filed
            // as one. `enable` already does this a few hundred lines above; the
            // removal side left `gate` at `.unknown`, which made "I could not read
            // the gate" and "I read it and it is still armed" produce the same
            // sentence. No roll-over guard is wanted here: `readConfiguration`
            // reads pages 28h to 2Bh and throws `malformedResponse` below 16
            // bytes, so there is no rolled-over page 0 to decode, and `auth0` is
            // the first protected page directly.
            residue.gate = .provenArmed(fromPage: Int(after.auth0))
            residue.record(
                failure: .gateProven,
                "AUTH0 read-back still shows the gate armed at page \(after.auth0)"
            )
            throw TagError.protectionIncomplete(
                residue,
                diagnostics: "removal did not open the gate at page \(after.auth0); "
                    + "the credential has NOT been touched"
            )
        }
        residue.gate = .provenOpen
        residue.record(.gateProven)

        // Restore AUTH1 to its **delivery value** (`00h`), not to the write-only
        // encoding. Both are inert while AUTH0 is `30h`, but a tag we call
        // "returned to factory" should actually match Table 13: live runs left
        // page 2Bh reading `01` indefinitely, so the claim was not quite true.
        do {
            try await writeConfigByte(
                page: UltralightCLayout.auth1Page,
                value: UltralightCLayout.auth1AtDelivery,
                name: "AUTH1"
            )
            residue.record(.accessWritten)
        } catch {
            residue.record(failure: .accessWritten, "AUTH1 reset did not complete: \(error)")
        }

        do {
            try await writeKey(.factoryDefault)
            residue.record(.credentialWritten)
            residue.credential = .factoryDefault
        } catch {
            // The tag is unprotected from here whatever happens, so this is
            // residue rather than a failure. What it means for the caller: the
            // key on the tag is neither provably the user's nor provably the
            // factory one, so the stored credential must be kept.
            residue.credential = .unknown(
                reason: "the key restore did not complete, so the tag may hold neither the key "
                    + "you configured nor the factory key"
            )
            residue.record(failure: .credentialWritten, "key restore did not complete: \(error)")
        }
        return residue
    }

    // MARK: - Writes

    /// Write the 16-byte key across pages 2Ch-2Fh in **memory order**.
    ///
    /// The order conversion is `UltralightCKey`'s job, not this function's, and
    /// that is the point: there is no way to reach this code with a key whose
    /// byte order is merely assumed.
    func writeKey(_ key: UltralightCKey) async throws {
        let memory = [UInt8](key.memoryOrder)
        for (index, page) in UltralightCLayout.keyPages.enumerated() {
            let chunk = Array(memory[(index * 4) ..< (index * 4 + 4)])
            let response = try await transceive(
                RawCommand(bytes: Data([0xA2, UInt8(page)] + chunk), name: "WRITE key page \(page)")
            )
            try Self.requireACK(response, what: "key page \(page)")
        }
    }

    /// Write one configuration byte, preserving nothing: bytes 1-3 of both
    /// AUTH0 and AUTH1 pages are RFU and read back as zeros on this chip
    /// (rev 3.3 Table 13), so there is no read-modify-write to do.
    func writeConfigByte(page: Int, value: UInt8, name: String) async throws {
        let response = try await transceive(
            RawCommand(bytes: Data([0xA2, UInt8(page), value, 0x00, 0x00, 0x00]), name: "WRITE \(name)")
        )
        try Self.requireACK(response, what: name)
    }

    /// A Type-2 `WRITE` answers with a 4-bit ACK (`0x0A`). CoreNFC surfaces that
    /// as a single byte; anything else is a NAK.
    static func requireACK(_ response: Data, what: String) throws {
        guard let first = response.first, first == 0x0A else {
            throw TagError.protocolError(
                "The tag refused a write",
                diagnostics: "WRITE \(what) expected ACK 0x0A, got \(response.hexString)"
            )
        }
    }
}
