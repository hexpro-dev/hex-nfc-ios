---
title: Write a link to a tag
description: Put a website address on a blank tag so that tapping the tag opens the page.
audience: user
pageKind: howto
navTitle: Write a link
tags:
  - writing
---

A tag can hold a website address, and a phone that reads the tag is offered that
address. In Hex NFC the address is a URL record. You build the record on your
iPhone, then hold the tag against it once to send the record across.

Before you start, have the tag to hand. If you are not sure a tag can still be
written, scan it first, as [Scan a tag](scan-a-tag.md) describes. The scan opens
the Tag screen. There, **Write** is available on a tag that still takes a write.
It is dimmed on a tag the app reads back as permanently locked, which refuses
every write. Tap **Close** to leave that screen for the home screen, then start
at step 1.

## Write a link to a blank tag

::::steps
:::step[Start a new build]
On the home screen, tap **Build**. The Tag screen opens with no records, under
the heading "Empty tag".
:::

:::step[Add a URL record]
Tap **Add record** > **URL**. The record editor opens on the new record.
:::

:::step[Enter the address]
In **URL**, type the address with its scheme in front, for example
`https://hex.pro`, then tap **Save**. The record appears in the list. The app
writes the address exactly as you entered it and adds nothing. An address that
reaches the tag without its `https://` is not a working link. A phone that reads
that tag has no page to open.
:::

:::step[Send the record to the tag]
Tap **Write**, at the top of the Tag screen. The write screen opens and reads
"Hold tag against the top of your iPhone". iOS puts its own scan sheet over the
app, carrying the same line.
:::

:::step[Hold the tag against your iPhone]
Rest the top edge of your iPhone on the tag and keep it there. The screen reads
"Writing…", then "Verifying…". Nothing in this step locks the tag. You can write
over it again as often as you like. The success wording, "Locked in", says only
that the records went across and read back intact. The screen closes on its own
and the Tag screen comes back.
:::
::::

Writing replaces everything the tag held. If you want to keep some of what is
already on a tag, scan it first. Edit that list instead of building a new one,
as [Edit a tag's records](edit-records.md) describes.

:::tip[Any record type writes the same way]
A link is the most common thing to put on a tag, and it is one of 13 kinds of
record you can add. [Record types](record-types.md) lists them all, and the
steps above are the same whichever one you choose.
:::

## What the app checks before it says it worked

The app never takes the tag's word for a write. It sends the records, reads the
tag again and compares what came back with what it sent. "Locked in" means the
tag was read back holding exactly what you wrote.

One state stops the write instead of finishing it. On a tag whose password
gates its records, the write screen reads "Tag is protected" and asks for that
password before anything is written. Type the password into **Tag password
(4 bytes)** and tap **Unlock & write**. Then hold the tag against the top of
your iPhone again. That second tap is the one that authenticates and writes.
The app skips the prompt when it already holds the password from the time you
protected the tag. The write goes through on the one tap. If you do not
know the password, tap **Cancel**: your records stay on the Tag screen. See
[Tag protection](tag-protection.md) for what a password does to a tag.

A tag with no header for records to sit in is not stopped before the write. The
app sends the records, the read-back finds nothing readable on the tag, and the
write ends on "Write failed".

What keeps you out of that is a scan. On a tag the app scanned as unformatted,
the Tag screen shows "This tag isn't formatted" above the record list. Under it
the screen reads "It has no Capability Container, so records written now won't
be readable. Format it first." Tap that notice to open the Operations screen and
format the tag. A tag you started from **Build** has no scan behind it, so the
Tag screen has nothing to warn you with.

Records you have built are not lost to the repair. Tap the menu button at the
top right of the Tag screen, then **Operations…**. The Operations screen opens
over the Tag screen. Your records are still there when you close it.
See [Erase or format a tag](erase-or-format.md).

To stop a write before it starts, tap **Cancel** on the write screen while it is
still waiting for a tag. Your records stay on the Tag screen. Tapping Cancel on
the iOS sheet before any tag is read does the same. With no tag against your
iPhone, the iOS sheet closes by itself after about a minute, and the write
screen reads "No tag found" with **Close** and **Try again**.

## If the write fails

A write that fails, or a read-back that differs from what was sent, ends on
"Write failed" with the reason under it. From there:

- To send the same records again, tap **Try again**. You keep anything you have
  already typed.
- To go back to the Tag screen without writing, tap **Close**.

A tag that keeps refusing may be the wrong kind for what you are writing.
[Tags that work with Hex NFC](tags-that-work.md) says which chips the app
recognises, and
[the chip support matrix](../developer/chip-support-matrix.md) has the detail
per chip.

## See also

- [Edit a tag's records](edit-records.md)
- [Save a tag as a preset](presets.md)
- [If a tag does not scan or write](troubleshooting.md)
