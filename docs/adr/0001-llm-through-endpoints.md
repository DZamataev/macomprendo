# ADR-0001: LLM features run through configurable endpoints, not a bundled engine

## Status

Accepted — 2026-08-23

## Context

Refine and Summarize need a chat model. Bundling llama.cpp plus weights would add hundreds of
megabytes to the download, force us to ship and update GGUF files, and make us responsible for
inference performance on every Mac. Meanwhile Ollama is already installed on most developer Macs
and exposes both a native API (`/api/tags`, `/api/chat`, `/api/pull`) and an OpenAI-compatible
surface, and every hosted provider worth supporting speaks `/v1/chat/completions`.

## Decision

Macomprendo ships no LLM engine. It talks to user-configured `Endpoint` values of kind `.ollama`
or `.openAICompatible`. `ProviderFactory` picks `OllamaProvider` for `.ollama` (needed for model
listing and one-click `pull`) and `OpenAICompatibleLLMProvider` otherwise. A seeded
"Ollama (local)" endpoint at `http://localhost:11434` is the default. API keys are stored in the
Keychain; `Settings` holds only the account reference.

## Consequences

- The app download stays small and the LLM can be swapped without a new release.
- Refine and Summarize are unavailable until the user has a reachable endpoint; the UI must
  surface `providerUnreachable` with "Start Ollama or choose another endpoint".
- Two streaming formats must be supported: Ollama's NDJSON and OpenAI's SSE with a `[DONE]`
  terminator. Both are parsed by dedicated, unit-tested parsers.
- Users bear the cost and privacy characteristics of whichever endpoint they choose; the app makes
  no network call the user has not configured.
