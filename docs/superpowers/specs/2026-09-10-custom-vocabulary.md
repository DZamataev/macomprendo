# A vocabulary ("custom words") feature: how Handy does it, and what we could do

Status: **research notes, 2026-09-10 — not approved, nothing implemented.**
Companion to `2026-09-10-asr-model-candidates.md`. Written to be grilled before it becomes a spec.

Goal as stated by the user: one button that loads a glossary of English
developer terms — `yarn`, `npm`, `xcodegen`, `SwiftUI`, `git rebase` — so dictation stops
mangling them.

## How Handy does it

Source read on 2026-09-10: `src-tauri/src/audio_toolkit/text.rs`,
`src-tauri/src/managers/transcription.rs`, `src-tauri/src/settings.rs` (main branch).

Settings are two fields, nothing more:

```rust
pub custom_words: Vec<String>,          // flat list of strings
pub word_correction_threshold: f64,     // default 0.18
```

There are **two mechanisms**, chosen per model, and they are mutually exclusive:

### 1. Decode-time biasing (Whisper family only)

```rust
let family = if settings.custom_words.is_empty() || !model_is_whisper {
    None
} else {
    Some(RunExtension::Whisper(WhisperRunOptions {
        initial_prompt: Some(settings.custom_words.join(", ")),
        ..Default::default()
    }))
};
```

The whole word list, comma-joined, becomes Whisper's `initial_prompt`. That is the cheapest
possible contextual biasing: Whisper conditions its decoder on the prompt text, so tokens
that appear there become more likely. Non-Whisper architectures reject the whisper run
extension (`INVALID_ARG`), and streaming models get no prompt at all.

### 2. Post-hoc fuzzy correction (everything else)

`apply_custom_words(text, custom_words, threshold)` runs **only when the model did not get
the prompt** (`custom_words_already_prompted` gates it). The algorithm:

- Normalise both sides to a match key: keep alphanumerics, lowercase, drop everything else.
  So `Charge B` and `ChargeBee` both key to `chargeb…` / `chargebee`.
- Slide n-grams of 1–3 words over the transcript, so a term split by the recogniser into
  several words can still match one glossary entry.
- Score = normalised Levenshtein distance; if Soundex says the two strings sound alike,
  multiply the score by 0.3. Accept the best match below `threshold` (0.18 by default).
- Guard rails: candidate ≤ 50 chars; skip pairs whose lengths differ by more than 25 %
  (≥ 2 chars always allowed) — this is what stops `openaigpt` collapsing into `openai`.
- Restore the original case pattern (ALL CAPS / Capitalised / lower) and re-attach the
  leading and trailing punctuation of the original token.
- **ASCII only.** `is_supported_fuzzy_key` requires every character to be ASCII alphanumeric,
  on both the glossary entry and the candidate. Non-Latin text is skipped deliberately:
  the comment says whitespace tokenisation and Soundex are wrong for CJK.

### 3. Adjacent features, not the same thing

- ~~`${custom_words}` is a placeholder that can be interpolated into the LLM post-processing
  prompt, so the same list reaches the refine step.~~ **Corrected 2026-09-14: this is false.**
  Handy's only prompt placeholder is `${output}` (the transcript itself). The glossary never
  reaches the LLM step in any form; it can influence it only indirectly, through Whisper's
  `initial_prompt` or through fuzzy correction applied earlier in the pipeline. Verified at
  `cjpais/Handy@db1aaac`: `actions.rs:82-86` (structured path deletes `${output}`),
  `actions.rs:310-319` (legacy path substitutes it), `src/i18n/locales/en/translation.json:435-448`
  (the UI documents `${output}` alone). Handy's own post-processing is off by default, is bound
  to a separate "Transcribe with Post-Processing" hotkey, and never streams
  (`settings.rs:632-634`, `actions.rs:928-940`, `llm_client.rs:382-388`).
- "Word Replacements" — deterministic find-and-replace, a separate later feature after
  issue #198, because fuzzy matching cannot delete filler words or expand `btw`.
- Handy has **no bulk import** (issue #1321, rejected during a feature freeze). Users edit
  `settings_store.json` by hand. The single button the user wants does not exist there.

## What our code can do today

### whisper.cpp — supported, unused

Our vendored `whisper.h` has it:

```c
const char * initial_prompt;
bool carry_initial_prompt;   // prepend to every decode window
const whisper_token * prompt_tokens;
int prompt_n_tokens;
```

`WhisperParams` (language, threads, noTimestamps, translate) has no prompt field, and
`WhisperCppTranscriber` never sets `params.initial_prompt`. Adding it is a small, honest
change on the engine we already ship: one field, one `withCString` nesting level beside the
existing one for `params.language`, and `WhisperParams.make` is already pure and unit-tested.

Caveats worth stating out loud:

- The prompt costs decoder context. Whisper's prompt window is bounded
  (`n_max_text_ctx`, 224 tokens by default); a 400-term glossary does not fit and the tail is
  silently dropped. A "load the whole dev dictionary" button therefore needs a budget and a
  truncation rule, not an unbounded list.
- A prompt biases, it does not guarantee. It can also *hallucinate* the prompt's words into
  silence — a documented Whisper failure mode.

### GigaAM / sherpa-onnx — partly supported, awkward

`SherpaOnnxOfflineRecognizerConfig` already has `hotwords_file`, `hotwords_score`,
`rule_fsts`, `blank_penalty`, and a `SherpaOnnxHomophoneReplacerConfig hr`. There is also
`SherpaOnnxCreateOfflineStreamWithHotwords` for per-utterance hotwords.

But upstream is explicit: **hotwords work only for transducer models and only with
`modified_beam_search`.** Applied to our four GigaAM entries:

| entry | engine shape | hotwords possible? |
|---|---|---|
| `gigaam-v3-e2e-ctc` | NeMo CTC | no |
| `gigaam-v3-e2e-rnnt` | transducer | yes, but needs `decoding_method = "modified_beam_search"` |
| `gigaam-multilingual-ctc` | CTC | no |
| `gigaam-multilingual-large-ctc` | CTC | no |

`GigaAMTranscriber.makeRecognizer` hard-codes `"greedy_search"`. And a deeper problem: a
hotword is tokenised with **the model's own token inventory**. GigaAM's Russian tokens
encoding the English string `yarn` is, at best, unverified. The hotwords route is not the
one that serves this request.

### OpenAI-compatible endpoint — supported, unused

`OpenAICompatibleTranscriber` builds a multipart body with `file`, `model` and optionally
`language`. The OpenAI transcription API also accepts a `prompt` field with exactly the
Whisper-prompt semantics. We do not send it.

### Engine-independent fallback

A Swift port of Handy's fuzzy corrector would work behind *every* backend, including
GigaAM and the endpoint, because it operates on the finished transcript. It is pure text
processing: no OS, no C API, trivially unit-testable, which fits invariant 3 better than
anything else in this document.

## The mixed-language problem, which Handy does not solve

The user dictates Russian with English technical terms embedded. That breaks both mechanisms
in ways worth deciding about before writing code:

1. **Fuzzy correction is ASCII-gated.** Handy's guard skips any candidate that is not ASCII.
   If Whisper hears `yarn` and writes `ярн` in Cyrillic, the corrector never looks at it —
   the most likely failure mode for this user is exactly the one the algorithm ignores.
   Handling it means a transliteration-aware key (`ярн` → `yarn`), which is a new thing, not
   a port.
2. ~~**A Latin-only prompt biases the language decision.**~~ **Corrected 2026-09-14: refuted by
   the source.** `whisper_full_with_state` runs `whisper_lang_auto_detect_with_state` *before* it
   tokenises the initial prompt (`src/whisper.cpp:6937-6959` vs `7052-7063`), so the detector
   never sees the prompt. A Latin prompt can still steer the *script and register of the output*
   (openai/whisper discussion #277), which is a different and milder effect.
3. **GigaAM Multilingual produces no punctuation or capitalisation**, so case restoration has
   nothing to restore and `NPM` versus `npm` is decided entirely by the glossary entry.

## Design sketch, for the grill

**Settings** (`Settings`, decoded with `decodeIfPresent`, so `currentSchemaVersion` need not
move — the pattern `SpeechSettings` already uses):

```swift
var vocabularyTerms: [String]         // user's list, order preserved
var vocabularyPacks: [String]         // ids of enabled built-in packs
var vocabularyCorrectionEnabled: Bool
var vocabularyThreshold: Double       // Handy's 0.18 as the default
```

**The one button** is a built-in pack: a bundled resource, e.g.
`Resources/Vocabulary/dev-en.json`, checked into the repo with a version and a source note,
listing developer terms (`yarn`, `npm`, `pnpm`, `xcodegen`, `SwiftPM`, `git rebase`,
`Xcode`, `Homebrew`, …). Enabling the pack unions its terms into what the pipeline sees; the
user's own list stays separate and editable, so a pack update never clobbers their entries.
That also answers Handy's missing bulk import without inventing a file format.

**The pipeline**, per backend:

| backend | mechanism |
|---|---|
| whisper.cpp | `initial_prompt`, budgeted and truncated; fuzzy correction skipped |
| OpenAI endpoint | multipart `prompt` field; fuzzy correction skipped |
| GigaAM (all four) | fuzzy correction only |

with a user-visible statement on the Dictation tab of which one is active for the selected
model, because "the dictionary works" means two different things here.

**Tests** (written first, per invariant 3): the corrector is pure, so n-gram matching,
the length guard, case and punctuation preservation, the ASCII gate, threshold boundaries and
"no glossary means text unchanged" are all ordinary unit tests. `WhisperParams` gaining a
prompt field, the truncation budget, and the per-backend routing decision are likewise pure.
Only the actual `params.initial_prompt` bridging is C glue for `SMOKE_TEST.md`.

## Open questions I cannot answer without you

1. **Which mechanism do you actually want?** Decode-time biasing changes what the model
   hears; post-hoc correction changes what it wrote. They fail differently: the first can
   hallucinate glossary words into silence, the second can rewrite a correctly-heard word
   into a wrong one. Handy ships both and picks by model.
2. **Do we need the Cyrillic case** (`ярн` → `yarn`), or is it enough to fix `yarn` vs
   `yard`? The first is the interesting engineering problem and the second is a port.
3. **Is the pack curated by us and committed**, or downloaded? Committed is simpler and fits
   invariant 9 (no network beyond configured endpoints and model downloads).
4. **Does the glossary also reach the refine/summarize prompts**, as Handy's
   `${custom_words}` placeholder does? Our `FactoryPresets` renderer could take the same
   variable.

## Explicitly unverified

- Handy's default threshold of 0.18 is read from its source, not validated against our audio,
  our models, or Russian text.
- No measurement exists that an `initial_prompt` improves `yarn`/`npm` recognition for *this*
  user's voice and models. Before building the UI, the cheap experiment is: hard-code a
  prompt in `WhisperCppTranscriber`, dictate the same paragraph twice, and compare. That is
  a smoke test, not a unit test, and it should precede the spec.
- Whisper's 224-token prompt budget is from upstream documentation, not measured against our
  vendored build.
