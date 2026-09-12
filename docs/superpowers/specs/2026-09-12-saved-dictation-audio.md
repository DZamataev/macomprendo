# Saved dictation audio

## Goal

Keep the microphone recording behind each history entry, so a user can hear what was
actually said when a transcript looks wrong, without turning the history database into a
multi-gigabyte archive.

## Vocabulary

- **Dictation history** — the existing opt-in record of accepted transcripts. It now also
  carries an optional recording.
- **Saved recording** — one encoded audio file belonging to exactly one history entry.
- **Retention** — the maximum age of a history entry. One value covers transcripts and
  recordings alike.

## Behaviour

### Settings

- Settings ▸ General gains `Save the original recording`, below `Save dictation history`.
- The new toggle is disabled while `Save dictation history` is off, and is off by default.
- Settings ▸ General gains `Keep history for` with the choices `1 day`, `7 days`,
  `30 days`, `60 days`, `90 days`, `180 days`, `365 days`, and `Unlimited`. The default,
  including settings documents written before this feature, is `90 days`. `Unlimited`
  keeps the existing 100,000-entry ceiling.
- Below the recording toggle, `Saved audio: <size>` reports the total size of the audio
  directory, recalculated when the tab appears and after any action that changes it,
  next to a button revealing that directory in Finder.
- `Delete saved audio` removes every recording and leaves every transcript. It asks for
  confirmation, like `Clear History`.
- Settings ▸ Dictation gains `Maximum recording length`, in minutes, accepting 1 to 60,
  defaulting to 5, which is today's fixed cap. A caption states that endpoint
  transcription rejects requests above roughly 13 minutes, and that local models have no
  such limit.

### Capture and encoding

- Both hotkey paths that already write history — Dictate and Dictate & Refine — save a
  recording when both the history and recording settings are on.
- The saved audio is the same 16 kHz mono the transcriber receives, encoded as AAC at
  48 kbit/s into `.m4a` through `AVAssetWriter`.
- Encoding and writing happen after the transcript has been inserted, so they never delay
  text reaching the frontmost app. The history row is written first, as today, and its
  audio reference is filled in when the file is on disk.
- A recording that reaches `Maximum recording length` stops as it does today, and the HUD
  now says so instead of stopping silently.

### Storage

- Recordings live in `~/Library/Application Support/Macomprendo/dictation-audio/`, one
  file per entry, named after the entry identifier.
- That directory and `~/Library/Application Support/Macomprendo/` are created with
  owner-only permissions.
- `dictation_history` gains a nullable `audio_file` column at schema version 2. An empty
  column means no recording was ever saved for that entry.
- At launch, files in the audio directory that no entry references are deleted.

### Retention

- Entries older than the retention setting are removed, together with their recordings,
  at launch, after each new entry, and immediately after the setting changes.
- Turning `Save the original recording` off stops new recordings and keeps existing ones.
- `Clear History` removes every transcript and every recording.

### Failures

- A failed encode or write leaves the transcript in place with no audio reference, and
  surfaces a `MacomprendoError` through the HUD, exactly as a failed history write does.

## Non-goals

- Capturing audio above 16 kHz mono. The recorder converts at the tap and keeps nothing
  else, so a higher-fidelity archive would mean buffering a second raw stream.
- Exporting, sharing, or re-transcribing a saved recording from inside the app.

## Measurements

Real Russian speech, 21.6 s, 16 kHz mono — the exact samples the transcriber receives:

| Encoding | MB/min | GB/year at 10 min/day | Energy kept, 4–8 kHz |
|---|---|---|---|
| AAC 16 kbit/s | 0.13 | 0.5 | 22% |
| AAC 24 kbit/s | 0.19 | 0.7 | 100% |
| AAC 48 kbit/s | 0.35 | 1.3 | 95% |
| ALAC lossless | 1.11 | 4.0 | 100% |

MP3 cannot be produced: `AudioFormatGetProperty(kAudioFormatProperty_EncodeFormatIDs)`
lists no MP3 encoder on macOS 26. Opus encodes only into `.caf`, and `AVAudioFile` pads
every `.m4a` with a ~22 KB `free` atom, which is why `AVAssetWriter` writes the file.

## Acceptance

- A failing test precedes each behaviour below, and `npm run test:swift` and
  `npm run test:scripts` are green.
- Settings JSON round-trip and legacy decoding preserve the new toggle, the retention
  choice, its 90-day default, and the recording-length value.
- Tests prove: a recording is saved for both hotkey paths when both settings are on, and
  for neither path when either is off; the audio reference lands on the right entry; a
  failed encode leaves the transcript and reports an error; retention deletes entries and
  their files at launch, after an append, and after a setting change; `Clear History`
  removes both; `Delete saved audio` removes only files; orphaned files are purged at
  launch; schema version 1 migrates to 2 and keeps existing rows.
- An integration test encodes a synthetic buffer and decodes it back, asserting the
  container, sample rate, channel count, and duration.
- `docs/SMOKE_TEST.md` covers recording, playing back from the history window, revealing
  the directory in Finder, and the length-limit toast.
- `PRIVACY.md`, `README.md`, the settings caption, and `CHANGELOG.md` no longer claim
  audio is never saved, and describe what is stored, where, and for how long.
