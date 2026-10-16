---
title: Hex NFC user guide
description: What you need to use Hex NFC on your iPhone, and which page of this guide covers each task.
audience: user
pageKind: article
navTitle: User guide
tags:
  - scanning
---

Hex NFC reads the NFC tags around you and shows every record a tag holds. It
writes records back to a blank tag and sets a password on the chips that can
carry one. The app also reads a Japanese transit card or the chip in an
electronic passport. There is no account to create, and the app carries no
analytics.

## What you need

- Hex NFC, installed from the [App Store](https://apps.apple.com/app/id6801457461), on your iPhone.
- An iPhone running iOS 17 or later.
- An NFC tag. Most blank stickers, cards and key fobs carry a chip the app
  reads. [Tags that work with Hex NFC](tags-that-work.md) names them, and the
  [chip support matrix](../developer/chip-support-matrix.md) says what each one
  can do.

## What you can do

Hex NFC opens on the home screen, which carries four tiles.

- Tap **Scan** to read a tag and see what it holds: [Scan a tag](scan-a-tag.md).
  A [transit card](transit-cards.md) reads the same way, and a
  [passport](passports.md) takes two taps.
- Tap **Build** to put records together from scratch, then write them:
  [Write a link to a tag](write-a-link.md).
- Tap **Library** for the tags you scanned before:
  [Find a tag you scanned before](scan-history.md). The sets of records you kept
  are there too: [Save a tag as a preset](presets.md).
- Tap **Advanced** to send a raw command to a chip whose command set you know:
  [Send a raw command to a tag](advanced-console.md).

## Change what a tag holds

Once a tag is open you can rebuild its records with
[Edit a tag's records](edit-records.md), choosing from the kinds in
[Record types](record-types.md). [Protect a tag with a
password](protect-a-tag.md) sets the secret a chip checks.
[Remove a tag's password](remove-password.md) takes it off again.
[Limit wrong password tries](attempt-limit.md) says how many refusals the chip
accepts. Three tools work on the tag itself: [Erase or format a
tag](erase-or-format.md), [Lock a tag permanently](permanent-lock.md) and
[Save a copy of a tag's memory](memory-dump.md).

## Get started

[Read your first tag](quick-start.md) goes from the home screen to your first
scan in about 5 minutes. [Tag protection](tag-protection.md) explains what a
password covers and what it cannot get back. When a tag will not answer, go to
[If a tag does not scan or write](troubleshooting.md).
[Settings](settings.md) lists every switch in the app, [Privacy and your
data](privacy.md) says what stays on your iPhone, and [Common
questions](faq.md) answers what it costs.
