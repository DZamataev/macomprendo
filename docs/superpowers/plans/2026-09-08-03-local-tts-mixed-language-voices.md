# Local TTS mixed-language voices — implementation plan

> Execute directly on `main` in `<repo>`; the user explicitly requested no worktree.

**Goal:** Group Local TTS models by language and switch downloaded model+speaker selections inside mixed-language text with the same segmentation behavior as System voices.

**Spec:** `docs/superpowers/specs/2026-09-08-local-tts-mixed-language-voices-design.md`

## Global constraints

- Use strict RED → GREEN TDD, one vertical behavior at a time.
- Keep System and Local persisted toggles/maps independent.
- Never route a Local run to System or auto-download a model.
- Runtime availability comes from `ModelManaging`, not a UI snapshot.
- Keep one in-flight `SherpaTTSService` task; a new `speak` cancels the old mixed queue.
- Construct real services only in `AppEnvironment.live()`.
- Add new Swift files by directory for SwiftPM, then run `npm run gen` so the explicit `.xcodeproj` includes them.
- Do not log selected text.
- Do not add machine-specific paths to tracked documents.
- Commit each completed task with a conventional commit. Do not push.

## Task 1 — Persist Local model+speaker mappings

**Files**

- Modify: `macos/Sources/Macomprendo/Core/Settings.swift` (`SpeechSettings`, its initializer and decoder)
- Modify: `macos/Tests/MacomprendoTests/Core/SettingsTests.swift`

**Interfaces**

Defines for every later task:

```swift
struct LocalVoiceSelection: Codable, Sendable, Equatable, Hashable {
    var modelID: String
    var speakerID: Int
}

// SpeechSettings
var localVoiceByLanguage: [String: LocalVoiceSelection]
var localSegmentationEnabled: Bool
```

Defaults are `[:]` and `false`. Existing initializer call sites compile because both parameters have defaults. Existing System `voiceByLanguage` and `segmentationEnabled` remain unchanged.

**Steps**

1. Add RED tests proving defaults, JSON round-trip of two mappings using the same model with different speakers, and decoding a payload with both new keys removed.
2. Run `swift test --package-path macos --filter SettingsTests`; verify failures name missing Local fields/types.
3. Add `LocalVoiceSelection`, initializer defaults/assignments, decoder `decodeIfPresent` defaults, and update the field-ownership comment.
4. Re-run the focused suite GREEN.
5. Mutation-check independence by temporarily decoding `localSegmentationEnabled` from `.segmentationEnabled`; the legacy/independence test must fail, then restore.
6. Commit: `feat(speech): persist local voice mappings`.

## Task 2 — Extract the shared mixed-language planner

**Files**

- Create: `macos/Sources/Macomprendo/Services/MixedLanguageSpeechPlanner.swift`
- Create: `macos/Tests/MacomprendoTests/Services/MixedLanguageSpeechPlannerTests.swift`
- Modify: `macos/Sources/Macomprendo/Services/SpeechService.swift` (`UtterancePlan`, `AVSpeechService.utterancePlan`)
- Modify: `macos/Tests/MacomprendoTests/Services/SpeechSegmentationTests.swift`

**Interfaces**

Consumes existing `TextRun`, `ScriptClass`, `LanguageSegmenter`, `LanguageDetecting`, and `AVSpeechService.minDetectionLetters` behavior. Exposes:

```swift
struct PlannedSpeechRun<Selection: Hashable & Sendable>: Sendable, Equatable {
    let text: String
    let selection: Selection
}

enum MixedLanguageSpeechPlanner {
    nonisolated static func plan<Selection: Hashable & Sendable>(
        text: String,
        enabled: Bool,
        defaultSelection: Selection,
        detectLanguages: Bool,
        detector: any LanguageDetecting,
        resolve: (TextRun, String?) -> Selection
    ) -> [PlannedSpeechRun<Selection>]
}
```

The planner owns segmentation, the 12-letter detection threshold, and adjacent/everything-one-selection coalescing. It does not know System or Local voice types.

**Steps**

1. Add RED planner tests for disabled/original text, mixed runs, detector threshold, neutral text, adjacent equal selections, and full collapse to the original string.
2. Run `swift test --package-path macos --filter MixedLanguageSpeechPlannerTests`; verify compile RED.
3. Implement only the generic planner.
4. Run planner tests GREEN.
5. Convert `AVSpeechService.utterancePlan` to delegate to it. Pass `detectLanguages: !settings.voiceByLanguage.isEmpty`; preserve the existing resolver and `UtterancePlan` public seam.
6. Run `SpeechSegmentationTests` and prove all existing expected plans remain unchanged.
7. Mutation-check the threshold and full-collapse guard; targeted tests must fail, then restore.
8. Run `npm run gen` and commit the new source/test membership: `refactor(speech): share mixed-language planning`.

## Task 3 — Plan Local runs from downloaded models

**Files**

- Modify: `macos/Sources/Macomprendo/Services/LocalSpeechService.swift`
- Modify: `macos/Tests/MacomprendoTests/Services/SherpaTTSSpeechServiceTests.swift`
- Modify if fixture support is required: `macos/Tests/MacomprendoTests/Fakes/StubModelManager.swift`

**Interfaces**

Consumes Task 1 settings and Task 2 planner. Define in `LocalSpeechService.swift`:

```swift
struct AvailableLocalVoice: Sendable, Equatable {
    let model: LocalModel
    let resolved: ResolvedLocalModel
}

struct LocalSpeechQueueItem: Sendable, Equatable {
    let text: String
    let configuration: LocalTTSConfiguration
}
```

Add pure `nonisolated` Local selection/planning helpers on `SherpaTTSService` or a file-private `LocalSpeechPlanner`. The service initializer gains:

```swift
init(modelManager: any ModelManaging,
     generator: any LocalSpeechGenerating,
     player: any AudioPlaying,
     detector: any LanguageDetecting,
     catalog: [LocalModel] = ModelCatalog.all(kind: .tts),
     chunkCharacterLimit: Int = SherpaTTSService.defaultChunkCharacterLimit)
```

`AppEnvironment` wiring is deferred to Task 5; tests inject `ScriptedLanguageDetector` immediately.

**Steps**

1. Extend the service test rig with Russian Piper, English Piper, and Kokoro fixtures; seed resolved directories through `StubModelManager`.
2. Add one RED test per resolver rule: explicit model+speaker; stale/undownloaded/incompatible mapping ignored; compatible default; exact-language Auto; script fallback on undecided detection; default final fallback; speaker clamp.
3. Run focused tests and confirm behavior RED without changing playback yet.
4. Implement the availability snapshot and pure resolver/plan helpers. Snapshot each catalog entry through `resolved(_:)`; never read `ModelsViewModel`.
5. Run resolver tests GREEN.
6. Mutation-check explicit-mapping precedence and deleted-mapping fallback, restore production code, rerun GREEN.
7. Commit: `feat(speech): plan downloaded local voices by language`.

## Task 4 — Cache two sherpa native models with LRU eviction

**Files**

- Modify: `macos/Sources/Macomprendo/Services/SherpaTTSService.swift` (`SherpaSpeechGenerator` only)
- Modify: `macos/Tests/MacomprendoTests/Services/SherpaTTSServiceTests.swift`

**Interfaces**

`LocalSpeechGenerating.generate` and `SherpaTTSBackend` stay unchanged. Replace `cachedIdentity/cachedModel` with private cache entries and MRU order. Add an internal initializer default:

```swift
init(backend: any SherpaTTSBackend = LiveSherpaTTSBackend(), cacheCapacity: Int = 2)
```

Capacity is clamped to at least one. Cache keys are full `SherpaTTSModelIdentity`; speaker/speed do not affect identity.

**Steps**

1. Replace the old reload test with RED tests proving A→B→A loads twice total, speaker changes reuse A, A→B→C→A reloads A after LRU eviction, and a failed C load leaves cached A/B usable.
2. Run `SherpaTTSGeneratorTests`; confirm old single-entry code fails alternation reuse.
3. Implement bounded LRU inside the actor. Insert only after successful load; promote on hit.
4. Re-run GREEN.
5. Mutation-check promotion by removing it; eviction-order test must fail, then restore.
6. Commit: `perf(speech): cache two local TTS models`.

## Task 5 — Execute a mixed Local queue

**Files**

- Modify: `macos/Sources/Macomprendo/Services/LocalSpeechService.swift`
- Modify: `macos/Sources/Macomprendo/App/AppEnvironment.swift`
- Modify: `macos/Tests/MacomprendoTests/Services/SherpaTTSSpeechServiceTests.swift`

**Interfaces**

Consumes Task 3 `LocalSpeechQueueItem`. `play(chunks:settings:)` becomes queue-oriented; planner output is split with `SpeechTextChunker` only after voice selection. Existing `LocalSpeechGenerating`, `AudioPlaying`, state callbacks, and `drain()` remain stable.

`AppEnvironment.live()` creates one `NLLanguageDetector` value and injects it into both:

```swift
system: AVSpeechService(detector: languageDetector)
local: SherpaTTSService(..., detector: languageDetector)
```

**Steps**

1. Add a RED `ru → en → ru` service test asserting exact text/configuration order and different speakers for mappings that reuse Kokoro.
2. Add RED tests that planning precedes chunking, N+1 configuration generates while N plays, missing optional mapped model falls back, missing default still fails, and stop/supersede drops late mixed audio.
3. Run the focused service suite RED.
4. Replace one shared configuration with queue items. Preserve structured `async let` prefetch and all generation-token guards.
5. Inject the detector at the sole production construction site in `AppEnvironment.swift` and in the test rig.
6. Run service tests GREEN and `swift build --package-path macos` for strict concurrency.
7. Mutation-check per-item configuration by forcing all items to the default; mixed test must fail, then restore.
8. Commit: `feat(speech): switch local voices within mixed text`.

## Task 6 — Derive grouped catalog and downloaded-only mapping choices

**Files**

- Modify: `macos/Sources/Macomprendo/UI/Settings/SpeechTab.swift` (`SpeechTabModel`)
- Modify: `macos/Sources/Macomprendo/UI/Settings/SpeechSourceModel.swift`
- Modify: `macos/Tests/MacomprendoTests/UI/SpeechTabModelTests.swift`
- Modify: `macos/Tests/MacomprendoTests/UI/SpeechSourceModelTests.swift`

**Interfaces**

Add to `SpeechTabModel`:

```swift
struct LocalVoiceGroup: Identifiable, Equatable {
    let language: String
    let displayName: String
    let models: [LocalModel]
    var id: String { language }
}

func localCatalogGroups(_ models: [LocalModel]) -> [LocalVoiceGroup]
func downloadedLocalGroups(catalog: [LocalModel]) -> [LocalVoiceGroup]
func localVoice(forLanguage language: String, catalog: [LocalModel]) -> LocalVoiceSelection?
func setLocalVoice(_ modelID: String?, forLanguage language: String, catalog: [LocalModel])
func setLocalSpeaker(_ speakerID: Int, forLanguage language: String, catalog: [LocalModel])
```

The implementation may make pure grouping helpers static, but view code must not reproduce the rules. `SpeechSourceModel.modelStates` remains the live state source and exposes a downloaded-ID query or passes states into `SpeechTabModel`; do not create another manager.

**Steps**

1. Add RED grouping tests: `ru/en/zh`, stable model order, Kokoro in both `en` and `zh`, empty language arrays ignored.
2. Add RED choice tests: only `.downloaded` models, Auto for stale mappings, exact model+speaker mutation, speaker clamp, same Kokoro with independent English/Chinese speakers.
3. Run UI model suites RED.
4. Implement derived groups and mutations using catalog metadata + live states.
5. Add RED audition tests: Local source in temporary settings, correct phrase/model/speaker, Local segmentation off, persisted active/default settings unchanged, audition toggle respected.
6. Implement Local audition through the existing injected `SpeechSynthesizing`; do not construct a service in UI.
7. Run UI model suites GREEN.
8. Commit: `feat(speech): model local voice mappings for settings`.

## Task 7 — Render the grouped Local controls

**Files**

- Modify: `macos/Sources/Macomprendo/UI/Settings/SpeechTab.swift` (`localSection`, row bindings)
- Modify: `docs/SMOKE_TEST.md`
- Modify: `CHANGELOG.md`
- Modify: `docs/superpowers/specs/2026-09-08-local-tts-mixed-language-voices-design.md` (status to implemented only after gates)
- Regenerate: `macos/Macomprendo.xcodeproj/project.pbxproj`

**Interfaces**

Consumes Task 6 groups/mutations. The View binds only to `SpeechTabModel`/`SpeechSourceModel` outputs and `SpeechSettings.localSegmentationEnabled`; it does not inspect filesystem state.

**Steps**

1. Replace the flat `ForEach(source.ttsModels)` with language `Section`s. Reusing a model ID in two sections is intentional; download controls still call the same `ModelsViewModel` ID.
2. Keep default model parameters, then add the exact toggle label `Switch voices for mixed-language text`.
3. Add disabled `Voice per language` controls: `Auto` + downloaded models; show a second Speaker picker only for an explicit multi-speaker mapping.
4. Delete the old caption claiming Local switching is System-only.
5. Run focused UI model tests and `swift build --package-path macos`.
6. Update changelog and smoke steps for Russian/English Auto and explicit mapping, Kokoro independent speakers, deleting a mapped model, and pause/stop across a boundary.
7. Run `npm run gen`; verify a second `npm run gen` produces no `.pbxproj` diff.
8. Commit: `feat(speech): add local mixed-language voice controls`.

## Task 8 — Review, aggregate verification, and native acceptance

**Files**

- Review range: `93df44a..HEAD`
- Fix only findings attributable to this feature; add regression tests first.

**Steps**

1. Self-review settings compatibility, planner equivalence, no-System-fallback, live-model availability, LRU destruction, queue cancellation, and duplicate Kokoro rows.
2. Run an independent adversarial code review against the spec. Resolve every blocker/should-fix with RED regression tests and a focused commit.
3. Run:
   - `npm run test:swift`
   - `npm run test:scripts`
   - `swift build --package-path macos`
   - `npm run gen` followed by `git diff --exit-code -- macos/Macomprendo.xcodeproj/project.pbxproj`
   - `xcodebuild -project macos/Macomprendo.xcodeproj -scheme Macomprendo -configuration Release -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build`
   - `npm run audit`
   - `git diff --check`
4. Build/install the signed app with `npm run install-app:signed`; read back `codesign --verify --deep --strict` and the live PID.
5. Use Peekaboo for Settings ▸ Speech ▸ Local TTS if it can produce a trustworthy receipt. Otherwise report the tooling blocker and hand off the exact smoke steps; never click blindly.
6. Manually verify: grouped sections, duplicated Kokoro state, downloaded-only mapping choices, toggle disabled/enabled state, Russian/English switching, different Kokoro speakers, Preview, ⌥S, pause/resume/stop, and deletion fallback.
7. Mark the spec implemented only after automated gates and manual acceptance.
8. Final commit if review/docs changed: `fix(speech): harden local voice switching`.

## Completion criteria

- Every acceptance criterion in the spec has a test or named manual smoke step.
- Existing System segmentation fixtures are unchanged and green.
- Local mappings never download or route to System.
- Native cache holds at most two model identities and alternation reuses both.
- `main` is clean; no worktree was created; no push was performed.
