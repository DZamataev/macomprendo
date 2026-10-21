# ADR-0020: Live call transcription reads the capture, and Stop finishes it by Resume

## Status

Accepted — 2026-10-21.

## Context

Call recordings were transcribed only after Stop: the Me track, then Others, each through
`LongAudioPipeline` from its `.m4a`. The user wants to read the call while it happens. The audio
reaches the app twice over — as capture buffers on the session clock, and as fragmented AAC files
written a second behind — and every provider is an offline recogniser that takes a finished
segment.

The candidates:

- **A streaming recogniser** (sherpa-onnx online models). Word-by-word text, but a second engine,
  new models, and accuracy well below the whisper and Parakeet models users already chose.
- **Tail the growing `.m4a` files.** No change to capture, but reading a fragmented MP4 that is
  still being written through `AVAsset` means polling, a delay of the fragment interval on top of
  the speech pause, and edge cases at fragment boundaries.
- **Feed the capture buffers to the existing pipeline.** The segmenter is already incremental
  (`accept(chunk)` returns finished segments); the pipeline only needs its audio from a stream
  instead of a decoder. The gap padding that keeps file time equal to call time is already a pure
  `TrackTimeline`.

Separately, a live run has to end somehow at Stop, at quit, and at a crash, and the last two
cannot drain anything.

## Decision

**Live transcription feeds each track's capture buffers, padded by its own `TrackTimeline`,
through `LongAudioPipeline`, one run per track, concurrently, at background lane priority.**

**Stop does not drain the live runs: it stops them and starts the ordinary call Resume**, which
transcribes from the files whatever was not stored. Quit and crash leave a row that the same
Resume finishes later. One path covers all three endings.

**Call Resume becomes per track:** each track continues from the end of its own last stored
segment. The previous rule — continue the last track with segments, treat the ones before it as
done — assumed Me finished before Others started, which concurrent live runs break.

## Consequences

- Text appears per phrase, about `callJoinGap` plus transcription time after the speaker pauses;
  never word by word.
- Capture, files, manifest and store schema are unchanged; the store gains only `setDuration`,
  because the row now exists before the call's length is known.
- The segment in flight at Stop, and any backlog, is transcribed again from the file — wasted work
  bounded by one segment's transcription, plus VAD over the backlog.
- Per-track resume decodes a track again from its last segment even when a sequential run had
  finished it; that track holds no more speech, so it costs VAD time, not transcription.
- The backlog of a model slower than real time is held in memory without a bound.
