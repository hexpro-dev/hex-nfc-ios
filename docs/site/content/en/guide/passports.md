---
title: Read a passport
description: Read the chip in an electronic passport with Hex NFC, using the details from its photo page, for one session only.
audience: user
pageKind: howto
navTitle: Passports
tags:
  - scanning
  - privacy
---

An electronic passport keeps its photo page on a chip: the name, the number,
the dates and the photograph. Hex NFC reads that chip and lays out what it
found on one screen. The chip opens only to three details printed inside the
passport. The app asks for those after the first tap finds the chip. It holds
the result for as long as the screen is open, and no longer.

Before you start you need the app installed from the App Store on an iPhone
that reads NFC tags, and the passport itself.
[Read your first tag](quick-start.md) covers installing the app and reading one
tag.

Open the passport at the photo page and keep it to hand. The passport number,
the date of birth and the date of expiry are printed there. You type all three
in. The photo page is where you read those details, not where the phone
goes. The chip symbol, a small rectangle with a circle inside it, is printed on
the cover of an electronic passport. A passport without that symbol carries no
chip, and nothing here will read it.

## Read a passport

::::steps
:::step[Open the scan screen]
Tap **Scan** on the home screen. The scan screen opens and reads "Hold tag
against the top of your iPhone".
:::

:::step[Hold the passport against your iPhone]
Close the passport, rest the top edge of your iPhone flat against the front
cover, and keep it still. The antenna sits in the front cover, the back cover
or the photo page, depending on the passport. If nothing happens after a few
seconds, try the back cover, then the open photo page. This first tap works out
what the chip is and then ends, and the scan sheet closes with it. The scan
screen now reads "Passport detected" and holds the three fields the chip opens
to: **Passport number**, **Date of birth** and **Date of expiry**.
:::

:::step[Enter the passport number]
In **Passport number**, enter the number from the photo page, letters
included. The field shows "e.g. PA1234567" until you type.
:::

:::step[Choose the two dates]
Tap **Date of birth** and choose the date printed on the photo page, then do
the same for **Date of expiry**. Each picker opens on a date the app picked to
start from, so check the year as well as the day. The expiry date is the one
the passport runs out on, not the date it was issued.
:::

:::step[Start the read]
Tap **Read passport**. The button will not start a read while the passport
number field is empty.
:::

:::step[Hold the passport against your iPhone again]
Hold it to the top of your iPhone and keep it there. The scan sheet counts the
read through "Connecting to your passport…", "Unlocking with your details…",
"Reading passport data…" and "Almost done…". The **Passport** screen opens when
it finishes.
:::
::::

Tap **Close** when you have read what you came for.

## What the Passport screen shows

The screen is read-only. Rows appear only where the chip answered, so a
passport with less on it shows a shorter screen.

- The booklet at the top carries the photograph from the chip and the two
  machine-readable lines as they are printed in the passport. Some passports
  store the photograph in a format iOS does not read, and the booklet then shows
  a grey figure in its place. Nothing else on the screen changes.
- Under **Passport details** are the surname, given names, passport number,
  nationality, issuing state, date of birth, sex and date of expiry.
- A **Data integrity** card appears when the chip carried a security object.
- A **Signature** card appears when the chip held a signature image and your
  iPhone could display it. Some passports store that image in a format iOS
  does not read, and then no card appears.
- Under **Additional details** are the extras some passports carry, among them
  place of birth, address, telephone, profession, issuing authority and date
  of issue.
- The card at the foot names the chip "ePassport" and its family
  "eMRTD (ISO/IEC 14443-4)". Other chips report more, as
  the [chip support matrix](../developer/chip-support-matrix.md) sets out.

## What the data integrity check tells you

Where the chip supplied a list of hashes, the app works out its own for the
data it read and compares the two. The **Data integrity** card then reads
"Likely untampered" or "Likely tampered", and the same words sit on the
booklet at the top of the screen. The card also lists the data groups it
checked, the hash it used, and any group that did not match.

The card states what the comparison is worth: "The data groups match the hash
list in the chip's security object. That object's own signature isn't
verified, so this is not proof the data is unaltered or a check of the
passport's authenticity."

:::important[Neither verdict says a passport is genuine]
Hex NFC does not check who signed the chip's data. "Likely untampered" means
the chip agrees with itself, which anyone who wrote the whole chip could
arrange.
:::

## If the details do not unlock the passport

The scan screen replaces its instruction, in red, with "Those details didn't
unlock the passport. Check them against the photo page and try again." What
you typed stays in the fields. Check each field against the photo page, then
tap **Read passport** and hold the passport again.

- Enter the passport number character for character, including letters and
  without spaces.
- Check the year on both dates. A date picker left in the wrong decade still
  reads correctly at a glance.
- Try once more with the details unchanged. The same message covers a read
  that broke off partway, which a steadier second tap often fixes.

If nothing at all happens while you hold the passport, the chip is not
answering. [If a tag does not scan or write](troubleshooting.md) covers that.
The first tap can instead read "Tag detected" and open the **Tag** screen. That
means your iPhone reached a chip but did not recognise it as a passport. Hex NFC
cannot read that chip as one. A Japanese transit card opens the **Transit card**
screen, and [Read a transit card](transit-cards.md) covers those.

## What the app keeps

Nothing. The three details unlock the chip for that one read. A note sits under
the fields. It says: "These details stay on your device, are used only for this
read, and are never stored or sent anywhere."

What the chip hands back is treated the same way. A passport read is never
added to your scan history, never exported and never sent anywhere. Tapping
**Close** drops the data with the screen. Seeing it again means reading the
passport again. The **Passport** screen carries the same note at its foot. It
reads: "Read from the chip and shown here for this session only: not saved,
not sent, and not verified for authenticity."

## See also

- [Read a transit card](transit-cards.md)
- [Privacy and your data](privacy.md)
- [Find a tag you scanned before](scan-history.md)
