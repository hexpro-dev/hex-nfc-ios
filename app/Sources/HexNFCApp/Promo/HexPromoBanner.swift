import HexNFCDesign
import HexNFCShaders
import SwiftUI

/// A cross-promotion for another Hex Pro app, at the foot of Home.
///
/// Written here rather than taken from the SDK, and that is exactly why
/// `PromoBanner.swift` is the one upstream file `app/Sources/HexPromoKit` does
/// not carry. A banner is the part of that package that has to look like the app
/// it is sitting in, and the vendored copy is kept byte for byte, so adapting it
/// there would have turned every future re-sync into a merge.
///
/// ## Borrowed from upstream, because production paid for it
///
/// The media draws at the CREATIVE's declared aspect ratio and is scaled to fit,
/// never distorted: a house aspect would crop or squash art the CMS authored at
/// its own shape.
///
/// A slot with no creative renders a true `EmptyView` and not a zero-height
/// placeholder. This view is only ever constructed with a resolved creative, so
/// the branch lives one level up in `HomePromoSlot`, where SwiftUI's `if let`
/// with no `else` produces a genuine absence. A zero-height view would still
/// collect its parent stack's spacing, and Home's `VStack` runs on
/// `HexTokens.Spacing.xl`, so the empty state would show as a visible gap under
/// the development-costs card. Media that will not decode takes the same route
/// out, from inside this file: see `mediaIsUnreadable`.
///
/// ## Not borrowed
///
/// The corner radius, the fill, the fade curve and the accessibility label are
/// all this app's. Upstream hardcodes `Text("Promotion")`, which is the specific
/// reason its banner could not be vendored: every user-facing string in Hex NFC
/// routes through `Localizable.xcstrings`, which carries six translations, and a
/// literal inside a vendored file cannot be entered in that catalogue.
///
/// ## Why it is labelled to the eye, not only to VoiceOver
///
/// Upstream announces the banner to assistive technology and to nobody else,
/// which is honest to the smallest possible audience. Home is already a stack of
/// titled cards (the development-costs panel directly above is one), so the
/// honest version costs nothing structurally: the promo is another `HexCard`
/// with a heading, and a reader can see what it is before deciding to tap.
///
/// The heading names Hex Pro instead of calling itself an advertisement, which
/// is the accurate description: a first-party promotion for another app by the
/// same developer, with no ad network, no third party and no tracking in it. The
/// VoiceOver label says "promotion" outright so that nobody has to infer it. The
/// About paragraph in Settings was tightened to match, because a heading that
/// says "More from Hex Pro" and a line that says "shows no ads" cannot both
/// stand on the same device.
struct HexPromoBanner: View {
    let creative: PromoCreative

    /// Injected rather than opened here, so this view stays free of the
    /// environment seam and of any platform-specific open call.
    let onOpen: (URL) -> Void

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.hexReduceMotion) private var appReduceMotion

    @State private var hasAppeared = false

    /// What this creative's media turned out to be, tagged with the URL it was
    /// judged on. The tag is what stops a campaign swap inheriting the last
    /// creative's verdict, which would collapse a banner that draws perfectly
    /// well or reveal one whose file has gone.
    @State private var mediaVerdict: PromoMediaVerdict?

    /// Both switches, matching `DonationProgressBar` directly above it on Home.
    /// Reading only the system flag would leave a reader who ticked the in-app
    /// override watching a promo video loop under a rainbow bar that had already
    /// frozen for them. `\.hexReduceMotion` comes from `HexNFCShaders`, which is
    /// where `RootView` publishes the combined value.
    private var reduceMotion: Bool {
        systemReduceMotion || appReduceMotion
    }

    private var mediaIsReady: Bool {
        mediaVerdict == .readable(creative.mediaURL)
    }

    private var mediaIsUnreadable: Bool {
        mediaVerdict == .unreadable(creative.mediaURL)
    }

    private var isVisible: Bool {
        hasAppeared && mediaIsReady
    }

    var body: some View {
        // Media that will not decode takes the whole card with it, heading and
        // chrome included. The file sits in the Caches directory, which iOS may
        // purge after the manager has already published `.resolved`, so a
        // creative that existed at resolve time can be gone by the time it is
        // drawn. A titled, tappable card wrapped around an empty box reads as a
        // broken promotion; nothing at all is what this slot looks like for most
        // of the app's life anyway, and Home loses no spacing to it.
        if !mediaIsUnreadable {
            card
        }
    }

    private var card: some View {
        HexCard {
            VStack(alignment: .leading, spacing: HexTokens.Spacing.m) {
                Text("More from Hex Pro")
                    .font(HexTokens.Font.heading)
                    .foregroundStyle(HexTokens.Color.textPrimary)
                media
                    .frame(maxWidth: .infinity)
                    .aspectRatio(creative.aspectRatio, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: HexTokens.Radius.s, style: .continuous))
                    // A creative with dark or transparent edges would otherwise
                    // bleed into the card fill and lose its own outline.
                    .overlay(
                        RoundedRectangle(cornerRadius: HexTokens.Radius.s, style: .continuous)
                            .strokeBorder(
                                HexTokens.Stroke.cardInner,
                                lineWidth: HexTokens.Stroke.cardInnerWidth
                            )
                    )
                    .contentShape(Rectangle())
                    .modifier(OpenOnTap(url: creative.linkURL, action: onOpen))
                    .accessibilityElement()
                    .accessibilityAddTraits(creative.isTappable ? .isButton : .isImage)
                    .accessibilityLabel(Text("Promotion for another Hex Pro app"))
                    .accessibilityIdentifier("home.promo.creative")
            }
        }
        // A fade and not a slide. The banner arrives after the rest of Home has
        // settled, and anything that moves at that point pulls the eye off
        // whatever the reader was already looking at.
        //
        // Held at zero until the media is known readable as well, so a creative
        // that turns out not to decode is never part-way through its fade when
        // it goes: it would flash an empty box on the way out. The card holds
        // its box for that frame either way, which costs nothing at the foot of
        // a scrolling screen.
        .opacity(isVisible ? 1 : 0)
        // Zero opacity still takes taps, so the fade cannot be left to carry
        // this on its own. Without it, the window before the media is judged,
        // and the whole life of a creative whose file has gone, leave an
        // invisible strip of Home that opens an external URL when tapped.
        .allowsHitTesting(isVisible)
        .animation(reduceMotion ? nil : HexTokens.Motion.standard, value: isVisible)
        .onAppear { hasAppeared = true }
        // The verdict is settled here, and settled again whenever the creative
        // changes, rather than left to whichever phase closure `AsyncImage`
        // happens to run first: the previous campaign's answer is overwritten
        // before this one can be drawn. The guard keeps a verdict already
        // reached for THIS creative, which is the case where the image decoded
        // before this ran.
        .task(id: creative.mediaURL) {
            guard !mediaIsReady, !mediaIsUnreadable else { return }
            mediaVerdict = PromoMediaVerdict.fromDisk(for: creative)
        }
        .accessibilityIdentifier("home.promo")
    }

    @ViewBuilder private var media: some View {
        if creative.isVideo {
            // Held on its first frame under Reduce Motion. A silent loop at the
            // foot of a screen is the continuous movement that setting exists to
            // stop, and the opening frame is already the poster the CMS authored.
            PromoVideoView(url: creative.mediaURL, autoplay: !reduceMotion)
                // Keyed on the media URL because `PromoVideoView` builds its
                // player from an autoclosure SwiftUI evaluates once per view
                // identity. Without the key, a creative swapped in while Home is
                // on screen leaves the previous file looping.
                .id(creative.mediaURL)
        } else {
            // A local file the manager already downloaded, so this never touches
            // the network. `AsyncImage` still earns its place: it decodes off the
            // main thread, which a creative authored at 1200 pt wide wants.
            AsyncImage(url: creative.mediaURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable().scaledToFit()
                        .onAppear { mediaVerdict = .readable(creative.mediaURL) }

                case .failure:
                    // The verdict has to reach the card above, and it arrives
                    // inside a closure SwiftUI is already running an update for,
                    // so it lands in state from `onAppear` rather than being
                    // assigned here.
                    Color.clear.onAppear { mediaVerdict = .unreadable(creative.mediaURL) }

                default:
                    // Not a spinner. The bytes are already on disk and decoding
                    // is effectively instant, so a spinner would only flash, and
                    // the card is invisible until the decode lands anyway.
                    Color.clear
                }
            }
        }
    }
}

/// Whether a creative's media can be drawn, tagged with the media it answers
/// for.
///
/// The tag is what a campaign swap turns on: a verdict reached for the previous
/// creative answers for that URL and for no other, so it can neither collapse
/// the next banner nor reveal it.
enum PromoMediaVerdict: Equatable {
    case readable(URL)
    case unreadable(URL)

    /// The verdict the filesystem can give on its own, or nil when the media
    /// has still to decode.
    ///
    /// Media sits in the Caches directory, which iOS may purge after the
    /// manager has published `.resolved`, so the file behind a creative can be
    /// gone by the time the banner draws it. For video that is the only signal
    /// there is: `AVPlayer` answers nothing synchronously, and its item's
    /// `.failed` status arrives only once the player has tried to load the
    /// asset, so watching it would either fade the card in and then take it
    /// away again, or hold every healthy video off screen until that load
    /// finished. One `stat` when the creative changes settles before the fade
    /// starts. The same check inside `body` was rejected in an earlier pass,
    /// and rightly: there it is main-thread filesystem I/O on every body
    /// evaluation.
    ///
    /// Its limit is that existence is not decodability. A video file that is
    /// present but unplayable still shows the player's empty frame, and a purge
    /// that happens while the banner is already on screen is not re-checked.
    /// An image gets a second answer from `AsyncImage`'s `.failure` phase, which
    /// does catch a file that is present and will not decode; video has no
    /// equivalent.
    static func fromDisk(for creative: PromoCreative) -> PromoMediaVerdict? {
        guard FileManager.default.fileExists(atPath: creative.mediaURL.path) else {
            return .unreadable(creative.mediaURL)
        }
        // An image is not readable until it has decoded, which `AsyncImage`
        // reports; for video, a file that is present is as much as this knows.
        return creative.isVideo ? .readable(creative.mediaURL) : nil
    }
}

/// Adds the tap gesture only when the creative carries a link.
///
/// A modifier rather than a `Button` with a no-op action: a `Button` reports
/// itself as a control to assistive technology whether or not it does anything,
/// so a creative with no link would be announced to VoiceOver as something to
/// activate and then do nothing when activated.
private struct OpenOnTap: ViewModifier {
    let url: URL?
    let action: (URL) -> Void

    func body(content: Content) -> some View {
        if let url {
            content.onTapGesture { action(url) }
        } else {
            content
        }
    }
}
