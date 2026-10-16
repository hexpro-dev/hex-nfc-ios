## Summary

<!-- 1–3 bullets describing what changed and why -->

## Scope

- [ ] `nfc:` — HexNFCKit, chip support, raw commands
- [ ] `chip:` — Chip simulators in HexNFCTagSim
- [ ] `ui:` — HexNFCApp views, screens, navigation
- [ ] `web:` — Landing page / catalog entries
- [ ] `meta:` — Repo plumbing, CI, docs

## Test plan

<!-- How did you verify this works? Include simulator output, screenshots,
     or a chip family + iPhone model if hardware-tested -->

## Checklist

- [ ] No new third-party Swift dependencies (test-only `swift-snapshot-testing` excepted)
- [ ] No hex color literals outside `HexTokens.swift`
- [ ] User-facing strings use `Localizable.xcstrings`
- [ ] Interactive views have `accessibilityLabel`
- [ ] No analytics, telemetry, or network calls outside the documented set
- [ ] No mentions of competing apps by name, and no references to game-collectible brands
- [ ] Any Type-2 config-page / lock-byte numbers are datasheet-verified and match
      `Type2ConfigLayout` (see `docs/internal/chip-config-pages.md`)
- [ ] Tag-protection secrets (PWD/PACK) stay in the Keychain — not in SwiftData,
      `.hexnfc` exports, logs, or `diagnostics`

By submitting this PR I agree to license my contribution under the Business Source License 1.1.
