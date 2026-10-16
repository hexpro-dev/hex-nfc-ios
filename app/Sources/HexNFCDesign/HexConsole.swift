import HexNFCShaders
import SwiftUI

/// A console log row — TX, RX, or a system notice line. The advanced console
/// log is `[HexConsoleEntry]`; the view renders it as a scrolling mono list
/// with hex tokens softly highlighted.
public struct HexConsoleEntry: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let kind: Kind
    public let timestamp: Date
    public let label: String?
    public let body: String

    public init(
        id: UUID = UUID(),
        kind: Kind,
        timestamp: Date = Date(),
        label: String? = nil,
        body: String
    ) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.label = label
        self.body = body
    }

    public enum Kind: Hashable, Sendable {
        case tx
        case rx
        case note
        case error
    }

    /// The prefix glyph shown at the head of the row (and used when copying).
    public var prefixSymbol: String {
        switch kind {
        case .tx: "→ TX"
        case .rx: "← RX"
        case .note: "•"
        case .error: "!"
        }
    }

    /// A single plain-text line for this entry — `prefix  HH:mm:ss.SSS  label
    /// body` — used by the console's "copy all" affordance so a pasted log
    /// reads the way it looks on screen.
    public var plainTextLine: String {
        [prefixSymbol, Self.lineTimeFormatter.string(from: timestamp), label, body]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "  ")
    }

    private static let lineTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

/// Console scrollback view. Mono font, virtualised by SwiftUI's `LazyVStack`,
/// each row coloured by `kind`. Hex tokens (`HH`, `:`, `,`) are tinted
/// against the surface so a packed log stays legible at a glance.
public struct HexConsole: View {
    private let entries: [HexConsoleEntry]
    private let autoScroll: Bool

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.hexReduceMotion) private var appReduceMotion

    public init(entries: [HexConsoleEntry], autoScroll: Bool = true) {
        self.entries = entries
        self.autoScroll = autoScroll
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: HexTokens.Spacing.xs) {
                    if entries.isEmpty {
                        Text("Console idle. Tap a preset on the left, or type a sequence and Run.")
                            .font(HexTokens.Font.footnote)
                            .foregroundStyle(HexTokens.Color.textSecondary)
                            .padding(.vertical, HexTokens.Spacing.m)
                    }
                    ForEach(entries) { entry in
                        HexConsoleRow(entry: entry)
                            .id(entry.id)
                    }
                }
                .padding(HexTokens.Spacing.m)
            }
            .background(HexTokens.Color.surface0)
            .clipShape(RoundedRectangle(cornerRadius: HexTokens.Radius.m, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HexTokens.Radius.m, style: .continuous)
                    .stroke(HexTokens.Stroke.cardInner, lineWidth: HexTokens.Stroke.cardInnerWidth)
            )
            .onChange(of: entries.last?.id) { _, newID in
                guard autoScroll, let newID else { return }
                // Jump rather than glide under Reduce Motion. Auto-scroll is
                // viewport travel the reader did not ask for and cannot
                // anticipate, and a command run emits a burst of rows whose
                // individual glides overlap into continuous flow. A jump is
                // what a vestibular-sensitive reader wants here, not a
                // degraded version of the animation.
                if systemReduceMotion || appReduceMotion {
                    proxy.scrollTo(newID, anchor: .bottom)
                } else {
                    withAnimation(HexTokens.Motion.snappy) {
                        proxy.scrollTo(newID, anchor: .bottom)
                    }
                }
            }
        }
    }
}

private struct HexConsoleRow: View {
    let entry: HexConsoleEntry

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: HexTokens.Spacing.s) {
            Text(entry.prefixSymbol)
                .font(HexTokens.Font.mono)
                .foregroundStyle(prefixColor)
                .frame(width: 28, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: HexTokens.Spacing.s) {
                    Text(Self.timeFormatter.string(from: entry.timestamp))
                        .font(HexTokens.Font.footnote)
                        .foregroundStyle(HexTokens.Color.textSecondary)
                    if let label = entry.label {
                        Text(label)
                            .font(HexTokens.Font.footnote)
                            .foregroundStyle(HexTokens.Color.textSecondary)
                    }
                }
                Text(highlightedBody)
                    .font(HexTokens.Font.mono)
                    .textSelection(.enabled)
                    .lineLimit(nil)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, HexTokens.Spacing.xs)
        .padding(.horizontal, HexTokens.Spacing.s)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: HexTokens.Radius.s, style: .continuous))
        // Tap anywhere on the row to lift its payload to the clipboard.
        .hexCopyable(entry.body)
    }

    private var prefixColor: Color {
        switch entry.kind {
        case .tx: HexTokens.Color.primaryLight
        case .rx: HexTokens.Color.success
        case .note: HexTokens.Color.textSecondary
        case .error: HexTokens.Color.dangerText
        }
    }

    private var rowBackground: Color {
        switch entry.kind {
        case .tx, .rx, .note: HexTokens.Color.surface1.opacity(0.6)
        case .error: HexTokens.Color.danger.opacity(0.10)
        }
    }

    /// Softly highlights `:` separators and `,` chain markers in hex strings.
    /// We keep it cheap — no real tokenizer, just AttributedString colouring.
    private var highlightedBody: AttributedString {
        var attr = AttributedString(entry.body)
        attr.foregroundColor = bodyColor
        for run in attr.characters.indices where attr.characters[run] == ":" {
            attr[run ..< attr.index(afterCharacter: run)].foregroundColor = HexTokens.Color.textSecondary
        }
        for run in attr.characters.indices where attr.characters[run] == "," {
            attr[run ..< attr.index(afterCharacter: run)].foregroundColor = HexTokens.Color.primaryLight
        }
        return attr
    }

    private var bodyColor: Color {
        switch entry.kind {
        case .tx, .rx: HexTokens.Color.textPrimary
        case .note: HexTokens.Color.textSecondary
        case .error: HexTokens.Color.dangerText
        }
    }
}

private extension AttributedString {
    func index(afterCharacter i: AttributedString.Index) -> AttributedString.Index {
        characters.index(after: i)
    }
}
