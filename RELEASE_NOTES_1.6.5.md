# ShengJi 1.6.5

ShengJi 1.6.5 improves long transcription workflows and adds one-source-at-a-time selection to ordinary realtime transcription.

## What's new

- Choose Mac System Audio, the system-default microphone, or a specific available input device for ordinary realtime transcription.
- Keep the selected source locked for the active session, with clear permission, disconnect, and retry states.
- Release file-recognition models, tasks, converters, and file resources before editing and export.
- Catch up large transcript updates without leaving a long character-by-character animation tail.
- Respect Reduce Motion for ordinary transcription text updates.

The existing floating live-caption source modes are unchanged. SenseVoice and NVIDIA Parakeet remain file-only engines; Apple SpeechAnalyzer recognition requires macOS 26, while Whisper realtime transcription remains available on macOS 15.5 or later.

## Privacy

Microphone and Mac system audio are processed locally. ShengJi does not save raw realtime audio or screen images, and does not upload audio, transcripts, device names, or device identifiers. Mac System Audio capture excludes ShengJi's own process audio.

## Installation notice

This release has an ad-hoc integrity signature only. It is not Developer ID signed or notarized by Apple, so Gatekeeper will block the first launch. Follow the repository's Download and Installation Guide and use Open Anyway only if you trust this repository and its GitHub Release. SHA-256 checksum files are provided for release assets.
