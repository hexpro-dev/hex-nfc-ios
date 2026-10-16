import SwiftUI

/// Visual half of the Advanced-Console "command run finished" moment, fired
/// one-shot on `trigger` change. A living-energy discharge rather than a drawn
/// outline: a noise-warped white-hot plasma rim with drifting hotspots, a
/// turbulent "liquid light" wash that blooms inward, and a heat-haze shimmer.
/// The rim + liquid are one additive `colorEffect` bloom (`hexConsoleBorder`)
/// layered over the log; the haze is a `distortionEffect` (`hexConsoleHaze`)
/// applied to that energy overlay — never to the log, which is a ScrollView a
/// distortion effect would blank.
///
/// The haptic half stays on `.hexHero(.consolePulse, trigger:)`, so this is the
/// visual-only counterpart; pair the two on the same trigger. Honours both the
/// system and in-app Reduce-Motion flags (skips entirely) and the snapshot mock
/// (the underlying `hexColorEffect`/`hexDistortionEffect` gates short-circuit).
public extension View {
    /// - Parameters:
    ///   - trigger: bump on each run completion to fire one pulse.
    ///   - cornerRadius: the log's corner radius, so the rim tracks its rounded
    ///     corners. Callers pass `HexTokens.Radius.m`; the shader module can't
    ///     import the design tokens.
    func hexConsolePulse(trigger: some Equatable, cornerRadius: CGFloat) -> some View {
        modifier(HexConsolePulseModifier(trigger: trigger, cornerRadius: cornerRadius))
    }
}

private struct HexConsolePulseModifier<T: Equatable>: ViewModifier {
    let trigger: T
    let cornerRadius: CGFloat

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.hexReduceMotion) private var appReduceMotion
    @State private var size: CGSize = .zero

    /// Total window. A touch longer than a clean pulse so the noise flow and the
    /// inward liquid-light diffusion have room to read as motion. Tunable.
    private static var duration: TimeInterval {
        0.7
    }

    func body(content: Content) -> some View {
        if systemReduceMotion || appReduceMotion {
            content
        } else {
            // Bake the measured size into a Sendable local so the animator
            // closure doesn't capture main-actor `@State` (mirrors HexScanReveal).
            let measured = size
            let radius = cornerRadius
            let dur = Self.duration
            content
                .background(sizeReader)
                .keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, progress in
                    HexConsolePulseLayers(
                        base: view,
                        size: measured,
                        cornerRadius: radius,
                        progress: progress,
                        duration: dur
                    )
                } keyframes: { _ in
                    LinearKeyframe(1.0, duration: dur)
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

private struct HexConsolePulseLayers<Base: View>: View {
    let base: Base
    let size: CGSize
    let cornerRadius: CGFloat
    let progress: Double
    let duration: Double

    /// Overhang so the warped rim + halo render past the log edge. Must exceed
    /// the shader's peak outward reach (domain warp + halo + aberration). Tunable.
    private static var pad: CGFloat {
        28
    }

    var body: some View {
        // The log is NEVER distorted: it's a ScrollView, and a Metal
        // distortion/color effect on a ScrollView blanks its content (even while
        // animating). The energy overlay carries everything — including the heat
        // haze (see `glow`). Gate on `intensity` so nothing is attached once the
        // pulse is over; at rest we hand back the plain, untouched log.
        if size.width > 1, size.height > 1, intensity > 0.0008 {
            base.overlay { glow }
        } else {
            base
        }
    }

    // MARK: Envelopes

    /// Quick ignite.
    private var attack: Double {
        hexConsoleSmoothstep(0.0, 0.12, progress)
    }

    /// Share of the window spent holding at the edge before release.
    private var holdFrac: Double {
        0.45
    }

    /// 0 during hold, 0→1 on release.
    private var release: Double {
        max(0.0, progress - holdFrac) / (1.0 - holdFrac)
    }

    /// Hold (1) then smooth fade.
    private var fade: Double {
        1.0 - hexConsoleSmoothstep(0.0, 1.0, release)
    }

    /// Rim/liquid master gain: 0→1→0.
    private var intensity: Double {
        attack * fade
    }

    /// Inward contour shrink on release.
    private var contract: Double {
        release
    }

    /// Liquid-light front advances inward across the whole window.
    private var bleed: Double {
        hexConsoleSmoothstep(0.05, 1.0, progress)
    }

    /// Heat haze is a quick passing wave — it hits just after ignition and is
    /// gone in ~0.3s, well before the rim and liquid light finish (~0.7s).
    private var haze: Double {
        let hazeOut = 0.30 // seconds
        let frac = min(0.99, hazeOut / duration)
        return attack * (1.0 - hexConsoleSmoothstep(0.0, frac, progress))
    }

    /// Seconds, for noise flow.
    private var time: Double {
        progress * duration
    }

    /// Plasma rim + liquid light as three opaque-black bloom copies (wide-soft +
    /// mid + crisp), additively composited — the `HexScanReveal` idiom. Opaque
    /// fills give `colorEffect` real pixels; the shader returns transparent off
    /// the effect so `plusLighter` blooms it without the fill showing. Drawn on a
    /// canvas expanded by `pad` (negative padding) so the rim spills outside the
    /// log edge as well as inside — no clip.
    private var glow: some View {
        let shader = HexShaders.consoleBorder(
            size: size,
            cornerRadius: Double(cornerRadius),
            pad: Double(Self.pad),
            intensity: intensity,
            contract: contract,
            bleed: bleed,
            time: time
        )
        // Heat haze refracts the energy itself (it can't safely touch the log —
        // see `body`). The overlay spans the padded canvas, so the shimmer is
        // measured over that space.
        let canvas = CGSize(width: size.width + 2 * Self.pad, height: size.height + 2 * Self.pad)
        let hazeShader = HexShaders.consoleHaze(size: canvas, amplitude: haze, time: time)
        return ZStack {
            Rectangle().fill(Color.black)
                .hexColorEffect(shader)
                .blur(radius: 6)
                .opacity(0.5)
            Rectangle().fill(Color.black)
                .hexColorEffect(shader)
                .blur(radius: 3)
                .opacity(0.9)
            Rectangle().fill(Color.black)
                .hexColorEffect(shader)
        }
        .compositingGroup()
        .hexDistortionEffect(hazeShader, maxSampleOffset: CGSize(width: 12, height: 14))
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
        .padding(-Self.pad) // expand the canvas beyond the log
    }
}

/// Scalar smoothstep (Hermite) — clamps and eases `x` between two edges.
private func hexConsoleSmoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
    guard edge1 > edge0 else { return x < edge0 ? 0 : 1 }
    let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
    return t * t * (3 - 2 * t)
}
