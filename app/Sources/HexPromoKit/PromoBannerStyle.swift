import CoreGraphics

/// Visual styling for a ``PromoBanner``. Deliberately minimal and theme-agnostic:
/// the banner is just the media scaled to fit with rounded corners. Each host app
/// passes its own corner radius.
public struct PromoBannerStyle: Sendable, Equatable {
    /// Corner radius applied to the clipped media. Default 12.
    public var cornerRadius: CGFloat
    /// Duration of the fade-in when a promo first appears.
    public var fadeInDuration: Double

    public init(cornerRadius: CGFloat = 12, fadeInDuration: Double = 0.3) {
        self.cornerRadius = cornerRadius
        self.fadeInDuration = fadeInDuration
    }

    /// The default style (corner radius 12).
    public static let `default` = PromoBannerStyle()
}
