import HexNFCShaders
import SwiftUI

/// A button style that gives every tappable surface the app's signature feel:
/// a subtle press-scale plus an interaction haptic fired through the moment
/// composer. Use it anywhere a `Button` would otherwise be `.plain`.
///
///  * `.light`  — ordinary navigation and presses (tiles, rows, dismiss).
///  * `.medium` — committing a *hard* action (loading a preset, etc.).
///
/// Haptics go through `HexHeroMoment.play()` so they honour the Settings
/// toggle and Reduce-Motion-independent haptic behaviour; the visual scale uses
/// the standard snappy micro-interaction spring.
public struct HexPressStyle: ButtonStyle {
    public enum Feel: Sendable { case light, medium }

    private let feel: Feel

    public init(_ feel: Feel = .light) {
        self.feel = feel
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(HexTokens.Motion.snappy, value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                guard pressed else { return }
                switch feel {
                case .light: HexHeroMoment.tap.play()
                case .medium: HexHeroMoment.commit.play()
                }
            }
    }
}

public extension View {
    /// Apply `HexPressStyle` — a press-scale + interaction haptic. Defaults to
    /// the light feel for navigation and ordinary taps.
    ///
    /// - Note: Do **not** use this on a text `Button` inside a `ToolbarItem`. A
    ///   custom `ButtonStyle` replaces the bar's native button chrome, which is
    ///   what supplies the standard horizontal padding *and* the no-truncation
    ///   sizing — without it the label hugs the edges and gets clipped to an
    ///   ellipsis in a crowded bar. Use ``hexPressHaptic(_:)`` there instead: it
    ///   keeps the native button and only adds the press haptic.
    func hexPressStyle(_ feel: HexPressStyle.Feel = .light) -> some View {
        buttonStyle(HexPressStyle(feel))
    }

    /// Add the signature press haptic to a button **without** replacing its
    /// style — so navigation/toolbar buttons keep their native chrome (padding,
    /// glass, no-truncation) yet still fire a tick on press-down.
    ///
    /// `HexPressStyle` can't be used in a toolbar (a custom `ButtonStyle` strips
    /// the bar's native button layout). This instead recognises a zero-distance
    /// drag *simultaneously* with the button, firing the same `tap`/`commit`
    /// moment the instant the finger lands — matching the press-down feel of
    /// `hexPressStyle` — while leaving the button's own tap action untouched. It
    /// routes through `HexHeroMoment`, so it honours the Settings haptics toggle
    /// and is a no-op when the button is disabled.
    ///
    /// - Important: Apply this *before* `disabled(_:)` so the gesture sits inside
    ///   the disabled scope (e.g. `Button(…).hexPressHaptic().disabled(flag)`).
    ///   Otherwise a disabled button would still buzz on touch.
    func hexPressHaptic(_ feel: HexPressStyle.Feel = .light) -> some View {
        modifier(HexPressHaptic(feel: feel))
    }
}

/// Fires `HexPressStyle`'s haptic on press-down via a simultaneous zero-distance
/// drag, so it composes with a *native* button instead of replacing its style.
private struct HexPressHaptic: ViewModifier {
    let feel: HexPressStyle.Feel
    /// Mirrors the button's enabled state so a disabled control stays silent.
    @Environment(\.isEnabled) private var isEnabled
    /// Latches on touch-down so a press fires exactly one tick, not one per
    /// `onChanged` delivered as the finger jitters.
    @State private var firing = false

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard isEnabled, !firing else { return }
                    firing = true
                    switch feel {
                    case .light: HexHeroMoment.tap.play()
                    case .medium: HexHeroMoment.commit.play()
                    }
                }
                .onEnded { _ in firing = false }
        )
    }
}
