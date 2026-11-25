# LocalScribe 1.8.1

## Fixes

- Recognition language names now follow the app language set in Settings instead of the macOS system language. This applies to the result page inspector, the language line in Markdown and PDF exports, "language not supported" messages for transcription and live captions, and command-line output.

## Interface

- The result page inspector no longer shows a Privacy section, and the AI section no longer repeats the privacy note. The pre-recording info popover is now titled "About Recognition", and the on-device note below Live Captions on the home screen has been removed. Privacy information remains available in Settings.
- Settings is less crowded: explanations that used to appear under each option now appear when you hover over the option. Standalone notes, such as privacy, file locations, and AI usage, are collected in an info icon at the bottom of each tab, which opens after a brief hover. Status messages and warnings are still shown directly, and the About tab is unchanged.
- The Edit Prompts button in Settings > Models now shows its icon and is no longer offset.

## Compatibility and installation

- Apple silicon (`arm64`), macOS 15.5 or later. Apple SpeechAnalyzer and floating live captions require macOS 26.
- The public package uses an ad-hoc integrity signature. It is not Developer ID signed or notarized by Apple. Follow the installation guide only if you trust this repository and release.
