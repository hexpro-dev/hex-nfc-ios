---
title: Save a copy of a tag's memory
description: Copy every page a tag's chip will hand over into a .bin file with Hex NFC, then share the file.
audience: user
pageKind: howto
navTitle: Memory dump
tags:
  - chips
---

Memory dump copies a tag's pages into a `.bin` file and hands that file to the
iOS share sheet. It only reads. The tag is the same afterwards. The dump takes
one tap of the tag and never asks you to type the tag's UID back.

You need an iPhone with NFC, Hex NFC installed from the App Store and the tag
in your hand. If you have not read a tag with the app before, start with
[Read your first tag](quick-start.md). Memory dump lives on the Operations
screen. That screen opens from the menu button at the top right of the Tag
screen. The steps below scan a tag to get there. [Scan a tag](scan-a-tag.md)
covers the scan on its own.

It works on the chips Hex NFC addresses page by page. Those chips are
NTAG 210µ, NTAG213, NTAG213 TT, NTAG215, NTAG216, MIFARE Ultralight EV1,
MIFARE Ultralight C, EM V10, EM V11 and EM V16. On any other tag the screen
shows "This tag does not support that operation."

[Tags that work with Hex NFC](tags-that-work.md) says how to tell which chip
you are holding.

## Dump a tag's memory

:::warning[Send the file before you leave the screen]
The app keeps no copy of the dump. If you dismiss the share sheet or leave the
Memory dump screen without sending the file, it is gone. You have to read the
tag again.
:::

::::steps
:::step[Open the scan screen]
In Hex NFC, on the home screen, tap **Scan**. The scan screen opens and begins
looking for a tag.
:::

:::step[Hold the tag against your iPhone]
Rest the top edge of your iPhone flat on the tag and keep it still for about a
second. The Tag screen opens with what the tag holds.
:::

:::step[Open Operations]
On the Tag screen, tap the menu button at the top right, the one
to the left of **Write**. The menu holds two rows, **Save as preset…** and
**Operations…**. Tap **Operations…**.
:::

:::step[Start the dump]
Tap **Memory dump**. The screen opens and starts scanning at once, with no
confirmation in between.
:::

:::step[Hold the tag against your iPhone again]
Rest the top edge of your iPhone on the tag once more. The status line reads
"Hold the tag against the top of your iPhone." while it waits. It changes to
"Reading…" once the tag answers. At the end it shows "Memory dump ready." with
the number of bytes captured under it.
:::

:::step[Share the file]
Tap **Share .bin**, then choose where to send the file. That button appears
only after a read that finished.
:::
::::

## What the file holds

The file is the chip's memory copied page by page from the first page, 4 bytes
to a page, with no header and nothing added. Locked, password-protected and
reserved pages are all in it, wherever the chip allows them to be read. Pages
the chip refuses to decode are left out rather than asked for. One refused read
ends the session and would cost you the rest of the dump. On a
MIFARE Ultralight C the copy stops before the last four pages, which hold the
chip's key and answer no read at all.

A complete dump is a fixed size for each chip, so the count under "Memory dump
ready." tells you whether you got all of it. The Tag screen names the chip at
the top of the tag info card. It uses the same words as the first column below.
A MIFARE Ultralight EV1 tells you there which of the two sizes it is.

:::table[Bytes in a complete dump]
| Chip | Complete dump |
| :--- | ---: |
| NTAG 210µ, EM V10, EM V11, EM V16 | 64 bytes |
| NTAG213, NTAG213 TT | 180 bytes |
| NTAG215 | 540 bytes |
| NTAG216 | 924 bytes |
| MIFARE Ultralight EV1 (48b) | 80 bytes |
| MIFARE Ultralight EV1 (128b) | 164 bytes |
| MIFARE Ultralight C | 176 bytes |
:::

Hex NFC writes the file to temporary storage, under a name carrying the date
and time of the read. Sharing it is what keeps it. The app has no list of
dumps. Nothing on the Tag screen points back to the file. Send it somewhere
before you leave the screen.

## If the dump does not finish

A failed dump leaves the tag exactly as it was, so there is no cost to reading
it again.

- To read the same tag again, tap **Try again**. The screen starts a new scan.
- To see what the tag answered, open **Diagnostics** under the failure message.
  The text inside can be selected and copied into a bug report.

Tapping Cancel on the iOS sheet before any tag is read takes you back to the
Operations screen. With no tag against your iPhone, the sheet closes by itself
and the screen reads "No tag found" with **Try again** under it.

"This tag does not support that operation." means the chip is not one of those
listed at the top of this page. NTAG424 DNA, ICODE SLIX, ICODE SLIX2, the
MIFARE DESFire chips and FeliCa all answer that way. The
[chip support matrix](../developer/chip-support-matrix.md) lists what each chip
can do.

For a tag that drops out partway through a read, see
[If a tag does not scan or write](troubleshooting.md). Go there too for a
message this page does not cover.

## See also

- [Scan a tag](scan-a-tag.md)
- [Tags that work with Hex NFC](tags-that-work.md)
- [Send a raw command to a tag](advanced-console.md)
