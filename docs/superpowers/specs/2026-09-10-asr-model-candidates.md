# ASR model candidates: what Handy offers and what we could actually add

Status: **research notes, 2026-09-10 — not approved, nothing implemented.**
Purpose: a shortlist to be grilled (`/grill-with-docs`) before any of it becomes a spec.
Builds on: `2026-08-31-transcription-backends-catalog-design.md` (the catalog, `LocalEngine`,
`ModelFileRole`, `GigaAMTranscriber`), `ADR-0009-sherpa-onnx-gigaam.md`.

## Where the list comes from

The Handy app (`cjpais/Handy`) model picker, transcribed from six screenshots taken on
2026-09-10. Handy is the comparison point because it solves the same problem (offline
push-to-talk dictation) and has a far larger catalog than ours.

Handy reaches those models through two runtimes we do **not** have:

- `transcribe-cpp` — a GGML/GGUF loader that auto-detects the architecture, so one engine
  covers Whisper, Parakeet-GGUF, Voxtral, Qwen3-ASR, Nemotron, Breeze, Granite.
- `transcribe-rs` — ONNX runtime wrappers for Parakeet, Moonshine, SenseVoice.

We reach models through `whisper.cpp` (GGML, one file) and `sherpa-onnx` 1.13.4
(`SherpaOnnxC.framework`, offline recognizer only). That difference — not model licensing —
is what decides which of Handy's entries are cheap for us and which are a new engine.

### What our vendored sherpa-onnx 1.13.4 already exposes

Read from the vendored header
(`.build/artifacts/sherpaonnxbinary/.../c-api/c-api.h`), `SherpaOnnxOfflineModelConfig`:

`transducer`, `paraformer`, `nemo_ctc`, `whisper`, `tdnn`, `zipformer_ctc`, `wenet_ctc`,
`sense_voice`, `moonshine`, `dolphin`, `canary`, `cohere_transcribe`, `omnilingual`,
`medasr`, `funasr_nano`, `fire_red_asr`, `fire_red_asr_ctc`, `qwen3_asr`, `telespeech_ctc`.

`SherpaOnnxOnlineModelConfig` (streaming): `transducer`, `paraformer`, `zipformer2_ctc`,
`nemo_ctc`, `t_one_ctc`.

So the C API for most of Handy's list is **already linked into the app today**. We use
exactly two of those config members (`nemo_ctc`, `transducer`) in `GigaAMTranscriber`.

Upstream is at v1.13.8; our pin is v1.13.4. Anything newer than the pin needs an
xcframework bump under invariant 13.

### What our download path already supports

`LocalModelManager` handles loose files (ASR today) **and** a single verified `.tar.bz2`
archive with `archiveSentinel` (used by the Piper/Kokoro TTS voices, `TarArchiveExtractor`).
Every sherpa-onnx ASR release asset is a `.tar.bz2` at

```
https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/<name>.tar.bz2
```

so the archive route is a solved problem for ASR too, apart from `ModelFileRole.archive`
currently being TTS-shaped in the resolver.

## Handy's catalog, verbatim (6 screenshots)

Recommended row: Parakeet Unified EN 0.6B (697 MB, streaming, en) · Nemotron Streaming 3.5
(716 MB, 28 langs, streaming) · Canary 180M Flash (208 MB, 4 langs, translate) · Cohere
Transcribe (1.6 GB, 14 langs) · Whisper Medium (793 MB, 99 langs, translate) · Voxtral Mini
4B Realtime (3.1 GB, 13 langs, streaming) · Parakeet TDT 0.6B v3 (705 MB, 25 langs) ·
Parakeet TDT 0.6B v2 (695 MB, en) · Qwen3-ASR 0.6B (811 MB, 30 langs) · Fun-ASR Nano
Multilingual (849 MB, 31 langs) · Granite Speech 4.1 2B NAR (1.7 GB, 5 langs) · Granite
Speech 4.1 2B.

Rest: Parakeet TDT 1.1B · Parakeet RNN-T 1.1B · Parakeet RNN-T 0.6B · Parakeet CTC 0.6B ·
Parakeet CTC 1.1B · Parakeet TDT-CTC 1.1B · Parakeet TDT-CTC 110M (129 MB) · Parakeet TDT
0.6B primeLine (German-tuned) · Multitalker Parakeet Streaming EN (700 MB) · Nemotron Speech
Streaming EN (695 MB) · Granite Speech 4.0 1B · Granite Speech 4.1 2B Plus · Canary 1B ·
Canary 1B Flash · Canary 1B v2 (25 langs, translate) · Canary-Qwen 2.5B · Qwen3-ASR 1.7B ·
Voxtral Mini 3B · Voxtral Small 24B (16 GB) · Fun-ASR Nano (3 langs) · MOSS-Transcribe-Diarize
0.9B · Breeze-ASR-25 (Taiwanese Mandarin) · MedASR (121 MB, en) · SenseVoice Small (240 MB,
5 langs) · Whisper Large v3 / v3 Turbo / Large / Large v2 / Medium(.en) / Small(.en) /
Base(.en) / Tiny(.en) · Moonshine Tiny/Base (en, ar, zh, ja, ko, uk, vi) · Moonshine Streaming
Tiny/Small/Medium · **GigaAM v3 RNN-T / CTC / E2E-RNN-T / E2E-CTC (Russian)** — the four we
already ship.

## Candidates for us, by cost

Sizes below are the **compressed sherpa-onnx release asset**, read from the GitHub API on
2026-09-10; Handy's numbers differ because they repackage.

### Tier A — new catalog entries only, no new engine

Offline sherpa-onnx models whose config member exists in our pinned 1.13.4. Cost per entry:
a `LocalModel` literal, a `ModelBrief`, a role/plan mapping, hashes, a smoke-test line.
The `GigaAMConfigPlan` enum has to grow beyond `ctc`/`transducer`, and `LocalEngine` needs
a name that is not `gigaAM` for anything that is not GigaAM.

| Model | Asset | Size | Languages | Why it is interesting |
|---|---|---|---|---|
| Parakeet TDT 0.6B v3 | `sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8` | 487 MB | 25 EU incl. **ru, uk** | Handy's default. Offline transducer — same code path as GigaAM RNN-T. The one entry that competes with GigaAM on Russian while also doing English. |
| Parakeet TDT 0.6B v2 | `...-tdt-0.6b-v2-int8` | 483 MB | en | Best-in-class English, same path. |
| Parakeet TDT-CTC 110M | `sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8` | 104 MB | en | Tiny and instant; the cheap English default. |
| Parakeet unified EN 0.6B (non-streaming) | `...-unified-en-0.6b-int8-non-streaming` | 501 MB | en | Same weights as Handy's streaming recommendation, used in batch. |
| SenseVoice Small | `sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09` | 166 MB | zh, en, ja, ko, yue | 166 MB for five languages; own config member with ITN flag. |
| Canary 180M Flash | `sherpa-onnx-nemo-canary-180m-flash-en-es-de-fr-int8` | 154 MB | en, es, de, fr (+translate) | Only sherpa model here with a real translate task; `src_lang`/`tgt_lang`/`use_pnc` in the config. |
| Moonshine (en, and ar/es/ja/ko/uk/vi/zh) | `sherpa-onnx-moonshine-*-quantized-2026-02-27` | 30–120 MB | one per model | The whole per-language family Handy lists. 4-file (or merged-decoder) layout. |
| Dolphin base / small CTC | `sherpa-onnx-dolphin-{base,small}-ctc-multi-lang-int8-2025-04-02` | 81 / 192 MB | many Asian | Not in Handy's list; cheap, single-file CTC. |
| Zipformer RU | `sherpa-onnx-zipformer-ru-int8-2025-04-20` | 60 MB | ru | 60 MB Russian, as a low-end alternative to GigaAM. Not in Handy's list. |
| MedASR CTC EN | `sherpa-onnx-medasr-ctc-en-int8-2025-12-25` | 132 MB | en | Medical English; niche, but its own config member exists. |
| Qwen3-ASR 0.6B | `sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25` | 879 MB | ~30 | Multi-file (conv frontend + encoder + decoder + tokenizer dir) — heaviest Tier A entry. |
| Fun-ASR Nano | `sherpa-onnx-funasr-nano-int8-2025-12-30` | 842 MB | 3 / 31 (claim to verify) | LLM-shaped config (prompts, temperature, seed) — does not fit our "no parameters" GigaAM story. |
| Cohere Transcribe 14-lang | `sherpa-onnx-cohere-transcribe-14-lang-int8-2026-04-01` | 1.7 GB | 14 (list to verify) | Handy calls it the accuracy leader. Big. |
| Omnilingual ASR 300M / 1B CTC | `sherpa-onnx-omnilingual-asr-1600-languages-*-int8` | 292 MB / 786 MB | ~1600 | Not in Handy's list. Absurd coverage per byte; quality per language unverified. |
| Fire-Red ASR2 | `sherpa-onnx-fire-red-asr2-{ctc-,}zh_en-int8-2026-02` | 521 / 839 MB | zh, en | Only if Chinese matters, which it currently does not. |

### Tier B — needs the online (streaming) recognizer, and possibly a newer pin

Everything Handy marks "Streaming": Nemotron Streaming 3.5 (multilingual, 475 MB),
Nemotron Speech Streaming EN (464 MB), Multitalker Parakeet Streaming EN, Parakeet unified
streaming (240/560/1120 ms), Moonshine Streaming Tiny/Small/Medium, T-one Russian streaming
(`sherpa-onnx-streaming-t-one-russian-2025-09-08`, 129 MB).

The 2026-08-31 spec put streaming under non-goals for a reason: our flow is record-then-
transcribe, and partial results are a different protocol (`SherpaOnnxCreateOnlineRecognizer`,
a feed/decode loop, endpointing) plus HUD and paste-timing questions. Several of these
assets are also dated after our v1.13.4 pin and need the xcframework bump first.

**Open question for the grill:** is streaming a product goal at all, or is the honest answer
that dictation-then-paste never shows a partial result to anyone?

### Tier C — would need a whole new runtime

Voxtral Mini 3B / Mini 4B Realtime / Small 24B, Granite Speech 4.0 1B / 4.1 2B / 2B NAR /
2B Plus, Canary 1B / 1B Flash / 1B v2 / Canary-Qwen 2.5B, Qwen3-ASR 1.7B,
MOSS-Transcribe-Diarize 0.9B, Parakeet 1.1B family, Parakeet primeLine German-tuned.

None of these has a published sherpa-onnx release asset. Handy runs them through
`transcribe-cpp` on GGUF. Adopting them means adopting a third binary runtime — a second
ADR-0007-scale decision, not a catalog entry.

One exception worth checking: **Breeze-ASR-25** is a Whisper fine-tune distributed by Handy
as `breeze-asr-q5_k.bin`, i.e. plain GGML. If it loads in `whisper.cpp` it is a Tier A-cost
entry on the engine we already have — but it is Taiwanese Mandarin, which is of no use here.
The same reasoning would apply to any Russian Whisper fine-tune in GGML, and that is the
lead actually worth chasing.

### Tier D — deliberately not wanted

- Whisper Large v1/v2/v3, distil-*, medium-aishell via sherpa: we already run Whisper through
  `whisper.cpp` with Metal. A second copy through ONNX is strictly worse.
- Handy's `blob.handy.computer` URLs: repackaged by a third party, no upstream provenance.
  If we take a model, we take it from the publisher's own release.

## What this changes in our design if any of Tier A is taken

1. `LocalEngine.gigaAM` is misnamed the moment a Parakeet or SenseVoice entry uses the same
   sherpa offline recognizer. It should become something like `sherpaOfflineASR`, with the
   per-family config choice living in the plan enum. That is a settings-schema migration
   (`transcriptionSource` stores model ids, not engine names — to be confirmed).
2. `GigaAMConfigPlan` grows a case per config member (`senseVoice`, `moonshine`, `canary`,
   `dolphin`, …). `GigaAMTranscriber` is then misnamed too.
3. "GigaAM takes no parameters" stops being true catalog-wide: Canary has `src_lang`/
   `tgt_lang`/`use_pnc`, SenseVoice has `language`/`use_itn`, Fun-ASR Nano has prompts and a
   sampling temperature. The Dictation tab's per-engine Parameters pane has to become
   per-model, or those knobs stay hidden and the models ship half-configured.
4. ASR archives: `ModelFileRole.archive` + `archiveSentinel` exist but are exercised only by
   TTS. Reusing them for ASR needs the resolver to hand a directory to the transcriber.
5. Every entry needs SHA-256 through `scripts/fetch-model-hashes.mjs`, a brief with a real
   source link, and a `SMOKE_TEST.md` line — invariants, not paperwork.

## Explicitly unverified

- Language lists for Cohere Transcribe (14), Qwen3-ASR (30), Fun-ASR Nano (31), Nemotron 3.5
  (28) are Handy's UI claims, copied here, not checked against the publishers.
- Handy's accuracy/speed bars are their own scores with no published methodology. Nothing in
  this document should be presented to a user as a benchmark.
- No model here has been run on this machine. Sizes are release-asset sizes; installed size
  after extraction is larger and unmeasured.
- Licences are unchecked for every Tier A entry except the GigaAM ones we already ship.
