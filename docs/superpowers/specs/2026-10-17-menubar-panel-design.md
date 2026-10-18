# Menubar panel design

Date: 2026-10-17
Status: design handoff; application implementation has not started.

The operator accepted the revised quick-access layout, requested transcription progress
and Show All Windows, questioned the idle status, and required consideration of the
Mac's light/dark appearance. This document incorporates those revisions. Detailed
implementation planning and native verification belong to the implementing agent.

## 1. Goal and scope

Replace SwiftUI `MenuBarExtra(.menu)` with an application-owned `NSStatusItem` and
`NSPopover` hosting a SwiftUI panel. Live recording levels and time must not rebuild
menu items or disturb the hovered action. Keep every existing menu capability available.

The panel is a quick-access surface, not a settings checklist. Frequent actions and
input/model selection come first; infrequent enablement switches are disclosed below.

Do not change the audio pipeline, model routing, hotkey semantics, transcript storage,
licensing, or other windows' designs. Do not add telemetry, dependencies, a theme
preference, speaker/output-device selection, or buttons that invoke selection-based
text actions. Preserve the existing termination/shutdown sequence.

### Design history

- Superseded: six checkboxes near the top, permanent Ready/Dictation ready, duplicate
  model description in the header, and `not set` beside Record/Stop.
- Accepted direction: compact recording block, microphone/model/translation selectors,
  file/history commands, collapsed Options with switches, then window/application commands.
- Latest additions: transcription progress, Show All Windows, inherited system appearance.
- Implementation defaults chosen in this handoff: progress also has a compact closed-panel
  status-item representation; Show All Windows restores existing windows rather than
  creating every possible window. These semantics were not individually reviewed by the operator.

## 2. Visual reference and durable mockup

[Interactive layout study](assets/2026-10-17-menubar-panel-design.html).
Open it in a browser. It includes idle and concurrent call-recording/file-transcription
states, expandable Options, illustrative device choices, and System/Light/Dark preview.
All values and simulated levels are examples, not captured application state. The
appearance selector belongs to the study only. This document overrides the mockup where
it specifies states the study does not render.

References (structure and behavior, not source-code reuse):

- [Vorssaint](https://github.com/vorssaint/vorssaint-utils): a status-item controller,
  a popover, SwiftUI content and compact tool rows. Its GPL source must not be copied.
  Relevant files: `Sources/Vorssaint/App/StatusItemController.swift`,
  `Sources/Vorssaint/App/AppDelegate.swift`,
  `Sources/Vorssaint/UI/MenuPanel/MenuPanelView.swift` in that external repository.
- [Apple Control Center, Sonoma](https://support.apple.com/guide/mac-help/quickly-change-settings-mchl50f94f8f/14.0/mac/14.0):
  native material, restrained grouping and spacing. Do not copy the tile grid.
- [iStat Menus](https://bjango.com/mac/istatmenus/): a separate region for live readings,
  labels on the left and values on the right. Do not add its graph density.

Use approximately 300 pt width, the system font, native control sizing, about 8–12 pt
outer spacing and compact rows. One recording group and, while relevant, one transcription
group; not a card around every command. Text left-aligned, shortcuts trailing-aligned.
Use existing `Icon(.case)` Phosphor icons in content. Add an icon through the repository's
icon manifest/tooling if needed; the mockup's drawn icons are not production assets.

## 3. Order and contents

1. **Header:** Macomprendo. No permanent Ready or Dictation ready label.
2. **Call recording:** a compact Record Call row when idle. When recording, show
   Recording call, elapsed time, Stop Recording, then Me/Others capsule level meters.
   Keep Stop above the meters. Show start failures with their existing recovery text in
   this block. Starting/stopping leaves the popover open so success/failure is visible.
3. **Transcription activity:** visible while a file/call transcript is running, or when
   its controller reports a failure. Details below. It follows the recording block so
   transcription updates cannot move Stop Recording.
4. **Quick selectors:** Microphone, Dictation model, Translate into, in that order.
   Each has a small caption and a readable selected value. The model value identifies
   the local source or configured endpoint; no duplicate source line in the header.
5. **Commands:** Transcribe File…, Transcripts…, Dictation History….
6. **Options**, collapsed on each fresh opening: Save dictation history switch, then
   Enable hotkeys with all six existing actions as switches. Show assigned shortcuts
   as secondary text; omit absent ones. A short hint may point to Settings → Hotkeys.
7. **Show All Windows**, Settings… (⌘,), Check permissions…,
   About Macomprendo…, Quit Macomprendo (⌘Q).

The history command remains available when saving history is off. The Record Call
switch enables its keyboard shortcut; it does not start or stop recording. The separate
Record/Stop action still works when that hotkey is disabled. Re-read shortcut assignments
on every panel opening; a long-lived host must not cache launch-time shortcuts.

The model picker uses `DictationTabModel.selectableSources`, `activeSource`, `activate`
and `hasReadySource`, not new readiness logic. Keep the active unavailable choice visible,
disable selection if no source is ready, and explain the existing readiness problem.
Translation uses the existing `TranslationTarget` options and computed labels.

### Non-idle dictation

Preserve meaningful `DictationController.state` feedback without printing idle readiness.
Show Recording dictation…, Transcribing dictation…, Inserting text…, or the existing
failure text in a conditional activity line. Keep it distinct from call recording and
background transcription. Put this line below the call block, never above Stop Recording.
There is no numeric progress for interactive dictation in the current controller;
transcribing dictation is indeterminate, not a fabricated percentage.

### Microphone

Reuse the existing setting and device-list policy: System default (actual device name),
connected inputs, and the selected disconnected input. Preserve that missing device's
selection/name and explain the existing fallback. This is Macomprendo's input choice
for dictation and call capture, not a system-wide output switch.

When Settings ▸ General ▸ **Release the microphone after recording** is off and an input is
held open between recordings, a **Release Microphone** row sits under the picker; it lets go
of the input so Bluetooth headphones leave call mode. It never appears during a recording.

The panel and Settings must stay synchronized, including device arrival/removal while
both are visible. `MicrophonePickerModel` currently has one start/stop observation task;
sharing its lifetime unchanged between two surfaces would let closing either stop the
other's updates. Give each surface an independent observation lifetime over the same
settings/devices, or introduce explicit shared subscription ownership. Test this seam.
The model's foreign-settings binding also needs invalidation for writes from the other
surface, not just writes through its own setter.

## 4. Transcription progress

Observe the existing `FileTranscriptionController.state` directly. It covers manually
started files, resumed jobs, retranscription and call recordings after Stop. There is
one active background transcription job, not a new queue to implement here.

### Popover

- For `.running`, show the title, Transcribing file or Transcribing Me/Others, the
  processed position and duration, and a progress presentation.
- For file jobs (`speaker == nil`), a determinate bar and integer percent may use
  clamped `position / duration` when both values are finite and duration is positive.
  Floor the display percent, capped at 99 while `.running`; only `.finished` establishes
  completion. If the inputs are invalid/unknown, show indeterminate activity and no percent.
- For call jobs (`speaker != nil`), show an indeterminate activity indicator plus the
  current speaker and the existing processed/total clock text. The controller publishes
  each track's position/duration shifted to the call clock, and starts again for the
  next track. These are NOT overall two-track completion and NOT raw per-track elapsed
  seconds. Do not turn their ratio into an overall percentage or invent track weights.
- Use `TranscriptsView.progressText(position:duration:speaker:)` as the existing wording
  reference; extract a shared pure formatter if needed, rather than make one view depend
  on another. Numbers advance on real controller events, not a UI timer estimating work.
- Clicking the activity opens Transcripts and selects the running transcript by its id,
  including when that window was not previously open. Close the popover first.
  Ensure the initial library reload/selection does not overwrite the requested id.
- `.idle` and `.finished` have no persistent progress card. Preserve the existing
  completion toast behavior. `.failed` shows its existing message and a way to open
  Transcripts for recovery; a failure without an id still opens the library.
- Do not clear a failure or cancel a job just because the popover closes. Cancellation
  remains available in the existing Transcripts window; a second cancel control is not required.
- The current state only begins reporting `.running` when the pipeline supplies its
  opened event. Do not claim progress for earlier preparation using made-up values.

### Status item while the popover is closed

A compact secondary readout makes activity discoverable without reopening the panel:

| State | Symbol/title |
|---|---|
| Idle | Existing waveform template, no idle text |
| Call recording | Existing record.circle template + elapsed recording clock |
| File transcription only | Waveform template + integer percent, or an ellipsis if indeterminate |
| Call transcription only | Waveform template + current speaker and processed clock; full pair in tooltip |
| Call recording + file transcription | Recording symbol + recording clock + secondary percent/ellipsis |
| Call recording + another call's transcription | Recording symbol + recording clock + an activity marker; full speaker/position in tooltip and popover |

Never replace a live recording indicator with transcription status. The tooltip and
VoiceOver label name each activity explicitly. Title writes occur only when the rendered
value changes, not on every microphone level event. Use tabular digits and reserve stable
space for the current title mode; do not re-anchor an open popover on percent digit counts
or clock hour rollover. No filenames or transcript text in status-item titles or logs.

## 5. Show All Windows

Interpret this as **bring existing user windows forward**, not launch every feature.
Close the popover, activate Macomprendo, restore minimized eligible windows, and raise
all of them. Preserve their sizes, positions, content and jobs; choose one existing window
as key without creating duplicates or restarting its work.

Eligible: open Settings, Dictation History, Transcripts, About, onboarding/permissions,
and an already-open Quick Panel. Exclude the status-item window, this popover, recording
HUD, correction-review overlays, internal hosting windows and standalone file panels.
An attached sheet belongs to its owner and must keep its modal relationship. Closed but
retained controllers are not open windows and must not be resurrected.

When no eligible windows exist, keep the command visible but disabled with accessible
help explaining that no windows are open. Do not silently open Settings as a fallback.
An explicit role/registration or verified window classification is preferable to raising
every `NSApp.windows` entry. `DockIconCoordinator.owners` alone is not an inventory:
it excludes Quick Panel and contains no NSWindow handles.

This is not Mission Control/App Exposé, window tiling, or moving windows between Spaces.
Restore/raise using normal AppKit behavior; do not rewrite collection behavior to force
windows onto a different Space. Never close/reopen Quick Panel as a way to raise it:
closing that panel intentionally cancels its stream (existing fix `6da0fbb`).

## 6. Native interaction and appearance

### Popover lifecycle

Keep ownership of the single status item/popover in App, created through AppEnvironment
behind a protocol suitable for headless fakes. Retain one hosting controller/view tree;
SwiftUI may reevaluate bodies, but meter updates must not replace row identity or content
hosts. Buttons own stable hover/focus state. Do not restore the removed call-controller
`objectWillChange` forwarding to AppModel.

Both left and right clicks toggle this same panel. The status button is highlighted
while open; repeat click, outside click and Escape close it and clear highlight.
**Executor decision (smoke):** `.transient` closed and reopened the panel when activating the
app brought an open window of ours (Transcripts) forward, and missed some clicks into other
apps' windows on another display. The popover is `.applicationDefined`, dismissed by a global
click monitor (other apps), a local one (our other windows, Escape) and the app resigning
active. Original note: start with native `.transient` behavior. Vorssaint's `.applicationDefined` custom dismissal
exists for its own workflow and is not a requirement here. Verify picker interaction,
clicks into this app's other windows, and focus before adding any custom event monitor.

Switches, selectors and Record/Stop keep the panel open. Commands opening a window or
file chooser close it before `NSApp.activate(ignoringOtherApps: true)` and routing.
Transcribe File… keeps its current audiovisual-file filter, opens Transcripts and calls
`fileTranscription.transcribe(fileAt:)` after successful selection; cancellation starts
nothing. Quit uses the existing application termination delegate, including async shutdown.

Preserve ⌘, and ⌘Q both from the key popover and existing app windows. Global action
shortcuts displayed on switches are annotations, not new `.keyboardShortcut` bindings.
Provide keyboard focus, activation, Escape, and native Picker/Toggle accessibility;
VoiceOver must identify the two levels, recording state and transcription activity.

On a short display, cap height to the status item's actual screen visible frame.
Keep recording controls accessible and scroll the middle content in one region, without
nested scroll views. Do not let Options expand the popover offscreen or move Stop on
meter/timer ticks. In light/dark transitions, preserve hover, focus and selections.

### Follow the device, not the mockup

- There is no app-level theme switch in this feature. Leave AppKit appearance inherited
  and do not force a SwiftUI `preferredColorScheme`; respond to effective appearance
  changes, including automatic system changes while the popover stays open.
- Use the native popover material (or a single AppKit `.popover` visual-effect surface
  if a wrapper is necessary). Avoid layering duplicate materials, fixed RGB backgrounds,
  a fake web blur, and an additional hand-painted popover shadow/arrow.
- Use semantic primary/secondary/disabled/separator colors. Use system selected-content
  background and selected-content text for hover/focus, not permanently blue backgrounds
  and white labels. On selection, secondary labels/icons must remain legible too.
- Recording/error color is semantic and accompanied by text/icon, not color alone.
  Level-meter and progress accents follow the system accent. Preserve contrast with
  non-blue accents and Increase Contrast; Reduce Transparency gets an opaque system
  background rather than unreadable text over the wallpaper.
- The status-item SF Symbol image is a template. Let macOS choose its contrast: the
  menu bar's wallpaper-derived appearance can differ from the popover's appearance.
  Do not color it manually based on the SwiftUI light/dark value.
- Respect Reduce Motion; progress reflects values without decorative pulsing or fades.
  Theme/contrast changes must not reset progress, recreate windows or stop any work.
- Verify macOS 14.2-compatible APIs. Do not make newer Liquid Glass APIs mandatory or
  imitate Tahoe-only chrome on older macOS. The OS provides the appropriate material.

## 7. Verified source map and implementation seams

Paths below exist at baseline `92bee9a`. Re-read them before editing; this is a map,
not authorization to overwrite later changes. Three local fixes `2b2cfd3`, `6da0fbb`
and `92bee9a` must be preserved. Do not commit, push or create a worktree without permission.

| Existing file | Relevant seam |
|---|---|
| `macos/Sources/Macomprendo/App/MacomprendoApp.swift` | MenuBarExtra; AppDelegate startup/shutdown; Settings and Window scenes |
| `macos/Sources/Macomprendo/App/AppEnvironment.swift` | Constructs OS-facing implementations; existing panel host factories |
| `macos/Sources/Macomprendo/App/AppModel.swift` | Settings owner, controllers, selector models, statusText |
| `macos/Sources/Macomprendo/UI/MenuBar/MenuBarView.swift` | All existing menu commands, selector bindings, window opening |
| `macos/Sources/Macomprendo/UI/MenuBar/CallRecordingMenu.swift` | Call rows, label, old text meter |
| `macos/Sources/Macomprendo/UI/Components/LevelMeter.swift` | Capsule meter and pure lit-bar helper |
| `macos/Sources/Macomprendo/UI/Components/Icon.swift` | Existing icon vocabulary and SVG loader |
| `macos/Sources/Macomprendo/Services/HotkeyService.swift` | Six HotkeyAction cases, enablement, shortcut labels |
| `macos/Sources/Macomprendo/UI/Settings/MicrophonePickerModel.swift` | Input options, selection, missing-device caption, observation lifetime |
| `macos/Sources/Macomprendo/UI/Settings/GeneralTab.swift` | Existing microphone binding and observation owner |
| `macos/Sources/Macomprendo/Services/AudioInputDevices.swift` | Shared device service; fresh changes stream per caller |
| `macos/Sources/Macomprendo/Features/FileTranscriptionController.swift` | State at lines 15–23; sequential call tracks at 376–422; shifted progress at 446–500 |
| `macos/Sources/Macomprendo/UI/Transcripts/TranscriptsView.swift` | Selection/reload on appear; progressText at 642–647; existing cancel/recovery |
| `macos/Sources/Macomprendo/Features/DictationController.swift` | DictationState has activity/failure but no numeric progress |
| `macos/Sources/Macomprendo/Core/WindowID.swift` | Existing SwiftUI window identifiers |
| `macos/Sources/Macomprendo/Features/DockIconCoordinator.swift` | Window owners for Dock visibility, not a window registry |
| `macos/Sources/Macomprendo/UI/Onboarding/OnboardingWindowController.swift` | Retains a closed NSWindow; do not blindly raise every retained window |
| `macos/Sources/Macomprendo/UI/QuickPanel/FloatingPanelHost.swift` | Existing Quick Panel host; preserve show/close/stream lifetime |

Implement a small pure presentation projection (row visibility, optional shortcut,
progress/status labels) and a stable SwiftUI panel; do not build a second feature controller
or copy readiness/selection/storage logic. OS window routing/raising belongs behind
protocols; concrete construction stays in AppEnvironment. App owns status-item lifetime.
New type/file names are deliberately left to the implementation plan, not presented here
as existing APIs.

**Cold-launch window routing is a required integration seam.** A detached NSHostingController
must not assume that `@Environment(\.openWindow)`/`openSettings` has the same scene context
as MenuBarExtra. Use an explicit scene-aware route or deliberate AppKit window ownership
that works before any user window has appeared. Do not bootstrap it only from a Settings
`.onAppear`, use private selectors, or silently duplicate the existing SwiftUI windows.
Native cold-start smoke is required; this documentation pass did not verify that bridge.

**Executor decision (2026-10-17, spike):** a SwiftUI view hosted in an `NSHostingController`
inside an app-owned `NSPopover` gets working `openWindow` and `openSettings` actions at cold
launch, before any window has appeared. Without a `MenuBarExtra` as the first scene, SwiftUI
opens the first `Settings`/`Window` scene at launch; a hidden
`MenuBarExtra(isInserted: .constant(false))` kept as the first scene prevents that and shows
nothing (a zero-height status window). The app delegate must also answer
`applicationShouldTerminateAfterLastWindowClosed` with `false`.

## 8. Implementation handoff and acceptance

Next agent: read AGENTS.md and the architecture/build-test skills from `.agents/skills`,
then write an implementation plan from this spec before application edits. Use Graphify
for navigation where available. Work sequentially in the existing checkout unless the
operator authorizes another path. Do not launch implementation subagents in this handoff.

### Sequence

1. Write RED tests for pure presentation rules and fakeable routing/lifecycle decisions.
2. Establish explicit window routing and the status-item/popover host through AppEnvironment;
   retain termination behavior and prove cold-start routes work.
3. Build the revised panel, selector observation lifetimes, call/progress subviews and
   optional status text. Keep noisy updates confined to their consumers.
4. Add Show All Windows with explicit eligibility, minimized-window handling and a fake;
   verify actual registered windows separately from its pure eligibility rules.
5. Verify native system appearance and keyboard/mouse behavior. Update smoke checks,
   architecture and CHANGELOG Unreleased only when implementing the behavior.
6. Regenerate the Xcode project, run all gates, update the existing local knowledge graph,
   install the signed app, and ask the operator to run hardware/UI acceptance.

### Automated coverage required

- Normal idle layout has no ready text, no unbound-shortcut placeholder and collapsed Options;
  all six toggles and history saving remain reachable; only existing bound shortcuts render.
- Recording state shows clock/Stop/meters; stop remains independent of hotkey enablement;
  start failure retains its message; isolated level changes do not notify the entire AppModel.
- File progress happy path, invalid/zero duration, negative/out-of-range positions,
  nonfinite inputs, running-at-end versus finished, and new/superseded job transitions.
- Call progress names Me/Others and never presents one track's ratio as whole-call completion.
  A track transition or concurrent recording cannot erase the recording indicator.
- Idle/running/finished/failed/cancelled projections and unknown-duration dictation state.
  Use existing generation/cancellation guarantees; do not add simulated progress timers.
- Opening a progress result requests the exact id even on a cold window; failed-without-id
  can open the library; popover close leaves recording/transcription running.
- Command routing closes/activates/opens in order, chooser cancellation starts no job,
  switches/selectors/Record/Stop leave the panel open, Quit retains async shutdown.
- Show All Windows includes eligible minimized windows and an existing Quick Panel,
  excludes overlays/closed retained windows, and never creates or restarts a feature.
- Microphone list/selection updates across Settings and popover; closing either leaves
  the other's observer alive; disconnected selection/default label remain correct.

Existing starting points: `macos/Tests/MacomprendoTests/UI/MenuBarLabelTests.swift`,
`macos/Tests/MacomprendoTests/UI/CallRecordingMenuTests.swift`,
`macos/Tests/MacomprendoTests/UI/MicrophonePickerModelTests.swift`,
`macos/Tests/MacomprendoTests/Features/FileTranscriptionControllerTests.swift`.
Tests asserting `not set` and the old one-Text NSMenu label are specifically superseded
by this spec; replace their menu-presentation expectations deliberately, not unrelated tests.
Tests for a retained helper's old contract need not be weakened: add a panel-specific
optional-shortcut formatter when that avoids breaking other consumers.

### Native smoke additions for docs/SMOKE_TEST.md

- During a real call, hold the pointer still over Stop Recording and over a different row
  while meters update; highlight and hit target stay fixed. Click Stop successfully.
- File transcription progress matches the Transcripts window, remains visible when that
  window is closed, opens the correct transcript, and disappears on completion/cancellation.
  Call transcription correctly labels each track; no false overall percentage.
- Concurrent recording/transcription shows both, including a second job and track transition.
- Left/right/repeat click, outside click into another app and into an existing Macomprendo
  window, Escape, keyboard focus, ⌘, and ⌘Q; no stuck status-button highlight.
- After cold launch, each window command works before Settings has ever appeared.
  File chooser cancel/open, native pickers and all translation/model availability states.
- Show All Windows with several open and minimized windows, no windows, closed-but-retained
  onboarding, and an active Quick Panel stream. Excluded overlays do not gain focus.
- Device connect/disconnect/change with both surfaces open; close one and change a device
  again. Confirm persisted selection and actual capture follow the existing input policy.
- System Light, Dark and automatic switching while open; also reopen after a theme change.
  Check native material/arrow, text, picker menus, disabled controls, selected/hover colors,
  meters and progress. Test a non-blue accent, Increase Contrast, Reduce Transparency,
  Reduce Motion, and a menu-bar wallpaper whose contrast differs from the panel theme.
- Small visible screen height and multiple displays; Options remains reachable, Stop stays
  accessible, and long device/model/error labels do not widen the panel or cover shortcuts.
- VoiceOver announces recording/progress/switch state without speaking levels ten times
  per second. Mere theme changes or popover dismissal do not cancel background work.

Replace the old smoke assertion that idle always reads Ready. In docs/ARCHITECTURE.md,
update the menu ownership and note that history remains readable when saving is disabled
(the current history section still describes the older disabled-command behavior).

### Completion gates for the implementation, not this documentation pass

- `npm run test:swift`
- `npm run test:scripts`
- `npm run audit` (both Gitleaks scans must run)
- `swift build --package-path macos` with no new warnings
- `npm run gen`; keep generated project changes with the implementation and require a
  second run to produce no further changes. `macos/project.yml` already discovers Swift
  source directories; edit it only for necessary configuration/resource changes. A new
  resource directory must also be declared in `macos/Package.swift`.
- Check the Xcode build as well as SwiftPM. CI uses Xcode 16.4 / Swift 6.1: do not introduce
  main-actor `AVAsset.load*` calls; this UI task should not need media decoding changes.
- Update the existing graph once after the code batch; keep generated graph files local.
- `npm run install-app:signed`, then operator hardware/UI acceptance; no routine TCC reset.

A green HTML mockup or unit suite does not establish native hover, focus, window routing,
appearance or audio-device behavior. Report automated evidence and native checks separately.
If unavailable signing/tooling or an unworkable cold-launch route blocks implementation,
report the concrete blocker rather than substituting a fake success. Record any material
executor decision or contradiction back into this spec before completing the handoff.
