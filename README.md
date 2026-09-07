<p align="center">
  <img src="Resources/AppIcon.png" width="112" alt="ZebTrace app icon">
</p>

<h1 align="center">ZebTrace</h1>

<p align="center">
  <strong>Your Mac’s audio, ready to revisit.</strong><br>
  Record system sound and your microphone. Browse, listen, transcribe, and summarize locally.
</p>

<p align="center">
  <a href="https://github.com/cutelizebin/zebtrace/releases/tag/v0.4.3"><img src="https://img.shields.io/badge/preview-v0.4.3-3d7866" alt="Preview v0.4.3"></a>
  <img src="https://img.shields.io/badge/macOS-14.2%2B-333333?logo=apple&logoColor=white" alt="macOS 14.2 or later">
  <a href="https://github.com/cutelizebin/zebtrace/actions/workflows/ci.yml"><img src="https://github.com/cutelizebin/zebtrace/actions/workflows/ci.yml/badge.svg?branch=main" alt="Build and tests"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-3d7866" alt="MIT license"></a>
</p>

<p align="center">
  <strong><a href="https://github.com/cutelizebin/zebtrace/releases/download/v0.4.3/ZebTrace-0.4.3-universal-preview-unnotarized.dmg">Download for macOS</a></strong>
  &nbsp; · &nbsp; <a href="README.zh-CN.md">简体中文</a>
  &nbsp; · &nbsp; <a href="https://github.com/cutelizebin/zebtrace/releases/tag/v0.4.3">Release notes</a>
  &nbsp; · &nbsp; <a href="CONTRIBUTING.md">Contribute</a>
</p>

<p align="center">
  <img src="docs/assets/recording-library-light.png" width="1200" alt="ZebTrace recording library: recordings grouped by date, a readable summary, and an original-audio player. Illustrative sample content.">
</p>
<p align="center"><sub>Interface preview with illustrative sample content, not an ASR accuracy example.</sub></p>

## A quiet place for your audio

ZebTrace lives in the menu bar until you need it. You choose when recording starts and stops; open the library when you want to revisit a moment. It works with whatever audio reaches your Mac’s system and microphone inputs, without assuming a meeting or a particular activity.

| Record | Revisit | Understand |
| --- | --- | --- |
| Start and pause from the menu bar. System sound and microphone audio are saved as separate tracks. | Browse recordings by date, search dates or summaries, and listen to the original audio in one window. | Generate timestamped transcripts and summaries with local models. Switch between text and audio as you read. |

- **Local by design.** Recordings and generated text stay on your Mac. No account, audio upload, or telemetry.
- **Files you own.** Ordinary `.m4a`, Markdown, and JSON files in a folder you choose. Models live alongside them.
- **A native Mac app.** A focused library, compact player, and settings for model downloads, removal, and storage.
- **English and 简体中文.** Follows your system language, with a manual override and [resources for adding languages](docs/localization.md).

## Up and running

**[Download the Universal DMG](https://github.com/cutelizebin/zebtrace/releases/download/v0.4.3/ZebTrace-0.4.3-universal-preview-unnotarized.dmg)** · [ZIP, checksums, and release notes](https://github.com/cutelizebin/zebtrace/releases/tag/v0.4.3)

Requires **macOS 14.2+**. One app includes Apple Silicon and Intel binaries. No Python, Homebrew, FFmpeg, Ollama, Xcode, or account is needed to use the download.

1. **Install.** Open the DMG and drag **ZebTrace.app** into **Applications**.
2. **Record.** Open the app, click **Z** in the menu bar, and choose **Start Recording**. Approve microphone and system audio access when prompted.
3. **Revisit.** Choose **Pause and Save → Open Main Window**. Select a recording to listen, or choose **Generate Review** for a transcript and summary.

> **First launch:** this preview is not notarized. If macOS blocks it and you trust the source, first try opening the app, then go to **System Settings → Privacy & Security → Open Anyway**. [Apple’s instructions](https://support.apple.com/en-us/102445).

Recording needs no models. The first local review asks to download **about 3.1 GB** of model files, shared across recordings. Downloads can resume and are checked against pinned SHA-256 hashes. Once the models are ready, transcription and summaries work offline.

**Upgrading?** Pause/save and quit the old app before replacing it. Existing recordings remain in place. See the [usage reference](docs/usage-reference.md) or [中文使用指南](docs/quick-start.zh-CN.md) for permissions and troubleshooting.

## Local models, simple controls

Choose models in **Settings → Models and Storage…**. The app handles downloads and inference; model choices apply to future processing.

| Job | Included choices |
| --- | --- |
| Speech → transcript | **Whisper large-v3-turbo · Q5** by default; **Whisper large-v3 · Q5** is also available |
| Transcript → summary | **Qwen3 4B · Q4** |
| Detect speech for transcription | **Silero v6.2.0** |

Heavy transcription and summary steps run sequentially, and their helpers exit afterward to release memory. **Summarize After Saving** is optional and off by default. Recording works independently of these models.

The full Whisper speech model is about **1.08 GB**; its complete model combination is about **3.6 GB**. Shared downloads are reused. The current setup prepares speech, summary, and VAD models together. See [model choices and recognition quality](docs/asr-quality.md) and [models and licenses](docs/local-review.md#models-and-licenses).

## One folder, ordinary files

The default location is **`~/Downloads/ZebTrace`**. Choose another folder in the app; downloaded models follow the selected location, while earlier recordings stay where they were saved.

```text
ZebTrace/
├── Models/                         Shared local models
└── 2026-09-07/
    └── 2026-09-07_09-30-00/         One recording
        ├── system-00001.m4a
        ├── microphone-00001.m4a
        ├── session.json
        ├── transcript.md           After transcription
        ├── summary.md              After summarization
        └── …                       Metadata and reusable analysis cache
```

Audio is written as it arrives, in **10-minute segments** by default; choose 1, 5, 10, 30, or 60 minutes. Pausing saves the current segment immediately. Non-speech sounds and quiet periods remain in the received audio; speech detection only affects transcription.

Remove model downloads in settings, or use **Cleanup and Uninstall…** for managed data and preferences. Recordings are kept unless explicitly included. Deleting the app in Finder alone does not remove its data. [Storage format and cleanup details →](docs/usage-reference.md#saved-data)

## Know the preview’s limits

Transcripts and summaries can be wrong; check important details against the original audio. Microphone/system labels identify **sources, not people**. Speaker identification, reliable speaker-turn separation, echo cancellation, and synchronized mixed-track playback are not implemented. Music and environmental sound events are not reliably described.

**Qwen3 is currently the text model; Qwen3-ASR is not integrated.** Universal builds are checked in CI, but Intel inference and Bluetooth device transitions still need hardware validation. See [release validation](docs/release-readiness.md) for the tested scope.

Next steps focus on transcription quality, speaker turns, and related audio across sources, with original files preserved and models kept replaceable. The [audio-understanding design](docs/audio-understanding-design.md) describes proposed work, not additional features in this release.

## Build and contribute

Building requires **Xcode 15.1+** or compatible **Swift 5.9+ / macOS 14.2+ SDK** tools, plus **CMake**. The first build fetches checksum-pinned whisper.cpp and llama.cpp sources and bundles native inference helpers. It does not download model weights.

```sh
git clone https://github.com/cutelizebin/zebtrace.git
cd zebtrace
make run       # Build and open the app; recording stays manual
make test      # Run isolated tests without recording
make check     # Tests, script/plist checks, and app build
make package   # Universal preview DMG, ZIP, and checksums
```

Bug reports, translations, documentation, and focused pull requests are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) to get started; report vulnerabilities through [SECURITY.md](SECURITY.md).

| Explore | Documentation |
| --- | --- |
| Use the app | [Full usage reference](docs/usage-reference.md) · [中文使用指南](docs/quick-start.zh-CN.md) |
| Understand the code | [Architecture](docs/architecture.md) · [Local inference](docs/inference-runtime.md) · [Extensibility](docs/extensibility-review.md) |
| Work on the experience | [Interface design](docs/interface-design.md) · [Localization](docs/localization.md) |
| Ship a build | [Distribution](docs/distribution.md) · [Validation](docs/release-readiness.md) · [Changelog](CHANGELOG.md) |

## License

[MIT](LICENSE) · © 2026 ZebTrace contributors. Bundled runtimes and downloaded models retain their own [licenses and notices](docs/local-review.md#models-and-licenses).
