# Open-source readiness

Reviewed on 2026-09-05 for the 0.2.0 preview.

The repository is suitable for an early open-source demo. It includes the source,
MIT license, icon assets and provenance, contribution and privacy documentation,
local build scripts, and GitHub CI configuration. Universal preview downloads are
distributed as DMG/ZIP assets on [GitHub Releases](https://github.com/cutelizebin/zebtrace/releases).
The optional signing/notarization workflow
is implemented; a notarized release still needs Developer ID credentials and
successful Apple validation, along with broader hardware testing.

## Local validation

Environment: Apple silicon, macOS 26.5.2, Xcode 26.6, Swift 6.3.3.

| Check | Result |
| --- | --- |
| Automated tests using synthetic audio and isolated temporary directories | 46 passed |
| Native and cross-architecture release builds | arm64 and x86_64 compiled; Universal binary verified |
| Downloaded-package structure | ZIP extracted and DMG mounted; app contents, Applications link, and bilingual installation instructions checked |
| App metadata, language resources, entitlements, and ad-hoc signature | Passed on the extracted ZIP and mounted DMG |
| Runtime dependency audit | Both slices use Apple system libraries; no build-machine RPATHs or external library dependencies |
| Relocated localization resource probe | English/Chinese switching passed after moving the app, with development-resource fallback disabled |
| Package integrity | DMG verification and SHA-256 checks passed |
| Shell syntax, CI YAML, executable script permissions, and relative documentation links | Passed |
| Intended source files reviewed for recordings, credentials, and machine-specific paths | None found in the reviewed files and pattern checks |
| GitHub Actions references | Official actions pinned to full commit SHAs; read-only repository permissions |

The review fixed failed finalization being reported as success on a repeated stop,
preserved the first write error, added microphone hardware checks, and simplified
application startup. Tests also cover system-language priority, Chinese variants,
English fallback, persistent overrides, and matching translation placeholders.

These checks do not record from real devices. Local test results are not evidence
of a successful remote CI run or long-duration meeting reliability.

## Validation still needed

- Extended meetings with both tracks, including 10-minute segment boundaries.
- AirPods/Bluetooth profile transitions, USB device removal, and device switching.
- Interactive permission denial/regrant, sleep/wake, and quitting during capture.
- Runtime checks on macOS 14.2 and Intel Macs; these are declared targets, not
  separately verified hardware in this review.
- Full installed-app testing on Macs without developer tools. Binary dependency
  and relocated-resource checks passed locally; this review did not remove Xcode
  or execute the app on a second Mac.
- Developer ID signing and notarization before offering a build that passes
  Gatekeeper without an unknown-developer exception. The current preview provides
  Apple's manual first-launch approval instructions.

## Publishing the source

The source repository is [cutelizebin/zebtrace](https://github.com/cutelizebin/zebtrace).
See [GitHub Actions](https://github.com/cutelizebin/zebtrace/actions) for remote
build results, which are separate from the local validation recorded above.
Private vulnerability reports use the channel described in [SECURITY.md](../SECURITY.md).
The release workflow defaults to a draft prerelease with Universal preview
downloads and first-launch guidance. Publish its draft after checking the
artifacts. Signing credentials can be added later without changing the install
format. Retain the documented limitations in the initial preview.

See [README.md](../README.md) for builds and behavior, and the
[Chinese guide](quick-start.zh-CN.md) for a short manual recording check.
