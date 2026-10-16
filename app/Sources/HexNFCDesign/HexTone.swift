import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// One colour, held as numbers rather than as a `SwiftUI.Color`.
///
/// `Color` is a black box: there is no supported way to read components back
/// out of one on every platform, and `resolve(in:)` needs an environment. The
/// contrast guard in `WCAGContrastTests` has to compute relative luminance from
/// the values that actually ship, so the palette keeps them as `Double`s and
/// hands `Color` out at the edge.
///
/// Components are sRGB, matching `SwiftUI.Color(red:green:blue:)` and
/// `UIColor(red:green:blue:alpha:)`. Neither is Display P3, so routing the
/// palette through `UIColor` for the Increase Contrast support below does not
/// shift a single existing colour.
public struct HexInk: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// From a `0xRRGGBB` literal, which is how the palette reads on the page.
    public init(_ hex: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    public var color: SwiftUI.Color {
        SwiftUI.Color(red: red, green: green, blue: blue).opacity(alpha)
    }

    /// This ink painted over `background`, per the usual source-over rule.
    ///
    /// Contrast is a property of what the eye receives, so a translucent
    /// foreground has no ratio of its own: `cardTextDim` at 72% white measures
    /// as one thing over the top of the transit gradient and another over the
    /// bottom. The guard composites before it measures, and so must anything
    /// else reasoning about these numbers.
    public func composited(over background: HexInk) -> HexInk {
        guard alpha < 1 else { return self }
        let a = alpha
        return HexInk(
            red: red * a + background.red * (1 - a),
            green: green * a + background.green * (1 - a),
            blue: blue * a + background.blue * (1 - a),
            alpha: background.alpha
        )
    }
}

/// A palette entry: one colour, plus the colour it becomes when the reader has
/// turned on **Settings > Accessibility > Display & Text Size > Increase
/// Contrast**.
///
/// The tier lives inside the token on purpose. `HexTokens.Color` is referenced
/// in the low hundreds across three dozen files, and the obvious alternative,
/// reading `@Environment(\.colorSchemeContrast)` at each of them and branching,
/// is a change that ships half-applied the first time someone adds a view and
/// forgets. It also cannot reach `HexConsole`, which puts a colour into an
/// `AttributedString` where there is no environment to read.
///
/// So the branch happens once, here, in a dynamic `UIColor` whose provider UIKit
/// re-runs whenever the trait collection changes. A token that names no sibling
/// is the same colour in both tiers, which is what makes this additive: turning
/// the mechanism on cannot alter the default appearance of anything.
public struct HexTone: Equatable, Sendable {
    /// What the reader sees normally.
    public let standard: HexInk
    /// What the reader sees with Increase Contrast on. Equal to `standard`
    /// unless a sibling was given.
    public let increased: HexInk

    public init(_ standard: HexInk, increased: HexInk? = nil) {
        self.standard = standard
        self.increased = increased ?? standard
    }

    public init(_ hex: UInt32, alpha: Double = 1, increased: HexInk? = nil) {
        self.init(HexInk(hex, alpha: alpha), increased: increased)
    }

    /// The ink for a given tier. The guard uses this to measure both without
    /// needing an environment; `colorSchemeContrast` is get-only, so no test
    /// can build one with Increase Contrast on.
    public func ink(increasedContrast: Bool) -> HexInk {
        increasedContrast ? increased : standard
    }

    public var color: SwiftUI.Color {
        #if canImport(UIKit)
        guard standard != increased else { return standard.color }
        return SwiftUI.Color(uiColor: UIColor { traits in
            let ink = traits.accessibilityContrast == .high ? increased : standard
            return UIColor(
                red: ink.red, green: ink.green, blue: ink.blue, alpha: ink.alpha
            )
        })
        #else
        // The package builds for macOS so the suite can run on the host,
        // but the app is iOS-only and this path never renders to a reader.
        return standard.color
        #endif
    }
}
