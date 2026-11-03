<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/hexpro-dev/.github/main/profile/assets/banner-dark.png">
  <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/hexpro-dev/.github/main/profile/assets/banner-light.png">
  <img alt="Hex Pro: Software for People" src="https://raw.githubusercontent.com/hexpro-dev/.github/main/profile/assets/banner-light.png" width="100%">
</picture>

<p align="center">
  <a href="https://hex.pro"><img alt="hex.pro" src="https://img.shields.io/badge/hex.pro-the%20company-0B76D9?style=flat-square&labelColor=1b2530"></a>
  <a href="https://apps.hex.pro"><img alt="apps.hex.pro" src="https://img.shields.io/badge/apps.hex.pro-apps%20%26%20tools-0B76D9?style=flat-square&labelColor=1b2530"></a>
  <a href="https://citadel.hex.pro"><img alt="citadel.hex.pro" src="https://img.shields.io/badge/citadel.hex.pro-file%20sync-0B76D9?style=flat-square&labelColor=1b2530"></a>
  <a href="https://games.hex.pro"><img alt="Hex Games" src="https://img.shields.io/badge/Hex%20Games-the%20game%20studio-9F9F9F?style=flat-square&logo=github&logoColor=white&labelColor=1b2530"></a>
  <img alt="Australian owned and operated" src="https://img.shields.io/badge/Australian-owned%20%26%20operated-9F9F9F?style=flat-square&labelColor=1b2530">
</p>

# Hex NFC: Free NFC Reader and Tag Editor for iPhone

Read, write, and password-protect NFC tags on iOS. Every NDEF record type,
every common chip family, the advanced commands and the memory tools, all
free, all source-available, no third-party ads, no tracking, no accounts.

[![App Store](https://img.shields.io/badge/App_Store-Download-0b76d9?style=flat-square&logo=apple)](https://apps.apple.com/app/id6801457461)
[![License: BSL 1.1](https://img.shields.io/badge/license-BSL_1.1-5ba3f5?style=flat-square)](LICENSE)
[![iOS 17+](https://img.shields.io/badge/iOS-17.0%2B-9b958c?style=flat-square)](https://apps.hex.pro/hex-nfc)

Hex NFC is on the [App Store](https://apps.apple.com/app/id6801457461) for iPhones running iOS 17 or later.

## Features

| Feature | What it does |
|---|---|
| Reader | Detects the chip family, surfaces all NDEF records and parses their payloads into something readable |
| 13 record types to build | Text, URI, 22 social platforms, Search, File, Mail, vCard, Phone, SMS, FaceTime, Map, Crypto and Wi-Fi. App link, Bluetooth, Data, Shortcut and Raw records are read, edited and written back too |
| Tag protection | Password or key protection on NTAG21x, MIFARE Ultralight EV1 and C, NTAG424 DNA and ICODE SLIX2, and a permanent lock behind a typed-UID confirmation |
| Memory tools | Read and write per page, dump to `.bin`, format the Capability Container for the chip family |
| APDU console | Raw command REPL with a curated preset library for NTAG21x, NTAG424 DNA, ISO 15693, MIFARE Ultralight EV1 and EM Microelectronic |
| Presets and history | Save tag images, share them as `.hexnfc` JSON, keep a history of recent scans and pin the ones you want to keep |
| Transit cards and passports | Read a Japanese transit card's balance and recent journeys, or the chip in an electronic passport, read-only. A passport's details can be typed or read from its photo page with the camera |
| QR import | Scan a QR code and add it as a record |
| 7 languages | English, 中文, العربية, Español, 日本語, Français, Português (Brasil) |

## Supported chips

- Type 2: NTAG 210µ, NTAG213, NTAG215, NTAG216, NTAG213 TT, MIFARE
  Ultralight EV1 and MIFARE Ultralight C. Read, write, format, permanent lock
  and memory dump; password or 3DES key protection on every one except the
  NTAG 210µ, which has nowhere to store a password.
- Type 4: NTAG424 DNA, with read, write and AES key protection. A blank
  MIFARE DESFire EV1, EV2 or EV3 card can be set up as an NDEF tag with Format,
  after which it reads and writes like any other tag, and Remove NDEF setup
  returns a card the app set up to blank. Cards that already hold other
  applications, such as transit and access cards, are refused. Raw DESFire
  commands stay available in the Advanced console. Type 4 tags from other
  makers, and an Android phone emulating a tag, read and write through iOS's
  own NDEF support.
- Type 5 (ISO 15693): ICODE SLIX and SLIX2, with read, write, format and
  permanent lock, plus a write password on the SLIX2.
- FeliCa: Suica, PASMO and the rest of that transit family, read-only.
- NFC health devices, such as some insulin pens, are recognised and named. The
  app does not read their measurements, never writes to them and saves nothing
  from them; it points to apps that do read them.

Support is not the same as testing on real silicon. The
[chip support matrix](docs/site/content/en/developer/chip-support-matrix.md)
says, chip by chip and operation by operation, what has been confirmed on a real
tag and what has only run against a simulator.

## Why source-available

Hex NFC is built by **[Hex Pro](https://hex.pro)** as a brand showcase. There's
nothing to buy in it: no in-app purchases, no subscriptions. No accounts, no
tracking, no analytics SDK. The home screen does carry a banner for another Hex
Pro app. It's first party, so there's no third-party ad network, no tracking
identifier and no personalisation behind it. See [`PRIVACY.md`](PRIVACY.md) for
what the app sends over the network, and where the banner comes from.

The full source is public, so you can audit every line and build it yourself.
The Business Source License 1.1 reserves commercial and competing
redistribution to Hex Pro. It converts to the Apache License 2.0 on the Change
Date of 2030-06-01, or four years after a given version is first published,
whichever comes first; see [`LICENSE`](LICENSE). The Hex Pro wordmark and the
hexagon-split logo are trademarks; see [`NOTICE`](NOTICE) for the details.

## Install

**End users:** [Download on the App Store](https://apps.apple.com/app/id6801457461).

**Developers:**

```bash
git clone https://github.com/hexpro-dev/hex-nfc-ios
cd hex-nfc-ios/app
swift build
swift test
open HexNFC.xcodeproj
```

iOS 17+ deployment target. The Xcode project carries the CoreNFC
entitlements required to talk to a real tag; the SPM package builds standalone
for fast test iteration.

## Help

The [user guide](https://apps.hex.pro/hex-nfc/docs) walks through each task in
the app, and [If a tag does not scan or write](https://apps.hex.pro/hex-nfc/docs/guide/troubleshooting)
goes through each message it shows. In the app, **Settings > Send Feedback**
sends a message straight to Hex Pro. The
[help page](https://apps.hex.pro/hex-nfc/support) lists every other way to
reach us, including `support@hex.pro`. Bug reports and chip requests are
welcome as [issues](https://github.com/hexpro-dev/hex-nfc-ios/issues);
[`CONTRIBUTING.md`](CONTRIBUTING.md) says what to include.

## Architecture

```
HexNFCApp ─┬─> HexNFCDesign  ──> HexNFCShaders
           ├─> HexNFCStorage ──> HexNFCRecords
           ├─> HexNFCKit     ──> HexNFCRecords
           ├─> HexPromoKit   (vendored, see its PROVENANCE.md)
           └─> HexNFCTestKit ──> HexNFCKit, HexNFCRecords
HexNFCTagSim ──> HexNFCKit  (test-only)
```

`HexNFCKit` is the load-bearing NFC abstraction; production wires
`CoreNFCSession`, tests wire `SimulatedSession` driven by chip simulators in
`Tests/HexNFCTagSim/`. See
[`docs/site/content/en/developer/architecture.md`](docs/site/content/en/developer/architecture.md)
for the full breakdown.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). Bug reports, chip support patches,
translations, and documentation improvements are all welcome.

This repository is a public mirror; the canonical history is maintained
upstream by Hex Pro. Your PR may be merged here and *also* appear in a
later "Sync vX.Y.Z" commit, and that is expected.

## Security

Report security issues privately to `security@hex.pro`. See
[`SECURITY.md`](SECURITY.md).

## License

[Business Source License 1.1](LICENSE). Converts to the Apache License 2.0 on the Change Date.
