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
  from the start of the source, its normalised `text`, and `rawText` — the recogniser's own
  words, kept only when normalisation rewrote them (`nil` otherwise, as in dictation history).
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
- A failure is shown only for the job it belongs to (or a job with no row yet) and clears when
  another transcript is selected. A new job's row appears as soon as it starts; a finished job is
  selected.
- Actions on the selected transcript: `Copy` (plain text without timestamps), `Export…` with
  `.txt`, `.srt`, `.md`, `Summarize`, `Resume` (only when `incomplete`), `Delete` (confirmed).
- With no transcripts, the detail is a drop zone: `Drop an audio or video file here`.

### Pipeline

1. **Preflight.** The controller checks transcription readiness via `BackendReadiness`; a
   backend that is not ready fails the job with its reason before any decoding starts. The VAD
   model is bundled, so there is nothing to download.
2. **Decode.** `MediaAudioDecoding` reads the first audio track with `AVAssetReader`, converts it
   to 16 kHz mono `Float` PCM and yields it in chunks, together with the asset duration. The
   whole file is never held in memory.
3. **Segment.** `SpeechSegmenting` consumes the PCM stream and yields segments of at most
   35 seconds. VAD does not filter speech; it decides only what to drop and where to cut:
   - speech regions closer than 10 s are joined into one span **with the audio between them**,
     so speech the detector misses (a phrase over music) and a word at a short pause still reach
     the recogniser with its context;
   - each span is padded by 0.3 s on both sides (clamped to the stream);
   - non-speech longer than 10 s is dropped, so silence or music alone never reaches the
     recogniser and cannot make it invent words;
   - a span is split only when it is longer than 35 s (the 30 s cap plus a 5 s minimum
     remainder); the cut is the quietest 20 ms frame of the last 5 seconds before 30 s (the latest
     such frame on a tie), so neither piece is shorter than 5 s and no piece is longer than 35 s.
     Pieces shorter than 0.3 s are dropped. whisper.cpp slides its own 30 s window over longer
     input; the sherpa-onnx models take any length.
   - Why the 5 s remainder: a 32.6 s span at the end of a 75-minute interview was cut at 29.7 s;
     the 2.9 s remainder held only padding, outro music and a 0.84 s VAD blip, and whisper
     large-v3-turbo wrote "Субтитры сделал DimaTorzok" for it. whisper.cpp v1.9.2 reported a
     no-speech probability of 0.000 for that segment and for every real one, so a no-speech
     threshold cannot catch it; `suppress_nst` did not change the output.
   Silero's own `max_speech_duration` does not cap length: probed on 70 s of continuous speech it
   returned one 70 s segment with the limit at 25 s and at 10 s.

   Measured on a 78 s Russian voice-over with music (whisper large-v3-turbo): passing VAD
   regions alone lost "Да, как вы поняли" (spoken over music, outside every region) and
   "сторону" (a 0.17 s pause split the phrase); the joined, padded spans recovered both.
   Cost: subtitle cues in `.srt` are as long as segments, up to 35 s.
4. **Transcribe.** Each segment goes, in order, to the existing `TranscriptionProvider` — the
   protocol does not change. Remote endpoints receive each segment as its own WAV request, so the
   OpenAI 25 MB upload limit is never approached.
5. **Normalise.** Each segment's text passes through the glossary `Normalizer` exactly as a
   dictation does, when the glossary is enabled. A segment whose text is empty after trimming
   is not stored.
6. **Store.** The transcript row is created with status `inProgress` once the file has opened
   (so an unreadable file leaves no row); each segment is appended as soon as it is transcribed. When the last segment lands the status becomes
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
  reports `sourceFileUnavailable` and shows **Choose File…**; the chosen file resumes from the same
  position and becomes the transcript's new bookmark.
- At launch, before any job can start, every transcript still `inProgress` (the app was
  killed) becomes `incomplete` with the reason `Macomprendo quit before it finished.`

### Summary

- `Summarize` opens the ordinary Summarize Quick Panel — the one the hotkey opens — with the
  transcript's plain text (no timestamps): the Summarize feature's LLM (Settings ▸ Refine &
  Summarize), its presets and preset picker, rerun and Copy. **Replace selection** is hidden for a
  panel opened this way, since no other app holds a selection.
- The whole text goes in one request. Measured on Ollama 0.40.3 with `qwen2.5:1.5b`, 78k
  characters of Russian (~10.6k words, 28,299 tokens) were accepted whole at the default context.
  Splitting long text into parts belongs to the panel itself, not to this window
  (issue #24).
- Summaries are not stored. The store keeps its `summary` column and the Markdown export its
  Summary section, dormant, for call recording.

### Export

- `.txt` — segment texts joined by newlines, no timestamps.
- `.srt` — one cue per segment, numbered from 1, `HH:MM:SS,mmm --> HH:MM:SS,mmm`.
- `.md` — a `#` title with the file name, a metadata line (date, duration, model), a stored
  summary under `## Summary` when present (none is stored today), then `## Transcript` with
  `**[hh:mm:ss]** text` lines.

### Errors

New `MacomprendoError` cases, each with `errorDescription` and `recoverySuggestion`:

- `mediaUnreadable` — AVFoundation cannot open the file or it is DRM-protected.
- `noAudioTrack` — the file has no audio track.
- `noSpeechFound` — VAD found no speech in the whole source.
- `sourceFileUnavailable` — `Resume` cannot resolve the stored bookmark.
- `transcriptStore` — the transcripts database cannot be opened or written.
- `exportFailed` — an export could not be written.
- `speechDetector` — the bundled VAD model is missing or sherpa-onnx rejects it.

## Architecture

Layers keep pointing downward (UI → Features → Services/Providers → Core); every concrete
service is built in `AppEnvironment`.

| Layer | Unit | Role |
|---|---|---|
| Core | `Transcript`, `TranscriptSegment`, `TranscriptSource`, `TranscriptStatus` | Value types; reuse `TranscriptionRun` |
| Core | `TranscriptExporter` | Pure `Transcript` → txt / srt / md |
| Services | `MediaAudioDecoding` / `AVAssetMediaDecoder` | File → `AsyncThrowingStream` of 16 kHz mono PCM + duration |
| Services | `SpeechSegmenting` / `SherpaSileroSegmenter` | PCM stream → segments; the split rule (cut at 30 s, split above 35 s) lives in a pure helper |
| Services | `TranscriptStoring` / `SQLiteTranscriptStore` | Actor; `~/Library/Application Support/Macomprendo/transcripts.sqlite3` |
| Services | `SpeechSegmentSplitter` | Pure 30 s cut point, 35 s split threshold, 0.3 s floor |
| Services | `FileBookmarking` / `FoundationFileBookmarks` | Bookmark a source file, resolve it on `Resume` |
| Providers | `TranscriptionLane` | Serialises local-model calls; a waiting dictation goes before a waiting file segment |
| Features | `LongAudioPipeline` | Decode → segment → transcribe with retries, as a stream of events |
| Features | `FileTranscriptionController` | `@MainActor`; `idle → running(progress) → finished(id) / failed(message)` |
| Features | `TranscriptLibraryController` | `@MainActor`; list, selection, delete, copy, export text |
| UI | `TranscriptsView`, menu item | List, detail, drop zone, progress, actions |

### Store schema

- `transcripts(id, source_kind, title, source_bookmark, duration_s, status, status_reason,
  model_id, engine, language, app_version, summary, created_at)`
- `transcript_segments(id, transcript_id, start_s, end_s, raw_text, text)`, indexed by
  `(transcript_id, start_s)`, deleted with their transcript.

Transcripts are kept until the user deletes them; dictation-history retention does not apply.

### VAD model

`silero_vad.onnx` from the sherpa-onnx `asr-models` release (643,854 bytes, SHA-256
`9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6`), **bundled** in
`Resources/SpeechDetection`. Bundling replaced the first draft's on-demand download: a catalog
entry would have needed a third `ModelKind`, which every `ModelCatalog.all` consumer and the
exhaustive engine switches in `ProviderFactory`, `SherpaTTSService` and `DictationTabModel`
would have had to learn, for a file smaller than one app icon set. Silero VAD is MIT; it gets a
`LicenseRegistry` entry, its text in `Resources/Licenses`, and a `NOTICE` row.

## Privacy

- No transcript or summary text is logged at default level (invariant 6).
- Audio leaves the machine only to the transcription endpoint the user configured; transcript
  text only to the configured LLM, and only on `Summarize`.

## Testing

Unit tests (swift-testing, written first), with fakes for every new protocol:

- `TranscriptExporter`: SRT numbering and `HH:MM:SS,mmm` formatting past one hour, empty
  transcript, Markdown with and without a summary.
- Segment rule: regions closer than 10 s join with the gap audio kept, spans are padded 0.3 s,
  non-speech over 10 s is dropped, ≤ 35 s passes through, longer spans split at the quietest
  frame of the 5 s before 30 s (both pieces ≥ 5 s), sub-0.3 s pieces drop, offsets are seconds from the source start.
- An opt-in regression test on a real recording (`MACOMPRENDO_LONG_AUDIO_FIXTURE` = audio path,
  `MACOMPRENDO_LONG_AUDIO_EXPECT` = a file of phrases, one per line) runs the real decoder,
  segmenter and local whisper model and requires every phrase in the transcript. The recording
  stays outside the repository.
- `FileTranscriptionController`: state order and progress; normalisation per segment; cancel
  keeps segments and marks `incomplete`; a new job cancels the running one; retry twice then
  `incomplete`; resume starts from the last segment end; `noSpeechFound` deletes the transcript;
  a backend that is not ready stops in preflight, for a new job and for `Resume`.
- `SQLiteTranscriptStore`: incremental append, status transitions, `inProgress` → `incomplete`
  at open, cascade delete, newest-first listing.
- Priority hand-off: with a file job running, a dictation request is served before the next
  file segment.
- `SummarizeController` opened from the window hides Replace selection; the hotkey path keeps it.
- `Resume` with a newly chosen file resumes from the stored position and replaces the bookmark.

`docs/SMOKE_TEST.md` gains: mp3, m4a and an mp4 with video; a video without an audio track; a
one-hour podcast (memory stays flat, progress advances); dictating while a file transcribes;
each of the three transcription backends; resume after quitting mid-job.

## Documents

- ADR `0015-long-audio-segmentation-with-silero-vad.md` (bundled model, own split rule: cut at
  30 s, split above 35 s).
- ADR `0016-transcripts-store-separate-from-dictation-history.md`.
- `docs/ARCHITECTURE.md` gains a *Long-audio transcription* section.
- `CHANGELOG.md` `Unreleased`: file transcription, Transcripts window, summary.

## Out of scope

- Call recording (sub-project 2).
- Speaker diarisation, word-level timestamps, Finder `Open With` / Services entry points,
  batch queues of several files, editing transcript text, and playback synced to segments.
