# LocalScribe 1.7.2

## Long transcript fixes

- Line numbers show as plain numbers (`1215`, not `1,215`) on a single line. The number column widens for transcripts above 999 lines instead of wrapping, and line numbers stay aligned with the text.
- Scrolling a finished transcript with thousands of lines is smooth. The editor no longer rescans the whole document for every visible line number, and the live preview builds only visible lines while transcription is running.
- Apple Speech file transcription now reports progress by recognized audio time instead of by how much audio has been read. Progress stays below 100% until recognition finishes, and the status line shows read and recognized percentages separately.
- While the remaining text is being finalized, or while a model or audio is being prepared, the bottom control bar shows a spinner and status instead of an empty capsule.

## Export file names

- Microphone transcripts default to the moment transcription started, for example `2026-11-17_01-49-05_Transcription.srt`. The name stays the same across repeated exports.
- File transcripts default to the original file name, for example `Interview_Transcription.srt`.
- Recovered sessions follow the same rules as their original source.

## Compatibility and installation

- Apple silicon (`arm64`), macOS 15.5 or later. Apple SpeechAnalyzer and floating live captions require macOS 26.
- The public package uses an ad-hoc integrity signature. It is not Developer ID signed or notarized by Apple. Follow the installation guide only if you trust this repository and release.
- Recognition engines, translation, AI enhancement, recovery, and original microphone audio workflows retain their existing behavior.
