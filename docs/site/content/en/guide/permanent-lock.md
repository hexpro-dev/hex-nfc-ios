---
title: Lock a tag permanently
description: Make a tag read-only for the rest of its life, and what the app does to stop you locking the wrong one.
audience: user
pageKind: howto
navTitle: Permanent lock
tags:
  - protection
  - writing
---

Hex NFC can lock a tag permanently from your iPhone by setting the lock bits on
the chip itself. The tag keeps the records it holds, and no record or formatting
can ever be written to it again. Reading is unaffected, so any phone can still
read the tag.

Two things decide whether a tag can be locked, and a scan shows you both. On the
**Tag** screen, the card at the top is headed with the chip's name. It carries a
**Supports** row. "Lock" appears in that row only on a chip this app can lock.
Under it, the **Protection** card says what is protecting the tag now. "Off"
means nothing is, and the lock can go ahead. A chip that takes no password has
no **Protection** card at all, and nothing on it can block a lock.

A summary naming a password or a key, such as "Password · write-only", means
protection is switched on. A tag in that state does not get locked. How the app
says so depends on the chip.

On an NTAG or a MIFARE Ultralight EV1, Hex NFC checks before it writes anything.
It answers "This tag is password protected, so it cannot be permanently locked.
Remove the password first, then lock it." On a MIFARE Ultralight C or an ICODE
SLIX2, the app starts the lock. The summary on those two chips names a 3DES key
or a password. The tag's own gate refuses the first write. That refusal comes
back as "Nothing was locked." Nothing is burned either way, so the tap costs the
tag nothing. Take the password or the key off first: see
[Remove a tag's password](remove-password.md).

What blocks the lock is protection being switched on, not the password itself. A
password that is stored on a tag but no longer gates anything reads as "Off" on
the **Protection** card of a fresh scan. A tag in that state can be locked.

:::warning[A locked tag cannot be unlocked]
No password, no other app and no later tap reverses a permanent lock. Lock a tag
only once what it holds is final.
:::

## Lock a tag permanently

::include[two-tap-confirmation]

::::steps
:::step[Scan the tag you want to lock]
In Hex NFC, on the Hex NFC home screen, tap **Scan**, then hold the tag against
the top of your iPhone. The **Tag** screen opens and shows what the tag holds.
See [Scan a tag](scan-a-tag.md).
:::

:::step[Check the tag can be locked]
On the Tag screen, look for "Lock" in the **Supports** row of the tag info card,
and for the **Protection** card reading "Off". A chip that takes no password
shows no **Protection** card, which is also fine.
:::

:::step[Open the Operations screen]
On the Tag screen, tap the menu button at the top right, beside
**Write**, then tap **Operations…**.
:::

:::step[Choose Permanent lock]
Scroll to **Dangerous Actions**, then tap **Permanent lock**. The screen that
opens says what the lock costs and what it cannot undo. The tile is there for
every tag, including chips that have no lock bits. The app checks the chip only
on the second tap. On a chip that cannot be locked, it answers "This tag does
not support that operation." once you have typed the UID. Nothing is written.
:::

:::step[Hold the tag for the first tap]
Read the warning, then tap **Permanently lock this tag**. The screen reads "Tap
1 of 2. Hold the tag to identify it.", so hold the tag against the top of your
iPhone until the sheet closes.
:::

:::step[Type the tag's UID]
The tag's UID appears beside an empty field, under "Type this tag's UID to
confirm.". It is shown in capitals with no colons or spaces, and all of it is
typed. A UID the tag info card shows as `04:BA:4A:92:1B:21:90` appears here as
`04BA4A921B2190`. Capitals and lower case both match, and a space before or
after what you type is ignored. The button stays dimmed until what you type
matches.
:::

:::step[Hold the tag for the second tap]
Tap **Permanently lock this tag** again, then hold the tag against the top of
your iPhone. The screen reads "Tap 2 of 2. Hold the same tag again." while it
waits, and reports the result when the tag comes away.
:::
::::

## What the app says when the lock lands

"Tag permanently locked." is the result you want. The app asked the tag to
accept one more write after setting the bits, the tag refused, and that refusal
is the proof.

"Lock written." means the bits went on and this tap could not witness them.
Some chips only apply their lock bits the next time the tag wakes up. The app
adds "This chip's lock bits only take effect at the next tap, so it can't be
checked in this session. Scan the tag again to confirm it now refuses writes."
Scan the tag once more and read the verdict off the **Protection** card.

On the **Tag** screen, **Protection** reads "Permanently locked" for a tag the
app has read back as locked. Under that sits "Records and formatting can no
longer be written." Until that confirming scan it reads
"Lock written · scan again to confirm" instead. **Write** is unavailable on a
tag read back as locked.

A password stored on the tag survives the lock, and the card then reads
"Permanently locked · password still set". The line underneath says whether that
password can still be taken off. Which chips can be locked at all is covered in
[Tags that work with Hex NFC](tags-that-work.md).

## If the lock did not finish

A lock runs in stages. A run that stops partway leaves the tag in a state the
app names rather than calling it a failure.

- "Nothing was locked." The chip refused every stage and said so. Nothing
  burned, and the tag is exactly as it was, so a second run costs it nothing.
  Scan the tag again and check the two things a lock needs. The **Protection**
  card reads "Off", or a chip that takes no password shows no **Protection**
  card at all. "Lock" appears in the **Supports** row of the tag info card. On a
  MIFARE Ultralight C or an ICODE SLIX2, this message is what protection looks
  like. Take the key or the password off, then run the lock again.
- "This tag is now partly locked, and that cannot be undone. Some of its memory
  is read-only for good; the rest was refused and is still writable." Part of
  the chip is spent. No second run completes the rest. Back on the Tag screen,
  the **Protection** card reads "Partly locked · some of this tag is read-only
  for good". A tag that still holds a password reads
  "Partly locked · password still set" instead. On an NTAG or a MIFARE
  Ultralight, a fresh scan says the same again, because the app reads those lock
  bytes back. It does not re-read an ICODE SLIX2's per-block locks at scan time,
  so a fresh scan of one says nothing about the partial lock. On that chip the
  result at the end of the run is the only record you get.
- "The tag stopped answering during a lock that cannot be undone, so this app
  cannot say whether any of its memory is now read-only. Treat this tag as one
  that may be locked." The tag came away mid-write. Scan it again and read the
  **Protection** card before you use the tag for anything.
- "Part of this tag is now read-only for good, and that cannot be undone. The
  tag stopped answering before the rest could be confirmed, so the rest may be
  locked as well." One stage is confirmed. The other is unknown. Scan the tag
  again, and treat it as locked.

## See also

- [Tag protection](tag-protection.md)
- [Erase or format a tag](erase-or-format.md)
- [If a tag does not scan or write](troubleshooting.md)
