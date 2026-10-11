# Custom AI services

[Simplified Chinese](AI-SERVICES.zh-CN.md)

LocalScribe 1.7.1 can use built-in Gemma, LM Studio on the same Mac, or the official OpenAI and DeepSeek APIs for transcript proofreading, refinement, and summarization. Recognition, translation, and audio export continue using their existing local engines.

## Configure a service

1. Open Settings → Models and enable **Use a custom AI service**. The configuration sheet opens immediately. Closing the sheet leaves custom mode enabled, even if it is incomplete.
2. Select LM Studio, OpenAI, or DeepSeek. Cloud addresses are fixed to the official API. LM Studio accepts `localhost`, `127.0.0.1`, or `[::1]`, with a configurable port and optional `/v1` suffix; other hosts, credentials in URLs, and query strings are rejected.
3. Enter a key for cloud services, or an optional LM Studio token if its server requires authentication. Credentials stay in this Mac’s non-synchronizing Keychain. Leave a replacement field blank to preserve a saved credential; use the explicit delete control to remove it.
4. Fetch the model list, choose a model, or enter its ID. Model lists can include models that do not support text generation or require loading. LocalScribe constructs the request; no JSON template is needed.
5. Cloud generation requires consent to send task text and accept possible API charges. Fetching models does not send transcript text. The optional connection test sends only a fixed synthetic sentence and may incur a small charge.
6. Save. Saving without a key or model is allowed, but generation stays unavailable until the configuration is complete. Test results are cleared when the draft changes. Configure remains available while custom mode is enabled.

LM Studio must be running with an available text model. LocalScribe does not manage its process or download its models. External LAN servers and arbitrary cloud gateways are not supported in this version.

## Gemma and failure behavior

Custom mode immediately cancels LocalScribe’s Gemma download and stops its owned Gemma helper. Further downloads, install commits, and helper starts are blocked. Installed models remain available for manual removal. Missing credentials, incomplete configuration, HTTP errors, and unavailable models never trigger a fallback or a model download. Disabling custom mode restores built-in eligibility but does not resume a cancelled download. Gemma’s low-memory opt-in does not restrict custom services.

One AI window owns the task at a time. Another window receives a busy message. Cancellation applies to the owning window; changing service configuration cancels obsolete work, and stale progress/results cannot overwrite a new task. Only LocalScribe-owned processes are terminated.

All services use the existing protected prompts, conservative batches, validation, live preview, undo, and recovery workflow. Proofreading checks IDs, count, nonempty text, length, numbers, links, email addresses, and time expressions. Invalid segments retain their original text. A malformed proofreading JSON response may be repaired once. Transport failures are not automatically retried. Summaries retain the existing grounding and length checks; AI output still needs human review.

## Protocol and privacy

The three providers use Chat Completions and model-discovery endpoints. OpenAI requests use `max_completion_tokens` and `store: false`, without unconditional model-specific sampling fields. DeepSeek requests use `max_tokens` and disable thinking for these tasks. LM Studio uses `max_tokens` and deterministic temperature. No llama.cpp-only fields are sent to external providers. Both SSE and JSON are supported. Tool calls, refusals, non-stop finish reasons, empty results, and incomplete streams are rejected. Redirects are not followed; arbitrary server error bodies are not shown.

Cloud tasks send only the required transcript text, nearby context, protected system instructions, and additional instructions to the selected provider. They do not upload original audio or video. `store: false` is an API option, not a promise about all provider retention policies. LM Studio receives the text locally; its other networking behavior is controlled by its own settings.

## Validation status

OpenAI and DeepSeek connectors are preview features pending production-key smoke tests. Automated tests use disposable credentials and local fixtures; they do not call cloud APIs. Coverage includes provider-specific requests, model discovery, Keychain round trips, address restrictions, redirects, rate/authentication failures, byte-fragmented UTF-8 SSE, incomplete responses, timeout, cancellation, Gemma download isolation, and optimization safety. These tests establish implementation behavior, not real model quality or account compatibility.

Before promoting a cloud connector to stable support, use a production key with synthetic short text to validate discovery, connection, proofreading, summarization, and cancellation. Also validate an actual LM Studio text model. Never include keys or private transcripts in test fixtures, issues, or reports.

Protocol references: [LM Studio](https://lmstudio.ai/docs/developer/openai-compat/chat-completions), [OpenAI](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create), [DeepSeek](https://api-docs.deepseek.com/api/create-chat-completion/).
