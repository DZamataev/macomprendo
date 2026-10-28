# Call subtitles and transcript notes — design

Status: approved by the operator 2026-10-28 (clarifying answers recorded in §1). Reviewed by
gpt-reviewer (GPT-6.1 Sol) before implementation.

## 1. Requirements

1. When a **call** transcript finishes (`status` becomes `complete`), its SubRip subtitles are
   written into the recording folder as `<folder name>.srt` — e.g.
   `rec 2026-10-15 16-42-07/rec 2026-10-15 16-42-07.srt`, next to the two `… Me.m4a` /
   `… Others.m4a` tracks. File transcripts get no automatic `.srt`.
   - Overwritten on every completion (Resume, Transcribe Again): the folder is the app's own.
   - Only on `complete`; never for `incomplete`, cancelled or no-speech rows, and not during
     launch recovery — a recovered call gets its `.srt` when a later Resume completes it.
   - Settings ▸ General ▸ Call recordings: **Save subtitles (.srt) in the recording folder**,
     on by default (`Settings.saveCallSubtitles`, missing key → `true`).
2. Every transcript has **Notes**: free multiline text (links from the call's chat, etc.)
   kept in a plain-text sidecar named like the recording:
   - call: `<recording folder>/<folder name>.notes.txt`;
   - file: `<source without its last extension>.notes.txt` next to the source file
     (`/a/meeting.mp4` → `/a/meeting.notes.txt`).
   - Edited in a popover from the transcript's action row (**Notes**, the icon filled when
     notes exist) and, while a call is being recorded, inline in the menubar panel's call
     block.
   - Autosaved: debounced while typing and flushed when the editor closes, the target changes,
     the recording stops or the app quits. Empty text removes the file (and never creates it).
     Re-read from disk whenever an editor opens, so edits made in another editor show up.
   - Included in the Markdown export as `## Notes` (after Summary, before Transcript) and
     prepended to the text **Summarize** sends.

## 2. Decisions

- **Name after the current folder name** (`folder.lastPathComponent` of the resolved
  bookmark), the user's literal rule. A folder renamed in Finder after notes were written
  orphans the old `*.notes.txt` under its old name; documented, not handled.
- **Sidecars live on disk only**, never in SQLite: no schema migration, the files are the
  source of truth, and the dormant `Transcript.summary` is not repurposed.
- **Menubar panel: inline editor, not a nested popover.** The panel is an
  `.applicationDefined` `NSPopover` whose local event monitor closes it on any click in
  another window of ours (`StatusItemController.handleLocal`), which a child popover window
  is. The panel's root view is rebuilt on every opening, so the draft lives in a controller
  owned by `AppModel`, not in view state; switching to the chat app closes the panel, and the
  autosave has already landed by then.
- **One notes coordinator** (`TranscriptNotesController`, `@MainActor`, owned by `AppModel`)
  holds drafts keyed by sidecar URL, so the panel and the Transcripts window editing the same
  call share one draft and one save queue. Writes are synchronous and tiny (main actor), so
  they are naturally serialised; a debounced save always writes the *current* draft for its
  URL, never a captured older value.
- **Unreadable notes are an error, not empty text.** Missing file → `""`; a file that is not
  UTF-8 or cannot be read → `MacomprendoError.notesUnreadable` and the editor stays read-only
  for that URL, so an autosave can never overwrite it.
- **Saving never creates folders.** A sidecar whose parent is gone fails with
  `notesNotSaved`; the draft stays dirty and is retried on the next edit.
- **SRT failure does not undo completion.** The SRT is written after `setStatus(.complete)`
  in `FileTranscriptionController.runCall`, in its own `do/catch`, from the transcript
  re-read from the store (the `resuming` snapshot lacks the new segments). A failure is
  reported with the call-finished toast (`callSubtitlesNotSaved`) instead of
  "Call transcript ready".
- **Deletion.** The draft for the transcript's notes is *flushed* first in every case, so no
  outcome loses text. Deleting only the row keeps every file. "Also move the source to the
  Trash" already trashes a call's whole folder, notes and subtitles included; for a file
  transcript the notes sidecar is trashed after the source. Outcomes: source refused → nothing
  deleted, existing `sourceNotMovedToTrash`; source trashed but notes refused → the row is
  still deleted and a `notesNotMovedToTrash` warning stays shown; absent notes → nothing to do.
  Once the source moved, the URL's entry is retired (`discard`), so a late editor close cannot
  recreate the file. The confirmation text names the notes file too.
- **Flush on stop.** `AppModel` observes `CallRecordingController.recordingFolder`; when it
  changes away from a folder (any stop route: panel, hotkey, auto-recorder, sleep, quit) the
  notes for that folder are flushed. `AppModel.shutdown()` flushes every draft first.
- **Notes at action time.** Markdown export and Summarize ask the coordinator for
  `currentText(for:)` — the dirty draft if there is one, else a fresh disk read — even when no
  editor was opened. Unreadable notes fail the action with `notesUnreadable` rather than being
  silently omitted. TXT and SRT export never resolve or read notes. The notes URL is computed
  from the open transcript each time, so a relinked bookmark is followed.

### Notes coordinator contract

Per sidecar URL, an entry is *unloaded* (no entry), *clean*, *dirty* or *unreadable*, plus an
optional last save error for that URL only.

- `load(url)`: unloaded/clean/unreadable → re-read from disk (missing file = `""`; a successful
  read clears unreadable and the save error); dirty → kept, never replaced.
- `edit(text, url)`: allowed only for clean/dirty entries; marks dirty and (re)schedules a
  debounced save. Unloaded or unreadable entries ignore edits (the editor shows read-only).
- save / `flush(url)`: writes the current draft; success → clean, error cleared; failure →
  stays dirty with `notesNotSaved` on that URL; retried by the next edit or flush.
- `flushAll()` flushes every dirty entry and returns the failures (logged at quit).
- `discard(url)` cancels the pending save and forgets the entry.
- Errors are per URL: A's failure is never shown in B's editor, and B's success never clears A.

## 3. Shape

| Layer | Type | Role |
|---|---|---|
| Core | `TranscriptSidecars` (enum) | `subtitlesURL(callFolder:)`, `notesURL(callFolder:)`, `notesURL(sourceFile:)` |
| Core | `TranscriptExporter` | `render(_:as:notes:)` (Markdown `## Notes`), `summaryInput(_:notes:)` |
| Core | `Settings.saveCallSubtitles` | default `true` |
| Core | `MacomprendoError` | `callSubtitlesNotSaved`, `notesUnreadable`, `notesNotSaved` |
| Services | `TranscriptSidecarFiling` + `FileSystemTranscriptSidecars` | read/save notes (empty removes), write subtitles atomically, `fileExists` |
| Features | `FileTranscriptionController` | writes the call `.srt` on completion |
| Features | `TranscriptNotesController` | drafts, debounce, flush, discard, error |
| Features | `TranscriptLibraryController` | `notesURL(for:)`, notes for export/summarize, trash the file sidecar |
| Features | `CallRecordingController` | publishes `recordingFolder` while recording |
| UI | `TranscriptNotesEditor`, `TranscriptsView`, `CallRecordingPanelSection`, `GeneralTab` | popover / inline editor / toggle |

## 4. Out of scope

Automatic `.srt` for file transcripts; rediscovering notes after a folder rename; notes in the
plain-text or SubRip exports; notes in dictation history.
