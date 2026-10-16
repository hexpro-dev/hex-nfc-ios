import HexNFCShaders
import SwiftUI

/// A soft, slow-moving rainbow glow bar used for the development-costs
/// donation affordance. The rainbow is deliberately gentle and is the *only*
/// place the brand strays from blue — see `HexTokens.Gradient.rainbow`.
///
/// Honours both the system Reduce Motion setting and the app's
/// `\.hexReduceMotion`: when either is on, the gradient freezes to a static
/// sweep (no scrolling, no glow pulse).
public struct DonationProgressBar: View {
    private let fraction: Double

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.hexReduceMotion) private var appReduceMotion

    /// - Parameter fraction: recovered share, clamped to `0...1`.
    public init(fraction: Double) {
        self.fraction = min(max(fraction, 0), 1)
    }

    private static let loopSeconds: Double = 9

    public var body: some View {
        let reduceMotion = systemReduceMotion || appReduceMotion
        GeometryReader { geo in
            let trackWidth = geo.size.width
            // Keep a sliver visible even at very low fractions.
            let fillWidth = max(trackWidth * fraction, 8)
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(HexTokens.Color.surface2)
                fill(width: fillWidth, reduceMotion: reduceMotion)
            }
        }
        .frame(height: 12)
        .accessibilityElement()
        .accessibilityLabel(Text("Development costs recovered"))
        .accessibilityValue(Text("\(Int((fraction * 100).rounded())) percent"))
    }

    @ViewBuilder
    private func fill(width: CGFloat, reduceMotion: Bool) -> some View {
        if reduceMotion {
            layered(width: width) { staticGradient }
        } else {
            TimelineView(.animation) { timeline in
                let elapsed = timeline.date.timeIntervalSinceReferenceDate
                let phase = CGFloat(
                    elapsed.truncatingRemainder(dividingBy: Self.loopSeconds) / Self.loopSeconds
                )
                layered(width: width) { scrollingGradient(phase: phase) }
            }
        }
    }

    /// Stacks a crisp capsule fill over a clipped-then-blurred copy of itself,
    /// so the rainbow spills past the bar's edges as a soft outer glow.
    private func layered(
        width: CGFloat,
        @ViewBuilder _ content: () -> some View
    ) -> some View {
        ZStack {
            content()
                .frame(width: width)
                .clipShape(Capsule(style: .continuous))
                .blur(radius: 14)
                .opacity(0.75)
            content()
                .frame(width: width)
                .clipShape(Capsule(style: .continuous))
        }
    }

    private var staticGradient: LinearGradient {
        LinearGradient(
            colors: HexTokens.Gradient.rainbow,
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    /// An over-wide gradient (the spectrum tiled twice) offset horizontally so
    /// it scrolls seamlessly: shifting by one tile width lands on an identical
    /// pattern, so the loop never jumps.
    private func scrollingGradient(phase: CGFloat) -> some View {
        GeometryReader { geo in
            let tile = geo.size.width
            LinearGradient(
                colors: HexTokens.Gradient.rainbow + HexTokens.Gradient.rainbow,
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: tile * 2)
            .offset(x: -phase * tile)
        }
    }
}
