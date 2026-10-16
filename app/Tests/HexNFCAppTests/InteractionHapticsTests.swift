import HexNFCShaders
import XCTest

/// Locks the interaction-haptic surface added for UI polish:
///  * the navigation/commit moments resolve to their dedicated patterns, and
///  * *every* moment (old and new) still maps to a pattern that has a real
///    `.ahap` resource in the bundle — so `HexHeroMoment.play()` is never a
///    silent miss.
final class InteractionHapticsTests: XCTestCase {
    func test_interactionMoments_mapToDedicatedPatterns() {
        XCTAssertEqual(HexHeroMoment.tap.haptic, .tapTick)
        XCTAssertEqual(HexHeroMoment.commit.haptic, .commitThud)
    }

    func test_everyMoment_resolvesToAPatternWithAhap() {
        let bundle = HexNFCShaders.resourceBundle
        for moment in HexHeroMoment.allCases {
            let pattern = moment.haptic
            XCTAssertNotNil(
                bundle.url(forResource: pattern.fileName, withExtension: "ahap"),
                "Moment \(moment.rawValue) → \(pattern.fileName).ahap is missing from the bundle."
            )
        }
    }

    func test_play_isSafeToCall() {
        // No haptics hardware in the test host — this must be a silent no-op,
        // never a crash or throw.
        HexHeroMoment.tap.play()
        HexHeroMoment.commit.play()
    }
}
