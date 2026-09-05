# Security and privacy

ZebTrace captures system playback and microphone input only after you explicitly start recording. This demo saves recordings locally and has no account, analytics, upload, or network service integration.

Audio and session metadata are stored in `~/Downloads/ZebTrace` by default, or in the folder you select through **选择保存位置…**. The app remembers and displays that location. A missing custom folder or unavailable disk causes an error instead of a silent fallback. Change locations after pausing; the app does not move or delete existing recordings. Recording recovery examines only the selected save folder, without automatically traversing previous default folders.

Custom save-folder and segment-length settings migrate once from `org.mycontext.app` to `org.zebtrace.app`, without overwriting existing ZebTrace settings. No recordings or old installations are moved or removed. Because the bundle identifier changed, macOS audio permissions must be granted again for ZebTrace.

Recordings are ordinary files, without application-level encryption or automatic retention limits. They remain until you remove them and may be included in your Mac's backups or synchronization of the chosen folder. ZebTrace itself does not upload recordings. System capture can include audio from other applications, so check what is playing before recording and let meeting participants know when appropriate.

Pause recording before changing devices or recording context. The app also attempts to pause safely on sleep, device changes, and capture errors. Audio is encoded and written continuously, with a bounded pending-buffer queue; the default 10-minute segment does not retain 10 minutes of PCM audio in memory. **分段时长** offers persistent 1/5/10/30/60-minute choices, disabled during recording and applied to the next session. A crash or power loss may leave the most recent segment incomplete; longer segments increase the amount of audio at risk, while earlier completed segments should remain readable. Pausing finalizes the current segment without waiting for its full duration. This is a demo and is not a backup or archival guarantee.

## Reporting a vulnerability

Do not include recordings, meeting content, access credentials, or identifying metadata in public reports.

Use [GitHub's private vulnerability reporting form](https://github.com/cutelizebin/zebtrace/security/advisories/new), also available under **Security → Advisories → Report a vulnerability**. Maintainers can manage this repository setting using [GitHub's private reporting setup instructions](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/configure-vulnerability-reporting/configure-for-a-repository).

If no private channel is available, open an issue containing only a request for a private reporting channel; do not publish exploit details or personal data there. This repository does not yet publish a dedicated security contact.

Security fixes currently target the latest development version. There are no long-term support releases or guaranteed response times.
