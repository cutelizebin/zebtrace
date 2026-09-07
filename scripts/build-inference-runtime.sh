#!/usr/bin/env bash
# Build pinned, relocatable local inference helpers. Does not modify an app bundle.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="$PROJECT_ROOT/dist/vendor/cache"
OUTPUT="${INFERENCE_OUTPUT_DIR:-$PROJECT_ROOT/dist/inference-runtime}"
ARCHITECTURES="${INFERENCE_ARCHITECTURES:-${BUILD_ARCHITECTURES:-native}}"
JOBS="${INFERENCE_BUILD_JOBS:-4}"
MINIMUM_MACOS=14.2
WHISPER_COMMIT=371b5a7561823ab2bb32142d2751e35e7534727b
WHISPER_ARCHIVE_SHA=89051d8fca516a3ad1f5c2f8f9d2fccb089afbaec338fca3f8731999babc6f81
LLAMA_COMMIT=427291b5b34cd914a31b3fd3b61a68f6184f4b9f
LLAMA_ARCHIVE_SHA=056ae92c363e5c761e6c03102f4aa6c1551e134f9e322eea1a4cf3f6cf87f585

[[ "$(uname -s)" == Darwin ]] || { echo 'macOS is required.' >&2; exit 1; }
command -v cmake >/dev/null || { echo 'Building helpers requires CMake and Xcode Command Line Tools.' >&2; exit 1; }
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo 'INFERENCE_BUILD_JOBS must be a positive integer.' >&2; exit 1; }
[[ "$OUTPUT" = /* ]] || OUTPUT="$PROJECT_ROOT/$OUTPUT"
case "$ARCHITECTURES" in
    native) ARCHITECTURES="$(uname -m)" ;;
    universal|arm64|x86_64) ;;
    *) echo 'INFERENCE_ARCHITECTURES must be native, universal, arm64, or x86_64.' >&2; exit 1 ;;
esac
mkdir -p "$CACHE" "$OUTPUT"

verify_hash() {
    [[ "$(/usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}')" == "$2" ]]
}

fetch_source() {
    local name="$1" commit="$2" expected_sha="$3"
    local archive="$CACHE/$name-$commit.tar.gz" source="$CACHE/$name-$commit"
    if [[ ! -f "$archive" ]]; then
        /usr/bin/curl --fail --location --retry 3 --connect-timeout 30 \
            "https://codeload.github.com/ggml-org/$name/tar.gz/$commit" -o "$archive.partial"
        verify_hash "$archive.partial" "$expected_sha" || { echo "Archive checksum failed: $name" >&2; exit 1; }
        mv "$archive.partial" "$archive"
    fi
    verify_hash "$archive" "$expected_sha" || { echo "Cached archive checksum failed: $archive" >&2; exit 1; }
    if [[ ! -f "$source/.zebtrace-source-sha256" ]] || [[ "$(cat "$source/.zebtrace-source-sha256")" != "$expected_sha" ]]; then
        # This directory contains only this script's extracted vendor source.
        rm -rf "$source"
        /usr/bin/tar -xzf "$archive" -C "$CACHE"
        printf '%s\n' "$expected_sha" > "$source/.zebtrace-source-sha256"
    fi
}

fetch_source whisper.cpp "$WHISPER_COMMIT" "$WHISPER_ARCHIVE_SHA"
fetch_source llama.cpp "$LLAMA_COMMIT" "$LLAMA_ARCHIVE_SHA"

# The upstream completion tool appends an end marker to stdout. Keep machine-
# consumed stdout limited to generated text; retain that marker in debug logs.
OUTPUT_PATCH="$PROJECT_ROOT/scripts/patches/llama-completion-output.patch"
LLAMA_SOURCE="$CACHE/llama.cpp-$LLAMA_COMMIT"
if /usr/bin/patch --dry-run --silent --forward -p1 -d "$LLAMA_SOURCE" < "$OUTPUT_PATCH" >/dev/null 2>&1; then
    /usr/bin/patch --silent --forward -p1 -d "$LLAMA_SOURCE" < "$OUTPUT_PATCH"
elif ! /usr/bin/patch --dry-run --silent --reverse -p1 -d "$LLAMA_SOURCE" < "$OUTPUT_PATCH" >/dev/null 2>&1; then
    echo 'The pinned llama-completion output patch does not match the cached source.' >&2
    exit 1
fi

copy_licenses() {
    local destination="$1" source file relative name
    for name in "whisper.cpp-$WHISPER_COMMIT" "llama.cpp-$LLAMA_COMMIT"; do
        source="$CACHE/$name"
        while IFS= read -r -d '' file; do
            relative="${file#"$source/"}"
            mkdir -p "$destination/licenses/$name/$(dirname "$relative")"
            cp "$file" "$destination/licenses/$name/$relative"
        done < <(/usr/bin/find "$source" -type f \( -iname 'LICENSE*' -o -iname 'COPYING*' \) -print0)
    done
    # miniaudio's license is embedded in its header, rather than a separate file.
    /usr/bin/sed -n '/^This software is available as a choice of the following licenses/,$p' \
        "$CACHE/whisper.cpp-$WHISPER_COMMIT/examples/miniaudio.h" > "$destination/licenses/miniaudio.txt"
}

verify_binary() {
    local binary="$1" dependency
    while IFS= read -r dependency; do
        case "$dependency" in
            /usr/lib/*|/System/Library/*) ;;
            *) echo "Non-system runtime dependency in $binary: $dependency" >&2; exit 1 ;;
        esac
    done < <(/usr/bin/otool -L "$binary" | /usr/bin/awk '/compatibility version/ {print $1}')
    if /usr/bin/otool -l "$binary" | /usr/bin/awk '/cmd LC_RPATH/ {seen=1} END {exit !seen}'; then
        echo "Unexpected LC_RPATH in $binary" >&2
        exit 1
    fi
}

write_runtime_info() {
cat > "$OUTPUT/$1/runtime-info.json" <<EOF
{
  "schemaVersion": 1,
  "architectures": "$1",
  "minimumMacOS": "$MINIMUM_MACOS",
  "whisperCommit": "$WHISPER_COMMIT",
  "whisperArchiveSHA256": "$WHISPER_ARCHIVE_SHA",
  "llamaCommit": "$LLAMA_COMMIT",
  "llamaArchiveSHA256": "$LLAMA_ARCHIVE_SHA",
  "llamaOutputPatch": "scripts/patches/llama-completion-output.patch (end marker moved to debug log)",
  "appleSiliconBackend": "Metal with embedded shader source and Accelerate",
  "intelBackend": "CPU and Accelerate",
  "thirdPartyDynamicLibraries": false
}
EOF
}

build_architecture() {
    local architecture="$1" name commit target build source metal=OFF
    local destination="$OUTPUT/$architecture"
    [[ "$architecture" == arm64 ]] && metal=ON
    mkdir -p "$destination"
    for name in whisper.cpp llama.cpp; do
        if [[ "$name" == whisper.cpp ]]; then
            commit="$WHISPER_COMMIT"; target=whisper-cli
        else
            commit="$LLAMA_COMMIT"; target=llama-completion
        fi
        source="$CACHE/$name-$commit"
        build="$CACHE/build-$name-$commit-$architecture"
        local options=(
            -DCMAKE_BUILD_TYPE=Release
            "-DCMAKE_OSX_ARCHITECTURES=$architecture"
            "-DCMAKE_OSX_DEPLOYMENT_TARGET=$MINIMUM_MACOS"
            -DCMAKE_SKIP_RPATH=ON
            -DBUILD_SHARED_LIBS=OFF
            -DGGML_BACKEND_DL=OFF
            -DGGML_NATIVE=OFF
            -DGGML_ACCELERATE=ON
            "-DGGML_METAL=$metal"
            "-DGGML_METAL_EMBED_LIBRARY=$metal"
            -DGGML_OPENMP=OFF
            -DGGML_CPU_ALL_VARIANTS=OFF
        )
        if [[ "$architecture" == arm64 ]]; then
            options+=(-DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod)
        else
            options+=(-DGGML_AVX=OFF -DGGML_AVX2=OFF -DGGML_AVX512=OFF -DGGML_AVX_VNNI=OFF -DGGML_FMA=OFF -DGGML_F16C=OFF)
        fi
        if [[ "$name" == whisper.cpp ]]; then
            options+=(-DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF -DWHISPER_CURL=OFF -DWHISPER_COMMON_FFMPEG=OFF -DWHISPER_COREML=OFF -DWHISPER_SDL2=OFF)
        else
            options+=(-DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_APP=OFF -DLLAMA_BUILD_UI=OFF -DLLAMA_OPENSSL=OFF -DLLAMA_SUBPROCESS=OFF)
        fi
        echo "Building $target for $architecture (Metal=$metal)"
        cmake -S "$source" -B "$build" "${options[@]}"
        cmake --build "$build" --config Release --target "$target" --parallel "$JOBS"
        cp "$build/bin/$target" "$destination/$target"
        chmod 755 "$destination/$target"
        verify_binary "$destination/$target"
    done
    copy_licenses "$destination"
    cp "$OUTPUT_PATCH" "$destination/licenses/llama-completion-output.patch"
    write_runtime_info "$architecture"
}

if [[ "$ARCHITECTURES" == universal ]]; then
    build_architecture arm64
    build_architecture x86_64
    mkdir -p "$OUTPUT/universal"
    for target in whisper-cli llama-completion; do
        /usr/bin/lipo -create "$OUTPUT/arm64/$target" "$OUTPUT/x86_64/$target" -output "$OUTPUT/universal/$target"
        chmod 755 "$OUTPUT/universal/$target"
        verify_binary "$OUTPUT/universal/$target"
    done
    copy_licenses "$OUTPUT/universal"
    cp "$OUTPUT_PATCH" "$OUTPUT/universal/licenses/llama-completion-output.patch"
else
    build_architecture "$ARCHITECTURES"
fi

write_runtime_info "$ARCHITECTURES"
echo "Inference helpers ready: $OUTPUT/$ARCHITECTURES"
