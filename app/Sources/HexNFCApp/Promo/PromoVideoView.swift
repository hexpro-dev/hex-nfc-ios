import AVKit
import Foundation
import SwiftUI

/// Owns the queue player and its looper for a video creative, so playback
/// survives a view update.
///
/// A port of the model inside upstream's dropped `LoopingVideoPlayer` rather
/// than a reinvention, because one detail in it is not obvious and is expensive
/// to rediscover: `AVPlayerLooper` has to be RETAINED. Let it go and looping
/// stops silently after a single pass, with no error and nothing in the log.
/// That is why `looper` is a stored property nothing ever reads.
///
/// Muted, always. A banner that makes noise on a screen somebody opened to read
/// a tag is an ambush, and App Review takes the same view.
@MainActor
final class PromoVideoModel: ObservableObject {
    let player: AVQueuePlayer
    private let looper: AVPlayerLooper

    init(url: URL) {
        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.actionAtItemEnd = .advance
        player = queue
        looper = AVPlayerLooper(player: queue, templateItem: item)
    }

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
    }
}

/// A muted, looping video creative.
///
/// Hit testing is off on the player so the tap gesture in `HexPromoBanner`
/// always wins. Left on, `VideoPlayer` shows its own transport controls and
/// swallows the tap, which turns a promotion into a video widget nobody asked
/// for and breaks the only thing the banner is there to do.
struct PromoVideoView: View {
    let url: URL

    /// False under Reduce Motion, where the first frame stands still instead of
    /// looping. Nothing else about the view changes: the poster frame is the
    /// creative's own opening art.
    let autoplay: Bool

    /// A `@StateObject` so SwiftUI builds the player once per view identity. A
    /// plain `@State` would reconstruct it (and its looper) on every update,
    /// which restarts playback from the top each time.
    ///
    /// The flip side is that the autoclosure runs once per identity and never
    /// sees a later `url`, so the call site keys this view on the creative's
    /// media URL. Without that key a campaign swap while Home is on screen keeps
    /// the OLD file playing, and the swap is the manager's ordinary sequence
    /// rather than an edge case: it publishes the cached creative first and the
    /// freshly fetched one a moment later.
    @StateObject private var model: PromoVideoModel

    init(url: URL, autoplay: Bool) {
        self.url = url
        self.autoplay = autoplay
        _model = StateObject(wrappedValue: PromoVideoModel(url: url))
    }

    var body: some View {
        VideoPlayer(player: model.player)
            .allowsHitTesting(false)
            .onAppear {
                if autoplay {
                    model.play()
                }
            }
            // Playback follows the flag and not the appearance event. Settings
            // is a sheet over Home, so the banner stays mounted while the reader
            // ticks the in-app Reduce Motion override and `.onAppear` never
            // fires again. Driven from appearance alone, the loop carried on
            // under a rainbow bar that had already frozen for that same reader.
            .onChange(of: autoplay) { _, isOn in
                if isOn {
                    model.play()
                } else {
                    model.pause()
                }
            }
            .onDisappear { model.pause() }
    }
}
