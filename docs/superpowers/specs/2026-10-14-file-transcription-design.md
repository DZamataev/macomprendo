# File transcription

## Goal

Let the user transcribe any audio or video file — a podcast, a lecture, a recorded meeting —
with the transcription backend they already configured, read the result with timestamps, export
it, and summarise it. This is the first of two sub-projects; the second, call recording, records
microphone and system audio and feeds the recording through the same long-audio pipeline and
store.

## Vocabulary

- **Transcript** — the persisted result of transcribing one long recording. It has a source
  (`file` now, `call` later), a status, segments and an optional summary. Distinct from a
  *dictation history entry*: transcripts live in their own store.
- **Segment** — one stretch of speech found by the VAD, with `start`/`end` offsets in seconds
  from the start of the source, its `rawText` and its normalised `text`.
- **VAD** — voice activity detection: Silero VAD running through the vendored sherpa-onnx C API
  (`SherpaOnnxVoiceActivityDetector`). It decides where speech is, so silence and music are
  never sent to the recogniser.
- **Long-audio pipeline** — decode → segment → transcribe each segment → normalise → store.

## Behaviour

### Entry points

- The menu gains `Transcribe File…`, which opens an `NSOpenPanel` filtered to
  `UTType.audiovisualContent`, then opens the Transcripts window and starts the job.
- The Transcripts window accepts a dropped file anywhere in its content and starts the job.
- Starting a job while another runs cancels the running one; the cancelled transcript keeps what
  it had and becomes `incomplete` (see *Interruption*).

### Transcripts window

- A single SwiftUI `Window` (`WindowID.transcripts`), opened from the menu. While it is open
  `DockIconCoordinator` keeps the Dock icon visible, as for Dictation History.
- Left: the list of transcripts, newest first — title (file name), date, duration, and a badge
  for `inProgress` or `incomplete`. Right: the selected transcript.
- The detail shows segments as rows `[hh:mm:ss] text`, the `TranscriptionRun` (model, engine,
  language) and, while a job runs, progress `Transcribing — 12:40 / 58:03` with a Cancel button.
- Actions on the selected transcript: `Copy` (plain text without timestamps), `Export…` with
  `.txt`, `.srt`, `.md`, `Summarize`, `Resume` (only when `incomplete`), `Delete` (confirmed).
- With no transcripts, the detail is a drop zone: `Drop an audio or video file here`.

### Pipeline

1. **Preflight.** The controller checks transcription readiness via `BackendReadiness`, and that
   the VAD model is installed. A missing VAD model shows the download offer before any decoding
   starts; the job begins once the download finishes.
2. **Decode.** `MediaAudioDecoding` reads the first audio track with `AVAssetReader`, converts it
   to 16 kHz mono `Float` PCM and yields it in chunks, together with the asset duration. The
   whole file is never held in memory.
3. **Segment.** `SpeechSegmenting` consumes the PCM stream and yields segments of at most
   30 seconds. A longer stretch of continuous speech is split at the quietest point of its last
   5 seconds. Segments shorter than 0.3 s are dropped.
4. **Transcribe.** Each segment goes, in order, to the existing `TranscriptionProvider` — the
   protocol does not change. Remote endpoints receive each segment as its own WAV request, so the
   OpenAI 25 MB upload limit is never approached.
5. **Normalise.** Each segment's text passes through the glossary `Normalizer` exactly as a
   dictation does; `rawText` keeps the recogniser output.
6. **Store.** The transcript row is created at step 1 with status `inProgress`; each segment is
   appended as soon as it is transcribed. When the last segment lands the status becomes
   `complete`.

A source with no speech at all fails as `noSpeechFound`, and the empty transcript is deleted.

### Sharing the local model with dictation

The local model is a single instance in `LocalTranscriptionProviderCache`. Dictation outranks
file transcription: the file pipeline acquires the model for one segment at a time, and a
waiting dictation request is served before the pipeline's next segment. A dictation therefore
waits for at most one in-flight segment, never for the file. File jobs are not cancelled by
dictation.

### Interruption and resume

- Cancel, a newer job, app quit, or a segment that fails after two retries stops the job. Stored
  segments stay; the transcript becomes `incomplete` with the reason, which never contains API
  keys or transcript text.
- The transcript stores a bookmark to its source file. `Resume` re-decodes the source from the
  `end` of the last stored segment and appends. If the bookmark no longer resolves, `Resume`
  reports `sourceFileUnavailable` and offers to pick the file again.
- A transcript found `inProgress` at launch (the app was killed) is shown as `incomplete`.

### Summary

- `Summarize` uses the configured LLM through the existing `LLMProvider`, streaming into the
  detail pane like `SummarizeController` does, with a new prompt preset `transcriptSummary` in
  every factory language.
- Transcript text up to 12,000 characters is summarised in one request. Longer text is split on
  segment boundaries into parts of at most 12,000 characters; each part is summarised, then the
  part summaries are summarised into one.
- The finished summary is stored with the transcript and shown above the segments;
  `Summarize` on a transcript that has one regenerates it. Cancelling leaves the previous
  summary.

### Export

- `.txt` — segment texts joined by newlines, no timestamps.
- `.srt` — one cue per segment, numbered from 1, `HH:MM:SS,mmm --> HH:MM:SS,mmm`.
- `.md` — a `#` title with the file name, a metadata line (date, duration, model), the summary
  under `## Summary` when present, then `## Transcript` with `**[hh:mm:ss]** text` lines.

### Errors

New `MacomprendoError` cases, each with `errorDescription` and `recoverySuggestion`:

- `mediaUnreadable` — AVFoundation cannot open the file or it is DRM-protected.
- `noAudioTrack` — the file has no audio track.
- `vadModelMissing` — the VAD model is not installed; recovery offers the download.
- `noSpeechFound` — VAD found no speech in the whole source.
- `sourceFileUnavailable` — `Resume` cannot resolve the stored bookmark.

## Architecture

Layers keep pointing downward (UI → Features → Services/Providers → Core); every concrete
service is built in `AppEnvironment`.

| Layer | Unit | Role |
|---|---|---|
| Core | `Transcript`, `TranscriptSegment`, `TranscriptSource`, `TranscriptStatus` | Value types; reuse `TranscriptionRun` |
| Core | `TranscriptExporter` | Pure `Transcript` → txt / srt / md |
| Core | `TranscriptChunker` | Pure split of transcript text into ≤ 12,000-character parts on segment boundaries |
| Services | `MediaAudioDecoding` / `AVAssetMediaDecoder` | File → `AsyncThrowingStream` of 16 kHz mono PCM + duration |
| Services | `SpeechSegmenting` / `SherpaSileroSegmenter` | PCM stream → segments; the 30 s split rule lives in a pure helper |
| Services | `TranscriptStoring` / `SQLiteTranscriptStore` | Actor; `~/Library/Application Support/Macomprendo/transcripts.sqlite3` |
| Services | `ModelCatalog` | New `ModelKind.vad`, engine `sherpaSileroVAD`, file role `vadModel` |
| Providers | `LocalTranscriptionProviderCache` | Gains the priority hand-off between dictation and file segments |
| Features | `FileTranscriptionController` | `@MainActor`; `idle → preflight → transcribing(progress) → finished(id) / failed(error)` |
| Features | `TranscriptSummaryController` | `@MainActor`; single or multi-part summary, one in-flight task |
| Features | `FactoryPresets` | `transcriptSummary` preset per language |
| UI | `TranscriptsWindow`, menu item | List, detail, drop zone, progress, actions |

### Store schema

- `transcripts(id, source_kind, title, source_bookmark, duration_s, status, status_reason,
  model_id, engine, language, app_version, summary, created_at)`
- `transcript_segments(id, transcript_id, start_s, end_s, raw_text, text)`, indexed by
  `(transcript_id, start_s)`, deleted with their transcript.

Transcripts are kept until the user deletes them; dictation-history retention does not apply.

### VAD model

The Silero VAD ONNX model from the sherpa-onnx `asr-models` release, downloaded on demand through
`ModelManager` like every other model, with its SHA-256 recorded in the catalog. It is not
bundled. Silero VAD is MIT-licensed; it gets an entry in `LicenseRegistry` and its text in
`Resources/Licenses` because the app downloads and runs it.

## Privacy

- No transcript or summary text is logged at default level (invariant 6).
- Audio leaves the machine only to the transcription endpoint the user configured; transcript
  text only to the configured LLM, and only on `Summarize`.

## Testing

Unit tests (swift-testing, written first), with fakes for every new protocol:

- `TranscriptExporter`: SRT numbering and `HH:MM:SS,mmm` formatting past one hour, empty
  transcript, Markdown with and without a summary.
- `TranscriptChunker`: short text is one part, parts never split a segment, a single segment
  longer than the limit becomes its own part.
- Segment split rule: ≤ 30 s passes through, longer speech splits at the quietest point of its
  last 5 s, sub-0.3 s segments drop, offsets are seconds from the source start.
- `FileTranscriptionController`: state order and progress; normalisation per segment; cancel
  keeps segments and marks `incomplete`; a new job cancels the running one; retry twice then
  `incomplete`; resume starts from the last segment end; `noSpeechFound` deletes the transcript;
  missing VAD model stops in preflight.
- `SQLiteTranscriptStore`: incremental append, status transitions, `inProgress` → `incomplete`
  at open, cascade delete, newest-first listing.
- `TranscriptSummaryController`: one request below the limit, map then reduce above it,
  cancellation keeps the previous summary.
- Priority hand-off: with a file job running, a dictation request is served before the next
  file segment.

`docs/SMOKE_TEST.md` gains: mp3, m4a and an mp4 with video; a video without an audio track; a
one-hour podcast (memory stays flat, progress advances); dictating while a file transcribes;
each of the three transcription backends; resume after quitting mid-job.

## Documents

- ADR `0015-long-audio-segmentation-with-silero-vad.md`.
- ADR `0016-transcripts-store-separate-from-dictation-history.md`.
- `docs/ARCHITECTURE.md` gains a *Long-audio transcription* section.
- `CHANGELOG.md` `Unreleased`: file transcription, Transcripts window, summary.

## Out of scope

- Call recording (sub-project 2).
- Speaker diarisation, word-level timestamps, Finder `Open With` / Services entry points,
  batch queues of several files, editing transcript text, and playback synced to segments.
