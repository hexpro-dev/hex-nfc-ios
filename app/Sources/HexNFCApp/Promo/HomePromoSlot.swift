import HexPromoKit
import SwiftUI

/// The platform component of the CMS join key, spelled once and used by both
/// sides of the join. The registrar below hands this value to `register`, which
/// keys the registration off `platform.rawValue`, and `cacheKey` reads back
/// under that same raw value. Keeping the enum for the write and a matching
/// string literal for the read left nothing between the two but the author's
/// attention: let them drift and the manager publishes under one key while this
/// view reads another, which surfaces as a banner that silently never appears.
private let promoPlatform: PromoPlatform = .ios

/// The cross-promo slot at the foot of Home, and the ONLY file in `HexNFCApp`
/// that imports `HexPromoKit`.
///
/// `PromoImportContainmentTests` pins that, and the reason is blast radius:
/// everything downstream takes a `PromoCreative`, which is ordinary app code, so
/// re-reading an upstream API change means re-reading this one file rather than
/// surveying the app. `app/Sources/HexPromoKit/PROVENANCE.md` names this file as
/// the sole importer in its re-sync steps, for the same reason.
///
/// The view renders nothing until the manager resolves a real creative, and
/// "nothing" means a genuine absence rather than a collapsed box. See
/// `HexPromoBanner` for what that costs if it is got wrong.
struct HomePromoSlot: View {
    /// The vendored manager is a Combine `ObservableObject`, so this is an
    /// `@ObservedObject` in an app that reaches for Observation everywhere
    /// else. Mirroring it into an observable wrapper was the alternative and it
    /// buys a second source of truth and nothing more.
    @ObservedObject private var manager = PromoManager.shared

    /// The SwiftUI seam rather than `UIApplication.shared.open`, which is what
    /// upstream's banner used. It compiles on the macOS host that `swift build`
    /// and `swift test` run on, so this file needs no `#if canImport(UIKit)` and
    /// gets compiled by CI rather than skipped. It can also be overridden from
    /// the environment, which `UIApplication` cannot. Web, App Store and Play
    /// Store links are all an ordinary open.
    @Environment(\.openURL) private var openURL

    /// Registration is a side effect in an initialiser, which is normally the
    /// thing to avoid. It is right here for the reason upstream found:
    /// `@StateObject` is built from an autoclosure SwiftUI evaluates exactly
    /// once per view identity. `.onAppear` would re-fire every time Home comes
    /// back into view, and because `PromoManager` collapses registrations into
    /// one batch request behind a 250 ms debounce, each of those re-fires
    /// cancels the pending fetch and starts the 250 ms again.
    @StateObject private var registrar = PromoSlotRegistrar()

    /// The read half of the join, built from the same three values the
    /// registrar writes with. A stored value rather than a private computed one
    /// so a test can compare it with the key the CMS row was created under.
    static let cacheKey = PromoCacheKey.make(
        bundleId: HexPromoSlot.bundleID,
        platform: promoPlatform.rawValue,
        locationId: HexPromoSlot.homeBottom
    )

    var body: some View {
        // No creative means no view at all, not a reserved box. For most of this
        // app's life the slot has nothing configured, and a placeholder would
        // put a permanent hole under the development-costs card.
        if let creative = Self.creative(from: manager.resolution(for: Self.cacheKey)) {
            HexPromoBanner(creative: creative) { openURL($0) }
        }
    }

    /// The SDK's resolution, translated into the app's own model.
    ///
    /// `.resolved` is the only case that draws anything. `.unresolved` means
    /// "we have not heard back yet" and `.empty` means "there is nothing
    /// configured for this slot"; to a reader of Home they are the same thing.
    static func creative(from resolution: PromoResolution) -> PromoCreative? {
        guard case .resolved(let promo, let mediaURL) = resolution else { return nil }
        return PromoCreative(
            id: promo.creativeId,
            mediaURL: mediaURL,
            isVideo: promo.mediaType == .video,
            aspectRatio: usableAspectRatio(promo.aspectRatio),
            linkURL: promo.isTappable ? promo.linkUrl.flatMap { URL(string: $0) } : nil
        )
    }

    /// The creative's declared aspect ratio, or a square when the CMS sent
    /// something that is not a shape.
    ///
    /// `ResolvedPromo.aspectRatio` divides `aspectWidth` by `aspectHeight` and
    /// guards the zero denominator alone, so `aspectWidth: 0` arrives here as 0
    /// and a single negative side arrives negative. The banner takes its whole
    /// box from `.aspectRatio(_:contentMode:)`, which has no meaning for
    /// either, and this is the boundary where a server value becomes an app
    /// one. A square is what the SDK itself substitutes for the case it does
    /// guard.
    static func usableAspectRatio(_ declared: Double) -> Double {
        declared > 0 ? declared : 1
    }
}

/// Registers the slot exactly once per view identity.
///
/// A class with a side-effecting initialiser and nothing else: no state, no
/// published property, no method. The type exists because "do this once, when
/// the view first appears" is something SwiftUI expresses through `@StateObject`
/// and through nothing else.
///
/// The call waits for the next main-actor turn. SwiftUI builds a `@StateObject`
/// in the middle of a view update, and `register` publishes straight away (it
/// seeds the slot as `.unresolved`) on the manager this view observes. Made
/// synchronously, that is SwiftUI's "Publishing changes from within view
/// updates is not allowed" runtime issue, logged on every launch.
@MainActor
private final class PromoSlotRegistrar: ObservableObject {
    init() {
        Task {
            PromoManager.shared.register(
                bundleId: HexPromoSlot.bundleID,
                platform: promoPlatform,
                locationId: HexPromoSlot.homeBottom
            )
        }
    }
}
