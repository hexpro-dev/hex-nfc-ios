@testable import HexNFCDesign
import SwiftUI
import XCTest

/// Rendering smoke test for the read-only transit card hero.
///
/// The project's CI runs the macOS-host `swift test` suite (plus an iOS *build*);
/// it does not execute an iOS UI-test bundle, and there is no golden-image
/// harness yet (device/OS-specific PNGs are fragile in CI). So rather than a
/// pixel snapshot, this locks the stable property that the hero composes and
/// rasterises to a non-empty image at its ID-1 aspect ratio without crashing —
/// and it runs on the host, where CI will actually exercise it. `ImageRenderer`
/// is cross-platform SwiftUI, so this needs no simulator.
final class TransitCardHeroSnapshotTests: XCTestCase {
    @MainActor
    func test_transitCardHero_rendersNonEmpty() throws {
        let hero = TransitCardHero(
            systemName: "Transit IC (Suica / PASMO …)",
            balanceText: "¥1,230",
            idmText: "01:02:03:04:05:06:07:08"
        )
        .frame(width: 340, height: 340 / 1.585)

        let renderer = ImageRenderer(content: hero)
        renderer.scale = 2
        let cgImage = try XCTUnwrap(renderer.cgImage, "hero failed to rasterise")

        XCTAssertGreaterThan(cgImage.width, 0)
        XCTAssertGreaterThan(cgImage.height, 0)
        // ID-1 proportions: wider than tall.
        XCTAssertGreaterThan(cgImage.width, cgImage.height)
    }
}
