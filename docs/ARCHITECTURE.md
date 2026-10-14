# Macomprendo architecture

## Layers

```
┌────────────────────────────────────────────────────────────┐
│ UI            MenuBar · Settings · QuickPanel · HUD         │
│               CorrectionReview · Onboarding · History       │
│               About · Components                            │
└───────────────────────────┬────────────────────────────────┘
                            │ observes / calls
┌───────────────────────────▼────────────────────────────────┐
│ Features      DictationController · DictationCapture        │
│               DictationHistoryController                    │
│               RefineController · SummarizeController        │
│               SpeakController                               │
│               Prompts (PromptPreset, Renderer, Factory)     │
│               @MainActor, explicit state enums              │
└─────────────┬────────────────────────────┬─────────────────┘
              │                            │
┌─────────────▼──────────────┐ ┌───────────▼─────────────────┐
│ Services                   │ │ Providers                   │
│ HotkeyServicing            │ │ HTTPClient                  │
│ MiddleMouseMonitoring      │ │ LLMProvider                 │
│ AudioRecording             │ │  · OllamaProvider           │
│ AudioInputDeviceListing    │ │  · OpenAICompatibleLLM…     │
│ SelectedTextReading        │ │ TranscriptionProvider       │
│ TextInserting              │ │  · WhisperCppTranscriber    │
│ FrontmostAppTracking       │ │  · GigaAMTranscriber        │
│ SpeechSynthesizing         │ │  · OpenAICompatible…        │
│ ModelManaging              │ │ DictationAudioEncoding      │
│ PermissionsChecking        │ │ Streaming (SSE, NDJSON)     │
│ LanguageDetecting          │ │                             │
│ ActivationPolicyControlling│ │                             │
│ DictationHistoryStoring    │ │                             │
│ GlossaryStoring            │ │                             │
└─────────────┬──────────────┘ └───────────┬─────────────────┘
              │                            │
┌─────────────▼────────────────────────────▼─────────────────┐
│ Core          Settings · DictationHistoryEntry · Endpoint   │
│               Glossary · Normalizer · CorrectionReview      │
│               SettingsStore · KeychainStore                 │
│               MacomprendoError · Log · Pasteboard           │
└────────────────────────────────────────────────────────────┘
```

The diagram names the main seams, not every protocol: `rg 'protocol \w+' macos/Sources` lists
them all.

Factory prompt presets (`Features/Prompts/FactoryPresets.swift`) are the cross product of
`FactoryPresets.Role` (eight refine roles, four summarize roles) and `PromptLanguage` (seven
languages) — 84 presets in all, with content for each language written natively in
`Features/Prompts/Factory/FactoryPresets+<Language>.swift`. A preset's UUID is not random:
`FactoryPresets.presetID(role:language:)` derives it from the role's and the language's fixed
hex slots, so `restoreMissing(into:)` can tell "deleted factory preset" from "custom preset"
across all seven languages without a lookup table.

### Dictation history

`Settings.dictationHistoryEnabled` is off by default. At the two accepted microphone
transcript commit points, `DictationController` and `DictationCapture` ask the shared
`@MainActor` `DictationHistoryController` to record the text for Dictate or Dictate & Refine.
The controller depends on `DictationHistoryStoring` and `PasteboardProtocol`; `AppModel` owns
it, and `AppEnvironment` constructs the actor-backed `SQLiteDictationHistoryStore` at
`~/Library/Application Support/Macomprendo/dictation-history.sqlite3`.

The store retains the newest 100,000 text records, pages them by descending insertion ID, and
clears records only on the confirmed user action. Disabling the preference stops new writes
without purging existing records. `DictationHistoryView` is the UI consumer in the history
window; the menu opens that single SwiftUI window only while the preference is enabled, and
the existing `DockIconCoordinator` keeps the Dock icon visible while the window is open.
This preserves the UI → Features → Services → Core dependency direction.

Each row also carries the transcript before normalisation (`rawText`), a `TranscriptionRun` —
model, engine, language and app version that produced it — and, while **Save the original
recording** is on, an `.m4a` file written by `DictationAudioEncoding` (AAC or ALAC, ADR-0011).

### Glossary and normalisation

Packs are plain text files in `~/Library/Application Support/Macomprendo/Vocabulary/`
(ADR-0012); `packs.json` beside them lists the enabled ones. `GlossaryStoring` owns that
directory — seeding the six factory packs from the bundle, reading, writing and reporting files
it cannot parse. `Glossary` flattens the enabled packs plus the manual list into one key →
canonical-spelling map, where a term's listed forms (`pytest = пайтест`) are extra keys for the
same spelling, matched whole; `Normalizer.normalise` rewrites matching windows of a transcript and
reports every rewrite with its range in the *final* text. Both are pure Core types.

`DictationController` and `DictationCapture` normalise at the same two commit points that write
history, reading the glossary when the transcript arrives. Normalisation comes before biasing
(ADR-0013); biasing the recogniser itself is not implemented.

### Post-dictation review

When normalisation rewrote something, `DictationController` hands a `CorrectionReview` — a
projection of the normalisation result, never a second match — to `CorrectionReviewPresenting`.
The presenter owns a non-activating `FloatingPanel` placed below the HUD band, so the panel never
takes focus from the app the text was pasted into. It hides after two seconds, holds while
hovered, and is dismissed at the next dictation boundary.

### Audio capture

`AVAudioEngineRecorder` binds the input node to a device explicitly — the chosen
`Settings.preferredInputDeviceUID`, else the system default — so a device appearing, vanishing
or becoming the default mid-recording moves the recording instead of stranding it.
`AudioInputDeviceListing` reads devices and change notifications from the Core Audio HAL; the
engine itself sits behind `AudioInputEngine`, so device handling is unit-tested against a fake.

Two silence checks with different jobs:

- **Dead device.** A device delivering digital zeros (below −100 dBFS) for two seconds is
  excluded for the rest of the recording; the recorder moves to the system default, then the
  built-in microphone, and publishes an `InputFallback` the HUD and the refine toast show.
- **Silent capture.** A whole recording whose peak stays under −60 dBFS
  (`AudioMath.silenceThresholdDB`) is never sent to the transcriber: a model handed silence
  invents a word. It fails as `MacomprendoError.silentCapture`. The HUD warns after three
  seconds without input while recording continues.

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

Both declare the same three dependencies: `KeyboardShortcuts`, and two local wrappers around
vendored binaries. `macos/Packages/WhisperBinary` wraps the prebuilt `whisper.xcframework`
published with each whisper.cpp release, because whisper.cpp itself no longer ships a
`Package.swift`; `macos/Packages/SherpaOnnxBinary` wraps sherpa-onnx, which runs GigaAM and
local TTS (ADR-0009).

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
