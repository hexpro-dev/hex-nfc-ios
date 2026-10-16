# Privacy Policy

**Effective 7 July 2026**
Ars Vitae Pty Ltd, trading as Hex Pro (Australia)

## 1. The short version

Hex NFC has no accounts, no analytics, no advertising trackers, and nothing to
sell. What you scan stays on your device. The app makes exactly three kinds of
internet request, none of which carries personal information, and all of which
are described below.

## 2. What stays on your device

- Scan history and saved presets live in a local database on your device.
- App settings (haptics, motion, compatibility mode, sync) are stored locally.
- Tag passwords you set or use are stored only in the iOS Keychain on this
  device. They are never synced, never included in exported files, and never
  sent anywhere.

Deleting an item in the app removes it from the local database. Deleting the
app removes the app's local data from your device.

## 3. Electronic passports

When you read a passport or identity document, the chip's contents (including
name, date of birth, and photo) are shown on screen for that session only.
Nothing from a passport is ever saved, synced, exported, or transmitted. The
keys needed to talk to the chip are derived on your device from the document's
machine-readable zone and are discarded when the session ends.

## 4. Transit cards

Transit cards are read-only. The balance and trip information shown comes
straight from the card. Like other scans, a transit read is kept in your local
scan history so you can reopen it later; it stays on your device unless you
turn on iCloud sync.

## 5. iCloud sync (optional, off by default)

If you turn on iCloud sync, your presets and scan history are mirrored into
your private iCloud database, which is operated by Apple and protected by your
Apple ID. We cannot read it. Turning sync off stops the mirroring, and deleting
items removes them from sync. Tag passwords are never synced.

## 6. When the app talks to the internet

There are exactly three cases. None of them runs in the background, and none
carries anything that identifies you.

- **Development-costs figure.** The home screen fetches one public number
  (contributions received versus project cost) from our API at
  api.apps.hex.pro. The request contains no personal data.
- **Station-name suggestions.** Sent only when you tap Submit. The payload is
  the numeric line, station, and area codes, the card system code, and the
  station name you typed. Your card's serial number, balance, and travel
  history are never sent. Suggestions are reviewed by the maintainer and
  treated as anonymous; please do not put personal information in the name
  field.
- **Hex Pro app banner.** The home screen may show a banner for another Hex Pro
  app. Fetching it sends this app's bundle identifier, the platform ("ios"),
  and a slot name to our API at api.p.hex.pro, and returns an image or video
  that is cached on your device. There are no third-party ad networks, no
  tracking identifiers, and no personalisation: everyone sees the same banner.

Like every internet request, these necessarily expose your IP address to our
servers. We keep only standard, short-lived operational logs and do not use IP
addresses to identify or profile anyone.

## 7. Device permissions

Every permission is optional, and everything captured is processed on your
device:

- **NFC**: used only while a scan or write sheet is open.
- **Camera**: only for scanning QR codes you choose to import. Frames are never
  saved or uploaded.
- **Contacts**: only when you pick a contact to build a record. The picked
  details go onto your tag, not to us.
- **Location**: only when you tap "use current location" while building a map
  record.
- **Bluetooth**: only when you choose a device while building a Bluetooth
  handover record.

## 8. What we never do

No analytics or telemetry SDKs. No third-party advertising. No fingerprinting.
No selling, renting, or sharing of personal information. No accounts, and no
profile of you anywhere on our servers.

## 9. Data you write to tags

Anything you write to an NFC tag lives on hardware outside your device, and
anyone with a reader can read an unprotected tag. Treat tag contents as public
unless you protect the tag.

## 10. Exported files

Files you export or share contain the records and presets you selected. They
never include tag passwords.

## 11. Children

The app is not directed at children, and we knowingly collect no personal
information from anyone, children included.

## 12. Your rights

Because almost nothing about you ever reaches us, most privacy requests can be
satisfied on your own device by deleting items or the app. For anything
involving our servers (for example, a station suggestion you regret
submitting), contact us and we will help. You can also complain to the Office
of the Australian Information Commissioner or your local data-protection
authority.

## 13. Changes to this policy

When this policy changes, the new version appears here with a new effective
date.

## 14. Contact

Privacy questions: support@hex.pro
