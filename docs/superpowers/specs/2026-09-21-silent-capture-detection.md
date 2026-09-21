# Silent-capture detection: don't transcribe nothing

Status: **approved 2026-09-21.**

Builds on: `2026-09-10-corpus-capture.md` (the archive this was measured on).

## Problem

Measured on 2026-09-21 across the 109 saved recordings (18 minutes) in
`~/Library/Application Support/Macomprendo/dictation-audio`:

**25 of 109 files contain no signal at all** — not quiet, but `peak == 0.000`, every sample zero.
Their history rows say:

| rows | text | what happened |
|---|---|---|
| 16 | `OK` | shorter than 0.5 s, so `shortDictationInsertsOK` short-circuited. Correct. |
| **9** | `you` | 1.9–4.2 s of digital silence went to whisper, which **hallucinated a word** |

Those nine words were pasted into the user's documents. `you` is a documented Whisper failure
mode on silence, and the app had every means to prevent it: the recorder already computes RMS per
buffer for the HUD meter (`AudioMath.rms`, `AudioRecorder.swift:156`), and nothing consults it
before calling the model.

22 of the 25 silent files fall inside one session, 2026-09-18 between 08:12 and 08:36, which says
the capture device stopped delivering audio while the app went on recording zeros and
transcribing them. The app never noticed, never said anything, and produced text either way.

Two failures, then. The app **transcribes silence**, and the app **cannot tell the user its
microphone is dead**.

### What `8ede2a7` already fixed, and what it did not

`fix(dictation): stop reporting an empty recording as a save failure` (merged 2026-09-21) added
`guard !pcm.isEmpty else { return nil }` to `DictationHistoryController.saveRecording`, so a
recording with **zero samples** no longer reaches the encoder and no longer surfaces "Saving the
recording failed: there was nothing to encode" in the HUD. `DictationCapture:137` has the
equivalent `guard !samples.isEmpty` before transcribing.

That is a different buffer. `pcm.isEmpty` means `count == 0`; the twenty-five files measured here
are **non-empty buffers whose every sample is 0.0** — which is exactly why they exist on disk at
all: the encoder accepted them and wrote 0.1 to 4.2 seconds of silence. An emptiness check cannot
see them, and `DictationController` has no length or amplitude guard before
`provider.transcribe`.

So the merged fix removes a spurious error message for the zero-length case, and this spec handles
the all-zeros case that produced `you`. They do not overlap; both are needed.

Note what this is not: the same measurement found a median SNR of 31 dB (the control dictation:
31–37 dB) and no clipping anywhere (peak max 0.897). Background noise is not a problem in this
archive, which is why noise suppression and compression were considered and rejected.

### How this was measured

`ffmpeg` decoded each `.m4a` to 16 kHz mono; frames of 20 ms gave an RMS in dBFS; the 10th
percentile frame was taken as the noise floor and the 90th as speech, their difference as SNR.
Crude by design — it is a screen for "is there anything here", not a calibrated measurement. The
probe was a throwaway: `scripts/` is Node ESM by convention, and a one-off Python measurement does
not earn a place there. Re-running it means writing eight lines again, which is cheaper than
maintaining them.

## Goals

1. Never send a recording with no speech in it to a transcription model.
2. Tell the user when the microphone produced nothing, in words that name the likely cause.
3. Warn during a recording that is producing silence, not only after it.

## Non-goals

- **Noise suppression and dynamic-range compression.** Measured as unnecessary here: the archive
  is clean. sherpa-onnx 1.13.4 does ship `SherpaOnnxCreateOfflineSpeechDenoiser` (GTCRN, DPDFNet)
  already linked into the app, so this is a cheap thing to revisit if a noisy environment ever
  becomes real — but it is not real now, and denoisers are tuned for perceptual quality rather
  than word error rate.
- **Amplitude normalisation.** Separately established as a no-op: sherpa's NeMo path cancels
  constant gain exactly through per-feature CMVN, and Whisper's mel pipeline reduces it to a
  constant offset. OpenAI's own preprocessing does not normalise.
- **VAD.** Recording boundaries come from the hotkey. Adding voice activity detection to trim
  silence is a different feature with its own failure modes.
- **A stop-list of known hallucinations.** Deleting `you` or `Спасибо за просмотр` from output
  would eventually delete a word the user said.
- **Tuning `no_speech_thold` / `logprob_thold` / `entropy_thold`.** whisper.cpp exposes them and
  we set none; that is worth doing and it is a separate, measurable change. An amplitude gate is
  the cheap part that covers the observed cases.
- **Cleaning the nine bad rows out of history.** They are the only record of how the app behaves
  when capture fails. Keep them.

## Behaviour

### The silence gate

Before the transcriber is called, the captured PCM is checked. A recording whose **peak amplitude
is below −60 dBFS** (0.001 in Float32) is treated as having no speech: the model is not called, no
text is inserted, nothing is written to history, and the HUD says so.

Peak, not RMS, and here is why: RMS over a mostly-silent recording with one loud word can sit
under any sensible threshold, and the gate would throw away real speech. Peak answers exactly the
question being asked — "did the microphone ever produce anything?" — and the observed failures are
digital zero, which any threshold catches.

−60 dBFS is far below the quietest real speech in the archive (the softest recording peaked at
0.05, about −26 dBFS) and far above the noise floor of a working microphone (median −66 dBFS
between words). The gate has roughly 26 dB of margin on both sides, so it is not a judgement call
about "too quiet" — it is a test for "nothing at all".

The message names the cause, because the user cannot guess it:

> **No sound was captured.** The microphone produced silence for the whole recording. Check that
> the right input device is selected and that no other app has taken it.

This is a `MacomprendoError` with that description and recovery text, per invariant 8, surfaced
through the existing `hud.show(.error(...))` path.

### The live warning

The controller already consumes `recorder.level` (`DictationController.swift:83-86`) to drive the
HUD meter. That same stream answers the question early: if **three continuous seconds** of a
recording produce a level of zero, the HUD switches to a warning while recording continues —

> **Not hearing anything.** Check your input device.

Three seconds is chosen so a user who presses the hotkey and thinks before speaking is not
scolded; the observed silent recordings ran to 4.2 s, so they would have been caught. The warning
clears the moment a non-zero level arrives, and the recording is never stopped automatically —
that decision stays the user's.

### Interaction with the short-dictation path

`shortDictationInsertsOK` (`DictationController.swift:208`) short-circuits recordings under 0.5 s
to the literal `"OK"` without running a model. Sixteen of the twenty-five silent files took that
path and behaved correctly, so the gate sits **after** it: a deliberate short tap keeps inserting
`OK` even though it is silent, because that is the feature working as designed.

## Wiring

In `DictationController.transcribeAndInsert`, after `recorder.stop()` and after the
short-dictation branch (`:208`), before `transcriberProvider()` (`:218`). `DictationCapture` gets
the same gate beside its existing `guard !samples.isEmpty` (`:137`) — emptiness and silence are
two conditions, checked in one place.

Line numbers are as of `bac5bcb`; plan 01 moved this code, so re-read before editing.

The peak test is a pure function on `[Float]` and belongs beside `AudioMath.rms` in
`Services/AudioMath.swift`, which already holds exactly this kind of helper.

The live warning lives in `onLevel` (`:342`), which already receives every level update and knows
`startedAt`.

## Testing

Written first, per invariant 3. All of this is pure or controller logic with existing fakes.

`AudioMath`:
- `peak` of an empty buffer is 0; of all-zeros is 0; of a mixed buffer is the largest absolute
  value, including a negative sample
- the dBFS threshold constant converts as documented (−60 dBFS ↔ 0.001)

Gate, with `FakeTranscriptionProvider` and `FakeDictationHistoryStore`:
- an all-zero buffer longer than the short-dictation cutoff: the provider is **never called**, no
  text is inserted, no history row is written, and the HUD shows the silence error
- a buffer at exactly the threshold passes to the provider (the boundary is inclusive upward, so
  a borderline-quiet real recording is never discarded)
- a normal recording is unaffected
- an all-zero buffer **shorter** than the cutoff with `shortDictationInsertsOK` on still inserts
  `OK`: the gate must not break the short-tap feature
- the same gate applies in `DictationCapture`
- **the regression case, built from the real failure**: 4.2 s of zeros — the length of history row
  308 — produces no model call. This is the case that pasted `you` into a document.

Live warning, with the fake recorder driving `level`:
- three seconds of zero levels shows the warning
- a non-zero level before three seconds does not
- a non-zero level after the warning clears it
- the warning never stops the recording

Smoke (`docs/SMOKE_TEST.md`):
- select a microphone, mute it in Sound settings, dictate for five seconds: the warning appears
  while recording, and on release the error names the input device rather than inserting text

## Deliverables

- `Services/AudioMath.swift` — `peak(_:)` and the silence threshold.
- `Core/MacomprendoError.swift` — the silent-capture case with recovery text.
- `Features/DictationController.swift` — the gate and the live warning.
- `Features/DictationCapture.swift` — the gate.
- `docs/SMOKE_TEST.md`, `CHANGELOG.md`.

## Open questions

1. **Should a silent recording still be saved to history?** It is currently saved with
   hallucinated text. The spec says write nothing, on the grounds that a row with no text is not a
   dictation — but a corpus-minded user might want the failure recorded. Writing an empty row
   would violate the existing `CHECK(length(trim(text)) > 0)`.
2. **Is three seconds right for the live warning?** It is a guess, bounded below by "don't nag
   someone who pauses to think" and above by the 4.2 s worst case observed. Worth revisiting after
   using it.
