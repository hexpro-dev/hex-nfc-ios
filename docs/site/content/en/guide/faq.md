---
title: Common questions
description: Answers about what Hex NFC costs, which iPhones it needs, what happens to the tags you scan, and how to get help.
audience: user
pageKind: faq
navTitle: FAQ
tags:
  - privacy
---

The other guide pages walk through each task. This page answers what comes up
around them: what the app costs and what it asks of your iPhone. It also
answers what happens to the tags you scan, and how to reach Hex Pro.

## What it costs

### Does Hex NFC cost anything?

No. Hex NFC costs nothing, and there are no accounts, subscriptions, in-app
purchases or paid features. Install Hex NFC from the
[App Store](https://apps.apple.com/app/id6801457461) and the whole app is there.

### What is the development-costs card?

A progress figure, and nothing you have to act on. The Hex NFC home screen
carries a card headed **Development Costs Recovered** that shows how much of
the project's cost has come back so far. **View Breakdown** opens a page on the
Hex Pro website in your browser, where contributing is voluntary. Nothing in
the app is unlocked by anything on that page.

### Does the app show ads?

No ad network runs inside it. The home screen may show a card headed **More
from Hex Pro** for another app by the same publisher. No third-party ad
network, no tracking and no personalisation sit behind that card: everyone sees
the same one.

## What your iPhone needs

### Which iPhones can run Hex NFC?

Any iPhone running iOS 17 or later, which means the iPhone XR and iPhone XS
onwards, plus the second and third-generation iPhone SE. Every one of those
carries the NFC reader the app uses, so the iOS version is the only thing to
check. Hex NFC is an iPhone app and does not run on an iPad. On a device
without the reader, a scan ends with "This device does not support NFC."
instead of looking for a tag.

### Do I need an internet connection?

No. Reading a tag, writing one and protecting one all happen between your
iPhone and the tag. The app reaches Hex Pro for four things. Two are the
development-costs figure and the card for another Hex Pro app. The other two go
out only when you send them: a station name from a transit card, and a feedback
message. iCloud sync is the fifth use of the network, and it stays off until
you turn it on. See [Privacy and your data](privacy.md).

### Why will my iPhone not read one of my tags?

Its chip may be one an iPhone cannot read at all. MIFARE Classic is the common
case, and it is an iOS limitation rather than a fault in the tag. See
[Tags that work with Hex NFC](tags-that-work.md) for the chips the app
recognises.

## The tags you scan

### What happens to a tag after I scan it?

The scan is saved on your iPhone, under **History** on the Library screen. That
list is capped, and an unpinned row expires with age as well; a row you have
pinned stays past both limits. Deleting a row removes
the stored scan. See [Find a tag you scanned before](scan-history.md).

### Are passports and transit cards saved as well?

The two differ. A passport read is held for that one session and dropped when
you close the sheet. None of it reaches your history, an export or iCloud. A
transit card read is saved like any other scan. The row sits under **History**
on the Library screen and counts against the 50 rows that list holds. While
iCloud sync is on, it is mirrored to iCloud. Opening that row shows the card as
it was read, and deleting the row removes the stored scan. See
[Read a passport](passports.md) and [Read a transit card](transit-cards.md).

### Does anything about my tags leave my iPhone?

Only if you turn on **iCloud sync**, which sits in the **Sync** group on the
Settings screen and starts off. It mirrors your presets and your scan history
into your private iCloud database, which Apple operates and your Apple ID
protects. Tag passwords are never part of it: they stay in the iOS Keychain on
the iPhone that set them. See [Settings](settings.md#turn-on-icloud-sync) and
[Privacy and your data](privacy.md).

### Can Hex NFC recover a tag password I have forgotten?

No, and nothing else can either. The tag itself checks the password, so
protected memory on a tag whose password is lost is irrecoverable. A password
you set is kept in the Keychain of the iPhone that set it. On a second iPhone,
the same tag asks you to enter it. See [Tag protection](tag-protection.md).

### Can Hex NFC read my insulin pen? {#insulin-pen}

It can tell you what the pen is, but not what it holds. A NovoPen 6 or NovoPen
Echo Plus opens a **Health device** screen that names an app able to read its
dose history. Hex NFC never writes to a health device and saves nothing from
one. See [Health devices](tags-that-work.md#health-devices).

## Getting help {#getting-help}

### How do I report a problem or ask a question? {#report-a-problem}

In Hex NFC, tap the gear button on the home screen, then **Send Feedback**. The
message goes straight to Hex Pro with the app version, iOS version, device
model and language, and the form lists those before you send. Add your email
address under **Reply address (optional)** if you want an answer. You can also
email support@hex.pro.

If a scan or a write fails, work through the message you saw in
[If a tag does not scan or write](troubleshooting.md).
