# Macomprendo — Design Spec

Date: 2026-08-23 · Status: approved for planning

## 1. Purpose

Macomprendo is a native, menubar-only macOS app that turns global hotkeys into four
text/voice actions:

| # | Action | Default hotkey | Input | Output |
|---|--------|----------------|-------|--------|
| 1 | **Dictate** | ⌥Space (hold or toggle) | microphone | transcript pasted into the frontmost app |
| 2 | **Dictate & Refine** | ⌥⇧Space | microphone | Quick Panel: original + LLM-refined text; Copy / Insert either |
| 3 | **Speak selection** | ⌥S | selected text | spoken through the default audio output |
| 4 | **Summarize selection** | ⌥M | selected text | Quick Panel with a streamed summary; Copy / Replace selection |
| 5 | **Refine selection** | unassigned | selected text | same Quick Panel as #2 |

Transcription runs locally with whisper.cpp by default, or through any
OpenAI-compatible `/v1/audio/transcriptions` endpoint. LLM features (refine,
summarize) run through **Ollama** (local, default `http://localhost:11434`) or any
**OpenAI-compatible** chat-completions endpoint with an API key. No telemetry, no
network calls except those the user configures.

Non-goals for v1: file transcription, meeting recording, history/database of
transcripts, App Store sandboxing, bundled LLM inference, iOS.

## 2. Platform & project layout

- Swift 6 (strict concurrency), SwiftUI + AppKit, **macOS 14.0+**, universal binary.
- Not sandboxed (global hotkeys + Accessibility + paste simulation require it).
  Hardened runtime, Developer ID signed, notarized, distributed as stapled ZIP.
- Layout mirrors `mac-dev-clean`:

```
macomprendo/
  AGENTS.md                 # single source of agent instructions
  CLAUDE.md -> AGENTS.md    # symlink
  .agents/skills/macomprendo-*/SKILL.md   # single-source skills (Codex location)
  .claude/skills -> ../.agents/skills     # symlink
  .claude/agents/{planner,swift-implementer,reviewer}.md
  .claude/settings.json     # allowlisted build/test commands
  .github/workflows/ci.yml  # swift test + unsigned xcodebuild + audits, SHA-pinned actions
  docs/ARCHITECTURE.md  docs/SMOKE_TEST.md  docs/DECISIONS/ADR-*.md  docs/superpowers/{specs,plans}/
  package.json              # scripts runner (node >= 20); npm deps allowed when they earn their keep
  scripts/build-app.mjs  notarize-app.mjs  configure-notarization.mjs
          release.mjs  audit-public-repo.mjs  sync-agent-config.mjs  lib/ (shared helpers)
  scripts/__tests__/        # node:test unit tests for the scripts
  macos/
    project.yml             # XcodeGen source of truth; generated .xcodeproj committed
    Package.swift           # for `swift test` / `swift build`
    AppBundle/Info.plist, AppIcon.icns, Macomprendo.entitlements (hardened runtime only)
    Sources/Macomprendo/
      App/        MacomprendoApp.swift (@main, MenuBarExtra), AppModel.swift, AppEnvironment.swift
      Core/       Settings.swift, KeychainStore.swift, Logger.swift, MacomprendoError.swift, Endpoint.swift
      Services/   HotkeyService, AudioRecorder, SelectedTextService, TextInserter,
                  SpeechService, ModelManager, PermissionsService, FrontmostAppTracker
      Providers/  TranscriptionProvider.swift, WhisperCppTranscriber.swift, OpenAICompatibleTranscriber.swift,
                  LLMProvider.swift, OllamaProvider.swift, OpenAICompatibleLLMProvider.swift,
                  Streaming/ (SSEParser, NDJSONParser)
      Features/   DictationController, RefineController, SpeakController, SummarizeController,
                  Prompts/ (PromptPreset, FactoryPresets, PromptRenderer)
      UI/         MenuBar/, Settings/, QuickPanel/, RecordingHUD/, Onboarding/, Components/ (icons, buttons)
    Tests/MacomprendoTests/   (swift-testing, one file per unit, Fakes/ for protocol doubles)
```

### Dependencies (SwiftPM)

| Package | Why |
|---------|-----|
| whisper.cpp prebuilt xcframework via local SPM package `macos/Packages/WhisperBinary` (upstream ships no Package.swift) | local transcription, Metal embedded |
| `sindresorhus/KeyboardShortcuts` | global hotkeys + recorder UI |
| Phosphor Icons vendored as SVGs from npm `@phosphor-icons/core` (MIT) via `scripts/sync-icons.mjs` | in-app icons (the `phosphor-icons/swift` SPM package breaks `swift build` — ADR-0008) |

Everything else is Foundation/AppKit/SwiftUI/AVFoundation/`URLSession`. The menubar
status item uses an SF Symbol template image (Phosphor in-app only).

## 3. Architecture

Three layers, dependencies point downward only. Everything that touches hardware or
the OS sits behind a protocol so controllers and UI are unit-testable.

```
UI  ──▶  Features (controllers, @MainActor, own state machines)
             │
             ▼
        Services (protocols + default impls)        Providers (protocols + impls)
             │                                             │
             ▼                                             ▼
        Core (Settings, Keychain, Errors, Logging, Endpoint model)
```

### 3.1 Core

- `Settings` — `Codable` struct persisted in `UserDefaults` (key `settings.v1`), observed
  through `AppModel`. Fields: hotkeys (managed by KeyboardShortcuts), dictation mode
  (hold/toggle), `transcriptionSource` (`.local(modelID)` | `.endpoint(id, model)`),
  `llmSelection` per feature (`refine`, `summarize`) = `(endpointID, model)`,
  speech (voiceID, rate, pitch, volume), `presets: [PromptPreset]`, default preset per kind,
  launchAtLogin, insert method preference (`auto|paste|typing`), Quick Panel position overrides (the HUD is transient, always top-center, not persisted). Versioned with a `schemaVersion` and a migration hook.
- `Endpoint` — `{ id: UUID, name, kind: .ollama | .openAICompatible, baseURL,
  apiKeyRef }`. API keys live only in the Keychain (`KeychainStore` protocol; default
  uses `Security` framework, tests use `InMemoryKeychain`). Settings stores the
  reference, never the secret. Default seeded endpoint: "Ollama (local)".
- `MacomprendoError: LocalizedError` — `permissionDenied(kind)`, `modelMissing`,
  `modelDownloadFailed`, `providerUnreachable(endpoint)`, `providerHTTP(status, body)`,
  `providerStreamMalformed`, `audio(String)`, `noSelection`, `insertFailed`,
  `cancelled`. Each has `errorDescription` + `recoverySuggestion` shown in UI.
- `Logger` — `os.Logger` categories; never logs transcript/LLM text at default level.

### 3.2 Services (protocols)

| Protocol | Default impl | Notes |
|---|---|---|
| `HotkeyServicing` | `KeyboardShortcutsHotkeyService` | `.dictate`, `.dictateAndRefine`, `.speak`, `.summarize`, `.refineSelection`; delivers keyDown/keyUp so hold-to-talk works |
| `AudioRecording` | `AVAudioEngineRecorder` | 16 kHz mono Float32 PCM; `start()`, `stop() -> [Float]`; live RMS for HUD meter; 5-min cap |
| `SelectedTextReading` | `AXSelectedTextService` | AX `kAXSelectedTextAttribute` on focused element; fallback: save pasteboard → simulate ⌘C → read → restore |
| `TextInserting` | `PasteTextInserter` | re-activate remembered frontmost app, set pasteboard, simulate ⌘V, restore pasteboard after 300 ms; fallback copy-only + toast |
| `FrontmostAppTracking` | `NSWorkspaceTracker` | remembers app/pid active when hotkey fired |
| `SpeechSynthesizing` | `AVSpeechService` | enumerates `AVSpeechSynthesisVoice`, speaks, stops, publishes `isSpeaking` |
| `ModelManaging` | `WhisperModelManager` | catalog (tiny, base, small, medium, large-v3-turbo + `.en` variants), download with progress/resume/SHA-256 from Hugging Face `ggerganov/whisper.cpp`, store under `~/Library/Application Support/Macomprendo/models/` |
| `PermissionsChecking` | `SystemPermissions` | microphone (`AVCaptureDevice`), accessibility (`AXIsProcessTrustedWithOptions`), deep links to System Settings |

### 3.3 Providers

```swift
protocol TranscriptionProvider: Sendable {
    func transcribe(_ pcm: [Float], sampleRate: Int, language: String?) async throws -> String
}
protocol LLMProvider: Sendable {
    func listModels() async throws -> [String]
    func chat(_ messages: [ChatMessage], model: String, options: ChatOptions) -> AsyncThrowingStream<String, Error>  // token deltas
}
```

- `WhisperCppTranscriber` — wraps `whisper_full` on a background actor, loads the
  selected ggml model lazily and keeps it resident; Metal on by default.
- `OpenAICompatibleTranscriber` — multipart POST to `{baseURL}/v1/audio/transcriptions`
  (WAV encoded from PCM), `Authorization: Bearer <key>`, `model` field, `response_format=json`.
- `OllamaProvider` — `GET /api/tags`, `POST /api/chat` with `stream: true` (NDJSON),
  `POST /api/pull` for the one-click "Pull qwen2.5:1.5b" button.
- `OpenAICompatibleLLMProvider` — `GET /v1/models`, `POST /v1/chat/completions`
  with `stream: true` (SSE `data:` lines, `[DONE]` terminator).
- `ProviderFactory` builds the right provider for an `Endpoint`. Ollama endpoints also
  satisfy `/v1/...`, so the factory prefers the native Ollama API only for
  `kind == .ollama` (needed for pull + tags).
- All HTTP goes through a `HTTPClient` protocol (`URLSession` default; tests use a
  `URLProtocol` stub). Timeouts: connect 10 s, stream idle 60 s. Streams are cancelled
  by `Task` cancellation.

### 3.4 Features (controllers)

Each is a `@MainActor` `ObservableObject` with an explicit state enum and injected
services; `AppModel` owns one of each and wires hotkeys → controllers.

- **DictationController** — `idle → recording → transcribing → inserting → idle|failed`.
  Hold mode: keyDown starts, keyUp stops. Toggle mode: press starts, press stops; second
  press while transcribing cancels. Empty/near-silent result → "Nothing heard" toast.
- **RefineController** — same capture as dictation (or selected text for #5), then opens
  Quick Panel in *refine* layout, streams `LLMProvider.chat` with the chosen preset.
  Presets are user data (see §3.6): factory presets Clean up (default), Formal, Casual,
  Shorten, Expand, Fix grammar, Translate to ‹language› are seeded on first run and can
  be edited, reordered, deleted, or supplemented with new ones. Re-run with ⌘↩ after
  editing the instruction. Actions: Copy original / Copy refined / Insert original / Insert refined
  (Insert = `TextInserting` into remembered app; for #5 it replaces the selection).
- **SummarizeController** — selected text → Quick Panel in *summary* layout; uses the
  summarize presets (§3.6); actions Copy / Replace selection.
- **SpeakController** — selected text → `SpeechSynthesizing`; pressing the hotkey while
  speaking stops. The HUD shows a "Speaking…" state with the stop hint while audio plays.

### 3.6 Prompt presets

Refine and summarize prompts are fully user-customizable:

- `PromptPreset { id: UUID, kind: .refine | .summarize, name, systemPrompt, userTemplate,
  isFactory: Bool, sortOrder }`, stored in `Settings.presets`. `userTemplate` supports
  `{text}` (required), `{instruction}` and `{language}` placeholders; `PromptRenderer`
  validates that `{text}` is present and renders the final messages.
- `FactoryPresets.swift` holds the defaults (refine: Clean up, Formal, Casual, Shorten,
  Expand, Fix grammar, Translate; summarize: Brief, Bullets, TL;DR, Key actions) plus a
  shared default system prompt ("return only the result, no commentary"). They are
  seeded once (`Settings.presetsSeeded`) and thereafter are ordinary presets: the user
  can edit any field, reorder, delete unused factory presets, add new ones, and
  "Restore factory presets" (re-adds missing factory items without touching custom ones).
- Settings ▸ Refine & Summarize shows a preset list per kind with add/duplicate/delete,
  an editor (name, system prompt, user template, live placeholder check, "Test with
  sample text" button that streams from the selected endpoint), and a default-preset
  picker per kind. The Quick Panel's preset picker reads the same list.
- At least one preset per kind must exist; deleting the last one is refused with a
  message. Deleting the default preset moves the default to the first remaining one.

### 3.5 UI

- **Menubar** (`MenuBarExtra`, `.menu` style): status line, mic/model in use, toggles for
  each hotkey feature, "Open Settings…", "Check permissions…", Quit. App is `LSUIElement`.
- **Recording HUD** — small floating `NSPanel` (non-activating, all spaces, top-center of
  the screen with the mouse) with a level meter, elapsed time, state label and the
  cancel hint; also used for transient toasts (errors, "Copied", "Nothing selected").
- **Quick Panel** — fixed-position floating `NSPanel` (top-center, 680×420, remembered
  per screen), non-activating until the user clicks into it, Esc closes, stays open
  while streaming. Two layouts: *refine* (Original | Refined side-by-side, each an
  editable `TextEditor`, per-side Copy/Insert buttons, preset picker + instruction
  field on top) and *summary* (single pane + preset picker). Streaming indicator,
  stop button, error banner with recovery text.
- **Settings** (`Settings` scene, tabs): General (launch at login, dictation mode, insert
  method), Hotkeys (KeyboardShortcuts recorders), Dictation (source: local model picker
  w/ download status, or endpoint + model; language auto/fixed), Speech (voice grouped
  by language, rate/pitch/volume sliders, preview), Refine & Summarize (endpoint+model
  per feature, preset manager per §3.6), Providers (endpoint list: add/edit/test connection,
  Keychain-backed API key field, Ollama "Pull model" button), Models (whisper catalog,
  download/delete, disk usage).
- **Onboarding** — first launch window: Microphone, Accessibility (required for selected
  text + paste), optional model download, optional Ollama detection.
- Icons: Phosphor via `Components/Icon.swift` wrapper; SF Symbol for the status item.
  Colors: semantic (`accent` for active recording, orange warnings, red errors),
  `.thinMaterial` panels, monospaced digits for timers.

## 4. Key flows

**Dictate**: hotkey ↓ → `FrontmostAppTracker.capture()` → `AudioRecorder.start()` → HUD.
hotkey ↑ / toggle → `stop()` → `TranscriptionProvider.transcribe` → trim → if empty:
toast; else `TextInserter.insert(text, into: rememberedApp)` → HUD ✓ (auto-hide 1.2 s).

**Dictate & Refine**: as above through transcription, then Quick Panel opens with
Original filled, Refined streaming. User edits/re-runs, then Copy or Insert; Insert
re-activates the remembered app and pastes. Panel closes after Insert; stays after Copy.

**Speak / Summarize / Refine selection**: `SelectedTextService.read()` (AX → ⌘C
fallback) → if empty: toast `noSelection` → else dispatch to controller.

**Model download**: Settings/onboarding → `ModelManager.download(id)` → progress →
SHA-256 verify → atomic move → `WhisperCppTranscriber` reloads on next use.

## 5. Error handling & safety

- Every failure becomes a `MacomprendoError` with recovery text surfaced in the HUD or
  panel; nothing fails silently. Provider errors include the endpoint name and HTTP
  status; unreachable Ollama suggests "Start Ollama or choose another endpoint".
- Pasteboard is always restored after simulated ⌘C/⌘V (deferred 300 ms, guarded by a
  change-count check so user copies in between are not clobbered).
- Permission-denied states are detected before starting an action and open the
  relevant System Settings pane.
- Secrets: API keys only in Keychain; never in logs, settings export, or crash text.
- Concurrency: providers are `Sendable` actors/structs; controllers are `@MainActor`;
  one in-flight action per controller, new hotkey press cancels the previous task.

## 6. Testing (TDD)

swift-testing, `swift test --package-path macos`, CI-enforced. Unit coverage targets:

- `Settings` round-trip + migration; `Endpoint` seeding; `KeychainStore` with in-memory fake.
- `SSEParser`, `NDJSONParser` against fixture byte chunks split at arbitrary boundaries.
- Provider request building & response decoding via stubbed `HTTPClient`
  (`/api/tags`, `/api/chat`, `/v1/models`, `/v1/chat/completions`, `/v1/audio/transcriptions`, `/api/pull`).
- `WAVEncoder` (PCM → WAV header) byte-exact.
- Controllers' state machines with fakes for recorder / transcriber / inserter /
  selected-text / speech (including cancellation and error paths).
- `PasteTextInserter` pasteboard restore logic with a `PasteboardProtocol` fake.
- `ModelCatalog` + download state machine with `URLProtocol` stub (progress, SHA
  mismatch, resume).
- `PromptRenderer` rendering/validation; `FactoryPresets` seeding, restore-missing, last-preset deletion guard.

Hardware-bound code (AVAudioEngine, AX, CGEvent, KeyboardShortcuts, whisper C calls) is
kept thin and covered by `docs/SMOKE_TEST.md`, a manual checklist run before release.

## 7. Build, CI, release

All tooling scripts are **Node.js ≥ 20 ES modules (`.mjs`)**. Prefer `node:` built-ins
(`child_process`, `fs/promises`, `path`, `crypto`, `util.parseArgs`); add npm
dependencies (e.g. `execa`, `yaml`, `picocolors`) when they clearly simplify the code —
pinned in `package.json` with a committed `package-lock.json`, `npm ci` in CI.
Ported from mac-dev-clean's shell/Python logic: `build-app.mjs` (swift build per arch →
lipo → assemble bundle → PlistBuddy version → codesign), `notarize-app.mjs` (identity
discovery, notarytool submit/staple/validate, zip + sha256), `configure-notarization.mjs`,
`release.mjs` (version bump in `project.yml`, pbxproj, `CHANGELOG.md`; tests; tag;
`gh release`), `audit-public-repo.mjs`, `sync-agent-config.mjs`. Shared helpers in
`scripts/lib/` (`run.mjs` for spawning with logging, `version.mjs`, `log.mjs`).
`package.json` exposes them as `npm run build|notarize|release|audit|sync-agents|test:scripts`.
Scripts are unit-tested with `node:test` in `scripts/__tests__/` (process spawning
injected/mocked). CI: `npm run test:scripts`, `swift test`, unsigned `xcodebuild`,
audit, symlink check.
Identity: bundle id `com.dzamataev.macomprendo`, `DEVELOPMENT_TEAM 68QJJA7HK9`,
copyright "© 2026 Denis Zamataev", MIT license. Placeholder app icon until final art
is supplied. Release prerequisite (documented in `DISTRIBUTING.md`): a "Developer ID
Application" certificate for team 68QJJA7HK9 must be installed — currently only an
Apple Development certificate exists, which is sufficient for local dev builds.
Default whisper model offered at onboarding: `large-v3-turbo`, with `base` as the
lightweight alternative.

## 8. AI-driven development setup

- `AGENTS.md` (single source; `CLAUDE.md` symlinks to it): project map, commands,
  invariants (pasteboard restore, no secrets in logs, protocol-injected services,
  TDD), how-to recipes pointing to skills, definition of done, planning convention
  (specs in `docs/superpowers/specs`, plans in `docs/superpowers/plans`, ADRs in
  `docs/DECISIONS`).
- Skills (single source `.agents/skills/`, symlinked into `.claude/skills/`):
  `macomprendo-architecture`, `macomprendo-build-test`, `macomprendo-add-provider`,
  `macomprendo-add-hotkey-feature`, `macomprendo-release`, `macomprendo-scripts` (Node script conventions).
- Claude-specific: `.claude/agents/planner.md` (model: opus), `swift-implementer.md`,
  `reviewer.md` (model: opus); `.claude/settings.json` permission allowlist for
  `swift build/test`, `xcodegen`, `xcodebuild`, `node scripts/*.mjs`, `npm run *`.
- `scripts/sync-agent-config.mjs` creates/validates symlinks; CI fails if they drift.

## 9. Decisions (to be recorded as ADRs)

1. Ollama + OpenAI-compatible endpoints instead of bundled llama.cpp — keeps the app
   small; Ollama is already the de-facto local runtime.
2. whisper.cpp in-process by default; remote STT via the OpenAI audio endpoint —
   Ollama has no STT API today; if it adds `/v1/audio/transcriptions` it works unchanged.
3. Not sandboxed — required for global hotkeys, AX selection, and paste simulation.
4. KeyboardShortcuts over hand-rolled Carbon hotkeys — recorder UI + conflict handling for free.
5. Phosphor Icons for UI (vendored SVGs from `@phosphor-icons/core`; the SwiftPM package is unusable with `swift build`), SF Symbols for the status item — template-image requirement.
6. Quick Panel at a fixed top-center position — predictable, matches MacWhisper/ChatGPT quick chat.
