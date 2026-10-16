import SwiftUI

/// Snapshot-test seam. When set to `.mock`, every Hex shader view modifier
/// short-circuits to a deterministic static fill — never touches Metal so
/// snapshot output is identical across CI runners and device classes.
public enum MockShaderProvider: Sendable {
    case real
    case mock

    @MainActor public static var current: MockShaderProvider = .real
}

/// View extensions used by call sites in `HexNFCDesign` / `HexNFCApp` to
/// attach shaders. Each one funnels through the mock + Reduce-Motion gates.
public extension View {
    /// Apply a `colorEffect` shader, dropping it when Reduce Motion is on or
    /// the mock provider is engaged.
    func hexColorEffect(
        _ shader: Shader,
        isEnabled: Bool = true
    ) -> some View {
        modifier(HexColorEffectModifier(shader: shader, isEnabled: isEnabled))
    }

    /// Apply a `distortionEffect` shader with the standard mock + ReduceMotion
    /// gates.
    func hexDistortionEffect(
        _ shader: Shader,
        maxSampleOffset: CGSize = CGSize(width: 6, height: 6),
        isEnabled: Bool = true
    ) -> some View {
        modifier(HexDistortionEffectModifier(
            shader: shader,
            maxSampleOffset: maxSampleOffset,
            isEnabled: isEnabled
        ))
    }

    /// Apply a `layerEffect` shader with the standard mock + ReduceMotion
    /// gates.
    func hexLayerEffect(
        _ shader: Shader,
        maxSampleOffset: CGSize = CGSize(width: 6, height: 6),
        isEnabled: Bool = true
    ) -> some View {
        modifier(HexLayerEffectModifier(
            shader: shader,
            maxSampleOffset: maxSampleOffset,
            isEnabled: isEnabled
        ))
    }
}

private struct HexColorEffectModifier: ViewModifier {
    let shader: Shader
    let isEnabled: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.hexReduceMotion) private var appReduceMotion

    func body(content: Content) -> some View {
        if shouldRunShader(isEnabled: isEnabled, reduceMotion: systemReduceMotion || appReduceMotion) {
            content.colorEffect(shader)
        } else {
            content
        }
    }
}

private struct HexDistortionEffectModifier: ViewModifier {
    let shader: Shader
    let maxSampleOffset: CGSize
    let isEnabled: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.hexReduceMotion) private var appReduceMotion

    func body(content: Content) -> some View {
        if shouldRunShader(isEnabled: isEnabled, reduceMotion: systemReduceMotion || appReduceMotion) {
            content.distortionEffect(shader, maxSampleOffset: maxSampleOffset)
        } else {
            content
        }
    }
}

private struct HexLayerEffectModifier: ViewModifier {
    let shader: Shader
    let maxSampleOffset: CGSize
    let isEnabled: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.hexReduceMotion) private var appReduceMotion

    func body(content: Content) -> some View {
        if shouldRunShader(isEnabled: isEnabled, reduceMotion: systemReduceMotion || appReduceMotion) {
            content.layerEffect(shader, maxSampleOffset: maxSampleOffset)
        } else {
            content
        }
    }
}

@MainActor
private func shouldRunShader(isEnabled: Bool, reduceMotion: Bool) -> Bool {
    if !isEnabled {
        return false
    }
    if reduceMotion {
        return false
    }
    if MockShaderProvider.current == .mock {
        return false
    }
    return true
}
