# Privacy Policy

**Effective 31 October 2026**
Ars Vitae Pty Ltd, trading as Hex Pro (Australia)

## 1. The short version

Hex NFC has no accounts, no analytics, no advertising trackers, and nothing to
sell. What you scan stays on your device. The app makes four kinds of internet
request, all described below. Three of them carry no personal information. The
fourth is a feedback message, which is sent only when you write one and tap
Send, and carries only what the form shows you.

## 2. What stays on your device

- Scan history and saved presets live in a local database on your device.
- App settings (haptics, motion, sync) are stored locally.
- The app occasionally asks how you are finding it. Whether it has asked, how
  you answered, and a count of recent scans and writes that decides when it may
  ask are stored on your device. They are never synced or sent.
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
machine-readable zone and are discarded when the session ends. If you choose to
scan the photo page with the camera instead of typing those details, the camera
image is examined on your device only to find them, and no image is saved or
transmitted.

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

There are exactly four cases. None of them runs in the background. The first
three carry nothing that identifies you; the fourth carries only what you choose
to send.

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
- **Feedback.** Sent only when you write a message in the feedback form and tap
  Send. It contains your message, the email address you entered if you chose to
  give one, and the app version, iOS version, device model and app language,
  which the form shows you before you send. It goes to our API at api.hex.pro
  and is delivered to our feedback inbox. We use it to read and answer your
  message and to fix problems, never for marketing, and keep it for up to 24
  months. Nothing from your tags, scans or history is included.

Like every internet request, these necessarily expose your IP address to our
servers. We keep only standard, short-lived operational logs and do not use IP
addresses to identify or profile anyone. A feedback message is stored with a
keyed hash of your IP address, used only to limit how many messages one
connection can send, and the hash is erased within seven days.

## 7. Device permissions

Every permission is optional, and everything captured is processed on your
device:

- **NFC**: used only while a scan or write sheet is open.
- **Camera**: only for scanning QR codes you choose to import, and for reading a
  passport's photo page when you choose to scan it. Frames are never saved or
  uploaded.

The app does not ask for access to your contacts, your location or Bluetooth.

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

The app is not directed at children, and we do not knowingly collect personal
information from children. The only personal information the app can send us is
what you choose to put in a feedback message.

## 12. Your rights

Because almost nothing about you ever reaches us, most privacy requests can be
satisfied on your own device by deleting items or the app. For anything
involving our servers (for example, a station suggestion you regret
submitting, or a feedback message you want deleted), contact us and we will
help. You can also complain to the Office
of the Australian Information Commissioner or your local data-protection
authority.

## 13. Changes to this policy

When this policy changes, the new version appears here with a new effective
date.

## 14. Contact

Privacy questions: support@hex.pro
