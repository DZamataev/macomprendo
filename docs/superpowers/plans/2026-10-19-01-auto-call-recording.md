# Automatic Call Recording Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Start a call recording automatically when a call app from the user's list uses the microphone, and stop it when the call ends; off by default, switchable in the menubar panel's Options and in Settings ▸ General, with an editable app list.

**Architecture:** A pure matcher in Core decides which listed app (if any) is in a call from a snapshot of Core Audio's process list. A pure policy in Features turns a stream of those answers into start/stop decisions with 3 s / 15 s timing and hand-stop suppression. A thin `@MainActor` controller polls the snapshot once a second while the setting is on and drives the existing `CallRecordingController.toggle()`, which is not changed.

**Tech Stack:** Swift 6 strict concurrency, Core Audio process objects (macOS 14.2+), SwiftUI, swift-testing.

**Spec:** `docs/superpowers/specs/2026-10-19-auto-call-recording-design.md`.

## Global Constraints

- Layers point downward only (UI → Features → Services/Providers → Core); concrete services are constructed only in `AppEnvironment.live()` (`macos/Sources/Macomprendo/App/AppEnvironment.swift:86`). Every OS-facing piece sits behind a protocol with a fake in `macos/Tests/MacomprendoTests/Fakes` (AGENTS.md 1–2).
- TDD: write the named test, run it red, implement, run it green. The Core Audio reader and the SwiftUI rows are thin glue covered by `docs/SMOKE_TEST.md` (AGENTS.md 3).
- `CallRecordingController` (`macos/Sources/Macomprendo/Features/CallRecordingController.swift`) is **not modified**. Starting and stopping go through its public `toggle()` (line 117) and `isRecording` (line 43).
- Bundle IDs and app names are not user content and may be logged; transcript text never is (AGENTS.md 6).
- Icons only through `Icon(.case)` (AGENTS.md 12); the remove button uses the existing `.remove` case, Add uses `.add`.
- New Swift files: `swift test` picks them up by directory, `xcodebuild` does not until `npm run gen` regenerates `macos/Macomprendo.xcodeproj`; run `npm run gen`, commit the project, and a second `npm run gen` must be a no-op (AGENTS.md 10).
- Conventional commits, one per task. Stage only the paths the task lists. Never push.
- Each task's report must say what in this plan was wrong, ambiguous or decided by the executor — that matters more than the code. Do not edit an existing test that contradicts the new behaviour; leave it red and report it.

---

### Task 1: `CallApp`, `AudioProcessActivity` and the matcher (Core)

**Files:**
- Create: `macos/Sources/Macomprendo/Core/CallApp.swift`
- Test: `macos/Tests/MacomprendoTests/Core/CallAppTests.swift`

**Interfaces (later tasks rely on these exact names):**

```swift
struct AudioProcessActivity: Sendable, Equatable {
    let pid: pid_t
    let bundleID: String?
    let isRunningInput: Bool
    let isRunningOutput: Bool
}

struct CallApp: Codable, Sendable, Equatable, Identifiable {
    enum Kind: String, Codable, Sendable, CaseIterable { case app, browser }
    var name: String
    var bundleIDPrefix: String
    var kind: Kind
    var id: String { bundleIDPrefix }

    static let defaults: [CallApp]   // the spec's built-in table, in that order
    /// True when `bundleID` equals the prefix or continues it after a `.`.
    func matches(bundleID: String) -> Bool
    /// The first app in `apps` that is in a call, per the spec's App / Browser rules.
    static func activeCall(in processes: [AudioProcessActivity], apps: [CallApp],
                           excludingPID: pid_t) -> CallApp?
}
```

Rules: an **App** entry is active when any non-excluded process it matches has `isRunningInput`. A **Browser** entry is active when, among the non-excluded processes it matches, one has `isRunningInput` and one (the same or another) has `isRunningOutput`. Processes with `bundleID == nil` never match. Entries are tried in list order.

- [ ] **Step 1: Write the failing tests** — `anAppUsingTheMicrophoneIsTheActiveCall` (happy path: Zoom input → Zoom), `anAppPlayingWithoutTheMicrophoneIsNoCall`, `aBrowserNeedsMicrophoneAndOutputAcrossItsProcesses` (Chrome main output + `com.google.Chrome.helper` input → Chrome; input alone → nil), `thePrefixMatchesOnlyAtADotBoundary` (`com.microsoft.teams` does not match `com.microsoft.teams2`; `com.google.Chrome` matches `com.google.Chrome.helper`, not `com.google.Chromex`), `ourOwnProcessNeverMatches`, `theFirstListedAppWins`, `aProcessWithoutBundleIDNeverMatches`, `defaultsHaveUniquePrefixesAndBothKinds`.
- [ ] **Step 2: Run** `swift test --package-path macos --filter CallAppTests` — expected: FAIL, `cannot find 'CallApp' in scope`.
- [ ] **Step 3: Implement** `Core/CallApp.swift` with the table from the spec's *The built-in list* section (copy names, prefixes, kinds exactly).
- [ ] **Step 4: Run** the filter again — expected: PASS.
- [ ] **Step 5:** `npm run gen`; commit `feat(calls): call app list and active-call matcher`.

---

### Task 2: Settings fields

**Files:**
- Modify: `macos/Sources/Macomprendo/Core/Settings.swift` — stored properties near `transcribeCallsAfterRecording` (line 356), defaults in `static var default` (~line 397), decoding at the end of `init(from:)` (~line 491).
- Test: `macos/Tests/MacomprendoTests/Core/SettingsTests.swift`, inside `@Suite struct CallRecordingSettingsTests` (line 622).

**Interfaces:** `var autoRecordCalls: Bool` (default `false`), `var autoRecordApps: [CallApp]` (default `CallApp.defaults`). `CodingKeys` are synthesized; decode each with `decodeIfPresent(…) ?? d.<field>` like `transcribeCallsAfterRecording`.

- [ ] **Step 1: Write the failing tests** — `automaticCallRecordingIsOffWithTheDefaultAppsAndRoundTrips` (document `{"schemaVersion":2,"dictationMode":"hold"}` decodes to `false` and `CallApp.defaults`; an encoded `true` + a one-entry list round-trips), `aStoredEmptyAppListStaysEmpty`.
- [ ] **Step 2: Run** `swift test --package-path macos --filter CallRecordingSettingsTests` — FAIL (no member).
- [ ] **Step 3: Implement** the two fields, defaults and decoding.
- [ ] **Step 4: Run** — PASS. Then `npm run test:swift`: any other `Settings(...)` memberwise construction that breaks is fixed by adding the two arguments (grep `Settings(` under `macos/`).
- [ ] **Step 5:** Commit `feat(calls): settings for automatic call recording`.

---

### Task 3: Audio process monitor (Services) and its fake

**Files:**
- Create: `macos/Sources/Macomprendo/Services/AudioProcessMonitor.swift`
- Create: `macos/Tests/MacomprendoTests/Fakes/FakeAudioProcessMonitor.swift`
- Modify: `macos/Sources/Macomprendo/App/AppEnvironment.swift` — a field `var audioProcesses: any AudioProcessMonitoring` beside `callMicrophone` (line 79) and `audioProcesses: CoreAudioProcessMonitor()` in `live()` (~line 160).
- Modify: `macos/Tests/MacomprendoTests/Fakes/FakeEnvironment.swift` — parameter `audioProcesses: any AudioProcessMonitoring = FakeAudioProcessMonitor()` passed through.

**Interfaces:**

```swift
protocol AudioProcessMonitoring: Sendable {
    /// Every process Core Audio reports, read now. Empty when the list cannot be read.
    func snapshot() -> [AudioProcessActivity]
}
final class CoreAudioProcessMonitor: AudioProcessMonitoring { … }
final class FakeAudioProcessMonitor: AudioProcessMonitoring, @unchecked Sendable {
    var processes: [AudioProcessActivity]   // lock-guarded; tests assign it
}
```

The reader is verified code from the probe (`kAudioHardwarePropertyProcessObjectList` on `kAudioObjectSystemObject`, then per object `kAudioProcessPropertyPID`, `kAudioProcessPropertyBundleID` as a retained `CFString`, `kAudioProcessPropertyIsRunningInput`, `kAudioProcessPropertyIsRunningOutput`, all global scope, main element). A failed read of the list returns `[]`; a failed per-process read skips that process. Empty bundle ID → `nil`.

- [ ] **Step 1:** Implement the protocol, reader and fake (glue; no unit test of Core Audio). Wire `AppEnvironment` and `FakeEnvironment`.
- [ ] **Step 2: Verify by hand:** a temporary test enabled by `MACOMPRENDO_PROBE_AUDIO_PROCESSES=1` that prints `CoreAudioProcessMonitor().snapshot()` entries with input or output; run it, confirm real bundle IDs print, then delete the temporary test.
- [ ] **Step 3:** `npm run gen`; `npm run test:swift` green; commit `feat(calls): Core Audio process monitor`.

---

### Task 4: The policy (Features, pure)

**Files:**
- Create: `macos/Sources/Macomprendo/Features/AutoCallRecordPolicy.swift`
- Test: `macos/Tests/MacomprendoTests/Features/AutoCallRecordPolicyTests.swift`

**Interfaces:**

```swift
struct AutoCallRecordPolicy: Sendable {
    enum Decision: Equatable { case start(CallApp), stop }
    static let startAfter: TimeInterval = 3
    static let stopAfter: TimeInterval = 15
    init()
    /// One poll. `recorderBusy` is `CallRecordingController.isRecording`.
    mutating func observe(_ call: CallApp?, at now: Date, recorderBusy: Bool) -> Decision?
}
```

Rules (from the spec; derive the expected times in each test yourself and report any disagreement with this table rather than adjusting either side):
- Track `callSince` (first time of the current unbroken run of non-nil `call`) and `quietSince` (first time of the current run of nil).
- **Start** when `call != nil`, `now - callSince >= 3`, `!recorderBusy`, not suppressed, and no own recording. Remember `ownRecording = true`.
- **Stop** when `ownRecording`, `recorderBusy`, and `call == nil` with `now - quietSince >= 15`. Then `ownRecording = false`.
- **Hand stop:** `ownRecording` and `!recorderBusy` without the policy having said `.stop` → `ownRecording = false`, `suppressed = true`.
- **Re-arm:** `suppressed` clears once `call == nil` for 15 s.
- A recording the user started (`recorderBusy` with `!ownRecording`) is never stopped and blocks starting.

- [ ] **Step 1: Write the failing tests** — `aCallLastingThreeSecondsStartsAndFifteenQuietSecondsStop` (happy path), `aTwoSecondBlipStartsNothing`, `aShortGapKeepsTheRecording` (10 s gap, no stop), `aManualRecordingIsNeverStopped`, `aBusyRecorderIsNeverStartedOver`, `aHandStopIsRespectedUntilTheCallIsOver` (no restart during the same call; restart after 15 s quiet and a new call), `switchingAppsMidCallIsOneCall` (Zoom → Chrome without a nil gap does not restart).
- [ ] **Step 2: Run** `swift test --package-path macos --filter AutoCallRecordPolicyTests` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — PASS. Mutate by hand: set `startAfter` to 2 → `aTwoSecondBlipStartsNothing` must fail; drop the suppression → `aHandStopIsRespected…` must fail. Revert.
- [ ] **Step 5:** `npm run gen`; commit `feat(calls): automatic call recording policy`.

---

### Task 5: The controller and `AppModel` wiring

**Files:**
- Create: `macos/Sources/Macomprendo/Features/AutoCallRecorder.swift`
- Test: `macos/Tests/MacomprendoTests/Features/AutoCallRecorderTests.swift`
- Modify: `macos/Sources/Macomprendo/App/AppModel.swift` — a `lazy var autoCallRecorder` beside `callRecording` (line 140); in `settings.didSet` (line ~15) start/stop it when `autoRecordCalls` changes; in `start()` (near the middle-mouse wiring, ~line 383) start it if the loaded setting is on.
- Test: `macos/Tests/MacomprendoTests/App/AppModelTests.swift`.

**Interfaces:**

```swift
@MainActor final class AutoCallRecorder {
    init(monitor: any AudioProcessMonitoring,
         recorder: CallRecordingController,
         apps: @escaping @MainActor () -> [CallApp],
         toast: @escaping @MainActor (String) -> Void,
         ownPID: pid_t = ProcessInfo.processInfo.processIdentifier,
         now: @escaping () -> Date = Date.init,
         interval: Duration = .seconds(1))
    var isRunning: Bool { get }
    func start()      // starts the poll loop; idempotent
    func stop()       // cancels the loop and resets the policy; never stops a recording
    func tick()       // one poll — the loop calls it; tests call it directly
}
```

`tick()`: `let call = CallApp.activeCall(in: monitor.snapshot(), apps: apps(), excludingPID: ownPID)`; feed `policy.observe(call, at: now(), recorderBusy: recorder.isRecording)`; on `.start(app)` call `recorder.toggle()` and `toast("Recording call — \(app.name)")`; on `.stop` call `recorder.toggle()` and `toast("Call ended — recording stopped")`. `AppModel` passes `toast: { [hud] in hud.toast($0) }` (`hud` is `AppModel.hud`, line 59) and `apps: { [unowned self] in self.settings.autoRecordApps }`.

Construct the `CallRecordingController` in tests the way `macos/Tests/MacomprendoTests/Features/CallRecordingControllerTests.swift` does (read its `Rig`); do not create a second rig type if one can be reused.

- [ ] **Step 1: Write the failing tests** — `aScriptedCallRecordsOnceAndStopsWhenItEnds` (happy path: monitor shows Zoom input; ticks at t=0…3 → recorder starting/recording and toast; monitor empty; ticks to t=18 → recorder stopping/idle and second toast), `nothingIsPolledWhileStopped`, and in `AppModelTests` `theSettingStartsAndStopsTheAutoRecorder`.
- [ ] **Step 2: Run** the filters — FAIL.
- [ ] **Step 3: Implement** controller and wiring.
- [ ] **Step 4: Run** — PASS; `npm run test:swift` green.
- [ ] **Step 5:** `npm run gen`; commit `feat(calls): record calls automatically`.

---

### Task 6: UI — Options switch and Settings section

**Files:**
- Modify: `macos/Sources/Macomprendo/UI/MenuBar/MenuPanelView.swift` — after the `PanelSwitchRow(title: "Transcribe calls after Stop", …)` (line 267).
- Modify: `macos/Sources/Macomprendo/UI/Settings/GeneralTab.swift` — in `Section("Call recordings")` (line 53), after the *Transcribe a call as soon as it stops* toggle and its caption (line 68).
- Modify: `macos/Sources/Macomprendo/App/AppModel.swift` — `func microphoneUsersNotListed() -> [CallApp]`: `env.audioProcesses.snapshot()` filtered to `isRunningInput`, own PID excluded, no listed entry matching, de-duplicated by bundle ID, named via `NSRunningApplication(processIdentifier:)?.localizedName` else the bundle ID, kind `.app`.
- Test: `macos/Tests/MacomprendoTests/App/AppModelTests.swift` — `microphoneUsersNotListedSkipsListedAppsAndOurselves`.

UI per the spec's *Settings* section: Options row `PanelSwitchRow(title: "Record calls automatically", isOn: $model.settings.autoRecordCalls)`; in Settings the toggle with the spec's caption text verbatim, the list rows (name, prefix in `.secondary`, kind picker, remove button with `Icon(.remove)`), *Using the microphone now* refreshed by a 1 s `.task` loop while visible, a manual bundle-ID field + kind picker + Add, and **Restore Default Apps** (`model.settings.autoRecordApps = CallApp.defaults`).

- [ ] **Step 1:** Failing `AppModelTests` test → implement `microphoneUsersNotListed()` → green.
- [ ] **Step 2:** Build the views. `swift build --package-path macos` with no new warnings.
- [ ] **Step 3: Eyeball:** `npm run install-app:signed`; open the panel's Options and Settings ▸ General; with any app holding the microphone (e.g. QuickTime ▸ New Audio Recording) confirm it appears under *Using the microphone now*, Add moves it into the list, remove and Restore work. Screenshot both surfaces.
- [ ] **Step 4:** Commit `feat(calls): automatic call recording settings`.

---

### Task 7: Docs

**Files:** `CHANGELOG.md` (`## [Unreleased]`: an `### Added` entry for automatic call recording; a `### Changed` entry for the tighter call-clock pill from commit `2d2d913` if none exists), `docs/SMOKE_TEST.md` (a section from the spec's *Testing* smoke bullets, including reading real bundle IDs during FaceTime / Safari Meet / Telegram calls), `PRIVACY.md` (line 26 paragraph: detection reads only which apps use audio, locally, once a second while the setting is on; nothing is recorded until a listed app is in a call), `docs/adr/0019-automatic-call-detection-by-audio-process.md` (why process-list polling over window titles, listeners or ScreenCaptureKit).

- [ ] **Step 1:** Write them. `npm run audit` green (no absolute home paths).
- [ ] **Step 2:** Commit `docs(calls): automatic call recording`.

## Blockers (stop and ask)

- The real bundle IDs holding the microphone during FaceTime, Safari, Telegram and Teams calls are unverified (spec, *Verified platform facts*). Do not guess replacements; the operator reads them during the smoke test and the defaults table is corrected then.

## Self-review

- Every spec section maps to a task: detecting (1, 3), starting/stopping/overrides (4, 5), settings (2, 6), built-in list (1), architecture (1, 3, 4, 5), testing (all), verified facts (3, 7), privacy (7).
- `CallRecordingController` untouched; its `toggle()` (line 117) and `isRecording` are the only entry points used.
