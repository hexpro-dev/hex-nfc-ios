# Security Policy

## Reporting a vulnerability

Please report security vulnerabilities privately to **`security@hex.pro`**.

Do **not** open a public GitHub issue. We follow a 90-day coordinated
disclosure timeline:

1. You report the issue privately.
2. We acknowledge within 72 hours.
3. We work with you on a fix and a public disclosure date.
4. After the fix is shipped (or 90 days, whichever comes first), the issue
   is disclosed publicly with credit unless you prefer otherwise.

## In scope

- The iOS app source in `app/`
- The chip simulators in `app/Tests/HexNFCTagSim/`
- The web landing page at `apps.hex.pro/hex-nfc`
- The sync workflow if it could expose private commits or secrets

## Out of scope

- Issues in third-party services (App Store, GitHub Actions, etc.)
- Reports requiring physical possession of a victim's unlocked device
- Theoretical attacks without a demonstrable impact path

## Privacy

Hex NFC does not collect telemetry, analytics, or user data. The privacy
manifest (`PrivacyInfo.xcprivacy`) is committed in-tree and is the
source of truth. If you find a network call we haven't documented in
the README's "Privacy" section, that is a security issue. Please report it.
