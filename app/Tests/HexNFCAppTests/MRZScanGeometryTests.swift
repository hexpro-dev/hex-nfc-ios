@testable import HexNFCApp
import CoreGraphics
import ImageIO
import XCTest

/// The passport scanner's geometry: which strip of the frame Vision reads, in
/// which orientation, and how far the camera zooms. A mistake here never
/// crashes; the recogniser just looks at the wrong place, so pin the numbers.
final class MRZScanGeometryTests: XCTestCase {
    /// An iPhone 16 Pro Max-sized portrait screen over a 4K buffer.
    private let layer = CGSize(width: 430, height: 932)
    private let buffer = CGSize(width: 3840, height: 2160)

    func test_orientation_followsThePreviewAngle() {
        XCTAssertEqual(MRZScanGeometry.orientation(forPreviewRotationAngle: 90), .right)
        XCTAssertEqual(MRZScanGeometry.orientation(forPreviewRotationAngle: 0), .up)
        XCTAssertEqual(MRZScanGeometry.orientation(forPreviewRotationAngle: 180), .down)
        XCTAssertEqual(MRZScanGeometry.orientation(forPreviewRotationAngle: 270), .left)
        XCTAssertEqual(MRZScanGeometry.orientation(forPreviewRotationAngle: -90), .left)
    }

    func test_uprightSize_swapsForPortrait() {
        XCTAssertEqual(MRZScanGeometry.uprightSize(buffer: buffer, previewRotationAngle: 90), CGSize(width: 2160, height: 3840))
        XCTAssertEqual(MRZScanGeometry.uprightSize(buffer: buffer, previewRotationAngle: 180), buffer)
    }

    func test_regionOfInterest_accountsForAspectFillCrop() {
        // Upright 2160 x 3840 filling 430 x 932: scale 932/3840, so the image
        // shows 524.3 wide and 47.1 points of it are cropped off each side.
        let upright = MRZScanGeometry.uprightSize(buffer: buffer, previewRotationAngle: 90)
        let guide = CGRect(x: 25, y: 400, width: 380, height: 90)
        let region = MRZScanGeometry.regionOfInterest(guide: guide, layer: layer, uprightImage: upright)
        let shownWidth = 2160 * (932.0 / 3840.0)
        XCTAssertEqual(region.minX, (25 + (shownWidth - 430) / 2) / shownWidth, accuracy: 1e-6)
        XCTAssertEqual(region.width, 380 / shownWidth, accuracy: 1e-6)
        XCTAssertEqual(region.height, 90 / 932, accuracy: 1e-6)
        // Vision's origin is the bottom left.
        XCTAssertEqual(region.minY, 1 - 400.0 / 932 - 90.0 / 932, accuracy: 1e-6)
    }

    func test_regionOfInterest_centredGuideStaysCentred() {
        let upright = MRZScanGeometry.uprightSize(buffer: buffer, previewRotationAngle: 90)
        let guide = CGRect(x: 215 - 190, y: 466 - 45, width: 380, height: 90)
        let region = MRZScanGeometry.regionOfInterest(guide: guide, layer: layer, uprightImage: upright)
        XCTAssertEqual(region.midX, 0.5, accuracy: 1e-6)
        XCTAssertEqual(region.midY, 0.5, accuracy: 1e-6)
    }

    func test_regionOfInterest_clampsAnOverhangingGuide() {
        let upright = MRZScanGeometry.uprightSize(buffer: buffer, previewRotationAngle: 0)
        let region = MRZScanGeometry.regionOfInterest(
            guide: CGRect(x: -50, y: -50, width: 300, height: 100), layer: layer, uprightImage: upright
        )
        XCTAssertGreaterThanOrEqual(region.minX, 0)
        XCTAssertLessThanOrEqual(region.maxY, 1)
        XCTAssertFalse(region.isEmpty)
    }

    func test_zoom_movesTheHolderPastMinimumFocus() {
        // 70 degree field of view, 200 mm minimum focus, band at 90% of the
        // screen. A 125 mm page needs 214 mm at 1x, too close to 200 mm to
        // focus reliably, so aim for 1.4 x 200 = 280 mm: about 1.3x.
        let page = MRZScanGeometry.zoomFactor(
            minimumFocusDistance: 200, fieldOfView: 70, buffer: buffer, previewRotationAngle: 90,
            layer: layer, guideWidth: 387, subjectWidthMillimetres: 125, maximum: 4
        )
        XCTAssertEqual(page, 1.30, accuracy: 0.01)
        // The band is sized to the 112 mm zone itself, which needs a bit more.
        let zone = MRZScanGeometry.zoomFactor(
            minimumFocusDistance: 200, fieldOfView: 70, buffer: buffer, previewRotationAngle: 90,
            layer: layer, guideWidth: 387, maximum: 4
        )
        XCTAssertEqual(zone, 1.45, accuracy: 0.01)
    }

    func test_zoom_staysAtOneWhenNotNeededOrUnknown() {
        let close = MRZScanGeometry.zoomFactor(
            minimumFocusDistance: 100, fieldOfView: 70, buffer: buffer, previewRotationAngle: 90,
            layer: layer, guideWidth: 387, maximum: 4
        )
        XCTAssertEqual(close, 1)
        let unknown = MRZScanGeometry.zoomFactor(
            minimumFocusDistance: -1, fieldOfView: 70, buffer: buffer, previewRotationAngle: 90,
            layer: layer, guideWidth: 387, maximum: 4
        )
        XCTAssertEqual(unknown, 1)
    }

    func test_zoom_isCappedAtTheUpscaleThreshold() {
        let zoom = MRZScanGeometry.zoomFactor(
            minimumFocusDistance: 600, fieldOfView: 70, buffer: buffer, previewRotationAngle: 90,
            layer: layer, guideWidth: 387, maximum: 2
        )
        XCTAssertEqual(zoom, 2)
    }

    // MARK: - Dates

    func test_mrzDate_pivotsBirthIntoThePast() throws {
        let now = try XCTUnwrap(DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 10, day: 27).date)
        let calendar = Calendar(identifier: .gregorian)
        let year = { (text: String, expiry: Bool) in
            PassportMRZDate.date(text, isExpiry: expiry, now: now).map { calendar.component(.year, from: $0) }
        }
        XCTAssertEqual(year("740812", false), 1974)
        XCTAssertEqual(year("250101", false), 2025)
        XCTAssertEqual(year("300101", false), 1930)
        XCTAssertEqual(year("300101", true), 2030)
    }

    func test_mrzDate_refusesUnknownAndImpossibleDates() {
        XCTAssertNil(PassportMRZDate.date("7408<<", isExpiry: false))
        XCTAssertNil(PassportMRZDate.date("010229", isExpiry: true))
        XCTAssertNil(PassportMRZDate.date("010431", isExpiry: true))
        XCTAssertEqual(PassportMRZDate.display("7408<<", isExpiry: false), "7408<<")
    }
}
