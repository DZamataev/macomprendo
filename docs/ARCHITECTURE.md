# Macomprendo architecture

## Layers

```
┌────────────────────────────────────────────────────────────┐
│ UI            MenuBar · Settings · QuickPanel · HUD         │
│               Onboarding · Components                       │
└───────────────────────────┬────────────────────────────────┘
                            │ observes / calls
┌───────────────────────────▼────────────────────────────────┐
│ Features      DictationController · RefineController        │
│               SummarizeController · SpeakController         │
│               Prompts (PromptPreset, Renderer, Factory)     │
│               @MainActor, explicit state enums              │
└─────────────┬────────────────────────────┬─────────────────┘
              │                            │
┌─────────────▼──────────────┐ ┌───────────▼─────────────────┐
│ Services                   │ │ Providers                   │
│ HotkeyServicing            │ │ HTTPClient                  │
│ AudioRecording             │ │ LLMProvider                 │
│ SelectedTextReading        │ │  · OllamaProvider           │
│ TextInserting              │ │  · OpenAICompatibleLLM…     │
│ FrontmostAppTracking       │ │ TranscriptionProvider       │
│ SpeechSynthesizing         │ │  · WhisperCppTranscriber    │
│ ModelManaging              │ │  · OpenAICompatible…        │
│ PermissionsChecking        │ │ Streaming (SSE, NDJSON)     │
└─────────────┬──────────────┘ └───────────┬─────────────────┘
              │                            │
┌─────────────▼────────────────────────────▼─────────────────┐
│ Core          Settings · Endpoint · SettingsStore           │
│               KeychainStore · MacomprendoError · Log        │
│               Pasteboard                                    │
└────────────────────────────────────────────────────────────┘
```

## Rules

1. **Dependencies point downward only.** Core never imports Services, Providers,
   Features or UI. Services and Providers never import Features or UI. Features never
   import UI.
2. **Services and Providers meet the layers above them at a protocol.** The protocol is
   declared in the same file as its default implementation; consumers take
   `any SomeProtocol`, never the concrete type.
3. **`App/AppEnvironment.swift` is the only composition root.** It is the single place
   where `UserDefaultsSettingsStore`, `SystemKeychainStore`, `AVAudioEngineRecorder`,
   `URLSessionHTTPClient` and friends are constructed. A `new`-expression for a concrete
   service anywhere else is a bug.
4. **`AppModel` owns `Settings`.** It loads on launch, writes back on every mutation, and
   is injected into views as an `@EnvironmentObject`. Nothing else reads `UserDefaults`.
5. **Concurrency.** Controllers and views are `@MainActor`. Providers are `Sendable`
   structs; long-lived stateful services are `actor`s. Classes with lock-guarded state
   declare `@unchecked Sendable`. Each controller keeps at most one in-flight `Task` and
   cancels it before starting the next.
6. **Errors are values.** Every user-visible failure is a `MacomprendoError` with an
   `errorDescription` and a `recoverySuggestion`; the HUD or the Quick Panel shows both.
7. **Secrets.** `Settings.endpoints[].apiKeyRef` is a Keychain account name.
   `KeychainStoring` is the only path to the secret itself. Keys never appear in logs,
   settings, or error text.
8. **Privacy.** `Log` categories exist so transcript and LLM text can be excluded: never
   log them at the default level.

## Testing strategy

| Kind | How |
|---|---|
| Value types, parsers, renderers | Plain unit tests |
| Providers | `StubHTTPClient` — scripted responses and chunk boundaries |
| Controllers | Fakes for every injected protocol; assert on the state enum |
| Pasteboard logic | `FakePasteboard`, asserting `restoreCalls` |
| Hardware glue (AVAudioEngine, AX, CGEvent, whisper C calls, NSPanel) | Kept thin, no unit tests; covered by `docs/SMOKE_TEST.md` |

## Build topology

Two manifests describe one source tree:

- `macos/Package.swift` — SwiftPM. Runs the tests (`swift test --package-path macos`) and
  builds the release binary.
- `macos/project.yml` — XcodeGen. Generates `macos/Macomprendo.xcodeproj` for IDE work and
  the unsigned CI compile check.

Both declare the same two dependencies. `macos/Packages/WhisperBinary` wraps the prebuilt
`whisper.xcframework` published with each whisper.cpp release, because whisper.cpp itself
no longer ships a `Package.swift`.

## Icons

In-app icons are Phosphor (MIT), vendored as SVGs in
`macos/Sources/Macomprendo/Resources/Icons/` and listed in `icons.json`. They are copied
there by `npm run sync-icons` from the `@phosphor-icons/core` devDependency and committed,
so no Swift build needs Node. `UI/Components/Icon.swift` is the only file that knows an
icon is an SVG: it loads the file through `NSImage`, marks it `isTemplate`, and falls back
to an SF Symbol if the resource is missing. Views write `Icon(.microphone)` and never
`Image(systemName:)`.

The `phosphor-icons/swift` SPM package is deliberately **not** used — it declares no
resources, so `Bundle.module` does not exist and it fails to compile under `swift build`.
The menubar status item is the one place an SF Symbol is correct, because `MenuBarExtra`
requires a template symbol name.
