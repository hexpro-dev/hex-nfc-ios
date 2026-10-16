import SwiftUI

/// One named moment in the app's signature feel — a haptic + shader pair
/// applied via the `.hexHero(...)` view modifier.
///
/// Real Metal shader implementations land in Phase 5; for Phase 2 the
/// shader half is rendered with native SwiftUI fallbacks (gradients,
/// `colorEffect` placeholders) so the moments fire and feel right even
/// before the `.metal` files exist.
public enum HexHeroMoment: String, Sendable, CaseIterable {
    case scanIdle
    case scanDetected
    case scanReading
    case scanSuccess
    case writeTransmit
    case writeVerify
    case writeLockIn
    case error
    case destructiveWarn
    case consoleCommit
    /// A strong pulse when a command run lands in the Advanced Console. Pairs
    /// with the `.hexConsolePulse` rainbow-border visual.
    case consolePulse
    case dragSnap
    /// Fired when a data value is lifted to the clipboard via `.hexCopyable`.
    case copy
    /// A light, crisp tick for ordinary navigation and button presses —
    /// opening a sheet, tapping a tile, dismissing. The lightest moment.
    case tap
    /// A meatier confirm for a *hard* action landing: a record added, a preset
    /// saved or loaded, a write kicked off. Pairs with no shader on its own.
    case commit

    /// The haptic pattern that pairs with the visual half.
    public var haptic: HexHapticPattern {
        switch self {
        case .scanIdle: .scanIdlePulse
        case .scanDetected: .scanDetected
        case .scanReading: .scanReading
        case .scanSuccess: .scanSuccess
        case .writeTransmit: .writeTransmit
        case .writeVerify: .writeVerify
        case .writeLockIn: .writeLockIn
        case .error: .errorStab
        case .destructiveWarn: .destructiveWarn
        case .consoleCommit: .consoleCommit
        case .consolePulse: .consolePulse
        case .dragSnap: .dragSnap
        case .copy: .copyTick
        case .tap: .tapTick
        case .commit: .commitThud
        }
    }

    /// Imperatively fire this moment's haptic. Use from button actions and
    /// other one-shot interaction handlers where a state-change `trigger:` /
    /// `isActive:` isn't natural. Routes through the same engine as the
    /// `.hexHero(...)` modifiers, so it honours the Settings haptics toggle and
    /// is a silent no-op on platforms without CoreHaptics.
    public func play() {
        HexHapticsEngine.shared.play(haptic)
    }
}

public extension View {
    /// Fire a moment composer for this view. Use the `trigger` form when the
    /// moment is event-driven (one-shot fire on a state change); use the
    /// `isActive` form when the moment is duration-driven (continuous shader
    /// + looped haptic while a state holds).
    func hexHero(_ moment: HexHeroMoment, trigger: some Equatable) -> some View {
        modifier(HexHeroTriggerModifier(moment: moment, trigger: trigger))
    }

    func hexHero(_ moment: HexHeroMoment, isActive: Bool) -> some View {
        modifier(HexHeroActiveModifier(moment: moment, isActive: isActive))
    }
}

private struct HexHeroTriggerModifier<T: Equatable>: ViewModifier {
    let moment: HexHeroMoment
    let trigger: T

    func body(content: Content) -> some View {
        content
            .onChange(of: trigger) { _, _ in
                HexHapticsEngine.shared.play(moment.haptic)
            }
    }
}

private struct HexHeroActiveModifier: ViewModifier {
    let moment: HexHeroMoment
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: isActive) { _, newValue in
                if newValue {
                    HexHapticsEngine.shared.play(moment.haptic)
                }
            }
    }
}
