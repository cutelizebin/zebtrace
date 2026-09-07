# Usage and developer reference

Detailed installation, recording, model, storage, and development instructions for ZebTrace. For the concise introduction and current download, see the [project homepage](../README.md). A [Simplified Chinese guide](quick-start.zh-CN.md) is also available.

## Recording behavior

Recording starts only when you choose **Start Recording**. **Pause and Save** ends the current session; starting again creates a new session. Launching or waking the app does not start recording. ZebTrace stays in the menu bar; **Open Main Window** opens the library, and closing that window does not pause capture.

System playback is captured through Core Audio taps and microphone input through AVAudioEngine. Each source is saved separately as AAC `.m4a` segments, with timing information in `session.json`. Capture pauses on sleep, audio-device changes, capture failures, and low disk space (under 500 MB available).

Recording does not assume a particular setting or activity. While you choose to record, it saves received audio, including non-speech sounds and quiet periods; speech detection does not control capture. Transcripts and summaries are optional text derived from recognized speech, not a complete account of every sound or activity. Music and environmental sound events are not currently identified reliably. There is no cloud account, audio upload, or telemetry.

## Installation and upgrades

Download the app from [GitHub Releases](https://github.com/cutelizebin/zebtrace/releases). The same Universal app contains native Apple silicon and Intel versions. Releases provide a DMG, ZIP, checksums, and release notes.

When upgrading, including from the earlier v0.2.0 recording-only release: pause/save and quit ZebTrace before replacing the app in Applications. Existing audio remains in place; older session-folder names are supported. Model downloads are needed only when you choose to prepare or use local review, not for recording.

1. Open the DMG and drag **ZebTrace.app** into **Applications**.
2. Open ZebTrace from Applications. It appears as a **Z** in the menu bar.
3. Choose **Start Recording** and allow microphone and system audio access when macOS asks.
4. Choose **Pause and Save**, then **Open Main Window** to browse the recording, listen to either original track, and optionally generate a review.

You only need **macOS 14.2 or later** to run a packaged app. **No Xcode, Swift installation, Python, Homebrew, FFmpeg, Ollama, or account is required.** The app bundles native inference helpers; model weights are downloaded separately on first use. A ZIP and `SHA256SUMS` are provided as alternatives to the DMG. Universal binaries do not establish that inference has been tested on Intel hardware.

The current preview is **not notarized**. If macOS blocks its first launch and you trust the download's source, try opening it once, then use **System Settings → Privacy & Security → Open Anyway** and confirm **Open**. Managed Macs may restrict this option. See [Apple's instructions](https://support.apple.com/en-us/102445). A future Developer ID signed and notarized build will simplify this first-launch step.

## Language

The default is **Language → Follow System**. The app checks macOS's preferred languages in order, uses English or Simplified Chinese when supported, and falls back to English otherwise. Chinese region/script variants select Simplified Chinese.

Choose **English** or **简体中文** to override the system preference. App menus, library, and model labels update immediately, including while recording, and the selection persists across launches. Speech recognition detects the spoken language automatically; a review uses the UI language selected when processing starts for its summary. App-owned UI, errors, exported review text, and model prompts use localization resources. Underlying system/runtime diagnostics may remain in their original language. See [adding a language](localization.md). macOS-owned permission dialogs and standard file-picker controls use macOS's app/system language rules and may require relaunching after a system-language change. Permission usage descriptions are bundled in both languages.

## Local recording review

Choose **Open Main Window**, select a saved recording, then **Generate Review**. The **Recording Review** menu also offers **Summarize Latest Recording** and **Summarize Another Recording…**. On first use, confirm the model download: **3,072,206,549 bytes (about 3.1 GB)**, shared across recordings in `Models/` under your selected save folder (default `~/Downloads/ZebTrace/Models`). Downloads use fixed revisions and SHA-256 checks, and can resume after cancellation or a network failure. Audio and text stay on the Mac.

The default model combination uses **Whisper large-v3-turbo Q5** for transcription and **Qwen3 4B Q4** for summaries, with a small Silero speech-detection model included in the download. Transcription and summarization run sequentially after recording stops. **Summarize After Saving** is optional and off by default; only a successful manual **Pause and Save** triggers it. Starting recording, sleep, and quit cancel processing; quitting waits for the helper to stop. A processing failure does not affect recording.

**Open Main Window** opens a date-grouped recording library. Select a session to read its rendered summary or timestamped transcript, listen to the original track segments, copy text, or remove generated content/recordings. Processing status and results stay tied to that session, including while another recording is being summarized. A saved transcript remains available when summarization fails. The native toolbar keeps recording close at hand; a compact bottom player handles audio, and secondary actions live in **More**. See the [interface design notes](interface-design.md).

**Settings → Models and Storage…** shows the available ASR and summary selections, download state, file sizes, model deletion, and inference memory state. Speech recognition offers Turbo and full large-v3; the full speech model is about **1.08 GB**, and its complete combination is about **3.6 GB**. Shared files are reused. Selection persists, affects future processing, and does not download weights or rewrite existing results. Preparation and readiness use the selected speech model together with the summary/VAD files; this preview does not offer an ASR-only download mode. Idle helpers exit and release their memory; downloaded files remain until explicitly deleted. Changing the save location verifies and moves shared models without overwriting conflicting files. Earlier recordings stay in their existing folders, listed in **Storage & Settings**. The old hidden model folder is migrated on upgrade.

**Storage & Settings → Cleanup and Uninstall…** removes managed model files and preferences, then moves the app to Trash. An explicit checkbox also includes recognized recordings and generated content. Unknown user files are preserved, and unavailable external drives must be reconnected for a full cleanup. Empty Trash to reclaim trashed files' space. Deleting only the app in Finder cannot invoke this cleanup; macOS retains control of permission history and system logs. See [local review usage and boundaries](local-review.md).

The review may contain recognition errors or unsupported summary claims. Source labels mean **microphone/system audio**, not named people. This version has no speaker identification, reliable speaker-turn separation, or acoustic echo cancellation, and playback does not mix the tracks. **Qwen3 4B is the text summary model; Qwen3-ASR is not integrated.** Check important details against the original audio. See the [audio-understanding design](audio-understanding-design.md) for proposed work and [ASR quality notes](asr-quality.md) for the current model comparison. Neither design proposals nor compilation establish model accuracy or hardware compatibility; consult the [release readiness notes](release-readiness.md) for validation limits.

## Saved data

The default save folder is `~/Downloads/ZebTrace`. The menu shows the current location; **Choose Save Folder…** opens the native folder picker and saves your choice across launches. Folder changes are disabled during recording. Pause first, choose another folder, then start a new session there.

New recordings use this layout:

```text
~/Downloads/ZebTrace/
├── Models/                              # Shared downloaded models
└── yyyy-MM-dd/
    └── yyyy-MM-dd_HH-mm-ss/
        ├── session.json
        ├── system-00001.m4a
        ├── microphone-00001.m4a
        ├── ...
        ├── transcript.md / transcript.json  # After transcription
        ├── transcription.json              # Session and content provenance
        ├── summary.md / analysis.json       # After successful review
        └── .zebtrace-analysis/              # Reusable processing cache
```

Folder names use the recording start time in the local time zone and Gregorian calendar. If a name already exists, the next session uses `_02`, `_03`, and so on; existing sessions are never overwritten. The session UUID remains in `session.json` as `id`. The earlier v0.2.0 release used `yyyy-MM-dd/HH-mm-ss-<session UUID>/`; current versions also recognize these folders in place for recovery, without automatically renaming or moving them.

Each recording session contains a JSON manifest and separate system/microphone audio segments. Use the manifest's timestamps when aligning the two sources; opening two audio files together does not automatically align them. Audio stays in normal files that can be copied, played, or deleted without ZebTrace.

The default segment length is **600 seconds (10 minutes)**. The **Segment Length** submenu offers **1, 5, 10, 30, and 60 minutes**, persists the selection across launches, and is disabled while recording. A changed setting applies to the next session. Audio is encoded and written as it arrives, with a bounded pending-buffer queue; a 10-minute segment does not keep 10 minutes of PCM audio in memory. Pausing finalizes the current file without waiting for the selected duration.

If a custom folder is deleted or its disk is unavailable, recording reports an error and asks you to select a location again. It does not silently fall back to the default. Changing the save folder does not move or delete existing recordings. Recording recovery examines only the currently selected save folder and does not automatically search previous default folders.

On first launch, custom save-folder and segment-length preferences are migrated once from `org.mycontext.app` to `org.zebtrace.app`. Existing ZebTrace preferences take precedence. This migrates settings only: recordings and legacy app installations are not moved or removed.

The version 1 manifest includes:

| Fields | Meaning |
| --- | --- |
| `schemaVersion`, `id` | Data format version and session identifier |
| `directoryName` (optional) | Session folder name captured at creation, used to validate the new layout even if the local time zone changes; absent in older manifests |
| `startedAt`, `updatedAt`, `endedAt` | ISO 8601 session lifecycle timestamps |
| `status`, `endReason` | Recording outcome and why the session ended |
| `hostTimeOrigin`, `hostClockTicksPerSecond` | Shared monotonic clock origin and tick conversion |
| `chunkDurationSeconds` | Selected target segment length in seconds (default `600`); rotation happens at audio buffer boundaries |
| `chunks` | Source, filename, start offset, duration, sample rate, channels, frame count, and finalization state for each segment |

Chunk `startOffsetSeconds` values locate the tracks on the session timeline and preserve audio gaps. A gap greater than 100 ms or a format change starts a new segment. On the next launch after an unexpected exit, unfinished sessions in the currently selected save folder are marked `interrupted`; their last AAC segment may be unplayable. Longer segments increase the amount of audio exposed to this unfinished-file risk. This does not guarantee sample-perfect synchronization or recovery of an in-progress file.

Cleanup is manual and there is no application-level encryption. Stereo system output plus a mono microphone targets approximately **86 MB per hour**, with actual size depending on the devices and encoder. macOS backups or synchronization of your chosen folder may include the recordings; ZebTrace itself does not upload them. Headphones reduce the chance that the microphone captures system playback a second time; this demo does not perform echo cancellation or mix the tracks.

## Permissions and troubleshooting

If recording fails after denying access, open **System Settings → Privacy & Security** and check **Microphone** and the system audio/screen recording permission category. Category labels vary by macOS version. Quit and reopen ZebTrace after changing permissions if macOS requests it.

The system audio tap may deliver no buffers while nothing is playing. Its menu status then reads **Waiting for audio…** (waiting for sound), and recording continues. A denied system audio permission may also result in silent audio rather than a clear failure. Play an audible sound, check the source indicator, then pause and listen to the saved system track to verify capture. A microphone that delivers no data for 12 seconds, or stops delivering data for that long, causes recording to pause.

Device changes and waking from sleep can require a fresh recording session. Check the menu status and start again manually after choosing the intended input/output devices. Audio from protected content may not be available to capture.

For the first test, use the Mac's built-in microphone with headphone output. Enabling a Bluetooth microphone can switch the device to its hands-free profile (HFP) and change audio formats. Startup behavior across those transitions has not been verified on real Bluetooth hardware; full AirPods compatibility is not established.

For a quick segment-rotation check, select **1 minute** before starting, record at least 70 seconds while playing audio and speaking, pause, and verify that both tracks have playable segments and session metadata. Restore **10 minutes** afterward if desired; the selection is remembered. Then test a second session, quitting during recording, and changing an audio device. Unit tests and CI cannot verify real hardware capture or permission prompts.

## Developer requirements

Building from source requires Xcode **15.1+**, or compatible Command Line Tools with **Swift 5.9+** and a macOS **14.2+ SDK**, plus **CMake** (for example, `brew install cmake`). There are no third-party Swift package dependencies. The first app build needs internet access to fetch checksum-pinned whisper.cpp and llama.cpp sources; it then builds and bundles their native helpers. Model weights are not downloaded by the app build. See [inference runtime builds](inference-runtime.md).

## Build and run

```sh
git clone https://github.com/cutelizebin/zebtrace.git
cd zebtrace
make build      # Build and ad-hoc sign dist/ZebTrace.app
make run        # Build, then launch the menu bar app
make test       # Run unit tests without launching or recording
make check      # Run tests, validate scripts/plists, and build the app bundle
make install    # Build and install to ~/Applications/ZebTrace.app
make package    # Universal preview DMG, ZIP, and checksums; no signing account needed
```

Quit ZebTrace and any legacy MyContext instance before replacing an existing app bundle, installing an update, or cleaning. A fresh source checkout can build while an installed copy is running. `make install` replaces a previous ZebTrace installation at the same location; it does not remove legacy installations or recordings. None of these commands starts recording.

Launch the packaged `.app` with `open` or Finder. `swift run` does not provide the application bundle and privacy usage descriptions needed for the normal recording flow.

The bundle identifier is `org.zebtrace.app`. It changed from `org.mycontext.app`, so macOS permissions must be granted again for ZebTrace. Local builds use an ad-hoc signature by default. To use an available signing identity:

```sh
CODESIGN_IDENTITY='Apple Development: Your Name (TEAMID)' make build
```

The default app build and preview package use ad-hoc signing. The optional release-packaging mode performs Developer ID signing and notarization; see [distribution instructions](distribution.md). An ad-hoc rebuild may make macOS ask for permissions again even with the same bundle identifier. Installing and launching from a consistent path helps keep permission management understandable. `BUILD_CONFIGURATION=debug make build` produces a debug bundle.

The build packages the repository's `Resources/AppIcon.icns` into the app bundle and fails clearly if that resource is missing or empty. Rebuild the ICNS from the checked-in `Resources/AppIcon.png` on macOS with:

```sh
make icon
```

This runs `scripts/build-icon.sh` using macOS `sips` and `iconutil`. To use another square source image of at least 1024 × 1024 pixels, run `./scripts/build-icon.sh /path/to/source.png`. A subsequent app build includes the regenerated icon. See [branding notes](branding.md) for the image-generation details and prompt.

## Repository layout

```text
Sources/ZebTrace/         Menu bar app, recording library, models, storage, and lifecycle controls
Sources/ZebTraceCore/     Capture, persistence, language preferences, and resources
Sources/ZebTraceAnalysis/ Local model management, providers, transcript, and summary pipeline
Tools/ZebTraceAnalyze/    Developer command-line analysis harness
Tests/                   Automated tests with isolated fixtures
Resources/               Icon source, ICNS, app metadata, and signing entitlements
scripts/                 App/runtime/icon builds, packaging, checks, and local install
.github/                 CI and contribution templates
docs/                    Architecture, local review, and distribution boundaries
```

See the [architecture notes](architecture.md) for the recording boundaries and lifecycle, [CONTRIBUTING.md](../CONTRIBUTING.md) for development and review expectations, and [SECURITY.md](../SECURITY.md) for privacy and vulnerability reporting. Build and test results are available in [GitHub Actions](https://github.com/cutelizebin/zebtrace/actions).

## License

[MIT](../LICENSE). Copyright © 2026 ZebTrace contributors. Bundled inference runtimes and downloaded model weights retain their own licenses and notices; see [local review](local-review.md#models-and-licenses) and [runtime provenance](inference-runtime.md).
