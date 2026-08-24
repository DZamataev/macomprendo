---
name: macomprendo-add-hotkey-feature
description: Use when adding a new global-hotkey action to Macomprendo — the wiring from HotkeyAction through the controller to the HUD or Quick Panel, and how to test the state machine.
---

# Adding a hotkey feature

A feature is: a `HotkeyAction` case, a `@MainActor` controller with an explicit state
enum, a UI surface (Recording HUD or Quick Panel), and a Settings row.

## 1. Declare the action

`Services/HotkeyService.swift`:

```swift
enum HotkeyAction: String, CaseIterable, Sendable {
    case dictate, dictateAndRefine, speak, summarize, refineSelection
}
enum HotkeyEvent: Sendable, Equatable { case keyDown(HotkeyAction), keyUp(HotkeyAction) }
```

Add the case, then add the matching `KeyboardShortcuts.Name` with its default shortcut.
`KeyboardShortcuts.Name` is **not** `Sendable`, so the constant must be `@MainActor`:

```swift
extension KeyboardShortcuts.Name {
    @MainActor static let dictate = Self("dictate", default: .init(.space, modifiers: [.option]))
}
```

Both `keyDown` and `keyUp` are delivered, because hold-to-talk needs the key-up.

## 2. Write the controller

`Features/<Name>Controller.swift`. It is `@MainActor`, an `ObservableObject`, owns an
explicit state enum, and takes every collaborator as a protocol:

```swift
enum DictationState: Equatable { case idle, recording, transcribing, inserting, failed(String) }

@MainActor final class DictationController: ObservableObject {
    @Published private(set) var state: DictationState = .idle
    private var task: Task<Void, Never>?

    init(recorder: any AudioRecording,
         transcriberProvider: @escaping @Sendable () async throws -> any TranscriptionProvider,
         inserter: any TextInserting,
         tracker: any FrontmostAppTracking,
         permissions: any PermissionsChecking,
         hud: HUDController,
         settings: @escaping @MainActor () -> Settings)

    func handle(_ event: HotkeyEvent)
    func cancel()
}
```

Rules that apply to every controller:

- **Check permissions before starting**, not after failing: `permissions.status(of:)`,
  and on `.denied` show `MacomprendoError.permissionDenied(_)` and offer
  `openSystemSettings(for:)`.
- **Capture the frontmost app on key-down** with `FrontmostAppTracking.capture()`; the
  user will have moved focus by the time you insert.
- **One in-flight task.** Store it, and `task?.cancel()` before starting the next.
- **Hold vs toggle** comes from `Settings.dictationMode`: in `.hold`, `keyDown` starts and
  `keyUp` stops; in `.toggle`, `keyDown` starts and the next `keyDown` stops, and a third
  press while transcribing cancels.
- **Every failure sets `.failed(message)`** built from a `MacomprendoError`, and shows it
  in the HUD. Nothing fails silently.

## 3. Wire it up

- Construct the controller in `App/AppEnvironment.live()` and store it on `AppEnvironment`.
- `AppModel` subscribes to `HotkeyServicing.events` and forwards each event to the right
  controller.
- Add the recorder row to `UI/Settings/HotkeysTab.swift`
  (`KeyboardShortcuts.Recorder(for: .yourAction)`).
- Add a toggle to `UI/MenuBar/MenuBarView.swift` if the feature can be disabled.

## 4. Test the state machine

Drive `handle(_:)` with `HotkeyEvent`s and fakes for every protocol, then assert on
`state`. Cover: the happy path; permission denied; an empty transcript ("Nothing heard");
a provider error; cancellation mid-flight; and a second key-down arriving while the first
task is still running.

The hardware implementations (`AVAudioEngineRecorder`, `CGEventKeySimulator`,
`AXSelectedTextService`, `KeyboardShortcutsHotkeyService`) get no unit tests — keep them
thin and add a line to `docs/SMOKE_TEST.md`.
