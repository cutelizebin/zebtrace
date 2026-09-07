#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:---preview}"
if [[ $# -gt 1 || ( "$MODE" != "--preview" && "$MODE" != "--release" ) ]]; then
    echo "Usage: $0 [--preview|--release]" >&2
    exit 2
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Packaging requires macOS with the Xcode command-line tools." >&2
    exit 1
fi

SIGNING_IDENTITY="-"
NOTARY_ARGUMENTS=()
if [[ "$MODE" == "--release" ]]; then
    SIGNING_IDENTITY="${CODESIGN_IDENTITY:-}"
    if [[ "$SIGNING_IDENTITY" != "Developer ID Application: "* || -z "${NOTARYTOOL_PROFILE:-}" ]]; then
        echo "Release packaging requires CODESIGN_IDENTITY='Developer ID Application: ...' and NOTARYTOOL_PROFILE." >&2
        echo "Use --preview for an explicitly unnotarized local package; release mode never falls back." >&2
        exit 1
    fi
    NOTARY_ARGUMENTS=(--keychain-profile "$NOTARYTOOL_PROFILE")
    if [[ -n "${NOTARYTOOL_KEYCHAIN:-}" ]]; then
        NOTARY_ARGUMENTS+=(--keychain "$NOTARYTOOL_KEYCHAIN")
    fi
    /usr/bin/xcrun --find notarytool >/dev/null
    /usr/bin/xcrun --find stapler >/dev/null
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_ROOT/Resources/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PROJECT_ROOT/Resources/Info.plist")"
MINIMUM_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PROJECT_ROOT/Resources/Info.plist")"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]; then
    echo "Unsupported application version for an artifact filename: $VERSION" >&2
    exit 1
fi
STEM="ZebTrace-$VERSION-universal"
if [[ "$MODE" == "--preview" ]]; then STEM="$STEM-preview-unnotarized"; fi
OUTPUT_BASE="${RELEASE_OUTPUT_DIR:-$PROJECT_ROOT/dist/releases}"
if [[ "$OUTPUT_BASE" != /* ]]; then OUTPUT_BASE="$PROJECT_ROOT/$OUTPUT_BASE"; fi
DESTINATION="$OUTPUT_BASE/$STEM"
if [[ -e "$DESTINATION" ]]; then
    echo "Package already exists: $DESTINATION. Choose another RELEASE_OUTPUT_DIR or remove that generated package first." >&2
    exit 1
fi
mkdir -p "$OUTPUT_BASE"
STAGING_DIR="$(mktemp -d "$OUTPUT_BASE/.zebtrace-package.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Always use a separate bundle location, leaving any running native demo alone.
BUILD_CONFIGURATION=release BUILD_ARCHITECTURES=universal \
    BUILD_OUTPUT_DIR="$STAGING_DIR/build" CODESIGN_IDENTITY="$SIGNING_IDENTITY" \
    "$PROJECT_ROOT/scripts/build.sh"
APP_PATH="$STAGING_DIR/build/ZebTrace.app"
ARTIFACTS="$STAGING_DIR/artifacts"
mkdir -p "$ARTIFACTS"

notarize() {
    local artifact="$1" report="$2" status
    /usr/bin/xcrun notarytool submit "$artifact" "${NOTARY_ARGUMENTS[@]}" \
        --wait --timeout "${NOTARIZATION_TIMEOUT:-30m}" --output-format json > "$report"
    status="$(/usr/bin/plutil -extract status raw -o - "$report")"
    if [[ "$status" != "Accepted" ]]; then
        echo "Notarization did not succeed ($status): $artifact" >&2
        /bin/cat "$report" >&2
        exit 1
    fi
}

if [[ "$MODE" == "--release" ]]; then
    SIGNATURE="$(/usr/bin/codesign --display --verbose=4 "$APP_PATH" 2>&1)"
    if [[ "$SIGNATURE" != *"Authority=Developer ID Application:"* ]]; then
        echo "The app was not signed with a Developer ID Application certificate." >&2
        exit 1
    fi
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$STAGING_DIR/notary-app.zip"
    notarize "$STAGING_DIR/notary-app.zip" "$STAGING_DIR/notary-app.json"
    /usr/bin/xcrun stapler staple "$APP_PATH"
    /usr/bin/xcrun stapler validate "$APP_PATH"
    /usr/sbin/spctl --assess --type execute --verbose=2 "$APP_PATH"
fi

# Create the downloadable ZIP after stapling the app, so its ticket travels with it.
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARTIFACTS/$STEM.zip"
DMG_ROOT="$STAGING_DIR/dmg-root"
mkdir -p "$DMG_ROOT"
/usr/bin/ditto "$APP_PATH" "$DMG_ROOT/ZebTrace.app"
ln -s /Applications "$DMG_ROOT/Applications"
cat > "$DMG_ROOT/INSTALL.txt" <<EOF
ZebTrace $VERSION — macOS $MINIMUM_MACOS or later / 或更高版本

Drag ZebTrace.app to Applications, then open it from Applications.
Start recording from the menu bar and allow microphone/system audio when asked.
No Homebrew, Swift, Xcode, or command-line setup is needed to run the app.
Recording Review downloads about 3.1 GB of models once, then transcribes and summarizes locally.

将 ZebTrace.app 拖入 Applications，然后从“应用程序”打开。
从菜单栏开始记录，并按系统提示允许麦克风和系统声音访问。
运行应用无需安装 Homebrew、Swift 或 Xcode。
从“录音回顾”首次下载约 3.1 GB 模型，之后在本地转写与总结。
EOF
if [[ "$MODE" == "--preview" ]]; then
    cat >> "$DMG_ROOT/INSTALL.txt" <<'EOF'

UNNOTARIZED PREVIEW: first launch may require manual approval in macOS Privacy & Security.
First try opening ZebTrace from Applications. If macOS blocks it and you have confirmed
that the download came from the project's official release and has not been modified,
open System Settings > Privacy & Security > Open Anyway, then confirm Open again.

未公证预览：首次打开可能需要在 macOS“隐私与安全性”中手动允许。
先从“应用程序”尝试打开 ZebTrace。如果被 macOS 拦截，且你确认下载来自项目官方
发行页面并且未被修改，请进入“系统设置 > 隐私与安全性 > 仍要打开”，再确认“打开”。

Apple's instructions / Apple 官方说明: https://support.apple.com/en-us/102445
EOF
fi
/usr/bin/hdiutil create -volname "ZebTrace $VERSION" -srcfolder "$DMG_ROOT" \
    -format UDZO -fs HFS+ "$ARTIFACTS/$STEM.dmg"
if [[ "$MODE" == "--release" ]]; then
    /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$ARTIFACTS/$STEM.dmg"
    notarize "$ARTIFACTS/$STEM.dmg" "$STAGING_DIR/notary-dmg.json"
    /usr/bin/xcrun stapler staple "$ARTIFACTS/$STEM.dmg"
    /usr/bin/xcrun stapler validate "$ARTIFACTS/$STEM.dmg"
    /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$ARTIFACTS/$STEM.dmg"
fi
/usr/bin/hdiutil verify "$ARTIFACTS/$STEM.dmg"
"$PROJECT_ROOT/scripts/verify-app.sh" "$DMG_ROOT/ZebTrace.app" universal

if [[ "$MODE" == "--release" ]]; then
    DISTRIBUTION_STATUS="Developer ID signed; Apple notarization Accepted; app and DMG tickets stapled."
else
    DISTRIBUTION_STATUS="UNNOTARIZED PREVIEW; ad-hoc signed; first launch may require manual approval in macOS Privacy & Security."
fi
cat > "$ARTIFACTS/PACKAGE-INFO.txt" <<EOF
ZebTrace $VERSION (build $BUILD_NUMBER)
Architectures: arm64 and x86_64 (Universal)
Minimum macOS: $MINIMUM_MACOS
Status: $DISTRIBUTION_STATUS
Runtime dependencies: Apple system frameworks and libraries; no developer toolchain required.
Install: open the DMG and drag ZebTrace.app into Applications, or extract the ZIP.
Recording always starts manually; macOS audio permissions are still required.
EOF
if [[ "$MODE" == "--preview" ]]; then
    cat >> "$ARTIFACTS/PACKAGE-INFO.txt" <<'EOF'
Unnotarized first launch: try opening from Applications; if blocked and you trust the
official download, use System Settings > Privacy & Security > Open Anyway, then Open.
Apple instructions: https://support.apple.com/en-us/102445
EOF
fi
(
    cd "$ARTIFACTS"
    /usr/bin/shasum -a 256 "$STEM.zip" "$STEM.dmg" PACKAGE-INFO.txt > SHA256SUMS
    /usr/bin/shasum -a 256 -c SHA256SUMS
)
# Only expose final artifacts after all checks have succeeded.
if [[ -e "$DESTINATION" ]]; then
    echo "Another package now exists at $DESTINATION; refusing to replace it." >&2
    exit 1
fi
mv "$ARTIFACTS" "$DESTINATION"
echo "Packaged: $DESTINATION"
echo "$DISTRIBUTION_STATUS"
