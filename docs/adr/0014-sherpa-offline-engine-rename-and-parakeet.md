# ADR-0014: The sherpa offline engine is renamed, and streaming is deferred

## Status

Accepted — 2026-09-14

## Context

`LocalEngine.gigaAM`, `GigaAMTranscriber` and `GigaAMConfigPlan` name a vendor, but what they
actually are is a wrapper over sherpa-onnx's offline recognizer. Adding NVIDIA Parakeet TDT
0.6B v3 — same recognizer, same code path, a different config member — makes the name false.

Parakeet TDT v3 is worth adding: NVIDIA reports 5.51 % WER on FLEURS ru_ru and 3.00 % on CoVoST2
Russian, it emits punctuation and capitalisation (GigaAM Multilingual does not), it covers 25
languages including English, it is CC BY 4.0, and its sherpa asset
(`sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2`, 487 MB) exists today. Crucially,
sherpa's hotword biasing is implemented for TDT: `OfflineTransducerModifiedBeamSearchNeMoDecoder`
detects TDT, splits token and duration logits, and applies the `ContextGraph` boost to the token
logits before top-k. Whisper has no equivalent — biasing there would be ours to write.

Streaming models were considered at the same time and rejected. whisper.cpp has no true
streaming (`examples/stream` re-runs sliding windows; upstream says results are not great), and
sherpa's online NeMo implementation supports `greedy_search` only, so streaming Parakeet and
Nemotron cannot take hotwords at all. Streaming therefore costs either the primary engine or the
glossary.

## Decision

Rename `LocalEngine.gigaAM` to `.sherpaOfflineASR` now, decoding the stored string `"gigaAM"`
to the new case in a hand-written `init(from:)` — the pattern `PromptPreset` already uses. Rename
the transcriber and grow the config plan per sherpa config member. Add Parakeet TDT 0.6B v3 as a
catalog entry and compare it against whisper in real use.

Streaming (Tier B of `2026-09-10-asr-model-candidates.md`) is deferred until an online recognizer
supports contextual biasing.

## Consequences

- A settings-schema migration ships with the rename; a build that predates it reads the new value
  as unknown.
- ASR arrives as a `.tar.bz2` archive, so `ModelFileRole.archive` and `archiveSentinel` — today
  exercised only by TTS voices — must hand a directory to a transcriber.
- Parakeet's Russian numbers are from NVIDIA's own card on FLEURS/CoVoST2. No published
  comparison against whisper on the same protocol exists, and nothing measures Russian speech
  code-switching into English jargon, which is this user's actual case. The catalog entry is a
  way to find out, not a claim.
- CC BY 4.0 requires attribution: the model needs a `LicenseRegistry` entry and licence text
  under invariant 16.
- "GigaAM takes no parameters" stops being true catalog-wide once entries with their own config
  knobs arrive; the Dictation tab's parameters pane becomes per-model rather than per-engine.
