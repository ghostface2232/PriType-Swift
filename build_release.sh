#!/bin/bash
set -e
export COPYFILE_DISABLE=1

# Define variables
APP_NAME="PriTypeV2"
BUILD_DIR=".build/release"
LEGACY_PAYLOAD_DIR="Packaging/Payload"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/pritype-release-payload.XXXXXX")
PAYLOAD_DIR="$TMP_ROOT/Payload"
INSTALL_DIR="/Library/Input Methods"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS_DIR="${PAYLOAD_DIR}/${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
PKG_OUTPUT="PriTypeV2_Release.pkg"
COMPONENT_PLIST="PriTypeV2_components.plist"
# Signing is chosen by the caller, not discovered from the keychain:
#   APP_SIGN_IDENTITY  codesign identity for the app. Defaults to "-" (ad-hoc).
#                      Any fixed certificate, even a self-signed one, keeps
#                      Accessibility and Input Monitoring grants across updates;
#                      ad-hoc signing makes macOS ask for them again every time.
#   PKG_SIGN_IDENTITY  Developer ID Installer identity. Unset leaves the pkg unsigned.
#   KEYCHAIN_PROFILE   notarytool profile. Notarizes only with a Developer ID
#                      app and a signed pkg.
APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:--}"
PKG_SIGN_IDENTITY="${PKG_SIGN_IDENTITY:-}"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-}"

cleanup() {
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -u "$PAYLOAD_DIR/$APP_BUNDLE" >/dev/null 2>&1 || true
    rm -rf "$TMP_ROOT"
    rm -f "$COMPONENT_PLIST"
}
trap cleanup EXIT

echo "=========================================="
echo "    PriType Release Build & Packaging     "
echo "=========================================="

echo "[1/6] Building release..."
swift build -c release

echo "[2/6] Creating bundle structure..."
if [ -d "$LEGACY_PAYLOAD_DIR/$APP_BUNDLE" ]; then
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -u "$LEGACY_PAYLOAD_DIR/$APP_BUNDLE" >/dev/null 2>&1 || true
fi
rm -rf "$LEGACY_PAYLOAD_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# Copy executable and Info.plist
cp "$BUILD_DIR/PriType" "$MACOS_DIR/$APP_NAME"
cp Info.plist "$CONTENTS_DIR/"

# Copy resources
cp -R Resources/* "$RESOURCES_DIR/" 2>/dev/null || true
cp "AppIcon.icns" "$RESOURCES_DIR/" 2>/dev/null || true
cp "icon.tiff" "$RESOURCES_DIR/" 2>/dev/null || true
cp "input-ko.tiff" "$RESOURCES_DIR/" 2>/dev/null || true
cp "input-en.tiff" "$RESOURCES_DIR/" 2>/dev/null || true
if [ -d "$BUILD_DIR/PriType_PriTypeCore.bundle" ]; then
    cp -R "$BUILD_DIR/PriType_PriTypeCore.bundle" "$RESOURCES_DIR/"
fi
find "$PAYLOAD_DIR" -name '._*' -delete
xattr -cr "$PAYLOAD_DIR/$APP_BUNDLE" 2>/dev/null || true

# Code Signing the App
echo "[3/6] Code Signing the .app bundle..."
if [ "$APP_SIGN_IDENTITY" = "-" ]; then
    echo "Using ad-hoc signature"
    codesign --force --sign - "$PAYLOAD_DIR/$APP_BUNDLE"
elif [[ "$APP_SIGN_IDENTITY" == "Developer ID Application:"* ]]; then
    echo "Using App Identity: $APP_SIGN_IDENTITY"
    codesign --force --options runtime --timestamp --sign "$APP_SIGN_IDENTITY" "$PAYLOAD_DIR/$APP_BUNDLE"
else
    # Apple's timestamp service only accepts Apple-issued certificates.
    echo "Using App Identity: $APP_SIGN_IDENTITY"
    codesign --force --sign "$APP_SIGN_IDENTITY" "$PAYLOAD_DIR/$APP_BUNDLE"
fi
codesign --verify --strict --verbose=2 "$PAYLOAD_DIR/$APP_BUNDLE"
codesign --display --requirements - "$PAYLOAD_DIR/$APP_BUNDLE" 2>&1 | grep designated || true

# Building the PKG
APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
PKG_VERSION="${APP_VERSION}"

echo "[4/6] Building the PKG installer..."

# Disable relocation by generating a component plist
echo "Generating component plist to disable relocation..."
pkgbuild --analyze --root "$PAYLOAD_DIR" "$COMPONENT_PLIST"
# Use plutil to change BundleIsRelocatable to false for the first item
plutil -replace 0.BundleIsRelocatable -bool NO "$COMPONENT_PLIST"

# The identifier predates the fork. Keep it so installs of earlier releases upgrade in place.
PKG_SIGN_ARGS=()
if [ -n "$PKG_SIGN_IDENTITY" ]; then
    echo "Using Installer Identity: $PKG_SIGN_IDENTITY"
    PKG_SIGN_ARGS=(--sign "$PKG_SIGN_IDENTITY")
else
    echo "Leaving the PKG unsigned"
fi
pkgbuild --root "$PAYLOAD_DIR" \
         --component-plist "$COMPONENT_PLIST" \
         --install-location "$INSTALL_DIR" \
         --scripts "Packaging/scripts" \
         --identifier "com.meapri.PriTypeV2" \
         --version "$PKG_VERSION" \
         "${PKG_SIGN_ARGS[@]}" \
         "$PKG_OUTPUT"

if [ -n "$KEYCHAIN_PROFILE" ]; then
    if [ -z "$PKG_SIGN_IDENTITY" ] || [[ "$APP_SIGN_IDENTITY" != "Developer ID Application:"* ]]; then
        echo "Error: notarization needs a Developer ID Application identity and a signed PKG." >&2
        exit 1
    fi
    echo "[5/6] Submitting for Notarization..."
    xcrun notarytool submit "$PKG_OUTPUT" --keychain-profile "$KEYCHAIN_PROFILE" --wait
    echo "Stapling Notarization Ticket..."
    xcrun stapler staple "$PKG_OUTPUT"
else
    echo "[5/6] Skipping notarization (KEYCHAIN_PROFILE not set)"
fi

echo "[6/6] Validating the package..."
if ! pkgutil --payload-files "$PKG_OUTPUT" | grep -q "PriTypeV2.app/Contents/MacOS/PriTypeV2$"; then
    echo "Error: the PKG payload is missing the app executable." >&2
    exit 1
fi
if [ -n "$PKG_SIGN_IDENTITY" ]; then
    pkgutil --check-signature "$PKG_OUTPUT"
fi
if [ -n "$KEYCHAIN_PROFILE" ]; then
    xcrun stapler validate "$PKG_OUTPUT"
    spctl -a -vv -t install "$PKG_OUTPUT"
fi
shasum -a 256 "$PKG_OUTPUT"

echo "=========================================="
echo "    Done! PKG created: $PKG_OUTPUT"
echo "=========================================="
