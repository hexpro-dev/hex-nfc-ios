---
title: Architecture
description: How the Hex NFC Swift package divides into targets, and the conventions every target follows.
audience: developer
tags:
  - architecture
---

A high-level tour of how Hex NFC, a SwiftUI app for iPhone on iOS 17 and later,
is organised. For day-to-day detail, read the source.

## Module graph

```text
HexNFCApp ─┬─> HexNFCDesign  ──> HexNFCShaders
           ├─> HexNFCStorage ──> HexNFCRecords
           ├─> HexNFCKit     ──> HexNFCRecords
           ├─> HexPromoKit   (vendored, product-less)
           └─> HexNFCTestKit ──> HexNFCKit, HexNFCRecords
HexNFCTagSim ──> HexNFCKit  (test-only)
```

### `HexNFCRecords`

Value types and their codecs. The `NDEFRecord` enum has 18 cases covering
every record type the app can read or write: Text, URI, App link, Social (22
platforms), Search, File, Mail, vCard, Phone, SMS, FaceTime, Map, Crypto,
Bluetooth handover, Wi-Fi WPS, Data (a MIME type and raw payload), Shortcut
and Raw. The target also holds the models and decoders for passport data
groups and Suica transit history, and `StationDirectory`, which loads the
bundled station and line data that `TransitReader` uses to name stations.

`NDEFCodec` round-trips between `[NDEFRecord]`, the wire-level
`[NDEFPayload]` and raw message bytes; only `HexNFCKit` bridges `NDEFPayload`
to CoreNFC. The URI prefix table (the 36 NDEF URI identifier codes, `0x00` to
`0x23`, where `0x00` means no prefix) lives here along with a
longest-prefix-match reverse lookup.

### `HexNFCKit`

The NFC abstraction. `TagSession` is the protocol that production code wires
to `CoreNFCSession` (wrapping `NFCTagReaderSession`) and unit tests wire to
`SimulatedSession`. The UI tests launch the app with `--useSimulatedNFC`,
which swaps in `MockTagSession`, a stand-in in `HexNFCKit` that returns canned
records and has no chip model. The launch-argument check is not behind
`#if DEBUG`, so the mock is compiled into release builds too. `ConnectedTag`
exposes the chip's capabilities as a `TagCapability` option set. On a live
tap, a tag the session could not identify gets NDEF read, NDEF write and raw
transceive. `permanentLock()` and the Type 2 password commands are written
once, in a `ConnectedTag` extension, and throw
`TagError.capabilityUnsupported` before sending a frame when the chip lacks
the capability. The production tag, `CoreNFCConnectedTag`, gates memory reads
and writes the same way. Raw `transceive` is not gated.

`TagIdentifier` picks a probe for each CoreNFC tag type, and `ChipCatalog`
decodes what the probe reads into a `ChipProfile` with the chip's family,
capabilities and memory layout. NTAG213, NTAG215, NTAG216, NTAG213 TT,
NTAG 210µ and MIFARE Ultralight EV1 are identified from `GET_VERSION`.
NTAG210, NTAG212, NTAG213F and NTAG216F answer `GET_VERSION` too, but the
decoder deliberately leaves them unidentified, because their memory maps have
not been checked against real chips. NTAG424 DNA is identified from the
wrapped `GET_VERSION` APDU. That decoder checks only the vendor and
hardware-type bytes, so any NXP chip reporting the NTAG 4xx hardware type is
identified as an NTAG424 DNA and given that chip's profile. DESFire is
identified from its native `GET_VERSION` frame.
MIFARE Ultralight C refuses `GET_VERSION`, which halts the tag, so the session
restarts polling and recognises the chip from a read of pages 0 and 28h.
ISO 15693 tags resolve from the IC manufacturer code plus Get System
Information: NXP silicon becomes ICODE SLIX, or SLIX2 when it reports 80
blocks, and any other manufacturer gets a generic ISO 15693 profile.
Passports are recognised by selecting the eMRTD application. FeliCa cards
get a generic profile, with transit reading added on system code `0003`.
`ChipCatalog` also has profiles and a decoder (`identify(emSignature:)`) for
EM Microelectronic V10, V11 and V16, but nothing in the production session
calls that decoder, so the app does not identify an EM chip on a live tap.
The page 0 bytes it matches (`E0 10`, `E0 11` and `E0 16`) are values the EM
simulators define for themselves, not values read from EM silicon.

The Advanced console's built-in commands live in `CommandPresetCatalog`, each
tagged with the family it is written for. There are presets for Type 2 chips
(the EM chips among them), NTAG424 DNA and ICODE SLIX, and none for DESFire,
FeliCa or passports. The EM presets are untested on silicon: the V10
crypto-mode command and the tamper-status reads use the values the simulators
define, and each EM personalisation chain writes a Capability Container whose
size byte comes from the memory layout in `ChipCatalog` rather than a
datasheet. The console lists every preset and runs whatever is loaded without
checking the tag's family, so nothing stops an EM preset being sent to a tag
that is not an EM chip.

The target also holds the protection driver for each family that has one, the
FeliCa `TransitReader` and the read-only passport reader. `EPassportReader`
runs PACE when the document's `EF.CardAccess` advertises a configuration it
supports, and BAC otherwise. If an advertised PACE fails, the read fails; it
does not retry with BAC. When it can read the chip's security object
(`EF.SOD`), it hashes each data group it read and compares the result with the
hash list in that object, and the result screen labels the data "Likely
untampered" or "Likely tampered". If there is no readable security object, or
it lists none of the data groups read, the screen shows no integrity label at
all. The reader does not verify the security object's signature or certificate
chain, so this is not Passive Authentication: a security object rewritten to
match altered data passes the check, and nothing the app does establishes that
a passport is genuine.

### `HexNFCStorage`

SwiftData stack (`SwiftDataStack`) for three models:
- `Preset`: named tag images (a list of records and optional capability
  requirements).
- `HistoryEntry`: a scan record, written by the scan flow after each
  successful tag or transit card read and never for a passport. A repeat of an
  identical scan updates the existing row's time instead of adding one.
  Unpinned entries past the 50 most recent are trimmed after each insert, and
  unpinned entries older than 90 days are deleted at launch.
- `SavedCommandPreset`: the stored form of HexNFCKit's `CommandPreset`, meant
  for user-saved console commands. It is in the schema, but nothing in the app
  reads or writes it yet, and the Advanced console lists only the built-in
  presets.

iCloud private-database mirroring is one configuration flag behind the
Settings toggle (default off). The flag is read when the store opens at
launch, so a change takes effect the next time the app starts. If the store
cannot be opened with mirroring then, the app opens it without mirroring and
Settings says sync is not running. Protection secrets never go into SwiftData:
`KeychainProtectionCredentialStore` (keyed by preset) and
`KeychainTagCredentialStore` (keyed by tag UID) keep them in the Keychain as
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly` items, which do not sync.

### `HexNFCShaders`

Metal shaders and CoreHaptics patterns for the signature scan, write and
console moments. Shaders are `.metal` source files compiled by SPM's Metal
toolchain; haptic patterns are `.ahap` JSON. The `.hexHero(...)` SwiftUI
modifier plays the haptic pattern for a given moment. The visual half of each
of those moments is a separate modifier (`hexScanReveal`, `hexWriteBurst`,
`hexConsolePulse`) that the screen attaches on the same trigger.

### `HexNFCDesign`

Design tokens (`HexTokens`), motion presets, the signature `HexTransition`
(the hexagon logo drawn as three slices, which animate in on a staggered
spring when its `state` changes from `.hidden` to `.present`; every place the
app uses it passes `.present`, so the stagger never plays) and component
primitives: `HexCard`, `HexButton`, `HexField`, `HexBadge`,
`HexRecordRow` and `HexConsole`.

### `HexNFCApp`

The SwiftUI screens and flow models, built as a library. The Xcode app shell
(`HexNFC.xcodeproj`), which carries the entitlements and `Info.plist`, creates
the `AppModel` and shows `RootView`. Per-flow `@Observable` models
(`ScanFlowModel`, `EditFlowModel`, etc.) drive the screens. `RootView` holds
one `NavigationStack` around `HomeView` and presents each flow as a sheet. The
loop from scan to edit to write is a sheet chain (`ScanSheet`, then
`TagEditorSheet`, which presents `WriteSheet`), so the root stack is never
popped between steps. Screens include `RecordEditorSheet`, which is
polymorphic by record kind.

The target also holds two HTTP clients of its own. `CostsClient` fetches the
development-costs figure shown on the home screen when the root view appears,
with no action from the user. `StationSubmissionClient` runs only when the user
submits a name for a transit station the bundled data cannot name, and posts
that name with the station's line, station and region codes and the card's
system code. It does not send the card's IDm, balance or history.

### `HexPromoKit`

The client behind the home screen's cross-promotion banner. `PromoManager`
fetches the active promotion from Hex Pro's promo API and caches it, with its
media, on disk; `HexNFCApp` draws the banner itself. The target is copied
without local edits from Hex Pro's own promo SDK, and a provenance file beside
the sources records the pinned commit and a hash of each file. The package
declares no product for it, because `HexNFCApp` is its only consumer.

### `HexNFCTestKit`

Session-agnostic test plans and a runner that drive both live NFC hardware
and the simulators through one code path. It's a real library target that
links into the app, but every `HexNFCApp` file that imports it is compiled
only under `#if DEBUG`, where an in-app hardware harness runs the plans against
real tags. A headless XCTest (`TestKitPlanTests`) runs the same plans against
every simulator that has a chip profile. A live step that fails where its
simulator passes is how a simulator's drift from silicon shows up, so drift is
caught only when someone runs the harness on real tags. Release builds link
the target but have no screen that reaches it.

### `HexNFCTagSim` (test-only)

In-process chip simulators for NTAG 210µ, NTAG213/215/216, NTAG213 TT,
NTAG424 DNA, MIFARE Ultralight C, MIFARE Ultralight EV1 (48- and 128-byte),
MIFARE DESFire EV3, ICODE SLIX and SLIX2 (one ISO 15693 simulator at 28 or 80
blocks), EM Microelectronic V10/V11/V16, Suica, an electronic passport (eMRTD)
and an unrecognised Type 2 fallback. Each is a class conforming to
`ChipSimulator`, whose raw transceive surface is
`func handle(command: Data) -> Data`. Simulators are reference types so the
mutations a test drives (counters, attempt limits, lock bytes) are visible
to the test that built them. Test targets inject one via
`SimulatedSession(chip:)`. A simulated tag takes its chip profile from its
simulator rather than from identification, so in a test every simulator with
a profile reads as identified, the EM simulators included, although the app
does not recognise an EM chip on a live tap. The EM Microelectronic
simulators use byte values they define themselves, not datasheet values, for
the identifier in page 0, each variant's tamper-status page and the V10
crypto-mode reply, because the full command set for those chips is not
published. They also answer `GET_VERSION` with eight zero bytes, where the
published command set of the closest related EM chip has no `GET_VERSION` at
all. No EM chip has been tested on hardware, so a passing EM simulator test
is not evidence about EM silicon.

## Conventions

- All CoreNFC access is inside `HexNFCKit`. No other target imports `CoreNFC`.
- Brand colours are tokens (`HexTokens.Color.primary`), never hex literals
  outside `HexTokens.swift`.
- User-facing strings go through `Localizable.xcstrings`, and the `Info.plist`
  strings (the app name and permission prompts) through `InfoPlist.xcstrings`.
- `TagError`, the NFC layer's error type, carries both
  `userMessage: LocalizedStringResource` and `diagnostics: String` so a bug
  report can include the wire-level detail.
- The only third-party Swift package is `pointfreeco/swift-snapshot-testing`,
  and only test targets use it. `HexPromoKit` is Hex Pro's own code, vendored
  rather than fetched. The app also bundles the IBM Plex Mono font, under the
  SIL OFL 1.1.
