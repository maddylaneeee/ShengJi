## About LocalScribe

LocalScribe 1.7.0 build 40 adds optional original-audio recording for new microphone transcriptions and fixes language switching in the menu bar, AI prompt editor, and transcript export dialog.

- **Save original microphone audio.** Enable Save Original Audio before starting a new microphone task. Choose Storage Priority, Quality Priority, or Highest Quality. Recordings are saved locally as M4A; silence is retained and pause gaps are omitted.
- **Play and export recordings.** Play, pause, seek, and listen at 0.5×, 1×, or 2×. Export the original M4A alongside TXT, Markdown, JSON, PDF, SRT, or WebVTT using the same base filename. Editing or translating the transcript does not change the recording.
- **Recover audio with the transcript.** The latest recoverable task keeps its original recording. Audio-saving failures do not stop recognition, and recoverable partial recordings are clearly labeled.
- **Switch languages without restarting.** Menu titles follow the selected app language. The AI prompt editor and transcript export dialog also use that language for their titles, explanations, controls, and buttons.
- **Speech synthesis is disabled.** Speech-generation controls and settings are unavailable in this release. Existing speech-generation recovery records open as editable text.

Original-audio saving is available only for new microphone transcriptions. It is not available for media-file transcription, Mac system audio, floating captions, or microphone transcription appended to an imported transcript. It is off by default for each new task.

Requires an Apple silicon Mac running macOS 15.5 or later. Apple SpeechAnalyzer and floating live captions require macOS 26 or later.

## Installation

Download `LocalScribe-macOS-arm64.dmg`, open it, and drag the app to Applications.

> This build is not Developer ID signed or notarized by Apple. After the first blocked launch, open System Settings → Privacy & Security, click Open Anyway, and then confirm Open. Continue only if you trust this repository.
