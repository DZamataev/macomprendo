# Automatic call recording

## Goal

Start a call recording by itself when a call begins, and stop it when the call ends, so a call
is never lost because nobody pressed **Record Call**. Off by default. It drives the existing
recorder from `2026-10-15-call-recording-design.md` unchanged: the same two tracks, folder,
transcript and "transcribe after Stop" behaviour. Only *who presses Start and Stop* is new.

## Vocabulary

- **Audio process** — a process macOS reports through Core Audio's process object list
  (`kAudioHardwarePropertyProcessObjectList`, macOS 14.2+), with its PID, bundle ID and whether
  it is running audio input (`kAudioProcessPropertyIsRunningInput`) and output
  (`kAudioProcessPropertyIsRunningOutput`).
- **Call app** — an entry in the user's list: a display name, a bundle-ID prefix, and a kind.
  - **App** kind (Zoom, Teams, Telegram…): its process using the microphone means a call.
  - **Browser** kind (Chrome, Safari…): a call only when one of its processes uses the
    microphone **and** one plays audio at the same time — a browser holds the microphone for
    dictation sites and voice notes too.
- **Active call** — the first call app that matches the current snapshot.
- **Automatic recording** — a recording this feature started. A recording the user started
  stays the user's: this feature never stops it.

## Behaviour

### Detecting

- Every second the monitor takes a snapshot of the audio processes. Detection needs no
  permission and does not touch the microphone.
- A process matches an entry when its bundle ID equals the entry's prefix or starts with the
  prefix followed by `.` — so `com.google.Chrome` covers `com.google.Chrome.helper`.
- Macomprendo's own process never matches (by PID): its dictation and its call capture use
  the microphone too.
- Entries are checked in list order; the first match is the active call.

### Starting

- With the setting on, an active call that lasts **3 s** of consecutive snapshots starts a
  recording, provided the recorder is idle or failed. The 3 s filter out a microphone test or
  a voice-note blip.
- The HUD toasts `Recording call — <name>`.
- A recording already running, automatic or manual, is left alone.

### Stopping

- An automatic recording stops once no call app has been active for **15 s**. The grace
  covers apps that release the microphone while muted; a call that really ended costs 15 s of
  silence in the recording.
- The stop is the ordinary one (`CallRecordingController.toggle()` while recording): the call
  is then transcribed or left waiting exactly as the existing setting says.
- The HUD toasts `Call ended — recording stopped`.
- A recording the user started is never stopped automatically.

### The user overrides

- Stopping an automatic recording by hand (menu, panel, hotkey) is respected: no new
  automatic recording starts until the active call has been gone for 15 s, i.e. until that
  call is over.
- **A failed automatic start counts as a stop to respect.** The policy sees only
  `CallRecordingController.isRecording`, so a recorder that went to `failed` is indistinguishable
  from a hand stop: no retry until the call has been gone for 15 s. Retrying every second would
  only spam the same failure.
- **The 15 s re-arm counts from when the call disappears**, not from the hand stop: a user who
  stops the recording two seconds into a call still gets the feature back 15 s after that call
  ends.
- Turning the setting off while an automatic recording runs leaves the recording running; it
  is then the user's to stop.
- Quitting or sleeping stops it as today (`systemWillSleep`, termination). Quitting stops the
  auto-recorder loop **first** of all (`AppModel.shutdown`): a tick that saw the recorder idle
  after the call recording was finalised would otherwise start a fresh recording while the
  process is terminating.

### Settings

- `autoRecordCalls: Bool`, default `false`.
- `autoRecordApps: [CallApp]`, default the built-in list below. Decoded with
  `decodeIfPresent`, like every other setting; a stored list replaces the default entirely, so
  a removed entry stays removed.
- **Menubar panel ▸ Options:** a switch row *Record calls automatically*, after *Transcribe
  calls after Stop*.
- **Settings ▸ General ▸ Call recordings:**
  - Toggle *Record calls automatically*, with a caption: *Starts recording when a call app
    from the list below uses the microphone, and stops when the call ends. Many places require
    everyone's consent before a call is recorded; telling them is up to you.*
  - Everything below appears only while the switch is on: the built-in list is sixteen rows
    long, and the rest of the tab must not be buried under a feature that is off. Adding an
    entry whose prefix is already in the list does nothing — the prefix is the list's identity.
  - The list of call apps: name, bundle-ID prefix, kind (App / Browser), and a remove button
    per row.
  - *Using the microphone now* — the audio processes currently running input that no entry
    matches, each with **Add**. Add creates an App entry with the process's bundle ID and
    the app's localized name (`NSRunningApplication(processIdentifier:)`, falling back to the
    bundle ID). This is how a user adds an app whose bundle ID they do not know: start a call,
    open Settings, press Add. The section refreshes every second while it is shown.
  - A manual row: a bundle-ID text field, a kind picker and **Add**, for adding an app ahead
    of its first call.
  - **Restore Default Apps** replaces the list with the built-in one.

### The built-in list

| Name | Prefix | Kind |
|---|---|---|
| Zoom | `us.zoom.xos` | App |
| Microsoft Teams | `com.microsoft.teams2` | App |
| Microsoft Teams (classic) | `com.microsoft.teams` | App |
| FaceTime | `com.apple.FaceTime` | App |
| Slack | `com.tinyspeck.slackmacgap` | App |
| Webex | `Cisco-Systems.Spark` | App |
| Telegram | `ru.keepcoder.Telegram` | App |
| Telegram Desktop | `org.telegram.desktop` | App |
| WhatsApp | `net.whatsapp.WhatsApp` | App |
| Discord | `com.hnc.Discord` | App |
| Google Chrome | `com.google.Chrome` | Browser |
| Safari | `com.apple.WebKit.GPU` | Browser |
| Arc | `company.thebrowser.Browser` | Browser |
| Microsoft Edge | `com.microsoft.edgemac` | Browser |
| Firefox | `org.mozilla.firefox` | Browser |
| Yandex Browser | `ru.yandex.desktop.yandex-browser` | Browser |

`com.microsoft.teams` is a prefix of `com.microsoft.teams2` only textually; the `.`-boundary
rule keeps them apart, so both rows are needed. Safari captures through the shared WebKit GPU
process, so its row names that process. Which process actually holds the microphone during a
call in FaceTime, Safari and Telegram is **unverified** — see *Verified platform facts*; the
*Using the microphone now* list is the fallback for any entry that turns out wrong.

## Architecture

- **Core/CallApp.swift** — `struct AudioProcessActivity: Sendable, Equatable` (`pid: pid_t`,
  `bundleID: String?`, `isRunningInput`, `isRunningOutput`); `struct CallApp: Codable,
  Sendable, Equatable, Identifiable` (`name`, `bundleIDPrefix`, `kind: Kind` with `.app` /
  `.browser`, `id` = `bundleIDPrefix`); `CallApp.defaults`; and the pure matcher
  `CallApp.activeCall(in: [AudioProcessActivity], apps: [CallApp], excludingPID: pid_t) ->
  CallApp?`. Both are plain values in Core so `Settings` and the matcher need nothing above
  Core (invariant 1).
- **Services/AudioProcessMonitor.swift** — `protocol AudioProcessMonitoring: Sendable { func
  snapshot() -> [AudioProcessActivity] }` and `CoreAudioProcessMonitor`, the thin Core Audio
  reader. Polling, not listeners: one open-source report says the per-process input listener
  never fires on macOS 26, and a 1 s read of a few properties per process is cheap.
- **Features/AutoCallRecordPolicy.swift** — a pure value-type state machine. Input per tick:
  the active call (or nil), the time, whether the recorder is busy, and whether the running
  recording is the policy's own. Output: `.start(CallApp)`, `.stop`, or nothing. Holds the
  3 s / 15 s timers and the hand-stop suppression.
- **Features/AutoCallRecorder.swift** — `@MainActor` controller: a 1 s loop reading the
  monitor, feeding the policy, calling `CallRecordingController.toggle()`, and toasting.
  Started and stopped by `AppModel` as the setting flips; the loop does not run while the
  setting is off.
- `CallRecordingController` is not changed.

## Testing

- Settings: default off and the default list; round-trip; a document without the keys decodes
  to the defaults; a stored empty list stays empty.
- Matcher: App match on input; Browser needs input and output across its processes; prefix
  boundary (`com.microsoft.teams` vs `teams2`, `com.google.Chrome.helper`); own PID excluded;
  first entry wins; nil bundle ID ignored.
- Policy: happy path start after 3 s and stop after 15 s; a 2 s blip starts nothing; a gap
  shorter than 15 s keeps recording; manual recording never stopped; busy recorder never
  started over; hand-stop suppressed until the call is gone for 15 s, then re-armed.
- Controller with fakes (`FakeAudioProcessMonitor`, the existing call-capture fakes): a
  scripted call produces one recording and one stop, with both toasts.
- Smoke (`docs/SMOKE_TEST.md`): a real Zoom/Meet/Telegram/FaceTime call starts and stops a
  recording; the *Using the microphone now* list shows the call app during a call.

## Verified platform facts

- 2026-10-19, macOS 26.5, unsigned command-line probe: the process object list, PID,
  `kAudioProcessPropertyBundleID`, `IsRunningInput` and `IsRunningOutput` read with no
  permission prompt. Several idle apps report `IsRunningOutput = 1` without playing anything —
  output alone never means a call, which is why only Browser entries consult it, and only
  together with input.
- Not yet verified: the bundle ID that holds the microphone during a call in FaceTime,
  Safari, Telegram and Teams. To be read with the *Using the microphone now* list during the
  smoke test; wrong defaults are corrected in the list and in this table.

## Out of scope

- Detecting a call from window titles or calendar events (needs Screen Recording or calendar
  access).
- Naming the transcript after the call app.
- A Stop button on the start toast.
- Per-app "ask before recording" prompts.
