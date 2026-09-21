# ADR-0013: Canonical-form normalisation first, biasing second

## Status

Accepted — 2026-09-14. Rewritten 2026-09-17 after the control dictation
(`docs/superpowers/specs/2026-09-14-glossary-control-dictation.md`) measured the failures instead
of guessing at them. The original decision led with biasing and treated the text pass as its
supplement; the measurement reversed that.

## Context

A control paragraph read on 2026-09-17 with `ggml-large-v3-turbo` and Russian pinned produced 44
observations, 37 of them broken. Sorted by what actually went wrong:

| Failure | Share | Example |
|---|---|---|
| **casing** | 39 % | `nvm` → `NVM`, `auto-till-dry` → `Auto-Till-Dry`, `Autoload` → `AutoLoad` |
| **substitution** | 18 % | `jq` → `GQ`, `ruff` → `RAV`, `rn-core-lite` → `Rancor Lite` |
| **splitting** | 16 % | `xcodebuild` → `Xcode build`, `SafeAreaView` → `Safe Area View` |
| correct | 16 % | `SwiftUI`, `UIKit`, `TurboModules`, `git rebase` |
| transliteration | 9 % | `Metro` → `метро`, `Codegen` → `код ген` |

Casing plus splitting is 55 % of everything, and **contextual biasing cannot touch it**. When
whisper writes `NVM` for `nvm` it did not choose between them: it heard correctly and wrote the
wrong shape. Raising the logit of the `nvm` token settles an argument the decoder was never
having. The same holds for `Xcode build` against `xcodebuild` — right letters, one extra space.

Transliteration, assumed earlier to be the dominant failure on the strength of a single observed
`TextEditor` → `текст-эдитор`, is 9 %. With the transcription language pinned to Russian the
model writes Latin jargon in Latin nearly every time.

The biasing mechanisms available are also not portable. whisper.cpp has `initial_prompt` — soft
conditioning, bounded to 224 prompt tokens total (~223 usable), documented to hallucinate prompt
words into silence. sherpa-onnx has hotwords: a real `ContextGraph` score added to token logits,
with no size limit, but only for transducer models and only under `modified_beam_search`. The
OpenAI-compatible endpoint accepts a multipart `prompt` field with Whisper's semantics. GigaAM's
CTC entries can take neither.

## Decision

Three mechanisms, in this order of both build and effect.

**1. Canonical-form normalisation.** Pure text, runs under every backend. Normalise a candidate
by lowercasing and dropping spaces, hyphens and dots; compare against glossary terms normalised
the same way; on an exact key match, rewrite to the term's canonical spelling. A sliding window of
up to four words handles splitting, so `Safe Area View` and `Xcode gen generate` rejoin.
Normalisation is unconditional, including for two-letter terms: a term is in a pack because the
user put it there.

**2. Biasing**, per backend, for the 18 % the decoder genuinely got wrong:

| backend | mechanism |
|---|---|
| whisper.cpp | `initial_prompt`, budget-checked and truncated by rank |
| sherpa offline transducer (Parakeet, GigaAM RNN-T) | hotwords + `modified_beam_search` |
| sherpa offline CTC (GigaAM Multilingual) | none |
| OpenAI-compatible endpoint | multipart `prompt` |

**3. Cyrillic replacement rules**, the `TextEditor = текст-эдитор` form, last — 9 % of failures,
and the only mechanism needing hand-written forms per term. It matches on a stem of at least four
characters plus up to three characters of inflection, because Russian inflects
(`текст-эдиторе`, `текст-эдитора`).

A single "use the glossary" switch controls all three. Which biasing mechanism is active is a
property of the selected model, displayed on the Dictation tab, not a user choice.

## Consequences

- More than half the benefit arrives before any engine work: normalisation is independent of
  whisper, Parakeet, the prompt budget and the engine rename, so it ships first and alone.
- Whether Parakeet is worth adopting for its hotwords becomes measurable only after normalisation
  lands, because today's biggest failure class would otherwise dominate the comparison.
- "The dictionary works" means something different per model, so the UI must say which mechanism
  is in play.
- Normalisation produces two versions of every transcript. Dictation history stores both: the raw
  model output is what a corpus must measure, the corrected text is what was pasted.
- The Whisper prompt budget is finite and the glossary is not. Terms are ranked, the manual list
  enters whole, packs fill the remainder, and the tab warns with an estimate ("roughly 60 of 148
  terms reach Whisper"). The estimate is arithmetic, not `whisper_tokenize`, to avoid loading a
  model when Settings opens.
- `GigaAMTranscriber` hard-codes `"greedy_search"`; hotwords require changing that to
  `"modified_beam_search"` for transducer entries, which changes decode cost.
- Handy's fuzzy Levenshtein-plus-Soundex corrector is deliberately not adopted. Its thresholds
  exist to cover a class of errors that exact normalisation settles outright, and its ASCII gate
  skips the transliterated cases entirely.
- Whole-phrase dropouts ("В питоновом репозитории поставил всё" → "Теперь поставил все") are a
  separate defect no glossary addresses.
