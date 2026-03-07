#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_NAME="orcv"
DERIVED_DIR="$BUILD_DIR/DerivedData"
PRODUCT_APP="$DERIVED_DIR/Build/Products/Release/$APP_NAME.app"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
DEFAULT_VERSION="0.1.0"

RESOLVED_VERSION="${ORCV_VERSION:-}"
if [ -z "$RESOLVED_VERSION" ]; then
  TAG_ON_HEAD="$(git -C "$ROOT_DIR" describe --tags --exact-match 2>/dev/null || true)"
  if [[ "$TAG_ON_HEAD" == v* ]]; then
    RESOLVED_VERSION="${TAG_ON_HEAD#v}"
  fi
fi
if [ -z "$RESOLVED_VERSION" ]; then
  RESOLVED_VERSION="$DEFAULT_VERSION"
fi

if ! [[ "$RESOLVED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: resolved version '$RESOLVED_VERSION' is not semver (X.Y.Z)" >&2
  exit 1
fi

RESOLVED_BUILD_NUMBER="${ORCV_BUILD_NUMBER:-1}"
if ! [[ "$RESOLVED_BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "error: ORCV_BUILD_NUMBER must be numeric (got '$RESOLVED_BUILD_NUMBER')" >&2
  exit 1
fi

echo "Building $APP_NAME version $RESOLVED_VERSION ($RESOLVED_BUILD_NUMBER)"

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
  MARKETING_VERSION="$RESOLVED_VERSION" \
  CURRENT_PROJECT_VERSION="$RESOLVED_BUILD_NUMBER" \
  INFOPLIST_KEY_CFBundleShortVersionString="$RESOLVED_VERSION" \
  INFOPLIST_KEY_CFBundleVersion="$RESOLVED_BUILD_NUMBER" \
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
