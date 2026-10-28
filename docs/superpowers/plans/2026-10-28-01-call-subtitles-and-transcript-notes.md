# Plan — call subtitles and transcript notes

Spec: `docs/superpowers/specs/2026-10-28-call-subtitles-and-transcript-notes-design.md`.
Each step is test-first (`swift test --package-path macos --filter <Suite>`).

1. **Core naming** — `Core/TranscriptSidecars.swift`; tests in `Core/TranscriptSidecarsTests`.
2. **Exporter** — `render(_:as:notes:)` Markdown `## Notes`, unchanged output without notes;
   `summaryInput(_:notes:)`. Tests in `TranscriptExporterTests`.
3. **Settings + errors** — `saveCallSubtitles` (default, decode fallback, round-trip);
   four `MacomprendoError` cases (`callSubtitlesNotSaved`, `notesUnreadable`, `notesNotSaved`, `notesNotMovedToTrash`) with recovery text.
4. **Sidecar service** — `Services/TranscriptSidecarFiles.swift` protocol + file-system
   implementation (tests on a temporary directory); `Fakes/FakeTranscriptSidecars.swift`;
   `AppEnvironment.transcriptSidecars`.
5. **Call `.srt` on completion** — `FileTranscriptionController` gets `sidecars`; after
   `.complete` in `runCall`, when the setting is on, re-read the row and write the SubRip
   render to `TranscriptSidecars.subtitlesURL(callFolder:)`. `callFinished` gains a
   `warning: String?`. Tests: written on completion, after Resume/Again with every segment,
   not when off, not for files, not on failure/cancel, a write failure keeps `complete` and
   reports the warning.
6. **Notes coordinator** — `Features/TranscriptNotesController.swift`: `load`, `text(for:)`,
   `edit(_:for:)`, debounce (injected sleep), `flush`, `flushAll`, `discard`,
   `currentText(for:)`, per-URL `state`/`error` — the contract in spec §2. Tests with the fake:
   two editors on one URL, dirty survives load, external repair clears unreadable, A-fails /
   B-succeeds, failure → retry.
7. **Library + recorder** — `TranscriptLibraryController.notesURL(for:)`, `delete` trashes a
   file transcript's notes sidecar with the outcomes in spec §2 (flush first; source refused /
   notes refused / absent / DB fails); `CallRecordingController.recordingFolder`. Tests.
8. **UI + wiring** — `UI/Transcripts/TranscriptNotesEditor.swift`, Notes button + popover,
   Markdown export and Summarize with notes, inline panel editor, General tab toggle,
   `AppModel` wiring: flush on `recordingFolder` change, `flushAll()` first in `shutdown()`.
9. **Docs** — CHANGELOG `Unreleased`, `docs/SMOKE_TEST.md` steps; full DoD run.
