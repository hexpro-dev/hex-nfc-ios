#!/usr/bin/env bash
#
# Select the Xcode the project is developed against on a GitHub runner.
#
# Pinning an exact path (the old `xcode-select -switch /Applications/Xcode_15.4.app`)
# breaks silently whenever GitHub rotates an image, and pinning nothing at all
# lets the toolchain drift under you between runs. This matches the major
# version and takes the newest point release the image happens to carry, then
# fails loudly, with the list, when the image has none.
#
# Bump XCODE_MAJOR deliberately, in step with the local toolchain. Building
# with an SDK older than the App Store minimum gets the upload rejected, which
# is the failure this exists to prevent.

set -euo pipefail

XCODE_MAJOR="${XCODE_MAJOR:-26}"

candidate="$(ls -d /Applications/Xcode_"${XCODE_MAJOR}"* 2>/dev/null | sort -V | tail -1 || true)"

if [[ -z "${candidate}" ]]; then
    echo "No Xcode ${XCODE_MAJOR}.x found on this runner image." >&2
    echo "Available:" >&2
    ls -d /Applications/Xcode* >&2 || echo "  (none)" >&2
    exit 1
fi

echo "Selecting ${candidate}"
sudo xcode-select -switch "${candidate}"
xcodebuild -version
