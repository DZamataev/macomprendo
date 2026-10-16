# Call recording

## Goal

Record a call — the user's microphone and everything the Mac plays — into two ordinary audio
files, then transcribe both through the long-audio pipeline into one transcript whose segments
say who spoke: **Me** (the microphone) or **Others** (system audio). This is sub-project 2 of
`2026-10-14-file-transcription-design.md`; it reuses that spec's pipeline, store and Transcripts
window.

Transcription runs after the recording stops. The capture is built so that a later stage can
transcribe during the call without redesign (see *Live transcription later*).

## Vocabulary

- **Call recording** — one start-to-stop capture: a folder holding the two track files and
  `recording.json`.
- **Track** — one side of the recording: `me` (microphone) or `others` (system audio).
- **Speaker** — the label a transcript segment carries, taken from the track it came from. No
  diarisation: several remote people are all **Others**, and anyone speaking into the Mac's
  microphone is **Me**.
- **Process tap** — a Core Audio tap (`CATapDescription` + `AudioHardwareCreateProcessTap`,
  macOS 14.2+) on the output of other processes.
- **Session clock** — `mach_absolute_time` host time; both tracks are placed on it.

## Behaviour

### Starting and stopping

- The menu shows **Record Call** while idle and **Stop Recording** while recording; both carry
  the `recordCall` hotkey. The hotkey toggles: a press while idle starts, a press while
  recording stops. A press during `starting` stops as soon as capture is up — a stop is never
  lost.
- Start fails before any file is created when microphone permission is denied
  (`permissionDenied(.microphone)`) or the recordings folder cannot be created or written
  (`callRecordingLocationUnavailable`).
- System audio permission ("System Audio Recording Only" in Privacy & Security) has no public
  preflight. `Info.plist` carries `NSAudioCaptureUsageDescription`; macOS asks on the first tap.
  If the user declines, the tap delivers silence: the recording continues, the **Others** level
  stays empty, and the transcript has no Others segments. Nothing else reports it.
- Stop finalises both files, marks `recording.json` `finished`, and starts the transcription job
  (see *Transcription*). The Transcripts window does not open; a toast reports the finished
  transcript.
- System sleep stops the recording exactly as Stop does.
- Quitting the app while recording stops and finalises the recording, creates its transcript as
  `incomplete` with the reason `Macomprendo quit before it finished.`, and does not transcribe.
  `Resume` transcribes it later.
- Dictation works during a call recording. Each owns its own `AVAudioEngine` and neither enables
  voice processing; local-model calls are already serialised by `TranscriptionLane`.

### What is captured

- **Me** — the microphone dictation uses (`Settings`' microphone UID; `nil` follows the system
  default), raw: no voice processing, no echo cancellation, no noise
  suppression.
- **Others** — one global process tap over every process except Macomprendo
  (`CATapDescription(stereoGlobalTapButExcludeProcesses:)` with our own process object),
  `muteBehavior = .unmuted`, read through a private aggregate device that contains the tap and no
  sub-device.
- **No echo handling.** When the call plays through speakers the microphone hears the other side
  too, and their words can appear under **Me**. This is accepted; ADR-0017 records why voice
  processing is not used.
- When the default output device changes mid-recording, the tap and its aggregate are rebuilt and
  writing continues into the same file. When the chosen input device changes or disappears, the
  microphone engine restarts on the current device and continues into the same file.
- Every gap — a rebuild, a device change, a stalled callback — is filled with silence measured on
  the session clock, so second *t* of either file is second *t* of the call. Gaps shorter than
  50 ms are not padded; slow clock drift between the two devices is not corrected.

### Files

- The recordings folder is `Settings.callRecordingsDirectory`, default
  `~/Library/Application Support/Macomprendo/Recordings` (outside the TCC-protected Documents,
  Desktop and Downloads folders).
- Each recording is a folder named after its local start time:

  ```
  rec 2026-10-15 16-42-07/
    rec 2026-10-15 16-42-07 Me.m4a
    rec 2026-10-15 16-42-07 Others.m4a
    recording.json
  ```

  If the name is taken (two starts in one second), ` (2)`, ` (3)`… is appended to the folder
  name; the file names follow the folder.
- Both tracks are converted to 48 kHz mono `Float32` at capture and written by `AVAssetWriter` as
  AAC at 48 kbit/s (ADR-0011's voice bitrate) in a fragmented MP4 with a 1 s fragment interval,
  so a crash loses at most the last second and leaves a playable `.m4a`.
- `recording.json`:

  ```json
  {
    "version": 1,
    "startedAt": "2026-10-15T13:42:07Z",
    "status": "recording",
    "tracks": {
      "me":     { "file": "rec 2026-10-15 16-42-07 Me.m4a",     "startOffset": 0.000 },
      "others": { "file": "rec 2026-10-15 16-42-07 Others.m4a", "startOffset": 0.184 }
    }
  }
  ```

  `status` is `recording` until Stop or quit finalises it as `finished`. `startOffset` is the
  seconds from the session start to the track's first sample. It is written atomically (temp
  file + rename).
- Recordings are stored apart from transcripts: deleting a transcript never deletes its
  recording, and deleting a recording folder in Finder leaves the transcript.

### Crash recovery

At launch, after `markAbandonedJobs` and before any job can start, every folder in the recordings
folder whose `recording.json` says `recording` is finalised as `finished`. If no transcript
points at it, an `incomplete` call transcript is created for it with the reason
`Macomprendo quit before it finished.`, so it shows up in the Transcripts window and `Resume`
transcribes it.

### Menu bar

- While recording, the status item shows the SF Symbol `record.circle` (template) and the elapsed
  time next to it, `12:04` (`1:02:04` past an hour). `MenuBarExtra` moves to its
  `content:label:` form for this. The status item remains the one SF Symbol exception of
  invariant 12.
- While recording, the menu opens with:

  ```
  Recording call — 12:04
  Me      ▮▮▮▮▮▯▯▯▯▯
  Others  ▮▮▯▯▯▯▯▯▯▯
  Stop Recording                ⌥⌘R
  ```

  The level rows are text: ten cells, filled in proportion to `AudioMath.level` of the last
  100 ms. The menu is an `NSMenu` (`.menuBarExtraStyle(.menu)`); if a native menu does not
  re-render while open, the rows show the levels as of opening. Either is acceptable.
- There is no other indicator, warning or hint.

### Settings

- Settings ▸ General gains a **Call recordings** section: the folder path, **Choose…**,
  **Show in Finder**, and `Recordings use 1.4 GB` — the total size of the recordings folder,
  computed off the main thread when the tab appears.
- Settings ▸ Hotkeys gains **Record Call**, with no default shortcut (as Refine Selection).
  `recordCall` joins `HotkeyAction`, so it also gets its enable toggle in the menu's hotkey list;
  the **Record Call** / **Stop Recording** item is separate and sits next to **Transcribe File…**.

### Transcription

- After Stop, `FileTranscriptionController` starts a call job. As with files, a newer job
  cancels the running one, which becomes `incomplete` and resumable.
- The transcript: `source_kind = call`, title `Call 2026-10-15 16:42`, `source_bookmark` = a
  bookmark to the recording folder, `duration_s` = the recording's elapsed wall-clock time (the
  stop instant minus the start instant).
- The **Me** track is transcribed first, then **Others**, each through `LongAudioPipeline`
  unchanged. Every segment is shifted by its track's `startOffset` and stored with its
  `speaker`. Queries already order segments by `start_s`, which interleaves the two sides.
- Progress reads `Transcribing Me — 12:40 / 58:03`, then `Transcribing Others — …`.
- A track with no speech is not an error. Only when neither track has speech does the job fail
  as `noSpeechFound` and delete the empty transcript; the recording stays.
- `Resume` continues the last track that has segments from the end of its last segment, then
  transcribes any track after it. When the folder bookmark no longer resolves, or a track file
  is missing, `Resume` reports `callRecordingUnavailable` and shows **Choose Folder…**; the
  chosen folder must contain a `recording.json` and becomes the new bookmark.

### Transcripts window

- A call segment row reads `[00:12:04] Me: text`.
- A call transcript adds **Show in Finder**, which reveals its recording folder.
- `Copy` and `Summarize` use `Me: text` lines; Summarize is otherwise unchanged (Quick Panel,
  nothing stored).
- Export: `.txt` — `Me: text` per line; `.srt` — the cue text is prefixed with `Me: `; `.md` —
  `**[hh:mm:ss] Me:** text`. File transcripts export as before.

### Live transcription later

Capture pushes every converted buffer, with its track and session-clock time, to its track's
writer. This stage has one capture handler per track feeding one `CallAudioSink`; the fan-out to
an array of sinks does not exist yet. A later stage adds it, with a segmenter sink per track
appending segments while recording; the capture, the files and the store do not change.

### Errors

New `MacomprendoError` cases, each with `errorDescription` and `recoverySuggestion`:

- `systemAudioCaptureFailed(String)` — the tap or its aggregate device cannot be created or
  started (the OSStatus goes in the reason).
- `callRecordingLocationUnavailable` — the recordings folder cannot be created or written; the
  suggestion points at Settings ▸ General.
- `callRecordingWriteFailed(String)` — a track file cannot be written; the recording stops, and
  what was written is kept and transcribed.
- `callRecordingUnavailable` — `Resume` cannot find the recording folder or a track file.

## Architecture

Layers keep pointing downward (UI → Features → Services/Providers → Core); every concrete
service is built in `AppEnvironment`.

| Layer | Unit | Role |
|---|---|---|
| Core | `CallRecordingLayout` | Pure: folder and file names from a start date, collision suffix |
| Core | `CallRecordingManifest` | `recording.json` value type, `Codable`, atomic write |
| Core | `CallTrack`, `TranscriptSpeaker` | `me` / `others` |
| Core | `TranscriptSegment.speaker` | `TranscriptSpeaker?`; `nil` for file transcripts |
| Core | `Settings.callRecordingsDirectory` | Recordings folder path |
| Services | `SystemAudioCapturing` / `ProcessTapSystemAudioCapture` | Global tap, tap-only aggregate, output-change rebuild; buffers + host time |
| Services | `CallMicrophoneCapturing` / `EngineCallMicrophoneCapture` | Raw `AVAudioEngine` on the chosen input; device-change restart |
| Services | `CallAudioSink`, `CallTrackWriting` / `AssetCallTrackWriter` | Gap padding on the session clock; fragmented AAC `.m4a` |
| Services | `CallRecordingFolders` | Create a folder, list unfinished ones, total size |
| Services | `TranscriptStoring` | Schema v2: `transcript_segments.speaker` |
| Features | `CallRecordingController` | `@MainActor`; `idle → starting → recording(startedAt) → stopping → idle / failed(message)`; levels; elapsed time |
| Features | `CallTranscriptionJob` | Two tracks through `LongAudioPipeline`, offsets, speaker, per-track resume |
| Features | `FileTranscriptionController` | Runs file and call jobs; one at a time |
| UI | Menu bar label and menu rows, Settings section, Transcripts rows and actions | |

### Store schema v2

`PRAGMA user_version` 1 → 2 adds
`transcript_segments.speaker TEXT NULL CHECK (speaker IN ('me','others'))`. Existing rows keep
`NULL`. The migration runs once at open.

### Platform

`MACOSX_DEPLOYMENT_TARGET` and both `deploymentTarget` entries in `macos/project.yml`, and
`platforms` in `macos/Package.swift`, move from 14.0 to 14.2, the first release with process
taps.

## Privacy

- Recordings stay in the folder the user chose. Audio leaves the machine only to the
  transcription endpoint the user configured, segment by segment, as for files.
- No transcript text, file name or folder name is logged at default level (invariant 6).

## Testing

Unit tests (swift-testing, written first), with fakes for every new protocol:

- `CallRecordingLayout`: names for a given date and time zone, the ` (2)` suffix, files follow
  the folder.
- `CallRecordingManifest`: round trip, atomic write, unknown `version` rejected.
- `AssetCallTrackWriter` gap logic, on synthetic buffers through a fake encoder: a 2 s hole is
  padded with 2 s of zeros, a 30 ms hole is not, the first buffer's offset becomes
  `startOffset`.
- `CallRecordingController`: state order; start fails cleanly on denied microphone and on an
  unwritable folder (no folder left behind); Stop during `starting`; Stop finalises, writes
  `finished` and starts a call job; sleep stops; quit leaves an `incomplete` transcript and no
  job; a writer failure stops with `callRecordingWriteFailed` and keeps the files.
- Crash recovery: a `recording` folder becomes `finished` and gains one `incomplete` transcript;
  a second launch adds none.
- `CallTranscriptionJob`: Me before Others; segments shifted by each `startOffset` and labelled;
  one silent track still completes; both silent → `noSpeechFound` and the transcript deleted;
  resume mid-Me and mid-Others; missing folder → `callRecordingUnavailable`; a chosen folder
  replaces the bookmark.
- `SQLiteTranscriptStore`: v1 database migrates to v2 with `NULL` speakers; speaker round trip.
- `TranscriptExporter`: txt, srt and md with speakers; file transcripts unchanged.
- Folder size: sums nested files, ignores a missing folder.

`docs/SMOKE_TEST.md` gains: a call over built-in speakers, over wired headphones, and over
AirPods (with the Mac's microphone and with the AirPods' own); switching output mid-call;
unplugging the chosen microphone mid-call; dictating during a recording; the menu bar timer and
level rows; declining System Audio Recording; quitting mid-recording and `Resume`; killing the
app mid-recording and relaunching; a one-hour call (memory flat, files play).

## Documents

- ADR `0017-call-audio-via-process-tap-with-raw-mic.md`: process tap rather than
  ScreenCaptureKit (no Screen Recording permission); raw microphone and no echo cancellation,
  because voice processing in the same process silences process taps and dictation and muffles
  the user's outgoing call audio (moona3k/macparakeet `docs/research/vpio-process-tap-conflict.md`);
  the reported Bluetooth hands-free tap silence is accepted unverified.
- ADR `0018-call-recording-folder-layout.md`: folder per recording, two named `.m4a` tracks,
  `recording.json`, fragmented MP4, storage apart from transcripts.
- `docs/ARCHITECTURE.md` gains a *Call recording* section.
- `CHANGELOG.md` `Unreleased`: call recording, the macOS 14.2 requirement.

## Out of scope

- Echo cancellation or duplicate suppression of any kind.
- Transcribing during the call (the next stage; see *Live transcription later*).
- Per-app capture, automatic call detection, pause, a mixed playback file, a floating recording
  panel, warnings about a silent side, a headphones hint, a ScreenCaptureKit fallback.
- Listing or deleting recordings inside the app beyond the Settings total and Show in Finder.
- Stored summaries.
