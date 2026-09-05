#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_OUTPUT_DIR:-$PROJECT_ROOT/dist}"
if [[ "$BUILD_DIR" != /* ]]; then BUILD_DIR="$PROJECT_ROOT/$BUILD_DIR"; fi
INSTALL_DIR="$HOME/Applications"
DESTINATION="$INSTALL_DIR/ZebTrace.app"

if /usr/bin/pgrep -x 'ZebTrace|MyContext' >/dev/null 2>&1; then
    echo "Quit ZebTrace and any legacy MyContext instance before installing an update." >&2
    exit 1
fi
"$PROJECT_ROOT/scripts/build.sh"
mkdir -p "$INSTALL_DIR"
STAGING_DIR="$(mktemp -d "$INSTALL_DIR/.ZebTrace-install.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
/usr/bin/ditto "$BUILD_DIR/ZebTrace.app" "$STAGING_DIR/ZebTrace.app"
/usr/bin/codesign --verify --strict --verbose=2 "$STAGING_DIR/ZebTrace.app"

if /usr/bin/pgrep -x 'ZebTrace|MyContext' >/dev/null 2>&1; then
    echo "ZebTrace or legacy MyContext started during installation. Quit it, then run this command again." >&2
    exit 1
fi
rm -rf "$DESTINATION"
mv "$STAGING_DIR/ZebTrace.app" "$DESTINATION"
echo "Installed: $DESTINATION"
echo "Launch with: open ~/Applications/ZebTrace.app"
