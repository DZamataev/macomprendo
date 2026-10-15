# ADR-0017: Call audio comes from a global process tap and a raw microphone

## Status

Accepted — 2026-10-15.

## Context

A call recording captures two sides at once: the microphone — **Me** — and everything the Mac
plays — **Others** — while dictation keeps working during the recording. The system side has to
be captured without asking for the Screen Recording permission, and the microphone side has to
hold what the microphone actually heard.

Two forces pull on the microphone. When the call plays through the speakers, the microphone also
hears the far end through the air, so their words can be transcribed a second time as **Me**.
Apple's voice processing (`AVAudioInputNode.setVoiceProcessingEnabled`) is the obvious tool — its
whole job is subtracting speaker audio from microphone input — but it cannot be enabled in the
same process as a Core Audio process tap, and the process tap is what captures the system side.

moona3k/macparakeet hit that collision directly and wrote it down
(`docs/research/vpio-process-tap-conflict.md`). With voice processing enabled, a process tap
delivered **header-only files** (557 bytes, no audio) and a following dictation engine read
silence; `VPAUAggregateAudioDevice` and `CADefaultDeviceAggregate-<PID>-N` devices outlived the
engine and broke the next one. Voice processing is a duplex I/O unit, not an input filter:
enabling it flips the output node too, mutates the input format from mono to multichannel, and
alters the process's HAL device topology. macparakeet then removed the tap by moving system audio
to ScreenCaptureKit, tried voice processing on the microphone anyway, and dropped it a second
time after live-call testing showed it **muffled the user's outgoing call audio** for the other
participants. Its shipped meeting microphone is raw, with any echo handling done offline on the
two recorded tracks.

## Decision

**System audio: a global Core Audio process tap.** `CATapDescription(stereoGlobalTapButExcludeProcesses:)`
with this app's own process object as the exclusion — everything the Mac plays except
Macomprendo — and `muteBehavior = .unmuted`, so the call keeps playing while it is recorded. The
tap is read through a private aggregate device built around the tap alone: no
`kAudioAggregateDeviceMainSubDeviceKey`, an empty sub-device list, `IsPrivate = true`,
`TapAutoStart = true` and drift compensation on. That tap-only aggregate is the shape quill uses,
and it keeps the aggregate off the default output device whose Bluetooth profile can flip.

**Microphone: raw.** A second `AVAudioEngine`, its input node bound to the microphone dictation
is set to use, in the device's own format, converted to 48 kHz mono. No voice processing, no echo
cancellation, no noise suppression — the **Me** track must hold what the microphone heard.

**No echo handling.** Over speakers the far end can appear under **Me** as well as under
**Others**. That is accepted: both tracks are stored raw, and a later offline pass in
macparakeet's ADR-028 shape could align them and render a cleaned microphone artifact without
touching capture. The spec keeps echo cancellation and duplicate suppression out of scope.

**Not ScreenCaptureKit.** ScreenCaptureKit's audio path would free the process of the tap and let
voice processing be reconsidered, but it requires the **Screen Recording** permission and a dummy
video target, whereas a process tap needs only the **System Audio Recording** grant, which is
what `NSAudioCaptureUsageDescription` describes. The spec's out-of-scope list rules out a
ScreenCaptureKit fallback.

**Dictation keeps working during a recording.** Each feature owns its own `AVAudioEngine` and
neither enables voice processing, so the HAL multiplexes microphone input across them; local-model
calls are already serialised by `TranscriptionLane`.

## Consequences

- **The far end can appear under Me over speakers.** Accepted, and it is why the two tracks are
  kept raw: a later stage can align them and subtract one from the other without changing capture.
- **A reported Bluetooth tap silence is accepted unverified.** meetrec reports that the Process Tap
  API silently delivers no callbacks when the default output is Bluetooth in HFP/SCO mode (AirPods
  while the app also records from the microphone) — `AudioDeviceStart` returns `noErr` but the IO
  proc never fires — and moved to ScreenCaptureKit for that reason. The claim has no repro, test or
  filed issue behind it, and the tap-only aggregate is the one structural difference that might
  avoid it, untested. The smoke test records a call over AirPods with the AirPods' own microphone
  (the hands-free profile) and accepts whatever it shows.
- **An output-device change rebuilds the tap.** The aggregate is bound to the output device present
  when it was created, so a change of the system default output tears the tap and its aggregate
  down and rebuilds them on the new route, writing into the same file; a failed rebuild leaves the
  system capture stopped rather than recording the wrong route. A change of the chosen input device
  restarts the microphone engine the same way.
- **macOS 14.2 is the minimum**, the first release with process taps. `MACOSX_DEPLOYMENT_TARGET`,
  both `deploymentTarget` entries in `macos/project.yml`, `platforms` in `macos/Package.swift` and
  `LSMinimumSystemVersion` all say 14.2.
- **A declined System Audio Recording grant is silent.** There is no public preflight for it. If the
  user declines, the tap delivers silence: the recording continues, the **Others** level row stays
  empty, and the transcript has no Others segments. Nothing else reports it.
