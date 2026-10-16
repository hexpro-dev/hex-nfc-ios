---
title: Tags that work with Hex NFC
description: Which chips the app recognises, what the tag info card tells you about one, and what an iPhone cannot read at all.
audience: user
pageKind: article
navTitle: Supported tags
tags:
  - chips
---

A sticker from a pack of blanks, a hotel key card and a library label all feel
the same in your hand. The chip inside them is not the same, and it decides how
much the tag holds and whether it can take a password. It also decides whether
your iPhone can read the tag at all.

For tags of your own, buy blanks from the NTAG family. An NTAG213 holds 144
bytes, enough for a web address or a short contact. An NTAG215 holds 504 bytes
and an NTAG216 holds 888, which is what a long note or a stack of records
needs. Each of the three can take a password and can be locked. A tag you did
not buy blank is usually filled with data only whoever issued it can make sense
of. A hotel key, a transport card and a building pass are all that kind of tag.

To find out what a tag in your hand is, scan it. What the app read opens on the
Tag screen. The card at the top of that screen is the tag info card, headed with
the chip's own name. [Scan a tag](scan-a-tag.md) walks through the scan itself.

The name is a part number, so it is the thing to search for when you want to
know what a tag can take. Chip by chip, what the app does with each one is set
out in the [Chip support matrix](../developer/chip-support-matrix.md). That page
is part of the developer documentation rather than this guide, so it talks about
commands and test runs.

## The names the app shows

The heading of the tag info card is the chip's own name. These are the names it can
show.

:::table[The chip names the tag info card can show]
| Family | Names on the tag info card |
| --- | --- |
| NTAG | NTAG 210µ, NTAG213, NTAG213 TT, NTAG215, NTAG216, NTAG424 DNA |
| MIFARE Ultralight | MIFARE Ultralight EV1 (48b), MIFARE Ultralight EV1 (128b), MIFARE Ultralight C |
| MIFARE DESFire | MIFARE DESFire, MIFARE DESFire EV1, MIFARE DESFire EV2, MIFARE DESFire EV3 |
| EM Microelectronic | EM V10, EM V11, EM V16 |
| ICODE | ICODE SLIX, ICODE SLIX2 |
| Named by family only | ISO 15693, FeliCa, ePassport |
:::

The last row is what you see when the chip answers as one of a family but will
not say which model it is. A Japanese transit card reads as FeliCa and opens its
own result, covered in [Read a transit card](transit-cards.md). A passport reads
as ePassport, covered in [Read a passport](passports.md).

Some chips say nothing an NFC app can match against a part number. The card then
carries a **Reported** row and a **Version bytes** row in place of a name, which
are the tag's own words about itself. Such a tag can still be read and written
as an ordinary tag. What it loses is everything that depends on knowing the
chip's memory layout. That rules out a password, a permanent lock and
**Memory dump**, the operation
[Save a copy of a tag's memory](memory-dump.md) explains.

## What the card says about the silicon

Two rows summarise the chip. **Supports** lists what the app can do with it,
such as "Read", "Write", "Password" or "Lock". "Write" means the tag takes a new
message, as in [Write a link to a tag](write-a-link.md). "Password" means it can
carry one of its own, covered in
[Protect a tag with a password](protect-a-tag.md). "Lock" means the tag can be
made read-only. That cannot be undone on any tag, which is why
[Lock a tag permanently](permanent-lock.md) is a page of its own. **Features**
lists the extras the silicon carries, such as "Tap counter" or "Tamper loop".

Under those sit rows that only appear when the chip answered for them. A row
that is missing means the chip said nothing about it, never that the scan went
wrong.

A **Tamper** row belongs to a chip with a tamper loop, which today means an
NTAG213 TT. It reads "Seal intact" while the loop is whole, and "Opened" once
the loop has been broken. A broken loop stays broken. A seal the app reports as
open was already open when you found the tag. No scan of yours broke it.

A **Times read** row comes from a chip with a tap counter, and holds the number
of reads the chip has counted. "Counter off" is different from a missing row:
the counter is there and switched off, which is how most tags leave the factory.

A **Counters** row comes from a MIFARE Ultralight EV1, in either of its two
sizes. That chip keeps three counters of its own, and the row holds all three on
one line. A second **Counters** row reading "Tearing event detected" means the
chip reports that those counters are not intact. A MIFARE Ultralight C shows
neither row, because its counter answers a command the app does not send.

A **Signature** row reads "NXP originality signature" when the chip answered
with a 32-byte signature. It reads "Not a standard NXP signature" when the
answer was shorter than that. Neither line is a verdict on whether a tag is genuine. The
app writes down what the chip replied, and checks it against nothing.

## What an iPhone cannot read

One common card is out of reach on any iPhone. A MIFARE Classic stops the scan
with a message saying so: the tag is not faulty, and no NFC app on iOS gets
further. [Why can my iPhone not read this tag at
all?](troubleshooting.md#tag-not-readable) has the message and the reason.

A MIFARE DESFire card is a softer version of the same limit. The app names the
card and can send raw commands to it, and it reads records only when the card
carries an ordinary NDEF area. The rest of a DESFire sits behind keys held by
whoever issued the card.

If a tag you believe is supported still will not scan, the cause is usually the
hold rather than the chip. See
[If a tag does not scan or write](troubleshooting.md).
