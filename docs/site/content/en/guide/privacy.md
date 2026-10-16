---
title: Privacy and your data
description: What Hex NFC keeps on your iPhone, the three kinds of request it makes to Hex Pro, and what each permission is for.
audience: user
pageKind: article
navTitle: Privacy
tags:
  - privacy
  - security
---

You hold a tag against your iPhone and what it holds appears on screen. That
reading happens on your iPhone, and the result stays there. Hex NFC has no
accounts and no analytics, and the three kinds of request it makes to Hex Pro's
own servers carry nothing about you. The full text of the policy is in the app.
On the Hex NFC home screen, tap the gear button in the top right. Then under
**Legal** tap **Privacy Policy**.

## What stays on your iPhone

Your scan history and your saved presets live in a local database on this
iPhone, and your settings are stored locally too. Deleting an item removes it
from that database. Deleting the app removes the app's local data with it.

Tag passwords are held apart from all of that, in the iOS Keychain on the one
iPhone that set them. A password is never synced, never written into a file you
export, and never sent anywhere. The app files two kinds of item. One is for a
tag whose protection a write applied, filed under that tag's UID. That write
runs from the Tag screen's **Protection** card, or from a preset that applies
protection. The other item is for a preset that applies protection, filed under
the preset. Neither holds anything about you. A password you type into
**Operations…** > **Protect with password** is filed in neither, so keep your
own copy of it. Deleting the app does not take the filed passwords with it,
because iOS keeps Keychain items after an app goes. A passport read is kept
nowhere at all. What the chip returns is on screen for that session and gone
when the session ends. [Read a passport](passports.md) describes that in full.

Two things clear a stored password. Deleting a preset drops the password saved
with it. That happens whether or not the tag it was written to is still
protected. A tag can then be left gated by a password the app no longer holds.
The other is turning the protection off on the tag's **Protection** card and
then writing the tag, which [Remove a tag's password](remove-password.md) sets
out. Even there, the app drops the password only when it has read the tag back.
That read-back has to find both of these:

- The protection is gone.
- The tag's password is the chip's factory default again.

A removal that proves the first but not the second keeps the stored password. A
tag that is open while still holding your password cannot be protected again
without it. A removal run from **Operations** clears nothing from the Keychain.
Any item already filed for that tag stays where it is.

Nothing in Hex NFC lists the tags it holds a password for. A tag you cannot tap
again cannot have its stored password cleared from inside the app. That Keychain
item stays on this iPhone unless a later removal clears it, or you erase the
iPhone.

**iCloud sync** starts off, and the switch takes effect the next time you open
the app. With it on, your presets and scan history are mirrored to your private
iCloud database, which Apple operates and your Apple ID protects. Hex Pro cannot
read it. Tag passwords stay out of it either way. The switch is in
[Settings](settings.md).

Turning sync off stops the mirroring only once you close Hex NFC and open it
again, as [Close and reopen the app](settings.md#close-and-reopen-the-app)
describes. Going back to your iPhone's Home Screen leaves the app running and
the mirroring with it.

Stopping the mirroring is not the same as removing what iCloud already holds,
and deleting the app does not remove it either. To take that copy away, open the
Settings app on your iPhone. Tap your name at the top, then tap the iCloud row.
Work through the storage it lists, where the data each app keeps can be deleted.

:::note[A tag is not private storage]
Anything you write to a tag lives on hardware outside your iPhone, and anyone
with a reader can read an unprotected tag. Treat what a tag holds as public
unless you protect it, which [Tag protection](tag-protection.md) explains.
:::

## The three times the app reaches Hex Pro

None of these runs in the background, and none of them carries anything that
identifies you.

- The home screen fetches one public figure about the project's development
  costs from api.apps.hex.pro. The request contains no personal data.
- A station-name suggestion goes out when you tap **Submit** on an unknown stop
  from a transit card. Tapping the keyboard's send key while the name field is
  open sends it too. It carries the line, station and area codes, the card's
  system code, and the name you typed. The card's serial number, balance and
  travel history are not part of it, so keep personal details out of the name
  field.
- The **More from Hex Pro** card fetches a banner for another Hex Pro app from
  api.p.hex.pro. The request sends this app's bundle identifier, the platform
  and a slot name. The answer names an image or a video, which the app
  downloads from a second address and keeps on your iPhone. Everyone sees the
  same banner. No ad network, tracking identifier or personalisation sits
  behind it.

iCloud sync is the other thing that uses the network, and the exception to the
paragraph above. With it on, your presets and scan history travel between your
iPhone and Apple in the background. None of that reaches Hex Pro.

Any internet request shows your IP address to the server that answers it. Hex
Pro keeps short-lived operational logs and does not use an IP address to
identify or profile anyone.

## What each permission is for

Hex NFC asks you for two permissions. NFC is the one it cannot work without,
and iOS gives you no switch for it. The camera is optional, and iOS asks for it
the first time you scan a QR code. What either one captures stays on your
iPhone.

The Privacy Policy in the app describes three more, for contacts, location and
Bluetooth. Nothing in the app asks for those three, so iOS never prompts you
about them.

:::table[The permissions Hex NFC asks for]
| Permission | What it is used for |
| :--- | :--- |
| NFC | Reading and writing tags, only while a scan or write screen is open. |
| Camera | Scanning a QR code you choose to turn into a record. Frames are never saved or uploaded. |
:::

## What Hex Pro never does

Hex NFC carries no analytics or telemetry SDKs and no third-party advertising,
and nothing in it fingerprints your iPhone. Hex Pro does not sell, rent or share
personal information. There are no accounts, so no Hex Pro server holds a
profile of you. A file you export holds the records and presets you picked, and
never a tag password.

## See also

- [Settings](settings.md)
- [Read a transit card](transit-cards.md)
- [Read a passport](passports.md)
- [Tag protection](tag-protection.md)
