# Building a real dictation corpus, and using it

Status: **research notes, 2026-09-10 — superseded in part.**
Third of three companion documents, with `2026-09-10-asr-model-candidates.md` and
`2026-09-10-custom-vocabulary.md`.

The user's decisions on the five gaps below, taken 2026-09-10:

1. Lossless audio — **yes, as an option, default off.**
2. Metadata in SQLite — **yes.**
3. Retention — **no change**; the user sets `.unlimited`.
4. Export — **not now**; hand-correction will be done ad hoc as material accumulates.
5. Metric — **not now**; no scoring task yet.

Gaps 1 and 2 are therefore scoped into `2026-09-10-corpus-capture.md`. What remains here is
background, and the reasoning behind gaps 3–5 for whenever they come back.

Stated plan: collect real recordings for a while, hand-correct them into a reference, then
use that reference to judge models and vocabulary changes.

This is the right order. Everything in the other two documents — which of Handy's models to
adopt, whether an `initial_prompt` helps, what threshold a fuzzy corrector should use — is
currently unfalsifiable. A corpus turns all of it into arithmetic. The risk is spending
weeks of dictation and discovering the collected data cannot answer the question.

## What we already have

`saveOriginalRecording` (default off, requires `dictationHistoryEnabled`) writes the
recording behind each history entry. The pipeline, read from source:

- `AVAudioEngineRecorder` produces 16 kHz mono `[Float]`.
- That exact buffer goes to the transcriber, and the *same* buffer goes to
  `AACDictationAudioEncoder` → `<entryID>.m4a`, AAC at 48 kbit/s.
- `DictationHistoryStore` schema (`user_version = 2`):
  `dictation_history(id, created_at, kind CHECK IN ('dictation','dictationAndRefine'),
  text, audio_file)`.
- Retention: `HistoryRetention`, default `.ninetyDays`, with `.unlimited` available.
  `deleteEntries(olderThan:)` returns the audio filenames it orphaned and they are removed.
- UI actions on an entry: play, copy, refine, clear-all. No per-entry delete, no export.

One thing that is already right and easy to get wrong: for **dictate & refine**, the text
written to history is `raw` from the transcriber, trimmed — captured *before* the LLM sees
it (`DictationCapture.swift:139–141`). So history rows are ASR hypotheses, not refined prose.
That is exactly what a corpus needs.

## Five gaps between this and a usable corpus

### 1. The stored audio is lossy, and it is not what the model heard

The model is fed float PCM; the corpus keeps AAC at 48 kbit/s. Re-running a *different*
model over the archive therefore measures that model **plus** an AAC round-trip that the
original run never suffered. Differences of a percent or two between two candidate models
are inside that noise.

48 kbit/s AAC for one hour of 16 kHz mono is ~21 MB; lossless 16-bit WAV is ~115 MB, FLAC
roughly 55–65 MB. For a corpus of a few hours this is not a real constraint.

**Decision needed:** a corpus-mode capture that stores WAV or FLAC, separate from the
history's AAC, or a switch that upgrades history audio to lossless while collecting.

### 2. No metadata, so errors cannot be attributed

A row is `(text, audio)`. It does not record which model produced the text, which engine,
which language setting, thread count, translate flag, app version, or whether a vocabulary
prompt was in play. Two months from now the archive cannot answer "was this transcribed by
whisper Large v3 Turbo or GigaAM v3 RNN-T", which makes half the interesting comparisons
impossible on collected data — you can only re-run everything from scratch, and see gap 1.

**Decision needed:** a schema migration (`user_version = 3`) adding the run's provenance.
Cheap now, impossible retroactively.

### 3. Ninety-day retention silently eats the corpus

The default deletes entries and their audio after 90 days. A corpus collected "for a while"
begins decaying before it is used, oldest first — which is also the most-varied material.

**Decision needed:** collecting requires `.unlimited`, or corpus entries must live outside
the retention sweep. Either way the app should say so rather than quietly deleting.

### 4. No export, so hand-correction has nowhere to happen

The reference transcript is produced by a human editing text. There is no export, no
import, and no per-entry edit. Today the only route is opening the SQLite file by hand.

The round trip also needs to survive re-import: correcting 300 entries in an editor and then
finding no way back in is the obvious way to waste the effort.

**Decision needed:** an export format that pairs audio with text and round-trips. A
directory of `<id>.wav` plus a `manifest.jsonl` with one `{id, hypothesis, reference,
metadata}` object per line is the cheap, diffable, version-controllable option.

### 5. Nothing computes the score

A corpus is only useful with a metric attached. For this use case the metric is not one
number:

- **WER / CER** overall — the standard, but it is dominated by ordinary words and will
  barely move when `yarn` is fixed.
- **Term recall on a glossary** — of the N times a dev term was actually spoken, how many
  came out right. This is the number that answers the vocabulary question, and it is the one
  the user actually cares about.
- Both need text normalisation decisions made explicitly: case, punctuation, `ё`/`е`,
  numerals as digits versus words. GigaAM Multilingual emits no punctuation or capitalisation
  at all, so comparing it against a hand-written reference without normalisation scores it as
  catastrophically bad for reasons that do not matter.

**Decision needed:** where this lives. `scripts/` (Node, per AGENTS.md) fits: it is
developer tooling, not app behaviour, it needs no Swift, and it can iterate on the corpus
without rebuilding the app. The app then only has to *export*.

## Privacy, which is not a footnote here

This corpus is a recording of the user's actual work, and hand-correction means reading all
of it. Invariants 5, 6 and 9 exist for this: audio and transcripts stay local, never get
logged at default level, never leave for any endpoint that was not explicitly configured.

Two consequences that bear on design:
- A corpus export is a pile of unencrypted speech in a folder. It must be somewhere
  deliberate, with the app saying where, not a temp directory the user forgets about.
- Anything that transcribes the corpus through an OpenAI-compatible endpoint ships the audio
  off the machine. If endpoint models are to be compared, that must be a separate, explicit,
  opt-in step and not something a "re-run everything" button does silently.

## A plausible order of work

1. **Collect on lossless audio with provenance.** Schema migration + a lossless corpus
   capture + retention honesty. Without this, everything collected before it is second-rate
   data. This is the only part that is urgent, because it is the only part that cannot be
   done retroactively.
2. **Export.** Audio + `manifest.jsonl`, round-trippable.
3. **Correct.** Hand-edit `reference` in the manifest. No code. This is the slow part and it
   is worth knowing the cost up front: reference transcription of speech runs roughly
   5–10× real time, so an hour of dictation is the better part of a working day.
4. **Score.** A `scripts/` tool: WER/CER, glossary term recall, per-model breakdown,
   explicit normalisation rules.
5. **Only then** decide anything from `2026-09-10-asr-model-candidates.md` or
   `2026-09-10-custom-vocabulary.md`. Every claim in both becomes testable at this point,
   including the ones I wrote confidently.

Steps 1–2 are app work under the usual invariants. Steps 3–5 are not the app at all.

## Open questions

1. **How much is enough?** A rough guide: ~30 minutes of your speech, roughly 200–300
   utterances, gives a usable WER signal for large differences between models. Detecting a
   1–2 % difference needs considerably more. What difference do you actually want to detect?
2. **Corpus mode as a toggle, or history upgraded?** Separate mode keeps the corpus clean and
   avoids inflating everyone's history; upgrading history means you already have material
   from today onwards without a new capture path.
3. **Should each utterance be transcribed by more than one model at collection time?** It
   makes comparison honest (same audio, same session, no AAC round-trip) at the cost of
   several seconds per dictation. Probably not worth it during real work, but it is the only
   way to compare models on audio that is never re-encoded.
4. **Is the glossary term list the same one as the vocabulary feature's?** If yes, the scorer
   and the corrector share one file and the pack doubles as the evaluation target.

## Explicitly unverified

- The AAC round-trip's actual effect on WER for our models is unmeasured. It is asserted here
  as a risk, not a measured quantity; the honest test is transcribing the same PCM directly
  and via an m4a round-trip and comparing.
- The 5–10× real-time figure for manual reference transcription is an industry rule of thumb,
  not a measurement of this user on this material.
- No size estimate exists for how large the history database and audio directory get at
  `.unlimited` for this user's daily volume.
