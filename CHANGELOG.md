# Changelog

Notable changes to ZebTrace are recorded here. Versions follow Semantic Versioning once releases are published.

## 0.2.0 — 2026-09-05 (preview)

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
