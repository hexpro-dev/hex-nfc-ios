import HexNFCShaders
import SwiftUI

/// Visual half of the **passport-unlock** moment, played on the *scan screen*
/// while the read is in flight (iOS's NFC card is only a partial bottom sheet,
/// so the app stays visible behind it and the reveal builds live during the scan).
///
/// A field of bright rainbow lines climbs from the bottom of the screen; as the
/// leading front passes ~60% of the way up it diverges into concentric circles
/// that ring the Hex logo (`hexPassportReveal`). The field brightens as the read
/// nears completion (it follows the reader's live `progress`), flares in a
/// white-hot burst when the read lands, then slides down and fades, the same
/// recede feel as the scan-success sweep grid. The Hex logo is drawn at the ring
/// centre for the circles to wrap around.
///
/// Because the build follows real read progress, its length is intrinsically
/// tuned to how quickly the unlock happens (a fast read reaches the burst sooner).
///
/// Honours both the system and in-app Reduce-Motion flags (skips the visual, but
/// still lands the success haptic on completion) and the snapshot mock (skips the
/// visual so snapshots stay deterministic).
public extension View {
    /// - Parameters:
    ///   - progress: the reader's live read progress, 0...1 (monotonic). The build
    ///     follows this while `isActive`.
    ///   - finished: flip true when the read lands, to fire the burst + recede and
    ///     the success haptic.
    ///   - isActive: whether a passport read is in flight (drives the overlay on
    ///     and off). Typically `progress > 0`.
    func hexPassportReveal(progress: Double, finished: Bool, isActive: Bool) -> some View {
        modifier(HexPassportRevealModifier(progress: progress, finished: finished, isActive: isActive))
    }
}

/// Per-frame shader inputs, produced by `HexPassportRevealClock`.
private struct HexPassportRevealValues {
    var front: Double = 0
    var intensity: Double = 0
    var burst: Double = 0
    var recede: Double = 0
    var flow: Double = 0
}

private struct HexPassportRevealModifier: ViewModifier {
    let progress: Double
    let finished: Bool
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.hexReduceMotion) private var appReduceMotion

    /// Reference-type animation state, mutated inside the `TimelineView` closure
    /// (a value `@State` there would trip "modifying state during view update").
    @State private var clock = HexPassportRevealClock()

    private var visualsOn: Bool {
        !(systemReduceMotion || appReduceMotion) && MockShaderProvider.current != .mock
    }

    func body(content: Content) -> some View {
        Group {
            if visualsOn, isActive {
                content.overlay { revealOverlay }
            } else {
                content
            }
        }
        // Fire the success haptic once, when the read lands. Synchronous (like
        // `.hexHero`) so nothing lingers if the screen changes, and it still lands
        // under Reduce Motion where the visual is skipped.
        .onChange(of: finished) { _, landed in
            if landed {
                HexHeroMoment.scanSuccess.play()
            }
        }
        // A fresh read reuses this modifier's identity (the scan sheet persists
        // across the tap), so reset the clock each time a read begins.
        .onChange(of: isActive) { _, active in
            if active {
                clock.reset()
            }
        }
    }

    /// Full-bleed overlay that measures its OWN size (so the shader field, the
    /// ringed logo, and `logoY` share one screen coordinate origin) and drives the
    /// shader every frame from the clock. `.ignoresSafeArea()` lets the lines climb
    /// from the true bottom edge under the home indicator.
    private var revealOverlay: some View {
        GeometryReader { geo in
            TimelineView(.animation) { timeline in
                let values = clock.tick(now: timeline.date, target: progress, finished: finished)
                HexPassportRevealField(size: geo.size, values: values)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Eases the shader's build toward the live read `progress`, then runs the fixed
/// burst + recede tail once the read finishes. Driven each frame by the host's
/// `TimelineView`. All state is here (a reference type) so the view stays pure.
private final class HexPassportRevealClock {
    private var started = false
    private var startTime: Double = 0
    private var lastTick: Double = 0
    private var displayed: Double = 0
    private var finishTime: Double?

    /// Fixed tail after the read lands.
    private static let burstUp = 0.12
    private static let burstDown = 0.50
    private static let recedeStart = 0.14
    private static let recedeEnd = 0.62

    func reset() {
        started = false
        displayed = 0
        finishTime = nil
    }

    func tick(now nowDate: Date, target: Double, finished: Bool) -> HexPassportRevealValues {
        let now = nowDate.timeIntervalSinceReferenceDate
        let clampedTarget = min(max(target, 0), 1)
        if !started {
            started = true
            startTime = now
            lastTick = now
            displayed = clampedTarget // begin at the current progress, not a jump from 0
        }
        // Clamp dt so a stalled frame (e.g. the NFC card animating in) doesn't
        // snap the build forward.
        let dt = max(0, min(now - lastTick, 0.1))
        lastTick = now

        // Exponential follow toward the goal (~0.18s time constant). The goal is
        // monotonic, so `displayed` only rises during the build.
        let goal = finished ? 1.0 : clampedTarget
        let follow = 1 - exp(-dt / 0.18)
        displayed = min(max(displayed + (goal - displayed) * follow, 0), 1)

        var values = HexPassportRevealValues()
        values.flow = (now - startTime) * 0.16 // continuous hue + ring expansion

        if finished, finishTime == nil {
            finishTime = now
        }
        if let finishTime {
            let fe = now - finishTime
            let up = smoothstep01(0.0, Self.burstUp, fe)
            let down = smoothstep01(Self.burstUp, Self.burstDown, fe)
            let recede = smoothstep01(Self.recedeStart, Self.recedeEnd, fe)
            values.front = 1.0
            values.burst = max(0.0, up - down)
            values.recede = recede
            values.intensity = displayed * (1.0 - recede)
        } else {
            values.front = displayed
            values.intensity = displayed
        }
        return values
    }
}

/// The GPU reveal layer plus the ringed Hex logo, parameterised by the current
/// frame's values, drawn full-bleed in the overlay's coordinate space. Renders
/// nothing once the field has fully receded so there is no lingering pass.
private struct HexPassportRevealField: View {
    let size: CGSize
    let values: HexPassportRevealValues

    /// Divergence / ring centre, ~60% of the way up the screen (above iOS's card).
    private var logoY: CGFloat {
        size.height * 0.40
    }

    var body: some View {
        let running = values.front > 0.0001
            || values.intensity > 0.0001
            || values.burst > 0.0001
        if running, values.recede < 0.999, size.width > 1, size.height > 1 {
            ZStack {
                field
                logo
            }
            .allowsHitTesting(false)
        }
    }

    private var field: some View {
        let shader = HexShaders.passportReveal(
            size: size,
            front: values.front,
            intensity: values.intensity,
            burst: values.burst,
            recede: values.recede,
            logoY: Double(logoY),
            flow: values.flow
        )
        return bloom(shader, blur: 14)
    }

    /// The Hex logo the circles ring: a crisp mark over a bloomed copy, growing
    /// and brightening with the build, flaring at the burst, and sliding down as
    /// the field recedes.
    private var logo: some View {
        let scale = 0.72 + 0.28 * values.intensity + 0.14 * values.burst
        let appear = smoothstep01(0.0, 0.35, values.front)
        let opacity = appear * (1.0 - smoothstep01(0.0, 0.85, values.recede))
        let glow = 0.35 + 0.65 * values.intensity + values.burst
        return ZStack {
            HexTransition(state: .present, size: 104)
                .blur(radius: 6 + 20 * min(1.0, values.intensity + values.burst))
                .opacity(0.85 * min(1.0, glow))
                .blendMode(.plusLighter)
            HexTransition(state: .present, size: 104)
        }
        .scaleEffect(scale)
        .opacity(opacity)
        .position(x: size.width / 2, y: logoY)
        .offset(y: values.recede * size.height * 1.1)
    }

    /// Crisp shader over a blurred bloom copy, additively composited: the
    /// `HexScanReveal` / `HexWriteBurst` idiom. Opaque-black fills give
    /// `colorEffect` real pixels; the shader returns transparent off the effect
    /// so `plusLighter` blooms it over the scene without the fill showing.
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
    }
}

/// Hermite smoothstep for `Double` (SwiftUI has no scalar `smoothstep`).
private func smoothstep01(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
    guard edge1 != edge0 else { return x < edge0 ? 0 : 1 }
    let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
    return t * t * (3 - 2 * t)
}
