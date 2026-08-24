---
name: macomprendo-architecture
description: Use when adding or moving any Swift type in Macomprendo — explains the four layers, where a new file belongs, and the protocol-injection rule that keeps controllers testable.
---

# Macomprendo architecture

## The layers

```
UI  ──▶  Features (controllers, @MainActor, explicit state enums)
             │
             ▼
        Services (protocols + default impls)   Providers (protocols + impls)
             │                                         │
             ▼                                         ▼
        Core (Settings, Endpoint, Keychain, Errors, Log, Pasteboard)
```

Dependencies point downward only. Core imports nothing from above it. Two files in
different layers never import each other's concrete types — they meet at a protocol
declared in the lower layer.

## Where does my new file go?

| It… | Layer | Directory |
|---|---|---|
| is a value type persisted in `Settings` | Core | `Core/` |
| talks to macOS (audio, AX, pasteboard, keyboard, speech, files) | Services | `Services/` |
| talks HTTP to a model server | Providers | `Providers/` |
| orchestrates a hotkey action and owns a state machine | Features | `Features/` |
| is a SwiftUI view or panel controller | UI | `UI/` |

Tests mirror the path: `Tests/MacomprendoTests/<Layer>/<Name>Tests.swift`. Fakes go in
`Tests/MacomprendoTests/Fakes/`.

## The protocol-injection rule

Anything that touches the OS or the network is declared as a protocol in the same file
as its default implementation:

```swift
protocol TextInserting: Sendable {
    func insert(_ text: String, into app: FrontmostApp?, method: InsertMethod) async throws
}
struct PasteTextInserter: TextInserting { /* … */ }
```

Controllers take the protocol, never the concrete type:

```swift
@MainActor final class DictationController: ObservableObject {
    init(recorder: any AudioRecording, inserter: any TextInserting, /* … */)
}
```

`App/AppEnvironment.swift` is the **only** place that constructs real implementations.
If you find yourself writing `AVAudioEngineRecorder()` inside a controller or a view,
you are in the wrong file.

## Concurrency

- Controllers and views: `@MainActor`.
- Providers and services: `Sendable` structs or `actor`s.
- Mutable shared state in a class: guard it with `NSLock` and declare
  `final class X: SomeProtocol, @unchecked Sendable`.
- One in-flight `Task` per controller, stored in a property, cancelled before the next
  action starts.

## Errors

Every failure a user can see is a `MacomprendoError` case with both
`errorDescription` and `recoverySuggestion`. Adding a new failure mode means adding a
case *and* both strings *and* a row in `MacomprendoErrorTests`.
