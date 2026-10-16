import HexNFCShaders
import SwiftUI

public extension View {
    /// The slow breathing scale the scan affordance uses while it waits for a
    /// tag, which stops entirely when the reader has asked for reduced motion.
    ///
    /// The gate is here rather than at the call site on purpose. Both times
    /// this app has shipped an unguarded animation, it was because the decision
    /// was left to a *screen*: `ScanSheet` never declared a reduce-motion
    /// environment value at all, and `TransitResultSheet` declared one that
    /// nothing read. A screen cannot forget a gate it does not own, so
    /// `HexTokens.Motion.scanPulse` is module-internal and this is the only way
    /// to spell the loop.
    ///
    /// - Parameter active: whether the pulse should be running right now.
    func hexPulse(active: Bool) -> some View {
        modifier(HexPulseModifier(active: active))
    }
}

private struct HexPulseModifier: ViewModifier {
    let active: Bool

    /// Both flags, per the house rule: the system setting and the in-app
    /// override are separate switches and either one means stop.
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.hexReduceMotion) private var appReduceMotion

    private var reduceMotion: Bool {
        systemReduceMotion || appReduceMotion
    }

    func body(content: Content) -> some View {
        if reduceMotion {
            // Nothing applied at all, rather than the same animation with a nil
            // curve. A `repeatForever` that is merely un-animated is still a
            // running animation, and toggling the setting from Control Centre
            // mid-scan would otherwise leave the mark parked at whatever scale
            // the loop had reached. This branch renders it at rest.
            //
            // Matching `HexScanReveal` and `HexWriteBurst`, which resolve to
            // their finished state the same way.
            content
        } else {
            content
                .scaleEffect(active ? HexTokens.Motion.pulseScale : 1.0)
                .animation(HexTokens.Motion.scanPulse, value: active)
        }
    }
}
