import SwiftUI

/// Swift wrappers around the Hex NFC Metal shader library. Each wrapper is a
/// thin builder around `Shader(function:arguments:)` returning a view
/// modifier that callers can attach via `.modifier(...)`.
///
/// Every wrapper participates in three gates:
///  * `MockShaderProvider.current` — snapshot tests inject `.mock` to short
///    circuit shaders to deterministic flat fills.
///  * `@Environment(\.accessibilityReduceMotion)` — callers wrap the shader
///    application via `View.hexShader(_:)` which silently drops the effect
///    when the user has Reduce Motion on. (Mesh & caustic shaders still
///    render in their idle-pose form.)
///  * `@Environment(\.colorScheme)` — colors are passed in by callers from
///    `HexTokens.Color`; the shader module never imports the design module
///    to keep the dep graph acyclic.
public enum HexShaders {
    /// Returns the shader library bundled with `HexNFCShaders` so the
    /// `Shader(function:)` initialiser can find `[[stitchable]]` functions
    /// inside the SPM-built Metal default library.
    public static var library: ShaderLibrary {
        ShaderLibrary.bundle(Bundle.module)
    }

    // MARK: - MeshField

    public static func meshField(
        time: Double,
        size: CGSize,
        colors: (Color, Color, Color, Color)
    ) -> Shader {
        Shader(
            function: .init(library: library, name: "hexMeshField"),
            arguments: [
                .float2(Float(size.width), Float(size.height)),
                .float(Float(time)),
                .color(colors.0),
                .color(colors.1),
                .color(colors.2),
                .color(colors.3),
            ]
        )
    }

    // MARK: - HexCaustics

    public static func hexCaustics(
        time: Double,
        intensity: Double,
        size: CGSize,
        tintCool: Color,
        tintWarm: Color
    ) -> Shader {
        Shader(
            function: .init(library: library, name: "hexCaustics"),
            arguments: [
                .float2(Float(size.width), Float(size.height)),
                .float(Float(time)),
                .float(Float(intensity)),
                .color(tintCool),
                .color(tintWarm),
            ]
        )
    }

    // MARK: - ScanlineRadial

    public static func scanlineRadial(
        origin: CGPoint,
        radius: Double,
        thickness: Double,
        ringColor: Color
    ) -> Shader {
        Shader(
            function: .init(library: library, name: "hexScanlineRadial"),
            arguments: [
                .float2(Float(origin.x), Float(origin.y)),
                .float(Float(radius)),
                .float(Float(thickness)),
                .color(ringColor),
            ]
        )
    }

    // MARK: - ChromaticAberration

    public static func chromaticAberration(
        progress: Double,
        amount: Double
    ) -> Shader {
        Shader(
            function: .init(library: library, name: "hexChromaticAberration"),
            arguments: [
                .float(Float(progress)),
                .float(Float(amount)),
            ]
        )
    }

    // MARK: - RainbowSweepGrid

    /// Vivid rainbow chromatic-aberration grid that sweeps top→bottom. Apply as
    /// a `colorEffect` to a transparent full-bleed overlay. `progress` runs 0→1
    /// over the sweep; `intensity` is a master gain (1.0 = full).
    public static func rainbowSweepGrid(
        size: CGSize,
        progress: Double,
        intensity: Double
    ) -> Shader {
        Shader(
            function: .init(library: library, name: "hexRainbowSweepGrid"),
            arguments: [
                .float2(Float(size.width), Float(size.height)),
                .float(Float(progress)),
                .float(Float(intensity)),
            ]
        )
    }

    // MARK: - RainbowBorder

    /// Rainbow rounded-rect border glow — a white-hot outline wrapped in a
    /// chromatic-aberration rainbow halo. Apply as a `colorEffect` to an opaque
    /// full-bleed layer. `shrink` (0..~0.45) pulls the outline inward per side;
    /// `hueShift` (turns) flows the spectrum around the rim; `intensity` is a
    /// master gain. `time` (seconds) + `shudder` (0..1) make the rim tremble and
    /// shimmer with unstable energy — pass `shudder: 0` for a smooth rim. Shared
    /// by the console pulse (contracts + shudders) and the write-success edge
    /// glow (rims the screen, flowing, smooth).
    public static func rainbowBorder(
        size: CGSize,
        cornerRadius: Double,
        shrink: Double,
        hueShift: Double,
        intensity: Double,
        time: Double,
        shudder: Double,
        radial: Double,
        pad: Double = 0
    ) -> Shader {
        Shader(
            function: .init(library: library, name: "hexRainbowBorder"),
            arguments: [
                .float2(Float(size.width), Float(size.height)),
                .float(Float(cornerRadius)),
                .float(Float(shrink)),
                .float(Float(hueShift)),
                .float(Float(intensity)),
                .float(Float(time)),
                .float(Float(shudder)),
                .float(Float(radial)),
                .float(Float(pad)),
            ]
        )
    }

    // MARK: - ConsoleBorder

    /// Living-energy border for the Advanced-Console pulse — a domain-warped
    /// white-hot rim (drifting hotspots, chromatic fringe) plus a turbulent
    /// "liquid light" wash that blooms inward. Apply as a `colorEffect` to an
    /// opaque full-bleed layer drawn on a canvas expanded by `pad` per side so
    /// the rim's halo spills outside the log edge. `intensity` (0..1) is the
    /// ignite→fade gain; `contract` (0..1) pulls the contour inward ~10% per
    /// side on release; `bleed` (0..1) advances the inward liquid-light front;
    /// `time` (s) flows the noise. Pair with `consoleHaze` for the refraction.
    public static func consoleBorder(
        size: CGSize,
        cornerRadius: Double,
        pad: Double,
        intensity: Double,
        contract: Double,
        bleed: Double,
        time: Double
    ) -> Shader {
        Shader(
            function: .init(library: library, name: "hexConsoleBorder"),
            arguments: [
                .float2(Float(size.width), Float(size.height)),
                .float(Float(cornerRadius)),
                .float(Float(pad)),
                .float(Float(intensity)),
                .float(Float(contract)),
                .float(Float(bleed)),
                .float(Float(time)),
            ]
        )
    }

    // MARK: - ConsoleHaze

    /// Heat-haze refraction for the Advanced-Console pulse — an fbm shimmer that
    /// bends the log's actual content, strongest near the rim and biased
    /// vertically (rising heat). Apply as a `distortionEffect` to the log itself.
    /// `amplitude` (0..1) gains the displacement; `time` (s) flows the shimmer.
    public static func consoleHaze(
        size: CGSize,
        amplitude: Double,
        time: Double
    ) -> Shader {
        Shader(
            function: .init(library: library, name: "hexConsoleHaze"),
            arguments: [
                .float2(Float(size.width), Float(size.height)),
                .float(Float(amplitude)),
                .float(Float(time)),
            ]
        )
    }

    // MARK: - RadialBurst

    /// Expanding rainbow ring + soft rippling inner trail, bursting from
    /// `origin`. Apply as a `colorEffect` to an opaque full-bleed layer.
    /// `ringRadius` / `ringWidth` are in points; `trail` gains the inner wash
    /// (its own keyframe), `hueShift` (turns) flows the spectrum + ripple, and
    /// `intensity` gains the ring. Drives the write-success burst.
    public static func radialBurst(
        size: CGSize,
        origin: CGPoint,
        ringRadius: Double,
        ringWidth: Double,
        trail: Double,
        hueShift: Double,
        intensity: Double
    ) -> Shader {
        Shader(
            function: .init(library: library, name: "hexRadialBurst"),
            arguments: [
                .float2(Float(size.width), Float(size.height)),
                .float2(Float(origin.x), Float(origin.y)),
                .float(Float(ringRadius)),
                .float(Float(ringWidth)),
                .float(Float(trail)),
                .float(Float(hueShift)),
                .float(Float(intensity)),
            ]
        )
    }

    // MARK: - PassportReveal

    /// Passport-unlock reveal: vertical lines climb from the bottom and diverge
    /// into concentric rainbow circles ringing the logo, brighten to a burst,
    /// then slide down and fade. Apply as a `colorEffect` to an opaque full-bleed
    /// layer. `front` (0..1) is the rising leading edge; `intensity` (0..1) is the
    /// master gain that grows toward completion; `burst` (0..1) is the white-hot
    /// flash from the logo; `recede` (0..1) slides the field down and fades it;
    /// `logoY` (points) is the divergence / ring centre; `flow` advances
    /// continuously to flow the spectrum and expand the rings.
    public static func passportReveal(
        size: CGSize,
        front: Double,
        intensity: Double,
        burst: Double,
        recede: Double,
        logoY: Double,
        flow: Double
    ) -> Shader {
        Shader(
            function: .init(library: library, name: "hexPassportReveal"),
            arguments: [
                .float2(Float(size.width), Float(size.height)),
                .float(Float(front)),
                .float(Float(intensity)),
                .float(Float(burst)),
                .float(Float(recede)),
                .float(Float(logoY)),
                .float(Float(flow)),
            ]
        )
    }

    // MARK: - ShockwaveDistort

    /// Invisible radial shockwave — a refraction-only `distortionEffect` pulse
    /// expanding from `origin`. `progress` runs 0→1; `amplitude` is a master
    /// gain. Pair the host `maxSampleOffset` with the shader's internal scale.
    public static func shockwaveDistort(
        size: CGSize,
        origin: CGPoint,
        progress: Double,
        amplitude: Double
    ) -> Shader {
        Shader(
            function: .init(library: library, name: "hexShockwaveDistort"),
            arguments: [
                .float2(Float(size.width), Float(size.height)),
                .float2(Float(origin.x), Float(origin.y)),
                .float(Float(progress)),
                .float(Float(amplitude)),
            ]
        )
    }

    // MARK: - DetectionBloom

    public static func detectionBloom(
        origin: CGPoint,
        radius: Double,
        progress: Double,
        bloomColor: Color
    ) -> Shader {
        Shader(
            function: .init(library: library, name: "hexDetectionBloom"),
            arguments: [
                .float2(Float(origin.x), Float(origin.y)),
                .float(Float(radius)),
                .float(Float(progress)),
                .color(bloomColor),
            ]
        )
    }

    // MARK: - WriteWavefront

    public static func writeWavefront(
        progress: Double,
        crestColor: Color
    ) -> Shader {
        Shader(
            function: .init(library: library, name: "hexWriteWavefront"),
            arguments: [
                .float(Float(progress)),
                .color(crestColor),
            ]
        )
    }

    // MARK: - VerifyShimmer

    public static func verifyShimmer(
        time: Double,
        shimmerColor: Color
    ) -> Shader {
        Shader(
            function: .init(library: library, name: "hexVerifyShimmer"),
            arguments: [
                .float(Float(time)),
                .color(shimmerColor),
            ]
        )
    }

    // MARK: - LockInRing

    public static func lockInRing(
        origin: CGPoint,
        phase: Double,
        maxRadius: Double,
        ringColor: Color
    ) -> Shader {
        Shader(
            function: .init(library: library, name: "hexLockInRing"),
            arguments: [
                .float2(Float(origin.x), Float(origin.y)),
                .float(Float(phase)),
                .float(Float(maxRadius)),
                .color(ringColor),
            ]
        )
    }

    // MARK: - ErrorJitter

    public static func errorJitter(
        intensity: Double,
        time: Double
    ) -> Shader {
        Shader(
            function: .init(library: library, name: "hexErrorJitter"),
            arguments: [
                .float(Float(intensity)),
                .float(Float(time)),
            ]
        )
    }

    // MARK: - ConsoleGlyphGlow

    public static func consoleGlow(
        freshness: Double,
        glowColor: Color
    ) -> Shader {
        Shader(
            function: .init(library: library, name: "hexConsoleGlow"),
            arguments: [
                .float(Float(freshness)),
                .color(glowColor),
            ]
        )
    }

    // MARK: - HexagonSliceMask

    public static func sliceMask(
        origin: CGPoint,
        radius: Double,
        stageFrame: Double,
        stageCaret: Double,
        stageInvCaret: Double
    ) -> Shader {
        Shader(
            function: .init(library: library, name: "hexSliceMask"),
            arguments: [
                .float2(Float(origin.x), Float(origin.y)),
                .float(Float(radius)),
                .float(Float(stageFrame)),
                .float(Float(stageCaret)),
                .float(Float(stageInvCaret)),
            ]
        )
    }
}
