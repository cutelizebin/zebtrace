# Open-source readiness

This document records validation for the **0.4.2, build 9** preview, including local transcription, summaries, and the recording library. The earlier **v0.2.0** release contains recording only. Recording checks alone do not validate the inference path.

The repository includes source, the MIT license, icon provenance, contribution and privacy documentation, build scripts, and CI configuration. Native inference sources and model files have pinned identities and separate license notices. Preview packaging uses ad-hoc signing; Developer ID signing and notarization remain an optional workflow requiring credentials and successful Apple validation.

## Published recording baseline

The v0.2.0 review checked recording lifecycle with synthetic audio, English/Chinese resources, native and cross-architecture compilation, relocated bundle resources, and the actual ZIP/DMG package structure, checksums, signatures, and system-library dependencies. The downloaded DMG was mounted for inspection and detached afterward. These checks did not establish Intel hardware reliability, real-device capture coverage, or long-meeting performance.

Remote results are available in [GitHub Actions](https://github.com/cutelizebin/zebtrace/actions). Published downloads are on [GitHub Releases](https://github.com/cutelizebin/zebtrace/releases); those links do not imply that current uncommitted or unpublished source has passed remote CI.

## Checks for the local review preview

Local checks on 2026-09-06 passed **125 automated tests**, including session/result isolation, localization parity, model migration, deletion boundaries, and app/CLI lease exclusion. The Universal app and both native helpers passed strict signing, architecture, macOS deployment-target, localization, and dynamic-dependency checks. Native library/model/storage view snapshots were inspected in English and Simplified Chinese; this is not exhaustive accessibility or interaction testing.

An existing microphone-only test recording was processed locally with the final helpers and newly co-located models; the system file decoded to digital silence and every transcript segment came from the microphone. Re-summary took **16.67 seconds**, reusing the already completed ASR cache, so it is not a full transcription benchmark. The conservative summary identifies ambiguous wording, but still favors extraction and is not guaranteed free of hallucinations. No accuracy percentage is claimed.

The actual **3,072,206,549-byte** model set migrated from legacy Application Support into the selected Downloads root and passed its catalog checks; the old model directory was removed. Original audio and manifests are checked separately from derived outputs. Destructive uninstall tests use fixtures; the user installation was not uninstalled. That development build was not published. The final ZIP was extracted outside the checkout and installed locally; its app passed verification. The DMG was mounted read-only, independently verified, and detached. All 15 original audio/manifest checksums remained unchanged.


The 0.4.1 (build 7) interface revision additionally passed native toolbar and component-layout checks across both languages, light/dark appearance and narrow windows. Its final ZIP and mounted DMG were verified again, and the ZIP app was installed locally. See [interface design and capture limitations](interface-design.md).

| Area | Required evidence |
| --- | --- |
| Automated behavior | Recording/session tests plus analysis validation, timestamp mapping, cache identity, cancellation, and transcript preservation on summary failure |
| Runtime build | Fixed source archives and patches verified; both helpers built for arm64 and x86_64 |
| Final package | Main app and both helpers pass signature, architecture, deployment-target, and dependency checks after ZIP extraction and DMG mounting |
| First use | Model download size/consent, shared location, hash verification, cancel/retry, and damaged-model recovery |
| Menu and reader | One Recording Review submenu, English/Chinese presentation, historical-session selection, copy/folder actions, and saved-transcript fallback |
| Lifecycle | Default-off automation, successful manual save only, recording priority, sleep/quit cancellation, helper exit, and no automatic resume |
| Real inference | Non-sensitive audio checked against an independent reference; summary claims checked against the transcript; cold/warm timing and memory observations labeled with their scope |
| Long recordings | Multiple audio chunks, overlapping sources, silence, text sectioning/recursive merging, and bounded failures without losing the transcript |
| Publication hygiene | No personal recordings, transcripts, prompts, caches, weights, credentials, or machine-specific paths in source or release assets |

Fake-provider tests can establish orchestration behavior; they cannot establish recognition accuracy, summary faithfulness, real helper output compatibility, or device performance. Native source compilation and dependency audits also cannot establish that inference works on every Intel Mac or the minimum supported macOS.


## ASR selection checks (2026-09-07)

The 0.4.2 update passed **130 automated tests**, including selected-model readiness/preparation and model-file ownership. Both Whisper variants remain managed by the existing store; an uninstalled alternative does not block the selected pipeline. The updated ZIP was extracted and installed locally; the DMG was mounted read-only, verified and detached. Both passed the Universal app/helper checks.

A separate native model-picker probe passed 19 assertions in each of English and Simplified Chinese. It exercised the actual menu-item action through the owner callback, persisted selection and restoration, invalid selections, and recording/shutdown guards without starting downloads or inference. Window snapshots confirmed that a missing, unused alternative leaves the selected pipeline ready, while selecting that missing model enables the download action.

One existing microphone-only recording was reprocessed with full large-v3 Q5 in **31.85 seconds**, including transcription and summary generation. Its metadata binds the full model's SHA-256, and all 15 original audio/manifest hashes remained unchanged. This is a local integration check, not a complete accuracy benchmark; another English sample showed regressions relative to Turbo. See [ASR comparison and limitations](asr-quality.md). Experimental SenseVoice weights and the temporary Python environment were removed; full large-v3 remains an app-managed optional model.

## Scene-independent recording checks (2026-09-07)

A subsequent clarification removed scenario-specific transcript naming and made both summary prompts explicit about their speech-text evidence boundary. All **131 tests** passed, including a new integration test covering non-speech tone and digital silence in both output languages: empty ASR output skips summary inference and preserves the original audio and manifest bytes. This does not benchmark real sound-event recognition or guarantee that a model follows every prompt instruction. These changes are included in build 9; build 8 packages predate the clarification.

## 0.4.2 build 9 release checks

The final source passed **132 automated tests**, including crash-recovery cleanup that removes only recognized scratch directories and preserves unknown content and symbolic links. The publication scan found no personal audio, transcript files, local model weights, private workspace paths, or credential patterns in the source candidates. The release workflow includes version-specific bilingual notes and builds packages from the version tag; GitHub Actions and the release page record the remote outcome.

The build 9 Universal package passed archive checksums and strict app/helper validation after ZIP extraction outside the checkout and read-only DMG mounting. Both architectures, macOS 14.2 deployment targets, localizations, signatures, and system-only dynamic dependencies were checked. The DMG was detached afterward. The app payload contains no personal recordings or model weights. These package checks do not establish notarization or Intel hardware inference quality.

## Remaining hardware and distribution boundaries

- Test extended recordings and audio segment boundaries with both tracks.
- Exercise AirPods/Bluetooth profile changes, USB removal, permissions, sleep/wake, and quitting during capture.
- Validate macOS 14.2 and Intel hardware directly; they remain targets rather than independently established runtime coverage here.
- Test the final installed app on a Mac without developer tools, including local review after the model download.
- Measure local-review memory, responsiveness, and power use during representative long sessions; sequential helpers are a design choice, not a fixed memory guarantee.
- Keep Apple's first-launch manual approval instructions with unnotarized previews; claim normal Gatekeeper acceptance only after a signed, notarized distribution has passed assessment.

## Publishing

The repository is [cutelizebin/zebtrace](https://github.com/cutelizebin/zebtrace). The release workflow defaults to a draft prerelease with Universal preview downloads. Review the final artifacts and update the version-specific documentation before publishing the draft. Retain the stated limitations; adding source code or producing a local package is not a release announcement.

Private vulnerability reporting is described in [SECURITY.md](../SECURITY.md). See [README.md](../README.md), [the Chinese guide](quick-start.zh-CN.md), [local review](local-review.md), and [distribution](distribution.md) for usage and validation procedures.
