# ADR-0011: Saved recordings are AAC files beside the history database

Date: 2026-09-12

## Status

Accepted

## Amendment, 2026-09-17: AAC by default, not AAC always

`Settings.savedRecordingFormat` now chooses between AAC at 48 kbit/s and Apple Lossless
(ALAC, 16-bit), and defaults to AAC. Everything else this ADR decided still holds: files
rather than SQLite blobs, `AVAssetWriter` rather than `AVAudioFile`, the `.m4a` container and
the one-file-per-entry naming — both formats go into the same container with the same
extension, so nothing downstream of the encoder changed.

The reason is a corpus, not audio quality for its own sake: re-running a different model over
an AAC archive measures that model plus an AAC round-trip the original never suffered. ALAC is
lossless compression of *integer* samples, so Float32 → Int16 quantisation still happens; what
it removes is the lossy codec artefacts in the 4–8 kHz sibilant band this ADR measured and
accepted. A row records no format: the file already knows, and a column could drift out of
step with it. See `docs/superpowers/specs/2026-09-10-corpus-capture.md`.

## Context

Dictation history may now keep the microphone recording behind each transcript. A recording
is three orders of magnitude larger than the text it produced, and history retention became
age-based in the same change, so every stored byte must be reclaimable on a schedule. The
recorder keeps only 16 kHz mono — the format whisper.cpp and `/v1/audio/transcriptions`
expect — so that is the highest fidelity any archive can hold without buffering a second
raw stream.

## Decision

Encode each recording as AAC at 48 kbit/s, 16 kHz mono, into an `.m4a` file written with
`AVAssetWriter`, stored in `dictation-audio/` beside the database, one file per entry named
after the entry identifier. `dictation_history` gains a nullable `audio_file` column at
schema version 2. Encoding happens after the transcript is inserted; the audio reference is
filled in afterwards.

## Consequences

- Roughly 0.35 MB per minute of speech, or 1.3 GB per year at ten minutes of dictation a
  day, against 1.11 MB/min for lossless ALAC. Measured on real speech, the full 0–8 kHz
  speech band survives; 16 kbit/s was rejected because it discards three quarters of the
  4–8 kHz band that carries sibilants.
- MP3 is impossible without vendoring an encoder: macOS ships no MP3 encoder, only a
  decoder. Opus encodes only into `.caf`, which Finder hands to GarageBand.
- `AVAssetWriter` rather than `AVAudioFile`, because the latter pads every `.m4a` with a
  ~22 KB `free` atom — nine times the payload of a three-second dictation.
- Files rather than SQLite blobs: age-based retention must return disk space, and deleting
  blob rows leaves the database at its high-water mark until `VACUUM` rewrites it. Deleting
  files returns the space immediately and leaves the database untouched.
- Files can be orphaned by crashes or external deletion, so the launch path purges
  unreferenced files and tolerates a missing file behind a populated column.
- An older build opening a version 2 database treats it as unsupported and asks to reset
  history; data written before the upgrade is untouched until the user confirms.
