import SwiftUI

/// A see-through outline of a passport's photo page, drawn over the passport
/// camera so the holder can see what belongs in the picture: the page edge,
/// where the photo and the printed details sit, and along the bottom, in a
/// stronger frame, the machine-readable zone the camera actually reads.
///
/// It is a layout, not a document. Grey bars stand for printed text and a
/// plain figure for the photo, with no state's crest, wording or specimen
/// data, so nothing on screen can be mistaken for the holder's own details.
///
/// Proportions are the ICAO Doc 9303 Part 4 TD3 page: 125 x 88 mm, with the
/// machine-readable zone (Zone VII) the bottom 23.2 mm. The visual zone's
/// layout varies by state; the positions here are representative.
public struct PassportPageGuide: View {
    /// How far the scan has got, which decides what the guide shows.
    public enum Emphasis: Sendable, Equatable {
        /// Nothing found yet: the whole layout, to show what to aim at.
        case searching
        /// The zone is in view: the layout steps back and the zone frame leads.
        case tracking
        /// Read: only the zone frame stays, in the success colour.
        case locked
    }

    /// TD3 page width (Doc 9303 Part 4).
    public static let pageWidthMillimetres: CGFloat = 125
    /// TD3 page height.
    public static let pageHeightMillimetres: CGFloat = 88
    /// Zone VII, the machine-readable zone, across the bottom of the page.
    public static let zoneHeightMillimetres: CGFloat = 23.2
    /// Width over height, for `.aspectRatio`.
    public static let aspectRatio = pageWidthMillimetres / pageHeightMillimetres
    /// The page's corner radius as a share of its width.
    public static let cornerRadiusShare: CGFloat = 3.5 / pageWidthMillimetres

    /// Where the machine-readable zone sits in a page drawn at `page`. The
    /// camera reads this rectangle, so the scanner derives its region of
    /// interest from here rather than from a copy of the proportions.
    public static func zone(inPage page: CGRect) -> CGRect {
        let share = zoneHeightMillimetres / pageHeightMillimetres
        return CGRect(x: page.minX, y: page.maxY - page.height * share, width: page.width, height: page.height * share)
    }

    private let emphasis: Emphasis

    public init(emphasis: Emphasis) {
        self.emphasis = emphasis
    }

    public var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let mm = size.width / Self.pageWidthMillimetres
            let zone = Self.zone(inPage: CGRect(origin: .zero, size: size)).insetBy(dx: 1.5 * mm, dy: 1.5 * mm)
            ZStack(alignment: .topLeading) {
                // A dark halo under each stroke keeps the outline visible once
                // a pale photo page is under it, not only over a dark desk.
                RoundedRectangle(cornerRadius: 3.5 * mm, style: .continuous)
                    .strokeBorder(HexTokens.Color.textPrimary.opacity(pageEdgeOpacity), lineWidth: 1.5)
                    .shadow(color: .black.opacity(Self.haloOpacity), radius: 1.5)

                Canvas { context, _ in
                    Self.drawLayout(in: &context, mm: mm)
                }
                .opacity(layoutOpacity)

                RoundedRectangle(cornerRadius: 2 * mm, style: .continuous)
                    .fill(zoneColour.opacity(zoneFillOpacity))
                    .overlay {
                        RoundedRectangle(cornerRadius: 2 * mm, style: .continuous)
                            .strokeBorder(zoneColour, lineWidth: emphasis == .locked ? 3 : 2)
                            .shadow(color: .black.opacity(Self.haloOpacity), radius: 1.5)
                    }
                    .shadow(color: emphasis == .locked ? HexTokens.Color.success.opacity(0.6) : .clear, radius: 12)
                    .frame(width: zone.width, height: zone.height)
                    .offset(x: zone.minX, y: zone.minY)

                Canvas { context, _ in
                    Self.drawZoneLines(in: &context, zone: zone, mm: mm)
                }
                .opacity(zoneLinesOpacity)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Emphasis

    private var pageEdgeOpacity: Double {
        switch emphasis {
        case .searching: 0.75
        case .tracking: 0.45
        case .locked: 0.2
        }
    }

    private var layoutOpacity: Double {
        switch emphasis {
        case .searching: 1
        case .tracking: 0.35
        case .locked: 0
        }
    }

    private var zoneLinesOpacity: Double {
        switch emphasis {
        case .searching: 1
        case .tracking: 0.3
        case .locked: 0
        }
    }

    private var zoneColour: Color {
        switch emphasis {
        case .searching: HexTokens.Color.textPrimary.opacity(0.85)
        case .tracking: HexTokens.Color.primaryLight
        case .locked: HexTokens.Color.success
        }
    }

    private var zoneFillOpacity: Double {
        switch emphasis {
        case .searching: 0.05
        case .tracking: 0.1
        case .locked: 0.14
        }
    }

    // MARK: - Drawing (all positions in millimetres on the page)

    private static let haloOpacity = 0.55
    private static let ghost = HexTokens.Color.textPrimary.opacity(0.22)
    private static let ghostStrong = HexTokens.Color.textPrimary.opacity(0.4)

    private static func bar(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, mm: CGFloat) -> Path {
        Path(roundedRect: CGRect(x: x * mm, y: y * mm, width: width * mm, height: height * mm), cornerRadius: height * mm / 2)
    }

    /// The visual zone: a header, the photo with a plain figure in it, the
    /// printed fields beside it as label and value bars, and a signature.
    private static func drawLayout(in context: inout GraphicsContext, mm: CGFloat) {
        // Header: document title, then type and number to the right.
        context.fill(bar(6, 4.5, 52, 2.6, mm: mm), with: .color(ghost))
        context.fill(bar(72, 5, 18, 1.8, mm: mm), with: .color(ghost))
        context.fill(bar(98, 5, 21, 1.8, mm: mm), with: .color(ghost))

        // Photo, with a head-and-shoulders figure.
        let photo = CGRect(x: 5 * mm, y: 11.5 * mm, width: 31 * mm, height: 40 * mm)
        context.stroke(Path(roundedRect: photo, cornerRadius: 1.2 * mm), with: .color(ghostStrong), lineWidth: 1)
        let head = CGRect(x: photo.midX - 6 * mm, y: photo.minY + 8 * mm, width: 12 * mm, height: 14 * mm)
        context.fill(Path(ellipseIn: head), with: .color(ghost))
        var shoulders = Path()
        shoulders.move(to: CGPoint(x: photo.minX + 3 * mm, y: photo.maxY))
        shoulders.addQuadCurve(
            to: CGPoint(x: photo.maxX - 3 * mm, y: photo.maxY),
            control: CGPoint(x: photo.midX, y: head.maxY - 1 * mm)
        )
        shoulders.closeSubpath()
        context.fill(shoulders, with: .color(ghost))

        // Fields: a short label bar over a longer value bar, in rows, two
        // columns where passports usually split them (birth date beside sex,
        // issue beside expiry).
        let rows: [(y: CGFloat, values: [(x: CGFloat, width: CGFloat)])] = [
            (12, [(41, 48)]),
            (19, [(41, 40)]),
            (26, [(41, 30), (82, 14)]),
            (33, [(41, 32)]),
            (40, [(41, 24), (82, 24)]),
        ]
        for row in rows {
            for value in row.values {
                context.fill(bar(value.x, row.y, min(16, value.width), 1.1, mm: mm), with: .color(ghost))
                context.fill(bar(value.x, row.y + 2, value.width, 2.1, mm: mm), with: .color(ghostStrong))
            }
        }

        // Signature.
        var signature = Path()
        signature.move(to: CGPoint(x: 42 * mm, y: 54 * mm))
        signature.addCurve(
            to: CGPoint(x: 58 * mm, y: 51 * mm),
            control1: CGPoint(x: 46 * mm, y: 47 * mm),
            control2: CGPoint(x: 50 * mm, y: 58 * mm)
        )
        signature.addCurve(
            to: CGPoint(x: 74 * mm, y: 52 * mm),
            control1: CGPoint(x: 64 * mm, y: 46 * mm),
            control2: CGPoint(x: 67 * mm, y: 58 * mm)
        )
        context.stroke(signature, with: .color(ghostStrong), lineWidth: 1)
    }

    /// Two rows of 44 character cells at the 2.54 mm OCR-B pitch, letters as
    /// bars and filler as `<`, in the shape a real zone has: a name line that
    /// ends in a long run of filler, and a number line with a short one.
    private static func drawZoneLines(in context: inout GraphicsContext, zone: CGRect, mm: CGFloat) {
        let pitch = 2.54 * mm
        let left = zone.midX - pitch * 22
        let rows: [(centre: CGFloat, pattern: String)] = [
            (zone.minY + zone.height * 0.36, "x<xxxxxxxxxxx<<xxxx<xxxxx<<<<<<<<<<<<<<<<<<<"),
            (zone.minY + zone.height * 0.70, "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx<<<<<xx"),
        ]
        let height = 2.3 * mm
        for row in rows {
            for (index, cell) in row.pattern.enumerated() {
                let x = left + CGFloat(index) * pitch
                if cell == "<" {
                    var chevron = Path()
                    chevron.move(to: CGPoint(x: x + pitch * 0.7, y: row.centre - height / 2))
                    chevron.addLine(to: CGPoint(x: x + pitch * 0.25, y: row.centre))
                    chevron.addLine(to: CGPoint(x: x + pitch * 0.7, y: row.centre + height / 2))
                    context.stroke(chevron, with: .color(ghostStrong), lineWidth: max(1, 0.3 * mm))
                } else {
                    let cellRect = CGRect(x: x + pitch * 0.2, y: row.centre - height / 2, width: pitch * 0.6, height: height)
                    context.fill(Path(roundedRect: cellRect, cornerRadius: 0.3 * mm), with: .color(ghost))
                }
            }
        }
    }
}
