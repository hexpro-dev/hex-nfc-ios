---
title: Chip support matrix
description: Which NFC chips Hex NFC can read, write, password-protect and lock on iPhone, and how much of that has been confirmed on real tags.
audience: developer
tags:
  - chips
---

This page sets out which NFC chips Hex NFC can read, write, password-protect and
lock on an iPhone, and how much of that has been confirmed on real tags. If a
chip you rely on is missing, or behaves differently from what the page says,
write to [support@hex.pro](mailto:support@hex.pro) with the chip name and what
happened.

## Legend

| Status | Meaning |
|---|---|
| ✅ | Works, and confirmed on real tags |
| ⚠️ | Implemented, with a caveat in the row's notes or in the text around its table (often that it has not been confirmed on a real tag) |
| ❌ | The app refuses or cannot do this |
| — | Not applicable |

NTAG 210µ, NTAG213, NTAG216, NTAG424 DNA, MIFARE Ultralight EV1 128-byte, MIFARE
Ultralight C, ICODE SLIX2 and MIFARE DESFire EV3 were tested on physical tags in
August 2026, and the transit reader has been confirmed on real Suica and PASMO
cards. The protect and remove sequences were reworked for every family in
September 2026, and NTAG213 is the only chip to have run the reworked protection
code on a real tag, for write protection alone, so no Password cell is ✅. No
memory dump from a real tag is on record, so no Mem dump cell is ✅. The Memory
dump operation itself has been run only against the NTAG213 and NTAG215
simulators. Some of the tested tags do not behave like NXP parts: the Ultralight
C tags repeat UID bytes from tag to tag, and an NTAG216 returned a short
originality signature, so results on those two chips may not carry over to
genuine NXP silicon.

A row marked simulator only rests on the protocol-level chip simulators, and a
row marked untested has not been run against a real tag or, where the note says
so, a simulator either. Treat their ⚠️ cells as expected to work rather than
lab-confirmed.

The **Lock** column is verified differently: locking is one-way, so it is
exercised on sacrificial tags in a separate pass rather than as part of a chip's
validation. In August 2026 that pass covered NTAG 210µ, NTAG213, NTAG216, MIFARE
Ultralight EV1 128-byte, MIFARE Ultralight C and ICODE SLIX2. The Type 2 lock
sequence was reworked in September 2026 and has since been re-run on NTAG213 and
NTAG 210µ. On NTAG216, Ultralight EV1 128-byte and Ultralight C the confirmation
predates that rework, so their Lock cells are ⚠️. The ICODE SLIX2 lock still
sends the commands that were confirmed, and its cell is ⚠️ only for the
identification fallback described in its row. Every other ⚠️ in the Lock column
rests on the chip simulators, except NTAG213 TT, where only the lock-bit mask is
tested and no simulator has run a permanent lock.

## Type 2 (ISO 14443-3A)

| Chip | Read | Write | Password | Lock | Mem dump | Notes |
|---|---|---|---|---|---|---|
| NTAG 210µ | ✅ | ✅ | — | ✅ | ⚠️ | 48 bytes user memory (64 total). No password support: the "micro" die has no configuration pages, so there is nowhere to store one. Also has no FAST_READ or counter. Ships NDEF-formatted |
| NTAG213 | ✅ | ✅ | ⚠️ | ✅ | ⚠️ | 144 bytes user memory. Write protection confirmed on real tags after the September 2026 rework; read protection has not been run on the reworked code |
| NTAG215 | ⚠️ | ⚠️ | ⚠️ | ⚠️ | ⚠️ | 504 bytes user memory. Simulator only: no NTAG215 has been tested on a real tag |
| NTAG216 | ✅ | ✅ | ⚠️ | ⚠️ | ⚠️ | 888 bytes user memory. Password and lock last confirmed on real tags before the September 2026 rework, through a test harness in a debug build |
| NTAG213 TT | ⚠️ | ⚠️ | ⚠️ | ⚠️ | ⚠️ | 144 bytes user memory. Simulator only. Tag tamper status shows on the tag info card in the tag editor, and as an Advanced console preset |
| MIFARE Ultralight EV1 48-byte | ⚠️ | ⚠️ | ⚠️ | ⚠️ | ⚠️ | 48 bytes user memory. Simulator only. Ships unformatted: run Format before writing |
| MIFARE Ultralight EV1 128-byte | ✅ | ✅ | ⚠️ | ⚠️ | ⚠️ | 128 bytes user memory. Ships unformatted: run Format before writing. Password and lock last confirmed on real tags before the September 2026 rework, through a test harness in a debug build |
| MIFARE Ultralight C | ✅ | ✅ | ⚠️ | ⚠️ | ⚠️ | 144 bytes user memory. Protected by a 16-byte 2-key 3DES key with a mutual handshake, not a PWD/PACK password. Key protection and lock last confirmed on real tags before the September 2026 rework, through a test harness in a debug build rather than through the Protection card or Operations. In the current code a write that applies the key, from the tag editor or from a saved preset, presents that key before it reads the tag's protection state, so on a tag that does not already hold it the chip refuses the handshake and stops answering. On an iPhone the write then stops at the unlock prompt, which reports that the key did not unlock the tag, and nothing is written or protected. That comes from reading the code and has not been run on a real tag. The chip simulator also writes nothing, but it ends the write with a lost-tag error, because its page reads do not model a chip that has stopped answering. Ships unformatted: run Format before writing. Has no GET_VERSION, FAST_READ, READ_CNT or originality signature (its 16-bit counter sits at page 29h and is read with an ordinary READ, so the app's counter feature does not apply). A memory dump stops at page 2Bh, because the chip does not decode reads of its key pages |
| NTAG210 / NTAG212 | ⚠️ | ⚠️ | ❌ | ❌ | ❌ | The app does not name the model: the tag info card shows what the chip reported about itself rather than a guess. We would rather say we don't know than drive the wrong page map. An unrecognised chip is limited to NDEF read, NDEF write and raw commands, so password protection, Permanent lock, Memory dump and Format are refused, and writes go through iOS's own NDEF writer rather than the app's page writer. iOS's writer is the path the app stopped using for recognised Type 2 tags, because it fails on tags pre-formatted with a Lock Control TLV, so a write to one of these chips may fail if the tag carries that TLV. Untested on real tags |
| NTAG213F / NTAG216F | ⚠️ | ⚠️ | ❌ | ❌ | ❌ | As above. The field-detect variants are left unrecognised pending verification on real silicon |
| EM Microelectronic V10 / V11 / V16 | ⚠️ | ⚠️ | ❌ | ❌ | ❌ | The app has profiles for all three, but its production identification never selects them, so a real EM tag is unrecognised and gets the same treatment as NTAG210 above. Reaching that point is not certain: if the tag refuses GET_VERSION, the app polls again to wake it and then reads page 28h, past the end of a 16-page chip, and a tag that refuses that read stops answering for the rest of the tap. No real EM tag has been tested, and the EM simulators use byte values they define themselves, not datasheet values. Personalisation chains for all three are in the Advanced console; the Capability Container size they write comes from the app's memory layout for the chip, not from a datasheet |
| MIFARE Classic 1K/4K | ❌ | ❌ | — | ❌ | ❌ | iOS does not expose MIFARE Classic to apps (no CRYPTO1 access), so the tag is unreadable on any iPhone. If iOS hands the tag over and the connection fails, the app says it looks like MIFARE Classic; if the scan times out instead, the timeout message names MIFARE Classic as a likely cause |

For Type 2 chips, **Password** is the NTAG21x scheme (a 4-byte PWD and a 2-byte
PACK, plus an AUTH0 page threshold and the PROT bit), which Protect with password
in Operations and the Protection card in the tag editor both set, to gate writes
only or reads and writes. The app recognises a read gate only when it starts at
page 4, which is where Operations always starts it and where the Protection card
starts it unless a custom start page is set. It detects read protection from how
a read of pages 3 to 6 answers, so a read gate that starts at any other page
inside the chip's memory, set with the Protection card's custom start page,
leaves the app unable to unlock or remove it. **Lock** is the irreversible
static/dynamic lock-byte burn (Permanent lock). **Mem dump** is Operations >
Memory dump, which runs on Type 2 chips only and saves every page the chip will
decode to a `.bin` file. For MIFARE Ultralight C, **Password** means the chip's
own 3DES scheme: a 16-byte key programmed into pages 2Ch to 2Fh and gated by
AUTH0, which the Protection card in the tag editor sets as a write gate only
(see the row's notes: in the current code that write fails on a tag that does
not already hold the key). A read gate on this chip would cover the pages the
app reads to recognise it, so the app does not offer one. The key can be
generated, pasted or derived from a passphrase.

## Type 5 (ISO 15693)

**SLIX2 password protection goes through ISO 15693 Selected mode.** Setting a
SLIX2 password needs `SET_PASSWORD`, which the chip accepts only in Addressed
or Selected mode: unaddressed, the tag silently ignores the command, and the
NFC daemon refuses an explicit Address flag before transmission, through both
`customCommand` and the raw `sendRequest` API. The route that works (confirmed
on real silicon on 7 August 2026) is Selected mode:
`NFCISO15693Tag.select(requestFlags:)` puts the tag in the Selected state, after
which the password commands are sent with the Select flag and no UID. The full
cycle (protect a tag, verify that the protection is enforced, then remove it)
was validated on hardware in August 2026. The protect and remove sequence has
since been reworked, and the reworked version has not yet been run on a real
tag.

| Chip | Read | Write | Password | Lock | Mem dump | Notes |
|---|---|---|---|---|---|---|
| NXP ICODE SLIX2 | ✅ | ✅ | ⚠️ | ⚠️ | ❌ | Ships unformatted: run Format before writing. Write password only, via Selected mode (see above), last confirmed on real tags before the September 2026 rework, through a test harness in a debug build rather than through the Protection card. In the current code a write that applies the password, from the tag editor or from a saved preset, presents the new password before it reads the tag's protection state, and a SLIX2 that does not hold that password executes nothing further until it leaves the field. The write stops at the unlock prompt, which reports that the password did not unlock the tag, and nothing is written. That is what the chip simulator does; it has not been run on a real tag. Recognised by its 80-block memory. In a session where the tag does not answer Get System Information it is treated as a 28-block SLIX: protection is not offered, Format writes a Capability Container for 28 blocks, and Permanent lock locks blocks 0 to 27 only and still reports success |
| NXP ICODE SLIX (28 blocks) | ⚠️ | ⚠️ | ❌ | ⚠️ | ❌ | Ships unformatted: run Format before writing. Every NXP ISO 15693 tag that does not report 80 blocks gets this profile, whatever its size. A 28-block ICODE cannot be told apart from SLI, SLIX-S or SLIX-L, so the app offers none of them protection. Simulator only, apart from identification on a real SLIX |
| ST M24LR | ⚠️ | ⚠️ | ❌ | ❌ | ❌ | Gets the generic ISO 15693 profile, like every non-NXP ISO 15693 tag. Untested: no real tag and no simulator |

For ICODE chips, **Password** is the SLIX2 write password, set from the
Protection card in the tag editor, subject to the limitation in the SLIX2 row.
Reads stay open: a SLIX2 read gate is privacy mode, and a tag in privacy mode
answers no inventory, so an iPhone could never find it again to remove the gate.
**Lock** is `LOCK_BLOCK` on every block of the geometry the app identified in
that session (the block count the tag reported, or 28 blocks when it did not
answer Get System Information), skipping blocks that are already locked and, on
a SLIX2, the counter block the chip will not lock. Memory dump does not run on
ISO 15693 tags.

## Type 3 (FeliCa)

| Chip | Read | Write | Notes |
|---|---|---|---|
| FeliCa Lite-S | ❌ | ❌ | The app declares only system code `0003` and a Lite-S answers to `88B4`, so iOS should never deliver one to the app. Untested: no Lite-S tag has been tried |
| Suica / PASMO / ICOCA and the rest of the `0003` family | ✅ | ❌ | Read-only: balance and the 20 most recent transactions, shown in a transit view that offers no write. Confirmed on real Suica and PASMO cards |
| iD / QUICPay | — | — | Payment services the app has no reader for; out of scope |

## Type 4 (ISO 14443-4)

| Chip | Read | Write | Password | Lock | Mem dump | Notes |
|---|---|---|---|---|---|---|
| NTAG424 DNA | ✅ | ✅ | ⚠️ | ❌ | ❌ | Key protection last confirmed on real tags before the September 2026 rework. No permanent lock and no memory dump: the chip keeps its data in files addressed by APDU, not in pages |
| MIFARE DESFire EV1 / EV2 / EV3 | ⚠️ | ⚠️ | ❌ | ❌ | ❌ | Identification (generation and storage size) and raw commands in the Advanced console. DESFire keeps data in key-protected applications rather than a blind-readable NDEF area, so the app declares no NDEF read or write for it. A scan still asks iOS for an NDEF message, and a write is not refused either: it is handed to iOS's NDEF writer. Only a card carrying an NDEF application can answer either, and none of the cards tested carried one. No write to a DESFire card has been tested. Confirmed on real EV3 cards; EV1 and EV2 have neither a real-card test nor a simulator |

For NTAG424 DNA, **Password** means the chip's own AES-128 authentication, not
the Type 2 PWD/PACK scheme: the Protection card in the tag editor takes a 16-byte
key, applies it with the next write, and can gate reads as well as writes.

## Hardware reliability

Hex NFC requires iOS 17, so it does not run on iPhone X or earlier. No iPhone
generation has been tested against another, so there are no per-model
reliability figures to publish.

The code treats ISO 15693 as an unreliable transport: identification falls back
to the catalogue profile when a tag does not answer Get System Information, and
permanent lock checks a block's security status before it believes an error
reply. When a scan fails, the scan screen says so and offers a retry.
