# Contributing

ZebTrace is a small, local-first macOS application. Contributions should keep recording explicit, the menu bar interface compact, and saved data accessible without proprietary services.

## Development

Use macOS 14.2 or later with Xcode 15.1 or later, or compatible Command Line Tools with Swift 5.9 or later and a macOS 14.2+ SDK.

```sh
make check   # Unit tests, script/plist checks, and a signed local app bundle
make run     # Build and launch; recording starts only from the menu
```

Quit ZebTrace and any legacy MyContext instance before replacing an existing app bundle or installing an update. A fresh source checkout can build while an installed copy is running. Build scripts use only files in the checkout and the macOS toolchain; no local build cache or signing account is required.

Package targets are `ZebTrace` (menu bar application) and `ZebTraceCore` (audio capture, session metadata, and persistence). Keep interface code in the application target and make recording logic testable independently of the menu bar. Avoid third-party dependencies unless their benefit clearly justifies their maintenance and privacy cost. If a package dependency is added, commit the resulting `Package.resolved` and document its license.

## Changes and review

- Keep each pull request focused and explain the resulting user behavior.
- Add meaningful tests when changing session lifecycle, timestamps, or persistence. Do not simulate successful hardware capture in a unit test.
- For capture changes, manually test microphone and system output together, pause/resume, and device changes. Include the macOS version and results in the pull request.
- Update documentation when changing recording behavior, storage format, permissions, or build requirements.
- Never commit recordings, credentials, or personal session metadata. Use synthetic fixtures where needed.

GitHub CI runs `make check` and builds Universal preview packages on macOS 15 with no signing secrets. Its GitHub Actions are pinned to full commit SHAs, with Dependabot configured to propose updates; verify updated SHAs against the official action repositories. CI does not publish a release, and its ad-hoc signed artifacts are unnotarized previews. It cannot validate interactive privacy prompts, actual audio devices, or a real meeting. Do not report those scenarios as verified without testing them.

Please communicate respectfully and give actionable feedback. By submitting a contribution, you agree that it may be distributed under the repository's MIT license. No contributor license agreement is required.
