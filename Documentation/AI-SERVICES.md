# AI enhancement and custom services

[Simplified Chinese](AI-SERVICES.zh-CN.md)

LocalScribe offers on-device translation, proofreading, refinement, and summaries with Apple Intelligence on supported Macs, with Gemma 4 and optional NLLB as other local choices. For proofreading and summaries, you can also choose LM Studio on the same Mac or the official OpenAI and DeepSeek APIs. Custom AI services do not replace the local recognition, translation, or audio-export engines.

## AI transcript enhancement

After transcribing or importing a transcript, open **AI Enhancement** in the right inspector.

- **Proofread / Refine** corrects obvious recognition errors and cleans up punctuation, fragments, and filler sounds, shown as a live diff. Meaningful repetition and spoken wording are preserved in the Apple Intelligence cleanup pass. Segments that fail validation keep their original text. With Apple Intelligence, misheard words are corrected in a separate pass before cleanup, and the cleanup keeps every other word as spoken; add names, brands, and terms to the instructions box to help the model correct them.
- **Summarize** replaces the preview with a summary and keeps an undo snapshot.
- Add one-time instructions (up to 500 characters) for names, terminology, style, length, focus, or format. Saved instructions are edited with `--cli prompts edit`. Always review AI output.

**Apple Intelligence.** On supported Macs running macOS 26 or later with Apple Intelligence enabled and its system model ready, LocalScribe can use the built-in on-device model for translation, proofreading, and summaries. No separate app-managed AI model download is needed; macOS manages system model preparation. Apple Translation remains the default translation provider. Translation sends larger windows to the model and keeps a per-run glossary of names, terms, and style so later windows stay consistent; languages Apple Intelligence doesn't support, and segments it can't process, fall back to Apple Translation. Summaries of long transcripts are written incrementally, with each step seeing the summary so far. When you update from an earlier version with Gemma or NLLB installed, LocalScribe asks once whether to remove those models and switch; if you keep them, nothing changes and you can switch later in **Settings → Models**. NLLB can still be downloaded as an optional translator. On Macs without Apple Intelligence, Gemma and NLLB work as before.

**Built-in Gemma 4** (Macs without Apple Intelligence, or when you keep the previous models). The default E2B model is about 2.8 GB; an optional E4B model (about 4.6 GB) can be enabled in Settings. Models are downloaded on demand and load only when you select an AI task; LocalScribe first releases its recognition and NLLB runtimes. On Macs with 8 GB of memory or less, Gemma is off by default and can be enabled in Settings.

**Custom AI services.** In **Settings → Models → Use a custom AI service**, connect LM Studio (loopback address only, default `http://127.0.0.1:1234/v1`), OpenAI, or DeepSeek. Enabling it cancels and blocks Gemma downloads and loading, with no automatic fallback, and takes priority over Apple Intelligence for AI enhancement. OpenAI and DeepSeek connectors are previews and send task text only after your consent; API usage may incur charges. The setup steps are below.

## Availability and limits

- Apple Intelligence requires macOS 26 or later, a supported Mac, and the feature enabled with its system model ready. The macOS 26 path has not yet been tested on real hardware; development and live tests used macOS 27.
- The on-device model has a limited context window and may decline content. Translation falls back to Apple Translation for affected segments; proofreading failures keep the original text. If Apple Intelligence becomes unavailable, the app returns to the previous models with a restore hint.
- Local NLLB requires at least 4 GB of memory and its model downloaded. With Apple Intelligence active, NLLB remains optional and can replace it for translation in Settings.
- Cloud AI requires credentials and consent, and may incur provider charges. OpenAI and DeepSeek connectors remain preview features. Review translations, corrections, and summaries before use.

## Configure a custom service

1. Open Settings → Models and enable **Use a custom AI service**. The configuration sheet opens immediately. Closing the sheet leaves custom mode enabled, even if it is incomplete.
2. Select LM Studio, OpenAI, or DeepSeek. Cloud addresses are fixed to the official API. LM Studio accepts `localhost`, `127.0.0.1`, or `[::1]`, with a configurable port and optional `/v1` suffix; other hosts, credentials in URLs, and query strings are rejected.
3. Enter a key for cloud services, or an optional LM Studio token if its server requires authentication. Credentials stay in this Mac’s non-synchronizing Keychain. Leave a replacement field blank to preserve a saved credential; use the explicit delete control to remove it.
4. Fetch the model list, choose a model, or enter its ID. Model lists can include models that do not support text generation or require loading. LocalScribe constructs the request; no JSON template is needed.
5. Cloud generation requires consent to send task text and accept possible API charges. Fetching models does not send transcript text. The optional connection test sends only a fixed synthetic sentence and may incur a small charge.
6. Save. Saving without a key or model is allowed, but generation stays unavailable until the configuration is complete. Test results are cleared when the draft changes. Configure remains available while custom mode is enabled.

LM Studio must be running with an available text model. LocalScribe does not manage its process or download its models. External LAN servers and arbitrary cloud gateways are not supported in this version.

## Custom-service failure behavior

When custom mode is enabled, proofreading and summaries use the custom service even on Macs where Apple Intelligence is available; there is no automatic fallback to Apple Intelligence or Gemma.

Custom mode immediately cancels LocalScribe’s Gemma download and stops its owned Gemma helper. Further downloads, install commits, and helper starts are blocked. Installed models remain available for manual removal. Missing credentials, incomplete configuration, HTTP errors, and unavailable models never trigger a fallback or a model download. Disabling custom mode restores built-in eligibility but does not resume a cancelled download. Gemma’s low-memory opt-in does not restrict custom services.

One AI window owns the task at a time. Another window receives a busy message. Cancellation applies to the owning window; changing service configuration cancels obsolete work, and stale progress/results cannot overwrite a new task. Only LocalScribe-owned processes are terminated.

Custom services use the existing protected prompts, conservative batches, validation, live preview, undo, and recovery workflow. Proofreading checks IDs, count, nonempty text, length, numbers, links, email addresses, and time expressions. Invalid segments retain their original text. A malformed proofreading JSON response may be repaired once. Transport failures are not automatically retried. Summaries retain the existing grounding and length checks; AI output still needs human review.

## Protocol and privacy

The three providers use Chat Completions and model-discovery endpoints. OpenAI requests use `max_completion_tokens` and `store: false`, without unconditional model-specific sampling fields. DeepSeek requests use `max_tokens` and disable thinking for these tasks. LM Studio uses `max_tokens` and deterministic temperature. No llama.cpp-only fields are sent to external providers. Both SSE and JSON are supported. Tool calls, refusals, non-stop finish reasons, empty results, and incomplete streams are rejected. Redirects are not followed; arbitrary server error bodies are not shown.

Cloud tasks send only the required transcript text, nearby context, protected system instructions, and additional instructions to the selected provider. They do not upload original audio or video. `store: false` is an API option, not a promise about all provider retention policies. LM Studio receives the text locally; its other networking behavior is controlled by its own settings.

## Validation status

OpenAI and DeepSeek connectors are preview features pending production-key smoke tests. Automated tests use disposable credentials and local fixtures; they do not call cloud APIs. Coverage includes provider-specific requests, model discovery, Keychain round trips, address restrictions, redirects, rate/authentication failures, byte-fragmented UTF-8 SSE, incomplete responses, timeout, cancellation, Gemma download isolation, and optimization safety. These tests establish implementation behavior, not real model quality or account compatibility.

Before promoting a cloud connector to stable support, use a production key with synthetic short text to validate discovery, connection, proofreading, summarization, and cancellation. Also validate an actual LM Studio text model. Never include keys or private transcripts in test fixtures, issues, or reports.

Protocol references: [LM Studio](https://lmstudio.ai/docs/developer/openai-compat/chat-completions), [OpenAI](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create), [DeepSeek](https://api-docs.deepseek.com/api/create-chat-completion/).
