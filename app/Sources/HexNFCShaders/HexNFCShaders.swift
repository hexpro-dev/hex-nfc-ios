import Foundation

/// Module marker. Metal shaders, CoreHaptics AHAP patterns, and the
/// `.hexHero(...)` composer that pairs them.
///
/// The 11 shader files (`MeshField`, `HexCaustics`, `ScanlineRadial`,
/// `ChromaticAberration`, `DetectionBloom`, `WriteWavefront`, `VerifyShimmer`,
/// `LockInRing`, `ErrorJitter`, `ConsoleGlyphGlow`, `HexagonSliceMask`) live
/// in `Metal/` and are authored as `.metal` source files compiled via the
/// SPM Metal toolchain. The 11 haptic patterns live as `.ahap` JSON in
/// `Haptics/Patterns/`.
public enum HexNFCShaders {
    public static let moduleName = "HexNFCShaders"

    /// Resource bundle that hosts the `.ahap` haptic patterns and `.metal`
    /// shader sources. Exposed so test targets in other modules can verify
    /// the bundled assets without re-importing internals.
    public static var resourceBundle: Bundle {
        Bundle.module
    }
}
