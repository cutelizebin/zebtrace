#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_OUTPUT_DIR:-$PROJECT_ROOT/dist}"
if [[ "$BUILD_DIR" != /* ]]; then BUILD_DIR="$PROJECT_ROOT/$BUILD_DIR"; fi
"$PROJECT_ROOT/scripts/build.sh"
/usr/bin/open "$BUILD_DIR/ZebTrace.app"
echo "ZebTrace is in the menu bar. Use its menu to start recording."
