# Phantom gate and call speakers — design

Status: approved by the operator 2026-10-28 («поставь цель и сделай всё автономно») after the
spike in `~/dev/scratch/2026-10-28-diarization-spike/` on the call
`rec 2026-10-28 15-33-51` (a 57-minute grooming, five people on the far side). The numbers
below come from that spike and are this design's evidence.

## 1. Requirements

1. **Phantom gate.** A long-audio segment whisper produced from no speech — `*Sigh*`, `you`,
   `und`, `- No, no, no.` on the Me track of a Russian call — is not stored. A short segment of
   real speech whose language whisper guessed wrong (`On sobie nie nienka` for «Он сегодня
   нянька», `Mm-hmm` for «угу») is decoded again in the transcript's language. Real speech in
   the transcript's language is never touched. No list of phrases (spec
   `2026-09-21-silent-capture-detection` rejected one: it eventually deletes a word the user
   said).
2. **Call speakers.** When a call transcript finishes, its Others track is split by voice: each
   stored Others segment says which of the other participants spoke it, and every place that
   prints a speaker prints `Speaker 1`, `Speaker 2`, … instead of `Others` — the transcript
   view, plain text, Markdown, SubRip and the `.srt` saved in the recording folder. `Me` stays
   `Me`.
   - Settings ▸ General ▸ Call recordings ▸ **Tell the other speakers apart**, on by default
     (`Settings.identifyCallSpeakers`, missing key → `true`). It needs a 46 MB model pair that
     the same row downloads; without it calls finish as before, labelled `Others`.
   - Runs after Stop (and after **Resume** / **Transcribe Again** of a call), never live: the
     live text stays `Others` until the call's transcript completes.

## 2. Evidence from the spike

- whisper large-v3-turbo with language `auto` labelled **every** phantom on the Me track
  `en`/`de` while the call is `ru`. Token probabilities (`*Sigh*` p≈0.95), `no_speech_prob`
  (≈0) and `--suppress-nst` (turns `*Sigh*` into English sentences) do not separate them;
  forcing `ru` turns them into `Субтитры сделал DimaTorzok`.
- A fresh Silero detector with the app's own settings (threshold 0.5, min silence 0.5 s, min
  speech 0.25 s, 512-sample window), run over just the segment's samples, finds **0 %** speech
  in every phantom and **≥ 22 %** in every real segment of either track (median 69 % / 85 %).
  Mis-languaged real speech scored 30–55 %.
- Diarization with sherpa-onnx 1.13.4 (pyannote segmentation 3.0 + 3D-Speaker ERes2Net base,
  fast clustering, distance threshold 1.2) found exactly the five far-side participants; 84 % of
  words agree with the named speakers Taskless recorded (96.9 % where one person holds the
  floor, 62.7 % within 3 s of another voice). The other embedding models scored 54–80 %.
  Thresholds 1.0 and 1.4 gave 27 and 1 speakers. Diarizing 51 minutes took ~3.5 minutes of
  CPU.

## 3. Decisions

### Phantom gate

- **Where:** `LongAudioPipeline.emit`, so file transcription, call tracks and live call
  transcription all get it; dictation does not (it is not long audio, and its own silence gate
  already exists).
- **Detected language:** `TranscriptionProvider` gains
  `recognise(_:sampleRate:language:) -> RecognisedSpeech` (`text`, `language: String?`), with a
  protocol-extension default that calls `transcribe` and reports no language. whisper.cpp
  overrides it: with `language == "auto"` it reads `whisper_full_lang_id` →
  `whisper_lang_str`. Every other provider reports `nil`, and the gate never acts on `nil`.
- **The transcript's language** is the one with the most kept seconds so far in this pipeline
  run (`LanguageTally`). A run whose language the user chose (`Settings.transcriptionLanguage`
  set) never gates: the provider was told the language.
- **Verdict** (`PhantomGate`, pure), for a segment of `duration` whose detected language is
  `detected`, the tally's leader `expected`, and the measured speech share `speech`
  (`speechFloor` = 0.1, `redecodeLimit` = 5 s):
  1. `detected == nil` → keep.
  2. `expected == nil` (nothing kept yet): `speech < speechFloor` → drop, else keep.
  3. `detected == expected` → keep.
  4. `speech < speechFloor` → drop.
  5. `duration ≤ redecodeLimit` → decode again with `language: expected`; an empty result
     drops it.
  6. otherwise keep — a long stretch in another language is someone really speaking it.
  The speech share is measured only where the verdict needs it (cases 2, 4–6), so a call in one
  language pays for it only on its phantoms.
- **Speech share:** `SpeechPresenceMeasuring.speechFraction(of:sampleRate:)`, implemented by
  `SherpaSileroSegmenter` with a fresh detector configured exactly like its sessions, fed in
  512-sample windows and flushed; detected region samples ÷ segment samples.
- A dropped segment is logged at debug level without its text (invariant 6).

### Call speakers

- **Data:** `TranscriptSegment.voice: Int?` — 1-based, numbered by first appearance, only on
  `.others` segments of a diarized call. `TranscriptSegment.speakerLabel` is `Speaker N` for
  such a segment, else the speaker's own label; `TranscriptExporter.speakerPrefix` and
  `Transcript.plainText` use it. Store schema 3 adds `transcript_segments.voice INTEGER`;
  version 2 files migrate in one transaction.
- **Turning voices into text: decode the Others track again by turn.** The stored Others
  segments are joined across speakers (up to 35 s, `callJoinGap` 1.5 s), and providers return
  no word times to cut them by. So the finished Others file is decoded whole, diarized, its
  turns merged (same voice, gap < 0.8 s, run ≤ 30 s; longer runs cut into equal pieces — the
  spike's `runs_from_diarization`) and each run transcribed through the same pipeline path —
  phantom gate included. The new segments replace the track's old ones in one store
  transaction (`replaceSegments(of:speaker:with:)`), so a failure part-way leaves the old text.
- **When:** in `FileTranscriptionController.runCall`, after every planned track has run and
  before the row becomes `complete` and its `.srt` is written. Skipped when the setting is
  off, the models are not downloaded, the manifest has no Others track or the track stored no
  segments.
- **Failure is not fatal.** Diarization or its re-decoding failing leaves the `Others`
  segments, completes the row, and reports `MacomprendoError.speakersNotIdentified` as the
  call-finished warning. Cancellation (Stop of the job, quit) still leaves the row
  `incomplete`, exactly like a cancelled track, so **Resume** redoes the step.
- **Progress:** `FileTranscriptionController.State.identifyingSpeakers(transcriptID:title:)`,
  shown as «Identifying speakers…» in the Transcripts window and the menubar panel.
- **Native work cannot be interrupted** (sherpa ignores the progress callback's return value),
  so `SherpaSpeakerDiarizer` runs it on a detached task and a cancelled caller stops waiting
  for it; the abandoned diarizer frees itself when it finishes.
- **Models:** one catalog entry `speaker-diarization` of a new kind `.speakers` (engine
  `.sherpaDiarization`), two loose files with pinned digests: pyannote segmentation 3.0
  (`model.onnx`, 6 MB, MIT, Hugging Face `csukuangfj/sherpa-onnx-pyannote-segmentation-3-0`)
  and 3D-Speaker ERes2Net base (40 MB, Apache-2.0, sherpa-onnx release
  `speaker-recongition-models`). Downloaded like every model by `LocalModelManager`; not
  redistributed, so — like the whisper and GigaAM weights — not in `LicenseRegistry`
  (invariant 16 lists only what ships inside the app); the licences are named in the settings
  caption instead.
- **Clustering:** distance threshold 1.2, `min_duration_on` 0.3 s, `min_duration_off` 0.5 s,
  threads `max(1, cores − 2)`.

## 4. Not in scope

- Renaming `Speaker N` to a person, or merging two speakers by hand.
- Diarizing the Me track, file transcripts, or live.
- Telling the clusterer the number of participants.
- Gating a run whose language the user fixed (the `Субтитры…` phantoms of a forced language).

## 5. Testing

- `PhantomGate` and `LanguageTally`: every verdict case, the tally's leader, ties.
- `LongAudioPipeline`: drops, re-decodes with the expected language, keeps, never measures a
  segment that matches, never gates a fixed-language run or a provider that reports nothing.
- `SpeakerTurnPlanner`: merging, the 30 s cut, numbering by first appearance.
- Store: schema 2 → 3 migration, `voice` round-trip, `replaceSegments` touches only one side.
- `FileTranscriptionController`: diarized Others land with voices before `complete` and the
  `.srt`; skipped when off / models missing / no Others; a diarizer failure completes with the
  warning; cancellation leaves `incomplete`.
- Exporter / plain text: `Speaker N` prefixes.
- Native glue (`SherpaSpeakerDiarizer`, `speechFraction`, whisper language id) stays thin; the
  smoke test covers it on a real recording.
