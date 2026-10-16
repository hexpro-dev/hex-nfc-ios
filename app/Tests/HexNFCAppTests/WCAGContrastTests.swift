import HexNFCDesign
import XCTest

/// Holds the palette to WCAG 2.2 AA.
///
/// Arithmetic over `HexTokens.Palette`, not rendering. Two reasons it has to be
/// that way round. `SwiftUI.Color` will not give its components back, and
/// `EnvironmentValues.colorSchemeContrast` is get-only, so no test can build an
/// environment with Increase Contrast switched on and ask what a colour
/// resolved to. Measuring the numbers the palette ships is the only way to
/// cover both tiers, and it is why `HexInk` keeps them as `Double`s.
///
/// **Thresholds.** WCAG's "large text" is defined in CSS pixels, and one iOS
/// point is one CSS pixel, so large starts at 24pt (18.66pt bold). Every font
/// in `HexTokens.Font` is smaller than that, `Font.heading` at 17pt semibold
/// included, so the text threshold here is 4.5:1 throughout and 3:1 is used
/// only for graphics and for the one genuinely large readout (the 40pt balance).
///
/// **Gradients are measured across their whole length**, not at the position
/// some particular label happens to sit. Sampling a position means encoding a
/// layout the test cannot see, and `PassportBookletHero` has no fixed aspect
/// ratio at all, so its gradient parameter moves with content. The worst case
/// over `t ∈ [0, 1]` needs no geometry, and it is the stronger claim.
final class WCAGContrastTests: XCTestCase {
    // MARK: - WCAG arithmetic

    /// WCAG 2.x relative luminance. The transfer function is the piecewise sRGB
    /// one, not a 2.2 power law; they differ near black by enough to move a
    /// ratio, and near black is exactly where this app lives.
    private func luminance(_ ink: HexInk) -> Double {
        func channel(_ value: Double) -> Double {
            value <= 0.040_45 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(ink.red) + 0.7152 * channel(ink.green) + 0.0722 * channel(ink.blue)
    }

    private func ratio(_ a: HexInk, _ b: HexInk) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private func mix(_ a: HexInk, _ b: HexInk, _ t: Double) -> HexInk {
        HexInk(
            red: a.red + (b.red - a.red) * t,
            green: a.green + (b.green - a.green) * t,
            blue: a.blue + (b.blue - a.blue) * t,
            alpha: a.alpha + (b.alpha - a.alpha) * t
        )
    }

    /// Worst contrast anywhere along a gradient, with the foreground allowed to
    /// depend on the background beneath it (a translucent foreground does).
    private func worstAlongGradient(
        from top: HexInk,
        to bottom: HexInk,
        overlay: HexInk? = nil,
        foreground: (HexInk) -> HexInk
    ) -> Double {
        stride(from: 0.0, through: 1.0, by: 0.01).reduce(Double.infinity) { worst, t in
            var background = mix(top, bottom, t)
            if let overlay {
                background = overlay.composited(over: background)
            }
            return Swift.min(worst, ratio(foreground(background), background))
        }
    }

    private let aaText = 4.5
    private let aaLarge = 3.0

    /// Where WCAG's "large text" begins for **bold** text, in iOS points.
    ///
    /// The spec says 14pt bold, in CSS points, which is 18.66 CSS pixels; an
    /// iOS point is one CSS pixel. Getting this wrong in the lenient direction
    /// is how a 17pt semibold heading gets waved through at 3:1, so it is
    /// written down once here rather than recalculated per call site.
    private static let wcagLargeBoldPoints: CGFloat = 18.66

    private func assertAtLeast(
        _ measured: Double,
        _ required: Double,
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThanOrEqual(
            measured, required,
            String(format: "%@ measures %.2f:1, needs %.1f:1", what, measured, required),
            file: file, line: line
        )
    }

    private var surfaces: [(String, HexInk)] {
        [
            ("surface0", HexTokens.Palette.surface0.standard),
            ("surface1", HexTokens.Palette.surface1.standard),
            ("surface2", HexTokens.Palette.surface2.standard),
        ]
    }

    private let tiers = [("standard", false), ("Increase Contrast", true)]

    // MARK: - The primary call to action

    func test_primaryCTA_carriesWhiteTextAtAA_atBothStopsAndBothTiers() {
        for (tier, increased) in tiers {
            let top = HexTokens.Palette.ctaTop.ink(increasedContrast: increased)
            let bottom = HexTokens.Palette.ctaBottom.ink(increasedContrast: increased)
            let worst = worstAlongGradient(from: top, to: bottom) { _ in HexInk(0xFFFFFF) }
            assertAtLeast(worst, aaText, "primary CTA fill vs white label (\(tier))")
        }
    }

    /// Flat fill is not enough on its own: `#00509E` against `surface0` is about
    /// 2.4:1, so without a visible edge the button would be *harder* to find in
    /// the tier that asked for more contrast. `contrastEdge` is what pays for it.
    func test_primaryCTA_underIncreasedContrast_isFlatAndStillSeparableFromTheSurface() {
        let top = HexTokens.Palette.ctaTop.increased
        let bottom = HexTokens.Palette.ctaBottom.increased
        XCTAssertEqual(top, bottom, "the CTA should render as a flat fill under Increase Contrast")

        let edge = HexTokens.Stroke.Palette.contrastEdge
        XCTAssertEqual(edge.standard.alpha, 0, "the contrast edge must draw nothing in the standard tier")
        assertAtLeast(ratio(edge.increased, top), aaLarge, "contrast edge vs the flat CTA fill")
        for (name, surface) in surfaces {
            assertAtLeast(ratio(edge.increased, surface), aaLarge, "contrast edge vs \(name)")
        }
    }

    func test_destructiveButtonFill_carriesWhiteTextAtAA_inBothTiers() {
        for (tier, increased) in tiers {
            let fill = HexTokens.Palette.dangerFill.ink(increasedContrast: increased)
            assertAtLeast(ratio(HexInk(0xFFFFFF), fill), aaText, "dangerFill vs white label (\(tier))")
        }
    }

    // MARK: - Foreground tones on the three surfaces

    func test_everyForegroundTone_clearsAAOnEverySurface_inBothTiers() {
        let tones: [(String, HexTone)] = [
            ("textPrimary", HexTokens.Palette.textPrimary),
            ("textSecondary", HexTokens.Palette.textSecondary),
            ("dangerText", HexTokens.Palette.dangerText),
            ("success", HexTokens.Palette.success),
            ("warning", HexTokens.Palette.warning),
            ("primaryLight", HexTokens.Palette.primaryLight),
        ]
        for (tier, increased) in tiers {
            for (name, tone) in tones {
                let ink = tone.ink(increasedContrast: increased)
                for (surfaceName, surface) in surfaces {
                    assertAtLeast(ratio(ink, surface), aaText, "\(name) on \(surfaceName) (\(tier))")
                }
            }
        }
    }

    /// A `HexBadge` prints its tone over a wash of that same tone, so both sides
    /// of the ratio move together and the wash opacity is load-bearing. At 0.18
    /// danger could not clear AA at any legible red.
    func test_everyBadgeTone_clearsAAOnItsOwnWash_inBothTiers() {
        // Label and wash are not always the same token: the primary badge
        // prints `primaryLight` over a wash of `primary`.
        let tones: [(String, HexTone, HexTone)] = [
            ("primary", HexTokens.Palette.primaryLight, HexTokens.Palette.primary),
            ("success", HexTokens.Palette.success, HexTokens.Palette.success),
            ("warning", HexTokens.Palette.warning, HexTokens.Palette.warning),
            ("danger", HexTokens.Palette.dangerText, HexTokens.Palette.dangerText),
        ]
        for (tier, increased) in tiers {
            for (name, labelTone, washTone) in tones {
                let ink = labelTone.ink(increasedContrast: increased)
                let washInk = washTone.ink(increasedContrast: increased)
                let wash = HexInk(
                    red: washInk.red, green: washInk.green, blue: washInk.blue,
                    alpha: HexBadge.washOpacity
                )
                for (surfaceName, surface) in surfaces {
                    assertAtLeast(
                        ratio(ink, wash.composited(over: surface)), aaText,
                        "\(name) badge on its own wash over \(surfaceName) (\(tier))"
                    )
                }
            }
        }
        assertAtLeast(
            ratio(
                HexTokens.Palette.textSecondary.standard,
                HexTokens.Palette.surface2.standard
            ),
            aaText, "neutral badge label on its surface2 capsule"
        )
    }

    /// Increase Contrast may only ever help. A sibling that measured worse than
    /// the colour it replaces would be a regression the eye would not catch,
    /// because the whole tier is invisible unless you go and switch it on.
    func test_increasedContrast_neverLowersAContrastRatio() {
        let tones: [(String, HexTone)] = [
            ("primary", HexTokens.Palette.primary),
            ("primaryLight", HexTokens.Palette.primaryLight),
            ("textSecondary", HexTokens.Palette.textSecondary),
            ("danger", HexTokens.Palette.danger),
            ("dangerText", HexTokens.Palette.dangerText),
            ("success", HexTokens.Palette.success),
            ("warning", HexTokens.Palette.warning),
            ("cardInner", HexTokens.Stroke.Palette.cardInner),
        ]
        for (name, tone) in tones where tone.standard != tone.increased {
            for (surfaceName, surface) in surfaces {
                // Composite first. `cardInner` is white at 4%, and measuring
                // that uncomposited compares pure white against the surface
                // (19:1) with an opaque sibling (5:1), which reads as a
                // catastrophic regression where the rendered result is the
                // opposite.
                let before = ratio(tone.standard.composited(over: surface), surface)
                let after = ratio(tone.increased.composited(over: surface), surface)
                XCTAssertGreaterThanOrEqual(
                    after, before,
                    String(
                        format: "%@ on %@ drops from %.2f:1 to %.2f:1 under Increase Contrast",
                        name, surfaceName, before, after
                    )
                )
            }
        }
    }

    // MARK: - The two hero surfaces

    /// `TransitCardHero`: `.topLeading` to `.bottomTrailing` behind four text
    /// elements, with `waveTexture` printed over the whole thing.
    func test_transitCard_clearsAAEverywhereAlongItsGradient() {
        let top = HexTokens.Transit.Palette.cardTop.standard
        let bottom = HexTokens.Transit.Palette.cardBottom.standard
        let texture = HexTokens.Transit.Palette.cardTexture.standard
        let cardText = HexTokens.Transit.Palette.cardText.standard
        let dim = HexTokens.Transit.Palette.cardTextDim.standard

        assertAtLeast(
            worstAlongGradient(from: top, to: bottom, overlay: texture) { _ in cardText },
            aaText, "transit cardText (17pt semibold header)"
        )
        assertAtLeast(
            worstAlongGradient(from: top, to: bottom, overlay: texture) { dim.composited(over: $0) },
            aaText, "transit cardTextDim (13pt Balance label and IDm)"
        )
    }

    /// The wave bands must not lighten the card. They are printed across the
    /// column the two smallest labels sit in, so white bands were quietly
    /// costing every ratio above about 0.3 while looking like pure decoration.
    func test_transitWaveTexture_darkensTheCardRatherThanLighteningIt() {
        let texture = HexTokens.Transit.Palette.cardTexture.standard
        let top = HexTokens.Transit.Palette.cardTop.standard
        XCTAssertLessThanOrEqual(
            luminance(texture.composited(over: top)), luminance(top),
            "the wave texture lightens the card, which lowers contrast for every label crossing it"
        )
    }

    /// `PassportBookletHero`: dark ink on a light page, so the worst case is the
    /// darkest paper. The badge prints its tint over a 14% wash of itself.
    func test_passportPage_clearsAAEverywhereAlongItsGradient() {
        let top = HexTokens.Passport.Palette.pageTop.standard
        let bottom = HexTokens.Passport.Palette.pageBottom.standard

        assertAtLeast(
            worstAlongGradient(from: top, to: bottom) { _ in HexTokens.Passport.Palette.ink.standard },
            aaText, "passport ink on the page (field values, issuing state)"
        )
        assertAtLeast(
            worstAlongGradient(from: top, to: bottom) { _ in HexTokens.Passport.Palette.inkDim.standard },
            aaText, "passport inkDim on the page (field labels)"
        )
        let gold = HexTokens.Passport.Palette.gold.standard
        assertAtLeast(
            worstAlongGradient(from: top, to: bottom) { _ in gold },
            aaLarge, "passport gold crest stroke (graphic)"
        )

        // The issuing-state code is gold *because* it is large. Derive the
        // threshold from the size that ships rather than asserting a constant,
        // so shrinking the text below WCAG's 18.66pt bold boundary fails here
        // instead of quietly moving the requirement to 4.5:1, which no gold
        // that still reads as foil can meet.
        let issuingStateIsLargeText = PassportBookletHero.issuingStateFontSize >= Self.wcagLargeBoldPoints
        assertAtLeast(
            worstAlongGradient(from: top, to: bottom) { _ in gold },
            issuingStateIsLargeText ? aaLarge : aaText,
            """
            passport gold issuing state at \(PassportBookletHero.issuingStateFontSize)pt bold, \
            which WCAG counts as \(issuingStateIsLargeText ? "large" : "normal") text
            """
        )

        // The three integrity-badge tints. Neutral is plain `ink`, not
        // `inkDim`: inkDim reaches only 3.85:1 against its own wash, and a
        // badge carrying no verdict reading as the same navy as the page's
        // other text is the right signal anyway.
        for (name, tone) in [
            ("inkGood", HexTokens.Passport.Palette.inkGood),
            ("inkBad", HexTokens.Passport.Palette.inkBad),
            ("ink (neutral)", HexTokens.Passport.Palette.ink),
        ] {
            let tint = tone.standard
            let wash = HexInk(
                red: tint.red, green: tint.green, blue: tint.blue,
                alpha: PassportBookletHero.badgeWashOpacity
            )
            assertAtLeast(
                worstAlongGradient(from: top, to: bottom) { _ in tint },
                aaText, "passport \(name) badge tint on the page"
            )
            assertAtLeast(
                stride(from: 0.0, through: 1.0, by: 0.01).reduce(Double.infinity) { worst, t in
                    let paper = mix(top, bottom, t)
                    return Swift.min(worst, ratio(tint, wash.composited(over: paper)))
                },
                aaText, "passport \(name) badge tint on its own wash"
            )
        }
    }

    /// The photo well is `ink` at 8% over the page, and the placeholder glyph is
    /// `inkDim` over that. It is a graphic, so 3:1.
    func test_passportPhotoPlaceholder_clearsTheGraphicThreshold() {
        let top = HexTokens.Passport.Palette.pageTop.standard
        let bottom = HexTokens.Passport.Palette.pageBottom.standard
        let ink = HexTokens.Passport.Palette.ink.standard
        let well = HexInk(red: ink.red, green: ink.green, blue: ink.blue, alpha: 0.08)
        let dim = HexTokens.Passport.Palette.inkDim.standard
        let glyph = HexInk(
            red: dim.red, green: dim.green, blue: dim.blue,
            alpha: PassportBookletHero.photoPlaceholderOpacity
        )
        let worst = stride(from: 0.0, through: 1.0, by: 0.01).reduce(Double.infinity) { worst, t in
            let background = well.composited(over: mix(top, bottom, t))
            return Swift.min(worst, ratio(glyph.composited(over: background), background))
        }
        assertAtLeast(worst, aaLarge, "passport photo placeholder glyph")
    }
}
