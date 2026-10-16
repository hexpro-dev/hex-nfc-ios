---
title: Erase or format a tag
description: Clear what a tag holds, or write the header a fresh chip needs before anything you write is readable.
audience: user
pageKind: howto
navTitle: Erase or format
tags:
  - writing
---

Hex NFC has two repairs for a tag that will not read, and they do opposite jobs. Erasing
writes an empty message over the tag's data area, so readers see a blank tag and the chip
stays writable. Formatting writes the Capability Container, the short header a reader looks
for before it reads anything else on the tag.

Before you start, scan the tag: on the Hex NFC home screen, tap **Scan**, then hold the tag
against the top of your iPhone. The **Tag** screen opens once the app has read it. It opens
for a tag that is not formatted or whose data will not read as well. A warning on the scan
screen is a diagnosis rather than a dead end. On the **Tag** screen, tap the
menu button at the top right, beside **Write**, then tap **Operations…**. Both repairs
sit under **Dangerous Actions** at the bottom of the **Operations** screen, where every
operation confirms the tag before it changes it:

::include[two-tap-confirmation]

## Which repair the tag needs

The app names the fault on the screen where you meet it, and the two names take opposite
repairs.

- Format the tag when the scan screen reads "This tag isn't formatted yet", or the **Tag**
  screen reads "Not formatted". The tag has no Capability Container, so nothing you write to
  it is readable.
- Erase the tag when the scan screen reads "This tag's data won't read", or the **Tag**
  screen reads "Data won't read". The Capability Container is already in place, so a format
  has nothing there to repair.

On a tag that still accepts writes, the **Tag** screen also shows a warning you can tap. It
reads "This tag isn't formatted" or "This tag's data won't read". Tapping it opens
**Operations**. A permanently locked tag shows the status but no warning, because both
repairs are writes.

## Erase a tag

An erase clears the tag's records and leaves the chip writable. It also rebuilds a data area
that has stopped reading.

::::steps
:::step[Open the erase screen]
On the **Operations** screen, tap **Erase**. The screen that opens says what the erase
writes, and warns you before anything reaches the tag.
:::

:::step[Start the erase]
Tap **Erase tag**. Your iPhone asks you for the tag.
:::

:::step[Hold the tag against your iPhone]
Rest the top of your iPhone on the tag. The screen reads "Tap 1 of 2. Hold the tag to
identify it.", then shows the tag's UID.
:::

:::step[Type the UID back]
The screen reads "Type this tag's UID to confirm." and puts the UID beside an empty field.
Enter those same characters in the field, with no colons between them and in either case,
then tap **Erase tag**.
:::

:::step[Hold the tag a second time]
Hold the tag against the top of your iPhone again. The screen reads "Tag erased." once the
app has read the empty message back off the tag.
:::
::::

An erase ends one of two ways. It reports "Tag erased." once the empty message reads back.
Otherwise it reports an error naming the fault, with the details under it for a bug report.
[If a tag does not scan or write](troubleshooting.md) covers what to try next.

:::note
An erase replaces the tag's message rather than wiping its memory. On NTAG and MIFARE
Ultralight tags, the chips most stickers and cards carry, the empty message is one page
long. The bytes of the old message stay where they were until something writes over them.
Write a message of your own over a tag you are handing on.
:::

## Format a tag

Use a format on a fresh chip that was not shipped pre-formatted. On NTAG and MIFARE
Ultralight tags a format writes the Capability Container only and does not touch the data
area. On ISO 15693 tags such as ICODE SLIX2 it also writes an empty message into the first
data block. On those tags the message the tag was carrying is gone.

::::steps
:::step[Open the format screen]
On the **Operations** screen, tap **Format**.
:::

:::step[Start the format]
Tap **Format tag**. Your iPhone asks you for the tag.
:::

:::step[Hold the tag against your iPhone]
Rest the top of your iPhone on the tag. The screen reads "Tap 1 of 2. Hold the tag to
identify it.", then shows the tag's UID.
:::

:::step[Type the UID back]
The screen reads "Type this tag's UID to confirm." and puts the UID beside an empty field.
Enter those same characters in the field, with no colons between them and in either case,
then tap **Format tag**.
:::

:::step[Hold the tag a second time]
Hold the tag against the top of your iPhone again. The screen reads "Tag formatted." once
the app has read the header back.
:::
::::

On an NTAG or MIFARE Ultralight tag, a format ends in one of three reports:

- "Tag formatted." means the header is written, read back and in place, and the tag is ready
  to take a message.
- "Already formatted: nothing written." means the tag was carrying the right header, so
  nothing reached it. The app sends you to **Erase**, because a tag that still will not read
  has its fault in the data area.
- "This tag already has a different Capability Container." means the header on the tag does
  not match the chip the app identified. Nothing was written.

An ISO 15693 tag reports "Tag formatted." every time, because its Capability Container block
stays rewritable and the app writes it on every run.

:::warning
On NTAG and MIFARE Ultralight tags, the Capability Container gets one write for the life of
the tag and can never be corrected. So the app reads that page first and writes only while
it is blank. It refuses a chip it could not identify rather than guessing at a header. The
chip name the app read sits at the top of the **Tag** screen, and
[Tags that work with Hex NFC](tags-that-work.md) says what each one takes.
:::

## Clear a tag from the record list

A tag can also be cleared from the **Tag** screen, without going through **Operations**.
A clear write carries no protection change, so it holds the tag once and asks for no typed
UID. A write that also arms or removes a password holds the tag twice and asks for the UID.
That is the same gate as an operation under **Dangerous Actions**.

::::steps
:::step[Delete every record]
On the **Tag** screen, swipe a record left and tap **Delete**, until the screen reads
"No records left". The removals are not on the tag yet.
:::

:::step[Write the empty result]
The screen now reads "You've removed every record. Write to clear the tag, or add one
back." Below that line, above **Add record**, tap **Write to clear tag**. Your iPhone asks
you for the tag.
:::

:::step[Hold the tag against your iPhone]
Rest the top of your iPhone on the tag and keep it there until the write finishes.
:::
::::

## See also

- [Scan a tag](scan-a-tag.md)
- [Edit a tag's records](edit-records.md)
- [Write a link to a tag](write-a-link.md)
- [If a tag does not scan or write](troubleshooting.md)
- [Tags that work with Hex NFC](tags-that-work.md)
