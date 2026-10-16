---
title: Limit wrong password tries
description: Set how many wrong passwords a protected tag will take before it stops accepting its password for good.
audience: user
pageKind: howto
navTitle: Attempt limit
tags:
  - protection
  - security
---

An attempt limit tells a password-protected tag how many wrong passwords to
take, and Hex NFC writes that number to the tag from your iPhone. Set it to 3,
and the tag accepts three wrong tries; the try after that stops it accepting its
password at all. From then on the protection can never be removed, and the
protected memory can never be rewritten. There is no way back.

Before you start:

- The tag has to be password-protected already.
- You need the password it holds now.
- The chip has to be an NTAG21x or a MIFARE Ultralight EV1, which is where this
  field lives.

To see what a chip carries, read
[Tags that work with Hex NFC](tags-that-work.md) or the
[chip support matrix](../developer/chip-support-matrix.md).

The limit is not part of the **Protection** card. It sits on the Operations
screen, under **Dangerous Actions**, because it is armed against one tag at a
time and cannot be undone.

::include[two-tap-confirmation]

The scan that opens the tag is not one of those two taps. Here you tap the tag
three times in all: once to scan it, then the operation's two taps.

:::warning[A wrong password can cost a try]
If the tag already carries a limit, the password you type here counts against it
when the tag refuses it. Hex NFC reports the limit a tag is set to, but no
command on these chips says how many tries have gone. Nothing tests a password
without spending one of those tries either. The app never shows a tag's password
back to you. No chip hands one out. The password to type is the one you kept
when you protected the tag.
:::

## Set the attempt limit

::::steps
:::step[Scan the tag]
In Hex NFC, on the home screen, tap **Scan**, then hold the tag against the top
of your iPhone. What the tag holds opens on the Tag screen. The card at the top
is headed with the chip's name. The **Protection** card sits directly under it,
above the records.

A tag whose password gates writing only scans like any other. Its **Protection**
card reads "Password · write-only".

A tag whose password also gates reading stops the scan instead. The scan screen
shows "Tag is protected" and asks for the password. Enter it, then tap **Unlock
& scan again**. The Tag screen opens after that, and its **Protection** card
reads "Password · read + write". That unlock presents the password to the tag,
so a wrong entry spends one of the tries this page is about.
[Scan a tag](scan-a-tag.md#unlock-a-protected-tag) covers the unlock in full.
:::

:::step[Open the attempt limit screen]
On the Tag screen, tap the menu button at the top right, beside **Write**, then tap
**Operations…**. On the Operations screen, tap **Attempt limit** in the
**Dangerous Actions** card.
:::

:::step[Enter the password the tag holds now]
Enter the tag's password in **Current password (4 bytes)**, as hex, with or
without `:` separators.
:::

:::step[Choose how many wrong tries to allow]
The row reads **Allow 3 wrong tries**, and its number changes as you press the
stepper beside it. Choose any number from 1 to 7. It starts at 3. The stepper
has no setting for none, so this screen can change the limit a tag carries but
never take it off. Removing the tag's password clears the limit with it, which
needs a password the tag still accepts.
:::

:::step[Tap Continue]
Tap **Continue**. The password field and the stepper stop taking changes, and
the screen asks for the first tap.
:::

:::step[Hold the tag for the operation's first tap]
Tap **Set the attempt limit**, then hold the tag against the top of your iPhone.
This tap reads the tag's UID and the limit the tag is already set to.

Closing the iOS sheet before you hold a tag takes you back to the stepper and
**Continue**, so you can pick a different limit. If the sheet closes by itself
with no tag against your iPhone, the screen reads "No tag found" with **Try
again** and **Start over**.
:::

:::step[Type the tag's UID]
Type the UID shown on the screen into the field beside it.
:::

:::step[Hold the same tag for the second tap]
Tap **Set the attempt limit**, then hold the tag against the top of your iPhone
again. The app writes the new limit and reads it back. The screen reports "This
tag is now set to allow 3 wrong tries."

Below that it adds "One more wrong try after that and it stops accepting its
password for good."
:::
::::

## What the app reports between the taps

The first tap reads the tag's own settings, so the screen says what the tag
carries before you type its UID. It reports one of three things:

- "This tag has no attempt limit set." No number of wrong tries can lock it.
- "This tag is already set to allow 3 wrong tries." The number is the one the tag
  holds, and the new limit replaces it.
- "This tag is read-protected, so the limit it holds now can't be read until its
  password is presented." There is nothing to report. The configuration pages
  are behind the password. The run carries on from here: type the UID, and the
  second tap presents the password and writes the new limit.

How many tries a tag has already spent is never reported, because no command on
these chips discloses it.

## If the tag has no password

An attempt limit guards a password, so the app refuses the operation on a tag
that has none. The refusal reads "This tag has no password set, so there is
nothing for an attempt limit to guard."

The refusal comes before anything is written. The tag is left exactly as it was.
Set a password first, as
[Protect a tag with a password](protect-a-tag.md) describes, then come back here.

## If the app cannot read the limit back

A tag that slips away mid-write gets the headline "Attempt limit written."

The explanation reads "The tag acknowledged the write, but this tap couldn't
read the byte back. Start the operation again: the first tap reports the limit
the tag is holding." The chip took the write. This tap could not prove what
landed.

The run has finished at that point, so the screen offers no retry. Go back to
the Operations screen and open **Attempt limit** again. Run it through: the
first tap of the new run reports the limit the tag is holding.

## If a password stops working afterwards

On a tag with a limit set, a password the tag refuses is reported as "The tag
refused that password. This tag has an attempt limit set, so it may be locked
out even if the password is right."

A check that never finished reads "That password didn't open the tag. This tag
has an attempt limit set, and every wrong try counts against it. Check the
password before trying again."

Both mean the same thing for your next move: find the right password before you
hold the tag again. A run that ends this way leaves **Start over** on the
screen, which hands the form back rather than sending the refused password a
second time. Once a tag has had more wrong tries than it allows, nothing opens
it, and its protected memory stays protected for good.

## See also

- [Remove a tag's password](remove-password.md)
- [Tag protection](tag-protection.md)
- [If a tag does not scan or write](troubleshooting.md)
