import SwiftUI

/// Labelled text field with Hex Pro chrome. Uses surface2 fill and a subtle
/// inner stroke. Optional inline help footer.
public struct HexField: View {
    private let label: LocalizedStringKey
    private let prompt: LocalizedStringKey?
    private let footer: LocalizedStringKey?
    @Binding private var text: String
    private let axis: Axis
    private let keyboard: PlatformKeyboardType

    public init(
        _ label: LocalizedStringKey,
        text: Binding<String>,
        prompt: LocalizedStringKey? = nil,
        footer: LocalizedStringKey? = nil,
        axis: Axis = .horizontal,
        keyboard: PlatformKeyboardType = .default
    ) {
        self.label = label
        self.prompt = prompt
        self.footer = footer
        _text = text
        self.axis = axis
        self.keyboard = keyboard
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HexTokens.Spacing.xs) {
            // The field carries `label` as its VoiceOver name (see `field`), so
            // this visual copy is hidden: on screen it names the field, but as
            // its own element VoiceOver would read it as a stray static string
            // just before announcing the same words again as the field's name.
            Text(label)
                .font(HexTokens.Font.footnote)
                .foregroundStyle(HexTokens.Color.textSecondary)
                .accessibilityHidden(true)
            field
                .padding(HexTokens.Spacing.m)
                .background(
                    RoundedRectangle(cornerRadius: HexTokens.Radius.s, style: .continuous)
                        .fill(HexTokens.Color.surface2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: HexTokens.Radius.s, style: .continuous)
                        .strokeBorder(HexTokens.Stroke.cardInner, lineWidth: 1)
                )
                .foregroundStyle(HexTokens.Color.textPrimary)
            if let footer {
                // Reaches VoiceOver as the field's hint instead, so hide it
                // here rather than leave it loose after the field as guidance
                // with nothing to say which field it is guidance for.
                Text(footer)
                    .font(HexTokens.Font.footnote)
                    .foregroundStyle(HexTokens.Color.textSecondary)
                    .accessibilityHidden(true)
            }
        }
    }

    /// One `TextField` whether or not a prompt was given. A prompt here is a
    /// sample value ("en", "+15551234", "without the @"), and with no
    /// accessibility label VoiceOver announced that sample as the field's
    /// *name*, or announced nothing at all where no prompt was supplied.
    /// `accessibilityLabel` gives the name back to `label`.
    private var field: some View {
        TextField(prompt ?? "", text: $text, axis: axis)
            .modifier(KeyboardModifier(type: keyboard))
            .accessibilityLabel(Text(label))
            .accessibilityHint(footerHint)
    }

    /// `accessibilityHint` takes a non-optional `Text` and an empty one is not
    /// announced, so a field without a footer passes an empty hint. Branching
    /// on `footer` instead would wrap the `TextField` in a conditional, which
    /// is what drops first-responder state when the branch flips.
    private var footerHint: Text {
        guard let footer else { return Text(verbatim: "") }
        return Text(footer)
    }
}

/// Cross-platform keyboard type. SwiftUI's `keyboardType(...)` only exists on
/// iOS — wrapping it keeps `HexNFCDesign` previewable from macOS too.
public enum PlatformKeyboardType: Sendable {
    case `default`
    case url
    case emailAddress
    case numberPad
    case phonePad
    case asciiCapable
}

private struct KeyboardModifier: ViewModifier {
    let type: PlatformKeyboardType
    func body(content: Content) -> some View {
        #if os(iOS)
        switch type {
        case .default: content
        case .url: content.keyboardType(.URL).textInputAutocapitalization(.never)
        case .emailAddress: content.keyboardType(.emailAddress).textInputAutocapitalization(.never)
        case .numberPad: content.keyboardType(.numberPad)
        case .phonePad: content.keyboardType(.phonePad)
        case .asciiCapable: content.keyboardType(.asciiCapable)
        }
        #else
        content
        #endif
    }
}
