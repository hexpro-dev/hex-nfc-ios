---
title: Read a transit card
description: Hold a Suica, PASMO or another Japanese transit card against your iPhone to see its balance and recent trips in Hex NFC.
audience: user
pageKind: howto
navTitle: Transit cards
tags:
  - scanning
---

Hold a Japanese transit IC card against your iPhone and Hex NFC shows the money
left on it and the trips it remembers. Suica, PASMO, ICOCA, TOICA, manaca,
SUGOCA, nimoca, Kitaca and the rest of the Japanese IC family all sit on one
system. Every one of them is read the same way. A transit card from another
country is not read here, and
[Tags that work with Hex NFC](tags-that-work.md) says what the app does read.

Before you start you need the app installed from the App Store on an iPhone
that reads NFC tags. You also need the card out of your wallet.
[Read your first tag](quick-start.md) covers installing the app and reading one
tag, and [Common questions](faq.md) says which iPhones the app needs. A transit
card is only ever read, never changed, so there is no way to add money to a
card here.

## Read a transit card

::::steps
:::step[Open Hex NFC]
Open Hex NFC. The home screen opens, with the **Scan** tile on it.
:::

:::step[Open the scan screen]
Tap **Scan**. The scan screen opens and reads "Hold tag against the top of your
iPhone".
:::

:::step[Hold the card against your iPhone]
Hold the card flat against the back of your iPhone, near its top edge. Keep
both still until the screen reads "Tag detected", which is the read finishing.
Where nothing happens after a few seconds, move the card a little and hold it
again. To stop instead, tap **Cancel**. That takes you back to the home screen.
Left alone with no card against it, the read ends by itself and the screen
reads "No tag found" with **Try again** under it.
:::

:::step[Wait for the card to open]
Move the card away. After about a second the **Transit card** screen opens on
its own.
:::

:::step[Close the card]
Tap **Close**. You are back on the home screen.
:::
::::

:::note[Only a stop you name leaves your iPhone]
The balance, the trips and the card's own ID stay on your iPhone. The one thing
the app sends anywhere is a stop name you type and submit. It carries the
stop's codes and the card type too.
[Name a stop the app could not](#name-a-stop) covers it.
:::

## If the card is not found

- Hold one card at a time, away from the other cards in your wallet.
- Hold the card against the back of your iPhone near its top edge, not against
  the middle of the back.
- Check that the card is a Japanese transit IC card. A card from another transit
  system does not open the **Transit card** screen.
- Where a read starts and then fails, the screen reads "Scan failed" and says
  what went wrong. Tap **Try again** and hold the card still for longer.

[If a tag does not scan or write](troubleshooting.md) covers the rest.

## What the Transit card screen shows

The screen has three parts, in this order:

1. The card, with the system it belongs to, such as "Transit IC (Suica /
   PASMO …)", and "Balance" over the money left on it in yen.
2. The [tag info card](tags-that-work.md), which describes the chip in the
   card. Two of its rows
   belong to transit cards alone: "System code", and "Transactions" for the
   number of entries read.
3. "History", the list of what the card remembers. A transit card keeps its 20
   most recent transactions, so 20 rows is the most this list holds. A card
   that reports none shows "No transaction history on this card" instead.

Under the list, in both cases, the app repeats what it can and cannot name. The
text reads: "Station names are shown where available; other stops appear as
their raw transit codes."

## What a history row says

A row gives what the transaction was, the day it happened, and the balance left
after it. A train trip shows the stop you entered and, where the card recorded
it, the stop you left. A stop the app cannot name shows one of two things in
place of the station name. One is the name of its train line followed by a
question mark. The other is the stop's raw transit code.

Where the card recorded no entry stop, that end reads "Unknown". Where it
recorded no exit stop, the row shows the one stop on its own, with no arrow
after it. A row carrying no readable date reads "Date unknown" under its
heading.

A transaction that is not a train trip names what happened in place of a route:

- "Bus fare".
- "Charge" for money added to the card.
- "Purchase" for something bought in a shop.
- "Transaction" for a block of the card that fits none of those.

VoiceOver reads a train trip as "Ride" before the two stops and the date.

## Name a stop the app could not {#name-a-stop}

A stop with no name yet is one you have been to, because it is on your card.
You can tell the app what it is called. When at least one train stop is
unnamed, a card above the history reads "Some of these stops aren't named yet.
You've been to them. Help fill in the blanks below." A line under it says what
a name carries. It reads: "A name you send goes to us for review and may ship
in a later update. It carries the stop's codes, the card type, and the name you
typed. Nothing else from the card is sent."

An unnamed stop is the one showing a train line and a question mark, or a raw
transit code, where a station name would be.

::::steps
:::step[Find a history row with an unnamed stop]
Scroll to the first row that shows one. The field for that stop sits directly
under the row. The line above the field names the train line the stop sits on.
Where the line is unknown too, it reads "Unknown stop".
:::

:::step[Enter the name]
In **Name this station**, enter what the stop is called.
:::

:::step[Send the name]
Tap **Submit**. The app shows "Thanks!" in place of the field, then the field
closes and stays closed until you scan the card again.
:::
::::

Each unnamed stop gets one field, even when several trips pass through it. A
name you have sent cannot be taken back. Where you sent the wrong one, scan the
card again to bring the field back, and send the right name. Every name goes
for review before any of it ships, so a mistake does not reach the app on its
own.

## See also

- [Read your first tag](quick-start.md)
- [Scan a tag](scan-a-tag.md)
- [Tags that work with Hex NFC](tags-that-work.md)
- [If a tag does not scan or write](troubleshooting.md)
- [Privacy and your data](privacy.md)
