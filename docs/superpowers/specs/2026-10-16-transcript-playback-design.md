# Transcript playback

## Goal

Play a transcript's audio from the Transcripts window: a player bar with a seek bar, play/pause,
±15 s skips and a speed menu, and a marker in the text on the segment that is playing. This works
for both kinds of transcript: a file transcript plays its source file, and a call transcript plays
its two tracks mixed back into the conversation. It builds on
`2026-10-14-file-transcription-design.md` (window, store, bookmarks) and
`2026-10-15-call-recording-design.md` (track files, `recording.json`, speakers).

## Vocabulary

- **Playback source** — what a transcript plays: one file (`file`), or the tracks of a call
  recording placed on the recording's timeline at their `startOffset`s (`call`).
- **Position** — the playhead, in seconds on the transcript's timeline. Segment `start`/`end` are
  already on that timeline for both kinds, so a position compares with them directly.
- **Active segment** — the segment the marker sits on at the current position.
- **Follow** — the list scrolls to keep the active segment in view.

## Behaviour

### Player bar

- The bar sits at the bottom of the transcript detail, under the segment list, for every
  transcript whose audio can be found. Left to right:
  `↺15  ▶︎/❚❚  15↻   ────●────   12:04 / 45:10   1× ▾   [Me] [Others]`.
- **Play/Pause** toggles. At the end, playback stops on the last frame; the next **Play** starts
  from 0.
- **↺15 / 15↻** move the position 15 s back or forward, clamped to `0…duration`; they keep the
  play/pause state.
- The **seek bar** shows the position and moves it when dragged or clicked. While the user drags,
  the bar follows the pointer, not the player; the player seeks on release. Elapsed and total time
  read `m:ss`, or `h:mm:ss` from an hour.
- The **speed menu** offers 1×, 1.25×, 1.5×, 2×. Speech keeps its pitch. The choice lasts for the
  window's lifetime and applies to the next transcript opened in it; it is not a setting.
- **Me / Others** (call transcripts only) are toggles, both on by default. Turning one off silences
  that side; turning both off is allowed (silence plays). A side whose track file is missing shows
  its toggle disabled with the tooltip "This side's track is missing".
- Opening another transcript, closing the window, or starting a call recording stops playback.
  Playback is otherwise independent of transcription: a transcript that is still being
  transcribed, or is incomplete, plays whatever audio exists.

### Marker in the text

- The active segment's row gets an accent-tinted background. The active segment is the
  latest-starting segment with `start ≤ position ≤ end + 1 s`; in a longer pause nothing is
  marked. So when two speakers overlap, the one that started later is marked, and when a short
  reply ends inside a long one, the marker goes back to the long one. Segments are sorted by
  `start` (they are stored and shown in that order), and the lookup only looks back 120 s, longer
  than any stored segment.
- The marker shows while playing and while paused at a position other than 0; before the first
  **Play** nothing is marked.
- While playing, the list follows the active segment, keeping it in view with a little context
  above it. A manual scroll (scroll wheel or trackpad over the list) turns follow off and shows a
  **Back to current** button over the list's bottom edge; pressing it scrolls back and turns follow
  on again. Seeking from a timestamp or the seek bar also turns follow on.
- Each segment's timestamp `[00:12]` is a link-styled button: a click seeks to the segment's
  `start` and plays. The segment text stays selectable for copying, as today.

### When the audio cannot be played

- A **file** transcript whose bookmark no longer resolves, or a **call** transcript whose folder,
  `recording.json` or both track files are gone, shows a one-line strip in place of the bar:
  "Audio unavailable — <reason>" with the existing **Choose File…** / **Choose Folder…** button.
  Choosing a new location there stores the new bookmark exactly as Resume's does, then loads the
  player; it does not start transcription.
- A file AVFoundation cannot play (no audio track, unsupported codec) shows the same strip with
  the reason and no button.
- A call with one track missing plays the other (see the Me / Others toggles).
- Playback failing mid-way (device gone, decode error) pauses, keeps the position, and shows the
  error in the strip until the next **Play**.

## Architecture

```
UI/Transcripts/TranscriptsView        player bar, marker, timestamp buttons, follow
UI/Transcripts/TranscriptPlayerBar    the bar itself
Features/TranscriptPlaybackController @MainActor, state enum, owns one player
Services/TranscriptAudioPlayer        protocol TranscriptAudioPlaying + AVPlayer implementation
Services/PlaybackComposition          builds the AVAsset for a playback source
Core/PlaybackTimeline                 active-segment lookup, time formatting
Core/PlaybackSource                   .file(URL) / .call([PlaybackTrack])
```

- **`PlaybackSource`** (Core): `.file(URL)` or `.call([PlaybackTrack])`, where `PlaybackTrack` is
  `(speaker: TranscriptSpeaker, url: URL, offset: TimeInterval)`.
- **`PlaybackTimeline`** (Core, pure): built from the segments; `activeIndex(at:)` is a binary
  search implementing the rule above, plus the `m:ss` / `h:mm:ss` formatter.
- **Source resolution** (in the controller, through existing services): a file transcript
  resolves its bookmark with `FileBookmarking`. A call transcript resolves the folder bookmark,
  reads `CallRecordingManifest.read(from:)`, and keeps the tracks that have a `startOffset` and
  whose file exists (`CallRecordingFolderManaging.fileExists`). No tracks left → unavailable.
- **`PlaybackComposition`** (Services): `.file` → `AVURLAsset`; `.call` → an
  `AVMutableComposition` with one audio track per playback track, inserted at its `offset`, plus
  an `AVAudioMix` whose per-track volume is the toggle (1 or 0). Built with the async
  `AVAsset.load` APIs. This is AVFoundation, but deterministic and file-based, so it is unit-tested
  with short generated audio files.
- **`TranscriptAudioPlaying`** (Services, `@MainActor` protocol), default `AVTranscriptAudioPlayer`
  on `AVPlayer`:
  `load(_ source:) async throws -> TimeInterval` (duration), `play()`, `pause()`,
  `seek(to:) async`, `rate`, `setMuted(_:for:)`, `onPosition` (about every 0.25 s while playing
  and once after every seek), `onEnded`, `onFailed`. `audioTimePitchAlgorithm = .timeDomain` keeps
  pitch. A video file plays only its sound, since no layer is attached. Thin glue covered by the
  smoke test; a `FakeTranscriptAudioPlayer` in `Tests/…/Fakes` drives the controller tests.
- **`TranscriptPlaybackController`** (Features, `@MainActor`): state
  `idle | loading | unavailable(reason, recovery) | ready(position, duration, isPlaying)`, plus
  `rate`, the toggles, `activeSegmentIndex` and `isFollowing`. `open(transcript)` cancels any
  in-flight load (a new transcript wins), stops the previous player, resolves and loads the
  source. One in-flight load at a time. `AppModel` stops it when a call recording starts.
  Constructed in `AppEnvironment` like every other controller.
- **Follow detection.** macOS 14 has no SwiftUI API that reports a user scroll, so the view
  installs a local `NSEvent` monitor for `.scrollWheel` while the window is key and the pointer is
  over the list, and turns follow off on the first event. The monitor is removed when the view
  disappears. Programmatic scrolling (`ScrollViewReader.scrollTo`) sends no scroll-wheel event and
  so does not trip it.
- **Rendering.** Rows keep today's identity (the segment's index). A row takes `isActive: Bool`,
  so a marker move re-renders two rows, not the list. The bar's position updates don't touch the
  list.
- **Errors.** One new case, `MacomprendoError.transcriptPlaybackUnavailable(String)`, with
  `errorDescription` "Can't play this transcript's audio" and a recovery suggestion naming
  **Choose File…** / **Choose Folder…** when the source moved. Reasons never include transcript
  text.

### Interaction with recording

The process tap excludes Macomprendo's own process (ADR-0017), so audio played here never lands
in a call's **Others** track. Playback still stops when a recording starts, so a call does not
begin with the app talking.

## Privacy

Playback reads only files the user already gave the app (bookmarks) and its own recordings. No
network. Nothing about playback is logged beyond `Log.ui.debug` state transitions without paths
or text.

## Testing

TDD for the logic; the AVPlayer glue, the marker's look and follow are smoke-tested.

- `PlaybackTimelineTests`: before the first segment; inside a segment; in a gap within and past
  the 1 s grace; overlapping speakers pick the later start; the last segment and past its end;
  empty transcript; formatter at 0, 59.9, 60, 3599, 3600 s.
- `PlaybackCompositionTests` (generated WAV files, a few hundred ms): a file source loads with the
  file's duration; a call source places each track at its offset (the composition track's first
  segment starts at the offset) and the duration is the furthest track end; the audio mix sets
  volume 0 for a muted side.
- `TranscriptPlaybackControllerTests` with `FakeTranscriptAudioPlayer`, fake bookmarks and fake
  folders: file and call resolution; a missing folder / manifest / both tracks → `unavailable`
  with the matching reason; one missing track → plays the other with its toggle disabled;
  play/pause/±15 s clamping; seeking from a segment plays and turns follow on; position updates
  move `activeSegmentIndex`; opening another transcript stops the previous player and drops a
  late result of the previous load; end of playback; `onFailed` pauses and reports; the rate
  persists across `open`.
- `docs/SMOKE_TEST.md` gains a **Transcript playback** section: file transcript (audio and
  video), call transcript with both sides and each side muted, speeds (pitch kept), seek bar drag,
  timestamp click, marker and follow, **Back to current**, moved file → strip → Choose File…,
  playback during dictation and when a recording starts.

## Documents

- `CHANGELOG.md` `Unreleased`: the player.
- `docs/ARCHITECTURE.md`: the playback controller and service in the Transcripts section.
- No ADR: the choice of `AVPlayer` + composition is local to this feature and recorded here.

## Out of scope

- Keyboard shortcuts (Space would fight the title field and text selection).
- A waveform in the seek bar.
- Playing a recording that is still being recorded.
- Word-level highlighting (segments are the finest unit stored).
- Remembering the position per transcript across launches.
