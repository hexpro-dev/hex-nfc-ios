---
title: Tag protection
description: What a password or a key on a tag protects, which chips can carry one, and why a lost password cannot be recovered.
audience: user
pageKind: article
navTitle: How protection works
tags:
  - protection
  - security
---

A tag stuck to a poster answers every phone that comes near it, and a blank chip
lets any of them overwrite what you wrote. Protection is the chip's own answer
to that. The secret sits in the chip's configuration pages, and the chip refuses
a change until the secret is presented. Hex NFC can set that secret from your
iPhone, present it on a later scan and take it off again. The gate belongs to
the tag, not to the app.

## What a protected tag refuses

A gate covers writing by default. A tag protected that way still reads out to
any phone, which is what you want for a poster or a business card. People tap
it and get the link, and nobody else changes it. Two chip families can extend
the gate to reading as well, which changes what any later scan can do.

[Scan a tag](scan-a-tag.md). On a chip that supports protection, the Tag screen
opens carrying two cards. The tag info card names the chip in your hand.
**Protection** carries the gate. Tap **Protection** and the sheet of the same
name opens with the settings on it.
[Protect a tag with a password](protect-a-tag.md) walks through setting one.

The read gate belongs to two families. On an NTAG213, NTAG215, NTAG216 or
MIFARE Ultralight EV1, the setting is **Also require password to read**, under
**Advanced**. Turning it on extends the gate to reading. The sheet puts the
consequence plainly: "Read-protected tags can't be read back, including
verification, without the password." On an NTAG424 DNA the setting is **Also
require key to read**. It sits beside the key itself rather than under
**Advanced**. An ICODE SLIX2 and a MIFARE Ultralight C have no such setting:
their secret covers writing, and reads stay open.

The **Protection** card on the Tag screen carries a one-line summary of what
the scan found. "Off" means the scan established that no secret is set.
"Password · write-only" means writes are gated and reads are open, and
"Password · read + write" means both are. The third answer is "Unknown ·
couldn't read this tag's protection", which is not the same as "Off": the tag
would not say. Scan the tag again: a tap that ends early leaves the app without
an answer. A chip whose protection the app cannot interrogate reports the same
thing every time. Writing to such a tag is still safe to try. A gated tag
refuses the write, and the write screen asks for the secret instead of changing
anything. Scanning a read-protected tag with no password in hand gives "This
tag needs its password before it will show anything."

## Which chips can carry a secret

The secret's shape follows the chip, and so does the field the app asks for it
in. That field is the unlock prompt, and it turns up when a tag refuses you. A
protected tag that will not answer a scan puts "Tag is protected" above the
field, with **Unlock & scan again** below it. A write to a protected tag asks
the same way before it goes ahead.

:::table[What each chip family's secret looks like]
| Chip | The secret | The field in the unlock prompt |
| --- | --- | --- |
| NTAG213, NTAG215, NTAG216, MIFARE Ultralight EV1 | A 4-byte password | **Tag password (4 bytes)** |
| NTAG424 DNA | A 16-byte AES key | **Tag key (16-byte AES)** |
| MIFARE Ultralight C | A 16-byte 3DES key, writes only | **Tag key (16-byte 3DES)** |
| ICODE SLIX2 | A 4-byte password, writes only | **Tag password (4 bytes)** |
:::

Each of those fields takes the secret as hex, two characters to a byte: 8
characters for a 4-byte password, 32 for a 16-byte key. Spaces or colons
between the bytes are accepted, and so is either case, so `FF FF FF FF` and
`ffffffff` are one password typed two ways. The field says "OK" once the right
number of bytes is in it, and until then it repeats how many it wants.

A scanned chip with no password machinery at all gets no **Protection** card,
unless the scan found lock bits burned. A lock verdict brings the card back to
carry it. It reads "Permanently locked", "Partly locked · some of this tag is
read-only for good" or "Lock written · scan again to confirm". On a locked tag
the card reports without opening. The card also stands on the Tag screen
before any tag has been scanned, which is how a preset picks up protection
settings. Which chip you are holding is still on the tag info card.
[Tags that work with Hex NFC](tags-that-work.md) covers the rest of what each
one can do. The full per-chip picture is in the
[chip support matrix](../developer/chip-support-matrix.md).

A read gate on a MIFARE Ultralight C hides the very pages the app identifies
the chip from. A tag armed that way could never be recognised again, let alone
unlocked. The app says the write-only limit in as many words: "Hex NFC can
protect this tag against writing, but not against reading."

## Why a lost password is final

Nothing about a tag's secret is recoverable from the outside. For a 4-byte
password the app's own warning is the whole story: "Lose the password and the
protected memory is gone. There is no recovery." The key-bearing chips say the
same thing at more length, "Lose this key and you can never rewrite this tag.
There is no factory reset for an NTAG424. Store it safely." and "Lose this key
and the protected memory can never be rewritten. Ultralight C has no factory
reset. Store it safely." A SLIX2 password can only be reset by presenting the
current one, so losing it ends the same way.

Hex NFC keeps a secret you save with a preset in one place only: "The secret is
stored only on this device (Keychain). It never syncs or travels in an export."
So a preset shared with someone else, or restored on another iPhone, arrives
without the password. [Save a tag as a preset](presets.md) says what that means
for reusing one across a stack of tags. Keep your own copy somewhere you trust.

## Changing protection takes two taps

::include[two-tap-confirmation]

You do not have to go and find that UID. The app shows it beside the field,
under "Type this tag's UID to confirm.", as a plain run of hexadecimal
characters with no separators. Either case is accepted. Setting a secret and
taking one off are both changes to the tag, so both go through that
confirmation.

## See also

- [Scan a tag](scan-a-tag.md)
- [Protect a tag with a password](protect-a-tag.md)
- [Remove a tag's password](remove-password.md)
- [Limit wrong password tries](attempt-limit.md)
- [Lock a tag permanently](permanent-lock.md)
