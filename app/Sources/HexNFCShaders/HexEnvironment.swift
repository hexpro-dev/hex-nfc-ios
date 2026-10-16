import SwiftUI

/// Custom environment key that combines the system Reduce-Motion preference
/// with the in-app override toggle from Settings. SwiftUI's built-in
/// `\.accessibilityReduceMotion` is read-only, so we publish this alongside
/// it and route call sites through `hexReduceMotion(_:)` to consult both.
public struct HexReduceMotionKey: EnvironmentKey {
    public static let defaultValue: Bool = false
}

public extension EnvironmentValues {
    /// True when motion should be reduced — either because the user enabled
    /// the system setting or because they ticked the in-app override.
    var hexReduceMotion: Bool {
        get { self[HexReduceMotionKey.self] }
        set { self[HexReduceMotionKey.self] = newValue }
    }
}

public extension View {
    /// Convenience modifier used by `RootView` to publish the effective
    /// Reduce-Motion flag once for the whole subtree.
    func hexReduceMotion(_ enabled: Bool) -> some View {
        environment(\.hexReduceMotion, enabled)
    }
}
