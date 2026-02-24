#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_NAME="WorkspaceGrid"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
BIN_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"

if [[ -z "${SIGNING_IDENTITY:-}" ]]; then
  SIGNING_IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"\(.*\)"/\1/p' \
      | head -n 1
  )"
fi

if [[ -z "${SIGNING_IDENTITY:-}" ]]; then
  SIGNING_IDENTITY="-"
  echo "warning: no code-signing identity found, using ad-hoc signing"
else
  echo "Signing with identity: $SIGNING_IDENTITY"
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BIN_DIR" "$RES_DIR"

swiftc \
  -O \
  -import-objc-header "$ROOT_DIR/WorkspaceGrid-Bridging-Header.h" \
  -framework Foundation \
  -framework AppKit \
  -framework CoreGraphics \
  -framework CoreMedia \
  -framework CoreVideo \
  -framework IOSurface \
  -framework ScreenCaptureKit \
  -o "$BIN_DIR/$APP_NAME" \
  "$ROOT_DIR/main.swift" \
  "$ROOT_DIR/AppDelegate.swift" \
  "$ROOT_DIR/ScreenCaptureAuthorization.swift" \
  "$ROOT_DIR/Models.swift" \
  "$ROOT_DIR/ShortcutManager.swift" \
  "$ROOT_DIR/ShortcutSettingsWindowController.swift" \
  "$ROOT_DIR/WorkspaceStateStore.swift" \
  "$ROOT_DIR/WorkspaceStore.swift" \
  "$ROOT_DIR/VirtualDisplayManager.swift" \
  "$ROOT_DIR/DisplayStreamManager.swift" \
  "$ROOT_DIR/PointerMath.swift" \
  "$ROOT_DIR/PointerRouter.swift" \
  "$ROOT_DIR/InputMacroEngine.swift" \
  "$ROOT_DIR/WorkspacePreviewWindowController.swift" \
  "$ROOT_DIR/WorkspaceGridView.swift" \
  "$ROOT_DIR/WorkspaceRootViewController.swift"

cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/WorkspaceGrid.entitlements" "$RES_DIR/WorkspaceGrid.entitlements"

codesign --force --deep --sign "$SIGNING_IDENTITY" \
  --entitlements "$ROOT_DIR/WorkspaceGrid.entitlements" \
  "$APP_DIR"

codesign --verify --verbose "$APP_DIR"

echo "Built: $APP_DIR"
echo "Run:   $APP_DIR/Contents/MacOS/$APP_NAME"
