#if canImport(CoreNFC) && os(iOS)
import CoreNFC
import Foundation

/// Identifies ISO 7816 / NFC Type 4 tags that CoreNFC surfaces as `.iso7816`
/// (rather than as `.miFare`).
///
/// NTAG424 DNA can arrive on *either* transport depending on the device and
/// how iOS chose to enumerate it — most often `.miFare`/`.unknown` (see
/// `MiFareTagIdentifier`), but sometimes `.iso7816`. Either way its
/// wrapped-APDU `GET_VERSION` (`90 60 00 00 00`) fingerprints it, so we probe
/// for it here too. The same probe names a DESFire EV1/EV2/EV3, which reaches
/// this transport once it hosts the NDEF application and the app declares that
/// AID. Other Type-4 silicon (payment cards and the like) can't be told apart
/// over the air without an app-specific select, so it falls back to the generic
/// command set.
///
/// A tag iOS delivered through the **NDEF application AID** takes its own
/// route, `identifyNDEFApplication`. iOS SELECTs the declared AIDs in Info.plist
/// order and stops at the first that answers, so `initialSelectedAID` says which
/// one did. The eMRTD AID is listed first, which means a tag delivered on the
/// NDEF AID has already refused it, and the passport probe is skipped.
struct ISO7816TagIdentifier: Sendable {
    struct Identification: Sendable {
        var profile: ChipProfile?
        var healthDevice: PHDAssociation?
    }

    /// NFC Forum NDEF Tag Application, version 2. Declared in Info.plist after
    /// the eMRTD AID (`docs/internal/aid-rationale.md`).
    static let ndefApplicationAID = "D2760000850101"

    func identify(_ tag: NFCISO7816Tag) async -> Identification {
        // Trace the breadcrumbs (UID / historical bytes / selected AID) for any
        // Type-4 chip we don't yet fingerprint, rather than dropping it silently.
        NFCTrace.shared.note(
            "ISO7816 uid=\(tag.identifier.hexString) "
                + "hist=\(tag.historicalBytes?.hexString ?? "-") "
                + "aid=\(tag.initialSelectedAID)",
            label: "identify"
        )
        if tag.initialSelectedAID.uppercased() == Self.ndefApplicationAID {
            return await identifyNDEFApplication(tag)
        }
        if let version = try? await getVersionAPDU(tag),
           let profile = ChipCatalog.identify(type4Version: version)
        {
            return Identification(profile: profile)
        }
        // Not an NTAG424 — probe for an electronic passport by SELECTing the
        // eMRTD LDS1 application. A tag that accepts the AID is an ePassport;
        // the data itself stays locked until the holder supplies the MRZ.
        if let sw = try? await selectEMRTD(tag),
           let profile = ChipCatalog.identify(eMRTDSelectStatus: sw)
        {
            return Identification(profile: profile)
        }
        return Identification(profile: nil)
    }

    /// A Type 4 tag reached through the NDEF application, which iOS has already
    /// selected.
    ///
    /// **The NDEF probe runs before anything else is sent.** If this is a
    /// personal health device, the first frames it receives should be the
    /// plain SELECTs and READs any Type 4 reader sends, not a wrapped DESFire
    /// command it has no reason to understand. Only a tag that turns out not to
    /// be one is asked for `GET_VERSION`, which is how an NTAG424 delivered on
    /// this transport is still recognised.
    private func identifyNDEFApplication(_ tag: NFCISO7816Tag) async -> Identification {
        let outcome = await probeNDEF(tag)
        if let healthDevice = healthDevice(from: outcome) {
            return healthDevice
        }
        if case .unreadable(let reason) = outcome {
            NFCTrace.shared.note("NDEF probe: \(reason)", label: "identify")
        }
        if let version = try? await getVersionAPDU(tag),
           let profile = ChipCatalog.identify(type4Version: version)
        {
            return Identification(profile: profile)
        }
        // An NDEF application that answered but whose file did not read is
        // still a Type 4 tag. CoreNFC's own NDEF read gets the final say.
        return Identification(profile: ChipCatalog.profile(for: .genericType4))
    }

    /// The health device check alone, for a session that skips identification
    /// (the Advanced console's toggle, which sets it on the app-wide factory).
    ///
    /// The skip exists to keep `GET_VERSION` off chips that halt on it. This
    /// check sends only SELECT and READ BINARY, which halt nothing, so it runs
    /// regardless: without it a pen is handed up unidentified, and an
    /// unidentified tag gets the generic command set, writes included. `nil`
    /// for anything that is not a health device, which stays unidentified as
    /// the skip asked.
    func identifyHealthDeviceOnly(_ tag: NFCISO7816Tag) async -> Identification? {
        guard tag.initialSelectedAID.uppercased() == Self.ndefApplicationAID else { return nil }
        return await healthDevice(from: probeNDEF(tag))
    }

    private func probeNDEF(_ tag: NFCISO7816Tag) async -> Type4NDEFProbe.Outcome {
        await Type4NDEFProbe { command, label in
            try await sendAPDU(tag, command, label: label)
        }.probe()
    }

    private func healthDevice(from outcome: Type4NDEFProbe.Outcome) -> Identification? {
        guard case .personalHealthDevice = outcome,
              let (profile, association) = ChipCatalog.identify(type4Probe: outcome)
        else { return nil }
        NFCTrace.shared.note(
            "PHDC device maker=\(association?.maker?.name ?? "unknown") "
                + "systemID=\(association?.systemID.hexString ?? "-")",
            label: "identify"
        )
        return Identification(profile: profile, healthDevice: association)
    }

    /// Sends one plain ISO 7816 command and returns `data || SW1 || SW2`, with
    /// tx/rx trace logging.
    private func sendAPDU(_ tag: NFCISO7816Tag, _ command: Data, label: String) async throws -> Data {
        guard let apdu = NFCISO7816APDU(data: command) else {
            throw TagError.protocolError("invalid APDU bytes", diagnostics: command.hexString)
        }
        NFCTrace.shared.tx(label, command)
        return try await withCheckedThrowingContinuation { continuation in
            tag.sendCommand(apdu: apdu) { data, sw1, sw2, error in
                if let error {
                    NFCTrace.shared.failure(error.localizedDescription, label: label)
                    continuation.resume(throwing: error)
                } else {
                    let response = data + Data([sw1, sw2])
                    NFCTrace.shared.rx(label, response)
                    continuation.resume(returning: response)
                }
            }
        }
    }

    /// SELECT the eMRTD application (AID `A0000002471001`) and return its status
    /// word. Plain ISO 7816 SELECT (not the wrapped-native form NTAG uses).
    private func selectEMRTD(_ tag: NFCISO7816Tag) async throws -> UInt16 {
        guard let apdu = NFCISO7816APDU(data: EPassportReader.selectAIDCommand) else {
            return 0
        }
        NFCTrace.shared.tx("SELECT eMRTD", EPassportReader.selectAIDCommand)
        return try await withCheckedThrowingContinuation { continuation in
            tag.sendCommand(apdu: apdu) { data, sw1, sw2, error in
                if let error {
                    NFCTrace.shared.failure(error.localizedDescription, label: "SELECT eMRTD")
                    continuation.resume(throwing: error)
                } else {
                    NFCTrace.shared.rx("SELECT eMRTD", data + Data([sw1, sw2]))
                    continuation.resume(returning: (UInt16(sw1) << 8) | UInt16(sw2))
                }
            }
        }
    }

    /// Wrapped-native `GET_VERSION` (`90 60 00 00 00`) over the ISO 7816
    /// transport. Reassembles the response as `data || SW1 || SW2` so it decodes
    /// the same way as the `.miFare`-transport form.
    private func getVersionAPDU(_ tag: NFCISO7816Tag) async throws -> Data {
        let first = try await send(tag, ins: 0x60, label: "GET_VERSION (APDU)")
        // GET_VERSION is a 3-frame chain on real silicon (first frame ends
        // `91 AF`). Drain the `90 AF …` continuations so the card is left idle
        // and the next native command doesn't get `91 CA` (COMMAND_ABORTED) —
        // see MiFareTagIdentifier. Best-effort; the first frame is all the
        // decode needs, and the simulator answers in one frame ending `91 00`.
        var frame = first
        var frames = 0
        while Self.endsWith(frame, 0x91, 0xAF), frames < 4 {
            guard let next = try? await send(tag, ins: 0xAF, label: "GET_VERSION (cont.)") else { break }
            frame = next
            frames += 1
        }
        return first
    }

    /// Sends a wrapped-native command (`90 <ins> 00 00 00`) and reassembles the
    /// response as `data || SW1 || SW2`, with tx/rx trace logging.
    private func send(_ tag: NFCISO7816Tag, ins: UInt8, label: String) async throws -> Data {
        let apdu = NFCISO7816APDU(
            instructionClass: 0x90,
            instructionCode: ins,
            p1Parameter: 0x00,
            p2Parameter: 0x00,
            data: Data(),
            expectedResponseLength: 256
        )
        NFCTrace.shared.tx(label, Data([0x90, ins, 0x00, 0x00, 0x00]))
        return try await withCheckedThrowingContinuation { continuation in
            tag.sendCommand(apdu: apdu) { data, sw1, sw2, error in
                if let error {
                    NFCTrace.shared.failure(error.localizedDescription, label: label)
                    continuation.resume(throwing: error)
                } else {
                    let response = data + Data([sw1, sw2])
                    NFCTrace.shared.rx(label, response)
                    continuation.resume(returning: response)
                }
            }
        }
    }

    /// Whether a response ends with the two-byte status word `a b`.
    static func endsWith(_ data: Data, _ a: UInt8, _ b: UInt8) -> Bool {
        let tail = data.suffix(2)
        return tail.count == 2 && Array(tail) == [a, b]
    }
}
#endif
