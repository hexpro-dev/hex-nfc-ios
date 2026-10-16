import SwiftUI

/// Canonical Hex Pro design tokens. *Every* color, spacing, radius, motion
/// curve, and font in this app routes through this file. A grep for the
/// hex literals here outside of this module is a violation of the project
/// invariant — see `CLAUDE.md`.
public enum HexTokens {
    // MARK: - Color

    /// The palette as numbers. `Color` below is this, handed out as
    /// `SwiftUI.Color`; views keep using `Color` and never touch this. It is
    /// public only so `WCAGContrastTests` can measure the values that ship,
    /// including the Increase Contrast tier, which no environment can be built
    /// to render (`colorSchemeContrast` is get-only).
    ///
    /// See `HexTone` for why the Increase Contrast sibling lives in the token.
    public enum Palette {
        /// Deliberately has no Increase Contrast sibling. `primary` is a stroke
        /// and a wash here (the ghost button's border, the primary badge's
        /// capsule), never a fill under white text, and every sibling that
        /// suits a fill is darker, which on these near-black surfaces makes a
        /// stroke *less* visible: `#00509E` measures 2.43:1 on `surface0` where
        /// `#0B76D9` measures 4.23:1. The CTA fill's sibling lives on `ctaTop`
        /// and `ctaBottom` instead, where it only affects a fill.
        public static let primary = HexTone(0x0B76D9)
        public static let primaryLight = HexTone(0x5BA3F5, increased: HexInk(0x8CC2FF))
        /// The two stops of the primary call-to-action's fill, which carries
        /// white text and so is the one gradient in the app with a contrast
        /// obligation of its own.
        ///
        /// It used to run `primaryLight` to `primary`, whose top stop gave
        /// white 2.62:1. It now runs `primary` to a deeper blue, holding the
        /// brand hue and clearing AA along the whole ramp. `HexButton` keeps
        /// the lit look with a 1pt `primaryLight` top edge, which is a stroke
        /// and so is nothing's text background.
        ///
        /// Both stops take the *same* Increase Contrast sibling, which is what
        /// flattens the button to a solid fill in that tier;
        /// `Stroke.contrastEdge` is what keeps it identifiable once flat.
        public static let ctaTop = HexTone(0x0B76D9, increased: HexInk(0x00509E))
        public static let ctaBottom = HexTone(0x0061C2, increased: HexInk(0x00509E))
        public static let surface0 = HexTone(0x0F0E0D)
        public static let surface1 = HexTone(0x1A1816)
        public static let surface2 = HexTone(0x221F1C)
        public static let textPrimary = HexTone(0xF3EFE9)
        public static let textSecondary = HexTone(0x9B958C, increased: HexInk(0xC8C2B8))
        /// Washes, strokes and glyphs. Not text, and not a surface carrying
        /// text: `danger` was doing all three jobs and could only satisfy one.
        public static let danger = HexTone(0xE3524B, increased: HexInk(0xFF8A82))
        /// Danger as a *foreground*: badge labels, error copy, destructive
        /// glyph captions. Lifted from `danger`, which reached only 4.35:1 on
        /// `surface2` and 3.52:1 on its own badge wash.
        public static let dangerText = HexTone(0xF9675E, increased: HexInk(0xFF8A82))
        /// Danger as a *surface* carrying white text: the destructive button.
        /// Deepened from `danger`, which gave white 3.77:1.
        public static let dangerFill = HexTone(0xCE403B, increased: HexInk(0x8E1F1A))
        public static let success = HexTone(0x6AC98A, increased: HexInk(0x8FE0AB))
        public static let warning = HexTone(0xE7B752, increased: HexInk(0xF5CE79))
    }

    public enum Color {
        /// Primary brand blue. The signature Hex Pro mark.
        public static let primary = Palette.primary.color
        /// Lighter sister of `primary`, used for hover / glow / particle tints.
        public static let primaryLight = Palette.primaryLight.color
        /// Deepest surface. Application background.
        public static let surface0 = Palette.surface0.color
        /// Mid surface — sheets, primary cards.
        public static let surface1 = Palette.surface1.color
        /// Top surface — pop-overs, contextual menus, nested cards.
        public static let surface2 = Palette.surface2.color
        public static let textPrimary = Palette.textPrimary.color
        public static let textSecondary = Palette.textSecondary.color
        /// Danger for washes, strokes and glyphs. For danger *text* use
        /// `dangerText`; for a danger *surface* under white text, `dangerFill`.
        public static let danger = Palette.danger.color
        public static let dangerText = Palette.dangerText.color
        public static let dangerFill = Palette.dangerFill.color
        public static let success = Palette.success.color
        public static let warning = Palette.warning.color
        /// Deep stop of the primary call-to-action gradient.
        public static let primaryDeep = Palette.ctaBottom.color
        /// Light stop of the primary call-to-action gradient.
        public static let primaryCTATop = Palette.ctaTop.color
    }

    // MARK: - Gradient

    public enum Gradient {
        /// Soft, desaturated spectrum reserved for the single donation
        /// affordance (the development-costs bar). Deliberately gentle — the
        /// brand stays blue everywhere else. These pastel literals live here,
        /// the canonical home for color, so views never carry hex literals.
        public static let rainbow: [SwiftUI.Color] = [
            SwiftUI.Color(red: 0xF5 / 255, green: 0xA3 / 255, blue: 0xA3 / 255),
            SwiftUI.Color(red: 0xF5 / 255, green: 0xD3 / 255, blue: 0xA3 / 255),
            SwiftUI.Color(red: 0xF0 / 255, green: 0xF0 / 255, blue: 0xA3 / 255),
            SwiftUI.Color(red: 0xA3 / 255, green: 0xF5 / 255, blue: 0xB8 / 255),
            SwiftUI.Color(red: 0xA3 / 255, green: 0xD8 / 255, blue: 0xF5 / 255),
            SwiftUI.Color(red: 0xC2 / 255, green: 0xA3 / 255, blue: 0xF5 / 255),
            SwiftUI.Color(red: 0xF5 / 255, green: 0xA3 / 255, blue: 0xE0 / 255),
        ]
    }

    // MARK: - Transit

    /// Palette for the read-only transit-card view (Suica/PASMO-family).
    /// These are *not* Hex brand colours — they evoke the iconic Japanese
    /// transit-card art so a scanned card feels authentic. They live here, the
    /// one sanctioned home for colour literals, so views stay literal-free.
    public enum Transit {
        public enum Palette {
            /// Deepened from `#2EA96B` / `#136B5A`, which left the card's own
            /// labels between 2.16:1 and 2.78:1. Hue and chroma are held in
            /// OKLab and only lightness moves, so it reads as a deeper printing
            /// of the same green rather than a different colour. A lighter
            /// green cannot pass: two of the five text elements are 13pt.
            public static let cardTop = HexTone(0x248554)
            public static let cardBottom = HexTone(0x0E5546)
            public static let cardText = HexTone(0xFCFDFB)
            /// Raised from 0.72. At 0.72 the two smallest labels on the card
            /// were its worst-contrast elements.
            public static let cardTextDim = HexTone(0xFFFFFF, alpha: 0.94)
            public static let chipGold = HexTone(0xD8C27A)
            /// The wave bands printed across the card, flipped from white to
            /// black at the same 5%. They cross the column the two 13pt labels
            /// sit in, so as white they were lightening the background under
            /// the card's hardest-to-read text while looking like pure
            /// decoration. Black bands are the cheapest ratio in this file:
            /// same texture, roughly +0.3 everywhere they fall.
            public static let cardTexture = HexTone(0x000000, alpha: 0.05)
        }

        /// Top of the card gradient — the signature transit green.
        public static let cardTop = Palette.cardTop.color
        /// Bottom of the card gradient — a deeper teal-green.
        public static let cardBottom = Palette.cardBottom.color
        /// Primary text/numerals on the card (high-contrast off-white).
        public static let cardText = Palette.cardText.color
        /// Secondary text on the card (translucent white).
        public static let cardTextDim = Palette.cardTextDim.color
        /// The IC-chip glyph gold.
        public static let chipGold = Palette.chipGold.color
        /// The wave bands printed across the card. These used to be a literal
        /// in `TransitCardHero`, which put them outside the guard even though
        /// they cross the column the card's smallest text sits in.
        public static let cardTexture = Palette.cardTexture.color
    }

    // MARK: - Passport

    /// Palette for the read-only electronic-passport view. Not Hex brand
    /// colours — a warm parchment data page with navy ink and gold foil, so a
    /// scanned passport reads as the official document it is. They live here,
    /// the one sanctioned home for colour literals, so views stay literal-free.
    public enum Passport {
        public enum Palette {
            public static let pageTop = HexTone(0xF4EFE3)
            public static let pageBottom = HexTone(0xE6E2D6)
            public static let mrzBand = HexTone(0xECE6D7)
            public static let ink = HexTone(0x1B2A4A)
            public static let inkDim = HexTone(0x5A647C)
            /// Deepened from `#A8864E`, which gave the crest stroke 2.62:1
            /// against the page. Still unmistakably foil.
            public static let gold = HexTone(0x9B7941)
            /// Verdict inks for the integrity badge. The dark-surface
            /// `Color.success` / `Color.danger` were being reused here, on
            /// parchment they were never mixed for: they measured 1.47:1 and
            /// 2.50:1 against their own washes. These are the same hues taken
            /// down to a weight that works on paper.
            public static let inkGood = HexTone(0x00602C)
            public static let inkBad = HexTone(0xA31A1A)
        }

        /// Top of the data-page gradient — warm ivory paper.
        public static let pageTop = Palette.pageTop.color
        /// Bottom of the data-page gradient — cooler aged paper.
        public static let pageBottom = Palette.pageBottom.color
        /// The engraved-band paper the MRZ sits on.
        public static let mrzBand = Palette.mrzBand.color
        /// Primary ink — a deep passport navy.
        public static let ink = Palette.ink.color
        /// Secondary ink — muted slate for field labels.
        public static let inkDim = Palette.inkDim.color
        /// Gold-foil accent for the crest / e-passport symbol.
        public static let gold = Palette.gold.color
        /// "Integrity verified" ink, for use on the parchment page only.
        public static let inkGood = Palette.inkGood.color
        /// "Integrity mismatch" ink, for use on the parchment page only.
        public static let inkBad = Palette.inkBad.color
    }

    // MARK: - Opacity

    public enum Opacity {
        /// The tinted capsule behind a label of the same hue: `HexBadge`, the
        /// console and harness status chips, the passport integrity badge.
        ///
        /// One value because it is one idea, and because both sides of that
        /// ratio are the same colour: the wash is the only thing separating the
        /// label from its own capsule. The four carried 0.18, 0.15, 0.15 and
        /// 0.14 independently, and the 0.15 chips sat at 4.49:1, which is the
        /// kind of miss that only shows up when something measures it.
        public static let tintWash: Double = 0.14
    }

    // MARK: - Spacing (4-point grid)

    public enum Spacing {
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
    }

    // MARK: - Radius

    public enum Radius {
        public static let s: CGFloat = 6
        public static let m: CGFloat = 10
        public static let l: CGFloat = 16
        public static let pill: CGFloat = 999
    }

    // MARK: - Stroke

    public enum Stroke {
        public enum Palette {
            public static let cardInner = HexTone(
                HexInk(0xFFFFFF, alpha: 0.04), increased: HexInk(0x8A857D)
            )
            /// Invisible by default; a hairline once Increase Contrast is on.
            public static let contrastEdge = HexTone(
                HexInk(0xFFFFFF, alpha: 0), increased: HexInk(0xC8C2B8)
            )
        }

        /// Subtle inner stroke on cards. 4% white over surface1 reads as a
        /// gentle bevel under both bright and dim ambient light, and becomes an
        /// actual boundary under Increase Contrast.
        public static let cardInner = Palette.cardInner.color
        public static let cardInnerWidth: CGFloat = 1

        /// Applied unconditionally to controls whose shape is carried by fill
        /// alone. It draws nothing until the reader asks for more contrast, so
        /// a caller does not branch and cannot forget the branch.
        public static let contrastEdge = Palette.contrastEdge.color
        public static let contrastEdgeWidth: CGFloat = 1
    }

    // MARK: - Motion

    public enum Motion {
        /// Snappy spring for micro-interactions — button taps, toggles.
        public static let snappy = Animation.spring(response: 0.32, dampingFraction: 0.82)
        /// Standard transition for sheets, page navigation.
        public static let standard = Animation.spring(response: 0.45, dampingFraction: 0.78)
        /// Lush spring for hero entrances — splash, scan-success bloom.
        public static let lush = Animation.spring(response: 0.62, dampingFraction: 0.74)
        /// Repeating pulse used by the scan affordance.
        ///
        /// **Deliberately not public.** This is the app's only `repeatForever`,
        /// and a screen that can name it is a screen that can start an
        /// unbounded animation without gating it on Reduce Motion, which is
        /// exactly how `ScanSheet` came to run the app's most-seen animation
        /// through that setting for as long as it did. `View.hexPulse(active:)`
        /// is the only way to spell this loop from outside the module, and it
        /// carries the gate with it, so forgetting is now a compile error
        /// rather than a shipped regression.
        static let scanPulse = Animation.easeInOut(duration: 1.1).repeatForever(autoreverses: true)

        /// Peak scale of that pulse. Lives beside the curve so the two cannot
        /// drift apart.
        static let pulseScale: CGFloat = 1.05
    }

    // MARK: - Typography

    /// Apple system fonts for Phase 2. Phase 5 polish swaps display + body
    /// for bundled Sansation + DM Sans when the font files land in
    /// `Sources/HexNFCDesign/Resources/Fonts/`.
    public enum Font {
        public static let display = SwiftUI.Font.system(size: 34, weight: .medium, design: .default)
        public static let title = SwiftUI.Font.system(size: 22, weight: .semibold, design: .default)
        public static let heading = SwiftUI.Font.system(size: 17, weight: .semibold, design: .default)
        public static let body = SwiftUI.Font.system(size: 15, weight: .regular, design: .default)
        public static let footnote = SwiftUI.Font.system(size: 13, weight: .regular, design: .default)
        public static let mono = SwiftUI.Font.system(size: 13, weight: .regular, design: .monospaced)

        /// The product name under the Hex Pro mark, in the house lockup face.
        ///
        /// IBM Plex Mono, sized and tracked to the proportions the web lockup
        /// uses (`BrandLockup.tsx` in hex-web): an 11px name under a 36px mark
        /// at `size="lg"`, tracked `0.22em`. Both are ratios rather than points
        /// so a caller that changes the mark's height keeps the proportion.
        ///
        /// Sol Alarm's `YFontSpec.lockup(logoHeight:)` implements the identical
        /// rule against its own tokens. Change one and change the other, or the
        /// family drifts apart again, which is what this replaced.
        ///
        /// The face is bundled by the app target and registered through
        /// `UIAppFonts`, not by this package, so a preview or a snapshot test
        /// rendered outside the app will quietly fall back to the system font.
        /// `fixedSize:` rather than `size:` because `Font.custom(_:size:)`
        /// scales with the body text style on its own, and nothing else in this
        /// enum scales; a lockup that grew while the mark beside it stayed put
        /// would break the very proportion this exists to hold.
        public static func lockup(logoHeight: CGFloat) -> Lockup {
            let size = logoHeight * (11.0 / 36.0)
            return Lockup(font: .custom("IBMPlexMono-Regular", fixedSize: size),
                          tracking: size * 0.22)
        }

        /// A lockup's face and its letter spacing, which travel together.
        public struct Lockup {
            public let font: SwiftUI.Font
            public let tracking: CGFloat
        }
    }
}
