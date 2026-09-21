# Corpus capture: lossless recordings, run metadata, and the raw transcript

Status: **approved 2026-09-17.** Narrowed from `2026-09-10-dictation-corpus.md` by the user's
decisions on its five gaps, then extended on 2026-09-17 with the raw-transcript column that
ADR-0013 requires.

Builds on: `2026-09-01-dictation-history.md`, `ADR-0010-sqlite-dictation-history`,
`ADR-0011-saved-dictation-audio`, `ADR-0013-glossary-reaches-each-backend-differently`.

## Problem

The user is building a corpus of real dictation to hand-correct into a reference. Three
properties of that corpus cannot be added afterwards, and all three are missing today.

1. `AACDictationAudioEncoder` stores 48 kbit/s AAC while the transcriber was fed Float32 PCM.
   Re-running a different model over the archive therefore measures that model plus an AAC
   round-trip the original never suffered, which is noise of unknown size sitting exactly
   where the interesting differences between candidate models are.
2. A history row is `(created_at, kind, text, audio_file)`. Nothing records which model,
   engine or language setting produced the text, so the archive cannot answer "what
   transcribed this" two months from now.
3. Glossary normalisation (ADR-0013) will rewrite transcripts before they are pasted. Once it
   ships, `text` is the *corrected* string, and the model's own output — the only thing worth
   measuring, and the source for deriving new replacement rules — is gone.

Point 3 is why this spec ships first, before the glossary work: the column has to exist before
the pass that would otherwise destroy the data.

## Decisions taken

- **Lossless audio is an option, default off.** The user will turn it on; everyone else
  keeps AAC and its 0.35 MB/min.
- **Metadata goes into SQLite**, alongside the history row, not into a sidecar file.
- **Both transcripts are stored** — the raw model output and the text that was pasted.
- **Retention is the user's problem**, solved by setting `.unlimited`. No app change.
- **Export and scoring are out of scope.** Hand-correction will be done ad hoc, and no
  metric is being computed yet. This spec deliberately stops at capture.

## Goals

1. A `Settings` switch that makes saved recordings lossless.
2. Per-entry provenance in `dictation_history`, written at the same moment as the text.
3. A column for the raw transcript, populated once normalisation exists.
4. No change to the default experience, and no schema reset for existing users.

## Non-goals (YAGNI)

- **Export, import, and a manifest format.** Nothing consumes them yet; when correction
  actually begins, what it needs will be known instead of guessed.
- **WER, CER, term recall, normalisation scoring.** Deferred until there is a reference to
  score against.
- **Editing a transcript in the history window.** The reference lives outside the app.
- **Re-transcribing the archive with another model.** A separate feature, and one with a
  privacy edge (an endpoint model would ship the corpus off the machine).
- **Storing the raw Float32 buffer.** See the fidelity discussion below: bit-exactness is
  not what this corpus needs, and it costs 3.5× the bytes.

## Audio format

The recorder produces 16 kHz mono Float32. Three candidates:

| Format | Per minute | Bit-exact vs. the buffer the model saw | Notes |
|---|---|---|---|
| AAC 48 kbit/s (today) | 0.35 MB | no — lossy | ADR-0011 |
| ALAC 16-bit, `.m4a` | 1.11 MB | no — Int16 quantisation | same container, same writer, `AVAudioPlayer` plays it |
| WAV Float32 | 3.84 MB | yes | needs a new encoder path; `WAVEncoder` today emits Int16 |

**Proposal: ALAC 16-bit**, written by the existing `AVAssetWriter` path with
`kAudioFormatAppleLossless` instead of `kAudioFormatMPEG4AAC`, into the same `.m4a`
container.

The honest caveat, stated because "lossless" is being used loosely: ALAC is lossless
compression of *integer* samples, so Float32 → Int16 quantisation still happens. That is a
noise floor around −96 dBFS, far below any microphone's own noise and far below anything an
ASR model responds to. What matters for this corpus is the removal of *lossy codec
artefacts* in the 4–8 kHz band that carry sibilants — the thing ADR-0011 measured and
accepted as a cost. Quantisation does not put anything back that AAC removed.

If bit-exactness ever does matter, Float32 WAV is the only answer, and the decision is
cheap to revisit because the setting is already a format choice rather than a boolean.
That argues for spelling it as an enum from the start:

```swift
enum SavedRecordingFormat: String, Codable, Sendable, CaseIterable {
    case aac        // 48 kbit/s, ~0.35 MB/min — the default
    case lossless   // ALAC 16-bit, ~1.11 MB/min
}
```

rather than `saveRecordingsLossless: Bool`, which would have to be migrated the moment a
third option appears.

Consequences to handle:

- `DictationAudioEncoding.encode` gains the format, or `AACDictationAudioEncoder` becomes
  `DictationAudioEncoder` holding one. The protocol stays the seam; the fake in `Tests/…/Fakes`
  records which format it was asked for.
- The extension stays `.m4a` for both, so `audio_file`, `DictationHistoryController.saveRecording`
  (which names files `\(entry.id).m4a`) and the player need no change, and a user switching
  formats mid-corpus does not end up with two naming schemes. The format of an existing file is
  discoverable from the file itself, not from the row.
- `GeneralTab`'s disk-usage wording quotes AAC's rate; it must state both, and the
  size warning that mentions "its WAV copy and its AAC copy" needs re-reading against the
  new path.
- `ADR-0011` is amended, not replaced: its reasoning for files-not-blobs, `AVAssetWriter`
  and `.m4a` all still hold. Only "AAC always" becomes "AAC by default".

## Schema version 3

Today's schema, read from `SQLiteDictationHistoryStore.connection()`, is version 2:
`id, created_at, kind, text, audio_file`, with `text` carrying `CHECK(length(trim(text)) > 0)`.
Version 0 creates it outright; version 1 migrates by adding `audio_file`; anything above 2 sets
`requiresConfirmedReset`.

Version 3 adds five nullable columns:

```sql
ALTER TABLE dictation_history ADD COLUMN raw_text TEXT;     -- model output before normalisation
ALTER TABLE dictation_history ADD COLUMN model_id TEXT;     -- catalog id, or endpoint model
ALTER TABLE dictation_history ADD COLUMN engine TEXT;       -- 'whisperCpp' | 'sherpaOfflineASR' | 'endpoint'
ALTER TABLE dictation_history ADD COLUMN language TEXT;     -- the requested setting, NULL = auto
ALTER TABLE dictation_history ADD COLUMN app_version TEXT;  -- CFBundleShortVersionString
PRAGMA user_version = 3;
```

All nullable, so rows written before this change stay valid and no reset is needed. The
`version == 0` branch creates them inline; a new `version == 2` branch migrates; the guard
becomes `version >= 0 && version <= 3`. An older build opening a version 3 database still treats
it as unsupported and offers a reset, exactly as ADR-0011 already describes for version 2 — that
behaviour is unchanged, not worsened.

`raw_text` is **NULL when the text was not rewritten**, which today is every row: normalisation
does not exist yet. It is added now so the glossary work needs no schema 4. `text` keeps its
non-empty CHECK and keeps meaning "what was pasted".

`engine` spells `sherpaOfflineASR`, the name ADR-0014 renames `gigaAM` to. Rows written before
that rename will read `gigaAM`; consumers must accept both. This is deliberate — the corpus
records what actually ran.

What is deliberately **not** stored, and why:

- Thread count and the translate flag: they change speed, not what the model recognises
  (translate is pinned false, and surfacing it is a separate change).
- Which glossary packs were enabled. Genuinely useful, and not cheaply knowable at this layer;
  when the glossary exists, a sixth nullable column is the same amount of work then as now.
- The detected language: whisper reports it, but our `TranscriptionProvider` returns a bare
  `String` and widening that protocol is a change with reach far beyond this spec.

The counter-argument for a single `run_metadata TEXT` JSON column is real: every future field
is free, with no migration. It is rejected because querying "group by model" through
`json_extract` on a column with no schema is exactly how the history of "what is actually in
here" gets lost, and because four migrations over the app's lifetime is not a burden.

### Where the values come from

`DictationController.transcribeAndInsert` (`:225`) and `DictationCapture` (`:141`) both call
`history.append(text:kind:)` immediately after the transcriber returns. Both already hold
the settings snapshot that chose the provider. The clean shape is a small value built at the
call site:

```swift
struct TranscriptionRun: Sendable, Equatable {
    let modelID: String?
    let engine: String?
    let language: String?
    let appVersion: String
}
```

passed as `append(text:rawText:kind:run:)`, so the store stays a store and neither controller
grows a dependency on `ModelCatalog`. Deriving it from `TranscriptionSource` is pure and
therefore unit-testable without a recogniser: `.local(modelID:)` yields the catalog entry's
engine, the endpoint case yields `endpoint` plus its configured model name.

`DictationHistoryController.append` currently trims the text and drops empties; it gains
`rawText` and passes both through. `record(text:kind:)`, used where no entry is needed, keeps
its shape with `rawText: nil`.

One subtlety worth a test: `shortDictationInsertsOK` short-circuits to the literal `"OK"`
without running any model (`DictationController.swift:203–206`). Those rows must record no
model, not the model that would have run, or the corpus contains transcripts attributed to a
model that never saw the audio.

## Testing

Written first, per invariant 3.

- `TranscriptionRun` derivation from each `TranscriptionSource` case, including the
  short-dictation path that produces none.
- Schema migration from version 2 to 3: existing rows survive, new columns read as `NULL`,
  and a version 3 database round-trips a row with every field populated.
- Creating schema 3 from an empty database.
- A version 4 database still sets `requiresConfirmedReset`.

There are no released users, so only two arrival paths exist: an empty database, and the
developer's own version 2 database holding the control dictation. Version 1 is untested because
no database was ever written at it.
- `append(text:rawText:kind:run:)` persists and re-reads both texts and the metadata;
  `fetchPage` returns them.
- `rawText: nil` round-trips as NULL and `DictationHistoryEntry.rawText` reads back nil.
- The encoder fake records the requested format; the controller asks for the one in settings.
- `Settings` decodes a document with no `savedRecordingFormat` key to `.aac`, and an
  unknown string to `.aac` rather than throwing — the same `decodeIfPresent` pattern
  `SpeechSettings` uses, so `currentSchemaVersion` does not move.

Smoke tests (`docs/SMOKE_TEST.md`), because the encoder is AVFoundation glue:

- With lossless on, a dictation produces an `.m4a` that `afinfo` reports as Apple Lossless,
  and playback from the history window works.
- Switching the format between two dictations leaves both playable.
- The Settings disk-usage figure tracks the larger files.

## Deliverables

- `Core/Settings.swift` — `SavedRecordingFormat`, decoding, default.
- `Providers/DictationAudioEncoder.swift` — format-aware encoder.
- `Core/DictationHistoryEntry.swift` — `rawText` and the run fields.
- `Services/DictationHistoryStore.swift` — schema 3, migration, widened `append` and `fetchPage`.
- `Features/DictationHistoryController.swift`, `DictationController.swift`,
  `DictationCapture.swift` — build and pass `TranscriptionRun` and `rawText`.
- `UI/Settings/GeneralTab.swift` — the `Recording quality` picker and corrected size wording.
  (The earlier draft said `DictationTab`; the recording controls actually live in `GeneralTab`,
  lines 37–60, beside `Save the original recording` and `Keep history for`.)
- `docs/adr/0011-saved-dictation-audio.md` — amended.
- `docs/SMOKE_TEST.md`, `CHANGELOG.md`.

## Resolved questions

1. **Is the format switch visible, and where?** Visible, in `GeneralTab`, as a
   `Picker("Recording quality")` placed directly under `Save the original recording` and above
   `Keep history for`, carrying the same `.disabled(!SavedAudioModel.recordingToggleIsEnabled(...))`
   guard the toggle already has. Options read `Compressed (AAC, ~0.35 MB/min)` and
   `Lossless (ALAC, ~1.11 MB/min)`, so the cost is in the control rather than in a caption
   nobody reads.

   A separate "corpus" grouping was rejected: it would invent a section for a single control,
   and the setting is not really about corpora — it is about the quality of what is kept, which
   is exactly what the surrounding controls are about. The tab's density is a real cost, paid
   once, for a control whose entire audience needs to find it.

2. **Does a row record the format it was written in?** No column. The file already knows, and
   `AVURLAsset` reads it in one call from whatever eventually exports the corpus — which is
   reading those files anyway. A column would denormalise a fact that can drift: a row claiming
   ALAC next to a file written before the setting changed, or after a failed encode, is worse
   than no claim at all.

   The mixed archive is therefore accepted, and made honest in the one place it matters: the
   `Saved audio: <size>` line already reports real bytes on disk, so a user who switches format
   watches the number grow at the new rate without being told a story about which files are
   which. If per-file format ever needs displaying — in the history window, next to playback —
   it is read from the file at that moment.
