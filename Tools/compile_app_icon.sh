#!/bin/bash
# Compile PriType.icon (Icon Composer) into the bundle's Resources directory.
# Produces Assets.car (Liquid Glass icon, macOS 26+) and PriType.icns (fallback
# for older macOS). Info.plist refers to both as "PriType".
set -e

RESOURCES_DIR="$1"
if [ -z "$RESOURCES_DIR" ]; then
    echo "Usage: $0 <Contents/Resources dir>" >&2
    exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PARTIAL_PLIST=$(mktemp "${TMPDIR:-/tmp}/pritype-icon-partial.XXXXXX")

xcrun actool "$ROOT_DIR/PriType.icon" \
    --compile "$RESOURCES_DIR" \
    --app-icon PriType \
    --platform macosx \
    --target-device mac \
    --minimum-deployment-target 14.0 \
    --output-partial-info-plist "$PARTIAL_PLIST" \
    --output-format human-readable-text >/dev/null
rm -f "$PARTIAL_PLIST"

test -f "$RESOURCES_DIR/Assets.car"
test -f "$RESOURCES_DIR/PriType.icns"
