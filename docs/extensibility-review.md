# Extensibility review — 0.4.0 local preview

This review covers the recording library, result provenance, model lifecycle, storage cleanup, localization, and the existing capture/analysis boundaries. It does not establish model accuracy, long-meeting performance, or a stable third-party plugin API.

| Area | Finding and resulting change |
| --- | --- |
| Result ownership | A global latest-result reader could show an earlier recording while a new session was processing. The library reads the selected session, validates its ID and current content hashes, and isolates asynchronous loads by selection/generation. A transcript has its own completion checkpoint before summary generation. |
| Native UI | The menu remains the capture entry point, with a reusable library, model manager, and storage/settings window. UI actions delegate to lifecycle controllers and storage services. Opening a window never starts recording or inference. |
| Storage ownership | Shared weights now live in the selected root's `Models`. Migration verifies copies, avoids overwriting conflicts, reports retained files, and moves partial downloads. Session results and derived caches remain beside their source recording. Prior roots stay listed for cleanup. |
| Deletion and concurrency | Session and model leases coordinate cooperating app/CLI operations. Cleanup enumerates recognized files, rejects unsafe paths/unknown session additions, preserves unrelated custom-root contents, and requires reconnected external roots for full cleanup. Uninstall validates a packaged `.app` target. Tests exercise temporary fixtures; the user's data was not deleted to test uninstall. |
| Localization | UI text, owned errors, exported document labels, and provider prompts use resources. System-language matching is data-driven over registered languages, with English fallback. Resource packaging and key/format tests enumerate registered languages instead of assuming exactly two. See [localization](localization.md). |
| Model lifetime | Downloaded weights and resident inference memory are distinct states. Helpers run sequentially and exit after work/cancellation. Deleting a model disables automatic review. |
| Catalog cost | Library refresh is triggered by lifecycle changes or an explicit reload. Status ticks do not rescan every recording; structured transcript entries load only for the selected detail. |

## Remaining explicit extension work

- `TranscriptionProvider` and `SummarizationProvider` are source-level seams. Arbitrary model files are not interchangeable. A new engine/profile still needs provider invocation, model catalog entries, preprocessing/timing evaluation, cache identity, license/provenance, and native packaging checks. The current UI deliberately offers the single supported ASR and summary profile.
- Whisper-specific VAD arguments and Qwen's ChatML template remain provider-specific. A future provider registry should declare each profile's runtime, auxiliary models, prompt/template identity, and resource requirements rather than spreading model checks into views.
- Adding a UI language requires its registered language entry, translated app/core resources, and permission descriptions. Summary prompts and output quality need separate evaluation; translating UI strings does not prove recognition quality for a new spoken language.
- The recording library currently indexes ordinary session folders under the current save root. Remembered older roots are exposed in storage settings. Large-library pagination/search indexing and a single view across multiple disconnected disks remain future work.
- This preview uses separate audio tracks and conservative text duplicate annotations. It does not implement acoustic echo cancellation, speaker diarization, word-level alignment, retention quotas, or power benchmarks for all-day recording.

Deleting the app in Finder cannot run an app cleanup callback. The explicit cleanup/uninstall flow covers app-managed files and settings; macOS owns permission history, logs, and Trash behavior. No uninstall watcher, login item, daemon, or background inference server is installed.
