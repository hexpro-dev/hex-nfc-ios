import SwiftUI

/// Namespace for the write-success burst's shared constants.
public enum HexWriteBurst {
    /// Coordinate space the burst renders in. The host names the same space and
    /// reports the logo's centre in it (via a preference) so the ring emanates
    /// exactly from the logo rather than the geometric view centre.
    public static let coordinateSpaceName = "hexWriteBurst"
}

/// Visual half of the write-success moment, fired one-shot on `trigger` change.
///
/// A ring bursts out of the centre logo: a hard white edge rimmed with a
/// chromatic-aberration rainbow that expands fast (`hexRadialBurst`), trailing a
/// soft rippling inner wash that fades slowly. As the ring reaches the edge a
/// flowing rainbow rim glows around the screen (`hexRainbowBorder`) and fades —
/// trail and edge ending together. The whole scene is refracted by a radial
/// shockwave (`hexShockwaveDistort`) synced to the ring.
///
/// The haptic half stays on `.hexHero(.writeLockIn, trigger:)`, so this is the
/// visual-only counterpart; pair the two on the same trigger. Honours both the
/// system and in-app Reduce-Motion flags (skips entirely) and the snapshot mock
/// (the underlying shader gates short-circuit).
public extension View {
    /// - Parameters:
    ///   - trigger: bump when the write lands to fire the burst once.
    ///   - origin: burst centre (the logo) in the `HexWriteBurst` coordinate
    ///     space; falls back to the view centre when nil.
    func hexWriteBurst(trigger: some Equatable, origin: CGPoint? = nil) -> some View {
        modifier(HexWriteBurstModifier(trigger: trigger, origin: origin))
    }
}

/// Multi-track keyframe state: a fast ring, a slow-fading inner trail, a delayed
/// screen-edge glow, and a continuous hue/ripple flow.
private struct HexBurstValues {
    var ring: Double = 0
    var trail: Double = 0
    var edge: Double = 0
    var flow: Double = 0
}

private struct HexWriteBurstModifier<T: Equatable>: ViewModifier {
    let trigger: T
    let origin: CGPoint?

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.hexReduceMotion) private var appReduceMotion
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        if systemReduceMotion || appReduceMotion {
            content
        } else {
            let measured = size
            let anchor = origin
            content
                .background(sizeReader)
                .coordinateSpace(.named(HexWriteBurst.coordinateSpaceName))
                .keyframeAnimator(initialValue: HexBurstValues(), trigger: trigger) { view, values in
                    HexWriteBurstLayers(base: view, size: measured, origin: anchor, values: values)
                } keyframes: { _ in
                    // Ring: launches fast, eases as it reaches the edge, then
                    // holds off-screen for the remainder.
                    KeyframeTrack(\.ring) {
                        CubicKeyframe(1.0, duration: 0.45)
                        LinearKeyframe(1.0, duration: 1.15)
                    }
                    // Trail: rises with the ring, then a long slow fade — gone
                    // by ~1.6s, together with the edge glow.
                    KeyframeTrack(\.trail) {
                        SpringKeyframe(1.0, duration: 0.32)
                        LinearKeyframe(0.85, duration: 0.33)
                        LinearKeyframe(0.0, duration: 0.95)
                    }
                    // Edge: flat until the ring reaches the rim, flash on, glow
                    // for a beat, then fade out by ~1.6s.
                    KeyframeTrack(\.edge) {
                        LinearKeyframe(0.0, duration: 0.40)
                        CubicKeyframe(1.0, duration: 0.18)
                        LinearKeyframe(1.0, duration: 0.40)
                        CubicKeyframe(0.0, duration: 0.62)
                    }
                    // Flow: continuous hue rotation + ripple advance over the
                    // whole burst.
                    KeyframeTrack(\.flow) {
                        LinearKeyframe(1.0, duration: 1.60)
                    }
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

private struct HexWriteBurstLayers<Base: View>: View {
    let base: Base
    let size: CGSize
    let origin: CGPoint?
    let values: HexBurstValues

    var body: some View {
        let active = values.ring > 0.0001 || values.trail > 0.0001 || values.edge > 0.0001
        if active, size.width > 1, size.height > 1 {
            base
                .overlay { burst }
                .overlay { edgeGlow }
                .hexDistortionEffect(
                    HexShaders.shockwaveDistort(
                        size: size,
                        origin: center,
                        progress: values.ring,
                        amplitude: max(0.0, 1.0 - values.ring) // punch fades as the ring leaves
                    ),
                    maxSampleOffset: CGSize(width: 36, height: 36)
                )
        } else {
            base
        }
    }

    private var center: CGPoint {
        if let origin {
            return origin
        }
        return CGPoint(x: size.width / 2, y: size.height / 2)
    }

    /// Distance from the origin to the farthest corner (+ a small margin), so
    /// the ring fully clears the screen.
    private var maxRadius: Double {
        let o = center
        let corners = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: size.width, y: 0),
            CGPoint(x: 0, y: size.height),
            CGPoint(x: size.width, y: size.height),
        ]
        let far = corners.map { hypot($0.x - o.x, $0.y - o.y) }.max() ?? max(size.width, size.height)
        return Double(far) * 1.05
    }

    private var burst: some View {
        let ringRadius = values.ring * maxRadius
        let ringWidth = max(maxRadius * 0.06, 18.0)
        let shader = HexShaders.radialBurst(
            size: size,
            origin: center,
            ringRadius: ringRadius,
            ringWidth: ringWidth,
            trail: values.trail,
            hueShift: values.flow,
            intensity: 1.0
        )
        return bloom(shader, blur: 16)
    }

    private var edgeGlow: some View {
        // `cornerRadius` approximates a modern device's display corner; the glow
        // is soft, so an exact value isn't load-bearing.
        let shader = HexShaders.rainbowBorder(
            size: size,
            cornerRadius: 44,
            shrink: 0.0,
            hueShift: values.flow,
            intensity: values.edge,
            time: values.flow,
            shudder: 0.0, // the write rim flows smoothly. No shudder
            radial: 0.0 // rainbow flows around the perimeter
        )
        return bloom(shader, blur: 18)
    }

    /// Crisp shader over a blurred bloom copy, additively composited — the
    /// `HexScanReveal` idiom. Opaque-black fills give `colorEffect` real pixels;
    /// the shader returns transparent off the effect so `plusLighter` blooms it
    /// over the scene without the fill showing.
    private func bloom(_ shader: Shader, blur: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(Color.black)
                .hexColorEffect(shader)
                .blur(radius: blur)
                .opacity(0.9)
            Rectangle().fill(Color.black)
                .hexColorEffect(shader)
        }
        .compositingGroup()
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }
}
