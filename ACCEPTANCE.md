# LocalScribe Acceptance Record

This document summarizes the public acceptance and regression history in English. The complete earlier record is preserved in [Chinese (Simplified)](ACCEPTANCE.zh-CN.md).

## 1.9.0 (45): Apple Intelligence

- With Apple Intelligence available, translation, proofreading, refinement, and summaries use the on-device model; the interface and streaming previews are unchanged. Live tests on macOS 27 translated ten English lecture segments into Chinese in about 11 seconds across several windows, with names kept consistent through the per-run glossary.
- Updating with Gemma or NLLB installed asks once per version; Remove deletes the managed model files and caches and switches, Keep leaves the previous models and workflow in place. Unsupported, disabled, or not-ready Apple Intelligence keeps the previous behavior, and a later loss of availability returns to it with a restore hint.
- Settings shows only the active engine's options; prompt editing is removed from Settings and available through `--cli prompts edit`, `show`, and `reset`. Saved and one-time instructions are limited to 500 characters.
- Unsupported languages, declined content, and repeated failures fall back to Apple Translation with a notice; proofreading failures keep the original text. Rolling summaries see the summary written so far and are validated for grounded numbers before use; each step is capped at about 4,000 tokens of context on Macs with 9 GB of memory or less, and about 3,000 on macOS 26.
- Proofreading aligns each cleaned sentence to the original fragments it came from, so the change preview matches the applied result. Live tests on macOS 27 joined 35 English fragments into 11 sentences and 11 Chinese fragments into 4, keeping every number and name and reporting no failures. Shifted, reordered, or invented lines keep the original text.
- The macOS 26 Apple Intelligence path is not yet verified on real hardware.

## 1.8.1 (44): language names and quieter settings

- With the macOS system language and the app language set differently, the inspector's recognition language, the Markdown and PDF export language line, unsupported-language errors, live-caption errors, and CLI output use the app language.
- The result page inspector, the pre-recording info popover, and the home screen no longer show privacy notes; Settings keeps them.
- Settings option explanations appear as hover tooltips, and standalone notes are collected in an info icon at the bottom of the General, Permissions, Models, and Updates tabs. Status and warning messages remain visible, and the About tab is unchanged.

## 1.8.0 (43): subtitle burning

- The home screen's Burn Subtitles card, File → Burn Subtitles… (⇧⌘B), and the result page's Burn into Video button open the same burn page; the result-page entry locks the source video and the currently shown original or translation, and Back to Preview returns to the result.
- SRT, WebVTT, LocalScribe JSON, ASS/SSA, SBV, and TTML/DFXP are detected from file contents. Files without timestamps, with malformed or reversed timestamps, or in other formats are rejected with a line number where possible; cues beyond the video or overlapping cues produce warnings.
- Create Copy is the default. Burn into Original requires confirmation and replaces the source only after the rendered file is verified. Font, size, position, margin, background, and shadow (on/off, color, width) are remembered and can be reset.
- The `burn` CLI command supports the same output modes and per-run style overrides, including `--shadow on|off`.
- Automated coverage includes parsing 20,000 cues in each of four formats, active-cue lookup across three hours at 30 fps, a bounded rendering cache, and a 240-second video with more than 1,200 cues. A 30-minute 1080p30 render with 12,001 cues completed with correct frames and timing and a peak memory of about 167 MB.

## 1.6.0 (23): adaptive interface, accessibility, and app settings

- Primary actions use native Liquid Glass on macOS 26 with a system-material fallback on macOS 15.5–25; secondary controls no longer receive a custom blue hover treatment.
- The home model controls remain on one row at normal window widths, and the four main content areas reflow without clipping in English or Chinese.
- Settings can switch the app immediately between System, English, and Simplified Chinese, and between System, Light, and Dark appearances.
- A dedicated Permissions tab shows microphone, speech-recognition, and screen/system-audio status without prompting until the user requests access.
- Keyboard commands, focus presentation, VoiceOver labels, and reduced-transparency behavior cover the main transcription workflows.
- Developer-oriented update and backend details are removed from default views or placed behind advanced disclosure while user-relevant model size, license, and troubleshooting information remains available.
- Live-caption input choices and the macOS menu bar follow in-app language changes immediately; recognition-language menus recommend English and the device language without duplicates.
- Automatic update checks and verified downloads run at launch and every six hours by default, can be disabled persistently, and still require confirmation before installation and relaunch.

## 1.4.0 (19): English interface and public distribution

- The complete interface is available in English and Simplified Chinese and follows the preferred macOS language order automatically.
- Localization uses standard language resource directories so additional languages can be added without changing feature code.
- Privacy descriptions, menus, model details, progress states, errors, inspector values, and update views are localized.
- The public GitHub workflow builds an Apple silicon DMG and ZIP with an ad hoc signature, verifies both packages, and publishes checksums and an update manifest.
- The unsigned installation path is documented clearly: open the DMG, drag LocalScribe to Applications, attempt the first launch, and use System Settings > Privacy & Security > Open Anyway.
- The release is intentionally not Developer ID signed or notarized. Gatekeeper warnings are expected, and users are instructed to continue only when they trust the repository.
- The packaged NLLB helper includes its required Python base library, and release smoke-test failures are surfaced by the packaging workflow.

## 1.3.6 (18): completed live-caption segment retention

- Final Apple Speech segments remain in the sliding context for about two seconds.
- Punctuation and final-result boundaries no longer clear the floating caption immediately.
- New model output joins the retained context immediately, while display updates remain limited to about 15 Hz.

## 1.3.5 (17): continuous sliding captions and public repository

- Live captions no longer force short phrases at punctuation or artificial timeout boundaries.
- Text advances in reading order and the visible window follows the latest output.
- The display advances by a bounded number of characters per update to reduce motion blur on 60 Hz displays.
- When Reduce Motion is enabled, the current complete result is displayed without sliding animation.
- Public documentation, licensing, third-party notices, issue templates, and repository metadata were prepared for GitHub publication.

## 1.3.4 (16): transcript tools and subtitle import

- The transcript editor supports native selection, keyboard editing, undo, search, replacement, selection deletion, and node-range trimming.
- SRT, WebVTT, TXT, Markdown, and LocalScribe JSON imports are supported.
- Imported content can open directly in the completed editor or be retained while a new microphone session appends additional text.
- Automated coverage includes subtitle parsing, timestamp retention, search and replacement, and range deletion.

## 1.3.3 (15): progressive display and microphone accuracy

- File and microphone results use adaptive progressive text display, then complete immediately when processing finishes.
- Whisper microphone segmentation waits for natural pauses after a minimum duration and uses a bounded fallback duration for continuous speech.
- Microphone-only filtering suppresses known promotional phrases, isolated generic closings, and adjacent exact duplicates without changing file-transcription filtering.
- Apple live captions use SpeechAnalyzer directly and allow final results to finish naturally during shutdown.

## 1.3.2 (14): Whisper progress and trailing-silence filtering

- whisper.cpp segment callbacks expose intermediate text during long-file transcription.
- Progress messaging distinguishes model loading, media preparation, inference, and final filtering instead of showing an unreliable fixed percentage.
- Generic closing phrases are removed only when they occur in a short trailing segment whose matching audio interval has no speech energy.
- Real long-file GUI regression testing confirmed that text appears before inference completes.

## 1.3.1 (13): Whisper VAD and complete-file input

- Complete 16 kHz mono PCM input is passed to whisper.cpp, which advances its own internal windows.
- The bundled Silero VAD is enabled adaptively for longer media and retains speech padding and overlap.
- Audio conversion uses high-quality sample-rate conversion and sanitizes non-finite samples, DC offset, and clipping.
- Hallucination filtering combines no-speech probability, token confidence, mechanical repetition, and adjacent duplicate detection.

## 1.3.0 (12): model, results, and settings improvements

- New installations default to Apple Speech; third-party engines are enabled only after explicit selection and the last selection is restored.
- Transcription preparation uses a consistent default-versus-third-party model hierarchy.
- Automatic and manual post-transcription translation switch to the translated result when generation completes.
- Completed file and microphone sessions can restart while either saving or discarding the current text.
- Clipboard export, launch-at-login, Finder reveal, uninstall, privacy information, and GitHub links are available from the appropriate views.
- Compute-backend controls were removed from the interface: Apple manages its frameworks, Sherpa engines try Core ML and fall back to CPU, and Whisper tries Metal and falls back to CPU.

## 1.2.x: platform and regression baseline

- The deployment target is macOS 15.5 on Apple silicon. SpeechAnalyzer-specific features are isolated behind macOS 26 availability checks.
- Translation preserves stable segment identifiers, timestamps, and line correspondence, with explicit fallback markers for missing or mismatched results.
- Active transcripts use bounded rendering, pause automatic following when the user scrolls upward, and provide a return-to-latest action.
- Final segments, translations, and events are appended to a session journal; recovery snapshot version 2 remains compatible with version 1.
- Whisper uses whisper.cpp directly with Metal-to-CPU fallback. SenseVoice and Parakeet use sherpa-onnx, and NLLB uses an isolated CTranslate2 CPU/int8 runtime.
- Long-video regression testing verified complete result collection, bounded interface updates, serialized recovery writes, and timestamps extending to the end of the input.
- NLLB model downloads are pinned, size-checked, hash-checked, cancellable, and cleaned up when incomplete.
- Debug, Release, Analyze, unit tests, nested-signature checks, extraction checks, helper startup, and representative audio/video transcription form the release gate.

## Permissions and limitations

- Microphone live captions require microphone permission.
- Mac-audio live captions require Screen & System Audio Recording permission.
- Apple Speech and Apple Translation may download language assets managed by macOS.
- Live-caption translation is currently disabled; post-transcription translation remains available.
- Intel Macs are not currently supported.

## Release artifacts

Each public release may include:

- `LocalScribe-macOS-arm64.dmg`
- `LocalScribe-macOS-arm64.dmg.sha256`
- `LocalScribe-macOS-arm64.zip`
- `LocalScribe-macOS-arm64.zip.sha256`
- `update.json`

The current file sizes and SHA-256 values are authoritative in the matching GitHub Release assets and update manifest.
