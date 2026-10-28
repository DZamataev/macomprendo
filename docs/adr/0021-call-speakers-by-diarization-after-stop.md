# ADR-0021: A call's far side is split by voice after Stop, by transcribing it again by turn

## Status

Accepted — 2026-10-28.

## Context

A call has two tracks, so `Me` is always known, but everyone on the far side lands in one track,
`Others`. On a five-person grooming the Others text came in blocks of up to 35 seconds that mixed
two or three people. The vendored sherpa-onnx 1.13.4 already ships offline speaker diarization
(pyannote segmentation, a speaker embedding extractor, fast clustering); only the models are new.

Diarization says *when* each voice spoke, but the stored segments are the segmenter's, joined
across voices, and no provider returns word timestamps to cut them by. The candidates:

- **Label each stored segment by the voice that overlaps it most.** Cheap, but a segment holding
  three people gets one name — the problem stays.
- **Return word timestamps from every provider and cut the stored text.** whisper.cpp can, the
  sherpa engines and the endpoint differ; a cross-provider change for one feature.
- **Transcribe the Others track again, one voice's turn at a time.** One more pass of the
  recogniser over one track, and every provider works unchanged.

Diarization clusters the whole recording at once, so it cannot run live.

## Decision

**When a call's tracks are all transcribed, before the row is `complete`, the Others track is
decoded whole, diarized, and transcribed again by turn; the new segments, each with its `voice`,
replace the track's old ones in one store transaction.** Live text stays `Others` until then.
Without the downloaded models, with the setting off, or on any failure but cancellation, the old
segments stay and the call completes as before — a failure says so in the call-finished toast.

## Consequences

- One more recogniser pass over the Others track per call, plus ~4 minutes of CPU per hour of
  audio for diarization, after Stop.
- The whole Others track is held in memory while it is diarized — ~230 MB per hour of call, twice
  that for the moment it is cut into turns.
- sherpa cannot interrupt a running diarization, so a cancelled job stops waiting for it and the
  native work finishes on its own before freeing itself.
- `transcript_segments.voice` (schema 3) is the only schema change; `Speaker N` is derived from it
  wherever a speaker is printed.
- The number of speakers is not asked for: a distance threshold (1.2) decides, measured on one
  recording. A call with very similar voices can come out as fewer speakers than took part.
