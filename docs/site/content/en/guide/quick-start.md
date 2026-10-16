---
title: Read your first tag
description: Hold a tag against your iPhone, see what it holds, and find it again later, in about 5 minutes.
audience: user
pageKind: howto
navTitle: Quick start
tags:
  - scanning
---

In about 5 minutes you read one NFC tag with Hex NFC and see what it holds, on
screen and in the app's history. You need your iPhone and one tag.

## Before you start

- Install Hex NFC from the [App Store](https://apps.apple.com/app/id6801457461) on an iPhone running iOS 17 or later.
  There is nothing to set up on first launch: the app opens on the home screen.
  [Common questions](faq.md) covers what it costs and which iPhones it runs on.
- Have one tag to hand. A sticker, a card or a key fob all work.
- A blank tag counts as a read.
- Reading a tag changes nothing on it. Nothing on this page writes to your tag.

## Read your first tag

::::steps
:::step[Open the scan screen]
Hex NFC opens on the home screen, which carries four tiles under the app's
name: **Scan**, **Build**, **Library** and **Advanced**. Tap **Scan**, the tile
at the top left. The scan screen opens and waits, reading "Hold tag against the
top of your iPhone".
:::

:::step[Hold the tag against your iPhone]
Rest the top edge of your iPhone flat against the tag and keep it still. iOS
puts up a panel of its own across the bottom of the screen while the read runs.
The app's text stays above it. The scan screen reads "Reading…", then
"Tag detected". Once "Tag detected" appears the app has finished with the tag,
so you can take your iPhone away. If no tag is read, the screen reads "Scan
failed" and gives the reason under it. Tap **Try again**, then hold the tag
steady against the top of your iPhone. [If a tag does not scan or
write](troubleshooting.md) covers a tag that will not answer.
:::

:::step[Read what the app found]
Under "Tag detected" the app names the chip and counts what it read. A record
is one piece of content on a tag, a link or some text, and a tag carrying one
reads "1 record found". A tag carrying none reads "No NDEF records on this
tag". The screen holds for about a second. The chip name and the tag's UID
come back on the next screen, so there is nothing to memorise here.
[Scan a tag](scan-a-tag.md) has the other readings.
:::

:::step[Open a record]
The Tag screen opens by itself. The card at the top names the chip and carries
a **UID** row. Under the card, each record is a row showing its type and a
preview of what it holds. Tap a row to see the whole record, then tap
**Cancel** to come back. **Cancel** closes the record and writes nothing, on
the tag or in the app. A blank tag reads "Empty tag" in place of the rows,
which is a complete read rather than a failure.
:::

:::step[Close the tag]
Tap **Close**. The Tag screen closes without writing anything, and you are back
on the home screen.
:::
::::

## What you learned

You can now read any tag you pick up and tell what it carries. The app kept that
scan. Tap **Library** on the home screen, then **History**, the second of the
two tabs across the top of the Library screen. Your scan sits at the top of the
list. Pinning one keeps it past the limits that [Find a tag you scanned
before](scan-history.md) sets out. Opening a stored scan brings back the same
Tag screen, without holding the tag again.

## What's next

- Read [Scan a tag](scan-a-tag.md) for what each scan result means, and for a
  tag that asks for a password first.
- Read [Find a tag you scanned before](scan-history.md) to reopen, pin and
  delete stored scans.
- Read [Write a link to a tag](write-a-link.md) to put a website address on a
  blank tag.
- Read [Tags that work with Hex NFC](tags-that-work.md) to see which chips the
  app recognises.
- Read [If a tag does not scan or write](troubleshooting.md) when a tag will not
  answer.
