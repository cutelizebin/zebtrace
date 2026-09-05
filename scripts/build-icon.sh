#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [source-image]" >&2
    exit 2
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Building the ZebTrace icon requires macOS sips and iconutil." >&2
    exit 1
fi

ICON_SOURCE="${1:-$PROJECT_ROOT/Resources/AppIcon.png}"
if [[ "$ICON_SOURCE" != /* ]]; then
    ICON_SOURCE="$PWD/$ICON_SOURCE"
fi
if [[ ! -f "$ICON_SOURCE" || ! -r "$ICON_SOURCE" ]]; then
    echo "Icon source is missing or unreadable: $ICON_SOURCE" >&2
    exit 1
fi

if ! ICON_PROPERTIES="$(/usr/bin/sips --getProperty pixelWidth --getProperty pixelHeight "$ICON_SOURCE")"; then
    echo "Unable to read the icon source: $ICON_SOURCE" >&2
    exit 1
fi
ICON_WIDTH="$(/usr/bin/awk '/^[[:space:]]*pixelWidth:/ { print $2; exit }' <<< "$ICON_PROPERTIES")"
ICON_HEIGHT="$(/usr/bin/awk '/^[[:space:]]*pixelHeight:/ { print $2; exit }' <<< "$ICON_PROPERTIES")"
if [[ ! "$ICON_WIDTH" =~ ^[0-9]+$ || ! "$ICON_HEIGHT" =~ ^[0-9]+$ ]]; then
    echo "The icon source must be a readable raster image with pixel dimensions." >&2
    exit 1
fi
if (( ICON_WIDTH != ICON_HEIGHT || ICON_WIDTH < 1024 )); then
    echo "The icon source must be square and at least 1024 × 1024 pixels; received $ICON_WIDTH × $ICON_HEIGHT." >&2
    exit 1
fi

ICON_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/zebtrace-icon.XXXXXX")"
trap 'rm -rf "$ICON_BUILD_DIR"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
ICONSET_DIR="$ICON_BUILD_DIR/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"

# Render every standard 1x/2x representation directly from the source so that
# small icons never inherit artifacts from an already-downsampled intermediate.
for ICON_SIZE in 16 32 128 256 512; do
    for ICON_SCALE in 1 2; do
        ICON_PIXELS=$((ICON_SIZE * ICON_SCALE))
        ICON_SUFFIX=""
        if [[ "$ICON_SCALE" == 2 ]]; then ICON_SUFFIX="@2x"; fi
        /usr/bin/sips --setProperty format png \
            --resampleHeightWidth "$ICON_PIXELS" "$ICON_PIXELS" "$ICON_SOURCE" \
            --out "$ICONSET_DIR/icon_${ICON_SIZE}x${ICON_SIZE}${ICON_SUFFIX}.png" >/dev/null
    done
done

/usr/bin/iconutil --convert icns --output "$ICON_BUILD_DIR/AppIcon.icns" "$ICONSET_DIR"
ICON_OUTPUT="$PROJECT_ROOT/Resources/AppIcon.icns"
mkdir -p "$PROJECT_ROOT/Resources"
mv -f "$ICON_BUILD_DIR/AppIcon.icns" "$ICON_OUTPUT"
echo "Built icon: $ICON_OUTPUT"
