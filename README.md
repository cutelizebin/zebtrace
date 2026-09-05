<img src="Resources/AppIcon.png" width="96" alt="ZebTrace app icon">

# ZebTrace

[简体中文使用指南](docs/quick-start.zh-CN.md) · [Architecture](docs/architecture.md) · [Contributing](CONTRIBUTING.md)

A minimal, open-source macOS menu bar app for keeping your personal activity context on your own Mac. This first demo starts with audio: manually record system playback and your microphone, then save both locally.

**Status: early preview (0.2.0).** No automatic recording, transcription, cloud account, or telemetry. The app has a menu bar icon and no main window or Dock icon. English and Simplified Chinese are supported, with automatic system-language detection.

See the [release readiness notes](docs/release-readiness.md) for tested behavior and remaining hardware validation.

## What the demo does

- Start and pause recording from the menu bar.
- Capture system output through Core Audio taps and microphone input through AVAudioEngine.
- Save the two tracks separately as AAC `.m4a` segments, approximately 10 minutes each by default, with a `session.json` manifest and timing information for later alignment.
- Finish the current session when paused; starting again creates a new session.
- Show recording state and errors, open the recordings folder, and quit from the menu.
- Choose a save folder from the menu; the app remembers it for future sessions.
- Choose a segment length of 1, 5, 10, 30, or 60 minutes; the app remembers it for future sessions.
- Follow the system language or switch between English and Simplified Chinese from the menu.
- Pause conservatively on sleep, audio device changes, capture failures, and low disk space (under 500 MB available).

The longer-term direction is a personal context history with additional activity sources. Screen, browser, application activity, search, summaries, and transcription are outside this demo.

## Download and install

**[Download ZebTrace v0.2.0 for macOS (Universal DMG)](https://github.com/cutelizebin/zebtrace/releases/download/v0.2.0/ZebTrace-0.2.0-universal-preview-unnotarized.dmg)**

The same Universal app contains native Apple silicon and Intel versions. Visit the [v0.2.0 release page](https://github.com/cutelizebin/zebtrace/releases/tag/v0.2.0) for the ZIP, checksums, and release notes, or browse [all releases](https://github.com/cutelizebin/zebtrace/releases).

1. Open the DMG and drag **ZebTrace.app** into **Applications**.
2. Open ZebTrace from Applications. It appears as a **Z** in the menu bar.
3. Choose **Start Recording** and allow microphone and system audio access when macOS asks.
4. Choose **Pause and Save**, then **Open Latest Recording** to listen to both tracks.

You only need **macOS 14.2 or later**. **No Xcode, Swift installation, Homebrew, FFmpeg, account, or package-manager setup is required to run the app.** All runtime dependencies are Apple system frameworks and libraries. A ZIP and `SHA256SUMS` are provided as alternatives to the DMG.

The current preview is **not notarized**. If macOS blocks its first launch and you trust the download's source, try opening it once, then use **System Settings → Privacy & Security → Open Anyway** and confirm **Open**. Managed Macs may restrict this option. See [Apple's instructions](https://support.apple.com/en-us/102445). A future Developer ID signed and notarized build will simplify this first-launch step.

## Language

The default is **Language → Follow System**. The app checks macOS's preferred languages in order, uses English or Simplified Chinese when supported, and falls back to English otherwise. Chinese region/script variants select Simplified Chinese.

Choose **English** or **简体中文** to override the system preference. App menu labels and status text update immediately, including while recording, and the selection persists across launches. macOS-owned permission dialogs and standard file-picker controls use macOS's app/system language rules and may require relaunching after a system-language change. Permission usage descriptions are bundled in both languages.

## Developer requirements

Building from source requires Xcode **15.1+**, or compatible Command Line Tools with **Swift 5.9+** and a macOS **14.2+ SDK**. There are no third-party Swift package dependencies.

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

The default app build and preview package use ad-hoc signing. The optional release-packaging mode performs Developer ID signing and notarization; see [distribution instructions](docs/distribution.md). An ad-hoc rebuild may make macOS ask for permissions again even with the same bundle identifier. Installing and launching from a consistent path helps keep permission management understandable. `BUILD_CONFIGURATION=debug make build` produces a debug bundle.

The build packages the repository's `Resources/AppIcon.icns` into the app bundle and fails clearly if that resource is missing or empty. Rebuild the ICNS from the checked-in `Resources/AppIcon.png` on macOS with:

```sh
make icon
```

This runs `scripts/build-icon.sh` using macOS `sips` and `iconutil`. To use another square source image of at least 1024 × 1024 pixels, run `./scripts/build-icon.sh /path/to/source.png`. A subsequent app build includes the regenerated icon. See [branding notes](docs/branding.md) for the image-generation details and prompt.

## Saved data

The default save folder is `~/Downloads/ZebTrace`. The menu shows the current location; **Choose Save Folder…** opens the native folder picker and saves your choice across launches. Folder changes are disabled during recording. Pause first, choose another folder, then start a new session there.

```text
~/Downloads/ZebTrace/
└── yyyy-MM-dd/
    └── HH-mm-ss-<session UUID>/
        ├── session.json
        ├── system-00001.m4a
        ├── microphone-00001.m4a
        └── ...
```

Each recording session contains a JSON manifest and separate system/microphone audio segments. Use the manifest's timestamps when aligning the two sources; opening two audio files together does not automatically align them. Audio stays in normal files that can be copied, played, or deleted without ZebTrace.

The default segment length is **600 seconds (10 minutes)**. The **Segment Length** submenu offers **1, 5, 10, 30, and 60 minutes**, persists the selection across launches, and is disabled while recording. A changed setting applies to the next session. Audio is encoded and written as it arrives, with a bounded pending-buffer queue; a 10-minute segment does not keep 10 minutes of PCM audio in memory. Pausing finalizes the current file without waiting for the selected duration.

If a custom folder is deleted or its disk is unavailable, recording reports an error and asks you to select a location again. It does not silently fall back to the default. Changing the save folder does not move or delete existing recordings. Recording recovery examines only the currently selected save folder and does not automatically search previous default folders.

On first launch, custom save-folder and segment-length preferences are migrated once from `org.mycontext.app` to `org.zebtrace.app`. Existing ZebTrace preferences take precedence. This migrates settings only: recordings and legacy app installations are not moved or removed.

The version 1 manifest includes:

| Fields | Meaning |
| --- | --- |
| `schemaVersion`, `id` | Data format version and session identifier |
| `startedAt`, `updatedAt`, `endedAt` | ISO 8601 session lifecycle timestamps |
| `status`, `endReason` | Recording outcome and why the session ended |
| `hostTimeOrigin`, `hostClockTicksPerSecond` | Shared monotonic clock origin and tick conversion |
| `chunkDurationSeconds` | Selected target segment length in seconds (default `600`); rotation happens at audio buffer boundaries |
| `chunks` | Source, filename, start offset, duration, sample rate, channels, frame count, and finalization state for each segment |

Chunk `startOffsetSeconds` values locate the tracks on the session timeline and preserve audio gaps. A gap greater than 100 ms or a format change starts a new segment. On the next launch after an unexpected exit, unfinished sessions in the currently selected save folder are marked `interrupted`; their last AAC segment may be unplayable. Longer segments increase the amount of audio exposed to this unfinished-file risk. This does not guarantee sample-perfect synchronization or recovery of an in-progress file.

There is no automatic cleanup or application-level encryption. Stereo system output plus a mono microphone targets approximately **86 MB per hour**, with actual size depending on the devices and encoder. macOS backups or synchronization of your chosen folder may include the recordings; ZebTrace itself does not upload them. Headphones reduce the chance that the microphone captures system playback a second time; this demo does not perform echo cancellation or mix the tracks.

## Permissions and troubleshooting

If recording fails after denying access, open **System Settings → Privacy & Security** and check **Microphone** and the system audio/screen recording permission category. Category labels vary by macOS version. Quit and reopen ZebTrace after changing permissions if macOS requests it.

The system audio tap may deliver no buffers while nothing is playing. Its menu status then reads **Waiting for audio…** (waiting for sound), and recording continues. A denied system audio permission may also result in silent audio rather than a clear failure. Play an audible sound, check the source indicator, then pause and listen to the saved system track to verify capture. A microphone that delivers no data for 12 seconds, or stops delivering data for that long, causes recording to pause.

Device changes and waking from sleep can require a fresh recording session. Check the menu status and start again manually after choosing the intended input/output devices. Audio from protected content may not be available to capture.

For the first test, use the Mac's built-in microphone with headphone output. Enabling a Bluetooth microphone can switch the device to its hands-free profile (HFP) and change audio formats. Startup behavior across those transitions has not been verified on real Bluetooth hardware; full AirPods compatibility is not established.

For a quick segment-rotation check, select **1 minute** before starting, record at least 70 seconds while playing audio and speaking, pause, and verify that both tracks have playable segments and session metadata. Restore **10 minutes** afterward if desired; the selection is remembered. Then test a second session, quitting during recording, and changing an audio device. Unit tests and CI cannot verify real hardware capture or permission prompts.

## Repository layout

```text
Sources/ZebTrace/       Menu bar app and recording lifecycle controls
Sources/ZebTraceCore/   Capture, persistence, language preferences, and localized resources
Tests/                  Automated tests for core behavior
Resources/              Icon source, ICNS, app metadata, and signing entitlements
scripts/                App/icon builds, launch, checks, and local install commands
.github/                CI and contribution templates
docs/                   Architecture and design boundaries
```

See the [architecture notes](docs/architecture.md) for the recording boundaries and lifecycle, [CONTRIBUTING.md](CONTRIBUTING.md) for development and review expectations, and [SECURITY.md](SECURITY.md) for privacy and vulnerability reporting. Build and test results are available in [GitHub Actions](https://github.com/cutelizebin/zebtrace/actions).

## License

[MIT](LICENSE). Copyright © 2026 ZebTrace contributors.
