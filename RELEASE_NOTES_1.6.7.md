# LocalScribe 1.6.7

## Build 39

- Wrap and divide long subtitle cues, including unspaced CJK text, without dropping characters.
- Do not create an empty timed cue for blank transcript text.
- Preserve the original start and end timestamps when a long cue is divided; timestamps within that cue are estimated from text length.

The full macOS Xcode test suite passed, including five new subtitle and JSON regression cases. A fixed-font rendering check sampled seven frames across the two cues of a CJK fixture and after the final cue; the expected frames contained visible text and the final frame was blank.

## Build 38

- Load Gemma only after selecting an AI feature; completing a transcription no longer preloads the model.
- Disable Gemma by default on Macs with 8 GB or less. Enable it in Settings after confirming the memory-pressure warning. E4B remains an optional model.
- Block local NLLB model downloads and execution below approximately 4 GB of memory, allowing a 128 MiB capacity tolerance. Apple Translation remains available.
- Add a contrasting title bar for light and dark appearances.
- Add [first-launch installation instructions](INSTALL.md) for macOS 26 and 27, with a [Simplified Chinese edition](INSTALL.zh-CN.md).

### Build 38 validation

The full local suite ran 110 tests: 108 passed, 2 installed-model Gemma tests skipped because Gemma was disabled, and no failures. Light and dark interfaces, model settings, and the low-memory confirmation were checked locally. The product diff underwent a source-based security review.

## Installation

Public packages use ad-hoc signing and are not Developer ID signed or notarized by Apple. After a blocked first launch, approve the app in System Settings > Privacy & Security only if you trust this repository and download. See the installation guide for detailed steps.
