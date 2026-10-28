# Plan — phantom gate and call speakers

Spec: `docs/superpowers/specs/2026-10-28-phantom-gate-and-call-speakers-design.md`.
Each step is test-first (`swift test --package-path macos --filter <Suite>`).

1. **Segment voice** — `TranscriptSegment.voice`, `speakerLabel`; `Transcript.plainText` and
   `TranscriptExporter.speakerPrefix` print `Speaker N`. Tests in `TranscriptTests`,
   `TranscriptExporterTests`.
2. **Store schema 3** — `voice INTEGER` column, 2 → 3 migration, read/write, and
   `replaceSegments(of:speaker:with:)` (one transaction, one side only). `FakeTranscriptStore`
   mirrors it. Tests in `TranscriptStoreTests`.
3. **Detected language** — `RecognisedSpeech`, `TranscriptionProvider.recognise` with a
   default; `WhisperCppTranscriber` reports `whisper_full_lang_id` for `auto`.
   `ScriptedTranscriber` scripts languages per call.
4. **Gate logic** — `Features/PhantomGate.swift`: `LanguageTally`, `PhantomGate.verdict`.
   Tests in `PhantomGateTests`.
5. **Speech share** — `SpeechPresenceMeasuring` next to `SherpaSileroSegmenter`, which
   implements it; `ScriptedSpeechPresence` fake. Gate wired into `LongAudioPipeline.emit`.
   Tests in `LongAudioPipelineTests`.
6. **Catalog** — `ModelKind.speakers`, `LocalEngine.sherpaDiarization`, roles
   `segmentation` / `speakerEmbedding`, entry `speaker-diarization` with digests.
   `ModelCatalogTests` updated.
7. **Turn planner** — `Features/SpeakerTurnPlanner.swift` (merge, cut, number). Tests.
8. **Diarizer** — `Services/SpeakerDiarizer.swift`: `SpeakerDiarizing` + `SherpaSpeakerDiarizer`
   (detached native call); `ScriptedDiarizer` fake.
9. **Presegmented runs** — `LongAudioPipeline.run(segments:duration:)` over given segments,
   same emit path.
10. **Controller step** — settings `identifyCallSpeakers`, error `speakersNotIdentified`,
    state `.identifyingSpeakers`; `FileTranscriptionController.runCall` decodes Others whole,
    diarizes, plans, transcribes, replaces — before `complete` and the `.srt`. Tests in
    `FileTranscriptionControllerTests`.
11. **UI and wiring** — General tab toggle + model row (`ModelsViewModel` over the speakers
    catalog), progress text in Transcripts and the menubar panel, `AppEnvironment` /
    `AppModel` wiring.
12. **Docs** — ADR-0021, `ARCHITECTURE.md`, `SMOKE_TEST.md`, `CHANGELOG.md`.
13. **Verify** — full Definition of done; run the real recording through the shipped code.
