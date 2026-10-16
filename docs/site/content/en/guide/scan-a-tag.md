---
title: Scan a tag
description: Read what an NFC tag holds with Hex NFC on your iPhone, including a tag that asks for a password before it shows anything.
audience: user
pageKind: howto
tags:
  - scanning
---

Hex NFC reads a tag in one tap. You tap **Scan**, hold the tag against the top
of your iPhone, and the app shows which chip it found and what the tag holds. A
scan only reads, so nothing on the tag changes.

A tag can also be set to require its password before it will be read. A tag
protected that way refuses to be read until the password is presented.
Presenting it takes two taps rather than one. The second half of this page
covers that. Most protected tags are write-protected only. Those scan in one
tap like any other tag. If you have not scanned a tag before,
[Read your first tag](quick-start.md) covers the same tap from the start.

## Scan a tag

::::steps
:::step[Open the scan screen]
Open Hex NFC and tap **Scan** on its home screen. The scan screen opens and
reads "Hold tag against the top of your iPhone".
:::

:::step[Hold the tag against the top of your iPhone]
Rest the top edge of your iPhone on the tag and keep it still. The screen reads
"Reading…" while the tag is read.
:::

:::step[Read what the app found]
"Tag detected" appears with a tick, and the chip's name sits under it. Below
that the app says what it read. The line "1 record found" gives the number of
records on the tag. "No NDEF records on this tag" means the tag is formatted
but empty. The tag's UID is last.
:::
::::

The result holds for about a second, then the app opens **Tag** with the
records listed, where you can change them or write them again. Nothing from the
result is lost there. The chip's name is the heading of the tag info card, and
the records are the list below it. The UID is a row on that card, where a tap
copies it at any time. Each scan is saved to your history as well. See
[Find a tag you scanned before](scan-history.md) and
[Edit a tag's records](edit-records.md).

To stop before a tag is read, tap **Cancel** on the iOS scan sheet. The scan
screen closes and you are back on the home screen. With no tag against your
iPhone, the iOS sheet closes by itself after about a minute, and the scan screen
reads "No tag found" with **Cancel** and **Try again** under it.

Some tags leave the scan screen by another route. A Japanese transit card
opens its own read-only result, covered in
[Read a transit card](transit-cards.md). An electronic passport asks for the
details on its photo page first, covered in [Read a passport](passports.md). A
protected tag asks for its password, which is the next task here.

If the result says "This tag isn't formatted yet", nothing you write to the tag
will be readable until the tag is formatted.
[Erase or format a tag](erase-or-format.md) says how to do that.

## Unlock a protected tag

A tag that requires its password to be read stops the scan. The scan screen
shows "Tag is protected" above this sentence: "This tag looks
password-protected. Enter its password, then hold it to the top of your iPhone
again." Under that sit the password field, **Unlock & scan again**, and a row
holding **Cancel** and **Try again**. The password belongs to the tag, not to
an account, and only the person who set it has it. The setting that produces
this state is **Also require password to read**, covered in
[Protect a tag with a password](protect-a-tag.md).

::::steps
:::step[Enter the tag's password]
In **Tag password (4 bytes)**, enter the password as hexadecimal characters, 0
to 9 and A to F. A 4-byte password is 8 characters: type it as `A1B2C3D4` or as
`A1:B2:C3:D4`, because the colons between the bytes are optional and do not
count towards the length. The note under the field reads "OK" once the entry is
the right length. On an NTAG424 DNA the field reads **Tag key (16-byte AES)**
instead. On a MIFARE Ultralight C it reads **Tag key (16-byte 3DES)**. Those
two chips open with a key, not a password. Both of those keys are 16 bytes,
which is 32 characters.
:::

:::step[Start the second tap]
Tap **Unlock & scan again**. The button stays dim until what you entered is the
right length for the chip.
:::

:::step[Hold the tag against the top of your iPhone again]
The app presents the password, then reads the tag and shows "Tag detected" as
it does for any other tag.
:::
::::

A password the tag refuses brings you back to "Tag is protected", with the
prompt replaced by "That password didn't unlock the tag. Check it and try
again." On an NTAG424 DNA or a MIFARE Ultralight C it reads "That key
didn't unlock the tag. Check it and try again." instead. Correct the entry and
tap **Unlock & scan again** for another tap. A refused password stops the chip
answering for the rest of that tap. Every attempt is a fresh tap by design. To
go back to an ordinary read with no password, tap **Try again**.
**Cancel** does something else: it closes the scan screen without reading the
tag, and what you typed is discarded. Neither one changes the tag.

:::warning[A refused password can cost you a try]
A tag can be set to accept only so many wrong passwords before it stops
answering for good. On a tag that reports such a limit, the app replaces the
advice above with the refusal's own wording. Checking the password again is
worth more than another attempt. See
[Limit wrong password tries](attempt-limit.md).
:::

## Unlock a protected tag before writing to it

A write starts on **Tag**. A protected tag reaches **Tag** through the unlock
above. Finish that scan first, and the app opens **Tag** as it does for any
other tag. Two routes skip that read. In **Library**, the **History** tab
lists the tags you have scanned before, and a tap on a row re-opens that tag
on **Tag**. A swipe of a preset from the left, on the
**Presets** tab, offers **Write**, which opens the write screen straight away
against the preset's records.

On **Tag**, tap **Write** in the toolbar and the write screen opens.
[Write a link to a tag](write-a-link.md) covers a write from end to end; what
follows is the extra step a protected tag adds.

The write screen asks for the password again, even on a tag you unlocked a
moment ago. Each tap is a separate session, and the app carries no password
across one. Typing it a second time is expected, not a sign the unlock failed.
Counted from a standing start, a protected tag takes three taps: the scan it
refuses, the unlock scan that opens **Tag**, and the write.
The screen shows "Tag is protected", then asks for the password: "This tag is
password-protected. Enter its password to write to it, then hold it to the top
of your iPhone again."

::::steps
:::step[Enter the password on the write screen]
In **Tag password (4 bytes)**, enter the tag's password, the same 8 hexadecimal
characters a scan asks for. The field names a key instead of a password on the
two chips that use one, and a key is 32 characters.
:::

:::step[Start the write's second tap]
Tap **Unlock & write**. If the write also changes the tag's protection, the
button reads **Unlock & continue** instead. The app then shows you the tag's
UID and asks you to type it in, under "Type this tag's UID to confirm.", before
it writes. See [Protect a tag with a password](protect-a-tag.md).
:::

:::step[Hold the tag to write it]
Hold the tag against the top of your iPhone again. The app presents the
password and then writes.
:::
::::

A refusal here reads "That password didn't unlock the tag. Check it and try
again." as well, and is answered the same way: check what you entered, then
hold the tag again.

A scan can end in "Scan failed". A tag you believe is blank might ask for a
password. Either way, work through
[If a tag does not scan or write](troubleshooting.md).
