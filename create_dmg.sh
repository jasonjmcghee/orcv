#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="${1:-$ROOT_DIR/build/orcv.app}"
OUTPUT_DMG="${2:-$ROOT_DIR/build/orcv.dmg}"
VOLUME_NAME="${3:-orcv}"

if [ ! -d "$APP_PATH" ]; then
  echo "error: app bundle not found at '$APP_PATH'" >&2
  exit 1
fi

# Required static DMG layout assets (CI-safe, no Finder scripting).
if [ ! -f "$ROOT_DIR/assets/dmg/.DS_Store" ]; then
  echo "error: missing assets/dmg/.DS_Store" >&2
  echo "generate it locally with: python3 ./generate_dmg_ds_store.py" >&2
  exit 1
fi

APP_NAME="$(basename "$APP_PATH")"
WORK_DIR="$(mktemp -d /tmp/orcv-dmg.XXXXXX)"
TEMP_DMG="$WORK_DIR/temp.dmg"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# Calculate a generous size for the temp read-write image.
APP_SIZE_KB=$(du -sk "$APP_PATH" | awk '{print $1}')
DMG_SIZE_KB=$(( APP_SIZE_KB + 20480 ))  # app + 20 MB headroom

# Step 1: Create a read-write DMG and mount it.
hdiutil create \
  -volname "$VOLUME_NAME" \
  -size "${DMG_SIZE_KB}k" \
  -fs HFS+ \
  -layout SPUD \
  "$TEMP_DMG" >/dev/null

MOUNT_DIR="$(mktemp -d /tmp/orcv-dmg-mount.XXXXXX)"
hdiutil attach "$TEMP_DMG" -mountpoint "$MOUNT_DIR" -nobrowse -quiet

# Step 2: Populate the mounted volume directly.
cp -R "$APP_PATH" "$MOUNT_DIR/$APP_NAME"
ln -s /Applications "$MOUNT_DIR/Applications"
cp "$ROOT_DIR/assets/dmg/.DS_Store" "$MOUNT_DIR/.DS_Store"
if [ -d "$ROOT_DIR/assets/dmg/.background" ]; then
  cp -R "$ROOT_DIR/assets/dmg/.background" "$MOUNT_DIR/.background"
fi

# Step 3: Detach the volume.
hdiutil detach "$MOUNT_DIR" -quiet
rmdir "$MOUNT_DIR"

# Step 4: Convert to compressed read-only DMG.
mkdir -p "$(dirname "$OUTPUT_DMG")"
rm -f "$OUTPUT_DMG"
hdiutil convert "$TEMP_DMG" \
  -format UDZO \
  -o "$OUTPUT_DMG" >/dev/null

# Verify final DMG payload contains expected drag-and-drop targets.
VERIFY_MOUNT="$(mktemp -d /tmp/orcv-dmg-verify.XXXXXX)"
hdiutil attach "$OUTPUT_DMG" -mountpoint "$VERIFY_MOUNT" -nobrowse -quiet
if [ ! -d "$VERIFY_MOUNT/$APP_NAME" ] || [ ! -L "$VERIFY_MOUNT/Applications" ]; then
  hdiutil detach "$VERIFY_MOUNT" -quiet || true
  rmdir "$VERIFY_MOUNT" || true
  echo "error: DMG missing required root items ($APP_NAME and/or Applications shortcut)" >&2
  exit 1
fi
hdiutil detach "$VERIFY_MOUNT" -quiet
rmdir "$VERIFY_MOUNT"

echo "Created DMG: $OUTPUT_DMG"
