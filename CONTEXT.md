# Macomprendo

Macomprendo is a menubar dictation and text tool for macOS. Global hotkeys record speech,
transcribe it locally or through a configured endpoint, and paste the result; the same hotkeys
also refine, summarise, or speak the current selection.

## Language

### Dictation

**Dictation**:
One press-to-record, transcribe, and paste cycle.
_Avoid_: recording, capture, voice note

**Transcription source**:
Which recogniser a dictation runs through: a catalog entry downloaded locally, or a configured
endpoint.
_Avoid_: provider, engine choice, backend selection

**Local engine**:
The runtime a locally installed model runs on — whisper.cpp for GGML models, the sherpa-onnx
offline recognizer for everything else.
_Avoid_: framework, library, inference engine

**Catalog entry**:
One downloadable model as the app offers it: an id, files, hashes, and the plan that configures
its recogniser.
_Avoid_: model file, download

**Dictation history**:
The opt-in record of accepted transcripts, each optionally carrying its recording and the
provenance of the run that produced it.
_Avoid_: log, archive, transcript store

### Glossary

**Glossary**:
Everything the app is told to recognise as jargon: the enabled packs plus the user's own list.
_Avoid_: dictionary, custom words, vocabulary list

**Term**:
One glossary entry, stored in its canonical spelling — casing and hyphens included.
_Avoid_: word, keyword, hotword (that names a mechanism, not an entry)

**Canonical spelling**:
How a term must appear in the pasted text. `auto-till-dry`, not `Auto-Tilt-Dry`.
_Avoid_: correct form, proper case

**Pack**:
A named, switchable file of terms. Factory packs ship in the bundle and seed the user's
directory; a pack is enabled by listing its name in `packs.json`, beside the pack files.
_Avoid_: group, category, preset, collection

**Replacement rule**:
A term that also lists the Cyrillic forms a recogniser produces for it, so they can be rewritten
to the canonical spelling after transcription.
_Avoid_: substitution, find-and-replace, correction

**Normalisation**:
Rewriting a recognised term to its canonical spelling when the two match once casing, spaces,
hyphens and dots are ignored. It settles shape, not choice: `Xcode build` and `NVM` are already
the right letters.
_Avoid_: correction, fuzzy matching, cleanup

**Biasing**:
Raising a term's score inside the recogniser, before it chooses — Whisper's prompt or sherpa's
hotwords. It changes which word the model writes; normalisation and replacement rules change a
word it has already written.
_Avoid_: boosting, hinting, prompting (that names one implementation)

**Prompt budget**:
How much of the glossary fits into Whisper's bounded prompt window. The manual list enters whole;
packs fill what remains, by rank.
_Avoid_: limit, cap, token limit

### Prompts

**Preset**:
A user-editable prompt for refine or summarize, in one language, seeded from a factory preset.
_Avoid_: template, prompt config
