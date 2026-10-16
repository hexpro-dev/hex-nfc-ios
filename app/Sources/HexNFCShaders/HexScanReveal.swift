import SwiftUI

/// Visual half of the scan-success moment, fired one-shot on `trigger` change.
///
/// Two GPU layers stack for maximum impact:
///  1. A vivid **rainbow chromatic-aberration grid** (`hexRainbowSweepGrid`)
///     that sweeps top→bottom, fading in and out like a scanning pass, drawn
///     additively over the scene with a blurred bloom copy beneath a crisp one.
///  2. An invisible **radial shockwave** (`hexShockwaveDistort`) that refracts
///     the whole scene — grid included — outward from centre as the sweep runs.
///
/// The haptic half stays on `.hexHero(.scanSuccess, trigger:)`, so this is the
/// visual-only counterpart; pair the two on the same trigger. Honours both the
/// system and in-app Reduce-Motion flags (skips entirely) and the snapshot mock
/// (the underlying `hexColorEffect` / `hexDistortionEffect` gates short-circuit).
public extension View {
    func hexScanReveal(trigger: some Equatable) -> some View {
        modifier(HexScanRevealModifier(trigger: trigger))
    }
}

private struct HexScanRevealModifier<T: Equatable>: ViewModifier {
    let trigger: T

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.hexReduceMotion) private var appReduceMotion
    @State private var size: CGSize = .zero

    /// Long enough for the sweep to traverse the screen and the shockwave to
    /// dissipate, short enough to stay a punchy flash. The host should hold the
    /// success screen at least this long before dismissing.
    private static var duration: TimeInterval {
        0.9
    }

    func body(content: Content) -> some View {
        if systemReduceMotion || appReduceMotion {
            content
        } else {
            // Bake the measured size into a Sendable local so the animator
            // closure doesn't capture main-actor `@State`. `body` re-runs when
            // `size` changes, rebuilding the closure with the fresh value.
            let measured = size
            content
                .background(sizeReader)
                .keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, progress in
                    HexScanRevealLayers(base: view, size: measured, progress: progress)
                } keyframes: { _ in
                    LinearKeyframe(1.0, duration: Self.duration)
                }
        }
    }

    private var sizeReader: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { size = geo.size }
                .onChange(of: geo.size) { _, newValue in size = newValue }
        }
    }
}

/// The two stacked GPU layers, parameterised by the sweep `progress`. Applied
/// only while the sweep is running — at rest (`progress == 0`, and once it
/// settles back to an invisible state) the scene renders untouched, so there is
/// no idle offscreen pass.
private struct HexScanRevealLayers<Base: View>: View {
    let base: Base
    let size: CGSize
    let progress: Double

    var body: some View {
        if progress > 0.0001, size.width > 1, size.height > 1 {
            base
                .overlay { grid }
                .hexDistortionEffect(
                    HexShaders.shockwaveDistort(
                        size: size,
                        origin: CGPoint(x: size.width / 2, y: size.height / 2),
                        progress: progress,
                        amplitude: 1.0
                    ),
                    maxSampleOffset: CGSize(width: 36, height: 36)
                )
        } else {
            base
        }
    }

    /// Crisp grid over a blurred copy of itself — the bloom idiom from
    /// `DonationProgressBar`, so the rainbow spills into a soft glow.
    ///
    /// The rectangles are filled **opaque** (not `.clear`): `colorEffect` is a
    /// no-op on a fully transparent layer, so the shader needs real pixels to
    /// run on. It returns transparent everywhere the sweep isn't, so the fill
    /// never shows. `compositingGroup()` flattens the crisp + blurred copies
    /// first, then `plusLighter` blooms the whole grid additively over the UI.
    private var grid: some View {
        let shader = HexShaders.rainbowSweepGrid(size: size, progress: progress, intensity: 1.0)
        return ZStack {
            Rectangle().fill(Color.black)
                .hexColorEffect(shader)
                .blur(radius: 12)
                .opacity(0.9)
            Rectangle().fill(Color.black)
                .hexColorEffect(shader)
        }
        .compositingGroup()
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }
}
