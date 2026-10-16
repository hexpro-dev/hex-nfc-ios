---
title: Save a tag as a preset
description: Keep a set of records in your Library, write it to more tags, and share it with someone else.
audience: user
pageKind: howto
navTitle: Presets
tags:
  - library
  - writing
---

A preset is a named set of records kept on your iPhone. Save one from the tag
you are editing, then write those same records to as many tags as you like
without building them again.

Before you start, put a set of records on the Tag screen, so there is something
to save. On the Hex NFC home screen, tap **Scan**, then hold the tag you want to
copy. To start with no tag in front of you, tap **Build**. Either one opens
the Tag screen. See [Scan a tag](scan-a-tag.md) and
[Edit a tag's records](edit-records.md).

## Save the records you are editing

::::steps
:::step[Open the save sheet]
On the Tag screen, tap the menu button at the top right, then tap
**Save as preset…**. The menu row is dimmed until the tag holds at least one
record or a protection setting.
:::

:::step[Name the preset]
In **Name**, enter a name you will recognise later, such as the place the tags
are going. **Save** stays dimmed until the name is filled in.
:::

:::step[Add a note]
Optional: in **Notes**, write what the preset is for. The field takes up to
four lines.
:::

:::step[Choose an icon]
Under **Icon**, tap one of the three segments, which are named in words rather
than drawn as shapes: **Outer frame**, **Caret up** or **Caret down**. The one
you tap sets the hexagon badge shown beside the preset in the **Library**.
:::

:::step[Check what the preset will hold]
**Records** counts the records that will be stored. A preset that carries
protection and nothing else reads "No records. This preset only applies
protection." instead.

If the list holds a **Location** with no coordinates and no map URL, **Records**
also reads "A location record has no coordinates or map URL, so this preset
could never be written to a tag. Fill it in or delete it on the Tag screen, then
save." **Save** stays dimmed while it does. Tap **Cancel**, fill the record in
or delete it, then open the save sheet again. See
[Record types](record-types.md).
:::

:::step[Save it]
Tap **Save**. The sheet closes and the preset appears at the top of the
**Presets** tab in the **Library**.
:::
::::

A preset carries protection only when you set a password or a key on the tag
before you save it. You do that on the Tag screen, which shows **Protection** for
tags that can be protected. Tap **Protection** and turn on
**Password-protect this tag**. Enter the secret in the field the sheet shows,
such as **Password (4 bytes)**, then tap **Done**. See
[Protect a tag with a password](protect-a-tag.md).

Once that is done, the save sheet adds a **Protection** section naming what the
preset holds, such as "Password protection (write-only)". The secret does not go
into the preset itself. The app says so in the same section: "The secret is
stored only on this device (Keychain). It never syncs or travels in an export."
A preset arms a tag only while that secret sits on this iPhone. One you saved
without entering a secret arms nothing.

If your iPhone refuses the save, a red line appears at the bottom of the form.
It reads "Could not save: " and then the reason your iPhone gave. The sheet stays
open and your records stay on the Tag screen, so nothing you entered is lost.
Tap **Save** again. If the same reason comes back, tap **Cancel**. The records
are still on the Tag screen. You can write them straight to a tag instead of
keeping them as a preset.

## Write a preset to a tag

A padlock beside a preset's name means it carries protection settings. The row
stops there. It does not tell you whether the write will arm the tag, because
that turns on the secret held beside the preset. The secret is not shown. A
preset you saved on this iPhone after entering a password or a key of your own
holds that secret and arms the tag. A preset saved from a tag that was already
protected, where you never entered its password, holds none. It writes its
records and protects nothing. If you cannot tell which one is in front of you,
treat it as the arming kind.

::::steps
:::step[Open the Library]
On the home screen, tap **Library**. The Library screen opens on **Presets**, with the
preset you changed most recently at the top.
:::

:::step[Start the write]
Swipe the preset a short way from its left edge, then tap **Write**. The
**Library** closes and the write screen opens.
:::

:::step[Hold the tag against your iPhone]
Hold the tag against the top of your iPhone while the screen reads "Hold tag
against the top of your iPhone". It reads "Locked in" once the records are on
the tag.
:::
::::

:::warning[A preset that applies protection does not ask you to confirm the tag]
A preset that carries protection settings and still holds its secret on this
iPhone sets that secret on whatever tag you hold. This is the one place in the
app where protection is armed with no first tap to read the tag. There is no UID
to type back. Hold only the tag you meant to protect. Keep the preset for as long
as those tags are in use. Writing it again is the way back into a tag it locked.
Deleting it deletes that copy of the secret.
:::

## Manage your presets

Until you save one, the **Presets** tab reads "No saved presets". After that,
every row carries the preset's name and icon. A line under it counts the records
and gives the date the preset last changed.

A padlock beside the name marks a preset that carries protection settings, and
VoiceOver reads it as "Applies protection". What that padlock does and does not
promise is above, under [Write a preset to a tag](#write-a-preset-to-a-tag).

Swiping a preset from its left edge reveals **Write** and **Share**. Swiping it
from its right edge reveals **Delete** and **Duplicate**. Swipe a short way, then
tap the button you want. A swipe carried all the way across from the right edge
deletes the preset on its own.

A saved preset cannot be changed. To alter what a preset with no padlock holds,
build the records again on the Tag screen. Save them as a new preset, then
delete the old one.

Leave a padlocked preset alone. Rebuilding it from the Tag screen gives you
records and no secret, unless you set the password or key up again first.
Deleting the old preset takes the only copy of the secret that opens the tags it
protected. To get a second copy of one, use **Duplicate**, which carries the
stored secret across.

From the **Presets** tab, do any of the following:

- To keep a copy of a preset outside the app, swipe it from its left edge and
  tap **Share**. The app writes a `.hexnfc` file named after the preset and
  hands it to the share sheet. The records and the protection settings travel in
  that file; the password or key never does. Hex NFC has no way to open a
  `.hexnfc` file. What you send someone is a copy of the records to keep, not a
  preset they can add to their own app.
- To make a second copy of a preset, swipe it from its right edge and tap
  **Duplicate**. The copy holds the same records, the same protection settings
  and the same stored secret.
- To remove a preset, swipe it from its right edge and tap **Delete**. Nothing
  asks you to confirm, and the preset's stored secret goes with it.

## See also

- [Edit a tag's records](edit-records.md)
- [Write a link to a tag](write-a-link.md)
- [Tag protection](tag-protection.md)
- [Find a tag you scanned before](scan-history.md)
