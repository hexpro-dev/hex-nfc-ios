#if canImport(CoreNFC) && os(iOS)
import CoreNFC
import Foundation

/// Identifies MIFARE-family tags (the `.miFare` CoreNFC case).
///
/// CoreNFC already classifies DESFire vs Ultralight via `mifareFamily`, so
/// DESFire (e.g. transit cards such as Myki) is recognised directly. NTAG and
/// MIFARE Ultralight EV1 both report `.ultralight`, so we send GET_VERSION
/// (`0x60`) and hand the 8-byte version block to `ChipCatalog` to pin the
/// exact model.
struct MiFareTagIdentifier: Sendable {
    func identify(_ tag: NFCMiFareTag) async -> TagIdentifier.Result {
        NFCTrace.shared.note(
            "MIFARE family=\(Self.familyName(tag.mifareFamily)) uid=\(tag.identifier.hexString)",
            label: "identify"
        )
        switch tag.mifareFamily {
        case .desfire:
            // Pin the generation (EV1/EV2/EV3) + storage from the DESFire
            // native GET_VERSION first frame. Falls back to the generic
            // profile if the card declines 0x60 or returns an unexpected frame.
            if let version = try? await getVersion(tag),
               let profile = ChipCatalog.identify(desFireVersion: version)
            {
                return .init(profile: profile, report: nil)
            }
            return .init(profile: ChipCatalog.profile(for: .genericMifareDESFire), report: nil)

        case .ultralight, .unknown:
            // NTAG21x / Ultralight EV1 answer the bare GET_VERSION (0x60).
            //
            // Whether the chip answered at all is a different fact from what it
            // answered, and the two must not be collapsed. A send that throws
            // says nothing about the silicon: the tag may be perfectly capable
            // of `60` and merely out of the field for a moment, which is what
            // happened to a real NTAG213 mid-removal on 2026-09-21. See
            // `Type2ProbeVerdict`.
            guard case .answered(let version) = await probe(tag, Data([0x60]), label: "GET_VERSION") else {
                // The chip is not halted, because it was never reached. The
                // session re-polls and asks again rather than falling through
                // to a decoder that cannot recognise an NTAG21x.
                return .init(profile: nil, report: nil, verdict: .transportLost)
            }
            // Native GET_VERSION is a 3-frame chain on DESFire too, but the
            // *raw* form carries its status byte at the **front** (`AF …`, vs
            // the wrapped form's trailing `91 AF`). Drain it so the card is left
            // idle, exactly as the wrapped path does.
            await drainNativeContinuations(tag, after: version)
            if let profile = ChipCatalog.identify(getVersion: version) {
                return .init(profile: profile, report: nil)
            }
            // The chip answered, and its answer was not a version block: a NAK,
            // or a frame too short to be one. That is a refusal, and a refused
            // Type-2 command leaves the tag HALTed — so anything the caller
            // sends next dies with "tag connection lost" unless we re-select it.
            // Live-confirmed 2026-08-06 on an unidentified Ultralight-family
            // chip: `RX GET_VERSION 00`, then every subsequent command failed,
            // including `30:00` (READ page 0), which no Type-2 chip can refuse.
            let refused = version.count < 8
            // A `.unknown` tag that yielded no NTAG21x version block may be an
            // ISO 14443-4 (Type-4) chip in APDU mode — iOS drops both MIFARE
            // Classic *and* NTAG424 DNA into `.unknown`. NTAG424 DNA powers up
            // in 14443-4 and rejects the raw 0x60 with the ISO 7816 status word
            // `67 00`; its GET_VERSION must be wrapped as a DESFire-style APDU
            // (`90 60 00 00 00`). Retry on that form before giving up. Reached
            // only when the bare form *answered*, so this is a second frame at a
            // chip that is talking, never at a handle that just failed.
            if tag.mifareFamily == .unknown,
               let apduVersion = try? await getVersionAPDU(tag),
               let profile = ChipCatalog.identify(type4Version: apduVersion)
            {
                // It answered the wrapped form, so it is a live ISO 14443-4 chip
                // and nothing was halted.
                return .init(profile: profile, report: nil)
            }
            // Unidentified, but the chip answered `60h` — keep what that block
            // says about itself so the scan card and any bug report carry the
            // fingerprint rather than a blank. Display-only; no page map is
            // inferred (see `UnidentifiedChipReport`).
            return .init(
                profile: nil,
                report: ChipCatalog.describe(getVersion: version),
                verdict: refused ? .chipRefused : .answered
            )

        case .plus:
            // MIFARE Plus — not yet profiled.
            return .init(profile: nil, report: nil)

        @unknown default:
            return .init(profile: nil, report: nil)
        }
    }

    /// Second-pass identification for a chip with **no `GET_VERSION`**, run
    /// after `CoreNFCSession` has re-polled to wake a tag that the first probe
    /// halted.
    ///
    /// Reads only. Every command sent here is one a MIFARE Ultralight C
    /// answers, so the common case (by far the largest group of otherwise
    /// unidentifiable tags we hold) completes without halting the tag again. A
    /// chip that is *not* Ultralight C may NAK the `30 28` read and halt, which
    /// costs the session, but that path previously returned `chip: nil`
    /// unconditionally, so nothing that used to work stops working.
    func identifyWithoutGetVersion(
        _ tag: NFCMiFareTag,
        report: UnidentifiedChipReport?
    ) async -> TagIdentifier.Result {
        NFCTrace.shared.note("second pass: identifying without GET_VERSION", label: "identify")
        guard let pageZero = try? await send(tag, Data([0x30, 0x00]), label: "READ p0"),
              pageZero.count >= 16
        else {
            // Page 0 is unreadable on any live Type-2 tag, so this is a dead
            // session rather than an unknown chip.
            return .init(profile: nil, report: report)
        }
        // Only two reads, and both are addresses a MIFARE Ultralight C decodes.
        //
        // A read of the key pages (`30 2C`) was tempting as a third check — the
        // key is unreadable, so zeros would confirm the chip. Real silicon does
        // not mask those pages, it does not decode them at all: `30 2C` → `00`,
        // a NAK, live-confirmed 2026-08-07. That halts the tag, and doing it as
        // the last step of identification would hand the caller a tag that
        // answers nothing.
        let configPages = try? await send(tag, Data([0x30, 0x28]), label: "READ p40")
        if let profile = ChipCatalog.identify(preEV1PageZero: pageZero, configPages: configPages) {
            NFCTrace.shared.note("identified \(profile.displayName) by memory shape", label: "identify")
            return .init(profile: profile, report: report)
        }
        return .init(profile: nil, report: report)
    }

    /// NTAG / Ultralight EV1 `GET_VERSION`. Returns the raw 8-byte block. The
    /// frame is traced so the exact version bytes show up for any tag — the
    /// fingerprint we need when adding support for an unrecognised chip.
    private func getVersion(_ tag: NFCMiFareTag) async throws -> Data {
        let first = try await send(tag, Data([0x60]), label: "GET_VERSION")
        await drainNativeContinuations(tag, after: first)
        return first
    }

    /// Send one identification frame and report what it *did*, not what it
    /// said. A thrown send and a NAK are different facts and the caller has to
    /// be able to tell them apart (see `Type2ProbeVerdict`).
    private func probe(_ tag: NFCMiFareTag, _ packet: Data, label: String) async -> Type2ProbeOutcome {
        guard let data = try? await send(tag, packet, label: label) else { return .transportFailed }
        return .answered(data)
    }

    /// Drain a native `AF` continuation chain, best-effort.
    ///
    /// Native GET_VERSION is a 3-frame chain on DESFire, and the *raw* form
    /// carries its status byte at the **front** (`AF …`, vs the wrapped form's
    /// trailing `91 AF`). We identify from the first frame only, so drain the
    /// continuations (bare `AF` command) to leave the card idle for anything
    /// issued next. Latent today — DESFire use is identify-only and nothing
    /// follows it in-session — but it mirrors the wrapped path and future-proofs
    /// live DESFire app reads. NTAG21x / UL EV1 answer in one frame starting
    /// `00` (no leading `AF`), so this is a no-op for them.
    private func drainNativeContinuations(_ tag: NFCMiFareTag, after first: Data) async {
        var frame = first
        var frames = 0
        while frame.first == 0xAF, frames < 4 {
            guard let next = try? await send(tag, Data([0xAF]), label: "GET_VERSION (cont.)") else { break }
            frame = next
            frames += 1
        }
    }

    /// Wrapped-APDU `GET_VERSION` for an ISO 14443-4 Type-4 chip surfaced over
    /// the `.miFare` transport (NTAG424 DNA): `90 60 00 00 00`. Returns the raw
    /// response — the first frame's hardware-info block plus its `91 AF` / `91 00`
    /// status word — for `ChipCatalog.identify(type4Version:)`. Traced like the
    /// raw probe so the exact bytes surface for any unrecognised Type-4 chip.
    private func getVersionAPDU(_ tag: NFCMiFareTag) async throws -> Data {
        let first = try await send(tag, Data([0x90, 0x60, 0x00, 0x00, 0x00]), label: "GET_VERSION (APDU)")
        // Wrapped GET_VERSION is a 3-frame chained command on real silicon: the
        // first frame ends with the wrapped-native status `91 AF` ("additional
        // frame follows"). Drain the remaining `90 AF …` continuation frames so
        // the card is left idle — an unfinished chain makes the *next* native
        // command reply `91 CA` (COMMAND_ABORTED), which breaks re-running
        // GET_VERSION or authenticating right after identify. Best-effort:
        // identification only needs the first frame, so a drain hiccup must not
        // fail the probe. The chip simulator answers in one frame ending
        // `91 00`, so this loop is a no-op there.
        var frame = first
        var frames = 0
        while Self.endsWith(frame, 0x91, 0xAF), frames < 4 {
            guard let next = try? await send(tag, Data([0x90, 0xAF, 0x00, 0x00, 0x00]), label: "GET_VERSION (cont.)")
            else { break }
            frame = next
            frames += 1
        }
        return first
    }

    /// Wraps `sendMiFareCommand` as an async call with tx/rx trace logging.
    private func send(_ tag: NFCMiFareTag, _ packet: Data, label: String) async throws -> Data {
        NFCTrace.shared.tx(label, packet)
        return try await withCheckedThrowingContinuation { continuation in
            tag.sendMiFareCommand(commandPacket: packet) { data, error in
                if let error {
                    NFCTrace.shared.failure(error.localizedDescription, label: label)
                    continuation.resume(throwing: error)
                } else {
                    NFCTrace.shared.rx(label, data)
                    continuation.resume(returning: data)
                }
            }
        }
    }

    /// Whether a response ends with the two-byte status word `a b`.
    static func endsWith(_ data: Data, _ a: UInt8, _ b: UInt8) -> Bool {
        let tail = data.suffix(2)
        return tail.count == 2 && Array(tail) == [a, b]
    }

    static func familyName(_ family: NFCMiFareFamily) -> String {
        switch family {
        case .ultralight: return "ultralight"
        case .plus: return "plus"
        case .desfire: return "desfire"
        case .unknown: return "unknown"
        @unknown default: return "unknown(\(family.rawValue))"
        }
    }
}
#endif
