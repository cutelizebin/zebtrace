# Maintainer distribution guide

ZebTrace targets macOS 14.2 and later. The default downloadable build is a Universal preview containing `arm64` and `x86_64` executable slices. Building it requires no paid Apple Developer membership or signing credentials. Packaging creates local artifacts; publishing them is a separate step.

```bash
make check
make package
```

| Command | Result |
| --- | --- |
| `make package` or `./scripts/package.sh --preview` | Universal preview, ad-hoc signed and explicitly marked `preview-unnotarized`. |
| `make release-package` or `./scripts/package.sh --release` | Universal release requiring Developer ID signing and successful notarization. Missing credentials or failed verification stop the command. |

A preview is a runnable app, with its unnotarized status stated in the filenames. On first launch, a user who trusts the download may need to approve it using **System Settings → Privacy & Security → Open Anyway**, as described in [Apple's official instructions](https://support.apple.com/en-us/102445). Keep that first-launch guidance in the download notes and [README](../README.md).

The current version and build number come from `Resources/Info.plist`: `0.2.0` and `3`. Update these before a subsequent release.

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

Check the final extracted app for both permission files and the SwiftPM localization resource bundle. Verify menus, errors, and permission purpose text in English and Simplified Chinese; restart after changing the app's preferred language. Use a fresh test account for first-use permission dialogs so existing privacy grants do not hide them.

## Validate the final download

Run these against the app extracted from the final ZIP or copied from the final DMG, not just the build directory:

```bash
ZEBTRACE_APP='/path/to/extracted/ZebTrace.app'
lipo -archs "$ZEBTRACE_APP/Contents/MacOS/ZebTrace"
otool -arch all -L "$ZEBTRACE_APP/Contents/MacOS/ZebTrace"
otool -arch all -l "$ZEBTRACE_APP/Contents/MacOS/ZebTrace"
codesign --verify --deep --strict --verbose=2 "$ZEBTRACE_APP"
codesign --display --verbose=4 "$ZEBTRACE_APP"
```

Expect both architectures, a deployment target of macOS 14.2, and a valid code signature. Preview signatures are ad-hoc. For a Developer ID release, also verify the intended signing authority and run:

```bash
xcrun stapler validate "$ZEBTRACE_APP"
spctl --assess --type execute --verbose=4 "$ZEBTRACE_APP"
```

Expect a valid ticket and Gatekeeper acceptance for a Developer ID release; also validate its DMG ticket with `xcrun stapler validate`. Preview packages have no ticket and use the first-launch approval described above. For either mode, compare both archives against `SHA256SUMS`.

The app uses Apple frameworks. macOS has included the Swift runtime since before the project's minimum deployment target, so the current design does **not** require bundling an entire Swift runtime or asking users to install Xcode. See [Apple's Swift runtime release notes](https://developer.apple.com/documentation/xcode-release-notes/swift-5-release-notes-for-xcode-10_2). Confirm this for each final binary: dependencies should resolve to `/System/Library`, `/usr/lib`, or deliberately embedded and signed libraries. Inspect `LC_RPATH` for build-machine paths and ensure every non-system dependency is present for both architectures. Reevaluate runtime compatibility after a toolchain or dependency change; copying arbitrary toolchain libraries is not a substitute for testing.

Finally, exercise the downloaded app with quarantine intact on Macs without developer tools, including the minimum supported macOS and both hardware architectures. Confirm it starts, finds its localized resources, requests permissions, and saves playable audio after an explicit start. A successful `otool` audit alone cannot prove that every referenced runtime symbol exists on macOS 14.2.
