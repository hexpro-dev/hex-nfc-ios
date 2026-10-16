#if canImport(CoreNFC) && os(iOS)
import CoreNFC
import Foundation

/// Resolves a connected CoreNFC tag to a `ChipProfile`.
///
/// Device-specific detection is deliberately split by tag family — one small
/// identifier per family — rather than packed into `CoreNFCSession`. Each
/// identifier is the *thin* CoreNFC-facing probe; the pure decoding (version
/// blocks → chip model) lives in `ChipCatalog`, which is fully testable
/// without an entitled session. This dispatcher just picks the right probe.
///
/// Returns `nil` when the family is recognised but the exact model can't be
/// fingerprinted over the air — callers fall back to a generic command set.
struct TagIdentifier: Sendable {
    /// Outcome of identification. When `profile` is `nil` the probe may still
    /// have learned something about the chip — `report` carries whatever the
    /// version block decoded to, so the UI can say "NXP · NTAG · 32–64 bytes"
    /// instead of nothing at all.
    struct Result: Sendable {
        let profile: ChipProfile?
        let report: UnidentifiedChipReport?
        /// What the probe learned about the chip, as distinct from what it
        /// learned about the radio.
        ///
        /// `.chipRefused` means the chip answered a NAK. Per ISO 14443-3 that
        /// returns a Type-2 tag to HALT and it answers nothing more on that
        /// activation, so a chip that doesn't implement `GET_VERSION` (original
        /// MIFARE Ultralight, Ultralight C, NTAG203, EM) is left dead for the
        /// whole session by our own probe. `.transportLost` means the send never
        /// completed, so the chip is not halted and nothing was learned about
        /// it. The session re-polls for either, but it does different things
        /// afterwards, and telling them apart is the whole point of the type.
        ///
        /// The *decision* is `Type2ProbePolicy.nextStep(after:attempts:)`, and
        /// it deliberately does not live here: only the session knows how many
        /// passes this tap has already spent.
        var verdict: Type2ProbeVerdict = .answered
    }

    func identify(_ tag: NFCTag) async -> Result {
        let result = await resolve(tag)
        if let profile = result.profile {
            NFCTrace.shared.note("resolved \(profile.id.description)", label: "identify")
        } else {
            NFCTrace.shared.note(
                "resolved unidentified: generic fallback"
                    + (result.report?.summary.map { " (\($0))" } ?? ""),
                label: "identify"
            )
        }
        return result
    }

    private func resolve(_ tag: NFCTag) async -> Result {
        switch tag {
        case .miFare(let mifare):
            return await MiFareTagIdentifier().identify(mifare)

        case .iso15693(let iso):
            return await Result(profile: ISO15693TagIdentifier().identify(iso), report: nil)

        case .feliCa(let felica):
            return Result(profile: FeliCaTagIdentifier().identify(felica), report: nil)

        case .iso7816(let iso):
            return await Result(profile: ISO7816TagIdentifier().identify(iso), report: nil)

        @unknown default:
            return Result(profile: nil, report: nil)
        }
    }
}
#endif
