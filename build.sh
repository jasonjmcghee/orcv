#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_NAME="orcv"
DERIVED_DIR="$BUILD_DIR/DerivedData"
PRODUCT_APP="$DERIVED_DIR/Build/Products/Release/$APP_NAME.app"
APP_DIR="$BUILD_DIR/$APP_NAME.app"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild not found. Install Xcode or run on a macOS runner with Xcode preinstalled." >&2
  exit 1
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

xcodebuild \
  -project "$ROOT_DIR/orcv.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -derivedDataPath "$DERIVED_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

ditto "$PRODUCT_APP" "$APP_DIR"
codesign --force --deep --sign - "$APP_DIR"

codesign --verify --verbose "$APP_DIR"

DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"
if ! "$ROOT_DIR/create_dmg.sh" "$APP_DIR" "$DMG_PATH" "$APP_NAME"; then
  echo "warning: DMG creation failed; app build is still available at $APP_DIR" >&2
fi

echo "Built: $APP_DIR"
echo "Run:   $APP_DIR/Contents/MacOS/$APP_NAME"
if [ -f "$DMG_PATH" ]; then
  echo "DMG:   $DMG_PATH"
fi
