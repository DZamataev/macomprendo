# ADR-0002: Transcription uses whisper.cpp in-process, with a remote fallback

## Status

Accepted — 2026-08-23

## Context

Dictation must work offline, start instantly, and never send audio anywhere by default. Ollama has
no speech-to-text API, so the "just reuse the LLM endpoint" approach is not available. whisper.cpp
provides Metal-accelerated inference and runs comfortably in-process on Apple silicon.

## Decision

`WhisperCppTranscriber` is an actor wrapping `whisper_full`, loading the selected ggml model lazily
and keeping it resident. It is the default `TranscriptionProvider`. Models are downloaded on demand
from `ggerganov/whisper.cpp` into `~/Library/Application Support/Macomprendo/models/` and verified
by SHA-256. Users who prefer a server can instead select an `Endpoint` and
`OpenAICompatibleTranscriber` posts a WAV multipart body to `{baseURL}/v1/audio/transcriptions`.

## Consequences

- whisper.cpp itself is consumed as a prebuilt xcframework, not compiled from source — see
  ADR-0007 for why, and for what that means for bundle packaging.
- First-run requires a model download (default `large-v3-turbo`, lightweight alternative `base`).
- The C interop is hardware-bound and therefore thin, isolated behind `TranscriptionProvider`, and
  covered by `docs/SMOKE_TEST.md` rather than unit tests.
- If Ollama ever adds `/v1/audio/transcriptions`, it works through the existing endpoint path with
  no code change.
- **SHA-256 verification is not a settled property today.** The catalog carries a `sha256` field
  per model (populated by `scripts/fetch-model-hashes.mjs`), but all nine entries currently ship
  with it empty, so downloads are not actually checked against a hash yet. DISTRIBUTING.md and
  the `macomprendo-release` skill disclose this honestly; this ADR's "verified by SHA-256" should
  be read as the intended design, not a claim about the current build.
