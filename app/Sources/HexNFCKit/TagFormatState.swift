import Foundation

/// What the app established about a tag's NDEF *structure*, and how.
///
/// The distinction this type exists to make is the one a real NTAG213 forced on
/// 2026-09-09 (UID `04:5D:E5:FA:2A:14:90`). Its Capability Container was
/// perfect, byte for byte the value this app itself writes for the chip, and
/// iOS still refused the NDEF read, because one byte of the data area had left
/// the factory wrong: page 4 began `04` where its peel-sheet sibling began `01`,
/// the Lock Control TLV tag. `04` is not a TLV tag at all, so the walk that
/// finds the NDEF message never reached the perfectly good `03 00 FE` two bytes
/// later.
///
/// The app called that tag "unformatted" and sent the user to Format, which read
/// page 3, found the Capability Container already correct, wrote nothing, and
/// said so. Both statements were defensible on their own and together they were
/// a closed loop: the scan named a fault the format could not touch. The scan's
/// half was the wrong one. It had never read page 3.
///
/// So: **a tag is not unformatted because a read was refused.** A refusal says
/// the tag holds no NDEF message this phone can find. Which of the two repairs
/// that calls for is a fact about the Capability Container, and the only way to
/// know it is to read the Capability Container.
public enum TagFormatState: Equatable, Sendable {
    /// Nothing was established. The read was refused on a chip family that has
    /// no NDEF area to format at all (DESFire, FeliCa), or the Capability
    /// Container was never read. Renders nothing: silence is the honest answer.
    case unknown

    /// The NDEF read came back rather than being refused. Zero records still
    /// counts: a blank tag reads perfectly well.
    ///
    /// On the Type-2 page transport that is a strong statement, because the
    /// reader walks the Capability Container and the data area to get there.
    /// ISO 15693 and ISO 7816 report an unformatted tag as a clean read of zero
    /// records instead, so on those families this says only that nothing
    /// refused us. Neither reading renders anything, so the difference costs the
    /// user nothing; it is stated here so nobody later reads more into it.
    case readable

    /// Page 3 was read and holds no Capability Container. Formatting is the
    /// repair, and on a Type-2 chip it is the one write that cannot be taken
    /// back, because page 3 is OTP.
    case noCapabilityContainer

    /// Page 3 was read, holds a Capability Container, and the NDEF read was
    /// refused anyway. Whatever stops the tag reading is in the data area, so
    /// formatting has nothing to do here. Rewriting the data area is the repair.
    case unreadableDataArea

    /// `true` when the user has something to fix. Drives whether a notice shows
    /// at all, so `.unknown` and `.readable` both render nothing.
    public var needsAttention: Bool {
        self == .noCapabilityContainer || self == .unreadableDataArea
    }

    /// Whether a *completed* NDEF read on this chip family proves the tag's
    /// whole NDEF structure walks.
    ///
    /// True only on the Type-2 page transport, where the reader answers
    /// `queryNDEFStatus` first and a tag with no Capability Container is refused
    /// outright, so a read that came back is a read that walked. The other
    /// families report an unformatted tag as a clean read of **zero records**
    /// rather than as a refusal (`CoreNFCConnectedTag.isUnformattedNDEF`), so
    /// there a completed read says only that nothing refused us. Publishing
    /// "this tag reads" off that would be the same unread claim this whole type
    /// exists to remove, one family over.
    public static func readProvesStructure(_ family: TagFamily?) -> Bool {
        if case .type2 = family {
            return true
        }
        return false
    }

    /// The verdict for a page-addressed chip whose NDEF read came back refused,
    /// given the Capability Container page **as the tag served it**.
    ///
    /// `nil` bytes, or short ones, give `.unknown`. There is no reading to
    /// reason from, and guessing here is the defect this type replaces.
    public static func afterRefusedNDEFRead(capabilityContainer page3: Data?) -> TagFormatState {
        guard let page3, page3.count >= 4 else { return .unknown }
        return Type2CC.isFormatted(page3) ? .unreadableDataArea : .noCapabilityContainer
    }
}
