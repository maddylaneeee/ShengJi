# LocalScribe User Guide

**English** | [Chinese (Simplified)](USAGE.zh-CN.md) · [Project overview](../README.md)

For installation and first-launch permissions, start with the [installation guide](../INSTALL.md).

## Transcribe and edit

Choose a microphone, an audio/video file, or Mac audio as the input. On macOS 26 or later, try Apple Speech when it supports your language. On earlier systems, select and download a third-party model first. SenseVoice and Parakeet support files only; Whisper supports microphone and file transcription. Floating live captions require macOS 26 or later and accept microphone, Mac audio, or both mixed.

Results appear progressively. You can pause and resume transcription; session journals and recovery snapshots help recover interrupted tasks. In the editor, search, replace, delete selections, and trim ranges. Import SRT, WebVTT, TXT, Markdown, or LocalScribe JSON to continue editing, or append microphone transcription to an imported transcript.

Translate the finished transcript with Apple Translation (the default), Apple Intelligence, or optional NLLB. Live-caption translation is currently disabled. See [AI enhancement and services](AI-SERVICES.md) for proofreading, summaries, model selection, and fallback behavior.

Export TXT, Markdown, JSON, PDF, SRT, or WebVTT, or copy the text to the clipboard. Long Chinese, Japanese, and Korean subtitles are wrapped and split automatically.

## Recognition and translation engines

When your macOS version and language support Apple Speech, try it first. Recognition quality varies with language, recording quality, and task; compare engines on representative audio before choosing one.

| Engine | Use | Runtime |
| --- | --- | --- |
| Apple Speech | Microphone, files, live captions (macOS 26) | SpeechAnalyzer / SpeechTranscriber |
| Whisper | Microphone and files | whisper.cpp GGML, Metal with CPU fallback |
| SenseVoice | Files | sherpa-onnx, Core ML where eligible, CPU fallback |
| NVIDIA Parakeet | Files | sherpa-onnx, Core ML where eligible, CPU fallback |
| Apple Translation | Default post-transcription translation | macOS Translation framework |
| NLLB | Optional post-transcription translation | CTranslate2 CPU/int8 |
| Gemma 4 | Proofreading, refinement, summarization | llama.cpp with Metal, on device |
| Apple Intelligence | Translation, proofreading, refinement, summarization | Apple Foundation Models framework, on device (macOS 26+) |

Whisper uses the bundled Silero VAD to skip silence in long media and filters silent, low-confidence, repeated, and known hallucinated output.

**Advanced settings.** For third-party engines, the collapsed Advanced section in the right inspector exposes the options each runtime supports—for Whisper: prompt, temperature and fallback, beam or greedy search, context length, silence and confidence filters, VAD, and thread count. The last engine, model, and settings are remembered; **Restore Model Defaults** resets only the selected engine.

## Burn subtitles into video

Open **Burn Subtitles** on the home screen or choose **File → Burn Subtitles…** (⇧⌘B). Choose or drag in a video (MP4, MOV, M4V, or another format macOS can play) and a subtitle file: SRT, WebVTT, LocalScribe JSON, ASS/SSA, SBV, or TTML/DFXP. Files without valid timestamps are flagged as unsupported; ASS styling and TTML regions are ignored.

After a video transcription, **Burn into Video** next to Export opens the same page with the original or translated text currently shown.

- **Output:** Create Copy (default) or Burn into Original, which replaces the source only after the new file is rendered and verified.
- **Style:** any installed font, size, top or bottom position and margin, optional background, and adjustable shadow, with a live preview. The style is remembered.
- Rendering uses AVFoundation, keeps the source resolution and orientation, and re-encodes as HEVC for HEVC sources or H.264 otherwise.

## Save original microphone audio

Before starting a new microphone transcription, turn on **Save Original Audio** and pick Storage Priority, Quality Priority, or Highest Quality (AAC or ALAC in M4A). Afterwards, play it back at 0.5×, 1×, or 2× and export it with the transcript under the same base filename. Editing or translating the transcript never changes the audio. This option is unavailable for file transcription, Mac audio, live captions, and transcription appended to an imported transcript.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘N | Microphone transcription |
| ⌘O | Transcribe from file |
| ⇧⌘O | Import transcript |
| ⇧⌘B | Burn subtitles |
| Return | Start transcription |
| Space | Pause / resume |
| ⌘E | Export transcript |

## Command line

```sh
LS=/Applications/LocalScribe.app/Contents/MacOS/LocalScribe

$LS --cli help
$LS --cli models --json
$LS --cli download whisper.largeV3TurboQ5
$LS --cli transcribe input.mp4 --engine whisper --language en_US \
  --translate-to zh-Hans --format srt --output output.srt
$LS --cli translate "Hello" --source en_US --target ja
$LS --cli translate "Hello" --source en_US --target ja --provider intelligence
$LS --cli prompts edit
$LS --cli burn --video input.mp4 --subtitles input.srt --output subtitled.mp4
```

| Command | Purpose |
| --- | --- |
| `models [--json]` | List models and installation state |
| `download <model-id>` / `remove <model-id>` | Install or uninstall a recognition model |
| `transcribe <file>` | Transcribe with Whisper, SenseVoice, or Parakeet; options include `--model`, `--compute auto\|coreml\|metal\|cpu`, `--translate-to`, `--translation-provider apple\|nllb\|intelligence`, and `--format txt\|md\|json\|pdf\|srt\|vtt` |
| `translate <text>` | Translate text with Apple Translation (macOS 26), NLLB, or Apple Intelligence (`--provider intelligence`, macOS 26) |
| `prompts [show\|edit\|reset]` | Show saved AI instructions (`--json`), open the editor window, or reset them (`proofread\|summary\|all`) |
| `burn` | Burn subtitles; supports `--in-place`, `--overwrite`, `--font`, `--size`, `--position`, `--margin`, `--background`, and shadow options |

## Privacy and updates

Recognition and translation run on the Mac. Recognition audio and text processed by Apple Intelligence or built-in Gemma are not uploaded. LM Studio receives text over loopback on the same Mac. OpenAI or DeepSeek receive task text, context, and instructions only after you select and confirm them. API keys are stored in the local, non-synchronizing Keychain.

Other network access is used for on-demand model downloads, update checks and downloads, and opening external documentation. Apple Speech, Apple Translation, and Apple Intelligence may need system-managed assets to be ready before use.

The updater checks at launch and every six hours, reads `update.json` from the latest GitHub Release, verifies the ZIP's SHA-256, bundle identifier, and version, and asks before replacing the app. Automatic update checks can be turned off in Settings.
