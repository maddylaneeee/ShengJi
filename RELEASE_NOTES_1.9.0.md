# LocalScribe 1.9.0

## Apple Intelligence

- On Macs running macOS 26 or later with Apple Intelligence turned on, translation, proofreading, refinement, and summaries now use the built-in on-device Apple Intelligence model. No model download is needed, and the interface and live streaming output work as before.
- If you update with Gemma or NLLB models installed, LocalScribe asks once whether to remove them and switch to Apple Intelligence. If you keep them, everything works as before, and you can switch later from Settings > Models. Macs without Apple Intelligence keep using Gemma and NLLB.
- If Apple Intelligence is later turned off or becomes unavailable, LocalScribe returns to the previous models and shows how to restore it.
- A custom AI service (LM Studio, OpenAI, or DeepSeek) still takes priority for proofreading and summaries.

## Translation

- In Apple Intelligence mode, the second translation service is "Apple Intelligence". NLLB can still be downloaded as an optional offline translator and can replace Apple Intelligence for translation with a setting.
- Translation sends larger windows of text to the model at once. Within each translation run, LocalScribe keeps a short glossary of names, terms, and style so later windows translate them consistently.
- Languages Apple Intelligence doesn't support, and segments it declines or can't process, fall back to Apple Translation with a notice.
- The command line accepts `--provider intelligence` (aliases `afm`, `apple-intelligence`) for `translate` and `--translation-provider intelligence` for `transcribe`. The default provider is still Apple Translation.

## AI enhancement

- Summaries of long transcripts are written incrementally: each step sees the summary written so far, and a final pass merges it into one summary. On Macs with 9 GB of memory or less, each summary step uses at most about 4,000 tokens of context; on macOS 26, at most about 3,000.
- Proofreading joins short recognition fragments into complete sentences and drops filler-only fragments such as "um, uh". Each cleaned sentence is matched back to the original fragments it came from, and its time range covers them, so the change preview always shows exactly what will be applied. Edits that cannot be traced back to the original text are discarded and that text is kept. In the live change preview, the removed fragments appear directly above the sentence they were merged into.
- After an AI change is applied, **Undo AI Changes** now sits in the AI Enhancement section of the right sidebar.
- Apple Intelligence translation progress shows the real number of context windows (parts) it sends to the model, together with how many segments have been translated so far.
- Prompt editing has moved out of Settings. Use `LocalScribe --cli prompts edit` to open the editor window, `prompts show [--json]` to view saved instructions, and `prompts reset [proofread|summary|all]` to restore defaults. Saved and one-time instructions are now limited to 500 characters each; longer saved instructions are shortened once with a notice.

## Known limitations

- The on-device model has a limited context window and may decline some content. Affected translation segments fall back to Apple Translation; proofreading segments keep their original text.
- Like other AI output, translations and summaries can contain mistakes, for example in currency names. Review important content.
- The Apple Intelligence path was developed and tested on macOS 27. It has not yet been tested on real hardware running macOS 26.

## Compatibility and installation

- Apple silicon (`arm64`), macOS 15.5 or later. Apple Intelligence features require macOS 26 or later; Apple SpeechAnalyzer and floating live captions require macOS 26.
- The public package uses an ad-hoc integrity signature. It is not Developer ID signed or notarized by Apple. Follow the installation guide only if you trust this repository and release.
