#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/WireProxyMenu"

# Build in /tmp to avoid iCloud re-adding extended attributes
TMP_DIR="/tmp/WireProxyMenu_build"
APP_DIR="$TMP_DIR/WireProxyMenu.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

# Final destination (inside project, for reference)
FINAL_DIR="$SCRIPT_DIR/build"

SDK=$(xcrun --show-sdk-path)

echo "→ Cleaning..."
rm -rf "$TMP_DIR" "$FINAL_DIR"
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
  -e 's/$(MARKETING_VERSION)/1.0/g' \
  -e 's/$(CURRENT_PROJECT_VERSION)/1/g' \
  -e 's/$(MACOSX_DEPLOYMENT_TARGET)/13.0/g' \
  -e 's/$(DEVELOPMENT_LANGUAGE)/en/g' \
  "$SRC_DIR/Info.plist" > "$CONTENTS_DIR/Info.plist"

echo "→ Ad-hoc signing..."
codesign --force --deep --sign - \
  --entitlements "$SRC_DIR/WireProxyMenu.entitlements" \
  "$APP_DIR"

echo "→ Copying to build/..."
mkdir -p "$FINAL_DIR"
cp -r "$APP_DIR" "$FINAL_DIR/"

echo ""
echo "✓ Done! App built at:"
echo "  $FINAL_DIR/WireProxyMenu.app"
echo ""
echo "To run:"
echo "  open \"$FINAL_DIR/WireProxyMenu.app\""
