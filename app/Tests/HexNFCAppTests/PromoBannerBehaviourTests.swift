import AVFoundation
import Foundation
@testable import HexNFCApp
import XCTest

/// The promo banner's behaviour, at the level it is reachable from.
///
/// `HomePromoSlot.creative(from:)` cannot be called here: its parameter is the
/// vendored `PromoResolution` and this target does not depend on `HexPromoKit`.
/// Adding the dependency would fail `PromoImportContainmentTests`, which counts
/// how many times the module is named in `app/Package.swift`. The boundary
/// translation is therefore tested through the piece of it that takes ordinary
/// values.
///
/// Two behaviours in `HexPromoBanner` have no seam and are left untested rather
/// than checked by grepping the source, which is a check a comment would
/// satisfy: the card is held non-interactive while it is invisible, and the
/// verdict is re-settled when the creative changes. Both are `@State` on a
/// SwiftUI view and only mean anything once SwiftUI has run an update.
final class PromoBannerBehaviourTests: XCTestCase {
    // MARK: The creative the banner draws from

    /// A creative with no link must not report itself as a control.
    ///
    /// `HexPromoBanner` reads `isTappable` to choose between the `.isButton` and
    /// `.isImage` VoiceOver traits, while `OpenOnTap` reads `linkURL` to decide
    /// whether to attach a gesture at all. Both derive from the same optional,
    /// which is what keeps them agreeing; this pins that derivation, not the two
    /// view-side reads, which have no seam to test from here.
    func test_isTappable_followsTheLink() {
        XCTAssertTrue(makeCreative().isTappable)
        XCTAssertFalse(makeCreative(linkURL: nil).isTappable)
    }

    /// A malformed aspect ratio must not reach SwiftUI layout.
    ///
    /// `ResolvedPromo.aspectRatio` divides `aspectWidth` by `aspectHeight` and
    /// guards the zero denominator alone, so `aspectWidth: 0` in a CMS response
    /// arrives as 0 and a single negative side arrives negative. The banner
    /// takes its whole box from `.aspectRatio(_:contentMode:)`, which has no
    /// meaning for either.
    func test_usableAspectRatio_rejectsAValueThatIsNotAShape() {
        XCTAssertEqual(HomePromoSlot.usableAspectRatio(1.91), 1.91, accuracy: 0.0001)
        XCTAssertEqual(
            HomePromoSlot.usableAspectRatio(0),
            1,
            accuracy: 0.0001,
            "a zero ratio from the CMS now reaches SwiftUI layout"
        )
        XCTAssertEqual(
            HomePromoSlot.usableAspectRatio(-1.91),
            1,
            accuracy: 0.0001,
            "a negative ratio from the CMS now reaches SwiftUI layout"
        )
    }

    // MARK: The CMS join key

    /// The key the view reads a resolution back under has to be the key the
    /// registration was filed under.
    ///
    /// `PromoManager.register` files a slot under `bundleId|platform|locationId`
    /// and the view calls `resolution(for:)` with `HomePromoSlot.cacheKey`.
    /// Drift between the two neither throws nor logs: the manager publishes
    /// under one key, the view reads another, and the banner simply never
    /// appears. Both sides read the same three constants, so what a value here
    /// still catches is those constants composing into a key the CMS registry
    /// row was not created under. The expected key is spelled out because the
    /// module that composes it cannot be imported into this target.
    func test_cacheKey_isTheKeyTheRegistrationIsFiledUnder() {
        XCTAssertEqual(
            HomePromoSlot.cacheKey,
            "pro.hex.nfc|ios|home_bottom",
            "the read key no longer matches the key PromoManager files this slot's registration under"
        )
    }

    // MARK: Media that will not draw

    /// A video whose file has gone collapses the card.
    ///
    /// Media lives in the Caches directory, which iOS may purge after the
    /// manager has published `.resolved`, and a titled, tappable card wrapped
    /// around an empty player frame reads as a broken promotion. An image gets
    /// this verdict from `AsyncImage`'s `.failure` phase; video has no decode
    /// phase to report from, so the verdict has to come from the file.
    func test_mediaVerdict_collapsesAVideoWhoseFileHasGone() throws {
        let present = try temporaryFile()
        let onDisk = try XCTUnwrap(
            PromoMediaVerdict.fromDisk(for: makeCreative(mediaURL: present, isVideo: true)),
            "a video whose file is on disk is no longer judged at all, so the banner stays invisible"
        )
        XCTAssertEqual(onDisk, .readable(present))

        let purged = try temporaryFile()
        try FileManager.default.removeItem(at: purged)
        let gone = try XCTUnwrap(
            PromoMediaVerdict.fromDisk(for: makeCreative(mediaURL: purged, isVideo: true)),
            "a purged video no longer collapses the card, so the promotion draws an empty player frame"
        )
        XCTAssertEqual(gone, .unreadable(purged))
    }

    /// An image is left to the decoder while its file is there, and collapsed
    /// once it is not.
    ///
    /// Calling a present image readable from the filesystem would fade the card
    /// in over an `AsyncImage` that has not produced anything yet, which is the
    /// flash of an empty framed box the fade exists to avoid.
    func test_mediaVerdict_leavesAPresentImageToTheDecoder() throws {
        let present = try temporaryFile()
        XCTAssertNil(
            PromoMediaVerdict.fromDisk(for: makeCreative(mediaURL: present)),
            "a present image is judged readable before it has decoded, so the card fades in over nothing"
        )

        let purged = try temporaryFile()
        try FileManager.default.removeItem(at: purged)
        let gone = try XCTUnwrap(
            PromoMediaVerdict.fromDisk(for: makeCreative(mediaURL: purged)),
            "a purged image is no longer collapsed before it is drawn"
        )
        XCTAssertEqual(gone, .unreadable(purged))
    }

    // MARK: The player a campaign swap rebuilds

    /// The two things about the rebuilt player that are settled in its
    /// initialiser, and are therefore checkable without playing anything.
    ///
    /// Muting is the shipping rule: a banner that makes noise on a screen
    /// somebody opened to read a tag is an ambush. The looper is stored rather
    /// than discarded for a reason that is invisible in review, which is why the
    /// model was ported instead of reinvented. Reflection is the only way to see
    /// a stored property nothing reads.
    ///
    /// Playback itself is not asserted. `play()` on an item with no decodable
    /// media settles asynchronously, so any assertion on `rate` or
    /// `timeControlStatus` here would be a race dressed up as a test.
    @MainActor
    func test_videoModel_isMutedAndKeepsItsLooper() throws {
        let file = try temporaryFile()
        let model = PromoVideoModel(url: file)

        XCTAssertTrue(
            model.player.isMuted,
            "the promo player is no longer muted; a banner that plays sound unasked is an App Review rejection"
        )
        XCTAssertEqual(
            model.player.actionAtItemEnd,
            .advance,
            "AVPlayerLooper needs the queue to advance at item end or the loop stops"
        )

        let keepsLooper = Mirror(reflecting: model).children.contains {
            $0.label == "looper" && $0.value is AVPlayerLooper
        }
        XCTAssertTrue(
            keepsLooper,
            """
            PromoVideoModel no longer stores its AVPlayerLooper. Released, it stops looping \
            after one pass, silently, with nothing in the log to say so
            """
        )
    }

    // MARK: Fixtures

    private func makeCreative(
        id: String = "campaign-1",
        mediaURL: URL = URL(fileURLWithPath: "/var/tmp/hexnfc-promo/creative.png"),
        isVideo: Bool = false,
        aspectRatio: Double = 16.0 / 9.0,
        linkURL: URL? = URL(string: "https://hex.pro")
    ) -> PromoCreative {
        PromoCreative(
            id: id,
            mediaURL: mediaURL,
            isVideo: isVideo,
            aspectRatio: aspectRatio,
            linkURL: linkURL
        )
    }

    /// An empty file rather than a path that does not exist, so the checks that
    /// want media present are pointed at something real. Nothing in this file
    /// decodes or plays it.
    private func temporaryFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexnfc-promo-\(UUID().uuidString).mp4")
        try Data().write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
