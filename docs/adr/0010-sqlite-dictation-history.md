# ADR-0010: SQLite stores opt-in dictation history

Date: 2026-09-01

## Status

Accepted

## Context

Dictation history is optional but may contain up to 100,000 text transcripts. Opening the
history must not load the entire corpus, and appending a transcript must not rewrite a large
document. Storage remains local and must fit Macomprendo's protocol-injected, Swift 6 strict
concurrency architecture.

## Decision

Use the system SQLite library through an actor-backed `DictationHistoryStoring` service.
Store the database in Macomprendo's Application Support directory, page newest-first by a
monotonic integer identifier, and trim the oldest entry transactionally when the configured
100,000-entry ceiling is exceeded. Keep the database independent from the small preferences
document stored in UserDefaults.

The database contains only the timestamp, dictation kind, and transcript. It is local
plaintext protected by the macOS account and FileVault when enabled. Audio, application
identity, endpoint data, prompts, and LLM output are excluded.

## Consequences

- Appends, paging, and retention remain efficient at the required limit.
- Schema versioning and SQLite error mapping become explicit application responsibilities.
- The system SQLite library must be linked in SwiftPM and XcodeGen configuration.
- Tests can use temporary databases and a protocol fake without network or hardware.
- JSON was rejected because it rewrites and decodes the whole collection; SwiftData was
  rejected because it adds object-lifecycle and migration machinery without improving this
  narrow append/page/clear workload.
