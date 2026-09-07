# Contributing

ZebTrace is a small, local-first macOS application. Contributions should keep recording explicit, the menu bar interface compact, and saved data accessible without proprietary services.

## Development

Use macOS 14.2 or later with Xcode 15.1 or later, or compatible Command Line Tools with Swift 5.9 or later and a macOS 14.2+ SDK. App builds also need CMake; `brew install cmake` is one way to install it. The first runtime build downloads pinned upstream source archives and verifies their hashes. End users of a packaged app do not need these developer tools.

```sh
make check   # Unit tests, script/plist checks, and a signed local app bundle
make run     # Build and launch; recording starts only from the menu
```

Quit ZebTrace and any legacy MyContext instance before replacing an existing app bundle or installing an update. A fresh source checkout can build while an installed copy is running; no preexisting cache or signing account is required. Native runtime sources/builds are cached under ignored `dist/vendor/cache`. Runtime and model provenance are documented in [inference-runtime.md](docs/inference-runtime.md); model weights are not part of ordinary source builds.

Package targets are `ZebTrace` (menu bar application), `ZebTraceCore` (recording), `ZebTraceAnalysis` (local model management and analysis), and `ZebTraceAnalyze` (developer CLI). Keep UI and recording ownership separate from inference. `TranscriptionProvider` and `SummarizationProvider` are the replacement boundaries; preprocessing, job lifecycle, timing, cache identity, and result persistence remain project-owned. Avoid additional dependencies without a clear maintenance/privacy justification. If a Swift package dependency is added, commit `Package.resolved` and document its license.

## Changes and review

- Keep each pull request focused and explain the resulting user behavior.
- Add meaningful tests when changing session lifecycle, timestamps, or persistence. Do not simulate successful hardware capture in a unit test.
- For analysis changes, cover cancellation and helper cleanup, valid timing, cache invalidation, long-text handling, and preservation of transcripts on summary failure. Fake providers can test orchestration; real-model checks must be reported separately.
- For capture changes, manually test microphone and system output together, pause/resume, and device changes. Include the macOS version and results in the pull request.
- Update documentation when changing recording behavior, storage format, permissions, or build requirements.
- Never commit recordings, generated transcripts/summaries, prompts, caches, model weights, credentials, or personal session metadata. Use synthetic or properly licensed public fixtures where needed.
- When updating runtime/model pins, verify the official source, revision, hash, license, architecture support, and corresponding cache identity. Do not make runtime commands fetch unrequested models or upload audio.

GitHub CI runs `make check` and builds Universal preview packages on macOS 15 with no signing secrets. Its GitHub Actions are pinned to full commit SHAs, with Dependabot configured to propose updates; verify updated SHAs against the official action repositories. CI does not publish a release, and its ad-hoc signed artifacts are unnotarized previews. It cannot validate interactive privacy prompts, actual audio devices, or real-world audio conditions. Do not report those scenarios as verified without testing them.

For a developer-only end-to-end check, use `swift run -c release ZebTraceAnalyze SESSION RUNTIME MODELS zh|en` with a completed non-sensitive session and prepared model files. This invokes the real service and writes local results; if the chosen model directory is incomplete, the harness downloads missing weights without a dialog. See [local-review.md](docs/local-review.md#developer-harness) for the command and artifact boundaries. Compiling Universal helpers does not establish Intel runtime quality or acceptable performance on every supported Mac.

Please communicate respectfully and give actionable feedback. By submitting a contribution, you agree that it may be distributed under the repository's MIT license. No contributor license agreement is required.
