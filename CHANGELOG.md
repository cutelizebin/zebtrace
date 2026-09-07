# Changelog

Notable changes to ZebTrace are recorded here. Versions follow Semantic Versioning once releases are published.

## 0.4.3 — 2026-09-07 (preview, build 10)

This public preview adds local recording review and a main window to v0.2.0. [Download and release notes](https://github.com/cutelizebin/zebtrace/releases/tag/v0.4.3) · [English / 中文 release guide](docs/releases/0.4.3.md). Packages are ad-hoc signed and not notarized. Recording remains manual; local review is optional.

- Add a persistent ASR choice between Whisper large-v3-turbo Q5 and full large-v3 Q5. Prepare only the selected speech model and shared summary/VAD models; retain inventory, migration and removal for either choice. Model changes use separate ASR caches.
- Keep recording reviews independent of assumed settings or activities; clarify that speech recognition does not control capture and missing recognized speech does not establish silence or an absence of activity.
- Simplify the library with a native unified toolbar and resizable sidebar, a content-first reader, restrained system typography, and a single compact audio player. Move occasional actions into menus and retain source/segment selection on demand.
- Add **Open Main Window**, a date-grouped recording library with search, session selection, rendered Markdown, timestamped transcript navigation, original track playback, and per-session deletion.
- Bind generated content to session identifiers and manifest/content hashes; preserve independently verified transcripts when summaries are incomplete.
- Add native model management with current selections, download/deletion controls, disk usage, and distinct inference memory state.
- Keep shared models under the selected save folder's `Models/`; verify and migrate legacy/downloaded weights with no-overwrite transactions and retained-file reporting.
- Add storage inventory, explicit cleanup/uninstall, and cross-process leases protecting active analysis and model files from cooperating app/CLI mutations.
- Restrict crash-recovery cleanup to owned temporary directories; preserve unknown files, nested folders, and symbolic links.
- Move UI, owned error messages, exported text, and provider prompts into localization resources; make language resource packaging and parity tests enumerate registered languages.
- Name new session folders `yyyy-MM-dd/yyyy-MM-dd_HH-mm-ss/` using local Gregorian start times, adding `_02`, `_03`, and later suffixes when a name already exists.
- Keep session UUIDs in `session.json` and support recovery of the earlier `yyyy-MM-dd/HH-mm-ss-<UUID>/` layout in place, without automatically renaming or moving recordings.
- Add a single Recording Review submenu for saved-session transcription, summaries, cancellation, model management, and a recording library.
- Offer optional automatic review after a successful manual pause/save, disabled by default; recording, sleep, and quit take priority over inference.
- Bundle native whisper.cpp and llama.cpp helpers and download the recommended ASR/summary pair plus a small Silero VAD model explicitly, with fixed revisions, SHA-256 validation, shared storage, and resumable transfers.
- Keep transcription and summarization behind separate provider interfaces; run helpers sequentially and retain reusable work across cancellation or failure.
- Place transcript segments on the session timeline, annotate conservative possible cross-track duplicates, and retain both original tracks and texts.
- Transcribe short independently detected language windows with VAD filtering and per-window caches, while preserving the original timeline.
- Save transcripts, summaries, and provenance beside recordings; preserve a saved transcript when summarization fails and handle long text through section summaries and recursive merging.
- Add a developer CLI using the same analysis service and CMake-based runtime builds from pinned upstream sources. End users do not need Python, Homebrew, or a local inference server.

The first review remains a preview: no speaker identity recognition, reliable speaker-turn separation, or acoustic echo cancellation. Qwen3-ASR is not integrated; Qwen3 4B is used for text summaries. Model output needs checking against the saved audio.

## 0.2.0 — 2026-09-05 (recording-only preview)

- Support English and Simplified Chinese, following macOS preferred languages by default with a persistent menu override.
- Update menus and status messages immediately on language changes, and localize recording errors and permission descriptions.
- Bundle localization resources with the app so it can be moved to another Mac without the source checkout.
- Add Universal preview DMG and ZIP packages, installation instructions, and SHA-256 checksums; users do not need developer tools.
- Verify both binary architectures, deployment targets, localized resources, signatures, and runtime dependencies.
- Add a draft prerelease workflow and an optional Developer ID signing/notarization mode for later releases.

## Earlier local demo — 0.1.1

- Simplify application startup and menu setup, and show startup errors before exiting.
- Check microphone hardware availability before creating the input tap.
- Preserve finalization errors and the first write failure across repeated stop requests; add regression coverage for failed saves and queue overload.
- Separate the Chinese usage guide, pin CI actions, and allow checks from a fresh source checkout while an installed app runs.
- Rename the app to ZebTrace, with `ZebTrace.app`, the `ZebTrace` executable, the `ZebTraceCore` library, and bundle identifier `org.zebtrace.app` (build 2).
- Add a new application icon bundled as `AppIcon.icns`.
- Migrate legacy custom save-folder and segment-length preferences once without overwriting ZebTrace settings or moving or deleting recordings.
- Remove legacy recording-folder menu entries and limit interrupted-session recovery to the currently selected save folder.
- Require fresh macOS audio permissions for the new bundle identifier.
- Initial macOS menu bar demo with explicit recording controls.
- Separate local system output and microphone audio capture with segmented files and session metadata.
- Save to `~/Downloads/ZebTrace` by default, with a persistent save-folder picker in the menu bar; change folders between recording sessions.
- Default to 10-minute (600-second) segments, with persistent 1/5/10/30/60-minute choices applied to the next session; encode and write continuously with bounded buffering.
- Report unavailable custom folders explicitly without silently falling back to another location.
- Native Swift package, local app bundle scripts, and MIT open-source project scaffolding.
- macOS CI configuration for unit tests and app bundle validation.
