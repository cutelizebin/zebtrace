# Maintainer distribution guide

ZebTrace targets macOS 14.2 and later. The current preview is **0.4.2, build 9**, including local transcription and summaries; the earlier **v0.2.0** download contains recording only. Current packaging produces a Universal app and two Universal inference helpers with `arm64` and `x86_64` slices. Building a preview requires no paid Apple Developer membership or signing credentials. Packaging creates local artifacts; publishing them is a separate step.

Source builds require the documented Xcode/Swift toolchain and CMake (for example, `brew install cmake`). The first build fetches fixed upstream source revisions and verifies their archive hashes, then compiles the native helpers. This is a developer requirement, not an installation step for end users. See [inference-runtime.md](inference-runtime.md) for source pins, build controls, and licensing.

```bash
make check
make package
```

| Command | Result |
| --- | --- |
| `make package` or `./scripts/package.sh --preview` | Universal preview, ad-hoc signed and explicitly marked `preview-unnotarized`. |
| `make release-package` or `./scripts/package.sh --release` | Universal release requiring Developer ID signing and successful notarization. Missing credentials or failed verification stop the command. |

A preview is a runnable app, with its unnotarized status stated in the filenames. On first launch, a user who trusts the download may need to approve it using **System Settings → Privacy & Security → Open Anyway**, as described in [Apple's official instructions](https://support.apple.com/en-us/102445). Keep that first-launch guidance in the download notes and [README](../README.md).

The version and build number come from `Resources/Info.plist`. Keep the version-specific release notes and download links aligned with the tag being published. Version notes in `docs/releases/<version>.md` are included in the generated release draft.

## Inference payload

`make package` builds Universal `whisper-cli` and `llama-completion` alongside the main executable. The app bundles executable helpers in `Contents/Helpers`, runtime metadata in `Contents/Resources/InferenceRuntime`, and notices in `Contents/Resources/InferenceLicenses`. Keep JSON outside the nested-code directory so strict code signing succeeds. Sign each helper before signing the outer app, and verify the final extracted signatures and dependencies for all three executables. The build is configured to link third-party runtime code statically; no external Python, Homebrew, FFmpeg, Ollama, or inference server should be needed at runtime.

Model weights are **not** embedded in the ZIP or DMG. The app obtains explicit first-use consent to download the pinned ASR/summary pair and auxiliary VAD model, totaling 3,072,206,549 bytes (about 3.1 GB) for the default Turbo combination or 3,579,305,557 bytes (about 3.6 GB) with full large-v3, into `<selected recording root>/Models` (`~/Downloads/ZebTrace/Models` by default). Preserve this distinction in installation notes: the app can record immediately, while first local review needs a model download. Model bytes, hashes, licenses, and retries are described in [local-review.md](local-review.md). Never place a maintainer's existing model cache or session artifacts in a release archive.

## Optional Developer ID distribution

To ship a later build that passes normal Gatekeeper assessment without an unknown-developer exception, use a **Developer ID Application** certificate, Hardened Runtime, a secure signing timestamp, and notarization. Use a current full Xcode installation for these release tools. See [Apple's notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

Create or select your Developer ID Application identity using Xcode and the developer account's certificate tools. The signing identity must be available in the build machine's Keychain. See [Apple's Developer ID guide](https://developer.apple.com/developer-id/).

Create a named notary credential profile interactively; the tool prompts for credentials:

```bash
xcrun notarytool store-credentials zebtrace-notary
```

Then build a release package:

```bash
CODESIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
NOTARYTOOL_PROFILE='zebtrace-notary' \
make release-package
```

The release workflow uses `notarytool`, waits for acceptance, attaches tickets with `stapler`, and verifies the resulting distribution. A ZIP cannot itself receive a stapled ticket: its enclosed app must be stapled before producing the final ZIP. Keep the signed app unchanged afterward. See [Apple's custom notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

| Variable | Use |
| --- | --- |
| `CODESIGN_IDENTITY` | Required Developer ID Application identity for a release. Preview mode uses ad-hoc signing. |
| `NOTARYTOOL_PROFILE` | Required Keychain credential profile name for a release. |
| `NOTARYTOOL_KEYCHAIN` | Optional Keychain path containing that profile. |
| `NOTARIZATION_TIMEOUT` | Per-submission wait timeout; defaults to `30m`. The app and DMG are submitted separately. |
| `RELEASE_OUTPUT_DIR` | Package output directory; defaults to `dist/releases`. |
| `BUILD_ARCHITECTURES` | Standalone app builds: `native` by default, or `universal`. Packaging always builds Universal. |
| `BUILD_CONFIGURATION` | Standalone app builds: `release` by default, or `debug`. Packaging always uses `release`. |
| `BUILD_OUTPUT_DIR` | Standalone app output directory; defaults to `dist`. Packaging uses its own staging location. |

Package folders are named `ZebTrace-<version>-universal-preview-unnotarized` or `ZebTrace-<version>-universal`. Each contains matching ZIP and DMG files, `SHA256SUMS`, and `PACKAGE-INFO.txt`. An existing destination folder causes an error; choose another `RELEASE_OUTPUT_DIR` or remove the previous artifacts deliberately before rebuilding. Packaging does not replace the native app in `dist/ZebTrace.app`.

## GitHub release drafts

The release workflow runs for version tags and manual dispatch. Both default to `preview`, creating a **draft prerelease** with unnotarized filenames and installation guidance. Review the artifacts before publishing the draft. The tag must match the version in `Resources/Info.plist`.

For a later signed build, manually select `notarized` and configure repository secrets `APPLE_CERTIFICATE_P12_BASE64`, `APPLE_CERTIFICATE_PASSWORD`, `APPLE_SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_TEAM_ID`, and `APPLE_APP_SPECIFIC_PASSWORD`. This mode imports credentials into a temporary Keychain and creates a draft release only after signing and notarization succeed. Preview builds do not need these secrets.

## Languages and permission text

The main bundle advertises `en` and `zh-Hans`, with English as its development language. macOS chooses a supported localization from the user's language preferences and falls back to the development language when necessary. See [Apple's bundle resource lookup rules](https://developer.apple.com/library/archive/documentation/CoreFoundation/Conceptual/CFBundles/AccessingaBundlesContents/AccessingaBundlesContents.html#//apple_ref/doc/uid/10000123i-CH102-SW7).

Both `NSMicrophoneUsageDescription` and `NSAudioCaptureUsageDescription` have an English fallback in `Info.plist`. Their localized values must be copied to the **main app bundle**, at `Contents/Resources/en.lproj/InfoPlist.strings` and `Contents/Resources/zh-Hans.lproj/InfoPlist.strings`. Putting them only in the SwiftPM resource bundle is insufficient for the app's permission dialogs. See [Apple's Info.plist localization mechanism](https://developer.apple.com/library/archive/documentation/CoreFoundation/Conceptual/CFBundles/BundleTypes/BundleTypes.html).

Build and verification scripts read `CFBundleLocalizations` to copy and validate every advertised permission localization and its matching SwiftPM strings. Check the final extracted app for these resources. Verify the menu, library, model/storage windows, errors, and permission purpose text in each supported language. App language changes refresh presentation; system-owned permission dialogs follow macOS language rules. Use a fresh test account for first-use permission dialogs so existing privacy grants do not hide them.

Adding a language requires registration, resource files, and prompt review; see [localization.md](localization.md). The source key-parity test covers every registered language, and packaging rejects a declared locale whose permission or core strings are absent.

## Data and uninstall behavior

Release notes should explain that recording audio, derived results, hidden session caches, and downloaded models use the selected recording root. Models live in its `Models` child; changing the location keeps existing recordings in place and relocates validated managed models. Preferences and operating-system state still use normal macOS locations. Do not package any of these user files into the download.

The main library exposes record/result deletion, model management, and **Cleanup and Uninstall…**. Cleanup is explicit, keeps recordings by default, and can include them after confirmation. Recording and generated-content removal use Trash; uninstall can also move the app there. The app does not receive an uninstall callback when someone drags it to Trash in Finder. Users who want data cleanup should perform it in the app first; unknown files, offline previous volumes, and macOS permission records are not silently cleared. See [local review](local-review.md#storage-and-removal) for the user-facing distinctions.

## Validate the final download

Run these against the app extracted from the final ZIP or copied from the final DMG, not just the build directory:

```bash
ZEBTRACE_APP='/path/to/extracted/ZebTrace.app'
scripts/verify-app.sh "$ZEBTRACE_APP" universal
lipo -archs "$ZEBTRACE_APP/Contents/MacOS/ZebTrace"
otool -arch all -L "$ZEBTRACE_APP/Contents/MacOS/ZebTrace"
otool -arch all -l "$ZEBTRACE_APP/Contents/MacOS/ZebTrace"
codesign --verify --deep --strict --verbose=2 "$ZEBTRACE_APP"
codesign --display --verbose=4 "$ZEBTRACE_APP"
for helper in whisper-cli llama-completion; do
  lipo -archs "$ZEBTRACE_APP/Contents/Helpers/$helper"
  otool -arch all -L "$ZEBTRACE_APP/Contents/Helpers/$helper"
  codesign --verify --strict --verbose=2 "$ZEBTRACE_APP/Contents/Helpers/$helper"
done
```

Expect both architectures, a deployment target of macOS 14.2, and a valid code signature. Preview signatures are ad-hoc. For a Developer ID release, also verify the intended signing authority and run:

```bash
xcrun stapler validate "$ZEBTRACE_APP"
spctl --assess --type execute --verbose=4 "$ZEBTRACE_APP"
```

Expect a valid ticket and Gatekeeper acceptance for a Developer ID release; also validate its DMG ticket with `xcrun stapler validate`. Preview packages have no ticket and use the first-launch approval described above. For either mode, compare both archives against `SHA256SUMS`.

The app uses Apple frameworks and bundles its native inference executables. macOS has included the Swift runtime since before the project's minimum deployment target, so the current design does **not** require bundling an entire Swift runtime or asking users to install Xcode. See [Apple's Swift runtime release notes](https://developer.apple.com/documentation/xcode-release-notes/swift-5-release-notes-for-xcode-10_2). The current payload is expected to use only `/System/Library` and `/usr/lib` dynamic dependencies; package validation rejects non-system dependencies that cannot resolve inside the app. Inspect every executable's `LC_RPATH` for build-machine paths. Reevaluate runtime compatibility after a toolchain or dependency change; copying arbitrary toolchain libraries is not a substitute for testing.

Finally, exercise the downloaded app with quarantine intact on Macs without developer tools, including the minimum supported macOS and both hardware architectures. Confirm it starts, finds its localized resources, requests permissions, saves playable audio after an explicit start, and runs local review after a confirmed model download. Include interrupted downloads, cancellation, sleep, quitting during inference, a saved transcript after summary failure, and switching between recordings while results are loading. Check model relocation, cancel/release versus model deletion, generated-only deletion, and cleanup both with and without recordings using disposable fixtures. Confirm closing the main window leaves the menu bar app running. A successful `otool` audit or cross-compilation alone cannot establish Intel inference behavior or prove that every referenced runtime symbol exists on macOS 14.2.
