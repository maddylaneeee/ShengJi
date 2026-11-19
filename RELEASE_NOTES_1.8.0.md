# LocalScribe 1.8.0

## Burn subtitles into video

- The home screen's former "Translate after transcription" card is now **Burn Subtitles**. It is also available from **File → Burn Subtitles…** (⇧⌘B). Choose a video and a subtitle file, or drag each file onto its row.
- Supported subtitle formats: SRT, WebVTT, LocalScribe JSON with segments, ASS/SSA, SBV, and TTML/DFXP. The format is detected from the file contents, so a wrong extension still works.
- Files are checked before burning. A file without timestamps, with a malformed or reversed timestamp, or in another format is marked **Not supported**, with the line number where possible. Cues past the end of the video or overlapping cues are allowed with a warning. ASS styling and TTML regions are ignored.
- After a video transcription finishes, **Burn into Video** next to **Export Transcript** opens the burn page with the source video and the text currently shown—original or translation—filled in and locked, labeled with which one is used. **Back to Preview** returns to the result page. Edited transcripts use an approximate timeline and show a warning.

## Output and style

- **Create Copy** is the default and opens a save dialog next to the original (`<name>-subtitled.<ext>`). **Burn into Original** asks for confirmation and replaces the original only after the new video has been rendered and verified. This choice is never remembered.
- The page puts files, output, and **Subtitle Style** on the left and a large live preview on the right, so everything fits without scrolling at the default window size. Style options: any installed font, size, top or bottom position with margin, an optional background, and a soft layered shadow that can be switched off or adjusted in color (presets or a custom color) and width. The style, including the font, is remembered and can be reset to defaults.
- Rendering uses AVFoundation on this Mac and keeps the source resolution and orientation. Burned subtitles require re-encoding: HEVC sources stay HEVC; other sources are written as H.264. Containers macOS cannot read, such as MKV or WebM, are reported as unsupported.

## Command line

- New `burn` command: `LocalScribe --cli burn --video <path> --subtitles <path> [--output <path> | --in-place] [--overwrite]`, with optional `--font`, `--size`, `--position`, `--margin`, `--background`, `--shadow on|off`, `--shadow-color`, and `--shadow-width`. Style flags apply to that run only and start from the style saved in the app.

## Compatibility and installation

- Apple silicon (`arm64`), macOS 15.5 or later. Apple SpeechAnalyzer and floating live captions require macOS 26.
- The public package uses an ad-hoc integrity signature. It is not Developer ID signed or notarized by Apple. Follow the installation guide only if you trust this repository and release.
- Recognition, translation, AI enhancement, recovery, and original microphone audio workflows retain their existing behavior. Translation after transcription remains available on the result page.
