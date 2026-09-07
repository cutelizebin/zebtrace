#!/bin/bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 /path/to/ZebTrace.app [native|universal]" >&2
    exit 2
fi
APP_PATH="$(cd "$1" && pwd -P)"
EXPECTED_ARCHITECTURES="${2:-native}"
case "$EXPECTED_ARCHITECTURES" in
    native|universal) ;;
    *) echo "Expected native or universal architecture mode." >&2; exit 2 ;;
esac
EXECUTABLE_DIR="$APP_PATH/Contents/MacOS"
EXECUTABLE="$EXECUTABLE_DIR/ZebTrace"
test -x "$EXECUTABLE"
test -s "$APP_PATH/Contents/Resources/AppIcon.icns"
test -d "$APP_PATH/Contents/Resources/ZebTrace_ZebTraceCore.bundle"
test -x "$APP_PATH/Contents/Helpers/whisper-cli"
test -x "$APP_PATH/Contents/Helpers/llama-completion"
test -s "$APP_PATH/Contents/Resources/InferenceRuntime/runtime-info.json"
test -d "$APP_PATH/Contents/Resources/InferenceLicenses"
/usr/bin/plutil -lint "$APP_PATH/Contents/Info.plist"
DECLARED_MINIMUM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP_PATH/Contents/Info.plist")"
if [[ ! "$DECLARED_MINIMUM" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo "Invalid minimum macOS version in the app Info.plist." >&2
    exit 1
fi
LOCALIZATION_INDEX=0
while LANGUAGE="$(/usr/libexec/PlistBuddy -c "Print :CFBundleLocalizations:$LOCALIZATION_INDEX" "$APP_PATH/Contents/Info.plist" 2>/dev/null)"; do
    if [[ ! "$LANGUAGE" =~ ^[A-Za-z0-9]+(-[A-Za-z0-9]+)*$ ]]; then
        echo "Invalid localization identifier in Info.plist: $LANGUAGE" >&2
        exit 1
    fi
    /usr/bin/plutil -lint "$APP_PATH/Contents/Resources/$LANGUAGE.lproj/InfoPlist.strings"
    CORE_STRINGS="$APP_PATH/Contents/Resources/ZebTrace_ZebTraceCore.bundle/$LANGUAGE.lproj/Localizable.strings"
    if [[ ! -f "$CORE_STRINGS" ]]; then
        # SwiftPM normalizes localization directory names to lowercase.
        NORMALIZED_LANGUAGE="$(printf '%s' "$LANGUAGE" | /usr/bin/tr '[:upper:]' '[:lower:]')"
        CORE_STRINGS="$APP_PATH/Contents/Resources/ZebTrace_ZebTraceCore.bundle/$NORMALIZED_LANGUAGE.lproj/Localizable.strings"
    fi
    test -s "$CORE_STRINGS"
    /usr/bin/plutil -lint "$CORE_STRINGS"
    LOCALIZATION_INDEX=$((LOCALIZATION_INDEX + 1))
done
if [[ "$LOCALIZATION_INDEX" -eq 0 ]]; then
    echo "Info.plist must declare at least one CFBundleLocalizations entry." >&2
    exit 1
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"

expand_path() {
    case "$1" in
        @executable_path*) printf '%s%s\n' "$EXECUTABLE_DIR" "${1#@executable_path}" ;;
        @loader_path*) printf '%s%s\n' "$LOADER_DIR" "${1#@loader_path}" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

is_bundled_file() {
    [[ -f "$1" && ! -L "$1" ]] || return 1
    local directory
    directory="$(cd "$(dirname "$1")" && pwd -P)" || return 1
    [[ "$directory/" == "$APP_PATH/"* ]]
}

# Inspect every Mach-O, including any future bundled framework. Non-system
# dependencies must resolve inside this app, never to Homebrew or an SDK folder.
while IFS= read -r -d '' BINARY; do
    DESCRIPTION="$(/usr/bin/file -b "$BINARY")"
    [[ "$DESCRIPTION" == *Mach-O* ]] || continue
    ARCHITECTURES="$(/usr/bin/lipo -archs "$BINARY")"
    if [[ "$EXPECTED_ARCHITECTURES" == "universal" ]]; then
        /usr/bin/lipo "$BINARY" -verify_arch arm64 x86_64
    fi
    LOADER_DIR="$(dirname "$BINARY")"
    for ARCHITECTURE in $ARCHITECTURES; do
        case "$ARCHITECTURE" in
            arm64|x86_64) ;;
            *) echo "Unsupported architecture: $ARCHITECTURE in $BINARY" >&2; exit 1 ;;
        esac
        LOAD_COMMANDS="$(/usr/bin/otool -arch "$ARCHITECTURE" -l "$BINARY")"
        MINIMUM_OS="$(/usr/bin/awk '
            $1 == "cmd" { command = $2 }
            command == "LC_BUILD_VERSION" && $1 == "minos" { print $2 }
            command == "LC_VERSION_MIN_MACOSX" && $1 == "version" { print $2 }
            ' <<< "$LOAD_COMMANDS")"
        if [[ ! "$MINIMUM_OS" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
            echo "Missing or invalid deployment target in $BINARY ($ARCHITECTURE)." >&2
            exit 1
        fi
        if ! /usr/bin/awk -v actual="$MINIMUM_OS" -v declared="$DECLARED_MINIMUM" 'BEGIN {
            split(actual, a, "."); split(declared, d, ".")
            for (i = 1; i <= 3; i++) {
                if ((a[i] + 0) < (d[i] + 0)) exit 0
                if ((a[i] + 0) > (d[i] + 0)) exit 1
            }
        }'; then
            echo "$BINARY ($ARCHITECTURE) requires macOS $MINIMUM_OS, above the declared $DECLARED_MINIMUM." >&2
            exit 1
        fi
        RPATHS="$(/usr/bin/awk '
            $1 == "cmd" && $2 == "LC_RPATH" { rpath = 1; next }
            rpath && $1 == "path" {
                sub(/^[[:space:]]*path /, ""); sub(/ \(offset [0-9]+\)$/, ""); print; rpath = 0
            }' <<< "$LOAD_COMMANDS")"
        while IFS= read -r RPATH; do
            case "$RPATH" in
                /usr/lib/*|/System/Library/*|@loader_path|@loader_path/*|@executable_path|@executable_path/*|"") ;;
                *) echo "External runtime search path in $BINARY: $RPATH" >&2; exit 1 ;;
            esac
        done <<< "$RPATHS"
        DEPENDENCIES="$(/usr/bin/otool -arch "$ARCHITECTURE" -L "$BINARY")"
        while IFS= read -r LINE; do
            [[ "$LINE" == $'\t'* ]] || continue
            DEPENDENCY="${LINE#$'\t'}"
            DEPENDENCY="${DEPENDENCY% (compatibility version*}"
            case "$DEPENDENCY" in
                /usr/lib/*|/System/Library/*) continue ;;
                @executable_path/*|@loader_path/*)
                    if is_bundled_file "$(expand_path "$DEPENDENCY")"; then continue; fi
                    ;;
                @rpath/*)
                    RESOLVED=false
                    while IFS= read -r RPATH; do
                        [[ -n "$RPATH" ]] || continue
                        CANDIDATE="$(expand_path "$RPATH")/${DEPENDENCY#@rpath/}"
                        case "$CANDIDATE" in
                            # System libraries may live only in the dyld shared cache.
                            /usr/lib/*|/System/Library/*) RESOLVED=true; break ;;
                        esac
                        if is_bundled_file "$CANDIDATE"; then RESOLVED=true; break; fi
                    done <<< "$RPATHS"
                    if [[ "$RESOLVED" == "true" ]]; then continue; fi
                    ;;
            esac
            echo "Unresolved or external dependency in $BINARY ($ARCHITECTURE): $DEPENDENCY" >&2
            exit 1
        done <<< "$DEPENDENCIES"
    done
done < <(/usr/bin/find "$APP_PATH" -type f -print0)
echo "Verified app: $APP_PATH ($EXPECTED_ARCHITECTURES; macOS $DECLARED_MINIMUM; both localizations; no external dynamic library dependencies)"
