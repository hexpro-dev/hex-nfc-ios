import SwiftUI

/// The hero "page" for a scanned electronic passport — a parchment data-page
/// panel with the holder's photo, the machine-readable-zone fields laid out as
/// they appear in the booklet, and the raw MRZ printed along the bottom. It
/// evokes the physical data page so a scanned passport feels like the real
/// document, without reproducing any state's crest or seal.
///
/// Purely presentational + token-driven so it can be snapshot-tested. The photo
/// is passed as a SwiftUI `Image` (decoded by the hosting screen) so this design
/// module stays UIKit-free. The premium reveal is layered on via `.hexHero`.
public struct PassportBookletHero: View {
    /// Opacity of the tinted capsule behind the integrity badge, which prints
    /// its tint over a wash of that same tint.
    ///
    /// Public for the same reason as `HexBadge.washOpacity`: the contrast guard
    /// measures against the value that ships rather than a copy of it.
    public static let badgeWashOpacity = HexTokens.Opacity.tintWash

    /// Opacity of the placeholder person glyph shown when a passport carries no
    /// DG2 face image. It sits in the photo well, itself `ink` at 8%.
    public static let photoPlaceholderOpacity: Double = 0.90

    /// Point size of the issuing-state code in the header, and the reason the
    /// code beside it can still be foil gold.
    ///
    /// This is a **contrast threshold, not a typographic preference**. WCAG's
    /// "large text" starts at 18.66pt bold, and large text needs 3:1 where
    /// normal text needs 4.5:1. `Passport.gold` reaches 3.12:1 against the
    /// darkest end of the page and cannot reach 4.5:1 at all: the darkest gold
    /// that does, with hue and chroma held, is `#805F26`, which reads as brown
    /// rather than foil.
    ///
    /// So at 15pt, where this started, the choice was ink or a brown. At 19pt
    /// the gold is compliant. Shrink this below 18.66 and the requirement
    /// silently doubles and the gold silently fails, which is why the size
    /// lives here as a named constant and why `WCAGContrastTests` derives the
    /// threshold it demands from this value rather than hardcoding one.
    public static let issuingStateFontSize: CGFloat = 19

    /// A single labelled field on the data page.
    public struct Field {
        let label: LocalizedStringKey
        let value: String
        public init(label: LocalizedStringKey, value: String) {
            self.label = label
            self.value = value
        }
    }

    private let photo: Image?
    private let documentTypeLabel: String
    private let issuingState: String
    private let surname: String
    private let givenNames: String
    private let secondaryFields: [Field]
    private let mrzLines: [String]
    private let statusBadge: StatusBadge?

    /// An optional integrity chip shown in the header. Purely visual state; the
    /// verdict is computed by the reader and passed in.
    public struct StatusBadge {
        public enum Tone { case good, bad, neutral }
        let text: LocalizedStringKey
        let systemImage: String
        let tone: Tone
        public init(text: LocalizedStringKey, systemImage: String, tone: Tone) {
            self.text = text
            self.systemImage = systemImage
            self.tone = tone
        }
    }

    public init(
        photo: Image?,
        documentTypeLabel: String,
        issuingState: String,
        surname: String,
        givenNames: String,
        secondaryFields: [Field],
        mrzLines: [String],
        statusBadge: StatusBadge? = nil
    ) {
        self.photo = photo
        self.documentTypeLabel = documentTypeLabel
        self.issuingState = issuingState
        self.surname = surname
        self.givenNames = givenNames
        self.secondaryFields = secondaryFields
        self.mrzLines = mrzLines
        self.statusBadge = statusBadge
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HexTokens.Spacing.m) {
            header
            dataRow
            if !mrzLines.isEmpty {
                mrzStrip
            }
        }
        .padding(HexTokens.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(pageSurface)
        .clipShape(RoundedRectangle(cornerRadius: HexTokens.Radius.l, style: .continuous))
        .overlay(bevel)
        .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Passport data page"))
        .accessibilityValue(Text(verbatim: "\(givenNames) \(surname)"))
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: HexTokens.Spacing.s) {
            ePassportSymbol
            Text(verbatim: documentTypeLabel.uppercased())
                .font(.system(size: 13, weight: .semibold))
                .tracking(2)
                .foregroundStyle(HexTokens.Passport.ink)
            Spacer(minLength: 0)
            if let statusBadge {
                badge(statusBadge)
            }
            Text(verbatim: issuingState)
                .font(.system(size: Self.issuingStateFontSize, weight: .bold, design: .rounded))
                .foregroundStyle(HexTokens.Passport.gold)
        }
    }

    @ViewBuilder
    private func badge(_ badge: StatusBadge) -> some View {
        let tint: SwiftUI.Color = switch badge.tone {
        case .good: HexTokens.Passport.inkGood
        case .bad: HexTokens.Passport.inkBad
        case .neutral: HexTokens.Passport.ink
        }
        HStack(spacing: 4) {
            Image(systemName: badge.systemImage)
            Text(badge.text)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, HexTokens.Spacing.s)
        .padding(.vertical, 3)
        .background(tint.opacity(Self.badgeWashOpacity), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.4), lineWidth: 1))
    }

    // MARK: - Photo + fields

    private var dataRow: some View {
        HStack(alignment: .top, spacing: HexTokens.Spacing.l) {
            photoView
            VStack(alignment: .leading, spacing: HexTokens.Spacing.s) {
                field(label: "Surname", value: surname, emphasised: true)
                field(label: "Given names", value: givenNames, emphasised: true)
                if !secondaryFields.isEmpty {
                    // Two per row keeps the page compact like the real booklet.
                    let rows = stride(from: 0, to: secondaryFields.count, by: 2).map { i in
                        Array(secondaryFields[i ..< min(i + 2, secondaryFields.count)])
                    }
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, pair in
                        HStack(alignment: .top, spacing: HexTokens.Spacing.l) {
                            ForEach(Array(pair.enumerated()), id: \.offset) { _, f in
                                field(label: f.label, value: f.value)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var photoView: some View {
        let shape = RoundedRectangle(cornerRadius: HexTokens.Radius.m, style: .continuous)
        Group {
            if let photo {
                photo
                    .resizable().scaledToFill()
            } else {
                HexTokens.Passport.ink.opacity(0.08)
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.system(size: 38))
                            .foregroundStyle(HexTokens.Passport.inkDim.opacity(Self.photoPlaceholderOpacity))
                    )
            }
        }
        .frame(width: 92, height: 116)
        .clipShape(shape)
        .overlay(shape.strokeBorder(HexTokens.Passport.ink.opacity(0.25), lineWidth: 1))
    }

    private func field(label: LocalizedStringKey, value: String, emphasised: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(1)
                .textCase(.uppercase)
                .foregroundStyle(HexTokens.Passport.inkDim)
            Text(verbatim: value.isEmpty ? "n/a" : value)
                .font(.system(size: emphasised ? 16 : 13, weight: emphasised ? .semibold : .medium))
                .foregroundStyle(HexTokens.Passport.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    // MARK: - MRZ strip

    private var mrzStrip: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(mrzLines.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(HexTokens.Passport.ink.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, HexTokens.Spacing.s)
        .padding(.vertical, HexTokens.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            HexTokens.Passport.mrzBand,
            in: RoundedRectangle(cornerRadius: HexTokens.Radius.s, style: .continuous)
        )
    }

    // MARK: - Chrome

    /// The international e-passport symbol: a horizontal rounded rectangle with a
    /// centred circle. Recognisable and state-neutral (no crest reproduced).
    private var ePassportSymbol: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .strokeBorder(HexTokens.Passport.gold, lineWidth: 1.5)
                .frame(width: 22, height: 15)
            Circle()
                .strokeBorder(HexTokens.Passport.gold, lineWidth: 1.5)
                .frame(width: 6, height: 6)
        }
        .accessibilityHidden(true)
    }

    private var pageSurface: some View {
        LinearGradient(
            colors: [HexTokens.Passport.pageTop, HexTokens.Passport.pageBottom],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(guilloche)
    }

    /// Faint engraved wave lines evoking the printed guilloché security pattern.
    private var guilloche: some View {
        GeometryReader { geo in
            Path { path in
                let step = max(8, geo.size.height / 9)
                var y: CGFloat = -geo.size.width
                while y < geo.size.height + geo.size.width {
                    path.move(to: CGPoint(x: -8, y: y))
                    path.addLine(to: CGPoint(x: geo.size.width + 8, y: y + geo.size.width))
                    y += step
                }
            }
            .stroke(HexTokens.Passport.ink.opacity(0.05), lineWidth: 1)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var bevel: some View {
        RoundedRectangle(cornerRadius: HexTokens.Radius.l, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.5), HexTokens.Passport.ink.opacity(0.08)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )
    }
}
