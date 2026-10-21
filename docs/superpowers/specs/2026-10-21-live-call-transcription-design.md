# Live call transcription

## Goal

Transcribe a call recording while it is being recorded, so the user can read what was said
during the call in the Transcripts window, and the transcript is ready moments after Stop.
Optional: it is one of three modes of a setting that replaces "transcribe after Stop". This builds
on `2026-10-15-call-recording-design.md` (its *Live transcription later* section planned the hook)
and reuses its capture, files, store, transcription job and Transcripts window.

"Live" means per phrase: a segment appears once its speaker pauses (`callJoinGap`, 1.5 s) and the
model has transcribed it. There is no word-by-word streaming and no partial text inside an
unfinished phrase.

## Vocabulary

- **Live transcription** — transcribing a call's tracks from the capture, during the recording.
- **Live feed** — one track's capture buffers, placed on the session clock exactly as the track
  writer places them, delivered as a stream of sample chunks.
- **Catch-up** — the call job that runs after Stop and transcribes from the track files whatever
  live transcription had not stored yet.
- Everything else (call recording, track, speaker, session clock) as in the call recording spec.

## Behaviour

### The setting

- `Settings.transcribeCallsAfterRecording: Bool` is replaced by
  `Settings.callTranscription: CallTranscriptionMode` with three cases:
  - `whileRecording` — **While recording**: live transcription, then catch-up after Stop.
  - `afterRecording` — **After recording**: today's behaviour with the bool `true`.
  - `manual` — **Manually**: today's behaviour with the bool `false`; the call waits as
    `incomplete` with `notTranscribedYetReason` until **Resume**.
- Default: `afterRecording`. Decoding a stored settings file without `callTranscription` maps
  `transcribeCallsAfterRecording` `true` → `afterRecording`, `false` → `manual`, absent → the
  default. The old key is not written again.
- Settings ▸ General: the **Transcribe a call as soon as it stops** toggle becomes a picker
  **Transcribe calls** with the three options; its caption explains **Manually** as the old
  caption did, and **While recording** as "Text appears in Transcripts during the call. Uses the
  speech model throughout the call."
- Menu panel: the **Transcribe calls after Stop** switch becomes a row with the same three-way
  picker (a `Menu` or segmented control — whichever the panel's existing rows already use for a
  choice; a switch cannot hold three values).
- The mode is read once, at Start. Changing it during a recording affects the next recording.
- Automatic call recording uses the same setting and behaves identically.

### While recording

- At Start, once capture is up, the transcript row is created **at once** — `source_kind = call`,
  the same title, bookmark and `run` as today, no `duration_s` yet, status `inProgress`. The other
  two modes keep creating the row at Stop, unchanged.
- If that row cannot be created, the recording goes on without live text and behaves as
  **After recording** from then on; the failure is logged. Nothing is shown — the user loses only
  the live view.
- Each track (Me, Others) gets its own live feed and its own `LongAudioPipeline` run, fed from the
  live feed instead of a file. The two run concurrently; both obtain their provider through the
  background transcriber (`TranscriptionLane` priority `.background`), so a dictation overtakes
  them exactly as it overtakes file segments today.
- Every segment is shifted by its track's `startOffset`, labelled with its speaker, appended to the
  row with `appendSegment`, and announced with `transcriptsChanged()`. `TranscriptLibraryController.reload()`
  already re-reads the open transcript, so the Transcripts window shows each new segment, ordered
  by `start_s` across both sides.
- **Show Live Transcript** sits in the menu panel while recording in this mode, under the level rows:
  it opens the Transcripts window with the call's transcript selected.
- If the model is slower than real time, segments wait in memory and the text falls behind the
  call. Nothing is dropped.
- A live pipeline that fails (provider error after its retries, segmenter error) ends for that
  track only: the recording continues, the failure is logged at default level without any text,
  and catch-up transcribes the track after Stop. No toast, no new `MacomprendoError`.
- A track that never produces audio (Others with the System Audio grant declined still produces
  silence) simply yields no segments.
- While the row is `inProgress`, the Transcripts window offers no **Delete**, **Resume** or
  **Transcribe Again** for it — the existing rules for a running job.

### Stop

In `whileRecording`, Stop does, in order:

1. Stop capture; finish both live feeds and both writers.
2. Stop both live pipelines and await them (`stop()` + `awaitCompletion()`): the segment being
   transcribed at that instant is abandoned, everything already stored stays.
3. Write `startOffset`s and `duration_s` (new store method `setDuration(_:for:)`), mark the
   manifest `finished`.
4. Start catch-up: `FileTranscriptionController.resume(transcriptID:)`, the same call
   `afterRecording` makes today. The progress text, the "Call transcript ready" toast, failures
   and `noSpeechFound` behave as for any call job.

Abandoning the in-flight segment and the backlog instead of draining them keeps one path for
Stop, quit and crash; catch-up re-reads that audio from the files.

### Catch-up: resume per track

`CallTranscriptionPlan.steps` changes from "resume the last track that has segments; the tracks
before it are done" to **each track resumes from the end of its own last stored segment, or from 0
when it has none**. Live transcription stores both tracks concurrently, so neither is "done" when
the other has segments.

- A track with no `startOffset` is still skipped.
- The cost: after a sequential run interrupted in Others, Me is decoded again from the end of its
  last segment — VAD over the rest of Me, which holds no speech — seconds, not a re-transcription.
- The same rule applies to every call Resume: `afterRecording`, `manual` and recovered calls all
  go through it.

### Quit and crash

- Quit while recording in `whileRecording`: Stop's steps 1–3, then the row is set `incomplete`
  with `abandonedJobReason`, exactly as today; no catch-up. **Resume** later catches up per track.
- Crash: the row already exists and points at the folder, so launch recovery finalises the
  manifest and creates no second row; `markAbandonedJobs` turns the `inProgress` row
  `incomplete`. It has no `duration_s` — the list shows none for it; accepted.

## Architecture

Layers keep pointing downward; every concrete service is built in `AppEnvironment`.

| Layer | Unit | Role |
|---|---|---|
| Core | `CallTranscriptionMode` | `whileRecording` / `afterRecording` / `manual`; `Settings.callTranscription` and the decode-time migration |
| Services | `LiveTrackFeed` | A `CallAudioSink`: pads gaps with its own `TrackTimeline` (same `sessionStart`, same arithmetic as the writer), resamples 48 kHz → 16 kHz with `PCMResampler` (the resampler dictation uses), yields chunks into an unbounded stream exposed as a `DecodedAudio`; `finish()` ends the stream |
| Services | `TranscriptStoring.setDuration(_:for:)` | Writes `duration_s` |
| Features | `LongAudioPipeline` | A second `run` takes an already open `DecodedAudio` (a live feed) instead of a URL. Segmentation, retries and offsets are shared |
| Features | `LiveCallTranscriber` | Two pipeline runs → `appendSegment` + `transcriptsChanged`; `stop()` / `awaitCompletion()` |
| Features | `CallRecordingController` | Reads the mode at Start; in `whileRecording` creates the row, fans each capture handler out to writer and live feed, owns the `LiveCallTranscriber`, runs Stop as above |
| Features | `CallTranscriptionPlan` | Per-track resume |
| UI | Settings ▸ General picker, menu panel picker, **Show Live Transcript** | |

The capture handler already holds one writer per track; it calls `consume` on the writer and the
feed in turn — no general sink array. The handler runs on the audio thread: `LiveTrackFeed.consume`
does the `TrackTimeline` arithmetic, the padding, the resampling of one chunk and one
`continuation.yield`, under its own lock.

A live run emits `opened(duration: 0)` and `position` events like a file run; `LiveCallTranscriber`
ignores everything but segments.

## Privacy

Unchanged from call recording: audio leaves the machine only to the transcription endpoint the
user configured, segment by segment. No transcript text is logged at default level.

## Testing

Unit tests (swift-testing, written first), with fakes for every new protocol:

- `CallTranscriptionMode` migration: `true` → `afterRecording`, `false` → `manual`, absent →
  default, new key wins over old.
- `LiveTrackFeed`: a 2 s hole yields 2 s of zeros, a 30 ms hole does not, `startOffset` matches a
  writer fed the same chunks, `finish()` ends the stream.
- `LongAudioPipeline` from a chunk source: the same chunks as a fake decoder produces the same
  segments and offsets.
- `CallTranscriptionPlan`: both tracks with segments resume each from its own end; a track
  without segments runs from 0; a track without `startOffset` is skipped; the old
  sequential-interrupted cases now re-run Me from its last end.
- `LiveCallTranscriber`: segments from both tracks reach the store with speaker and offset; one
  track failing leaves the other running; `stop()` then `awaitCompletion()` releases the provider.
- `CallRecordingController`, mode `whileRecording`: the row is created at Start with
  `inProgress`; Stop stops the live run before starting catch-up and sets the duration; quit
  leaves `incomplete` and no catch-up; `afterRecording` and `manual` unchanged.
- `SQLiteTranscriptStore.setDuration` round trip.

`docs/SMOKE_TEST.md` gains a live-call pass on real hardware: a call through speakers, text in the
Transcripts window within a few seconds of each phrase, a dictation during the call not slowed
noticeably, Stop finishing with the full transcript.

## Out of scope

- A floating subtitle panel.
- Word-by-word streaming recognition (a different engine and models).
- A bound on the in-memory backlog. A model at half real time over an hour of continuous speech
  holds roughly 30 minutes of 48 kHz mono samples — about 350 MB. Add a cap (stop the live run
  for that track, catch-up covers it) if this is seen in practice.
