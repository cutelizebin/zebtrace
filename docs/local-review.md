# Local recording review

**[ZebTrace v0.4.3 (build 10)](https://github.com/cutelizebin/zebtrace/releases/tag/v0.4.3)** includes local transcription, text summaries, the recording library, and model/storage management. These features were absent from the earlier v0.2.0 recording-only release. Review operates on a saved recording; recording remains manually controlled.

Recording does not depend on a setting, activity, or the presence of speech. During a manually started session, the capture pipeline saves the audio it receives; VAD and ASR operate only on saved audio for the optional review. They do not discard non-speech from the original recording. A transcript with no recognized words does not establish silence or an absence of activity. The current review does not reliably identify music or environmental sound events, and summaries must not infer a setting or activity from missing transcript content.

## First use and daily use

Choose **Open Main Window** from the menu bar. The recording library has a date-grouped list, date/summary search, and a detail view for the selected session. Use **Record** / **Stop & Save** in the native window toolbar. The sidebar can be resized or collapsed. Close the window whenever you want; the app remains in the menu bar and closing the window does not pause recording.

Select any saved recording to read its summary or transcript without opening Finder. **Generate Review** starts transcription and summarization for that recording. The toolbar’s **More** menu contains **Regenerate**, copy, file, and deletion actions. The compact **Recording Review** menu remains available for the latest recording or an explicitly selected historical folder. Opening the library, selecting a row, or opening model settings never starts recording or inference.

Open **Settings** at the bottom of the sidebar for model/storage management, save location, or automatic summaries. On first use, the default Turbo combination downloads **3,072,206,549 bytes (about 3.1 GB)**; the full large-v3 combination uses **3,579,305,557 bytes (about 3.6 GB)**. The confirmation describes the chosen combination, and already prepared shared files are reused. Models live in `<recording root>/Models`, which is `~/Downloads/ZebTrace/Models` by default. **Models and Storage…** shows the supported speech and summary models, download state, disk use, and inference memory state. You can prepare the models, cancel processing to release inference memory, or delete downloaded models. The catalog offers Whisper large-v3-turbo Q5 (default) and full large-v3 Q5 for transcription, with one supported summary model. The speech-model picker is persistent and affects future processing; selecting a model does not download it or change saved results. Preparation uses the selected speech model plus shared summary/VAD files. ASR-only preparation is not exposed in this preview; recording itself needs none of these models. It does not accept arbitrary model files. Deleting model files and releasing inference memory are separate actions.

The app includes its inference executables, so no Python, Homebrew, FFmpeg, Ollama, or server setup is needed. Downloads need internet access; recordings and generated text are not sent to the download host. Changing the recording root relocates supported model files after validation and keeps recordings in their existing folders. Earlier application-support model files can be migrated into the selected root. Existing destination model files are checked instead of overwritten blindly.

Progress and cancellation appear for the session being processed. Other selected sessions keep their own details; an automatic completion does not change your selection or steal focus. Summaries render as readable Markdown, and the transcript includes source labels and clickable estimated times. The bottom player keeps play/pause and seeking within reach. Its source menu switches between microphone and system audio; recordings with multiple segments also expose segment choices and their session-relative ranges. The playback counter is relative to the chosen segment; transcript links seek using the original session offset. Playback is one segment at a time; the app does not mix the tracks or imply synchronized playback. Switching sessions or closing the window stops playback. A Markdown application is not required.

**Summarize After Saving** is off by default and becomes available after the models are ready. Enabling it applies to future successful manual **Pause and Save** actions. It does not enable recording on launch, wake, or a timer. Analysis uses the UI language selected when the task starts for summary output; speech recognition detects the spoken language automatically. The interface supports English and Simplified Chinese through resource files; see [adding a localization](localization.md). Some lower-level diagnostics may use the operating system or helper language.

## Recording takes priority

The app runs one download/analysis job at a time. Starting recording cancels that job and waits for it to stop before starting capture. Sleep and quit also cancel processing; quit waits for the helper to exit. Cancellation does not silently resume on wake or relaunch. Retry manually to reuse completed cached work.

Within a review, transcription and summarization run sequentially, with four CPU threads requested per helper. Each helper exits when its work ends instead of keeping both models resident. Long transcripts are split into sections, summarized, and recursively combined. This reduces concurrent model memory use, but is not a fixed memory ceiling or a guarantee that every recording fits a 16 GB Mac. If condensation cannot finish within its limits, the saved transcript remains available.

Analysis failures do not alter the recording pipeline or delete original audio. If transcription finished before cancellation or a summary failure, its saved transcript remains readable in the selected recording. While processing, the library shows the current progress and any validated saved transcript instead of presenting an older summary as new success.

## Results and timing

| Location inside the session folder | Contents |
| --- | --- |
| `transcript.md` | Readable transcript with session-relative times and source labels |
| `transcript.json` | Structured transcript entries, source file references, and possible-duplicate annotations |
| `summary.md` | Successfully written summary with a transcript link; absent while a new summary is incomplete |
| `transcription.json` | Session and content binding for the saved transcript before summarization completes |
| `analysis.json` | Completion metadata, output language, model/runtime and source-audio hashes, plus session/content binding |
| `.zebtrace-analysis/` | Reusable ASR and summary caches, a session lock, temporary work, and a retained previous review when replacing results |

Each audio chunk is normalized to mono 16 kHz PCM with streaming conversion, then read in short windows, choosing a low-energy boundary near 20 seconds where possible. Each helper request contains at most 24 seconds of PCM. Language detection runs for each window; the auxiliary Silero VAD model filters non-speech before transcription. Completed window results are cached so cancellation need not discard a whole recording chunk's progress. The provider's segment times are added to the window offset and original chunk `startOffsetSeconds`, then entries from both tracks are placed on the session timeline. These are model-estimated segment timestamps, not verified speaker turns or word-level forced alignment. Track labels identify the capture source, not an individual speaker.

Possible duplicate capture is deliberately conservative: substantial cross-track text must match exactly after case/punctuation normalization and overlap in time. The app marks the possible match and keeps both texts. Similar wording, different recognition results, and real simultaneous speech are not grounds to discard a track. The preview does not mix the original recordings, perform acoustic echo cancellation, identify people by voice, or reliably separate individual speaker turns. Two capture sources do not establish two participants, and a source can contain multiple or overlapping voices. Headphones can reduce microphone pickup of playback, but summaries still need review against the transcript and audio.

Completed cache entries are retained after cancellation. Cache identity includes the relevant audio content and source timing, preprocessing/cache version, runtime identity, and model content; summary reuse also depends on text, output language, and summary stage. Changing a model or runtime must not reuse incompatible results. A session lock prevents two analysis processes from writing the same cache simultaneously.

Recordings, results, and caches are ordinary local files without application-level encryption. The library validates the selected session's ID before showing generated content. Current results also bind the source manifest and content hashes; legacy results use their session ID. A copied or changed result is unavailable until regenerated, rather than being displayed as a different recording's review.

## Storage and removal

The selected root groups recording folders and their generated files/caches alongside a shared `Models` folder. Small preferences and macOS-managed state remain in their normal system locations. Changing the root leaves existing recordings where they are; the storage page lists remembered roots so their usage and cleanup remain visible.

A recording's secondary menu can **Delete Generated Content…** while keeping its audio, or **Delete Recording…** including its generated files and hidden cache. Both require confirmation and use the macOS Trash. Stop recording and processing before removing files. Deleting a model required by the selected combination disables automatic summaries; deleting an unused alternative does not. Model deletion retains recording folders and saved results; it does not clear session caches.

Open **Cleanup and Uninstall…** for explicit app cleanup. Recordings are kept by default; including them is a separate opt-in. Cleanup removes recognized model files and app settings, and can move recordings from available remembered roots to Trash. The uninstall action also moves the app to Trash and quits. Unknown user files and unavailable disks are not silently erased. Trash contents still occupy space until the user empties Trash.

Dragging the app to Trash in Finder does not invoke an app cleanup callback and does not remove its recording folders or models. Use the in-app cleanup before uninstalling if you want those removed. macOS owns microphone/system-audio permission records; ZebTrace does not remove those records or promise to clear every operating-system trace.

## Models and licenses

The catalog offers two speech models and shared summary/speech-detection models. Quality varies by recording; the full Whisper model is not universally more accurate:

| Role | Model | Download bytes | License |
| --- | --- | ---: | --- |
| Transcription | Whisper large-v3-turbo, Q5_0 | 574,041,195 | MIT |
| Transcription (optional) | Whisper large-v3, Q5_0 | 1,081,140,203 | MIT |
| Summary | Qwen3 4B, Q4_K_M | 2,497,280,256 | Apache-2.0 |
| Speech detection (internal) | Silero VAD v6.2.0 | 885,098 | MIT |

**Qwen3 4B summarizes text; Qwen3-ASR is not included.** The two Whisper choices use the same bundled runtime and can differ in accuracy by recording. Proposed speaker separation, echo-aware association, and replaceable ASR backends are described in the [audio-understanding design](audio-understanding-design.md); they are not implemented features of v0.4.3.

Downloads pin repository revisions and expected sizes/SHA-256 hashes. HTTP Range requests allow retrying partial transfers; completed files are checked before use. A failed integrity check is an error, not a silent model substitution. The model manager can remove incomplete or damaged model files for a fresh download.

The native whisper.cpp and llama.cpp runtimes have their own source notices; model weights retain their separate licenses. See [runtime provenance, exact model URLs, hashes, and licenses](inference-runtime.md). The app's MIT license does not replace these notices.

`TranscriptionProvider` and `SummarizationProvider` are separate code interfaces in `ZebTraceAnalysis`. Another provider can replace either stage while the app continues to own audio preparation, session timing, job cancellation, result storage, and caching. This is an implementation boundary, not a promise that any downloaded model file is compatible. A replacement must declare and validate its real timestamp behavior, resource needs, and cache identity.

## Developer harness

The command-line target uses the same service as the menu bar app. With a completed non-sensitive session, built helpers, and prepared model files:

```sh
swift run -c release ZebTraceAnalyze \
  /path/to/session \
  /path/to/ZebTrace.app/Contents/Helpers \
  "$HOME/Downloads/ZebTrace/Models" \
  zh
```

Use `en` for English summary output. The positional arguments are `SESSION RUNTIME MODELS zh|en [ASR_FILENAME]`. Omit the final argument for Turbo, or pass `ggml-large-v3-q5_0.bin` for full large-v3. This command prepares the chosen model directory immediately and downloads missing weights without an app dialog; use already prepared models for an offline check. It performs real inference and writes results beside the session, without capturing new audio. Keep personal recordings, transcripts, prompts, caches, and benchmark output out of Git. Runtime construction is documented in [inference-runtime.md](inference-runtime.md).

See [ASR model comparison and evaluation limits](asr-quality.md).

Model output can contain recognition errors and unsupported summary claims; no objective accuracy score is established by this demo. Universal packaging targets Apple silicon and Intel, but compilation alone does not establish Intel runtime reliability, older-macOS compatibility, long-recording memory use, or battery cost. See [release readiness](release-readiness.md) for the validation boundary.
