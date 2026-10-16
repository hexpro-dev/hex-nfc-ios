---
title: If a tag does not scan or write
description: Work out why Hex NFC could not scan or write a tag, and what to do about the message you saw.
audience: user
pageKind: faq
navTitle: Troubleshooting
tags:
  - troubleshooting
---

Nearly every failed read is a tag that moved. Rest the top edge of your iPhone
flat on the tag, keep it still for about a second, then tap **Try again**.

Hex NFC names what went wrong in a sentence rather than showing a code. Find
the sentence you saw below. Directly under every failure message sits a closed
row labelled **Diagnostics**, with a chevron at its right. Tap the row and the
technical detail opens underneath it.

## Find your message

- [Timed out, lost the tag mid-read, or cancelled](#scan-stopped)
- [MIFARE Classic, no NFC on this device, a build not authorised, or an
  operation the tag does not support](#tag-not-readable)
- [Records too large, or the tag wrote back something different](#write-failed)
- [A different tag, after you typed a tag's ID](#different-tag)
- [A password check that did not finish](#password-check)
- [Something unexpected went wrong](#unexpected)

## Try these first

- Rest the top edge of your iPhone on the tag, not the middle of the back.
- Take your iPhone out of a metal case, and lift the tag off any metal surface.
- Keep the tag and your iPhone still together until the app answers.
- Try a second tag. When the second one reads, the first tag is what to look at.

## What does "Scan failed" mean? {#scan-failed}

"Scan failed" is the heading over a read the app could not finish. The sentence
under it names the reason, and the headings below are grouped by it.

::::steps
:::step[Open the diagnostics]
Tap **Diagnostics**, the row directly under the message. The detail opens
underneath, and the text is selectable so you can copy it out.
:::

:::step[Start a new scan]
Tap **Try again**. The scan screen opens a new session and waits with "Hold tag
against the top of your iPhone".
:::

:::step[Hold the tag still]
Rest the top edge of your iPhone flat on the tag and keep it there until the app
answers.
:::
::::

## Why did the scan stop part way? {#scan-stopped}

"The scan timed out. Hold the tag steady against the top of the phone and try
again. If one particular tag times out every time, it may be a MIFARE Classic,
which iPhone can't read (an iOS limitation, not a fault in the tag)."

iOS ended the session because no tag answered it for long enough. You see this
sentence when your iPhone had already found a tag on the same screen, for
example on the second hold of a protected tag, or when an earlier attempt on
that screen ended in an error. Move the top edge of your iPhone slowly over the
tag and leave it there.

When your iPhone has found no tag at all, the screen reads "No tag found"
instead, with **Try again** under it. It is not a failure, so there are no
diagnostics under it. The fix is the same: rest the top edge of your iPhone flat
on the tag and keep it still.

A tag that starts to answer and then stops gets a different sentence: "Lost the
tag mid-read. Keep it pressed against the top of the phone and try again." The
tag left the field part way through a command.

"Scan cancelled." means the scan was closed before it finished, either by you or
by the app. It appears once your iPhone has found a tag on the same screen, or
after an earlier attempt there ended in an error. Closing the iOS sheet before
any tag is found just closes it, with no message. A scan reads only, so nothing
on the tag changed.

## Why can my iPhone not read this tag at all? {#tag-not-readable}

Three messages say the read cannot happen at all, however the tag is held. A
fourth sits here too, and it is not a read failure.

"This looks like a MIFARE Classic tag. iPhone can detect it but can't read its
encrypted memory. IOS doesn't expose the MIFARE Classic keys any app would
need." The chip answered far enough for the app to recognise the family. It got
no further.

:::important[No app on an iPhone reads a MIFARE Classic]
iOS hands no app the keys that unlock that chip's memory, so there is no setting
in Hex NFC that changes the outcome. Use a tag from
[Tags that work with Hex NFC](tags-that-work.md) instead.
:::

"This device does not support NFC." The app could not open an NFC session on
this iPhone at all. An iPhone has no NFC switch to turn back on. No setting in
Hex NFC changes this. Holding the tag differently will not help.
[Common questions](faq.md) says what the app needs to run. If the message
appears on an iPhone that runs Hex NFC otherwise, open **Diagnostics** and copy
the text. Send it to the address under
[If you need more help](#if-you-need-more-help).

"This build isn't authorised for that tag type yet." Your copy of the app is
not registered to read that kind of tag. Nothing about the tag or the way you
hold it changes that. Check the App Store for an update to Hex NFC first. If
the message comes back, open **Diagnostics** and send the text on to the
address under [If you need more help](#if-you-need-more-help).

"This tag does not support that operation." is the message that is not about
reading. The tag read. What it will not do is the operation you asked for, by
the route you took. The tag info card names the chip. Where the chip reports
them, its **Supports** and **Features** rows say what it can do.

**Operations** > **Protect with password** covers NTAG213, NTAG215, NTAG216 and
MIFARE Ultralight EV1. An NTAG424 DNA, a MIFARE Ultralight C and an ICODE SLIX2
take the **Protection** card on the Tag screen instead. That route protects them
properly. [Protect a tag with a password](protect-a-tag.md) walks both routes.
[Tags that work with Hex NFC](tags-that-work.md) covers the chips the app
recognises. The [chip support matrix](../developer/chip-support-matrix.md) has
the full technical detail, chip by chip.

## What does "Write failed" mean? {#write-failed}

"Write failed" is the heading over a write, a read-back or a protection change
that did not finish. Three controls sit under it. **Diagnostics** holds the
detail, **Close** returns you to the editor, and **Try again** runs the write
again, keeping the password you typed. On a write started from the Tag screen
that turns protection on or off, the retry reads the tag's UID again. It asks
you to type it back a second time. Your consent to change a tag is not carried
across a failure. A preset written from **Library** is not confirmed that way:
whichever tag you present is the instruction, so its retry goes straight back
to one tap.

Two of the messages have a fix of their own.

"These records are too large for this tag." Your records need more room than the
chip's data area holds. Shorten or remove a record, or write to a tag with more
memory. [Record types](record-types.md) says how much room each kind of record
takes.

"The tag wrote back something different from what was sent. Try the write again."
The app read the tag back after writing and the bytes did not match what it had
sent. Tap **Try again** with the tag held still.

## Why was the tag refused after I typed its ID? {#different-tag}

::include[two-tap-confirmation]

"That's a different tag." means the tag you held is not the one the app
expected. The **Diagnostics** row names which tap raised the message, and which
tag was expected.

On the **Operations** screen it comes on the second tap. The tag you held is not
the one whose UID you typed. Hold the same tag again, or start over with the tag
you meant to change.

A protection change from the Tag screen can raise it on either tap. On the
second tap it means the same thing. On the first tap nothing has been typed yet.
There the tag you held is not the tag the editor was opened from. Hold that tag
instead.

On the **Operations** screen a failed operation shows the message, then
**Diagnostics** directly under it, then **Try again** below that. Three screens
replace that button because the password you typed is already committed to the
run: **Protect with password** and **Attempt limit** show **Start over**, and
**Remove password** shows **Enter a different password**. Each one hands the
form back, so the next attempt sends what you type next rather than the password
the tag has just refused.

## What if the password check does not finish? {#password-check}

"Couldn't check the password: the tag stopped answering. Hold it steady against
the top of the phone and try again." The tag went quiet while the app was
checking the password. Nothing was settled about it either way. The app is not
telling you the password is wrong. Hold the tag steady and run the operation
again. [Remove a tag's password](remove-password.md) covers the password that
genuinely no longer opens a tag.

## Why does a message say something unexpected went wrong? {#unexpected}

"Something unexpected went wrong." appears on the scan screen, the write screen
and the **Operations** screen. It shows when a failure is not one the app
recognises as a tag error. "Something unexpected happened. Try again." comes
from the NFC layer for the same reason.

Two more describe a tag answering in a shape the app did not expect:

- "The tag responded outside the expected protocol."
- "The tag responded with data this app could not parse."

All four have the same next move. Open **Diagnostics**, copy the text, then hold
the tag again. When the same message comes back for the same tag, those
diagnostics identify it.

## If you need more help {#if-you-need-more-help}

The app publishes one address, `support@hex.pro`, in the **Privacy Policy** and
the **Terms & Conditions**, both in **Settings** under **Legal**. Send the copied
diagnostics there, with your iPhone model and your iOS version, which the
iPhone's own Settings app shows under General, then About. If the tag read far
enough to show a tag info card, add the chip name from it. If it never read at
all, say so. Say which tags read and which do not.

Next, read [Scan a tag](scan-a-tag.md) for what a healthy read looks like, or
[Common questions](faq.md) for what the app needs to run at all.
