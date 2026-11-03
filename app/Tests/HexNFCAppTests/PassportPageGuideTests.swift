@testable import HexNFCApp
@testable import HexNFCDesign
import SwiftUI
import XCTest

/// The passport camera's page guide: where it puts the machine-readable zone,
/// how much slack the camera reads around it, and that it draws at all.
final class PassportPageGuideTests: XCTestCase {
    func test_zone_isTheBottom23point2mmOfA125by88Page() {
        let page = CGRect(x: 20, y: 100, width: 375, height: 375 * 88 / 125)
        let zone = PassportPageGuide.zone(inPage: page)
        XCTAssertEqual(zone.minX, page.minX)
        XCTAssertEqual(zone.width, page.width)
        XCTAssertEqual(zone.maxY, page.maxY, accuracy: 1e-9)
        XCTAssertEqual(zone.height / page.height, 23.2 / 88, accuracy: 1e-9)
        XCTAssertEqual(PassportPageGuide.aspectRatio, 125.0 / 88.0, accuracy: 1e-9)
    }

    func test_readingRegion_givesTheZoneSlackOnEverySide() {
        let zone = CGRect(x: 10, y: 300, width: 400, height: 100)
        let region = MRZScanGeometry.readingRegion(zone: zone)
        XCTAssertEqual(region.midX, zone.midX, accuracy: 1e-9)
        XCTAssertEqual(region.midY, zone.midY, accuracy: 1e-9)
        XCTAssertEqual(region.width, 400 * (1 + 2 * MRZScanGeometry.readingMarginX), accuracy: 1e-9)
        XCTAssertEqual(region.height, 100 * (1 + 2 * MRZScanGeometry.readingMarginY), accuracy: 1e-9)
    }

    @MainActor
    func test_guide_rendersInEveryEmphasis() throws {
        for emphasis in [PassportPageGuide.Emphasis.searching, .tracking, .locked] {
            let guide = PassportPageGuide(emphasis: emphasis)
                .frame(width: 375, height: 375 / PassportPageGuide.aspectRatio)
            let renderer = ImageRenderer(content: guide)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage, "\(emphasis) failed to rasterise")
            XCTAssertGreaterThan(image.width, image.height, "\(emphasis): TD3 is landscape")
        }
    }
}
