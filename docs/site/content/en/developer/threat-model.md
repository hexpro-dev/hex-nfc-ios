---
title: Threat model
description: What Hex NFC protects against in its handling of tag data, destructive operations and dependencies, and what it leaves out of scope.
audience: developer
tags:
  - security
draft: true
---

Hex NFC is a tool that reads, writes and modifies NFC tags. This document
enumerates what we protect against and what we don't.

## In scope

### Data confidentiality

- Scanned tags are stored in SwiftData on the device, in a store the app
  does not exclude from device backups. The app's own iCloud sync is opt-in
  and off by default. When it is on, it mirrors presets and scan history into
  the user's private iCloud database. A scan history entry holds the tag's
  UID and records, and for a transit card its IDm, balance and transactions.
- Apart from iCloud sync, the app sends data read from a tag over the
  network in one case only. When a transit card shows a station the app
  cannot name, the user can type the name and tap Submit, which sends the
  line, station and region codes, the card's system code and the typed name
  to `api.apps.hex.pro`. That request carries nothing else from the card:
  not its IDm, its balance or its transaction list.
- `PrivacyInfo.xcprivacy` declares no tracking and no collected data types,
  and the station-name suggestion above is not listed in it. The app makes
  three other network requests, and none carries anything read from a tag:
  the home screen fetches a development-costs figure from
  `api.apps.hex.pro`, asks `api.p.hex.pro` for a banner for another Hex Pro
  app, and downloads the image or video that response names. A network
  request this page does not describe is a security bug.
- Every command the app itself sends to a tag, and the tag's reply, is also
  written to the iPhone's system log (subsystem `pro.hex.nfc`, category
  `apdu`), marked `.public` so the system does not redact it. This happens in
  release builds, and no setting turns it off. Frames that carry a password or
  a key are masked, and so are a passport's BAC EXTERNAL AUTHENTICATE, its
  PACE MSE:Set AT and the last PACE GENERAL AUTHENTICATE, which carries the
  authentication tokens. The PACE GENERAL AUTHENTICATE steps before that one
  are sent with command chaining (class byte `10`), which the masking rule
  does not match, so the encrypted nonce and the data exchanged for mapping
  and key agreement are logged in full. Anyone recording the radio exchange
  receives those frames too. Everything else is logged in full. That includes
  the UID of every tag the app detects and a transit card's IDm; the
  configuration pages the app reads; the first twelve bytes of a Type 2 tag's
  data area, which each scan and write reads to check the tag is present; a
  memory dump; every record the app writes to a Type 2 tag whose chip it
  identifies; and the blocks a transit card's balance and transactions are
  read from. When an NTAG424 DNA accepts the key a write carries, as a tag
  protected for writes only with that key does, the records the write sends
  and the records it reads back to check them are also logged in full.
  If the tag's NDEF file is set for encrypted communication, which is how the
  app protects a tag for reads as well, those frames are encrypted. A
  passport's data groups reach the log only as the encrypted frames of its
  secure-messaging session. Records that iOS reads on the app's behalf are
  not logged, apart from a record count and size on a tag iOS presents as a
  MIFARE tag: every Type 2 tag, a DESFire card, and an NTAG424 DNA when iOS
  presents it that way. Anyone who can read the iPhone's log, from a
  connected Mac or in a sysdiagnose, can read these frames.
- Tag-protection secrets are stored only in the Keychain, as items with
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` that never sync or move to
  another device. They are the 4-byte PWD and 2-byte PACK of NTAG21x and
  Ultralight EV1 tags, the NTAG424 DNA AES-128 key, the MIFARE Ultralight C
  16-byte 3DES key and the ICODE SLIX2 4-byte write password.
- Two Keychain stores hold them. `KeychainProtectionCredentialStore` keeps
  the secret of a preset saved with protection on, keyed by the preset, and
  deleting the preset from this iPhone's Library deletes it.
  `KeychainTagCredentialStore` is keyed by the tag's UID. When a write from
  the editor's Protection card applies or removes protection, or a protected
  preset written from the Library applies it, the secret is saved there after
  the new records are written and before the command that changes the tag's
  protection, ahead of any credentials already recorded for that tag (up to
  four in all). A failed save does not stop the write. Deleting a preset
  leaves these records alone, and the app has no control for removing one: a
  record is deleted only when a read-back after a removal shows the tag open
  and back on its factory credential. No code yet reads a record back to
  unlock a tag. A password typed on the Operations sheet is not saved
  anywhere.
- Only the non-secret *settings* (such as which page protection starts at
  and, for NTAG21x, Ultralight EV1 and NTAG424 DNA, whether it gates writes
  only or reads and writes) are saved with a preset, synced or written into a
  `.hexnfc` export; the secret never travels with them. A protected preset
  that reaches another device, through iCloud sync or a backup restored onto
  a new iPhone, carries its settings but not its secret. Its Library row
  still shows the lock that marks it as applying protection, but writing it
  there applies none and gives no warning. The same happens on this iPhone to
  a preset saved with protection on and no secret, for example from the
  editor of a scanned protected tag whose password was never entered there.
  The Save as preset sheet still says the secret is stored only on this
  device. The app can share a preset as a `.hexnfc` file but has no way to
  import one. Two things are written to files in the app's temporary
  directory, and the app deletes neither: a shared preset's `.hexnfc` file,
  and a memory dump's `.bin` file, which is written as soon as the dump
  finishes, whether or not it is shared.
- An electronic passport is read only after the user types the document
  number, date of birth and expiry date from its machine-readable zone. The
  app does not save those details, or anything it reads from the passport,
  including the face image, to scan history or any other app storage, and
  sends none of it over the network. The result is shown for that session
  only.

### Destructive operation safety

- On the Operations sheet, six operations require the user to type the
  tag's full UID before they run: Erase, Format, Permanent lock, Attempt
  limit, Protect with password and Remove password. The last three are for
  NTAG21x and Ultralight EV1 only; protection on NTAG424 DNA, Ultralight C
  and ICODE SLIX2 is set and removed from the Protection card in the tag
  editor. It is typed confirmation, not Yes/No: the UID shown beside the
  field is the one read by the first of two taps, and a second tap that
  presents a different tag is refused.
- Outside the Operations sheet, nothing in a release build has that gate.
  Protection applied or removed from the editor's Protection card runs as
  part of the next write, and so does the protection in a preset written from
  the Library; removing it still needs the tag's current password or key. An
  ordinary write replaces the tag's content, and a write with every record
  deleted clears the tag the same way Erase does. The Advanced console sends
  the raw commands the user types or loads from its built-in list, including
  ones that permanently lock memory or rewrite configuration pages, to one tag
  per run with no confirmation.
- The attempt limit (AUTH_LIM) is opt-in, and the screen that sets it carries
  a warning. Applying password protection to an NTAG21x or Ultralight EV1
  always writes a limit of 0 (unlimited), which also clears a limit the tag
  already carried. Apart from raw commands in the Advanced console, a non-zero
  limit is set only from the Attempt limit screen, on a tag that is already
  protected. A limit of N lets the tag refuse N wrong passwords. One more
  wrong password and the tag stops accepting its password for good, the right
  one included, so its protection can never be removed and the memory it
  protects can never be rewritten, or read again if reads were gated too. That
  is the chip's own behaviour, which we surface loudly rather than hide. We
  have confirmed that count on NTAG213. The Attempt limit screen also runs on
  NTAG213 TT, NTAG215, NTAG216 and Ultralight EV1, where the count has not
  been tested; the NTAG215, NTAG216 and Ultralight EV1 datasheets state the
  same rule. The Attempt limit screen shows the limit a tag already carries
  when the tag's configuration can be read without a password, which rules out
  a read-protected tag. The app can never read how many wrong passwords a tag
  has already refused, because no command on these chips reports that.
- Permanent lock is never a preset setting, and neither is the attempt
  limit: a preset written from the Library can apply protection but can
  never permanently lock a tag or set a limit. It does put the same password
  or key on every tag it is written to, and the app never displays the
  secret a preset has stored. Deleting a preset takes a swipe on its Library
  row with no confirmation, and its secret does not move to a new iPhone.
  With iCloud sync on, deleting the preset on another device, where it holds
  no secret, removes it from this iPhone as well and leaves its secret in
  this iPhone's Keychain, where nothing reads it. Once the preset and any
  duplicate of it are deleted, or the user moves to a new iPhone, the app
  holds no copy it will present to a tag (the per-tag records above stay on
  the original iPhone, but nothing reads them back).
  Unless the user kept the secret somewhere else, the protected memory on
  every tag written with that preset can then never be rewritten.
- The app never bypasses tag-side authentication. If a Type 2 tag refuses
  our PWD_AUTH, we surface the failure honestly and send no second password
  in that tap; we do not retry with a guess list. After Protect with password
  or Remove password is refused, the Operations sheet offers a labelled
  button that tries the published factory password on a fresh run, typed-UID
  gate included. Nothing takes that step on its own, and on a tag with an
  attempt limit it counts as a wrong try if the factory password is not the
  one the tag holds. Protect with password, run on a tag that is already
  protected against writes only, presents the new password as the tag's
  current one, so on a tag with an attempt limit that is a wrong try unless
  the tag already holds that password. A write that carries a password or
  key presents it before it writes anything. That covers a preset with a
  stored secret and a write from the editor's Protection card. On NTAG21x and
  Ultralight EV1 the app reads the tag's configuration first and sends no
  password to a tag that reads as unprotected. On NTAG424 DNA, Ultralight C
  and ICODE SLIX2 it presents the key or password whether the tag is
  protected or not. On the card the value presented is the one just typed
  there, including a new password meant to replace the tag's current one, so
  on a tag with an attempt limit it counts as a wrong try whenever the tag
  holds a different one. The one automatic fallback is on NTAG424 DNA:
  applying or removing protection draws on at most three keys in one
  session (the current key supplied to the operation, the published all-zero
  factory key and, when applying, the new key). That limits the keys tried,
  not the attempts. A write from the editor or a preset presents the
  supplied key once before it writes. If the tag refuses it and then reads
  as protected, the write presents the same key a second time in that tap
  before it stops and asks for the tag's key. A factory-fresh tag reads as
  unprotected, so the write goes on, and applying a new key to it is refused
  twice before the factory key opens it. A key change that fails adds up to
  two more attempts to learn which key the tag holds. We have not
  established whether that chip counts failed authentications.

### Build supply chain

- The build uses Apple frameworks and Hex Pro's own code only, plus one
  test-only dependency (`pointfreeco/swift-snapshot-testing`): no analytics
  or crash-reporting SDK, and no third-party UI library. That dependency is
  declared as a version range starting at 1.17.0 and `Package.resolved` is
  not committed, so every fresh checkout resolves the newest release in that
  range. `HexPromoKit` is vendored byte for byte from another Hex Pro
  repository at a pinned commit. Every additional dependency is a supply
  chain risk surface we won't accept.
- The release workflow fetches signing assets read-only via fastlane Match
  from a separate private repository. It clones that repository with
  credentials held as GitHub Actions secrets, and Match decrypts the assets
  with a passphrase held the same way. The signing private keys do not live
  in the app repository. The release toolchain is not pinned: the workflow
  installs the current fastlane release from RubyGems on every run and refers
  to GitHub Actions by major version tag rather than by commit.

## Out of scope

- The chip's cryptographic guarantees belong to the chip, which is a hardware
  trust boundary. We use whatever authentication the chip provides; we do not
  claim our app makes the chip more secure than the silicon. An NTAG21x or
  Ultralight EV1 password goes over the air in the clear whenever it is
  presented or written. So does an Ultralight C key or an ICODE SLIX2 write
  password when it is written to the tag. When a SLIX2 password is presented,
  it is masked only by a 16-bit random number the tag has just sent in the
  clear. Anyone recording these exchanges has the secret.
- Cloning is not prevented. NTAG21x UIDs are factory-fused, but the rest of
  the memory can be copied freely onto blank tags. This is an industry-wide
  property, and Hex NFC does not pretend to defeat it. The tag info card shows
  "NXP originality signature" when a Type 2 chip returns a full 32-byte
  signature, but the app never checks it against NXP's public key, so that
  row is not proof that a tag is genuine. The Features row lists
  "Originality signature" for any chip identified as a model that has one,
  whatever the chip returned. For NTAG424 DNA the card lists "SUN
  mirroring" among the chip's features, but the app neither configures nor
  checks SUN messages.
- A passport read is not proof that the document is genuine. The app
  compares the data groups it reads with the hash list in the chip's
  security object and shows "Likely untampered" when they match, but it does
  not verify that object's signature (Passive Authentication), and it runs
  neither Active Authentication nor Chip Authentication, the checks that
  detect a copied chip.
- Anyone with physical access to your unlocked iPhone can reach your tag
  data, as they can any other app's data. They can also use the passwords
  and keys saved with your presets, because writing a preset presents its
  stored secret to a tag already protected with it.
- A tag an adversary controls can return any data in response to our reads.
  We parse defensively, but we do not treat the tag as a trusted oracle for
  anything beyond its own content.

## Reporting

Report vulnerabilities privately to [security@hex.pro](mailto:security@hex.pro)
rather than in a public forum. We acknowledge a report within 72 hours, then
work with the reporter on a fix and a public disclosure date, following a
90-day coordinated disclosure timeline.
