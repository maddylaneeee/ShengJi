# LocalScribe 1.7.1

## Custom AI services

- Connect transcript proofreading, refinement, and summarization to LM Studio on the same Mac, or to the official OpenAI and DeepSeek APIs.
- Open Settings → Models → **Use a custom AI service** to select a provider, fetch models or enter a model ID, and test the connection with synthetic text. Requests are constructed automatically; no JSON template is needed.
- Enabling custom mode cancels Gemma downloads and stops LocalScribe-owned Gemma helpers. All Gemma download, install, and loading paths remain blocked while the switch is on, even if configuration is incomplete or an API request fails. Installed models are retained for manual removal. Disabling the switch does not resume a cancelled download.
- Custom services work independently of Gemma’s low-memory opt-in. Protected prompts, conservative batching, output validation, live preview, undo, and recovery continue to apply.
- Credentials are stored only in this Mac’s non-synchronizing Keychain. Cloud services require explicit consent to send task text and accept possible API charges; original audio and video are not uploaded.
- Configuration explanations appear in hover help. Model discovery for OpenAI and DeepSeek requires an API key; missing credentials are explained beside the disabled button. LM Studio can discover models without a token unless its server requires authentication.
- Streamed and non-streamed responses are supported. Incomplete streams, tool calls, refusals, and truncated results are rejected. Redirects are blocked, errors are redacted, and failed generation requests are not automatically retried. Cancellation is scoped to the owning window.

## Validation scope

OpenAI and DeepSeek connectors are preview features. Request adapters, local protocol fixtures, Keychain storage, streaming, failure handling, cancellation, and Gemma isolation have automated coverage; production-key validation is pending. Local fixtures do not establish real API account permissions, model availability, billing, or generation quality. A real LM Studio text model and cloud credentials remain part of manual acceptance.

## Compatibility and installation

- Apple silicon (`arm64`), macOS 15.5 or later. Apple SpeechAnalyzer and floating live captions require macOS 26.
- The public package uses an ad-hoc integrity signature. It is not Developer ID signed or notarized by Apple. Follow the installation guide only if you trust this repository and release.
- Recognition, local translation, transcript editing/export, and original microphone audio workflows retain their existing behavior.
