# Changelog

All notable changes to Hex NFC are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0] - 2026-10-16

First release on the App Store.

### Accessibility
- The app now supports VoiceOver, Reduce Motion and the Increase Contrast
  setting, and meets WCAG 2.2 AA contrast throughout.
- Every text field is announced by its name. The shared field components
  had no accessibility label at all, so VoiceOver read out the placeholder
  instead. The placeholders are sample values (`en`, `+15551234`, `without the
  @`), which meant the record editor announced example data as if it were the
  question. Hex fields for passwords, PACK values and AES keys now also spell
  the value out character by character and say whether it is valid, which was
  previously signalled by border colour alone.
- The permanent-lock confirmation reads its warning first. Focus went
  straight to the keyboard, so the one screen in the app that irreversibly
  bricks a tag was also the one whose warning a VoiceOver user could skip past
  without hearing.
- The scan mark holds still under Reduce Motion. Its slow pulse is the
  app's most-seen animation and it ignored the setting entirely. The console's
  auto-scroll jumps instead of gliding for the same reason.
- Contrast: the primary button, the transit card, the passport data page
  and the danger badge did not meet AA. Every colour moved in lightness only,
  holding hue and chroma, so the design reads as itself: the transit card is a
  deeper printing of the same green rather than a different one. The card's
  wave bands flipped from white to black, which costs nothing visually and
  lifts every label that crosses them.
- Increase Contrast deepens fills, lifts secondary text and gives filled
  buttons and cards a real edge. With the setting off, nothing changed.

### Added
- MIFARE Ultralight C support, including 3DES authentication. The chip is
  identified, read, written, formatted, protected and unprotected end to end.
  Its protection is a 16-byte 2-key 3DES key with a mutual handshake rather than
  a 4-byte password, so it gets its own protection model throughout rather than
  being bent into the NTAG21x one: the key can be generated, pasted, or derived
  from a passphrase, and is stored only in the device Keychain. Identification
  works despite the chip having no `GET_VERSION` command at all. It is
  recognised from its memory shape on a second polling pass, which is why these
  tags previously scanned as "unidentified".
- ICODE SLIX2 is now named as itself rather than reported as an ICODE SLIX.
  It is distinguished by block geometry (80 blocks against the SLIX's 28); the
  IC-reference byte reads `0x01` on both and turned out not to be a
  discriminator at all.
- NTAG 210µ support. The smallest NTAG21x die (48 bytes of user memory in
  16 pages) is now identified, read, written, formatted and locked, with a
  protocol-level simulator and full live-harness coverage. It is deliberately
  the family's minimum case: no password support (the micro die has no
  configuration pages), no `FAST_READ`, no counter. The Advanced console and
  Operations screens hide what the chip cannot do rather than offering it and
  failing.
- Unrecognised chips now explain themselves. When a tag can't be matched to
  a known profile, the scan card shows what its `GET_VERSION` block decoded to:
  vendor, product family, memory size and version, plus the raw bytes for a bug
  report, instead of only a UID. Nothing is inferred about the chip's memory map;
  the app still refuses to guess a page layout it can't verify.

### Fixed
- **Format could write the wrong Capability Container to an unrecognised tag.**
  The format operation fell back to the smallest CC when it didn't know the
  chip, on the reasoning that guessing low is conservative. It isn't: the CC page
  is one-time-programmable, so the write ORs bits into whatever is already there
  and can never clear them, permanently mis-declaring the tag's NDEF area.
  Formatting an unidentified tag is now refused outright.
- **Four chips were being reported as the wrong chip.** Identification compared
  only two bytes of the version block, ignoring the product-type and version
  bytes: NTAG210 and NTAG212 were reported as MIFARE Ultralight EV1, and
  NTAG213F and NTAG216F as an NTAG424 DNA, a different tag family with a
  different command set. All four are now either identified correctly or
  honestly reported as unrecognised.
- **Permanent lock is no longer tied to password support.** A chip with lock
  bytes but no password pages (such as NTAG 210µ) advertised the lock operation
  but refused it when asked.
- Tag protection is now **capability-driven across chip families**: the editor's
  Protection card and the per-family config appear for any chip that supports
  protection, not just Type-2.
  - **NTAG424 DNA (Type-4):** gate the NDEF file behind a 16-byte AES-128 key
    via the EV2 secure-messaging handshake (`AuthenticateEV2First` →
    `ChangeFileSettings` → `ChangeKey`), with an optional "also require key to
    read". The editor offers a key field + "Generate random key" and a
    loud soft-brick warning (an NTAG424 has no factory reset for a changed key).
  - **ICODE SLIX2 (Type-5):** set a 4-byte write password via the SLIX
    `GET_RANDOM`/`SET_PASSWORD` challenge. Any ICODE SLIX gets a real permanent
    lock via per-block `LOCK_BLOCK`. Uses standard SLIX commands, so a tag
    protected by Hex stays unlockable by other SLIX tools.
  - Type-2 behaviour and on-disk/`.hexnfc` format are unchanged (a Type-2 export
    stays byte-identical); the secret (PWD/PACK, AES key or SLIX password) lives
    only in the device Keychain and is masked in the diagnostic trace.
  - **Family-aware unlock:** writing to (or re-scanning) an already-protected tag
    now asks for the right credential, a 4-byte password for Type-2/SLIX or the
    **16-byte AES key for an NTAG424**, and routes it to the matching backend,
    rather than always assuming a Type-2 password.
  - **Re-writing a protected NTAG424** now works end-to-end: the EV2 secure
    session established to unlock the tag carries through to the NDEF write/read
    (secure-messaging WriteData/ReadData), so an authenticated rewrite no longer
    silently fails.
  - **Protection-only presets:** a preset can now carry protection with no records
    (e.g. to lock a stack of blank tags). "Save as preset" and the editor's Write
    button activate on a protection change alone, not only on a record edit.
- Tag password protection for Type-2 chips (NTAG213/215/216, NTAG213 TT,
  MIFARE Ultralight EV1 48b/128b). "Protect with password" sets the password
  **and** turns protection on (AUTH0 + ACCESS), so writes, and optionally
  reads, require the password; a "Remove password" flow clears it. Configure
  it once in the editor (Simple, plus an Advanced disclosure for start page,
  read-protection, and attempt limit), save it with a preset, and apply it to
  many tags on write. The password is stored only in the device Keychain; it
  never syncs to iCloud or travels in a `.hexnfc` export (settings do).
- Scanning now reads a tag's live protection state, so a tag locked elsewhere
  shows as protected in the editor (and history) instead of "Off". A
  read-protected tag prompts for its password on scan and a write to an
  already-protected tag prompts before writing. Either way you enter the tag
  password once and tap again to unlock the operation.
- Writing an NDEF message to a **factory-preformatted NTAG21x** tag (NTAG213/215/216)
  no longer fails with a "connection closed" error. Type-2 writes now go through
  the tag's page interface directly instead of the higher-level path that some
  preformatted tags reject.
- Scanning an **NTAG424 DNA** or **DESFire** tag no longer aborts the command that
  follows identification: the multi-frame product-version reply is now fully read,
  so re-scanning or authenticating right afterwards works instead of failing with
  a command-aborted error.
- Writing NDEF to an **NTAG424 DNA** no longer fails with a "no NDEF range" error;
  Type-4 tags now take the correct high-level NDEF path instead of the Type-2 page
  writer they don't support.
- Back-to-back NFC sessions are more reliable: closing a session now waits for the
  reader to fully tear down before the next one opens, so a follow-up scan or write
  no longer races the teardown and drops the tag.
- Erasing an already-blank or unformatted tag no longer errors; an empty write to a
  tag with no NDEF container is treated as a successful no-op.
- Formatting a tag's Capability Container now refuses chip families that don't
  support it with a clear message, instead of a confusing low-level error.

### Changed
- The Hex Pro banner on the Home screen is now drawn by the app itself rather
  than by the promo SDK. Its VoiceOver label comes from the app's string
  catalogue, so it is spoken in the same languages as the rest of the app
  instead of English only. The SDK is vendored in this repository now, so the
  build no longer depends on a second repository being checked out beside it.
- License changed from the Apache License 2.0 to the Business Source License 1.1
  (BSL 1.1). The full source stays public and auditable; production use is
  limited to personal, non-commercial use, with commercial and competing
  redistribution reserved to Hex Pro. It automatically converts to the Apache
  License 2.0 on the Change Date (2030-06-01).


[Unreleased]: https://github.com/hexpro-dev/hex-nfc-ios/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/hexpro-dev/hex-nfc-ios/releases/tag/v1.0.0
