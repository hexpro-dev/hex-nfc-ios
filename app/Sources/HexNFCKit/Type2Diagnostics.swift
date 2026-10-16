import Foundation

/// The read-only facts a Type-2 chip will volunteer about itself beyond its
/// NDEF message: the NXP originality signature, the one-way tap counter(s), the
/// counters' tearing status, and an NTAG213 TT's tamper loop.
///
/// Every field is optional and every absence is a legitimate state, not a
/// failure: a factory NTAG ships with its counter disabled, a clone stubs
/// `READ_SIG`, and most chips have no tamper loop at all.
public struct TagDiagnostics: Hashable, Sendable {
    /// The 32-byte ECDSA originality signature, when the chip returned a full
    /// one. `nil` when the chip has no `READ_SIG`, refused it, or answered short.
    public var originalitySignature: Data?

    /// `READ_SIG` answered, but not with 32 bytes.
    ///
    /// Worth its own flag rather than folding into `nil`. On genuine NXP silicon
    /// the reply is always 32 bytes; a short one means a clone or "compatible"
    /// die that stubs the opcode, which is exactly the kind of thing someone
    /// scanning an unknown tag wants to be told. The harness makes the same
    /// distinction (`t2.signature`) instead of failing the run.
    public var signatureIsShort = false

    /// NTAG21x's single 24-bit NFC counter, i.e. how many times the tag has been
    /// read since manufacture. `nil` when the chip has no counter or refused.
    public var tapCount: Int?

    /// `true` when `READ_CNT` was refused. On a factory NTAG this means
    /// `NFC_CNT_EN = 0`: the counter hardware exists but is switched off at
    /// delivery. A valid state, and a different statement from "this chip has no
    /// counter", so the UI can say "off" rather than showing nothing.
    public var counterDisabled = false

    /// MIFARE Ultralight EV1's three independent one-way counters (MF0ULx1
    /// §8.7), in index order, for those that answered. Unlike NTAG's, these tick
    /// only on `INCR_CNT` and ship at zero.
    public var ultralightCounters: [Int] = []

    /// Ultralight EV1 tearing check (`0x3E`): `true` when every counter that
    /// answered reported `0xBD`, "no tearing event". `nil` when not probed.
    public var countersIntact: Bool?

    /// NTAG213 TT's tamper loop.
    public var tamper: TamperState?

    /// The first bytes of the NDEF data area, kept **only** when the data area
    /// is what refused to read.
    ///
    /// Reported as an observation, in the same spirit as `signatureIsShort`
    /// above: these are the bytes, and the user can draw their own conclusion.
    /// The app deliberately does not call such a tag faulty. On NTAG213
    /// `04:5D:E5:FA:2A:14:90` (2026-09-09) it would have been wrong twice over,
    /// because the chip answered every read and the fix was a single page write
    /// and because Type-2 user memory is general-purpose: a tag some other
    /// system fills with its own bytes lands in exactly this state and is not
    /// broken at all. What the app can honestly do is show what it read. See
    /// `TagFormatState`.
    ///
    /// `nil` on every tag that reads, so no ordinary scan grows a row.
    public var dataAreaPrologue: Data?

    public enum TamperState: Hashable, Sendable {
        /// The loop is closed: the seal has not been broken.
        case intact
        /// The loop has been opened at least once. Latching: once broken, a TT
        /// reports this forever, which is the entire point of the feature.
        case opened
    }

    public init() {}

    /// `true` when the chip volunteered nothing, so the UI renders no section.
    public var isEmpty: Bool {
        originalitySignature == nil && !signatureIsShort && tapCount == nil
            && !counterDisabled && ultralightCounters.isEmpty && tamper == nil
    }
}

/// Reads `TagDiagnostics` off a Type-2 chip over a raw `transceive` closure.
///
/// Structured as a `transceive`-driven struct like the protection drivers, so
/// production and the chip simulators run the same code and a divergence is a
/// real signal rather than two implementations disagreeing.
///
/// **Two rules govern everything here, and both come from silicon:**
///
/// 1. *Capability first, always.* A Type-2 chip NAKs an opcode it doesn't
///    implement, and on this transport a NAK returns the tag to HALT for the
///    rest of the activation, so an unsupported probe doesn't merely fail, it
///    kills the session. Every command below is gated on the capability its
///    chip profile declares, which is where the datasheet reasoning lives.
///
/// 2. *Stop at the first refusal.* Even a capability-correct probe can be
///    refused for a legitimate reason: a factory NTAG's counter is disabled and
///    NAKs `READ_CNT`. That NAK has already halted the tag, so anything sent
///    afterwards would fail regardless of what it asked. Rather than emit a
///    stream of commands at a chip that has stopped listening, the run ends and
///    keeps whatever it had already collected.
///
/// The order is chosen so the most-likely-to-refuse probe goes last: the
/// signature is present whenever `.signatureRead` is declared, a TT always
/// answers `READ_TT_STATUS`, and the counter is the one that is commonly off at
/// delivery. Reading the counter first would have cost every NTAG213 TT its
/// tamper state, the single most valuable thing that chip knows.
public struct Type2DiagnosticsReader: Sendable {
    private let transceive: @Sendable (RawCommand) async throws -> Data

    public init(transceive: @escaping @Sendable (RawCommand) async throws -> Data) {
        self.transceive = transceive
    }

    /// Best-effort: never throws. A chip that refuses everything yields an empty
    /// `TagDiagnostics`, which the UI renders as no section at all.
    public func read(chip: ChipProfile?) async -> TagDiagnostics {
        var result = TagDiagnostics()
        guard let chip, case .type2(let variant) = chip.family,
              chip.capabilities.contains(.rawTransceive) else { return result }

        // 1. Originality signature (READ_SIG, 3Ch).
        if chip.capabilities.contains(.signatureRead) {
            guard let reply = await send([0x3C, 0x00], "READ_SIG", minimumLength: 2) else { return result }
            if reply.count == 32 {
                result.originalitySignature = reply
            } else {
                // Answered, but not like genuine silicon. Record it and stop:
                // a chip lying about this opcode is not one to keep probing.
                result.signatureIsShort = true
                return result
            }
        }

        // 2. Tamper loop (READ_TT_STATUS, A4h). NTAG213 TT only, and before the
        //    counter for the ordering reason in the type doc.
        if chip.capabilities.contains(.tamperStatus) {
            guard let reply = await send([0xA4], "READ_TT_STATUS", minimumLength: 4) else { return result }
            // NT2H1311TT rev 1.1: an intact loop answers four zero bytes; a
            // broken one answers the customer-programmed TT_MESSAGE instead.
            // So "all zero" is the only reading that means intact. Matching on
            // any specific non-zero value would be inventing a code, since the
            // message bytes are whoever-programmed-the-tag's to choose.
            result.tamper = reply.prefix(4).allSatisfy { $0 == 0x00 } ? .intact : .opened
        }

        // 3. Counters (READ_CNT, 39h).
        if chip.capabilities.contains(.counterRead) {
            let isUltralightEV1 = variant == .mifareUltralightEV1_48 || variant == .mifareUltralightEV1_128
            if isUltralightEV1 {
                // Three independent counters. A NAK on any of them halts the tag,
                // so the loop stops there and reports the ones already read.
                for index: UInt8 in 0 ... 2 {
                    guard let value = await counter(index, label: "READ_CNT \(index)") else {
                        return result
                    }
                    result.ultralightCounters.append(value)
                }
                // Tearing status only makes sense once the counters have spoken.
                var intact = true
                for index: UInt8 in 0 ... 2 {
                    guard let reply = await send([0x3E, index], "CHECK_TEARING_EVENT \(index)", minimumLength: 1) else {
                        result.countersIntact = intact
                        return result
                    }
                    // MF0ULx1 §10.7: 0xBD means no tearing event on that counter.
                    if reply.first != 0xBD {
                        intact = false
                    }
                }
                result.countersIntact = intact
            } else {
                // NTAG21x: one counter, at index 02h, disabled at the factory.
                guard let value = await counter(0x02, label: "READ_CNT") else {
                    result.counterDisabled = true
                    return result
                }
                result.tapCount = value
            }
        }

        return result
    }

    /// Send one probe. Returns `nil` for a refusal: a throw, or a reply shorter
    /// than the command's real answer, which on this transport is how a NAK
    /// arrives. `nil` means the tag has halted and the caller must stop.
    private func send(_ bytes: [UInt8], _ name: String, minimumLength: Int) async -> Data? {
        guard let reply = try? await transceive(RawCommand(bytes: Data(bytes), name: name)),
              reply.count >= minimumLength else { return nil }
        return reply
    }

    /// One 24-bit little-endian counter frame, or `nil` if refused.
    private func counter(_ index: UInt8, label: String) async -> Int? {
        guard let reply = await send([0x39, index], label, minimumLength: 3) else { return nil }
        let b = [UInt8](reply)
        return Int(b[0]) | Int(b[1]) << 8 | Int(b[2]) << 16
    }
}
