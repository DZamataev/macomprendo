# Dictation history

Date: 2026-09-01 · Status: approved for planning

Builds on: `2026-08-23-macomprendo-design.md` (dictation flows, privacy, layering)

## 1. Purpose and scope

Macomprendo can optionally keep a local, text-only history of successful microphone
transcriptions. History is disabled by default. When enabled, it records both:

- the accepted transcript produced by **Dictate**; and
- the original transcript produced by **Dictate & Refine**, before any LLM processing.

It does not store audio, selected text used by Refine Selection, refined LLM output,
provider responses, prompts, the target application, endpoint details, or model details.
Cancelled, failed, blank, and whitespace-only transcriptions do not create entries.

The feature keeps at most 100,000 entries. Adding entry 100,001 removes the oldest entry
in the same storage transaction. Disabling history stops new writes but preserves existing
entries. Clearing existing entries is a separate destructive action with confirmation.

## 2. User experience

### 2.1 Preference and menu

Settings > General, in the existing Dictation section, gains **Save dictation history**.
The default is off. Supporting text states that transcripts are stored locally as plain
text and that audio is never stored.

While the preference is enabled, the menubar menu shows **Dictation History…** between the
hotkey-action controls and **Settings…**. The item is absent while the preference is
disabled. Disabling history does not close an already-open history window; after that
window is closed it cannot be reopened from the menu until history is enabled again.

Opening the item activates the app and opens a single-instance Dictation History window.
The Dock icon remains visible while that window is open, using the same ownership model as
Settings and Onboarding.

### 2.2 History window

The window shows newest entries first. Each row contains:

- a localized date and time;
- the source label **Dictation** or **Dictation & Refine**;
- the transcript, preserving its text but using a bounded preview in the row; and
- an accessible **Copy** button using the already-vendored `.copy` icon.

Copy writes the complete transcript directly through `PasteboardProtocol`, matching the
existing explicit Copy actions. It does not snapshot and restore the previous pasteboard;
that invariant applies to simulated Command-C/Command-V flows, not an explicit copy.

The window initially loads a bounded page and fetches older pages as the user scrolls, so
opening a 100,000-entry history never loads every transcript into memory. It includes:

- loading, empty, and storage-error states;
- a **Clear History…** action with confirmation; and
- no search, editing, exporting, per-entry deletion, audio playback, or synchronization.

## 3. Data model and storage

### 3.1 Core value

`DictationHistoryEntry` is a `Sendable`, `Equatable`, `Identifiable` Core value containing:

- a stable database identifier;
- `createdAt: Date`;
- `kind: .dictation | .dictationAndRefine`; and
- `text: String`.

Only trimmed, non-empty text reaches the store.

### 3.2 SQLite service

`DictationHistoryStoring` is declared beside its default implementation in Services. Its
async throwing API supports append, newest-first paged fetch, and clear. The live
implementation is an actor, owns one SQLite connection, and is constructed only in
`AppEnvironment`. Tests receive an in-memory fake or a store backed by a temporary database.

The database lives at:

`~/Library/Application Support/Macomprendo/dictation-history.sqlite3`

Schema version 1 uses SQLite's `user_version` and a table with an integer insertion-order
primary key, creation timestamp, kind, and text. Queries order by insertion identifier
descending, which is deterministic even when timestamps collide. Append and retention
trimming run in one transaction. The schema supports cursor-based paging rather than
large offsets.

SQLite is selected because 100,000 text records make a JSON blob expensive to rewrite and
load, while SwiftData would introduce a second object lifecycle and less explicit migration
and protocol boundaries. The system SQLite library is linked directly; no new package or
network dependency is introduced. `ADR-0010-sqlite-dictation-history.md` records this
decision.

The database is local plaintext protected by the user's macOS account and any FileVault
configuration. It is not put in the Keychain: Keychain is for small secrets, not a large
queryable corpus. Macomprendo never logs transcript text at default level.

## 4. Components and data flow

`Settings` gains `dictationHistoryEnabled: Bool`, defaulting to `false`. Its hand-written
decoder supplies the default for older settings documents; no destructive migration is
needed.

A shared `@MainActor` `DictationHistoryController` in Features owns window-facing state:
loaded entries, paging state, clear confirmation/result, copy feedback, and the latest
storage error. It depends only on `DictationHistoryStoring` and `PasteboardProtocol`.
`AppModel` owns it and shares it with the history window.

There are exactly two recording commit points:

1. `DictationController` appends after transcription has passed cancellation, trimming,
   and the non-empty guard, immediately before insertion.
2. `DictationCapture` appends after the same acceptance checks and immediately before its
   single `onTranscript` callback. This is the microphone path used by Dictate & Refine.

The provider layer is not decorated because endpoint readiness probes also invoke a
transcriber. `RefineController.beginRefine` is not used because Refine Selection sends
non-dictated text through the same method. Quick Panel Copy/Insert actions are repeatable
and must not create duplicate history entries.

The current value of `dictationHistoryEnabled` is read at transcript acceptance time. If
the user disables the option while recording, that transcript is not saved; enabling it
while recording causes an accepted transcript to be saved.

History append is awaited at the unique commit point to preserve ordering and make failures
observable. A storage failure does not discard the transcript, prevent direct insertion,
or prevent the Refine panel from opening. The history controller receives the error for a
persistent UI banner, and the active flow presents a concise non-fatal warning.

## 5. Errors and concurrency

All SQLite access is serialized by the store actor. UI and feature controllers remain
`@MainActor`. No transcript crosses an unstructured detached task. Closing the history
window cancels its page-loading task without cancelling dictation writes.

Database open, schema, query, append, and clear failures become `MacomprendoError` values
with an `errorDescription` and `recoverySuggestion`. Error strings and logs identify the
operation but never include transcript text. A future database schema is not silently
opened or reset. A corrupt database is preserved until the user confirms **Clear History**;
that explicit action may remove the database and its sidecar files and recreate an empty
version-1 database, so it is also the recovery path for corruption or a future schema.

The existing one-task-per-controller and cancellation semantics remain authoritative.
Once a non-empty transcript passes its final cancellation check, a later direct-insertion
failure or a later LLM failure does not remove its history entry: the transcript itself was
successfully produced. A cancellation during the deliberately non-cooperative insertion
also does not roll the accepted entry back.

## 6. Testing

Implementation follows red-green-refactor. Unit tests cover:

- the preference default, legacy decode, round trip, and AppModel persistence;
- SQLite schema creation, append, newest-first deterministic order, cursor paging,
  persistence across reopen, 100,000-entry retention, timestamp collisions, transactions,
  clear, corrupt/future schema, and representative IO failures;
- actor concurrency with no lost appends;
- history-controller initial load, incremental load, clear, copy, empty state, task
  cancellation, and non-fatal storage errors;
- enabled and disabled direct dictation, blank/error/cancel exclusion, exactly one entry,
  insertion failure after a successful transcript, and toggling the preference in flight;
- the same inclusion/exclusion cases for Dictate & Refine without recording Refine
  Selection or endpoint probes;
- AppEnvironment/AppModel graph wiring and Dock-icon ownership for the history window.

SwiftUI presentation details are added to `docs/SMOKE_TEST.md`: preference persistence,
conditional menu visibility, single-window activation, paging, row copy, clear
confirmation, empty/error states, and Dock-icon lifecycle.

Before completion, run the full Swift and script tests, `swift build`, regenerate the
Xcode project and prove regeneration is then a no-op. Update `PRIVACY.md`, the README
privacy text, `CHANGELOG.md` Unreleased, `docs/ARCHITECTURE.md`, and this specification if
implementation reveals a changed contract.

## 7. Non-goals

- Audio retention or playback.
- Saving Refine Selection, summaries, refined LLM output, or endpoint probes.
- Full-text search, tags, editing, export, synchronization, or cloud backup controls.
- Encryption beyond normal macOS account/FileVault protection.
- Per-entry deletion or configurable count/age limits.
