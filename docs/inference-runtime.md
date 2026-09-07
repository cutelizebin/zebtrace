# Local inference helpers

ZebTrace packages `whisper-cli` for transcription and `llama-completion` for text summaries. Both are native executables: users do not need Python, Homebrew, FFmpeg, or a local server. Model files are separate, explicit downloads and can be reused offline.

## Build

On a Mac with Xcode Command Line Tools and CMake:

```sh
scripts/build-inference-runtime.sh
INFERENCE_ARCHITECTURES=universal scripts/build-inference-runtime.sh
```

`INFERENCE_ARCHITECTURES` accepts `native` (default), `arm64`, `x86_64`, or `universal`; it falls back to `BUILD_ARCHITECTURES` when unset. `INFERENCE_BUILD_JOBS` defaults to `4`. `INFERENCE_OUTPUT_DIR` overrides `dist/inference-runtime`.

Sources and build caches live under ignored `dist/vendor/cache`. The script pins official source archives by commit and SHA256, and refuses mismatched cached archives. It builds only the two required helpers. The resulting directory contains both executables, `licenses/`, and `runtime-info.json`:

```text
dist/inference-runtime/arm64/
dist/inference-runtime/x86_64/
dist/inference-runtime/universal/
```

Apple Silicon builds use Accelerate and Metal with shader source embedded in the executable. Intel builds use CPU and Accelerate with a conservative CPU instruction baseline. Third-party libraries are statically linked; only Apple system libraries/frameworks remain dynamic. The deployment target is macOS 14.2. This makes source selection reproducible; bit-identical binaries still depend on the compiler and SDK. A build on a current Mac does not establish runtime compatibility on every older Mac.

| Runtime | Fixed source commit | Archive SHA256 |
| --- | --- | --- |
| [whisper.cpp](https://github.com/ggml-org/whisper.cpp/tree/371b5a7561823ab2bb32142d2751e35e7534727b) | `371b5a7561823ab2bb32142d2751e35e7534727b` | `89051d8fca516a3ad1f5c2f8f9d2fccb089afbaec338fca3f8731999babc6f81` |
| [llama.cpp](https://github.com/ggml-org/llama.cpp/tree/427291b5b34cd914a31b3fd3b61a68f6184f4b9f) | `427291b5b34cd914a31b3fd3b61a68f6184f4b9f` | `056ae92c363e5c761e6c03102f4aa6c1551e134f9e322eea1a4cf3f6cf87f585` |

The checked-in `scripts/patches/llama-completion-output.patch` changes one upstream line: the completion end marker goes to debug logging instead of stdout. Generation behavior is unchanged. The runtime manifest records this patch; its application is checked against the pinned source.

## App bundle integration

The runtime script does not modify an app bundle. During app staging, copy the matching architecture's two executables into `Contents/Helpers`, `runtime-info.json` into `Contents/Resources/InferenceRuntime`, and `licenses/` into `Contents/Resources/InferenceLicenses`. JSON belongs in resources, outside the nested-code directory. Sign each helper with the app's signing identity and Hardened Runtime options before signing the outer app. Include these files in the final signature/dependency checks.

For Universal releases, run the runtime builder with `INFERENCE_ARCHITECTURES=universal` and copy its Universal outputs. The script verifies that dependencies are system libraries and that helpers contain no `LC_RPATH`; additionally inspect each final bundled slice using `lipo -archs` and `otool -arch all -L`. Relocation and final app signing should be verified after packaging.

Start helpers with `Process` arguments and closed stdin. Drain stdout and stderr concurrently, preserve bounded diagnostics, check exit status, and terminate the child on cancellation. Run one GPU model at a time. No model URL, download command, shell interpolation, or listening server is needed during inference.

## Transcription contract

Prepare a local mono 16 kHz PCM16 WAV with AVFoundation, then invoke:

```sh
whisper-cli -m /path/to/ggml-large-v3-turbo-q5_0.bin \
  -f /path/to/audio.wav -l auto -oj -of /path/to/result -t 4 \
  --vad -vm /path/to/ggml-silero-v6.2.0.bin -vsd 500 -vp 200
```

The same invocation accepts the catalog’s `ggml-large-v3-q5_0.bin` alternative without changing the runtime.

Read `/path/to/result.json` only after successful exit. `transcription[]` entries contain `text` and `offsets.from` / `offsets.to` in **milliseconds relative to the supplied WAV**. The app supplies windows near 20 seconds, at most 24 seconds each, and adds both the window offset and recording chunk's manifest offset to place segments on the session timeline. Silero VAD filters non-speech, while language detection runs independently per window. The detected language is in `result.language`. `-dl` only detects language and exits; it is not the transcription flag. Do not use `.en` models for recordings containing Chinese speech.

## Summary contract

Write the model-formatted input to a UTF-8 file and invoke:

```sh
llama-completion -m /path/to/Qwen3-4B-Q4_K_M.gguf \
  -f /path/to/prompt.txt --no-conversation --no-display-prompt \
  --simple-io --color off --no-perf -c 8192 -n 1600 \
  --temp 0.1 --seed 42 -ngl 99 -t 4
```

Use `-ngl 0` on Intel. Stdout carries generated text and trailing whitespace; stderr carries runtime diagnostics. Keep a finite context and output-token limit. For Qwen3, supply its ChatML turns and finish the prompt with an assistant prefix followed by an empty `<think>\n\n</think>\n\n` block to select a direct answer. Also ask for `/no_think` in the user instruction. This model can still make unsupported claims; summaries must remain linked to the source transcript. Context length is a token budget, not an audio-duration limit.

## Pinned model downloads

| Model | Bytes | SHA256 | License |
| --- | ---: | --- | --- |
| [Whisper large-v3-turbo Q5_0](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo-q5_0.bin) | 574041195 | `394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2` | [MIT](https://huggingface.co/ggerganov/whisper.cpp) |
| [Whisper large-v3 Q5_0](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-q5_0.bin) | 1081140203 | `d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1` | [MIT](https://huggingface.co/ggerganov/whisper.cpp) |
| [Qwen3 4B Q4_K_M](https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/bc640142c66e1fdd12af0bd68f40445458f3869b/Qwen3-4B-Q4_K_M.gguf) | 2497280256 | `7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5` | [Apache-2.0](https://huggingface.co/Qwen/Qwen3-4B-GGUF) |
| [Silero VAD v6.2.0](https://huggingface.co/ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b/ggml-silero-v6.2.0.bin) | 885098 | `2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987` | [MIT](https://huggingface.co/ggml-org/whisper-vad) |

These URLs pin model repository revisions. Download to a temporary file, verify both byte count and SHA256, and publish it atomically into the model cache. The default Turbo/summary/VAD combination totals 3,072,206,549 bytes. Selecting full large-v3 instead totals 3,579,305,557 bytes; keeping both ASR choices installed totals 4,153,346,752 bytes. Only the selected combination is needed for preparation/readiness. These totals exclude temporary download space and inference memory. Source-code licenses and model licenses are separate; keep their notices with the distribution.

## Verification

Use the pinned whisper.cpp repository's public `samples/jfk.wav` for ASR smoke tests and a non-sensitive short prompt for summary smoke tests. Confirm successful exit, valid JSON offsets/language, finite output, and clean completion stdout. Run these serially. Performance measured on one M4 is not a promise for Intel, older Apple Silicon, long recordings, or other languages.
