---
title: Send a raw command to a tag
description: Identify a chip, run a command preset and read what the tag sends back, in the Hex NFC Advanced console.
audience: user
pageKind: howto
navTitle: Advanced console
tags:
  - chips
---

The Advanced console in Hex NFC sends bytes from your iPhone straight to a tag.
It prints the command that went out, the answer that came in, and the time on
each. Open it when you want the frames themselves rather than a summary of them.

Before you start, have the tag to hand and have the datasheet for its chip open.
The datasheet is the chip maker's own document for that chip. It is published on
the maker's website under the chip's name, and the identify step below reports
that name. No page in this guide reproduces one, and the console sends what you
type whether or not you have read it.

The console fills one screen, and every control this page names is on it. At the
top sit the status chip with **Identify** beside it and the **Skip
identification** switch. Then come the **Command** field with the **Run** button
next to it, and the switch between **This run** and **All NFC traffic**. The
scrollback follows, and at the foot sits **Presets**, with **Search** above the
preset rows.

## Identify the chip

::::steps
:::step[Open Hex NFC]
Open Hex NFC. The Hex NFC home screen appears.
:::

:::step[Open the console]
On the home screen, tap **Advanced**, the last of the four tiles, under the
words "Raw command console". The console opens, and its empty scrollback reads
"Console idle. Tap a preset on the left, or type a sequence and Run." The
preset list sits at the foot of the screen. It is not to the left.
:::

:::step[Start the identify scan]
Tap **Identify**, the capsule to the right of the status chip. The scrollback
adds "Identifying tag…", and the iOS scan sheet appears with
"Hold tag to identify."
:::

:::step[Hold the tag against your iPhone]
Rest the top edge of your iPhone flat against the tag and keep it still. The
scrollback names the chip and the tag's UID, and the chip's name appears
beside **Presets**. The line reads
"Identified: NTAG213 · 04:BA:4A:92:1B:21:90".
:::
::::

An identified chip re-orders the preset library. Presets written for that chip
lead the list. Below them sit the ones that still apply to it:

- presets written for the whole chip type
- presets for a sibling chip in the same line, such as an NTAG215 preset on an
  NTAG216

Neither kind dims. A sibling's bytes can still address the wrong page on your
chip, so read them in **Command** first. A preset dims only when it is for a
different chip line, or for a different kind of tag altogether. A dimmed preset
still loads into **Command** when you tap it. To forget the chip, tap its name
beside **Presets**, and the list returns to its usual order.

When the app cannot name the chip, the console says
"Tag connected but the chip is unknown · 04:BA:4A:92:1B:21:90". It then prints
what the tag said about itself. The first line reads something like
"Reported: NXP · NTAG · 128-256 bytes · v1.0". That line carries the chip
maker, the product family, the memory size the chip declares and its product
version.
The second line is the raw bytes the first was read from, such as
"GET_VERSION: 00:04:04:02:01:00:0F:03". Tap a line to copy it. A "Copied" pill
appears for about a second, and the bytes are on the clipboard for a bug report.

## What the presets hold

A preset under **Presets** is a saved command sequence that the app ships with.
Each row carries three things and nothing else: the preset's name, a badge
naming the chip family it was written for, and the bytes themselves. Some of
them read a tag, and others write to it, including pages a chip accepts a
write to only once.

There is no description behind a row, so the bytes are the only account of
what a preset does. Read them in **Command** against the datasheet for your
chip before you run anything. On the Type-2 chips most stickers and cards
carry, a command that starts `30` or `3A` reads, and one that starts `A2`
writes. To see the console working without changing a tag, start with the row
named **Read 16 bytes**, whose bytes are `30:00`.

## Run a command

::::steps
:::step[Load a preset]
Tap a preset in the list under **Presets**. Its bytes go into **Command** and
the console records the name of the preset you loaded. Nothing has been sent.
:::

:::step[Check what will be sent]
Read the sequence in **Command** and edit it if you need to. Each pair of hex
digits is one byte, colons separate the bytes within a command, and a comma
separates one command from the next. An empty field shows the sample
"21:60:00, A2:04:E1:10:06:00". That sample is placeholder text, and it is not in
the field. Nothing is sent while the field is empty, and **Run** stays dim until
you load a preset or type a sequence. Read as an example, it is two commands of
three and six bytes, and the second one writes four bytes to a page.
:::

:::step[Send it]
Tap the **Run** button. The status chip reads "Polling…", the scrollback adds
"Polling for tag…", and the iOS scan sheet appears with "Hold tag for command."
:::

:::step[Hold the tag against your iPhone]
Rest the top edge of your iPhone flat against the tag and keep it still. The
scrollback adds a connected line carrying the tag's UID and the chip, as in
"Connected: 04:BA:4A:92:1B:21:90 · ntag213". The status chip then reads
"Running…" while the commands go out.

To stop before any byte reaches a tag, tap Cancel on the iOS sheet. The run
ends, the status chip goes back to "Idle", and the scrollback reads "Cancelled
before a tag was found. Nothing was sent." Left alone with no tag against it,
the sheet closes by itself and the status chip reads "No tag found". Once the
console has read a tag, from **Run** or **Identify**, a cancel or a timeout on a
later run is logged as an error line instead.
:::

:::step[Read the answers]
Each command adds a sent line and a received line, and the received line says
how many bytes came back. After the last answer the status chip reads "Done"
and the scrollback ends with "Done."
:::
::::

:::warning[The console checks nothing before it sends]
A write command changes the tag the moment it goes out. Some pages on a chip
accept one write for the life of the tag. A wrong byte there is not something a
later command can put back.
:::

To find one preset among many, enter part of its name or part of its bytes in
**Search**, under the **Presets** heading. You can also ignore the library and
type your own sequence into **Command**. A command the tag refuses ends the run
and the tap, and every line already in the scrollback stays where it is.

## Watch every frame, not only this run

Above the scrollback, tap **All NFC traffic**. The console then shows every
frame the app exchanges with a tag. Frames from scans, writes and tag
operations appear as well as those from this screen. New frames arrive as they
happen. Tap **This run** to go back to the console's own log.

## Reach a chip that refuses the probe

Turn on **Skip identification**, the switch between the status chip and
**Command**, when a tag answers nothing after it connects. The app then sends
your commands without first asking the chip what it is. The run reports the tag
as unknown instead of naming the chip. The switch stays on until you turn
it off; it does not go back on its own when a run ends. The reason sits
under the switch while it is on:
"Commands go straight to the chip. Needed for chips that refuse GET_VERSION: the probe halts them and every later command fails."

## If the console reports an error

An error line ends the run, and the tap with it. The iOS scan sheet closes with
it, so to send anything more, tap **Run** again and present the tag.

- "Could not parse command." means the text in **Command** is not a sequence
  the app can read, and nothing was sent. Check the three rules. Every byte is
  two hex digits, and colons sit between the bytes of one command. A comma sits
  between one command and the next.
- "Couldn't identify the tag." means the identify scan ended without a result.
  Tap **Identify** and present the tag again.
- "Something unexpected went wrong." means the run stopped for a reason the app
  has no better words for. The rest of the line carries the detail.
- Any other message on an error line is the app's own account of what the tag
  did. The wording is the same one a scan or a write would have given you.

For what those messages usually mean in practice, see
[If a tag does not scan or write](troubleshooting.md).

## See also

- [Save a copy of a tag's memory](memory-dump.md)
- [Tags that work with Hex NFC](tags-that-work.md)
- [Chip support matrix](../developer/chip-support-matrix.md)
