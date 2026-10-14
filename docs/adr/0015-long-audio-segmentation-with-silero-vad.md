# ADR-0015: Segmentation joins nearby speech, and the VAD model is bundled

## Status

Accepted — 2026-10-14. Amended 2026-10-14: a span is split only above 35 s (see *Amendment*
below); the 30 s cut itself is unchanged.

## Context

A long recording cannot go to the recogniser as one request. A local model transcribes a bounded
stretch at a time, a remote endpoint caps an upload at 25 MB, and an hour of audio is far past
either. Something has to find the speech and cut the file into segments. Silero VAD, run through
the vendored sherpa-onnx C API (`SherpaOnnxVoiceActivityDetector`), decides where the speech is.

Two questions had to be settled: whether the VAD model is downloaded from the catalog like the ASR
and TTS models, and what counts as one segment.

## Decision

**The model is bundled, not downloaded.** `silero_vad.onnx` from the sherpa-onnx `asr-models`
release (643,854 bytes, SHA-256
`9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6`) ships in
`Resources/SpeechDetection`. There is nothing to download and no readiness state of its own. A
catalog entry would have added a third `ModelKind` (today `asr` and `tts` only), which every
`ModelCatalog.all(kind:)` caller and the switches over model kind in `ProviderFactory`, the
sherpa TTS service and `DictationTabModel` would have had to learn, for a file smaller than one app
icon set. Silero VAD is MIT: it has a `LicenseRegistry` entry, its text in
`Resources/Licenses/silero-vad.txt`, and a `NOTICE` row.

**The VAD is a cutter, not a filter.** It decides what to drop and where to cut; it does not define
the recogniser's input on its own. Two pure types hold the rules — `SpeechSpanAssembler` (join,
pad, cap, drop) and `SpeechSegmentSplitter` (the cap and the floor) — and the detector session
(`SherpaSileroSession`) only feeds them:

- speech regions closer than **10 s** join into one span, **with the audio between them kept**;
- a span is padded by **0.3 s** on both sides, clamped to the stream, plus a lookback for the
  detector's backdated onset;
- non-speech longer than **10 s** is dropped, so silence or music alone never reaches the
  recogniser and cannot make it invent words;
- a span longer than **30 s** is cut at the quietest 20 ms frame of its last 5 seconds before the
  cap (the latest such frame on a tie); the remainder stays open and is cut again as needed, and
  pieces shorter than **0.3 s** are dropped;
- **every open span is cut at the cap as it grows**, whether a completed region backs it or the
  detector is still reporting it, so a region the detector never closes cannot grow the buffer.

`sherpa-onnx` (v1.13.4) backdates a region's start by `2 · window_size + min_speech_duration`
samples behind the first window the model calls speech (`voice-activity-detector.cc`,
`AcceptWaveform`). With the bundled v4 model (whose `window_overlap` is 0) and the session's
`window_size` 512 and `min_speech_duration` 0.25 s, that is **5,024 samples** (about 0.31 s). The
assembler keeps that, plus the leading padding — 9,824 samples, about 0.61 s — behind the current
speech run, so a span starts at the padded region start instead of inside it, which would clip the
speech onset.

## Measured failures that forced each rule

- **Silero's own `max_speech_duration` does not cap length.** Probed on 70 s of continuous speech,
  it returned one 70 s segment with the limit set at 25 s and again at 10 s: the setting only
  raises the threshold at which the model *encourages* a split. The cap therefore lives in
  `SpeechSegmentSplitter`, and the session still passes the same 30 s value as a hint.
- **Passing the VAD's regions alone lost words.** On a 78 s Russian voice-over with music
  (whisper large-v3-turbo), the phrase «Да, как вы поняли» was spoken over music, outside every
  region the detector reported, and «сторону» was cut off by a 0.17 s pause the detector treated as
  a split. Joining regions within 10 s with the audio between them, and padding each span,
  recovered both. The cost is that a subtitle cue is as long as a segment, up to 30 s.

## Memory

The assembler is bounded. While the detector is inside speech, `retainedSampleCount` never exceeds
one `maximumDuration` plus the splitter's 5 s search window plus the lookback, about **35.6 s** at
16 kHz, with at most one chunk of overshoot; a span stays open for at most `joinGap` past its end,
so no more than 10 s of silence is retained on top. The detector keeps **its own copy** of the open
region, which the assembler does not control: v1.13.4's `CircularBuffer::Push` doubles its capacity
when it overflows ("No data loss!"), so that copy grows with the region and the app cannot bound it
without resetting the detector.

## Consequences

- The `TranscriptionProvider` protocol is unchanged. Each segment is one request; a remote endpoint
  receives each as its own WAV upload, so the 25 MB limit is never approached.
- `MacomprendoError.speechDetector` fails only when the bundled file is missing or sherpa rejects
  it, so its recovery text is "reinstall", not "download the model".
- Because the rules live in pure types fed by the session, they are unit-tested without the
  detector; the detector itself and the bundled model are covered by `docs/SMOKE_TEST.md` and the
  opt-in `LongAudioRecordingTests`.
- Subtitle cues are segment-length, not word-length, because the recogniser's timestamps are not
  exposed through `TranscriptionProvider`.

## Amendment — 2026-10-14 (issue #25)

The rule above cut **every** span longer than 30 s, and the remainder could be arbitrarily short.
The measurement that forced this amendment: at the end of the 74.9-minute interview a 32.6 s span
was cut at 29.7 s; the 2.9 s remainder held only span padding, outro music and a 0.84 s VAD blip,
and whisper large-v3-turbo wrote **«Субтитры сделал DimaTorzok»** for it — a credit line that is
not in the recording. whisper.cpp v1.9.2 reported a no-speech probability of 0.000 for that
segment and for every real one, so no no-speech threshold separates them, and `suppress_nst`
changed nothing. The fix therefore lives in segmentation, not in whisper's knobs.

**A span is split only when it is longer than `maximumDuration + minimumRemainder` — 30 s + 5 s =
35 s**, with `minimumRemainder` a named constant next to the cap in `SpeechSegmentSplitter`. The
cut point is unchanged (the quietest 20 ms frame of the last 5 s before 30 s), so every piece is
5–35 s, except a whole span that was short to begin with, which is never split. The 32.6 s tail
now reaches the recogniser whole — whisper slides its own 30 s window over the longer input — so
no mostly-non-speech tail is ever cut loose. The threshold applies in `SpeechSegmentSplitter.split`,
in the assembler's early cut of an open span, and in its closing flush; the session still passes
30 s to Silero as `max_speech_duration`, which only *encourages* a split.

Two figures in the original text change accordingly: a subtitle cue can now be as long as 35 s,
and the memory bound under *Memory* rises from about 35.6 s to about 41 s — one span at the 35 s
threshold plus the 5 s search window and the lookback (`retentionBound` states the new figure).
The benchmark gym now also flags known phantom phrases per model, so a regression shows up in its
report.
