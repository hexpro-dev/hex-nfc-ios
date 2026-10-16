import HexNFCShaders
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Clipboard plumbing for read-only data values. Routed through here (rather
/// than calling `UIPasteboard` from screens) so every copy in the app gets the
/// same crisp confirmation haptic — part of the signature feel.
public enum HexClipboard {
    /// Place `string` on the system clipboard and fire the copy haptic.
    public static func copy(_ string: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = string
        #endif
        HexHapticsEngine.shared.play(HexHeroMoment.copy.haptic)
    }
}

public extension View {
    /// Make a read-only data value copy itself to the clipboard on tap, with a
    /// crisp haptic and a brief "Copied" confirmation pill floating over the
    /// field. Use on any value the user might want to grab verbatim — UIDs,
    /// balances, hex dumps, console lines.
    ///
    /// The whole view becomes the tap target; long-press text selection (where
    /// enabled) still works alongside it, and a VoiceOver "Copy" action mirrors
    /// the tap. Pass an empty `value` to make the field inert.
    func hexCopyable(_ value: String) -> some View {
        modifier(HexCopyableModifier(value: value))
    }
}

private struct HexCopyableModifier: ViewModifier {
    let value: String
    @State private var copied = false

    func body(content: Content) -> some View {
        if value.isEmpty {
            content
        } else {
            content
                .contentShape(Rectangle())
                .onTapGesture(perform: copy)
                .overlay {
                    if copied {
                        HexCopiedPill()
                            .allowsHitTesting(false)
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(named: Text("Copy")) { copy() }
        }
    }

    private func copy() {
        HexClipboard.copy(value)
        withAnimation(HexTokens.Motion.snappy) { copied = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            withAnimation(HexTokens.Motion.snappy) { copied = false }
        }
    }
}

/// The compact "Copied" confirmation shown briefly over a copied field.
private struct HexCopiedPill: View {
    var body: some View {
        HStack(spacing: HexTokens.Spacing.xs) {
            Image(systemName: "checkmark")
            Text("Copied")
        }
        .font(HexTokens.Font.footnote)
        .foregroundStyle(HexTokens.Color.textPrimary)
        .padding(.horizontal, HexTokens.Spacing.s)
        .padding(.vertical, HexTokens.Spacing.xs)
        .background(Capsule().fill(HexTokens.Color.surface2))
        .overlay(Capsule().strokeBorder(HexTokens.Stroke.cardInner, lineWidth: HexTokens.Stroke.cardInnerWidth))
        .shadow(color: .black.opacity(0.45), radius: 8, x: 0, y: 3)
        .fixedSize()
    }
}

/// Icon-only "copy everything" affordance — meant to hover at the corner of a
/// scrollable block (e.g. the console output container). Copies whatever
/// `text()` returns at tap time and flips to a checkmark for a beat.
public struct HexCopyAllButton: View {
    private let text: () -> String
    @State private var copied = false

    /// - Parameter text: evaluated on tap, so the latest content is captured.
    public init(text: @escaping () -> String) {
        self.text = text
    }

    public var body: some View {
        Button(action: copy) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(copied ? HexTokens.Color.success : HexTokens.Color.textSecondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(HexTokens.Color.surface2.opacity(0.92)))
                .overlay(Circle().strokeBorder(HexTokens.Stroke.cardInner, lineWidth: HexTokens.Stroke.cardInnerWidth))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Copy all"))
    }

    private func copy() {
        HexClipboard.copy(text())
        withAnimation(HexTokens.Motion.snappy) { copied = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            withAnimation(HexTokens.Motion.snappy) { copied = false }
        }
    }
}
