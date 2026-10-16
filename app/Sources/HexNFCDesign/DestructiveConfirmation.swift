import Foundation

/// Validation logic for the typed-UID destructive-confirmation gate. Lives
/// outside the iOS-only view so it can be unit-tested on any platform.
public enum DestructiveConfirmation {
    /// `true` once the user has typed the expected uidTail. Case-insensitive,
    /// whitespace-tolerant. Empty `uidTail` always returns `false` — a
    /// missing target is treated as a programming error to refuse.
    public static func matches(_ typed: String, uidTail: String) -> Bool {
        let lhs = typed.trimmingCharacters(in: .whitespaces).uppercased()
        let rhs = uidTail.uppercased()
        return !rhs.isEmpty && lhs == rhs
    }
}

#if os(iOS)
import SwiftUI

/// Unified confirmation gate for irreversible tag operations (erase, format,
/// permanent lock, set/remove password). Per the plan: no "are you sure?"
/// dialogs — the user types the last 4 hex chars of the tag's UID to confirm.
/// Typing fires the `destructive.warn` haptic via the `hexHero` modifier
/// from the call site; this primitive stays purely visual + validating so
/// HexNFCDesign keeps no dependency on HexNFCShaders for input.
public struct DestructiveConfirmationView: View {
    public let title: LocalizedStringKey
    public let warning: LocalizedStringKey
    public let uidTail: String
    public let actionTitle: LocalizedStringKey
    public let isBusy: Bool
    /// Whether this view raises the keyboard on its own field when it appears.
    ///
    /// True suits the screens where the UID is the only thing to type. It is
    /// wrong wherever a field sits **above** this one, which is what the
    /// Operations gate became when it started collecting a tag's credential in
    /// the same window: the keyboard opened on the second input on the screen
    /// and the first one looked optional.
    public let focusesOnAppear: Bool
    public let onConfirm: () -> Void
    public let onTypingProgress: ((Int) -> Void)?

    @State private var typed: String = ""
    @FocusState private var focused: Bool
    /// VoiceOver focus is a separate cursor from keyboard focus, so this is a
    /// separate property wrapper. It exists to land the reader on the warning
    /// rather than on the field.
    @AccessibilityFocusState private var warningFocused: Bool
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    public init(
        title: LocalizedStringKey,
        warning: LocalizedStringKey,
        uidTail: String,
        actionTitle: LocalizedStringKey,
        isBusy: Bool = false,
        focusesOnAppear: Bool = true,
        onConfirm: @escaping () -> Void,
        onTypingProgress: ((Int) -> Void)? = nil
    ) {
        self.title = title
        self.warning = warning
        self.uidTail = uidTail
        self.actionTitle = actionTitle
        self.isBusy = isBusy
        self.focusesOnAppear = focusesOnAppear
        self.onConfirm = onConfirm
        self.onTypingProgress = onTypingProgress
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HexTokens.Spacing.l) {
            // Title and warning are one element so the two cannot be separated
            // by a swipe, and carry the header trait so they sit on the heading
            // rotor. Neither holds a text field, so combining is safe here.
            VStack(alignment: .leading, spacing: HexTokens.Spacing.s) {
                Text(title)
                    .font(HexTokens.Font.title)
                    .foregroundStyle(HexTokens.Color.textPrimary)
                Text(warning)
                    .font(HexTokens.Font.body)
                    .foregroundStyle(HexTokens.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityFocused($warningFocused)

            VStack(alignment: .leading, spacing: HexTokens.Spacing.s) {
                Text("Type this tag's UID to confirm.")
                    .font(HexTokens.Font.footnote)
                    .foregroundStyle(HexTokens.Color.textSecondary)
                    // The field below carries this same string as its
                    // accessibility label, so leaving the caption in the tree
                    // would announce the name twice.
                    .accessibilityHidden(true)
                HStack(spacing: HexTokens.Spacing.s) {
                    Text(uidTail.uppercased())
                        .font(HexTokens.Font.mono)
                        .foregroundStyle(HexTokens.Color.primaryLight)
                        .padding(.horizontal, HexTokens.Spacing.m)
                        .padding(.vertical, HexTokens.Spacing.s)
                        .background(
                            RoundedRectangle(cornerRadius: HexTokens.Radius.s, style: .continuous)
                                .fill(HexTokens.Color.surface2)
                        )
                        // Its position beside the field says what it is on
                        // screen; as a lone element it reached VoiceOver as
                        // four unexplained characters, pronounced as a word.
                        // Name it, and spell out the characters to copy.
                        .accessibilityLabel(Text("UID"))
                        .accessibilityValue(
                            Text(verbatim: uidTail.uppercased()).speechSpellsOutCharacters()
                        )
                    Image(systemName: "arrow.right")
                        .foregroundStyle(HexTokens.Color.textSecondary)
                        // Decoration: it points from the target UID to the
                        // field and says nothing a reader needs.
                        .accessibilityHidden(true)
                    TextField("", text: $typed)
                        .focused($focused)
                        .font(HexTokens.Font.mono)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled(true)
                        .padding(.horizontal, HexTokens.Spacing.m)
                        .padding(.vertical, HexTokens.Spacing.s)
                        .background(
                            RoundedRectangle(cornerRadius: HexTokens.Radius.s, style: .continuous)
                                .fill(HexTokens.Color.surface1)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: HexTokens.Radius.s, style: .continuous)
                                .stroke(borderColor, lineWidth: 1)
                        )
                        .onChange(of: typed) { _, newValue in
                            onTypingProgress?(newValue.count)
                        }
                        // The field had no label, so VoiceOver fell back to the
                        // empty prompt and announced an anonymous text field.
                        .accessibilityLabel(Text("Type this tag's UID to confirm."))
                        // Value, not hint: whether the typed tail matches is
                        // what gates a permanent lock, and a hint is
                        // suppressible in VoiceOver's settings. The verdict was
                        // carried by `borderColor` alone, which a VoiceOver
                        // user never sees.
                        .accessibilityValue(spokenValue)
                }
            }

            Button(action: onConfirm) {
                HStack(spacing: HexTokens.Spacing.s) {
                    if isBusy {
                        ProgressView()
                            .tint(.white)
                    }
                    Text(actionTitle)
                        .font(HexTokens.Font.heading)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, HexTokens.Spacing.m)
                .padding(.horizontal, HexTokens.Spacing.l)
                // This is the live permanent-lock button. It carried its own
                // copy of `HexButton`'s destructive gradient, so fixing that
                // one alone would have left the most consequential button in
                // the app at 3.77:1 against its white label.
                .background(HexTokens.Color.dangerFill)
                .overlay(
                    RoundedRectangle(cornerRadius: HexTokens.Radius.m, style: .continuous)
                        .strokeBorder(
                            HexTokens.Stroke.contrastEdge,
                            lineWidth: HexTokens.Stroke.contrastEdgeWidth
                        )
                )
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: HexTokens.Radius.m, style: .continuous))
                .opacity(canConfirm ? 1.0 : 0.4)
            }
            .disabled(!canConfirm)
        }
        .padding(HexTokens.Spacing.l)
        .background(
            RoundedRectangle(cornerRadius: HexTokens.Radius.l, style: .continuous)
                .fill(HexTokens.Color.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HexTokens.Radius.l, style: .continuous)
                .stroke(HexTokens.Color.danger.opacity(0.6), lineWidth: 1)
        )
        .onAppear {
            // Raising the keyboard also dragged VoiceOver into the field, so
            // the warning about an irreversible operation was never spoken:
            // the reader's first stop was a text entry with no stated stakes.
            // Under VoiceOver, focus the warning and let the user swipe to the
            // field. Everyone else keeps the keyboard-on-appear behaviour.
            if voiceOverEnabled {
                warningFocused = true
            } else if focusesOnAppear {
                focused = true
            }
        }
    }

    /// Spoken value for the entry field: the characters typed so far, then the
    /// match verdict.
    ///
    /// The typed run is spelled character by character because VoiceOver
    /// otherwise pronounces a tail like "3A7F" as a word, and this field exists
    /// to be checked against the UID beside it one character at a time.
    /// `speechSpellsOutCharacters()` is applied to that run *before* the
    /// concatenation, so it does not spread to the verdict and turn "OK" into
    /// "O, K".
    ///
    /// It reports what the user typed, never `uidTail`: announcing the target
    /// here would tell a VoiceOver user the field already held the UID, on the
    /// one screen in the app where that mistake ends in a permanently locked
    /// tag, and it would leave them no way to hear what they had entered.
    private var spokenValue: Text {
        guard !typed.isEmpty else { return Text(verbatim: "") }
        let verdict = DestructiveConfirmation.matches(typed, uidTail: uidTail)
            ? Text("OK")
            : Text("Mismatch")
        return Text(verbatim: typed).speechSpellsOutCharacters()
            + Text(verbatim: ", ")
            + verdict
    }

    private var canConfirm: Bool {
        DestructiveConfirmation.matches(typed, uidTail: uidTail) && !isBusy
    }

    private var borderColor: Color {
        if typed.isEmpty {
            return HexTokens.Stroke.cardInner
        }
        return DestructiveConfirmation.matches(typed, uidTail: uidTail)
            ? HexTokens.Color.success
            : HexTokens.Color.warning
    }
}
#endif
