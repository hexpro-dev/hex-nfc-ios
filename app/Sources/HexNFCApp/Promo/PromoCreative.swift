import Foundation

/// The one promo slot this app owns.
///
/// The Hex Promo CMS stores a creative under exactly
/// `bundleId|platform|locationId`, and nothing on this side can check any of the
/// three against the registry: a wrong value compiles and renders identically to
/// a slot that simply has no creative configured. The failure it produces is a
/// banner nobody ever sees, so each part is written once and read nowhere else.
/// `PromoBannerBehaviourTests` pins the two values kept here against what the
/// registry row was created with, which catches a later edit but cannot catch
/// the row having been created wrong in the first place.
///
/// Two of the three are here. The platform is not, deliberately: it is the SDK's
/// own `PromoPlatform.ios` in `HomePromoSlot`, sitting beside the registration
/// that has to agree with it, so there is no second spelling of it to drift.
///
/// `home_bottom` is snake case because the CMS slot registry is, and matching
/// the registry exactly is the whole job. Creating the row on the CMS side is a
/// manual step in `hex-promo`; no code in this repository can do it.
enum HexPromoSlot {
    /// The app's bundle identifier, which is also the CMS tenant key.
    static let bundleID = "pro.hex.nfc"

    /// The foot of Home, under the development-costs card.
    static let homeBottom = "home_bottom"
}

/// Everything the banner needs in order to draw, translated out of the SDK's
/// own model.
///
/// This type is the reason the vendored SDK is imported by exactly one file in
/// `HexNFCApp`. The translation happens at the boundary in `HomePromoSlot`, and
/// everything downstream of it (the banner, the video player) is ordinary app
/// code with no vendored type in its signature.
///
/// The rule it follows: adaptation happens in our files and never in the
/// vendored ones, which are kept byte for byte so the next copy from upstream
/// stays a copy instead of becoming a merge.
/// `app/Sources/HexPromoKit/PROVENANCE.md` records that, together with the
/// upstream commit the copy is pinned to. The narrower the surface our files
/// touch, the smaller that re-sync is, and a banner built on this struct can be
/// previewed with no network, no cache directory and no manager singleton in
/// the way.
struct PromoCreative: Equatable, Sendable {
    /// The CMS creative id. Identifies the campaign in a diagnostic, and it is
    /// the value that changes when the campaign does.
    let id: String

    /// A LOCAL file URL. The manager has already downloaded the media, reusing
    /// the file on disk when the etag is unchanged, so nothing downstream of
    /// here touches the network.
    let mediaURL: URL

    /// Video rather than image. The CMS serves either.
    let isVideo: Bool

    /// The creative's own declared aspect ratio, so the banner reserves the box
    /// the art was authored for instead of squeezing it into a house shape.
    let aspectRatio: Double

    /// Where a tap goes, or nil when the creative carries no link.
    let linkURL: URL?

    var isTappable: Bool {
        linkURL != nil
    }
}
