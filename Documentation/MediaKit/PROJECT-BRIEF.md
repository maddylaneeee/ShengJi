# LocalScribe Project Brief

**English** | [Chinese (Simplified)](PROJECT-BRIEF.zh-CN.md)

## One sentence

LocalScribe is a free, open-source macOS app for local transcription, live captions, and subtitle editing and burning, with on-device Apple Intelligence for translation and transcript enhancement on supported Macs.

## Short description

LocalScribe turns microphones, media files, and the sound playing on a Mac into editable text and subtitles. Its native SwiftUI interface brings together recognition, transcript editing, translation, subtitle burning, and recovery for long tasks. On supported Macs, Apple Intelligence translates, proofreads, and summarizes on device; Gemma 4, optional NLLB, and custom AI services provide other choices.

## Highlights

- Microphone, audio/video file, and Mac-audio transcription;
- floating local captions for microphone, Mac audio, or both mixed;
- Apple Speech, Whisper, SenseVoice, and NVIDIA Parakeet recognition;
- transcript import, search, replacement, range trimming, and multi-format export;
- on-device Apple Intelligence translation, proofreading, and summaries;
- Apple Translation by default, optional NLLB translation, and Gemma 4 AI enhancement;
- custom LM Studio, OpenAI, or DeepSeek services for proofreading and summaries;
- subtitle burning with font, position, background, shadow, and live preview;
- optional original microphone audio, recovery, in-app updates, and CLI workflows;
- English, Simplified Chinese, and Japanese interfaces;
- MIT-licensed application source; third-party components and models retain their own licenses.

## Requirements and limits

- Apple silicon (`arm64`), macOS 15.5 or later; Intel Macs are not supported;
- Apple Speech recognition and floating live captions require macOS 26 or later;
- on macOS 15.5–25, select and download a third-party recognition model;
- SenseVoice and Parakeet support file transcription only; live-caption translation is disabled;
- Apple Intelligence requires macOS 26 or later, a supported Mac, and its system model enabled and ready; its macOS 26 path is not yet verified on real hardware;
- Gemma is off by default on Macs with 8 GB of memory or less; NLLB requires at least 4 GB;
- OpenAI and DeepSeek connectors are preview features and may incur API charges;
- the public package has an ad-hoc integrity signature, without Developer ID signing or Apple notarization.

## Privacy

Recognition runs on the Mac and does not upload original audio or video. Translation and built-in AI also run locally. LM Studio receives text over loopback on the same Mac. Only when the user chooses a cloud AI service and consents does LocalScribe send task text, context, and instructions to that provider. API keys are stored in this Mac's non-synchronizing Keychain.

## Links

- [GitHub](https://github.com/maddylaneeee/ShengJi)
- [Latest release and downloads](https://github.com/maddylaneeee/ShengJi/releases/latest)
- [Installation guide](../../INSTALL.md)
- [User guide](../USAGE.md) · [AI enhancement and services](../AI-SERVICES.md)
- [Website](https://lixinchen.ca/docs/localscribe/)
