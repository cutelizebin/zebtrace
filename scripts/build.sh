#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${BUILD_OUTPUT_DIR:-$PROJECT_ROOT/dist}"
if [[ "$DIST_DIR" != /* ]]; then DIST_DIR="$PROJECT_ROOT/$DIST_DIR"; fi
cd "$PROJECT_ROOT"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "ZebTrace requires macOS 14.2 or later to build and run." >&2
    exit 1
fi

CONFIGURATION="${BUILD_CONFIGURATION:-release}"
case "$CONFIGURATION" in
    debug|release) ;;
    *) echo "BUILD_CONFIGURATION must be debug or release." >&2; exit 1 ;;
esac
ARCHITECTURES="${BUILD_ARCHITECTURES:-native}"
case "$ARCHITECTURES" in
    native|universal) ;;
    *) echo "BUILD_ARCHITECTURES must be native or universal." >&2; exit 1 ;;
esac

# A fresh source copy can build independently of an installed, running app.
# Existing output bundles remain protected from replacement while either app runs.
protect_existing_bundle() {
    if [[ -e "$DIST_DIR/ZebTrace.app" ]] && /usr/bin/pgrep -x 'ZebTrace|MyContext' >/dev/null 2>&1; then
        echo "Quit ZebTrace and any legacy MyContext instance before replacing $DIST_DIR/ZebTrace.app." >&2
        exit 1
    fi
}
protect_existing_bundle

ICON_PATH="$PROJECT_ROOT/Resources/AppIcon.icns"
if [[ ! -s "$ICON_PATH" ]]; then
    echo "Missing or empty app icon: $ICON_PATH. Restore the icon resource before building." >&2
    exit 1
fi

mkdir -p "$DIST_DIR"
STAGING_DIR="$(mktemp -d "$DIST_DIR/.ZebTrace-build.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
APP_PATH="$STAGING_DIR/ZebTrace.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
if [[ "$ARCHITECTURES" == "universal" ]]; then
    BIN_DIRS=()
    for ARCH in arm64 x86_64; do
        swift build --configuration "$CONFIGURATION" --arch "$ARCH" --product ZebTrace
        BIN_DIRS+=("$(swift build --configuration "$CONFIGURATION" --arch "$ARCH" --show-bin-path)")
    done
    /usr/bin/lipo -create "${BIN_DIRS[0]}/ZebTrace" "${BIN_DIRS[1]}/ZebTrace" \
        -output "$APP_PATH/Contents/MacOS/ZebTrace"
    BIN_DIR="${BIN_DIRS[0]}"
else
    swift build --configuration "$CONFIGURATION" --product ZebTrace
    BIN_DIR="$(swift build --configuration "$CONFIGURATION" --show-bin-path)"
    cp "$BIN_DIR/ZebTrace" "$APP_PATH/Contents/MacOS/ZebTrace"
fi

RESOURCE_BUNDLE="$BIN_DIR/ZebTrace_ZebTraceCore.bundle"
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
    echo "SwiftPM localization bundle is missing: $RESOURCE_BUNDLE" >&2
    exit 1
fi
/usr/bin/ditto "$RESOURCE_BUNDLE" "$APP_PATH/Contents/Resources/ZebTrace_ZebTraceCore.bundle"
for LANGUAGE in en zh-Hans; do
    LOCALIZATION="$PROJECT_ROOT/Resources/$LANGUAGE.lproj/InfoPlist.strings"
    /usr/bin/plutil -lint "$LOCALIZATION"
    mkdir -p "$APP_PATH/Contents/Resources/$LANGUAGE.lproj"
    cp "$LOCALIZATION" "$APP_PATH/Contents/Resources/$LANGUAGE.lproj/InfoPlist.strings"
done
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
cp "$PROJECT_ROOT/LICENSE" "$APP_PATH/Contents/Resources/LICENSE"
cp "$ICON_PATH" "$APP_PATH/Contents/Resources/AppIcon.icns"
test -s "$APP_PATH/Contents/Resources/AppIcon.icns"
chmod 755 "$APP_PATH/Contents/MacOS/ZebTrace"
/usr/bin/plutil -lint "$APP_PATH/Contents/Info.plist"

# Swift's linker may include the build machine's Xcode toolchain in LC_RPATH.
# Remove these fallback paths from the staged copy before signing; leave the
# SwiftPM cache untouched and keep Apple system / app-relative search paths.
RPATHS="$(/usr/bin/otool -l "$APP_PATH/Contents/MacOS/ZebTrace" | /usr/bin/awk '
    $1 == "cmd" && $2 == "LC_RPATH" { rpath = 1; next }
    rpath && $1 == "path" {
        sub(/^[[:space:]]*path /, ""); sub(/ \(offset [0-9]+\)$/, ""); print; rpath = 0
    }' | /usr/bin/sort -u)"
while IFS= read -r RPATH; do
    case "$RPATH" in
        /usr/lib/*|/System/Library/*|@loader_path*|@executable_path*|"") ;;
        /*) /usr/bin/install_name_tool -delete_rpath "$RPATH" "$APP_PATH/Contents/MacOS/ZebTrace" ;;
        *) echo "Unsupported runtime search path: $RPATH" >&2; exit 1 ;;
    esac
done <<< "$RPATHS"

# Ad-hoc signing is sufficient for a local demo. A stable identifier is retained
# across builds; ad-hoc signatures may still cause macOS to request access again.
SIGNING_IDENTITY="${CODESIGN_IDENTITY:--}"
TIMESTAMP_ARGUMENT="--timestamp"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then TIMESTAMP_ARGUMENT="--timestamp=none"; fi
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" \
    --identifier org.zebtrace.app --options runtime "$TIMESTAMP_ARGUMENT" \
    --entitlements "$PROJECT_ROOT/Resources/ZebTrace.entitlements" "$APP_PATH"
"$PROJECT_ROOT/scripts/verify-app.sh" "$APP_PATH" "$ARCHITECTURES"

protect_existing_bundle
rm -rf "$DIST_DIR/ZebTrace.app"
mv "$APP_PATH" "$DIST_DIR/ZebTrace.app"
echo "Built: $DIST_DIR/ZebTrace.app"
