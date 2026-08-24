# Macomprendo — File Map & Interface Contracts (shared by all plans)

Spec: `docs/superpowers/specs/2026-08-23-macomprendo-design.md`. All plans implement
that spec. This document fixes file locations and the exact Swift/JS signatures that
cross plan boundaries. Implementers MUST use these names verbatim.

> **Read [Amendments (final)](#amendments-final) at the bottom of this file before you start.**
> Plans 1–5 deviated from a handful of the declarations below; the amendments record the
> agreed final shape and take precedence over anything above them.

## Plans (execute in order)

| # | Plan file | Delivers |
|---|-----------|----------|
| 1 | `2026-08-23-01-foundation.md` | Repo scaffold, XcodeGen/SwiftPM project, Core layer, Node tooling skeleton, CI, agent-agnostic AI setup. A menubar app that builds, runs, and persists settings. |
| 2 | `2026-08-23-02-providers.md` | HTTP client, stream parsers, Ollama/OpenAI LLM providers, WAV encoder, OpenAI transcriber, whisper.cpp transcriber, whisper model manager. Fully unit-tested, no UI. |
| 3 | `2026-08-23-03-dictation.md` | Hotkeys, audio recorder, permissions, frontmost tracker, text inserter, Recording HUD, DictationController, Onboarding, Settings tabs General/Hotkeys/Dictation/Models/Providers. Hotkey #1 works end-to-end. |
| 4 | `2026-08-23-04-text-features.md` | Selected-text service, speech service, prompt presets, Quick Panel, Refine/Summarize/Speak controllers, Settings tabs Speech + Refine & Summarize. Hotkeys #2–#5 work. |
| 5 | `2026-08-23-05-release-tooling.md` | Node scripts build/notarize/configure/release/audit, DISTRIBUTING.md, SMOKE_TEST.md, ADRs, CHANGELOG, final CI. |

## Global constraints (from spec)

- Swift 6.0, strict concurrency; SwiftUI + AppKit; `platforms: [.macOS(.v14)]`; universal (arm64 + x86_64).
- Bundle id `com.dzamataev.macomprendo`; `DEVELOPMENT_TEAM 68QJJA7HK9`; copyright "© 2026 Denis Zamataev"; MIT.
- Product/module name `Macomprendo`; executable `Macomprendo`; `LSUIElement = true`; not sandboxed; hardened runtime.
- SPM deps ONLY: whisper.cpp as a prebuilt xcframework via local package `macos/Packages/WhisperBinary` (product `Whisper`, module `whisper`; upstream has no Package.swift), `https://github.com/sindresorhus/KeyboardShortcuts` (from 2.0.0). Icons: Phosphor SVGs vendored from npm `@phosphor-icons/core` via `scripts/sync-icons.mjs` — the `phosphor-icons/swift` package is NOT used (breaks `swift build`).
- Tests: swift-testing (`import Testing`), `swift test --package-path macos`. Node: `node --test` in `scripts/__tests__/`.
- Tooling: Node ≥ 20 ESM `.mjs`; npm deps allowed (pinned, lockfile committed). No shell scripts.
- No telemetry. API keys only in Keychain. Never log transcript/LLM text at default level.
- XcodeGen `macos/project.yml` is the source of truth; regenerate with `xcodegen generate --spec macos/project.yml` (install via `brew install xcodegen`); commit the generated `.xcodeproj`.

## Repository layout

```
macomprendo/
  AGENTS.md                      CLAUDE.md -> AGENTS.md
  .agents/skills/macomprendo-{architecture,build-test,add-provider,add-hotkey-feature,release,scripts}/SKILL.md
  .claude/skills -> ../.agents/skills      .claude/agents/{planner,swift-implementer,reviewer}.md   .claude/settings.json
  .github/workflows/ci.yml       .gitignore   LICENSE   README.md   CHANGELOG.md   DISTRIBUTING.md   PRIVACY.md
  package.json  package-lock.json
  scripts/{build-app,notarize-app,configure-notarization,release,audit-public-repo,sync-agent-config}.mjs
  scripts/lib/{run.mjs,log.mjs,version.mjs,fs.mjs}     scripts/__tests__/*.test.mjs
  docs/ARCHITECTURE.md  docs/SMOKE_TEST.md  docs/DECISIONS/ADR-000N-*.md  docs/superpowers/{specs,plans}/
  macos/project.yml  macos/Package.swift  macos/Macomprendo.xcodeproj/
  macos/AppBundle/{Info.plist,AppIcon.icns,Macomprendo.entitlements}
  macos/Sources/Macomprendo/...   macos/Tests/MacomprendoTests/...
```

### `macos/Sources/Macomprendo/`

```
App/        MacomprendoApp.swift, AppModel.swift, AppEnvironment.swift
Core/       Settings.swift, SettingsStore.swift, Endpoint.swift, KeychainStore.swift,
            MacomprendoError.swift, Log.swift, Pasteboard.swift
Services/   HotkeyService.swift, AudioRecorder.swift, FrontmostAppTracker.swift, TextInserter.swift,
            SelectedTextService.swift, SpeechService.swift, ModelManager.swift, ModelCatalog.swift,
            PermissionsService.swift
Providers/  HTTPClient.swift, TranscriptionProvider.swift, WhisperCppTranscriber.swift,
            OpenAICompatibleTranscriber.swift, LLMProvider.swift, OllamaProvider.swift,
            OpenAICompatibleLLMProvider.swift, ProviderFactory.swift, WAVEncoder.swift,
            Streaming/SSEParser.swift, Streaming/NDJSONParser.swift, Streaming/LineSplitter.swift
Features/   DictationController.swift, RefineController.swift, SummarizeController.swift,
            SpeakController.swift, Prompts/PromptPreset.swift, Prompts/FactoryPresets.swift,
            Prompts/PromptRenderer.swift
UI/         MenuBar/MenuBarView.swift
            Settings/SettingsView.swift, Settings/GeneralTab.swift, Settings/HotkeysTab.swift,
            Settings/DictationTab.swift, Settings/SpeechTab.swift, Settings/PromptsTab.swift,
            Settings/ProvidersTab.swift, Settings/ModelsTab.swift
            QuickPanel/QuickPanelController.swift, QuickPanel/QuickPanelView.swift,
            QuickPanel/RefineLayout.swift, QuickPanel/SummaryLayout.swift
            RecordingHUD/HUDController.swift, RecordingHUD/HUDView.swift
            Onboarding/OnboardingView.swift
            Components/Icon.swift, Components/FloatingPanel.swift, Components/LevelMeter.swift
```

Tests mirror this: `macos/Tests/MacomprendoTests/<Layer>/<Name>Tests.swift`, fakes in
`macos/Tests/MacomprendoTests/Fakes/`.

## Core contracts (Plan 1 produces; everyone consumes)

```swift
// Core/Endpoint.swift
enum EndpointKind: String, Codable, Sendable, CaseIterable { case ollama, openAICompatible }
struct Endpoint: Codable, Sendable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var kind: EndpointKind
    var baseURL: URL                 // e.g. http://localhost:11434 or https://api.openai.com
    var apiKeyRef: String?           // Keychain account name; nil = no key
    static func ollamaLocal() -> Endpoint   // id fixed: UUID(uuidString: "00000000-0000-0000-0000-00000000A11A")!
}

// Core/Settings.swift
enum DictationMode: String, Codable, Sendable { case hold, toggle }
enum InsertMethod: String, Codable, Sendable { case auto, paste, typing }
enum TranscriptionSource: Codable, Sendable, Equatable {
    case local(modelID: String)                     // whisper ggml model id, e.g. "large-v3-turbo"
    case endpoint(id: UUID, model: String)          // OpenAI-compatible audio endpoint
}
struct LLMSelection: Codable, Sendable, Equatable { var endpointID: UUID; var model: String }
struct SpeechSettings: Codable, Sendable, Equatable { var voiceID: String?; var rate: Float; var pitch: Float; var volume: Float }  // defaults 0.5 / 1.0 / 1.0
struct Settings: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int
    var dictationMode: DictationMode
    var insertMethod: InsertMethod
    var launchAtLogin: Bool
    var transcriptionSource: TranscriptionSource
    var transcriptionLanguage: String?             // nil = auto
    var endpoints: [Endpoint]
    var refineLLM: LLMSelection?
    var summarizeLLM: LLMSelection?
    var speech: SpeechSettings
    var presets: [PromptPreset]                    // defined in Plan 4; Plan 1 declares the type stub below
    var presetsSeeded: Bool
    var defaultRefinePresetID: UUID?
    var defaultSummarizePresetID: UUID?
    var quickPanelFrames: [String: CGRect]         // key: screen identifier
    static var `default`: Settings                 // endpoints = [Endpoint.ollamaLocal()], refineLLM/summarizeLLM = (ollama, "qwen2.5:1.5b")
    static func migrate(_ json: Data) throws -> Settings
}

// Features/Prompts/PromptPreset.swift  (type lives here; Plan 1 creates file with the struct only, Plan 4 adds behaviour)
enum PresetKind: String, Codable, Sendable, CaseIterable { case refine, summarize }
struct PromptPreset: Codable, Sendable, Identifiable, Equatable {
    var id: UUID; var kind: PresetKind; var name: String
    var systemPrompt: String; var userTemplate: String   // userTemplate must contain "{text}"
    var isFactory: Bool; var sortOrder: Int
}

// Core/SettingsStore.swift
protocol SettingsPersisting: AnyObject, Sendable { func load() -> Data?; func save(_ data: Data) }
final class UserDefaultsSettingsStore: SettingsPersisting { init(defaults: UserDefaults = .standard, key: String = "settings.v1") }
final class InMemorySettingsStore: SettingsPersisting

// Core/KeychainStore.swift
protocol KeychainStoring: Sendable {
    func set(_ secret: String, account: String) throws
    func get(account: String) throws -> String?
    func delete(account: String) throws
}
struct SystemKeychainStore: KeychainStoring { init(service: String = "com.dzamataev.macomprendo") }
final class InMemoryKeychainStore: KeychainStoring   // thread-safe via lock

// Core/MacomprendoError.swift
enum PermissionKind: String, Sendable { case microphone, accessibility }
enum MacomprendoError: Error, LocalizedError, Equatable, Sendable {
    case permissionDenied(PermissionKind)
    case modelMissing(String)
    case modelDownloadFailed(String)
    case providerUnreachable(endpointName: String)
    case providerHTTP(status: Int, body: String)
    case providerStreamMalformed
    case audio(String)
    case noSelection
    case insertFailed
    case cancelled
    var errorDescription: String? { get }   // user-facing
    var recoverySuggestion: String? { get }
}

// Core/Log.swift
enum Log { static let app, audio, providers, hotkeys, ui: os.Logger }   // subsystem "com.dzamataev.macomprendo"

// Core/Pasteboard.swift
protocol PasteboardProtocol: AnyObject, Sendable {   // Sendable: Sendable structs hold one
    var changeCount: Int { get }
    func readString() -> String?
    func writeString(_ s: String)
    func snapshot() -> PasteboardSnapshot
    func restore(_ snapshot: PasteboardSnapshot)
}
struct PasteboardSnapshot: Sendable { var items: [[String: Data]] }  // type identifier -> data
final class SystemPasteboard: PasteboardProtocol, @unchecked Sendable   // wraps NSPasteboard.general
final class FakePasteboard: PasteboardProtocol, @unchecked Sendable     // in Tests/Fakes

// App/AppModel.swift (Plan 1 creates with settings only; later plans add controllers)
@MainActor final class AppModel: ObservableObject {
    @Published var settings: Settings { didSet { persist } }
    let keychain: any KeychainStoring
    init(store: any SettingsPersisting, keychain: any KeychainStoring)
}
// App/AppEnvironment.swift — composition root: builds real services; `static func live() -> AppEnvironment`
```

## Provider contracts (Plan 2 produces; Plans 3–4 consume)

```swift
// Providers/HTTPClient.swift
struct HTTPRequest: Sendable { var method: String; var url: URL; var headers: [String: String]; var body: Data?; var timeout: TimeInterval }
struct HTTPResponse: Sendable { var status: Int; var headers: [String: String]; var body: Data }
protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
    func stream(_ request: HTTPRequest) -> AsyncThrowingStream<Data, Error>   // raw chunks; throws providerHTTP on non-2xx before first chunk
}
struct URLSessionHTTPClient: HTTPClient { init(session: URLSession = .shared) }
// Tests/Fakes/StubHTTPClient.swift: records requests; scripted responses/chunks per URL path.

// Providers/Streaming
struct LineSplitter { mutating func feed(_ data: Data) -> [String]; mutating func flush() -> String? }   // handles chunk boundaries, \n and \r\n
struct SSEParser  { mutating func feed(_ data: Data) -> [SSEEvent]; mutating func finish() -> [SSEEvent] }  struct SSEEvent: Equatable { var event: String?; var data: String }   // "data: [DONE]" => SSEEvent(data:"[DONE]")
struct NDJSONParser { mutating func feed(_ data: Data) -> [Data]; mutating func finish() -> [Data] }   // one JSON object per element

// Providers/LLMProvider.swift
enum ChatRole: String, Codable, Sendable { case system, user, assistant }
struct ChatMessage: Codable, Sendable, Equatable { var role: ChatRole; var content: String }
struct ChatOptions: Sendable, Equatable { var temperature: Double = 0.3; var maxTokens: Int? = nil }
protocol LLMProvider: Sendable {
    var endpoint: Endpoint { get }
    func listModels() async throws -> [String]
    func chat(_ messages: [ChatMessage], model: String, options: ChatOptions) -> AsyncThrowingStream<String, Error>  // yields text deltas
}
struct OllamaProvider: LLMProvider { init(endpoint: Endpoint, http: any HTTPClient); func pull(model: String) -> AsyncThrowingStream<PullProgress, Error> }
struct PullProgress: Sendable, Equatable { var status: String; var completed: Int64?; var total: Int64? }
struct OpenAICompatibleLLMProvider: LLMProvider { init(endpoint: Endpoint, apiKey: String?, http: any HTTPClient) }

// Providers/TranscriptionProvider.swift
protocol TranscriptionProvider: Sendable {
    func transcribe(_ pcm: [Float], sampleRate: Int, language: String?) async throws -> String
}
struct OpenAICompatibleTranscriber: TranscriptionProvider { init(endpoint: Endpoint, apiKey: String?, model: String, http: any HTTPClient) }
actor WhisperCppTranscriber: TranscriptionProvider { init(modelURL: URL) }   // loads lazily on first transcribe; whisper_full with Metal
enum WAVEncoder { static func encode(pcm: [Float], sampleRate: Int) -> Data }   // 16-bit PCM mono

// Providers/ProviderFactory.swift
struct ProviderFactory: Sendable {
    init(http: any HTTPClient, keychain: any KeychainStoring)
    func llm(for endpoint: Endpoint) throws -> any LLMProvider
    func transcriber(for source: TranscriptionSource, endpoints: [Endpoint], models: any ModelManaging) async throws -> any TranscriptionProvider   // async: awaits ModelManaging.localURL
}

// Services/ModelCatalog.swift + ModelManager.swift
struct WhisperModel: Identifiable, Sendable, Equatable { let id: String; let displayName: String; let fileName: String; let sizeBytes: Int64; let sha256: String; let downloadURL: URL }
enum ModelCatalog { static let all: [WhisperModel]; static let defaultID = "large-v3-turbo"; static let lightweightID = "base" }
enum ModelState: Sendable, Equatable { case notDownloaded, downloading(fraction: Double), downloaded(URL), failed(String) }
protocol ModelManaging: AnyObject, Sendable {
    func state(of id: String) async -> ModelState
    func localURL(for id: String) async -> URL?
    func download(_ id: String) -> AsyncThrowingStream<Double, Error>   // fraction 0...1; verifies sha256; atomic move
    func delete(_ id: String) async throws
    var modelsDirectory: URL { get }
}
actor WhisperModelManager: ModelManaging { init(directory: URL, http: any HTTPClient) }
```

## Service contracts (Plan 3 produces most; Plan 4 adds SelectedText + Speech)

```swift
// Services/HotkeyService.swift
enum HotkeyAction: String, CaseIterable, Sendable { case dictate, dictateAndRefine, speak, summarize, refineSelection }
enum HotkeyEvent: Sendable, Equatable { case keyDown(HotkeyAction), keyUp(HotkeyAction) }
protocol HotkeyServicing: AnyObject { var events: AsyncStream<HotkeyEvent> { get }; func setEnabled(_ action: HotkeyAction, _ enabled: Bool) }
final class KeyboardShortcutsHotkeyService: HotkeyServicing     // KeyboardShortcuts.Name.dictate etc., defaults ⌥Space, ⌥⇧Space, ⌥S, ⌥M, none

// Services/AudioRecorder.swift
protocol AudioRecording: AnyObject, Sendable {
    var level: AsyncStream<Float> { get }                      // RMS 0...1
    func start() async throws
    func stop() async -> [Float]                               // 16 kHz mono Float32
    var isRecording: Bool { get async }
}
final class AVAudioEngineRecorder: AudioRecording { init(maxDuration: TimeInterval = 300) }

// Services/FrontmostAppTracker.swift
struct FrontmostApp: Sendable, Equatable { var pid: pid_t; var bundleID: String?; var name: String }
protocol FrontmostAppTracking: Sendable { func capture() -> FrontmostApp?; func activate(_ app: FrontmostApp) async -> Bool }
struct NSWorkspaceTracker: FrontmostAppTracking

// Services/TextInserter.swift
protocol TextInserting: Sendable { func insert(_ text: String, into app: FrontmostApp?, method: InsertMethod) async throws }   // throws insertFailed
struct PasteTextInserter: TextInserting { init(pasteboard: any PasteboardProtocol, tracker: any FrontmostAppTracking, keySimulator: any KeySimulating, restoreDelay: TimeInterval = 0.3) }
protocol KeySimulating: Sendable { func pressCommand(_ key: Character) async }   // CGEvent ⌘V / ⌘C
struct CGEventKeySimulator: KeySimulating

// Services/PermissionsService.swift
enum PermissionStatus: Sendable, Equatable { case granted, denied, undetermined }
protocol PermissionsChecking: Sendable {
    func status(of kind: PermissionKind) async -> PermissionStatus
    func request(_ kind: PermissionKind) async -> PermissionStatus
    func openSystemSettings(for kind: PermissionKind)
}
struct SystemPermissions: PermissionsChecking

// Services/SelectedTextService.swift (Plan 4)
protocol SelectedTextReading: Sendable { func read() async throws -> String }   // throws noSelection when empty
struct AXSelectedTextService: SelectedTextReading { init(ax: any AXReading, pasteboard: any PasteboardProtocol, keySimulator: any KeySimulating) }
protocol AXReading: Sendable { func focusedSelectedText() -> String? }
struct SystemAXReader: AXReading

// Services/SpeechService.swift (Plan 4)
struct Voice: Identifiable, Sendable, Equatable { let id: String; let name: String; let language: String; let quality: String }
protocol SpeechSynthesizing: AnyObject { var isSpeaking: Bool { get }; func voices() -> [Voice]; func speak(_ text: String, settings: SpeechSettings); func stop() }
final class AVSpeechService: SpeechSynthesizing

// UI/RecordingHUD/HUDController.swift (Plan 3)
enum HUDState: Equatable { case hidden, recording(level: Float, elapsed: TimeInterval), transcribing, success(String), error(String), toast(String) }
@MainActor final class HUDController: ObservableObject { @Published var state: HUDState; func show(_ s: HUDState); func toast(_ msg: String, duration: TimeInterval = 1.2) }

// UI/QuickPanel/QuickPanelController.swift (Plan 4)
enum QuickPanelLayout { case refine, summary }
@MainActor final class QuickPanelController: ObservableObject { func present(layout: QuickPanelLayout, on screen: NSScreen?); func dismiss() }
```

## Feature controller contracts

```swift
// Features/DictationController.swift (Plan 3)
enum DictationState: Equatable { case idle, recording, transcribing, inserting, failed(String) }
@MainActor final class DictationController: ObservableObject {
    @Published private(set) var state: DictationState
    init(recorder: any AudioRecording, transcriberProvider: @escaping @Sendable () async throws -> any TranscriptionProvider,
         inserter: any TextInserting, tracker: any FrontmostAppTracking, permissions: any PermissionsChecking,
         hud: HUDController, settings: @escaping @MainActor () -> Settings)
    func handle(_ event: HotkeyEvent)      // hold/toggle logic
    func cancel()
}

// Features/RefineController.swift (Plan 4)
enum RefineSource: Equatable { case dictation, selection(String) }
@MainActor final class RefineController: ObservableObject {
    @Published var original: String; @Published var refined: String; @Published var isStreaming: Bool
    @Published var selectedPresetID: UUID?; @Published var instruction: String; @Published var error: String?
    func start(source: RefineSource)      // for .dictation uses same recorder flow as DictationController
    func rerun(); func stop()
    func copy(_ side: RefineSide); func insert(_ side: RefineSide) async
}
enum RefineSide { case original, refined }

// Features/SummarizeController.swift (Plan 4)
@MainActor final class SummarizeController: ObservableObject {
    @Published var source: String; @Published var summary: String; @Published var isStreaming: Bool; @Published var error: String?
    func start(text: String); func rerun(); func stop(); func copy(); func replaceSelection() async
}

// Features/SpeakController.swift (Plan 4)
@MainActor final class SpeakController: ObservableObject { func toggle(text: () async throws -> String) async }

// Features/Prompts/PromptRenderer.swift (Plan 4)
struct RenderedPrompt: Equatable { var messages: [ChatMessage] }
enum PromptRenderer {
    static func validate(_ preset: PromptPreset) -> [String]                // list of problems; empty = ok
    static func render(_ preset: PromptPreset, text: String, instruction: String?, language: String?) -> RenderedPrompt
}
enum FactoryPresets { static func all() -> [PromptPreset]; static func seed(into s: inout Settings); static func restoreMissing(into s: inout Settings) }
```

## Node tooling contracts (Plan 1 skeleton, Plan 5 full)

```js
// scripts/lib/run.mjs
export async function run(cmd, args, { cwd, env, capture = false, dryRun = false, log = console } = {})  // -> { stdout, stderr, code }; throws on non-zero unless { check:false }
// scripts/lib/log.mjs
export const log = { info(msg), warn(msg), error(msg), step(msg) }      // picocolors allowed
// scripts/lib/version.mjs
export function readVersion(projectYmlText)                  // MARKETING_VERSION
export function bumpVersion(version, part /* 'patch'|'minor'|'major'|'X.Y.Z' */)
export function replaceVersion(text, from, to)              // used for project.yml, pbxproj, CHANGELOG
// scripts/lib/fs.mjs
export async function ensureSymlink(target, linkPath)       // idempotent; returns 'created'|'ok'|'fixed'
export async function sha256(filePath)
// package.json scripts: build, notarize, release, audit, sync-agents, test:scripts, test:swift, gen  (gen = xcodegen generate --spec macos/project.yml)
```

---

# Amendments (final)

**This section plus everything above is the authoritative contract.** Where an amendment
contradicts the declaration earlier in this file, the amendment wins. Each plan also lists its
own additions near its end ("Interface additions beyond the shared map"); those lists are
normative too — this section records only the items that cross a plan boundary or that *change*
a declaration made above.

## Plan 1 — Foundation

- `PasteboardProtocol` is `AnyObject, Sendable` (not just `AnyObject`); `SystemPasteboard` and
  `FakePasteboard` are `@unchecked Sendable`. Required because Plan 3's `PasteTextInserter` and
  Plan 4's `AXSelectedTextService` are `Sendable` structs holding `any PasteboardProtocol`.
- `PasteboardSnapshot` is `Sendable, Equatable` with `init(items: [[String: Data]] = [])`.
- `Endpoint` gains `static let ollamaLocalID: UUID` and a memberwise
  `init(id: UUID = UUID(), name:, kind:, baseURL:, apiKeyRef: String? = nil)`.
- `SpeechSettings` memberwise init defaults: `voiceID: nil, rate: 0.5, pitch: 1.0, volume: 1.0`.
- New error types: `SettingsMigrationError.unsupportedSchemaVersion(Int)`,
  `KeychainError.{unexpectedStatus(OSStatus), malformedData}`.
- `InMemorySettingsStore.init(initial: Data? = nil)`.
- `Log` gains `static let subsystem = "com.dzamataev.macomprendo"`.
- **Icon seam** (new, not in the map above): `UI/Components/ResourceBundle.swift`
  (`enum ResourceBundle { static var current: Bundle }`) and `UI/Components/Icon.swift` with
  `enum AppIcon: String, CaseIterable` + `var fallbackSymbol: String` +
  `func resourceURL(in bundle: Bundle = ResourceBundle.current) -> URL?`, and
  `struct Icon: View { init(_ icon: AppIcon, size: CGFloat = 16) }` plus
  `static func nsImage(for: AppIcon, size: CGFloat) -> NSImage?`.
  `AppIcon` **case names are semantic; raw values are the SVG file names**:
  `microphone`, `microphoneFill` (`microphone-fill`), `waveform`, `speak` (`speaker-high`),
  `stop`, `play`, `refine` (`sparkle`), `summarize` (`text-aa`), `clipboard` (`clipboard-text`),
  `insert` (`arrow-square-in`), `copy`, `settings` (`gear`), `hotkeys` (`keyboard`),
  `download` (`download-simple`), `delete` (`trash`), `success` (`check-circle`),
  `warning` (`warning-circle`), `close` (`x`), `add` (`plus`), `remove` (`minus`),
  `refresh` (`arrows-clockwise`), `endpoint` (`cloud`), `model` (`cpu`),
  `presets` (`list-bullets`), `magic` (`magic-wand`).
  Never `import PhosphorSwift`; never `Image(systemName:)` in a view (the `MenuBarExtra` status
  item is the single deliberate SF-Symbol exception).
- `AppModel`/`AppEnvironment` as declared above are **Plan 1 only**; Plan 3 replaces both files
  wholesale (see below).
- Node: `scripts/sync-icons.mjs` and `scripts/make-placeholder-icon.mjs` are Plan 1's, and
  `run(cmd, args, opts)` accepts `check` in addition to the options listed above.

## Plan 2 — Providers

- `ProviderFactory.transcriber(for:endpoints:models:)` is **`async throws`** (it awaits
  `ModelManaging.localURL(for:)`). This is why `DictationController.transcriberProvider` is
  `@escaping @Sendable () async throws -> any TranscriptionProvider` everywhere.
- `SSEParser.finish() -> [SSEEvent]` and `NDJSONParser.finish() -> [Data]` added.
- New internal type `Providers/EndpointURL.swift`: `join(_:_:)`, `openAI(_:_:)`.
- `HTTPRequest` gains a defaulted memberwise init (`method: "GET"`, `headers: [:]`, `body: nil`,
  `timeout: 10`); `HTTPResponse` gains a defaulted init and `func header(_ name: String) -> String?`.
- `ChatOptions` gains `static let default`.
- `ModelCatalog.model(id:) -> WhisperModel?`; `WhisperModelManager.init(directory:http:catalog:)`
  and `static func sha256(of:) throws -> String`.
- `OpenAICompatibleTranscriber` gains an internal `init(...,boundary:)` and
  `static func multipartBody(boundary:fileName:fileType:fileData:fields:) -> Data`.
- `WhisperCppTranscriber.swift` also declares `WhisperParams` and `WhisperTextAssembler`.
- Test doubles: `Fakes/StubURLProtocol.swift`, `Fakes/FakeModelManager.swift`.
- **`scripts/fetch-model-hashes.mjs` and its npm script `fetch-model-hashes` belong to Plan 2**,
  not Plan 5.

## Plan 3 — Dictation

- `App/AppEnvironment.swift` is rewritten: `struct AppEnvironment` no longer has `model`. It holds
  `hotkeys, recorder, inserter, tracker, permissions, models, http, keychain, factory,
  hudPresenter, ollamaDetector` and exposes `@MainActor static func live() -> AppEnvironment`.
  A test-only `AppEnvironment.fake(...)` lives in `Tests/MacomprendoTests/Fakes/`.
- `App/AppModel.swift` is rewritten:
  `init(store:keychain:env:hotkeyDefaults: UserDefaults = .standard)` (Plan 1's
  `init(store:keychain:)` is gone), plus `env`, `hud`, `dictation`, `transcriberProvider`,
  `start()`, `route(_:)`, `isEnabled(_:)`, `setEnabled(_:_:)`, `statusText`,
  `lazy var modelsViewModel`, `lazy var providersViewModel`. `SettingsSnapshot` lives in the same
  file. The app entry point moves to `@MainActor enum AppRoot { static let model: AppModel }` +
  `AppDelegate` in `App/MacomprendoApp.swift`.
- `KeySimulating` gains `func type(_ text: String) async` (for `InsertMethod.typing`).
- `HotkeyServicing`'s default impl `KeyboardShortcutsHotkeyService` has a `@MainActor init()`;
  `KeyboardShortcuts.Name` constants must be `@MainActor`.
- `HUDState` is `Equatable, Sendable`. `HUDController` becomes
  `init(presenter: (any HUDPresenting)? = nil, sleep: @escaping @Sendable (TimeInterval) async -> Void = …)`
  with `@Published private(set) var state`, `show(_:)`, `toast(_:duration:)`, `hide()`,
  `hideTask`, `static func autoHideDuration(for:)`. New `@MainActor protocol HUDPresenting`.
- `Core/ErrorText.swift` (new): `enum ErrorText { static func describe(_ error: Error) -> String }`.
- Everything else in Plan 3's own "Interface additions beyond the shared map" table applies
  (`AudioMath`, `PCMResampler`, `PrivacyPane`, `ActivationPoller`, `HotkeyEnablementStore`,
  `HUDLayout`, `HUDWindowPresenter`, `LevelMeterModel`, `ModelsViewModel`,
  `TranscriptionLanguages`, `LaunchAtLogin`, `ProvidersViewModel`, `ModelPulling`,
  `Endpoint.keychainAccount(for:)` = `"endpoint.<uuid>"`, `OllamaDetecting`,
  `HTTPOllamaDetector`, `OnboardingViewModel`, `OnboardingWindowController`).

## Plan 4 — Text features

- `SpeechSynthesizing` is a **`@MainActor` protocol** and gains
  `var onStateChange: (@MainActor () -> Void)? { get set }`.
- `AXSelectedTextService.init(ax:pasteboard:keySimulator:copyTimeout:pollInterval:)`
  (the last two have defaults).
- `QuickPanelController.init(holder: any SettingsHolding)` plus `attach(_:)`,
  `@Published private(set) var layout / isVisible`, `static let panelSize` (680 × 420),
  `static let topInset`, `screenKey(name:frame:)`, `defaultFrame(inScreenFrame:)`, a second
  `present(layout:screenName:screenFrame:)` overload, and `dismiss()`. New
  `@MainActor protocol QuickPanelHosting` and `FloatingPanelHost<Content: View>`.
- `RefineController` / `SummarizeController` keep every method listed above and add
  `handle(_:)` (refine only), `selectedPresetID`/`instruction` (summarize), `isCapturing`
  (refine) and `drain() async`; both are constructed with
  `(capture:)llm:panel:pasteboard:inserter:tracker:toaster:settings:`.
- New shared types: `Toasting` (`extension HUDController: Toasting {}`), `LLMTarget`,
  `FeatureConfigError`, `SettingsHolding` (`extension AppModel: SettingsHolding {}`),
  `DictationCapture`, `PresetError`, `PromptRenderer.placeholders(in:)`,
  `FactoryPresets.ID.*` fixed UUIDs, `Settings` preset helpers, `SpeechTabModel`,
  `PromptsTabModel`, `TextFeatures` (+ `AppModel.textFeatures`, `AppModel.llmTarget(for:)`).
- `ErrorText.describe(_:)` is widened in `Core/ErrorText.swift` to cover any `LocalizedError`,
  `CancellationError`, `FeatureConfigError` and `PresetError`.
- `AppEnvironment` gains `pasteboard`, `keySimulator`, `ax`, `speech`, and
  `quickPanelHost: (@MainActor (QuickPanelView) -> any QuickPanelHosting)?` (nil in tests).
- **`HUDState` gains `case speaking(hint: String)`** (Plan 4, Task 16 — the one place Plan 4
  changes a shipped Plan 3 type). It never auto-hides, so `HUDController.autoHideDuration(for:)`
  returns `nil` for it, and `HUDView` renders `Icon(.speak, size: 20)` + "Speaking…" + the hint.
  Consequently `Toasting` is **three** methods, not one:
  `toast(_:duration:)`, `show(_ state: HUDState)`, `hide()` — all already satisfied by
  `HUDController`, so `extension HUDController: Toasting {}` still needs no members. Any other
  exhaustive `switch` over `HUDState` must add the case.
  `SpeakController` gains `static let stopHint` and drives the state from the
  `SpeechSynthesizing.onStateChange` hook. This closes known spec gap 1 below.
- Plan 4's test doubles are named `Scripted*` and coexist with Plan 3's `Fake*`.

## Plan 5 — Release tooling

- New `scripts/lib/paths.mjs` (`ROOT`, `MACOS_DIR`, `PROJECT_YML`, `PBXPROJ`, `XCODEPROJ`,
  `CHANGELOG_PATH`, `APP_BUNDLE_DIR`, `INFO_PLIST_SRC`, `ICON_SRC`, `ENTITLEMENTS_SRC`,
  `LICENSE_PATH`, `DIST_DIR`, `README_PATH`, `APP_NAME`, `EXECUTABLE_NAME`, `BUNDLE_ID`,
  `TEAM_ID`, `NOTARY_PROFILE`, `DEPLOYMENT_TARGET`, `SCHEME`, `appPath(distDir)`).
- New `scripts/lib/changelog.mjs` (`updateChangelog`, `extractSection`).
- `scripts/lib/fs.mjs` additions: `mkdirp`, `rmrf`, `copyPath`, `chmodExec`, `pathExists`,
  `listDirsWithSuffix`, `listBundles`, `listFrameworks`, `move`, `makeTempDir`, `realFsOps`,
  `realIO`.
- New script `scripts/install-app.mjs` (npm script `install-app`); the npm script for
  `configure-notarization.mjs` is named **`configure-notary`**.
- Final `package.json` scripts (superseding the one-line list above):
  `gen`, `icon`, `test:swift`, `test:scripts`, `sync-agents`, `sync-agents:check`, `sync-icons`,
  `sync-icons:check`, `build`, `notarize`, `configure-notary`, `release`, `audit`, `install-app`,
  `fetch-model-hashes`. `test:scripts` keeps Plan 1's **quoted** glob
  `node --test 'scripts/__tests__/**/*.test.mjs'`.
- Build layout: `swift build` emits the app target's resources as
  `Macomprendo_Macomprendo.bundle` (holding `Icons/`), which `build-app.mjs` copies into
  `Contents/Resources`; a missing bundle is a hard failure. The XcodeGen build instead copies
  `Sources/Macomprendo/Resources/Icons` as a folder reference to `Contents/Resources/Icons` —
  `ResourceBundle.current` (`#if SWIFT_PACKAGE` → `.module`, else `.main`) resolves both.
- Git: `origin` is `git@github.com:DZamataev/macomprendo.git` (GitHub). A secondary `gitlab`
  remote may exist; every preflight check and `gh release create` targets `origin` only.
- CI runners are pinned to `macos-15`, never `macos-latest`.

## Known spec gaps (item 1 is closed; the rest have no task)

1. ~~Spec §3.4: the HUD's **"Speaking…" state with the stop hint** while `SpeakController` plays
   audio.~~ **Closed** by Plan 4, Task 16 (`HUDState.speaking(hint:)`, `HUDView` rendering,
   `Toasting.show(_:)`/`hide()`, driven from `SpeakController`). Sentence-*level* progress
   (highlighting the sentence being read) remains unimplemented and is not required by the spec.
2. Spec §3.1: `Settings` is specified to carry **"HUD/panel position overrides"**. Only
   `quickPanelFrames` exists; the Recording HUD has no persisted position override
   (`HUDLayout` always centres it on the screen under the mouse).
3. Spec §2 dependency table and §9 decision 5 still name `phosphor-icons/swift` as the delivery
   mechanism. The plans deliberately vendor `@phosphor-icons/core` SVGs instead; Plan 5's
   ADR-0008 records the change, but the spec text itself was not updated.
