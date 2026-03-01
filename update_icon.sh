#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_SOURCE="$ROOT_DIR/assets/orcv-Icon-iOS-Default-1024x1024@1x.png"
APPICONSET_DIR="$ROOT_DIR/orcv/Assets.xcassets/AppIcon.appiconset"

usage() {
    cat <<'EOF'
Usage:
  ./update_icon.sh [source_png]

If source_png is omitted, this default is used:
  assets/orcv-Icon-iOS-Default-1024x1024@1x.png
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ $# -gt 1 ]]; then
    usage
    exit 1
fi

SOURCE_IMAGE="${1:-$DEFAULT_SOURCE}"

if [[ ! -f "$SOURCE_IMAGE" ]]; then
    echo "error: source image not found: $SOURCE_IMAGE" >&2
    exit 1
fi

if ! command -v sips >/dev/null 2>&1; then
    echo "error: 'sips' is required but not found" >&2
    exit 1
fi

if [[ ! -d "$APPICONSET_DIR" ]]; then
    echo "error: app icon set directory not found: $APPICONSET_DIR" >&2
    exit 1
fi

render_icon() {
    local size="$1"
    local filename="$2"
    /usr/bin/sips -z "$size" "$size" "$SOURCE_IMAGE" --out "$APPICONSET_DIR/$filename" >/dev/null
}

render_icon 16 "icon_16x16.png"
render_icon 32 "icon_16x16@2x.png"
render_icon 32 "icon_32x32.png"
render_icon 64 "icon_32x32@2x.png"
render_icon 128 "icon_128x128.png"
render_icon 256 "icon_128x128@2x.png"
render_icon 256 "icon_256x256.png"
render_icon 512 "icon_256x256@2x.png"
render_icon 512 "icon_512x512.png"
render_icon 1024 "icon_512x512@2x.png"

echo "Updated AppIcon.appiconset from: $SOURCE_IMAGE"
