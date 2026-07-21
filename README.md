# ShengJi · LocalScribe

**English** | [Chinese (Simplified)](README.zh-CN.md)

[![macOS 15.5+](https://img.shields.io/badge/macOS-15.5%2B-000000?logo=apple)](https://support.apple.com/macos)
[![Apple silicon](https://img.shields.io/badge/Apple%20silicon-arm64-555555)](https://support.apple.com/guide/mac-help/about-this-mac-mchl3a2c2cb0/mac)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![CI](https://github.com/maddylaneeee/ShengJi/actions/workflows/ci.yml/badge.svg)](https://github.com/maddylaneeee/ShengJi/actions/workflows/ci.yml)
[![Download for macOS](https://img.shields.io/badge/download-macOS%20DMG-0A84FF?logo=github)](https://github.com/maddylaneeee/ShengJi/releases/latest/download/ShengJi-macOS-arm64.dmg)

**Turn microphones, media files, and the sound playing on your Mac into editable text and subtitles—locally.**

LocalScribe can transcribe microphones, audio and video files, and audio playing on your Mac. It combines Apple Speech, whisper.cpp, SenseVoice, NVIDIA Parakeet, Apple Translation, and NLLB behind one native SwiftUI interface.

Current version: **1.4.0 (19)** · [Download DMG](https://github.com/maddylaneeee/ShengJi/releases/latest/download/ShengJi-macOS-arm64.dmg) · [Non-developer download guide](Documentation/DOWNLOAD.md) · [User documentation](https://lixinchen.ca/docs/localscribe/)

> [!IMPORTANT]
> **Apple SpeechAnalyzer recognition and floating live captions require macOS 26.** The app itself supports macOS 15.5 or later. On macOS 15.5–25, manually select Whisper, SenseVoice, or Parakeet on the home screen. SenseVoice and Parakeet currently support file transcription only.

## Download and install

1. [Download the latest DMG](https://github.com/maddylaneeee/ShengJi/releases/latest/download/ShengJi-macOS-arm64.dmg).
2. Open it and drag ShengJi to Applications.
3. The first launch will be blocked. After trying once, open System Settings → Privacy & Security, click Open Anyway, then confirm Open.

For illustrated steps, troubleshooting, and SHA-256 verification, see the [Download and Installation Guide](Documentation/DOWNLOAD.md).

> [!WARNING]
> This build has an ad-hoc integrity signature only. It is neither Developer ID signed nor notarized by Apple. Override the warning only if you trust this repository and its Release. SHA-256 files are included with every Release.

![ShengJi home screen in English with model selection, import, translation and live-caption controls](Documentation/Screenshots/home-en.png)

## Why LocalScribe?

- **Local by default.** Recognition and optional translation run on the Mac; input audio and imported transcripts are not uploaded by the app.
- **More than dictation.** Use microphone input, media files, Mac audio, floating live captions, transcript editing, recovery, and subtitle export in one workflow.
- **Multiple offline engines.** Choose Apple Speech, whisper.cpp with Metal, SenseVoice, or NVIDIA Parakeet instead of being locked to one model family.
- **Long-task workflow.** Progressive results, append-only recovery journals, bounded transcript rendering, pause/resume, and resumable sessions are designed for long recordings.
- **Editable deliverables.** Import, search, replace, trim, translate, and export TXT, Markdown, JSON, PDF, SRT, or WebVTT.
- **System-aware interface.** English and Simplified Chinese switch automatically with the Mac language preference, using an extensible localization structure.

## Transcript editing and translation

![ShengJi transcript editor in Simplified Chinese with local translation, search, range editing, export and privacy details](Documentation/Screenshots/transcript-editor-zh-CN.png)

The screenshots are from version 1.4.0 of the real macOS app and use an isolated profile with non-private test transcript content. ShengJi includes complete English and Simplified Chinese interfaces and follows the preferred macOS language order.

## Languages

ShengJi follows the preferred language order in macOS automatically. Version 1.4.0 includes complete English and Simplified Chinese interfaces, localized privacy descriptions, menus, model information, progress states, errors, and inspector values. Localization lives in standard language resource directories, so another language can be added without changing feature code.

## Recognition and translation engines

| Engine | Use | Runtime |
| --- | --- | --- |
| Apple Speech | Microphone, files, live captions | SpeechAnalyzer / SpeechTranscriber |
| Whisper | Microphone and files | whisper.cpp GGML, Metal with CPU fallback |
| SenseVoice | Files | sherpa-onnx, Core ML eligible path with CPU fallback |
| NVIDIA Parakeet | Files | sherpa-onnx, Core ML eligible path with CPU fallback |
| Apple Translation | Default post-transcription translation | macOS Translation framework |
| NLLB | Optional post-transcription translation | CTranslate2 CPU/int8 |

Whisper file transcription uses the model's internal sliding windows rather than fixed, non-overlapping application chunks. For longer media, the bundled Silero VAD can skip silence while retaining speech padding and overlap. Output filtering considers silence, confidence, repetition, and known hallucination patterns.

## Highlights

- Apple Speech live captions for microphone, Mac audio, or mixed input on macOS 26.
- whisper.cpp Metal inference with bundled Silero VAD and automatic CPU fallback.
- Downloadable Whisper, SenseVoice, and Parakeet model choices.
- Adaptive progressive text display for file and microphone transcription.
- Editable transcripts with search, replacement, selection deletion, and range trimming.
- SRT, WebVTT, TXT, Markdown, and LocalScribe JSON import.
- TXT, Markdown, JSON, PDF, SRT, WebVTT, and clipboard export.
- Apple Translation by default, with optional local NLLB INT8 translation.
- Append-only session journals and recovery snapshots for long-running work.
- A command-line interface for models, transcription, export, and translation.

## Requirements and current limitations

- macOS 15.5 or later.
- Apple silicon (`arm64`); Intel Macs are not supported.
- Apple SpeechAnalyzer recognition and live captions require macOS 26.
- On macOS 15.5–25, select Whisper, SenseVoice, or Parakeet manually. SenseVoice and Parakeet currently support file transcription only.
- Live-caption translation is currently disabled; post-transcription translation remains available.
- Public Developer ID signing and Apple notarization are still pending.

Microphone input requires microphone permission. Capturing Mac audio requires Screen & System Audio Recording permission. Apple Speech and Apple Translation may download language assets managed by macOS.

## Build from source

Install Xcode and its Command Line Tools. The repository includes the native runtimes required by the app; large recognition and NLLB models are downloaded only when selected.

```sh
ruby generate_project.rb

xcodebuild \
  -project LocalScribe.xcodeproj \
  -scheme LocalScribe \
  -destination 'platform=macOS,arch=arm64' \
  build
```

Run the test suite:

```sh
xcodebuild \
  -project LocalScribe.xcodeproj \
  -scheme LocalScribe \
  -destination 'platform=macOS,arch=arm64' \
  test
```

CI runs the tests and Release static analysis on GitHub's macOS 26 Apple silicon runner.

The local packaging script creates ZIP and DMG artifacts and validates nested signatures, architectures, deployment targets, embedded Mach-O files, archive extraction, DMG mounting, and helper startup:

```sh
./tools/package_local_release.sh
```

By default it uses the configured local certificate. Set `CODESIGN_IDENTITY=-` to make the same ad-hoc package produced by GitHub Actions. Pushing a tag that matches the version in `Info.plist` (for example, `v1.4.0`) runs `release-unsigned.yml`, verifies the package, and creates the GitHub Release without storing a certificate or password in GitHub Secrets. Developer ID signing, timestamping, notarization, and stapling remain the preferred public distribution path.

## CLI

```sh
ShengJi.app/Contents/MacOS/LocalScribe --cli help
ShengJi.app/Contents/MacOS/LocalScribe --cli models --json
ShengJi.app/Contents/MacOS/LocalScribe --cli transcribe input.mp4 \
  --engine whisper --language en_US --format srt --output output.srt
```

## Privacy and updates

LocalScribe does not upload recognition audio or imported transcripts. Network access is used for user-initiated model downloads, update checks, and opening external documentation.

The built-in updater reads `update.json` from the latest GitHub Release, downloads its ZIP, verifies SHA-256, checks the bundle identifier and version, and asks before replacing the app. This update path is not a substitute for a notarized public release.

## Documentation

- [User documentation](https://lixinchen.ca/docs/localscribe/)
- [Download and Installation Guide](Documentation/DOWNLOAD.md)
- [Acceptance and regression notes](https://lixinchen.ca/docs/localscribe/acceptance.html)
- [SherpaOnnx build notes](https://lixinchen.ca/docs/localscribe/sherpa-onnx.html)
- [Report an issue](https://github.com/maddylaneeee/ShengJi/issues)
- [Media and recommendation kit](Documentation/MediaKit/README.md)

## License

LocalScribe source code is available under the [MIT License](LICENSE). Third-party components and models retain their original licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and the license files under `Vendor`.

The optional NLLB model is distributed upstream under CC-BY-NC-4.0.
