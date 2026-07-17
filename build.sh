#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/WireProxyMenu"

# Build in /tmp to avoid iCloud re-adding extended attributes;
# unique per run so concurrent/multi-user builds can't collide.
TMP_DIR="$(mktemp -d /tmp/WireProxyMenu_build.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT
APP_DIR="$TMP_DIR/WireProxyMenu.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

# Final destination (inside project, for reference)
FINAL_DIR="$SCRIPT_DIR/build"

SDK=$(xcrun --show-sdk-path)

echo "→ Cleaning..."
rm -rf "$FINAL_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

echo "→ Compiling Swift sources..."
swiftc \
  -sdk "$SDK" \
  -target arm64-apple-macosx13.0 \
  -framework AppKit \
  -framework SwiftUI \
  -framework UniformTypeIdentifiers \
  -O \
  -o "$MACOS_DIR/WireProxyMenu" \
  "$SRC_DIR/WireProxyMenuApp.swift" \
  "$SRC_DIR/AppDelegate.swift" \
  "$SRC_DIR/StatusBarController.swift" \
  "$SRC_DIR/WireproxyManager.swift"

echo "→ Copying icons..."
cp "$SRC_DIR/AppIcon.icns"   "$RESOURCES_DIR/AppIcon.icns"
cp "$SRC_DIR/menubar.png"    "$RESOURCES_DIR/menubar.png"
cp "$SRC_DIR/menubar@2x.png" "$RESOURCES_DIR/menubar@2x.png"

echo "→ Bundling wireproxy binary..."
cp "$SRC_DIR/wireproxy" "$MACOS_DIR/wireproxy"
chmod +x "$MACOS_DIR/wireproxy"

echo "→ Writing Info.plist..."
sed \
  -e 's/$(EXECUTABLE_NAME)/WireProxyMenu/g' \
  -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/com.wireproxymenu.app/g' \
  -e 's/$(PRODUCT_NAME)/WireProxyMenu/g' \
  -e 's/$(PRODUCT_BUNDLE_PACKAGE_TYPE)/APPL/g' \
  -e 's/$(MARKETING_VERSION)/1.2.0/g' \
  -e 's/$(CURRENT_PROJECT_VERSION)/3/g' \
  -e 's/$(MACOSX_DEPLOYMENT_TARGET)/13.0/g' \
  -e 's/$(DEVELOPMENT_LANGUAGE)/en/g' \
  "$SRC_DIR/Info.plist" > "$CONTENTS_DIR/Info.plist"

echo "→ Ad-hoc signing..."
# Sign inside-out (nested binary first) instead of deprecated --deep
codesign --force --sign - "$MACOS_DIR/wireproxy"
codesign --force --sign - \
  --entitlements "$SRC_DIR/WireProxyMenu.entitlements" \
  "$APP_DIR"

echo "→ Creating release zip..."
# Zip from the pristine /tmp copy so the archived app always carries a
# clean, verifiable signature — iCloud xattrs only ever hit build/.
ditto -c -k --keepParent "$APP_DIR" "$TMP_DIR/WireProxyMenu.zip"

echo "→ Copying to build/..."
mkdir -p "$FINAL_DIR"
cp -r "$APP_DIR" "$FINAL_DIR/"
cp "$TMP_DIR/WireProxyMenu.zip" "$FINAL_DIR/"
# iCloud/Finder may re-attach xattrs on the copy, which breaks strict
# signature validation; strip them (iCloud can still re-add later, hence
# the xattr -cr step in the README)
xattr -cr "$FINAL_DIR/WireProxyMenu.app"

echo ""
echo "✓ Done! App built at:"
echo "  $FINAL_DIR/WireProxyMenu.app"
echo ""
echo "To run:"
echo "  open \"$FINAL_DIR/WireProxyMenu.app\""
