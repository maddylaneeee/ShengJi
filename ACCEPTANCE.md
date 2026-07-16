# ShengJi Acceptance Record

This document summarizes the public acceptance and regression history in English. The complete earlier record is preserved in [Chinese (Simplified)](ACCEPTANCE.zh-CN.md).

## 1.4.0 (19): English interface and public distribution

- The complete interface is available in English and Simplified Chinese and follows the preferred macOS language order automatically.
- Localization uses standard language resource directories so additional languages can be added without changing feature code.
- Privacy descriptions, menus, model details, progress states, errors, inspector values, and update views are localized.
- The public GitHub workflow builds an Apple silicon DMG and ZIP with an ad hoc signature, verifies both packages, and publishes checksums and an update manifest.
- The unsigned installation path is documented clearly: open the DMG, drag ShengJi to Applications, attempt the first launch, and use System Settings > Privacy & Security > Open Anyway.
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
- SRT, WebVTT, TXT, Markdown, and ShengJi JSON imports are supported.
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

- `ShengJi-macOS-arm64.dmg`
- `ShengJi-macOS-arm64.dmg.sha256`
- `ShengJi-macOS-arm64.zip`
- `ShengJi-macOS-arm64.zip.sha256`
- `update.json`

The current file sizes and SHA-256 values are authoritative in the matching GitHub Release assets and update manifest.
