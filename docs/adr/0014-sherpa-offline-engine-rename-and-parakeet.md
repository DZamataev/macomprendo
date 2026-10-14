# ADR-0014: The sherpa offline engine is renamed, and streaming is deferred

## Status

Accepted — 2026-09-14. Amended 2026-10-14 on implementation; see **Amendment** below.

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

## Amendment — 2026-10-14

Implementation checked three of the consequences above against the code and replaced them:

- **No migration.** No `LocalEngine` value is persisted anywhere: settings store a model id, and
  the only engine string on disk is `TranscriptionRun.engine`, a plain `String` in the history
  database. The hand-written `init(from:)` would decode nothing, so it was not written. New rows
  record `sherpaOfflineASR`; rows already written keep `gigaAM`, and readers accept both.
- **Loose files, not the archive.** The four files of sherpa-onnx's int8 conversion are
  published loose on Hugging Face (`csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8`) with
  per-file digests, and its `tokens.txt` hashes identically to the one inside the 487 MB release
  archive. Loose files take the transducer path GigaAM RNN-T already uses, so archive-backed ASR
  was not needed.
- **No `LicenseRegistry` entry.** The registry lists components the app *redistributes*
  (invariant 16); a model the user downloads from its publisher is not one. CC BY 4.0 is stated
  in `NOTICE` under *Downloaded models* and in the model's brief; showing each model's licence in
  the app is issue #19.

Decoding stays `greedy_search`, so Parakeet's hotword support is not used yet: no glossary
biasing ships for any backend. The parameters pane stays per-engine, because Parakeet has no
setting of its own. A real-speech integration test confirmed sherpa reads Parakeet's encoder
metadata as TDT: English and Russian samples decode with punctuation and capitals.
