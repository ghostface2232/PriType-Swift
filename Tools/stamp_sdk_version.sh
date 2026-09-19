#!/bin/bash
# Record the SDK the binary was actually built against.
#
# SwiftPM links with the deployment target (14.0) in the SDK slot of
# LC_BUILD_VERSION. AppKit and SwiftUI read that value to decide which design
# to draw, so a 14.0 stamp makes the app look like a Sonoma-era app on macOS 27:
# bordered form groups, no Liquid Glass, a divider beside the sidebar. Xcode
# builds record the real SDK; this does the same for the SwiftPM build.
#
# Run it before codesigning: it rewrites the Mach-O header.
set -e

BINARY="$1"
if [ -z "$BINARY" ]; then
    echo "Usage: $0 <Mach-O binary>" >&2
    exit 1
fi

SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version)
MIN_VERSION=$(xcrun vtool -show-build "$BINARY" | awk '/minos/ { print $2; exit }')

xcrun vtool -set-build-version macos "$MIN_VERSION" "$SDK_VERSION" -replace \
    -output "$BINARY.stamped" "$BINARY" 2>/dev/null
mv "$BINARY.stamped" "$BINARY"
