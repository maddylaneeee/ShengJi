# Third-Party Notices

LocalScribe includes or optionally uses the third-party components below. Their license files are retained in the source tree or application bundle. This summary does not replace the full upstream license terms.

| Component | Purpose | License / upstream project |
| --- | --- | --- |
| whisper.cpp / GGML | Whisper inference, Metal acceleration, and the VAD interface | MIT · <https://github.com/ggerganov/whisper.cpp> |
| llama.cpp / GGML | Built-in Gemma inference and Metal acceleration; runtime notice in `Vendor/GemmaRuntime/LICENSE` | MIT · <https://github.com/ggml-org/llama.cpp> |
| Gemma 4 E2B IT / E4B IT (GGUF) | Optional AI enhancement models downloaded on demand, not distributed in this Git repository | Apache-2.0 · [E2B model card](https://huggingface.co/ggml-org/gemma-4-E2B-it-GGUF/blob/b4243c156154b6dca9324415f8c7ccc098b4aed1/README.md) · [E4B model card](https://huggingface.co/ggml-org/gemma-4-E4B-it-GGUF/blob/b8093469224f83f5c38f691eb906c380e9e63114/README.md) |
| Silero VAD v6.2.0 | Voice activity detection for long audio | MIT · <https://github.com/snakers4/silero-vad> |
| sherpa-onnx | SenseVoice and Parakeet inference | Apache-2.0 · <https://github.com/k2-fsa/sherpa-onnx> |
| ONNX Runtime | Runtime used by sherpa-onnx | MIT · <https://github.com/microsoft/onnxruntime> |
| CTranslate2 | NLLB inference | MIT · <https://github.com/OpenNMT/CTranslate2> |
| SentencePiece | NLLB tokenization | Apache-2.0 · <https://github.com/google/sentencepiece> |
| nllb-200-distilled-600M-ct2-int8 | Optional translation model, not distributed in this Git repository | CC-BY-NC-4.0 · <https://huggingface.co/osa911/nllb-200-distilled-600M-ct2-int8> |

Apple Speech, Translation, Foundation Models, NaturalLanguage, AVFoundation, ScreenCaptureKit, SwiftUI, and other Apple SDK frameworks are governed by Apple's platform SDK terms and are outside the scope of this project's MIT license.
