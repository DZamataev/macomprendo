# ADR-0019: A call is detected by polling which processes use the microphone

## Status

Accepted — 2026-10-19.

## Context

Automatic call recording has to notice, on its own, that a call began and that it ended — off by
default, with no permission the app does not already need, and without opening the microphone to
find out. The app already knows how to capture a call (ADR-0017) and how to lay one out on disk
(ADR-0018); the missing piece is the signal. Nothing in the app may ask for a new grant: the
recording itself needs the microphone and the System Audio Recording grant, and a *detector* that
added a third prompt would be refused by users and, on macOS, could not be silently retried.

The candidates:

- **Window titles or calendar events.** Accurate about intent — a Zoom window called a meeting —
  but titles need the Accessibility grant and calendar needs the Calendar grant. Out of scope in
  the spec.
- **ScreenCaptureKit's app list.** Reports which apps are producing audio, but only behind the
  Screen Recording permission and a dummy video target — the exact cost ADR-0017 rejected for the
  capture itself.
- **Core Audio process-object listeners.** `kAudioProcessPropertyIsRunningInput` has an
  add-property-listener interface, which would remove the polling. moona3k/macparakeet reports the
  per-process input listener never firing on macOS 26; with no repro of our own, a listener that
  silently never fires is a detector that silently never detects.
- **The default device's `kAudioDevicePropertyDeviceIsRunningSomewhere`.** No per-process
  attribution: it cannot tell a call from music, Siri or a dictation.

## Decision

**Poll Core Audio's process object list once a second while the setting is on.**
`kAudioHardwarePropertyProcessObjectList` on `kAudioObjectSystemObject` (macOS 14.2+), then per
object `kAudioProcessPropertyPID`, `kAudioProcessPropertyBundleID`,
`kAudioProcessPropertyIsRunningInput` and `kAudioProcessPropertyIsRunningOutput`. Verified with an
unsigned command-line probe on macOS 26.5: every one of those reads returns without a permission
prompt.

**Input is the call signal; output is only a browser's corroboration.** Several idle apps report
`IsRunningOutput = 1` while playing nothing, so output alone means nothing. An **App** entry
(Zoom, Teams, Telegram…) is in a call when a process it matches is running input. A **Browser**
entry (Chrome, Safari…) additionally requires output across the processes it matches, because a
browser holds the microphone for dictation sites and voice notes too.

**Matching is by bundle-ID prefix at a `.` boundary.** `com.google.Chrome` covers
`com.google.Chrome.helper` but not `com.google.Chromex`, and `com.microsoft.teams` does not cover
`com.microsoft.teams2` — which is why the built-in list carries both Teams rows. The app's own
process is excluded by PID: its dictation and its call capture use the microphone too.

**The list is the user's, and it is editable.** A bundle ID is an implementation detail of the
app, and some are surprising (`com.apple.WebKit.GPU` is Safari's capture process, not Safari).
Settings ▸ General lists the entries, *Using the microphone now* offers every input process no
entry covers with one **Add** press, and the wrong entry is removed rather than worked around.

**Timing lives outside the detector.** The 3 s start filter and the 15 s stop grace are a pure
state machine fed one answer per second, so every edge is a unit test and the detector stays a
one-function reader of the OS.

## Consequences

- **No new permission, no microphone.** Detection cannot prompt and cannot interfere with the call
  it is watching.
- **Detection is as good as the bundle ID.** An app that captures through a helper process the
  list does not name is invisible until the user adds it. Which process holds the microphone
  during a FaceTime, Safari and Telegram call is unverified — the smoke test reads the real IDs
  with *Using the microphone now* and the built-in table is corrected then.
- **Up to a second of latency, plus the deliberate 3 s / 15 s windows.** A call shorter than three
  seconds is not recorded at all; a call's last fifteen seconds of silence are inside the
  recording.
- **Polling costs one snapshot a second, only while the switch is on**, and nothing is polled with
  it off. Ten to a few dozen processes, four properties each.
- **A failed start is final for that call.** The recorder's `failed` state is indistinguishable
  from a hand stop, so the policy treats both as a stop to respect: no retry until the call has
  been gone for 15 s. Retrying every second could spam the same failure.
- **A listener remains the upgrade path** if the reported never-firing input listener turns out to
  be fixed on a later macOS: the protocol is one function, and the policy would not change.
