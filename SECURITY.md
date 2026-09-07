# Security and privacy

ZebTrace captures system playback and microphone input only after you explicitly start recording. Recordings and analysis results stay local; there is no account, analytics, or audio/text upload. Version 0.4.3 adds optional local transcription and summaries. The earlier v0.2.0 release is recording-only.

Audio and session metadata are stored in `~/Downloads/ZebTrace` by default, or in the folder you select through **选择保存位置…**. The app remembers and displays that location. A missing custom folder or unavailable disk causes an error instead of a silent fallback. Change locations after pausing; the app does not move or delete existing recordings. Recording recovery examines only the selected save folder, without automatically traversing previous default folders.

Custom save-folder and segment-length settings migrate once from `org.mycontext.app` to `org.zebtrace.app`, without overwriting existing ZebTrace settings. No recordings or old installations are moved or removed. Because the bundle identifier changed, macOS audio permissions must be granted again for ZebTrace.

Recordings are ordinary files, without application-level encryption or automatic retention limits. They remain until you remove them and may be included in your Mac's backups or synchronization of the chosen folder. ZebTrace itself does not upload recordings. System capture can include audio from other applications, so check what is playing before recording and let people whose voices are captured know when appropriate.

Pause recording before changing devices or recording context. The app also attempts to pause safely on sleep, device changes, and capture errors. Audio is encoded and written continuously, with a bounded pending-buffer queue; the default 10-minute segment does not retain 10 minutes of PCM audio in memory. **分段时长** offers persistent 1/5/10/30/60-minute choices, disabled during recording and applied to the next session. A crash or power loss may leave the most recent segment incomplete; longer segments increase the amount of audio at risk, while earlier completed segments should remain readable. Pausing finalizes the current segment without waiting for its full duration. This is a demo and is not a backup or archival guarantee.

## Local analysis and downloads

On first use, Recording Review asks before downloading the recommended models from fixed Hugging Face repository revisions. The download host receives normal download requests, not recordings or transcript content. Completed model files are checked against expected sizes and SHA-256 hashes; canceled or interrupted transfers can resume through HTTP Range requests. Models are shared across recordings in `Models/` under the selected recording folder (default `~/Downloads/ZebTrace/Models`) and use about 3.1 GB before additional temporary/runtime space. The app bundles native inference helpers and does not invoke a user-installed Python environment, Ollama server, or hosted inference API.

Automatic review is off by default. After explicitly enabling it with models ready, only a successful manual pause/save starts processing. Starting a new recording, sleep, and quit cancel analysis; quit waits for helpers to stop. Processing failures do not delete audio or change recording state. No inference resumes automatically on launch or wake.

Analysis writes `transcript.md`, `transcript.json`, `summary.md`, and `analysis.json` beside the audio. These files can contain sensitive conversation content, source filenames, timestamps, and model/runtime/source hashes. The hidden `.zebtrace-analysis` folder contains reusable transcript/summary caches, temporary derived audio/prompts, and a previous-review copy when replacing results; completed caches remain after cancellation. Temporary work is cleaned after ordinary termination and stale work is checked on a later review of the same session, not by a global scan.

Removing a model required by the selected pipeline disables automatic summaries and retains recordings, results, and session caches. Removing an unused ASR alternative leaves a ready selected pipeline available. To delete a recording and its derived data, stop processing and remove the entire session folder, including hidden files. Results and caches have no application-level encryption or automatic retention policy and may be included in system backups or folder synchronization.

Generated transcripts and summaries may contain omissions or unsupported claims. Duplicate-capture annotations preserve both sources; they do not establish that a voice is an echo or identify a speaker. Model-provided segment timestamps are estimates, not forced alignment. Treat recorded speech and transcript text as untrusted content; providers should not gain tools, shell execution, or network access from instructions embedded in a recording. The current summary helper produces text only.

Runtime source archives and model weights retain separate upstream licenses and provenance. Review changes to source pins, patches, model hashes, helper permissions, and process cancellation as part of dependency updates. See [local review](docs/local-review.md) and [inference runtime provenance](docs/inference-runtime.md).

## Reporting a vulnerability

Do not include recordings, transcript content, access credentials, or identifying metadata in public reports.

Use [GitHub's private vulnerability reporting form](https://github.com/cutelizebin/zebtrace/security/advisories/new), also available under **Security → Advisories → Report a vulnerability**. Maintainers can manage this repository setting using [GitHub's private reporting setup instructions](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/configure-vulnerability-reporting/configure-for-a-repository).

If no private channel is available, open an issue containing only a request for a private reporting channel; do not publish exploit details or personal data there. This repository does not yet publish a dedicated security contact.

Security fixes currently target the latest development version. There are no long-term support releases or guaranteed response times.
