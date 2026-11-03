#!/bin/sh
#
# Xcode Cloud runs this after cloning and before it resolves packages or builds
# anything. It refuses to go on unless the workflow is on the Xcode major the
# project is developed and tested against.
#
# 1.0 (build 36) is why. The Xcode Cloud workflow followed "Latest Release",
# which moved to Xcode 27 in September 2026, so the binary on the App Store was
# compiled against the iOS 27 SDK, which no tested build had been. That SDK turns an `if`
# inside rotor content into a conformance only iOS 27 has, and the app aborted
# on iOS 26 every time the tag editor opened. Every build tested before release
# came from Xcode 26.3. Nothing told anyone the toolchain had changed.
#
# Keep EXPECTED_MAJOR in step with XCODE_MAJOR in .github/scripts/select-xcode.sh
# and with the local toolchain. Move all three together, deliberately, and only
# after a Release build from the new Xcode has run the golden paths (scan, the
# tag editor, write, Library) on the oldest iOS the app supports.

set -eu

EXPECTED_MAJOR=26

version="$(xcodebuild -version | awk 'NR == 1 { print $2 }')"
major="${version%%.*}"

if [ "${major}" != "${EXPECTED_MAJOR}" ]; then
    echo "error: this workflow is running Xcode ${version}, and Hex NFC is built and tested with Xcode ${EXPECTED_MAJOR}.x." >&2
    echo "error: select an Xcode ${EXPECTED_MAJOR}.x release in the workflow's Environment settings instead of Latest Release," >&2
    echo "error: or move EXPECTED_MAJOR here, in .github/scripts/select-xcode.sh, and locally once a release build from the new Xcode has been tested on device." >&2
    exit 1
fi

echo "Xcode ${version}"
xcodebuild -showsdks | grep -i iphoneos || true
