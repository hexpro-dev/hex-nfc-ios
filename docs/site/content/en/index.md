---
title: Hex NFC documentation
description: Start here for the Hex NFC user guide, the engineering documents, and the app's legal pages and security contact.
audience: both
---

This site holds the documentation for Hex NFC, a free app from Hex Pro that
reads and writes NFC tags on an iPhone. The user guide is for people using the
app. The engineering documents are for people reading or changing its code.

## The user guide

The [Hex NFC user guide](guide/index.md) says what the app does and what it
needs, and every task has a page: reading a tag, writing one, protecting one, and what
to do when a tag will not answer. Start at
[Read your first tag](guide/quick-start.md).

## Engineering documents

[Architecture](developer/architecture.md) is for developers working on the
app. It goes through the Swift package target by target, including how chips
are identified and how the chip simulators stand in for real tags in tests,
and ends with the conventions the code follows.

Read the [chip support matrix](developer/chip-support-matrix.md) before buying
tags to use with the app, or when a tag does not behave the way you expect.
Each tag family has its own table. The FeliCa table covers reading and writing
only; the others add password protection, permanent lock and memory dump. The
page says which of those results have been confirmed on real tags and which
have not.

## Privacy policy and terms

Hex NFC's [privacy policy](https://apps.hex.pro/hex-nfc/privacy) and
[terms and conditions](https://apps.hex.pro/hex-nfc/terms) are published on
apps.hex.pro. Send questions about either to
[support@hex.pro](mailto:support@hex.pro).

## Reporting a security issue

Report a vulnerability privately to [security@hex.pro](mailto:security@hex.pro),
not in a public forum or issue tracker. Hex Pro acknowledges a report within
72 hours, then works with the reporter on a fix and a date for public
disclosure. The issue is made public once the fix has shipped, or 90 days
after the report if that is sooner, and the reporter is credited unless they
would prefer not to be.
