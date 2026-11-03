import CoreGraphics
import Foundation
import ImageIO

/// The arithmetic between what the passport scanner shows and what Vision and
/// the camera are told. Pure, so it is tested on macOS: a mistake here does
/// not crash, it just points the recogniser at the wrong strip of the frame.
enum MRZScanGeometry {
    /// Vision orientation for a buffer the preview rotates by `angle` degrees
    /// to show upright. The preview angle, not the capture angle: the capture
    /// angle follows gravity, so it flips when the phone is held flat over a
    /// passport on a desk, while the holder is lining the zone up with what the
    /// screen shows.
    static func orientation(forPreviewRotationAngle angle: CGFloat) -> CGImagePropertyOrientation {
        switch quarterTurns(angle) {
        case 1: .right
        case 2: .down
        case 3: .left
        default: .up
        }
    }

    /// The buffer's size once rotated upright.
    static func uprightSize(buffer: CGSize, previewRotationAngle angle: CGFloat) -> CGSize {
        quarterTurns(angle).isMultiple(of: 2) ? buffer : CGSize(width: buffer.height, height: buffer.width)
    }

    /// Where the guide band falls in the upright image, in Vision's normalised
    /// coordinates (origin bottom left), given a preview that aspect-fills
    /// `layer`. Clamped to the image, since the band can overhang a cropped
    /// edge.
    static func regionOfInterest(guide: CGRect, layer: CGSize, uprightImage: CGSize) -> CGRect {
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard layer.width > 0, layer.height > 0, uprightImage.width > 0, uprightImage.height > 0,
              !guide.isEmpty else { return full }
        let scale = max(layer.width / uprightImage.width, layer.height / uprightImage.height)
        let shown = CGSize(width: uprightImage.width * scale, height: uprightImage.height * scale)
        let crop = CGPoint(x: (shown.width - layer.width) / 2, y: (shown.height - layer.height) / 2)
        let x = (guide.minX + crop.x) / shown.width
        let top = (guide.minY + crop.y) / shown.height
        let width = guide.width / shown.width
        let height = guide.height / shown.height
        let region = CGRect(x: x, y: 1 - top - height, width: width, height: height).intersection(full)
        return region.isNull || region.isEmpty ? full : region
    }

    /// The strip Vision reads, given the machine-readable zone as the page
    /// guide draws it. Wider and taller than the zone by a margin, because the
    /// outline is a guide and a page held a little high, low or skewed still
    /// has to read; Vision's cost follows this area, so the margin is modest.
    static func readingRegion(zone: CGRect) -> CGRect {
        zone.insetBy(dx: -zone.width * readingMarginX, dy: -zone.height * readingMarginY)
    }

    /// Extra reading area either side of the zone, as a share of its width.
    static let readingMarginX: CGFloat = 0.03
    /// Extra reading area above and below the zone, as a share of its height.
    static let readingMarginY: CGFloat = 0.35

    /// Zoom that lets the holder stand far enough back for the lens to focus.
    ///
    /// Pro iPhones' main cameras cannot focus much closer than about 200 mm,
    /// and at 1x a passport page fills the frame well inside that, so the
    /// camera would never sharpen. Zooming narrows the view, which moves the
    /// distance at which the zone fills the guide band further away.
    ///
    /// - `fieldOfView` is the active format's horizontal angle in degrees,
    ///   along the sensor's long axis. In portrait the page runs along the
    ///   short axis, so its half-angle tangent shrinks by short/long.
    /// - The band covers `guideWidth` of a preview that aspect-fills the
    ///   upright image, so the band is a smaller share of the image than of
    ///   the screen.
    /// - Aim for `focusMargin` times the minimum focus distance, not the
    ///   distance itself, or focus hunts at the edge of its range.
    /// - `minimumFocusDistance` of -1 means the device does not know: no zoom.
    static func zoomFactor(
        minimumFocusDistance: Int,
        fieldOfView: Float,
        buffer: CGSize,
        previewRotationAngle angle: CGFloat,
        layer: CGSize,
        guideWidth: CGFloat,
        subjectWidthMillimetres: Double = mrzWidthMillimetres,
        focusMargin: Double = 1.4,
        maximum: CGFloat
    ) -> CGFloat {
        guard minimumFocusDistance > 0, fieldOfView > 0, guideWidth > 0, layer.width > 0, layer.height > 0
        else { return 1 }
        let upright = uprightSize(buffer: buffer, previewRotationAngle: angle)
        let longSide = max(buffer.width, buffer.height)
        let shortSide = min(buffer.width, buffer.height)
        let halfAngle = Double(fieldOfView) / 2 * .pi / 180
        // The upright image's width is the sensor's short side in portrait.
        let axisRatio = upright.width < upright.height ? Double(shortSide / longSide) : 1
        let tangent = tan(halfAngle) * axisRatio
        let scale = max(layer.width / upright.width, layer.height / upright.height)
        let guideShareOfImage = Double(guideWidth / (upright.width * scale))
        let distanceAtOne = subjectWidthMillimetres / (guideShareOfImage * 2 * tangent)
        let wanted = focusMargin * Double(minimumFocusDistance) / distanceAtOne
        return min(max(1, CGFloat(wanted)), max(1, maximum))
    }

    /// The width of a TD3 zone's printed lines: 44 characters at the 2.54 mm
    /// OCR-B pitch (ICAO Doc 9303 Part 3).
    static let mrzWidthMillimetres = 44 * 2.54

    private static func quarterTurns(_ angle: CGFloat) -> Int {
        let turns = Int((angle / 90).rounded()) % 4
        return turns < 0 ? turns + 4 : turns
    }
}
