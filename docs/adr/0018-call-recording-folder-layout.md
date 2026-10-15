# ADR-0018: A call recording is a folder of two tracks and a manifest

## Status

Accepted — 2026-10-15.

## Context

A call recording is two audio files that are transcribed together and read as one call. After a
crash, a force-quit or a power loss, three things still have to hold: the audio already written is
playable, a later launch can tell the recording was cut short, and the transcription job can place
both tracks on one clock so a segment's time means the same thing whichever side it came from.
Nothing about the layout may depend on the app still running.

## Decision

**One folder per recording**, named after the local start time: `rec yyyy-MM-dd HH-mm-ss`
(`rec 2026-10-15 16-42-07`). Hyphens stand where a clock has colons, because Finder shows a colon
as “/” and some volumes (SMB, FAT) forbid it. If the name is taken (two starts in the same second),
` (2)`, ` (3)`… is appended to the folder name and the file names follow it.

**Two named tracks** inside the folder, `<folder name> Me.m4a` and `<folder name> Others.m4a`,
beside `recording.json`. The name carries the speaker, so a file found on its own says which side
it is.

**48 kHz mono `Float32` in, AAC 48 kbit/s out** — ADR-0011's voice bitrate — written by
`AVAssetWriter` as a **fragmented MP4 with a 1 s `movieFragmentInterval`**. A crash loses at most
the last second and leaves a playable `.m4a`, and the file is readable mid-recording; `finishWriting`
consolidates the fragments at stop.

**`recording.json` is the manifest**, a `Codable` value type:

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

`status` is `recording` until Stop or quit finalises it as `finished`. `startOffset` is the seconds
from the session start to the track's first sample, on the **mach host clock** both tracks are
placed on (`HostClock`, the same reference `AVAudioTime` uses for tap timestamps). The manifest is
written atomically (temp file + rename) and rewritten as soon as each track's offset is known,
while the status stays `recording`, so a crash — which no `finished` write ever follows — still
tells launch recovery where each track starts.

**Gaps are padded on the host clock.** Every gap — a tap rebuild, a device change, a stalled
callback — is filled with silence measured on the session clock, so second *t* of either file is
second *t* of the call. Gaps shorter than 50 ms are host-clock jitter and are not padded; slow clock
drift between the two devices is not corrected.

**Storage is apart from transcripts.** Recordings live in `Settings.callRecordingsDirectory`,
default `~/Library/Application Support/Macomprendo/Recordings` — outside the TCC-protected
Documents, Desktop and Downloads folders. Deleting a transcript never deletes its recording, and
deleting a recording folder in Finder leaves the transcript.

**Launch recovery.** After `markAbandonedJobs` and before any job can start, every folder whose
`recording.json` says `recording` is finalised `finished`; if no transcript points at it, an
`incomplete` call transcript is created with the reason `Macomprendo quit before it finished.`, so
it appears in the Transcripts window and `Resume` transcribes it.

## Consequences

- A crash costs at most the last second of each track, and what survives plays.
- The transcript row is created **before** the manifest is marked `finished`, in the recorder and in
  launch recovery. A `create` that fails, or a crash in that window, leaves the folder `recording`,
  and the next launch finalises it and creates no second row — the row is what is missing, not the
  audio. A folder whose bookmark cannot be made is left `recording` too, rather than collecting a
  duplicate row on every launch.
- Both tracks are ordinary `.m4a` files: they play in QuickTime, and the pipeline decodes them with
  the same `AVAssetReader` a file transcript uses.
- The two raw tracks are the durable truth. A later stage can add a live sink per track (the spec's
  *Live transcription later*) without changing the files, the manifest or the store, and an offline
  cleaned-microphone artifact could be derived beside them.
