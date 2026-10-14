# ADR-0016: Transcripts live in their own store, apart from dictation history

## Status

Accepted — 2026-10-14.

## Context

A transcript and a dictation-history entry look similar — both hold text the recogniser produced —
but they are different things. A dictation entry is a flat text row written at one of two
microphone commit points, capped at 100,000 records and aged out by a setting. A transcript holds
segments with `start`/`end` offsets that arrive one at a time as a long job runs, a status that
moves `inProgress → complete` or `incomplete`, a source bookmark so it can be resumed, a source
kind, a duration and the run that produced it. Its lifecycle differs too: it is kept until the user
deletes it, whether or not any preference is on, and it is built to survive the app dying mid-job.

## Decision

**A separate database.** Transcripts live in
`~/Library/Application Support/Macomprendo/transcripts.sqlite3`, next to (not inside)
`dictation-history.sqlite3`:

- `transcripts(id, source_kind, title, source_bookmark, duration_s, status, status_reason,
  model_id, engine, language, app_version, summary, created_at)`
- `transcript_segments(id, transcript_id, start_s, end_s, raw_text, text)`, indexed by
  `(transcript_id, start_s)` and deleted with their transcript through `ON DELETE CASCADE`.

**`source_kind` is reserved for `call`.** `TranscriptSourceKind` has `file` and `call`, and the
schema's `CHECK` allows exactly those two; nothing writes `call` yet. Call recording, the follow-on
sub-project, stores into the same table, so the store lands once.

**No retention.** Dictation history drops entries by age and by the 100,000-record cap; transcripts
are kept until the user deletes them. Deleting a transcript deletes its segments with it and leaves
the source file alone.

**Interrupted jobs are repaired at launch.** `markAbandonedJobs` turns every `inProgress` row into
`incomplete` with the reason `Macomprendo quit before it finished.`, before any job can start
(`TranscriptLibraryController.performLaunchMaintenance`, kicked off first thing in
`AppModel.start()`). A job the app was killed during therefore reads the same as a clean quit.

**A clean quit stops the job first.** `FileTranscriptionController.shutdown()` cancels the running
job and awaits it — its pipeline task included — and leaves the row `incomplete` with the abandoned
reason rather than `Cancelled.`. `AppModel.shutdown()` then does the same for an in-flight
dictation and finally drops the local-model cache. That order frees the file's provider, and with
it the whisper context, before the cache drops the model: a native context still alive at process
exit aborts in whisper.cpp v1.9.2's ggml-metal static destructor, so quitting mid-job would
otherwise abort the app instead of exiting (ADR-0015's memory note explains why the provider is
held that long).

**`Resume` can be pointed at the file again.** `setSourceBookmark` replaces the row's bookmark when
the user chooses the source file again after the stored bookmark stopped resolving. The chosen file
becomes the bookmark before decoding starts, so a job that fails later still leaves `Resume` a
bookmark that resolves, and the next `Resume` finds the file.

## Consequences

- The two stores share no schema, no retention rule and no migration. Dictation history's cap and
  age retention never touch transcripts, and a dictation setting cannot shorten a transcript's
  life.
- The `summary` column is dormant. `Summarize` opens the ordinary Summarize Quick Panel with the
  transcript's plain text instead of running an in-app summary job, so nothing writes the column;
  `setSummary`, the column and the Markdown export's `## Summary` section stay for call recording,
  which will have somewhere to keep a summary.
- A transcript store failure is `MacomprendoError.transcriptStore`, separate from any history
  error, so the two can fail independently.
