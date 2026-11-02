#!/bin/bash
set -e

# Define variables
APP_NAME="PriTypeV2"
BUILD_DIR=".build/release"
INSTALL_DIR="$HOME/Library/Input Methods"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "Building release..."
swift build -c release

echo "Creating bundle structure..."
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

echo "Copying executable..."
cp "$BUILD_DIR/PriType" "$MACOS_DIR/PriTypeV2"
Tools/stamp_sdk_version.sh "$MACOS_DIR/PriTypeV2"

echo "Copying Info.plist..."
cp Info.plist "$CONTENTS_DIR/"

# Copy menu bar icon
# Copy Resources directory (localization, etc)
cp -R Resources/* "$RESOURCES_DIR/" 2>/dev/null || true

# Compile App Icon (PriType.icon)
Tools/compile_app_icon.sh "$RESOURCES_DIR"

# Copy input source icons
cp "icon.tiff" "$RESOURCES_DIR/" 2>/dev/null || echo "No icon.tiff found, skipping."
cp "input-ko.tiff" "$RESOURCES_DIR/" 2>/dev/null || echo "No input-ko.tiff found, skipping."
cp "input-en.tiff" "$RESOURCES_DIR/" 2>/dev/null || echo "No input-en.tiff found, skipping."

# Copy Swift Package Manager resource bundle (required for Bundle.module / L10n)
if [ -d "$BUILD_DIR/PriType_PriTypeCore.bundle" ]; then
    cp -R "$BUILD_DIR/PriType_PriTypeCore.bundle" "$RESOURCES_DIR/"
    echo "Copied PriType_PriTypeCore.bundle"
else
    # L10n cannot start without it.
    echo "Error: PriType_PriTypeCore.bundle not found." >&2
    exit 1
fi

# Code Signing
if [ -z "$SIGNING_IDENTITY" ]; then
    # -v 없이 찾는다. 자체 서명 인증서는 신뢰되지 않아 -v 목록에 없지만 서명에는 쓸 수 있고,
    # 이 목록은 개인 키가 있는 인증서만 보여 준다.
    SIGNING_IDENTITIES=$(security find-identity -p codesigning)

    # 1. 릴리스와 같은 인증서(PriType Release)를 먼저 확인.
    #    손쉬운 사용·입력 모니터링 권한은 서명 인증서에 묶이므로, 로컬 빌드와
    #    GitHub 릴리스가 같은 인증서를 써야 둘을 오가도 권한이 유지된다.
    if echo "$SIGNING_IDENTITIES" | grep -q '"PriType Release"'; then
        SIGNING_IDENTITY="PriType Release"
    else
        # 2. 정식 Apple Development 인증서
        APPLE_DEV_CERT=$(security find-identity -v -p codesigning | grep "Apple Development:" | head -n 1 | awk -F'"' '{print $2}')

        if [ -n "$APPLE_DEV_CERT" ]; then
            SIGNING_IDENTITY="$APPLE_DEV_CERT"
        # 3. 개발용 자체 서명 인증서(PriTypeDev)
        elif echo "$SIGNING_IDENTITIES" | grep -q '"PriTypeDev"'; then
            SIGNING_IDENTITY="PriTypeDev"
        fi
    fi
fi

if [ -n "$SIGNING_IDENTITY" ]; then
    echo "Signing with identity: $SIGNING_IDENTITY"
    # Hardened runtime: see build_release.sh.
    codesign --force --options runtime --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
    echo "Signing complete."
else
    echo "No SIGNING_IDENTITY set and no usable signing certificate found."
    echo "Using ad-hoc signing. (Warning: Accessibility permissions will break on every build!)"
    codesign --force --deep --options runtime --sign - "$APP_BUNDLE"
fi

echo "Installing to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/PriType.app"
rm -rf "$INSTALL_DIR/$APP_BUNDLE"
mv "$APP_BUNDLE" "$INSTALL_DIR/"

echo "Installation complete!"
echo "Please log out and log back in, or restart your computer."
echo "Then enable '$APP_NAME' in System Settings > Keyboard > Input Sources."
