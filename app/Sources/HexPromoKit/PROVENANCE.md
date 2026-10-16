# PROVENANCE: HexPromoKit

This directory is a **vendored copy**, not source maintained here. Nothing in
it is ours to edit.

| | |
|---|---|
| Upstream | `git@github.com:hexpro-dev/hex-promo.git` |
| Path | `sdk/swift/HexPromoKit/Sources/HexPromoKit/` |
| Commit | `fd09a670b80c228e0740036b0442bd2078415e05` |
| Copied | 21 August 2026 |
| Local adaptations | **none** |

The `Commit` row is where this repository records the pin, and the only place.
Everything else that names a hex-promo commit (the freshness command under
[Re-syncing](#re-syncing), the comment on the `HexPromoKit` target in
`app/Package.swift`, anything added later) is checked against that row by
`test_everySiteNamingAHexPromoCommitNamesThePinnedOne` in
`app/Tests/HexPromoKitTests/VendoredPromoProvenanceTests.swift`, which walks the
repository for commit-shaped strings sitting near a hex-promo reference. So a
re-sync edits one row and then asks the test which sites are still stale. This
document deliberately states no number of sites: the last two attempts to write
that number down were both wrong by the time anybody read them.

HexPromoKit is Hex Pro's own code, so it carries this file and gets no `NOTICE`
entry. `NOTICE` scopes its attribution list to "Third-party components", and
filing our own copyright under that heading would put a false statement into a
document that ships to users.

## The manifest

`VendoredPromoProvenanceTests` parses the table below, hashes each file, and
fails on any difference. It also walks this directory at any depth and fails on
a `.swift` file the table does not name, so a fifth `.swift` file cannot arrive
unrecorded, not even inside a subdirectory. Only `.swift` files: the walk
ignores everything else, and a stray non-source file surfaces as SPM's
unhandled-resource warning instead, which is why `PROVENANCE.md` itself is named
in the target's `exclude:` list.

| File | sha256 | Lines |
|---|---|---|
| `PromoModels.swift` | `5c872054d9a9591bb9b3a0d5552e5d075b1e5fd9fc90b6ef0f008886ec9bf635` | 150 |
| `PromoDiskCache.swift` | `ab8beb16cbb72afbfc858b8eb1c2c326602e999a0071bcae4e172640f2b3db98` | 148 |
| `PromoManager.swift` | `2965ecdcfe557c89c5ca18545e5318a72e3bbc66dcc33a7f3a86d687617757c6` | 237 |
| `PromoBannerStyle.swift` | `a6a1dc4b08b02a15313a91f1dbf95fdb52a1e931664ce50bb81fd7139b00fcb4` | 19 |

That check is narrower than it looks, and worth stating plainly: the manifest
and the files it hashes sit in the same directory and land in the same commit,
so it is **self-attested**. Edit a vendored file, refresh its row, and every
assertion goes green again. What it catches is the small correct-looking fix
made in passing, which is the realistic failure. Nothing here ties the copy to
upstream except the commit recorded above, and only a diff against that commit
settles it. That is step 2 of [Re-syncing](#re-syncing), and it needs a checkout
of the upstream repository, which is private.

## What was deliberately NOT copied

`PromoBanner.swift` (sha256
`5ec12bc9931789449996ac51f5b0ab718c62e1cdcdd629dc8bbfab34cf1b8f24`). Its absence
is a decision rather than an oversight, and its hash is recorded here so that a
later re-sync which copies the whole directory reads as a change of mind instead
of an accident.

A banner has to look like the app it sits in. Upstream's is styled by a
`PromoBannerStyle`, which carries a corner radius and a fade duration, so fitting
it to Home means editing it, and an edited vendored file turns every later
re-sync into a merge. Hex NFC draws its own in `app/Sources/HexNFCApp/Promo/`,
reading the vendored `PromoManager` without touching it. Dropping the file keeps
`SwiftUI`, `UIKit`, and `AVKit` out of this target as well, leaving it on
Foundation, Combine, and CoreGraphics.

`PromoBannerStyle.swift` came across anyway, and it is worth being straight
about what that means: `PromoBanner.swift` was its only consumer upstream, so
nothing in this repository references it, its doc comment links a type that is
not in this target, and it compiles into the shipping app as dead code. It is
kept because deleting it would be one more divergence for the next re-sync to
reconcile.

`Package.swift` and the upstream test file are not copied either: this target is
declared by `app/Package.swift`, and the tests are ported (see below).

## Why it is byte for byte, and what that costs

Keeping the copy identical is what turns drift into a hash comparison rather
than a reading exercise. The cost is that this directory sits outside the
repository's own tooling: `.swiftlint.yml` and `.swiftformat` both **exclude**
it. Checked against the files as they were copied:

- `PromoManager.swift` force-unwraps `URL(string: PromoManager.defaultBaseURL)!`.
  `force_unwrapping` is an opt-in rule this repository turns on, and CI runs
  `swiftlint --strict`, so that one line would fail the lint job.
- `PromoManager.swift` imports `Foundation` before `Combine`. SwiftLint's
  `sorted_imports` rejects that order and SwiftFormat's `sortImports` would
  rewrite it. The other three files import a single module each, so they are
  unaffected.

SwiftFormat's objection is the broader one: `redundantSelf`,
`wrapIfStatementBodies`, `wrapPropertyBodies`, `hoistPatternLet`,
`blankLinesAtStartOfScope`, `spaceAroundOperators` and
`wrapMultilineStatementBraces` all fire across these files. No count of sites is
written down here, because a count measures one particular copy and the re-sync
procedure below has no step that would refresh it. Re-measuring means copying
the files somewhere outside the repository and linting the copies: SwiftFormat's
`--exclude` beats an explicit path argument, so pointing it at these paths
silently reports nothing.

Every one of those is upstream's call to make. Correcting any of them here would
fork the file quietly and turn the next re-sync into a merge. Adaptation happens
at the boundary, in our own files, never in these.

## Re-syncing

No test here can tell you the copy is STALE. That is a consequence of vendoring
rather than a fact of life: CI used to check `hex-promo` out beside this repo,
and vendoring removed that step on purpose, because forked pull requests get no
secrets and a build that needs a private sibling repository is a build this
repository cannot run standalone. Freshness is a maintainer step instead, and it
belongs on the release checklist.

Both commands here need `$PROMO`, a checkout of the upstream repository. That
repository is private, so a reader of this one cannot run either of them; they
are written down here because this is where the pin lives.

Fetch first, and compare against the remote's default branch rather than `HEAD`.
An unfetched clone sees nothing that was pushed since it was last used, and a
working checkout usually sits on whatever branch was last worked on, so `HEAD`
answers a question nobody asked.

```bash
git -C "$PROMO" fetch origin
git -C "$PROMO" log --oneline \
    fd09a670b80c228e0740036b0442bd2078415e05..origin/main -- sdk/swift/HexPromoKit
```

Empty output means there is nothing to do. Otherwise:

1. Copy the same four files from the new commit, still leaving
   `PromoBanner.swift` behind.
2. Confirm the copy really is upstream's, which is the check no test in this
   repository can make. Run this from the root of this repository, with
   `$COMMIT` set to the commit you copied from:

   ```bash
   for f in PromoModels PromoDiskCache PromoManager PromoBannerStyle; do
       git -C "$PROMO" show \
           "${COMMIT}:sdk/swift/HexPromoKit/Sources/HexPromoKit/$f.swift" \
           | diff -q - "app/Sources/HexPromoKit/$f.swift"
   done
   ```

   Silence is a pass. Anything printed is a file that is not what this document
   says it is. The braces around `COMMIT` are load bearing: without them zsh
   reads `$COMMIT:sdk/...` as a modifier and the command dies.
3. Update the `Commit` and `Copied` rows at the top of this document, and every
   row of the manifest.
4. Update every other site that still names the old commit: the freshness
   command above, the comment on the `HexPromoKit` target in
   `app/Package.swift`, and whatever has arrived since. That is not a promise of
   completeness and there is no count of them anywhere here, because both go
   stale on the next edit. Run
   `cd app && swift test --filter test_everySiteNamingAHexPromoCommitNamesThePinnedOne`
   instead: it reports each remaining site by file and line, and goes green once
   none are left. The freshness command is the one worth naming twice. Left
   behind, it compares upstream against the commit you just replaced and answers
   "nothing to do" from then on.
5. Refresh the sha256 recorded for `PromoBanner.swift` under [What was
   deliberately NOT copied](#what-was-deliberately-not-copied). It is prose
   rather than a manifest row, so nothing checks it, and a stale hash there is
   what would let a later whole-directory copy read as an accident.
6. Re-port upstream's test suite into the files described under [The ported
   tests](#the-ported-tests). Upstream keeps its suite in one file and the port
   splits it across four, so this is a diff of upstream's file against the
   previous port rather than a copy, and `PromoTestWorld.swift` is where the
   port records what it had to change.
7. `cd app && swift test --filter VendoredPromoProvenance` to confirm the
   manifest matches, then `--filter HexPromoKit` for the behaviour.
8. Re-read `PromoManager`'s public surface.
   `app/Sources/HexNFCApp/Promo/HomePromoSlot.swift` is the only file in the app
   target that imports this module, and `PromoImportContainmentTests` enforces
   that scope by walking `app/Sources/HexNFCApp`. The rest of the blast radius
   is the four ported test files below, which import the module with `@testable`
   and sit outside that walk.

## The ported tests

`app/Tests/HexPromoKitTests/` holds upstream's own suite rather than a fresh
one, so a re-sync can be diffed against upstream line by line. Upstream keeps it
in a single file; the port splits it into three case files
(`PromoDecodingTests.swift`, `PromoDiskCacheTests.swift`,
`PromoManagerTests.swift`) with the shared fixtures in `PromoTestWorld.swift`,
which is also where the port records what it had to change. Upstream already
writes its fixtures against `pro.hex.nfc`, so no identifier rewrite was needed.
`VendoredPromoProvenanceTests.swift` sits in that directory too and is not
upstream's: it is this repository's own guard over the manifest and the pin,
described above.
