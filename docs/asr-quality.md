# ASR quality and model choices

ZebTrace offers two compatible local speech models: Whisper large-v3-turbo Q5 (the existing default) and full Whisper large-v3 Q5. Use the speech-model picker in **Settings → Models and Storage…**. The selection is persisted and used by both manual and automatic processing. It does not start a download, rewrite a transcript, or change the spoken language setting: speech language detection remains automatic and separate from UI language.

**Prepare Models** verifies/downloads only the selected speech model and the shared summary/VAD files. The unselected model can remain uninstalled. Both variants appear in disk inventory and can be removed independently; deleting an unused variant does not disable a ready selected pipeline. A model's file hash is part of transcription-cache identity, so regenerating after a model change runs the new model instead of reusing another model's text. Repeating processing with the same model and configuration can reuse completed transcription.

| Choice | Speech-model bytes | Practical tradeoff |
| --- | ---: | --- |
| Whisper large-v3-turbo Q5 | 574,041,195 | Smaller and faster; existing default |
| Whisper large-v3 Q5 | 1,081,140,203 | Larger and slower; an alternative to compare on the user's recordings |

OpenAI describes Turbo as a pruned version of large-v3 with fewer decoder layers, trading some quality for speed. This does not establish which model is more accurate on an individual recording. See the [official model card](https://huggingface.co/openai/whisper-large-v3-turbo) and [pinned artifacts/licenses](inference-runtime.md#pinned-model-downloads).

## Local comparison, 2026-09-07

A private 35.1-second microphone track was decoded by the app's existing AVFoundation conversion path. Its system track was digital silence; generated entries came only from the microphone. The input had no measured clipped samples. No audio was uploaded, and neither the personal audio nor its transcript is included in the repository.

The comparison changed one factor at a time where possible:

- Reproduced Turbo's existing two-window output.
- Compared full-track input, explicit Chinese versus automatic language detection, VAD on/off, and a neutral transcription-style prompt. These changes did not resolve the identified Chinese substitution; automatic detection already returned Chinese.
- Compared full large-v3 with the same Q5 format, normalized windows, automatic language detection and VAD settings. It resolved that substitution, while some other wording still differed.
- Tested SenseVoice Small int8 through sherpa-onnx in an isolated developer environment. It also resolved that substitution, but produced a different verbatim/filled-pause style. This engine is **not integrated into the app**.
- Checked an earlier Chinese/English two-track sample. Full large-v3 had some English substitutions that the existing Turbo output did not, so this release does not label the larger model universally more accurate or silently replace the default.

For the 35.1-second microphone input, two sequential CLI invocations took **10.35 seconds with Turbo** and **18.30 seconds with full large-v3** on the test M4 Mac. These are observed wall times including process/model startup, after models were downloaded; they exclude summaries and do not constitute a cold-cache, long-meeting, Intel or power benchmark. A same-model full-track experiment is a separate comparison and is not the production windowing strategy.

There is no complete human-verified reference transcript, so no CER/WER or accuracy percentage is claimed. A plausible correction to one word does not validate every word, timestamp, or summary. Whisper token probabilities are also not calibrated accuracy scores.

## Repeatable evaluation

Use a recording with a human-corrected reference and keep original audio unchanged. Run both variants through the same decoder, preprocessing and chunk boundaries, recording wall time and model identity. The developer CLI supports an optional ASR filename:

```sh
ZebTraceAnalyze SESSION RUNTIME MODELS zh ggml-large-v3-turbo-q5_0.bin
ZebTraceAnalyze SESSION RUNTIME MODELS zh ggml-large-v3-q5_0.bin
```

These commands generate results in the supplied session; use separate evaluation copies when retaining both outputs. The service archives the previous review before replacing it. Compare omissions, insertions, substitutions, proper nouns, code-switching and silence separately. Timing tests should include model-load state, audio duration and hardware. Automated fake-provider tests prove orchestration and cache isolation, not transcription accuracy.

Future quality work should evaluate speech-aware boundaries/context, uncertain-word presentation and a Chinese-focused provider on a representative bilingual corpus. Preserve source-track/session identity and original text; a summary model must not silently invent a corrected transcript. Adding another engine also requires validated timestamps, cancellation, packaging, licenses, model ownership and cache identity.

Evaluation must cover ordinary device use without assuming a particular recording scenario: intermittent or distant speech, media playback, overlapping sources, music, environmental sounds, and periods with no recognized speech. Speech accuracy is only one measure of that audio history. Neither VAD decisions nor an empty transcript determines whether the original recording is worth retaining. The current ASR stage produces speech text, not a complete sound-event description; an empty transcript cannot establish silence, absence of activity, or capture success.

SenseVoice experiment references: [official model](https://k2-fsa.github.io/sherpa/onnx/sense-voice/pretrained.html), [sherpa-onnx v1.12.32 API example](https://github.com/k2-fsa/sherpa-onnx/blob/v1.12.32/python-api-examples/offline-sense-voice-ctc-decode-files.py). Experimental weights and the isolated Python environment were temporary; end users still need no Python or extra runtime installation.
