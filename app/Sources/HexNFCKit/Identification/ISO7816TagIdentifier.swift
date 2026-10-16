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
/// for it here too. Other Type-4 silicon (DESFire generations, payment cards)
/// can't be told apart over the air without an app-specific select, so they
/// fall back to the generic command set.
struct ISO7816TagIdentifier: Sendable {
    func identify(_ tag: NFCISO7816Tag) async -> ChipProfile? {
        // Trace the breadcrumbs (UID / historical bytes / selected AID) for any
        // Type-4 chip we don't yet fingerprint, rather than dropping it silently.
        NFCTrace.shared.note(
            "ISO7816 uid=\(tag.identifier.hexString) "
                + "hist=\(tag.historicalBytes?.hexString ?? "-") "
                + "aid=\(tag.initialSelectedAID)",
            label: "identify"
        )
        if let version = try? await getVersionAPDU(tag),
           let profile = ChipCatalog.identify(type4Version: version)
        {
            return profile
        }
        // Not an NTAG424 — probe for an electronic passport by SELECTing the
        // eMRTD LDS1 application. A tag that accepts the AID is an ePassport;
        // the data itself stays locked until the holder supplies the MRZ.
        if let sw = try? await selectEMRTD(tag),
           let profile = ChipCatalog.identify(eMRTDSelectStatus: sw)
        {
            return profile
        }
        return nil
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
