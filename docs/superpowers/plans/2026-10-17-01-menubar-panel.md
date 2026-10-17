# Menubar Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the SwiftUI `MenuBarExtra(.menu)` with an app-owned `NSStatusItem` + `NSPopover` hosting a SwiftUI panel, laid out per the spec, so live recording levels never disturb the hovered row.

**Architecture:** Pure presentation rules live in `UI/MenuBar/MenuPanelPresentation.swift` (unit-tested). An AppKit `StatusItemController` (App layer, constructed from `AppModel.start()` through an `AppEnvironment` factory) owns the status item, its title and the transient popover; the popover hosts one long-lived `NSHostingController(MenuPanelView)`. Windows open through SwiftUI's `openWindow` / `openSettings` read inside the hosted panel — proven to work from an `NSPopover` at cold launch by a spike — and the scene graph keeps a hidden `MenuBarExtra(isInserted: false)` as its first scene so SwiftUI opens no window at launch. **Show All Windows** goes through a `WindowRaising` protocol with a pure eligibility rule.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI + AppKit (`NSStatusItem`, `NSPopover`, `NSHostingController`), swift-testing.

**Spec:** `docs/superpowers/specs/2026-10-17-menubar-panel-design.md` (mockup: `docs/superpowers/specs/assets/2026-10-17-menubar-panel-design.html`).

## Global Constraints

- Layers point downward only (UI → Features → Services/Providers → Core); no concrete OS-facing service constructed outside `AppEnvironment` (AGENTS.md 1–2). Every OS-facing piece sits behind a protocol with a fake in `macos/Tests/MacomprendoTests/Fakes`.
- TDD for every pure rule; AppKit/SwiftUI rendering, hover, focus and window routing are smoke-tested (`docs/SMOKE_TEST.md`).
- Icons in content only through `Icon(.case)`; a new icon goes through `Resources/Icons/icons.json` + `npm run sync-icons` + `AppIcon` case + `fallbackSymbol`. The status item image stays an SF Symbol **template** (`waveform`, `record.circle`) — never colored by hand.
- Do **not** restore the `callRecording.objectWillChange` forwarding into `AppModel` (removed in `92bee9a`). Preserve local fixes `2b2cfd3`, `6da0fbb`, `92bee9a`.
- Closing the popover never cancels recording or transcription. Closing the Quick Panel is the only thing that stops its stream — Show All Windows must never close/reopen it.
- No filenames or transcript text in status-item titles or logs.
- Status-item title is written only when its rendered value changes (not on every level tick); tabular digits.
- File progress: `floor(clamp(position / duration) * 100)`, capped at 99 while `.running`; non-finite / non-positive duration or non-finite position → indeterminate (no percent). Call jobs (`speaker != nil`): never a percent — speaker + `clock(position) / clock(duration)`.
- Panel width ≈ 300 pt; semantic system colors only; no `preferredColorScheme`; no fixed RGB backgrounds; macOS 14.2 APIs only.
- CI builds with Xcode 16.4 / Swift 6.1: no main-actor `AVAsset.load*`; nothing in this plan should need media APIs.
- New Swift files: `npm run gen`, commit the regenerated project; a second `npm run gen` is a no-op. Conventional commits. Never push, never switch branches, never touch `main`; stage only your task's files.

---

### Task 1: Pure panel presentation

**Files:**
- Create: `macos/Sources/Macomprendo/UI/MenuBar/MenuPanelPresentation.swift`
- Test: `macos/Tests/MacomprendoTests/UI/MenuPanelPresentationTests.swift`

**Interfaces — Produces** (all `nonisolated`, value types, `Sendable`, `Equatable`):

```swift
enum MenuPanelPresentation {
    /// The conditional dictation line below the call block; nil while idle (no "Ready").
    static func dictationActivity(_ state: DictationState) -> String?
    // .recording → "Recording dictation…", .transcribing → "Transcribing dictation…",
    // .inserting → "Inserting text…", .failed(m) → m, .idle → nil

    /// The shortcut shown beside a hotkey switch; nil when none is assigned (no "not set").
    static func shortcutAnnotation(_ shortcut: String?) -> String?   // trims; empty → nil

    struct TranscriptionActivity: Equatable, Sendable {
        enum Progress: Equatable, Sendable { case percent(Int), indeterminate }
        let transcriptID: Int64?
        let title: String?          // nil for a failure without a row
        let caption: String         // "Transcribing file" | "Transcribing Me" | "Transcribing Others" | failure message
        let detail: String?         // "12:40 / 58:03" (clock/clock); nil for failures
        let progress: Progress?     // nil for failures
        let isFailure: Bool
    }
    /// nil for .idle and .finished (no persistent card).
    static func transcriptionActivity(_ state: FileTranscriptionController.State) -> TranscriptionActivity?

    /// File percent per the global rule; nil → indeterminate.
    static func filePercent(position: TimeInterval, duration: TimeInterval) -> Int?

    /// The status item while the popover is closed (spec §4 table).
    struct StatusItemContent: Equatable, Sendable {
        enum Symbol: Equatable, Sendable { case idle, recording }   // waveform / record.circle
        let symbol: Symbol
        let title: String           // "" when idle
        let tooltip: String
        let accessibilityLabel: String
    }
    static func statusItem(recordingElapsed: TimeInterval?,
                           transcription: FileTranscriptionController.State) -> StatusItemContent
}
```

`statusItem` rules (exact strings; `clock` = `TranscriptExporter.clock`):
| recording | transcription | symbol | title |
|---|---|---|---|
| nil | idle/finished/failed | idle | `""` |
| nil | file running, percent p | idle | `"p%"` |
| nil | file running, indeterminate | idle | `"…"` |
| nil | call running (speaker S) | idle | `"S clock(position)"` e.g. `"Me 12:40"` |
| t | idle/finished/failed | recording | `clock(t)` |
| t | file running | recording | `"\(clock(t)) · p%"` or `"\(clock(t)) · …"` |
| t | call running | recording | `"\(clock(t)) · …"` |

Tooltip: `"Macomprendo"`, then one line per activity: `"Recording call — \(clock(t))"`, `"Transcribing file — p%"` (or `— in progress`), `"Transcribing Me — 12:40 / 58:03"`. Accessibility label = tooltip lines joined with `", "`. Never a title or filename.

- [ ] **Step 1:** Write `MenuPanelPresentationTests` covering: each `dictationActivity` case (idle → nil); `shortcutAnnotation(nil/""/"  "/"⌃D")`; `filePercent` at (0,100)→0, (42.7,100)→42, (100,100)→99, (150,100)→99, (-5,100)→0, (10,0)→nil, (10,-1)→nil, (.nan,100)→nil, (10,.infinity)→nil; `transcriptionActivity` for idle/finished → nil, file running (title, "Transcribing file", "0:42 / 1:40" style detail from `TranscriptExporter.clock`, `.percent`), call running for `.me` and `.others` (`.indeterminate`, never percent even when position/duration look valid), failed with and without id (`isFailure`, caption = message, title nil, detail nil, progress nil); every `statusItem` table row plus tooltip/label contents and that a call track transition (`.me` → `.others`) with recording on keeps `.recording` symbol and the recording clock first.
- [ ] **Step 2:** Run `swift test --package-path macos --filter MenuPanelPresentationTests` → compile failure.
- [ ] **Step 3:** Implement; `npm run gen`.
- [ ] **Step 4:** Filter green; `npm run test:swift` green.
- [ ] **Step 5:** Commit `feat(menubar): pure panel presentation rules`.

---

### Task 2: Microphone picker — one observer per surface, stays in sync

**Files:**
- Modify: `macos/Sources/Macomprendo/UI/Settings/MicrophonePickerModel.swift`
- Modify: `macos/Sources/Macomprendo/App/AppModel.swift` (a second instance for the panel: `lazy var panelMicrophonePickerModel`)
- Test: `macos/Tests/MacomprendoTests/UI/MicrophonePickerModelTests.swift`

**Interfaces — Produces:** `AppModel.panelMicrophonePickerModel: MicrophonePickerModel` (same type, own observation lifetime). `MicrophonePickerModel` republishes when the holder's `preferredInputDeviceUID`/`Name` change from elsewhere.

Rules: Settings keeps `microphonePickerModel`; the panel uses `panelMicrophonePickerModel`; each has its own `startObserving`/`stopObserving`, so closing one surface never stops the other's device updates. Cross-surface invalidation: the model must publish `objectWillChange` when the persisted microphone choice changes through the *other* instance (or anywhere). Implement by accepting a `settingsChanges: AnyPublisher<Settings, Never>` (or an equivalent closure-based subscription) in `init` — `AppModel` passes `$settings.eraseToAnyPublisher()`; the model sends `objectWillChange` only when the microphone fields differ from the last seen value (no churn on unrelated settings writes). Keep the existing `init(holder:devices:)` call sites compiling (default parameter).

- [ ] **Step 1:** Tests (with the existing fakes for devices and a settings holder exposing a `PassthroughSubject`/`CurrentValueSubject`): two models over one holder/devices — `a.stopObserving()` leaves `b` receiving device changes (fake emits a change → `b.connected` updated); writing `a.selection = uid` makes `b` publish exactly once (count `objectWillChange`) and `b.selection == uid`; an unrelated settings write publishes nothing; disconnected-selection option/caption still correct.
- [ ] **Step 2:** RED. **Step 3:** Implement. **Step 4:** green + full suite. **Step 5:** Commit `feat(menubar): microphone picker per surface, kept in sync`.

---

### Task 3: Show All Windows — eligibility and raising

**Files:**
- Create: `macos/Sources/Macomprendo/Services/WindowRaiser.swift` (protocol `WindowRaising` + AppKit `AppKitWindowRaiser` + pure eligibility)
- Create: `macos/Tests/MacomprendoTests/Fakes/FakeWindowRaiser.swift`
- Modify: `macos/Sources/Macomprendo/App/AppEnvironment.swift`, `Tests/.../Fakes/FakeEnvironment.swift` (new `windowRaiser` member)
- Test: `macos/Tests/MacomprendoTests/Services/WindowEligibilityTests.swift`

**Interfaces — Produces:**

```swift
struct WindowSnapshot: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case settings, dictationHistory, transcripts, about, onboarding, quickPanel
        case statusItem, popover, hud, correctionReview, sheet, panelChooser, other
    }
    let kind: Kind
    let isVisible: Bool
    let isMiniaturized: Bool
}
enum WindowEligibility {
    /// Eligible: settings/history/transcripts/about/onboarding/quickPanel that are visible or
    /// miniaturized. Everything else (status item, popover, HUD, correction review, sheets,
    /// open/save panels, unknown) never; a closed (not visible, not miniaturized) retained
    /// window never.
    static func isEligible(_ window: WindowSnapshot) -> Bool
}
@MainActor protocol WindowRaising: AnyObject {
    /// Whether any eligible window exists right now (drives the command's disabled state).
    var hasEligibleWindows: Bool { get }
    /// Activates the app, deminiaturizes eligible minimized windows and orders every eligible
    /// window front; makes one key. Creates nothing, closes nothing.
    func raiseAll()
}
```

Classification in `AppKitWindowRaiser` (verify each against the running app and record what you found in the report): SwiftUI `Window` scenes' `NSWindow.identifier?.rawValue` starts with the `WindowID` value (`dictation-history`, `transcripts`, `about`) — confirm; the SwiftUI Settings window's identifier is `com_apple_SwiftUI_Settings_window`; onboarding is the `NSWindow` owned by `OnboardingWindowController` (give it an explicit identifier `macomprendo-onboarding` if it has none); the Quick Panel is the `FloatingPanel` class from `UI/Components/FloatingPanel.swift` (match by type or set an identifier `macomprendo-quick-panel`) — but the HUD and correction-review overlays may also be `FloatingPanel`s, so prefer explicit identifiers set where those windows are created; `NSStatusBarWindow`, `_NSPopoverWindow`, `NSOpenPanel`/`NSSavePanel`, any window with a `sheetParent` → excluded. Prefer explicit identifiers over class-name sniffing; where a class name is the only signal, keep the string in one place with a comment.

- [ ] **Step 1:** Eligibility tests for every kind × visible/miniaturized/closed; RED.
- [ ] **Step 2:** Implement eligibility, protocol, AppKit raiser (thin; smoke-covered), identifiers at window creation sites as needed; fake records `raiseAll` calls and serves a settable `hasEligibleWindows`; wire into `AppEnvironment`/`FakeEnvironment`; `npm run gen`.
- [ ] **Step 3:** green + full suite; Commit `feat(menubar): show all windows behind a protocol`.

---

### Task 4: Status item + popover host

**Files:**
- Create: `macos/Sources/Macomprendo/App/StatusItemController.swift` (AppKit: `NSStatusItem`, transient `NSPopover`, hosting controller, title writer)
- Create: `macos/Sources/Macomprendo/App/StatusItemTitleWriter.swift` (pure-ish dedupe: holds last `StatusItemContent`, applies only on change) — or nest it if small
- Modify: `macos/Sources/Macomprendo/App/MacomprendoApp.swift` (scene graph), `App/AppModel.swift` (own the controller; create it in `start()` via an environment factory; `closePanel()` passthrough), `App/AppEnvironment.swift` + fake (factory `makeStatusItem: (@MainActor (AppModel) -> any StatusItemHosting)?`, `nil` in tests)
- Test: `macos/Tests/MacomprendoTests/App/StatusItemTitleWriterTests.swift`, plus an `AppModelTests` case for the panel-close passthrough with a fake host

**Interfaces — Produces:**

```swift
@MainActor protocol StatusItemHosting: AnyObject {
    func closePanel()
    var isPanelShown: Bool { get }
}
```
`AppModel.closeMenuPanel()` calls `statusItem?.closePanel()`; the panel's commands call it.

Behaviour (spec §6):
- Status button: SF Symbol template image from `StatusItemContent.symbol` (`waveform` / `record.circle`), title from `.title` with `NSFont.monospacedDigitSystemFont`, tooltip and accessibility label from the content. Content is recomputed from `callRecording.$state` + `$elapsed` and `fileTranscription.$state` via Combine; **never** from `$levels`; written only when it changes (title writer).
- Left and right click toggle the popover (`sendAction(on: [.leftMouseUp, .rightMouseUp])`); `behavior = .transient`; button highlighted while shown (`button.highlight(true/false)` in show/close + `NSPopoverDelegate.popoverDidClose`); Escape closes (popover default when key — verify); repeat click closes.
- One `NSHostingController(rootView: MenuPanelView(...).environmentObject(model))` created once and kept; `popover.contentViewController` set once. Size: let SwiftUI size it (`sizingOptions = .preferredContentSize`); cap the panel's max height to the status button's screen `visibleFrame.height - 40` (pass it into the view as a parameter on each show).
- `popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)`, then `NSApp.activate(ignoringOtherApps: true)` and make the popover window key so ⌘, / ⌘Q and Escape reach it.
- Scene graph in `MacomprendoApp`: the first scene is `MenuBarExtra("Macomprendo", isInserted: .constant(false)) { EmptyView() }` — a spike showed SwiftUI otherwise opens the first `Settings`/`Window` scene at launch, while the hidden extra keeps launch window-free; it creates a zero-height status window and nothing visible. Remove the real `MenuBarExtra` and `CallRecordingMenuLabel`. Add `applicationShouldTerminateAfterLastWindowClosed → false` to `AppDelegate` (with a test in `AppDelegateTests`). Keep `applicationShouldTerminate` exactly as is.
- Until Task 5 lands, host the **existing** `MenuBarView` content inside the popover is not possible (it is menu-styled) — host a minimal placeholder `MenuPanelView` with a `Quit` button so the app stays usable; Task 5 replaces it. Keep the placeholder in `UI/MenuBar/MenuPanelView.swift`.

- [ ] **Step 1:** RED tests: title writer applies the first content, skips an identical one, applies a changed one (count writes on a fake button sink); `AppDelegate.applicationShouldTerminateAfterLastWindowClosed == false`; `AppModel.closeMenuPanel()` reaches a fake host.
- [ ] **Step 2:** Implement; delete `CallRecordingMenuLabel` usage (and its tests that only assert the old label — replace with presentation tests from Task 1, don't weaken unrelated ones); `npm run gen`.
- [ ] **Step 3:** `swift build`, `npm run test:swift` green; then **native check**: `npm run install-app:signed`, confirm via `log`/`NSApp.windows` dump or Peekaboo that no window opens at launch, the status item shows, a click shows the popover. Record evidence in the report (no screenshots needed). Commit `feat(menubar): own status item and popover`.

---

### Task 5: The panel, per the spec; docs

Read the spec §2–§6 and the HTML mockup before starting. Load skills `frontend-design` and `swiftui-macos-ui` if available.

**Files:**
- Modify: `macos/Sources/Macomprendo/UI/MenuBar/MenuPanelView.swift` (the real panel)
- Create as needed: `UI/MenuBar/MenuPanelRows.swift` (row/button styles), `UI/MenuBar/CallRecordingPanelSection.swift`, `UI/MenuBar/TranscriptionActivitySection.swift`
- Delete: `UI/MenuBar/MenuBarView.swift`, `UI/MenuBar/CallRecordingMenu.swift` (keep anything still used elsewhere, e.g. move `CallLevelMeter` only if referenced; delete its tests if the type goes)
- Modify: `Resources/Icons/icons.json` + `UI/Components/Icon.swift` for any new icon (e.g. `file-audio`, `clock-counter-clockwise`, `app-window`/`squares-four`, `shield-check`, `info`, `power`, `record`, `stop`), via `npm run sync-icons`
- Modify: `docs/SMOKE_TEST.md` (replace the menu section with the spec §8 native smoke list), `docs/ARCHITECTURE.md` (menu ownership: status item + popover + hidden MenuBarExtra anchor; history readable when saving is off), `CHANGELOG.md` `Unreleased` (`### Changed`: the new panel; `### Fixed`: hover no longer jumps during a recording — merge with the existing Fixed entry about the menu rebuild)

**Layout** (spec §3, order fixed): header `Macomprendo` (semibold) → call block → dictation activity line (Task 1, only when non-nil, below the call block) → transcription activity card (Task 1) → Microphone / Dictation model / Translate into pickers (caption above value, `Picker(.menu)` style, model uses `dictation.selectableSources` / `activeSource` / `activate` / `hasReadySource`; microphone uses `panelMicrophonePickerModel` with `startObserving` on appear / `stopObserving` on disappear and its caption) → divider → Transcribe File… / Transcripts… / Dictation History… → divider → `Options` disclosure (collapsed on every open: `Save dictation history` switch, then the six `HotkeyAction.allCases` switches with `shortcutAnnotation(action.currentShortcutText())` trailing, re-read on each open, plus a one-line hint "Change shortcuts in Settings ▸ Hotkeys") → Show All Windows (disabled with `.help("No Macomprendo windows are open")` when `!hasEligibleWindows`, re-evaluated on open) / Settings… ⌘, / Check permissions… / About Macomprendo… / Quit Macomprendo ⌘Q.

**Call block:** idle → full-width secondary button `Record Call` (icon) with the record-call shortcut annotation if bound; recording → a group: red-dot (semantic `.red` + text) `Recording call` left, `clock(elapsed)` right (monospaced digits), full-width prominent `Stop Recording` button, then `Me` / `Others` rows with `LevelMeter` (observe `CallRecordingController` **only inside this subview**); a start failure's message under it. Stop sits above the meters; tick updates must not change any row's frame (fixed heights).

**Transcription card:** caption + percent (or spinner `ProgressView().controlSize(.small)` for indeterminate), title (one line, middle-truncated), `ProgressView(value:)` for a percent, `detail` clock text; failure variant shows the message. The whole card is a button: close panel → `NSApp.activate` → `await model.transcriptLibrary.select(id)` (when id) → `openWindow(id: WindowID.transcripts)`; make sure `TranscriptsView`'s initial `.task` reload does not drop that selection (check `TranscriptLibraryController.reload` keeps `selected`; fix there with a test if it does not).

**Commands:** every command that opens a window or chooser calls `model.closeMenuPanel()` first, then `NSApp.activate(ignoringOtherApps: true)`, then routes (`openWindow` / `openSettings` / `OnboardingWindowController.show(model:)` / `NSOpenPanel` exactly as `MenuBarView` did for Transcribe File…). Switches, pickers, Record/Stop keep the panel open. Quit: `NSApp.terminate(nil)` (existing async shutdown). `.keyboardShortcut(",")` on Settings… and `.keyboardShortcut("q")` on Quit.

**Look:** ~300 pt wide, 12 pt outer padding, rows ~24 pt with a hover highlight using `Color(nsColor: .selectedContentBackgroundColor)` + `.selectedMenuItemTextColor`-equivalent foreground on hover (secondary text stays legible), icons from `Icon(.case, size: 14)` in a fixed-width leading column, dividers inset, no custom background/shadow (native popover material), respects Reduce Motion (no animation on ticks). If the content is taller than the passed max height, the region below the call/transcription blocks scrolls (one `ScrollView`, not nested).

- [ ] **Step 1:** Icons TDD via `IconTests` (add cases → RED → sync → GREEN).
- [ ] **Step 2:** Build the panel and sections; delete the old menu files and superseded tests; `npm run gen`.
- [ ] **Step 3:** Any new pure helper gets a test first (e.g. which commands close the panel, if expressed as data).
- [ ] **Step 4:** `swift build` (no new warnings), `npm run test:swift`, `npm run test:scripts`, `npm run audit`, `npm run gen` twice no diff; `npm run install-app:signed`; open the popover once to confirm it renders (report what you observed; the operator does the full smoke).
- [ ] **Step 5:** Commits `feat(menubar): quick-access panel` and `docs(menubar): smoke test, architecture, changelog`.

## Self-review

Spec coverage: §3 order/contents → T5 (+T1 dictation line, shortcuts, T2 microphone); §3 non-idle dictation → T1/T5; §4 progress card → T1/T5, status item table → T1/T4; open-by-id → T5; §5 Show All Windows → T3/T5; §6 lifecycle (transient, clicks, highlight, Escape, ⌘,/⌘Q, height cap, hosting retained) → T4/T5; appearance → T5 look rules; §7 cold-launch routing → T4 hidden-extra anchor + spike result; §8 docs → T5. Type names consistent: `MenuPanelPresentation`, `TranscriptionActivity`, `StatusItemContent`, `WindowSnapshot`, `WindowEligibility`, `WindowRaising`, `StatusItemHosting`, `panelMicrophonePickerModel`, `closeMenuPanel()`.
