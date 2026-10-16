# Contributing to Hex NFC

Thanks for your interest in contributing. Hex NFC is source-available under
the Business Source License 1.1 and welcomes patches, bug reports, and
chip-support contributions.

## How this project is maintained

The upstream maintainer (Hex Pro) controls App Store releases. The repository
you see on GitHub is a public mirror; the canonical history lives privately.
Community pull requests land here on `main` and are cherry-picked into the
canonical repo on the next release cycle, with author attribution preserved
via commit trailers.

This means:

- Your PR may be merged on GitHub and *also* appear in a later "Sync vX.Y.Z"
  commit. That's expected.
- The App Store binary is built from the canonical repo. We cannot accept
  binary-only contributions; everything must be reproducible from source.
- Forks are welcome under the Business Source License 1.1 (non-production use;
  it converts to Apache 2.0 on the Change Date). The "Hex NFC" App Store identity and
  the hexagon-split logo are trademarks (see `NOTICE`) and cannot be reused
  in derivative apps without permission.

## What we want

- **Bug reports.** Especially edge cases on specific chip families. Include
  the chip ID, iOS version, iPhone model, exact steps, and the diagnostic
  payload from the in-app error sheet (long-press an error to copy it).
- **Chip support.** New tag types with attached datasheets. Add a simulator
  in `app/Tests/HexNFCTagSim/` first. We don't accept hardware-only patches.
- **Translations.** All user-facing strings live in `Localizable.xcstrings`.
- **Station data.** Help name transit (Suica-family) stops straight from the app,
  see [Station data](#station-data) below.
- **Documentation.** The chip support matrix in
  `docs/site/content/en/developer/chip-support-matrix.md` is community-maintained.

## What we don't want

- Analytics, telemetry, or any network-call additions that aren't user-initiated.
  This is non-negotiable; "no tracking" is a load-bearing brand promise.
- Third-party Swift package dependencies. Apple frameworks only, with the single
  test-only exception of `pointfreeco/swift-snapshot-testing`.
- AI-generated PR descriptions that don't match the actual diff. We read them.

## Station data

Transit cards store only numeric **saibane codes** (line + station); the bundled
pack maps the ones we know to station names. The best way to help is **from the
app**: when a scanned transit card shows a stop we can't name, type its name in
the inline field and submit. Because the stop is on your card, you've been there
so your suggestion is a first-party observation. It goes to the maintainer's
review queue (only the codes + the name are sent, never your card's ID, balance,
or history) and, once reviewed, ships in a later release.

If you'd rather not use the app, you can open a normal issue with the codes and
the station name.

Note for contributors: please don't copy station names from a denno.net /
"IC SFCard Fan"-lineage CSV or a GPL project (Metrodroid / FareBot). A name you
read off a station sign or recall from being there is exactly what we want.

## Development setup

```bash
cd app
swift build
swift test
open HexNFC.xcodeproj
```

Lint and format before submitting:

```bash
swiftlint
swiftformat .
```

## Commit messages

Use one of these prefixes:

- `nfc:` anything in `HexNFCKit`, chip support, raw commands
- `ui:` `HexNFCApp` views, screens, navigation
- `chip:` chip simulators in `HexNFCTagSim`
- `web:` landing page or catalog changes
- `meta:` repo plumbing, CI, docs, license

Keep messages in imperative voice and under 72 chars on the subject line.

## Reporting security issues

Do **not** open a public issue for security reports. See `SECURITY.md`.

## Code of Conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md) v2.1.
