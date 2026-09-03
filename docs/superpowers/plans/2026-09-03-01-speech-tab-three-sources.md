# Speech tab: three sources and a generalised model catalog — Plan 1

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild Settings ▸ Speech in the shape of Settings ▸ Dictation — an active-source selector with one readiness status above three navigation-only sub-tabs — and generalise the model catalog from "ASR models" to "local models" so the Local TTS tab has a catalog to list.

**Architecture:** Three layers change, bottom-up. `Services/ModelCatalog.swift` renames `ASREngine`→`LocalEngine` and `LocalASRModel`→`LocalModel`, adds `ModelKind`, and every existing caller narrows to `ModelCatalog.all(kind: .asr)`. `Core/Settings.swift` gains `SpeechSource.local` plus three `local*` fields. `Features/SpeechReadiness.swift` is new and pure. `UI/Settings/SpeechSourceModel.swift` is new and mirrors `DictationTabModel`; `UI/Settings/SpeechTab.swift` is rebuilt around it. Local TTS ships in this plan as a catalog that lists nothing yet and reports itself not-ready honestly — Plan 2 adds the eight entries and the engine.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, swift-testing (`@Test` / `#expect`), XcodeGen.

**Spec:** `docs/superpowers/specs/2026-09-03-speech-sources-and-local-tts.md`

## Global Constraints

- Layers point downward only: UI → Features → Services/Providers → Core. Never construct a concrete service outside `AppEnvironment`.
- TDD: the failing test comes first, always. Run it, see it fail, then implement.
- Swift 6 strict concurrency: controllers and view models are `@MainActor`; catalog value types are `Sendable`.
- Icons come from `Icon(.case)`. Never write `Image(systemName:)` in a view.
- Secrets never leave the Keychain: `SpeechSettings` stores `endpointAPIKeyRef`, never a key.
- Every user-visible failure is a `MacomprendoError` with `errorDescription` and `recoverySuggestion`. No new cases are needed by this plan.
- `Settings.currentSchemaVersion` stays at `2`. New fields decode through the existing hand-written `init(from:)` with `decodeIfPresent` and a default.
- Test command: `npm run test:swift`. Build check: `swift build --package-path macos`.
- Commit messages are conventional commits.
- `macos/project.yml` is the source of truth for the Xcode project. New source files land in directories already globbed by it, so no `npm run gen` is required by this plan — verify with `npm run gen` producing no diff at the end.

---

### Task 1: Generalise the catalog vocabulary from ASR to local models

Pure renaming plus one new enum. No behaviour changes anywhere: after this task every call site compiles and every existing test passes unchanged in meaning. Doing it as its own commit keeps the 95-occurrence rename out of the diffs that follow.

**Files:**
- Modify: `macos/Sources/Macomprendo/Services/ModelCatalog.swift`
- Modify: `macos/Sources/Macomprendo/Services/ModelManager.swift`
- Modify: `macos/Sources/Macomprendo/UI/Settings/ModelsViewModel.swift`
- Modify: `macos/Sources/Macomprendo/UI/Settings/DictationTabModel.swift`
- Modify: `macos/Sources/Macomprendo/UI/Settings/DictationTab.swift`
- Modify: `macos/Sources/Macomprendo/UI/Onboarding/OnboardingViewModel.swift`
- Modify: `macos/Sources/Macomprendo/UI/Onboarding/OnboardingView.swift`
- Modify: `macos/Sources/Macomprendo/UI/RecordingHUD/HUDController.swift`
- Modify: `macos/Sources/Macomprendo/Core/Settings.swift`
- Modify: `macos/Tests/MacomprendoTests/Services/ModelCatalogTests.swift`
- Modify: `macos/Tests/MacomprendoTests/Services/LocalModelManagerTests.swift`
- Modify: `macos/Tests/MacomprendoTests/UI/ModelsViewModelTests.swift`
- Modify: `macos/Tests/MacomprendoTests/UI/DictationTabModelTests.swift`
- Modify: `macos/Tests/MacomprendoTests/UI/OnboardingViewModelTests.swift`
- Modify: `macos/Tests/MacomprendoTests/Fakes/FakeModelManager.swift`
- Modify: `macos/Tests/MacomprendoTests/Fakes/StubModelManager.swift`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: `enum ModelKind: String, Sendable { case asr, tts }`; `enum LocalEngine: String, Codable, Sendable, CaseIterable` with cases `whisperCpp`, `gigaAM` and computed `var kind: ModelKind`; `struct LocalModel` (was `LocalASRModel`) with unchanged stored properties plus `var kind: ModelKind`; `ModelCatalog.all(kind:) -> [LocalModel]`; `ResolvedLocalModel.engine: LocalEngine`.

- [ ] **Step 1: Write the failing test**

Add to `macos/Tests/MacomprendoTests/Services/ModelCatalogTests.swift`:

```swift
@Test func everyCatalogEntryReportsItsKindFromItsEngine() {
    #expect(LocalEngine.whisperCpp.kind == .asr)
    #expect(LocalEngine.gigaAM.kind == .asr)
    #expect(ModelCatalog.all.allSatisfy { $0.kind == .asr })
}

@Test func allByKindPartitionsTheCatalog() {
    #expect(ModelCatalog.all(kind: .asr).count == ModelCatalog.all.count)
    #expect(ModelCatalog.all(kind: .tts).isEmpty)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm run test:swift`
Expected: compile failure — `cannot find 'LocalEngine' in scope`, `cannot find 'ModelKind' in scope`.

- [ ] **Step 3: Add the new vocabulary to `ModelCatalog.swift`**

Replace the `ASREngine` declaration at the top of `macos/Sources/Macomprendo/Services/ModelCatalog.swift`:

```swift
/// Whether a model transcribes speech or produces it.
enum ModelKind: String, Sendable, CaseIterable { case asr, tts }

/// Which local runtime opens a model. Named for the runtime, not for the task, because one
/// runtime (sherpa-onnx) serves both kinds.
enum LocalEngine: String, Codable, Sendable, CaseIterable {
    case whisperCpp
    case gigaAM

    var kind: ModelKind {
        switch self {
        case .whisperCpp, .gigaAM: .asr
        }
    }
}
```

In the same file rename `struct LocalASRModel` to `struct LocalModel`, change its `let engine: ASREngine` to `let engine: LocalEngine`, and add below `totalSizeBytes`:

```swift
    var kind: ModelKind { engine.kind }
```

Change `ModelCatalog`'s stored arrays and helpers to the new type, and replace `all(for engine:)` with the kind-aware pair:

```swift
    static func all(for engine: LocalEngine) -> [LocalModel] {
        all.filter { $0.engine == engine }
    }

    static func all(kind: ModelKind) -> [LocalModel] {
        all.filter { $0.kind == kind }
    }
```

- [ ] **Step 4: Propagate the rename**

Run: `cd /Users/frenzy/dev/macomprendo && grep -rln 'ASREngine\|LocalASRModel' macos/Sources macos/Tests`

For every file listed, replace `ASREngine` with `LocalEngine` and `LocalASRModel` with `LocalModel`. These are type-name-only substitutions — no logic changes. `ResolvedLocalModel.engine` in `ModelManager.swift` becomes `LocalEngine`; `StubModelManager._resolvedEngines` becomes `[String: LocalEngine]`.

- [ ] **Step 5: Run the full suite**

Run: `npm run test:swift`
Expected: PASS, including the two new tests.

- [ ] **Step 6: Verify no new warnings**

Run: `swift build --package-path macos 2>&1 | grep -c warning`
Expected: the same count as before the task (record it with `git stash` first if unsure).

- [ ] **Step 7: Commit**

```bash
git add macos/Sources macos/Tests
git commit -m "refactor(models): generalise the catalog vocabulary from ASR to local models"
```

---

### Task 2: Narrow every ASR call site to `kind: .asr`

`ModelCatalog.all` will start returning TTS entries in Plan 2. Every existing consumer means "the transcription models" and must say so now, while the catalog is still all-ASR and the change is provably behaviour-preserving.

**Files:**
- Modify: `macos/Sources/Macomprendo/UI/Settings/DictationTabModel.swift:70` (the `catalog:` default)
- Modify: `macos/Sources/Macomprendo/UI/Settings/ModelsViewModel.swift:19` (the `catalog:` default)
- Modify: `macos/Sources/Macomprendo/UI/Onboarding/OnboardingViewModel.swift`
- Modify: `macos/Sources/Macomprendo/UI/RecordingHUD/HUDController.swift`
- Modify: `macos/Sources/Macomprendo/Services/ModelManager.swift:53` (the `LocalModelManager` convenience init)
- Test: `macos/Tests/MacomprendoTests/UI/DictationTabModelTests.swift`

**Interfaces:**
- Consumes: `ModelCatalog.all(kind:)` from Task 1.
- Produces: nothing new; every ASR consumer now filters by kind.

- [ ] **Step 1: Write the failing test**

Add to `macos/Tests/MacomprendoTests/UI/DictationTabModelTests.swift` — that suite is already `@MainActor`, which constructing a `DictationTabModel` requires, while `ModelCatalogTests` is not:

```swift
/// Guards the one way the TTS catalog added in Plan 2 could leak into transcription: a
/// consumer that took `ModelCatalog.all` and meant "the ASR models". Written while the
/// catalog is still all-ASR, so it starts green and turns red the moment a TTS entry lands
/// on a screen that cannot use it.
@Test func everyTranscriptionConsumerSeesASREntriesOnly() {
    let dictation = DictationTabModel(holder: ScriptedSettingsHolder())
    #expect(dictation.rows(for: .whisperCpp).allSatisfy { $0.kind == .asr })
    #expect(dictation.rows(for: .gigaAM).allSatisfy { $0.kind == .asr })
    #expect(dictation.selectableSources.allSatisfy { source in
        if case .local(let id) = source.source {
            return ModelCatalog.model(id: id)?.kind == .asr
        }
        return true
    })
}
```

Note this test is `@MainActor`; it lives in `DictationTabModelTests`, which is already an `@MainActor` suite.

- [ ] **Step 2: Run the test**

Run: `npm run test:swift`
Expected: PASS already — the catalog holds only ASR entries today. The test exists to fail later, and its value is that it is committed *before* the TTS entries.

- [ ] **Step 3: Narrow the call sites**

In `DictationTabModel.swift`, change the initialiser default:

```swift
    init(holder: any SettingsHolding, catalog: [LocalModel] = ModelCatalog.all(kind: .asr)) {
```

In `ModelsViewModel.swift`:

```swift
    init(models: any ModelManaging, catalog: [LocalModel] = ModelCatalog.all(kind: .asr)) {
```

In `ModelManager.swift`, the convenience initialiser keeps the whole catalog — the manager downloads both kinds:

```swift
    init(directory: URL, http: any HTTPClient) {
        self.init(directory: directory, http: http, catalog: ModelCatalog.all)
    }
```

Leave that one as `ModelCatalog.all` and add the comment `// Both kinds: this manager downloads TTS models too.` above it.

In `OnboardingViewModel.swift` and `HUDController.swift`, replace each `ModelCatalog.all` with `ModelCatalog.all(kind: .asr)`. Verify by running: `grep -rn 'ModelCatalog.all\b' macos/Sources` — the only bare `all` left must be `ModelManager.swift`'s and `ModelCatalog`'s own definition.

- [ ] **Step 4: Run the suite**

Run: `npm run test:swift`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources macos/Tests
git commit -m "refactor(models): narrow transcription consumers to ASR models"
```

---

### Task 3: `SpeechSource.local` and the three local settings fields

**Files:**
- Modify: `macos/Sources/Macomprendo/Core/Settings.swift:26-38` (the enum), `:54-98` (the struct and its memberwise init), `:101-127` (the decoder)
- Test: `macos/Tests/MacomprendoTests/Core/SettingsTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `SpeechSource.local`; `SpeechSettings.localModelID: String?`, `.localSpeakerID: Int`, `.localSpeed: Float`. Defaults: `nil`, `0`, `1.0`.

- [ ] **Step 1: Write the failing test**

```swift
@Test func aDocumentWrittenBeforeLocalTTSDecodesWithDefaults() throws {
    let json = Data("""
    {"schemaVersion":2,"speech":{"source":"endpoint","endpointModel":"gpt-4o-mini-tts"}}
    """.utf8)
    let settings = try Settings.migrate(json)
    #expect(settings.speech.source == .endpoint)
    #expect(settings.speech.endpointModel == "gpt-4o-mini-tts")
    #expect(settings.speech.localModelID == nil)
    #expect(settings.speech.localSpeakerID == 0)
    #expect(settings.speech.localSpeed == 1.0)
}

@Test func theLocalSourceRoundTripsThroughJSON() throws {
    var settings = Settings.default
    settings.speech.source = .local
    settings.speech.localModelID = "vits-piper-ru_RU-ruslan-medium"
    settings.speech.localSpeakerID = 3
    settings.speech.localSpeed = 1.25

    let encoded = try JSONEncoder().encode(settings)
    let decoded = try Settings.migrate(encoded)

    #expect(decoded.speech.source == .local)
    #expect(decoded.speech.localModelID == "vits-piper-ru_RU-ruslan-medium")
    #expect(decoded.speech.localSpeakerID == 3)
    #expect(decoded.speech.localSpeed == 1.25)
    #expect(decoded.schemaVersion == 2)
}

@Test func addingTheLocalSourceDoesNotMoveTheSchemaVersion() {
    #expect(Settings.currentSchemaVersion == 2)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm run test:swift`
Expected: FAIL — `type 'SpeechSource' has no member 'local'`.

- [ ] **Step 3: Implement**

In `Settings.swift`, extend the enum:

```swift
/// Which backend reads text aloud.
enum SpeechSource: String, Codable, Sendable, CaseIterable, Identifiable {
    case system
    case local
    case endpoint

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "System voices"
        case .local: "Local TTS"
        case .endpoint: "Endpoint"
        }
    }
}
```

In `SpeechSettings`, add the three stored properties next to the existing endpoint ones, with the ownership comment the spec asks for:

```swift
    // Which fields belong to which source. Getting this wrong is how a slider ends up doing
    // nothing, so it is written down rather than inferred:
    //   System only:   voiceID, rate, pitch, volume, voiceByLanguage, segmentationEnabled
    //   Local only:    localModelID, localSpeakerID, localSpeed
    //   Endpoint only: endpointBaseURL, endpointModel, endpointVoice, endpointInstructions,
    //                  endpointAPIKeyRef
    //   Shared:        source, previewText, auditionOnSelect

    /// A `ModelCatalog` id of a TTS entry. `nil` means no local model has been chosen yet,
    /// which is what makes the local source not ready.
    var localModelID: String?
    /// The speaker inside a multi-speaker model. 0 for the single-speaker Piper voices.
    var localSpeakerID: Int
    /// sherpa's `OfflineTts` speed. 1.0 reads at the pace the model was trained on.
    var localSpeed: Float
```

Add them to the memberwise initialiser with defaults `localModelID: String? = nil`, `localSpeakerID: Int = 0`, `localSpeed: Float = 1.0`, assigning each in the body.

Add them to the hand-written decoder in the extension:

```swift
        localModelID = try c.decodeIfPresent(String.self, forKey: .localModelID)
        localSpeakerID = try c.decodeIfPresent(Int.self, forKey: .localSpeakerID) ?? d.localSpeakerID
        localSpeed = try c.decodeIfPresent(Float.self, forKey: .localSpeed) ?? d.localSpeed
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm run test:swift`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Macomprendo/Core/Settings.swift macos/Tests/MacomprendoTests/Core
git commit -m "feat(speech): add the local source and its settings fields"
```

---

### Task 4: `SpeechReadiness`

Pure, computed on demand, never stored — the same discipline as `BackendReadiness`, which it deliberately sits beside rather than extends.

**Files:**
- Create: `macos/Sources/Macomprendo/Features/SpeechReadiness.swift`
- Test: `macos/Tests/MacomprendoTests/Features/SpeechReadinessTests.swift`

**Interfaces:**
- Consumes: `SpeechSource` and `SpeechSettings` from Task 3; `ModelState` from `Services/ModelManager.swift`.
- Produces:
  ```swift
  enum SpeechFixAction: Sendable, Equatable {
      case downloadModel(id: String)
      case selectModel
      case fillEndpoint
      case saveKey
  }
  enum SpeechReadiness: Sendable, Equatable {
      case ready
      case notReady(reason: String, fix: SpeechFixAction?)
      static func of(source: SpeechSource,
                     settings: SpeechSettings,
                     modelStates: [String: ModelState]) -> SpeechReadiness
  }
  ```

- [ ] **Step 1: Write the failing test**

Create `macos/Tests/MacomprendoTests/Features/SpeechReadinessTests.swift`:

```swift
import Foundation
import Testing
@testable import Macomprendo

@Suite struct SpeechReadinessTests {

    private func settings(_ mutate: (inout SpeechSettings) -> Void = { _ in }) -> SpeechSettings {
        var s = SpeechSettings()
        mutate(&s)
        return s
    }

    // MARK: - System

    @Test func theSystemSourceIsAlwaysReady() {
        #expect(SpeechReadiness.of(source: .system, settings: settings(), modelStates: [:]) == .ready)
    }

    @Test func theSystemSourceIsReadyWithNoVoiceChosen() {
        // AVFoundation falls back to the system default voice, so speech is heard. Reporting
        // "not ready" here would be a lie the user cannot act on.
        let s = settings { $0.voiceID = nil }
        #expect(SpeechReadiness.of(source: .system, settings: s, modelStates: [:]) == .ready)
    }

    // MARK: - Local

    @Test func theLocalSourceNeedsAModelToBeChosen() {
        let s = settings { $0.localModelID = nil }
        let readiness = SpeechReadiness.of(source: .local, settings: s, modelStates: [:])
        #expect(readiness == .notReady(reason: "No voice has been chosen yet.", fix: .selectModel))
    }

    @Test func theLocalSourceIsReadyOnceItsModelIsDownloaded() {
        let s = settings { $0.localModelID = "piper-ru" }
        let readiness = SpeechReadiness.of(source: .local, settings: s,
                                           modelStates: ["piper-ru": .downloaded])
        #expect(readiness == .ready)
    }

    @Test func anUndownloadedLocalModelOffersItsDownload() {
        let s = settings { $0.localModelID = "piper-ru" }
        let readiness = SpeechReadiness.of(source: .local, settings: s,
                                           modelStates: ["piper-ru": .notDownloaded])
        #expect(readiness == .notReady(reason: "This voice has not been downloaded yet.",
                                       fix: .downloadModel(id: "piper-ru")))
    }

    @Test func aModelWithNoRecordedStateReadsAsNotDownloaded() {
        // The states dictionary is populated asynchronously; an absent key means "not seen on
        // disk", which is the same actionable situation as a known-absent model.
        let s = settings { $0.localModelID = "piper-ru" }
        let readiness = SpeechReadiness.of(source: .local, settings: s, modelStates: [:])
        #expect(readiness == .notReady(reason: "This voice has not been downloaded yet.",
                                       fix: .downloadModel(id: "piper-ru")))
    }

    @Test func aDownloadInProgressReportsProgressAndOffersNoButton() {
        let s = settings { $0.localModelID = "piper-ru" }
        let readiness = SpeechReadiness.of(source: .local, settings: s,
                                           modelStates: ["piper-ru": .downloading(fraction: 0.42)])
        #expect(readiness == .notReady(reason: "Downloading… 42%", fix: nil))
    }

    @Test func aFailedDownloadReportsItsMessageAndOffersARetry() {
        let s = settings { $0.localModelID = "piper-ru" }
        let readiness = SpeechReadiness.of(source: .local, settings: s,
                                           modelStates: ["piper-ru": .failed("Checksum mismatch")])
        #expect(readiness == .notReady(reason: "Checksum mismatch",
                                       fix: .downloadModel(id: "piper-ru")))
    }

    // MARK: - Endpoint

    @Test func aFullyConfiguredEndpointIsReadyWithoutAnyProbe() {
        // Deliberately weaker than Dictation's rule: this claims "configured", not "verified".
        // A wrong key surfaces at the first hotkey press through the existing error toast.
        let s = settings { $0.endpointAPIKeyRef = SpeechSettings.endpointKeychainAccount }
        #expect(SpeechReadiness.of(source: .endpoint, settings: s, modelStates: [:]) == .ready)
    }

    @Test func anEndpointWithNoSavedKeyIsNotReady() {
        let s = settings { $0.endpointAPIKeyRef = nil }
        #expect(SpeechReadiness.of(source: .endpoint, settings: s, modelStates: [:])
                == .notReady(reason: "No API key is saved for this server.", fix: .saveKey))
    }

    @Test func anEndpointMissingAFieldIsNotReady() {
        for mutate in [{ (s: inout SpeechSettings) in s.endpointModel = "" },
                       { (s: inout SpeechSettings) in s.endpointVoice = "  " }] {
            var s = SpeechSettings()
            s.endpointAPIKeyRef = SpeechSettings.endpointKeychainAccount
            mutate(&s)
            #expect(SpeechReadiness.of(source: .endpoint, settings: s, modelStates: [:])
                    == .notReady(reason: "The server, model and voice must all be filled in.",
                                 fix: .fillEndpoint))
        }
    }

    @Test func aMissingFieldIsReportedBeforeAMissingKey() {
        // One fix button, so the order must be defined: fill the form, then save the key.
        var s = SpeechSettings()
        s.endpointModel = ""
        s.endpointAPIKeyRef = nil
        #expect(SpeechReadiness.of(source: .endpoint, settings: s, modelStates: [:])
                == .notReady(reason: "The server, model and voice must all be filled in.",
                             fix: .fillEndpoint))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm run test:swift`
Expected: FAIL — `cannot find 'SpeechReadiness' in scope`.

- [ ] **Step 3: Write the implementation**

Create `macos/Sources/Macomprendo/Features/SpeechReadiness.swift`:

```swift
import Foundation

/// What the user should do about a speech source that cannot speak.
enum SpeechFixAction: Sendable, Equatable {
    case downloadModel(id: String)
    case selectModel
    case fillEndpoint
    case saveKey
}

/// Whether the configured speech source can actually speak right now. Computed on demand,
/// never stored: it is a view of state that already exists elsewhere.
///
/// A sibling of `BackendReadiness` rather than a generalisation of it — that type switches on
/// `TranscriptionSource` and this one on `SpeechSource`, and a shared generic would add a type
/// parameter to save three lines.
///
/// The endpoint rule is deliberately weaker than the transcription one: it claims "configured",
/// not "verified". Proving a speech endpoint works means paying for a synthesis request and
/// making a settings screen wait for it, and a wrong key surfaces harmlessly at the first
/// hotkey press through `SpeakController`'s error toast — where a wrong transcription endpoint
/// surfaces only after the user has already spoken and lost the dictation.
enum SpeechReadiness: Sendable, Equatable {
    case ready
    case notReady(reason: String, fix: SpeechFixAction?)

    static func of(source: SpeechSource,
                   settings: SpeechSettings,
                   modelStates: [String: ModelState]) -> SpeechReadiness {
        switch source {
        case .system:
            // A nil voiceID is not a failure: AVFoundation falls back to the system default.
            return .ready

        case .local:
            guard let id = settings.localModelID else {
                return .notReady(reason: "No voice has been chosen yet.", fix: .selectModel)
            }
            switch modelStates[id] ?? .notDownloaded {
            case .downloaded:
                return .ready
            case .notDownloaded:
                return .notReady(reason: "This voice has not been downloaded yet.",
                                 fix: .downloadModel(id: id))
            case .downloading(let fraction):
                return .notReady(reason: "Downloading… \(Int(fraction * 100))%", fix: nil)
            case .failed(let message):
                return .notReady(reason: message, fix: .downloadModel(id: id))
            }

        case .endpoint:
            // Field order matters: there is one fix button, and filling the form comes before
            // saving a key for it.
            let fields = [settings.endpointBaseURL.absoluteString,
                          settings.endpointModel,
                          settings.endpointVoice]
            guard fields.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            else {
                return .notReady(reason: "The server, model and voice must all be filled in.",
                                 fix: .fillEndpoint)
            }
            guard settings.endpointAPIKeyRef != nil else {
                return .notReady(reason: "No API key is saved for this server.", fix: .saveKey)
            }
            return .ready
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm run test:swift`
Expected: PASS, 12 new tests.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Macomprendo/Features/SpeechReadiness.swift macos/Tests/MacomprendoTests/Features/SpeechReadinessTests.swift
git commit -m "feat(speech): add per-source readiness"
```

---

### Task 5: `SpeakController` refuses to speak through a source that is not ready

The spec's late catch: the selector lists all three sources, so an unready one can be selected, and silence with no explanation would be the worst outcome.

**Files:**
- Modify: `macos/Sources/Macomprendo/Features/SpeakController.swift:69-81` (`speak(_:from:)`)
- Modify: `macos/Sources/Macomprendo/App/TextFeatures.swift:113` (the one construction site)
- Modify: `macos/Sources/Macomprendo/App/AppModel.swift:30` (add the TTS `ModelsViewModel` beside the ASR one)
- Test: `macos/Tests/MacomprendoTests/Features/SpeakControllerTests.swift`

**Interfaces:**
- Consumes: `SpeechReadiness.of(source:settings:modelStates:)` from Task 4.
- Produces: `SpeakController.init(speech:toaster:settings:modelStates:)` where `modelStates` is `@escaping @MainActor () -> [String: ModelState]`, defaulting to `{ [:] }`.

- [ ] **Step 1: Write the failing test**

```swift
@Test func speakingThroughANotReadySourceToastsInsteadOfStayingSilent() {
    let speech = ScriptedSpeech()
    let toaster = ScriptedToaster()
    var settings = Settings.default
    settings.speech.source = .local
    settings.speech.localModelID = "piper-ru"          // chosen but never downloaded
    let controller = SpeakController(speech: speech,
                                     toaster: toaster,
                                     settings: { settings },
                                     modelStates: { [:] })

    controller.speak("Прочитай это", from: .hotkey)

    #expect(speech.spoken.isEmpty)
    #expect(toaster.messages.last?.contains("has not been downloaded") == true)
}

@Test func speakingThroughAReadySourceIsUnaffected() {
    let speech = ScriptedSpeech()
    let toaster = ScriptedToaster()
    var settings = Settings.default
    settings.speech.source = .local
    settings.speech.localModelID = "piper-ru"
    let controller = SpeakController(speech: speech,
                                     toaster: toaster,
                                     settings: { settings },
                                     modelStates: { ["piper-ru": .downloaded] })

    controller.speak("Прочитай это", from: .hotkey)

    #expect(speech.spoken.map(\.text) == ["Прочитай это"])
}

@Test func theSystemSourceNeverBlocks() {
    let speech = ScriptedSpeech()
    let controller = SpeakController(speech: speech,
                                     toaster: ScriptedToaster(),
                                     settings: { Settings.default },
                                     modelStates: { [:] })
    controller.speak("Hello", from: .hotkey)
    #expect(speech.spoken.count == 1)
}
```

Check the existing test file for how it builds a controller (`macos/Tests/MacomprendoTests/Features/SpeakControllerTests.swift:14`); `ScriptedToaster` records into `messages`, which is what these tests read.

- [ ] **Step 2: Run test to verify it fails**

Run: `npm run test:swift`
Expected: FAIL — `extra argument 'modelStates' in call`.

- [ ] **Step 3: Implement**

Add the stored property and initialiser parameter to `SpeakController`:

```swift
    private let modelStates: @MainActor () -> [String: ModelState]

    init(speech: any SpeechSynthesizing,
         toaster: any Toasting,
         settings: @escaping @MainActor () -> Settings,
         modelStates: @escaping @MainActor () -> [String: ModelState] = { [:] }) {
        self.speech = speech
        self.toaster = toaster
        self.settings = settings
        self.modelStates = modelStates
```

(keep the rest of the initialiser body unchanged)

In `speak(_:from:)`, insert the gate after the blank-text guard and before `active = source`:

```swift
        // The selector lists sources that are not ready, so one can be active. Speaking
        // nothing and saying nothing would leave the user pressing a hotkey that does not
        // work; falling back to system voices would hide that their choice is broken.
        let current = settings()
        if case .notReady(let reason, _) = SpeechReadiness.of(source: current.speech.source,
                                                              settings: current.speech,
                                                              modelStates: modelStates()) {
            toaster.toast(reason, duration: 2.5)
            return
        }
```

At the one construction site, `macos/Sources/Macomprendo/App/TextFeatures.swift:113`, pass the live TTS download states. `SpeakController` must read the **TTS** catalog's states, not the ASR ones — `AppModel.modelsViewModel` lists transcription models only after Task 2, so a local voice would always read as never-downloaded. Add the second view model to `AppModel.swift`, directly below `lazy var modelsViewModel` at line 30:

```swift
    /// The TTS half of the catalog. A second view model rather than a shared one, because each
    /// screen lists exactly one kind and `ModelsViewModel` filters at construction.
    lazy var ttsModelsViewModel = ModelsViewModel(models: env.models,
                                                  catalog: ModelCatalog.all(kind: .tts))
```

and pass it through in `TextFeatures.live`:

```swift
        let speak = SpeakController(
            speech: env.speech,
            toaster: hud,
            settings: { model.settings },
            modelStates: { [unowned model] in
                model.ttsModelsViewModel.rows.reduce(into: [:]) { $0[$1.id] = $1.state }
            })
```

`ModelsViewModel.rows` is empty until something calls `refresh()`, which the Speech tab does in its `.task`. Until then a chosen-but-unverified local voice reads as not-downloaded and the hotkey reports that — the honest answer when nothing has checked the disk yet.

- [ ] **Step 4: Run test to verify it passes**

Run: `npm run test:swift`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources macos/Tests
git commit -m "fix(speech): refuse to speak through a source that is not ready"
```

---

### Task 6: `SpeechSourceModel`

Mirrors `DictationTabModel`: it owns the selector, the readiness, the sub-tab navigation and the adopted model states. `SpeechTabModel` keeps voices, auditions and the Keychain write.

**Files:**
- Create: `macos/Sources/Macomprendo/UI/Settings/SpeechSourceModel.swift`
- Test: `macos/Tests/MacomprendoTests/UI/SpeechSourceModelTests.swift`

**Interfaces:**
- Consumes: `SpeechReadiness` (Task 4), `SpeechSource.local` (Task 3), `ModelCatalog.all(kind: .tts)` (Task 1), `SettingsHolding` (`@MainActor protocol SettingsHolding: AnyObject { var settings: Settings { get set } }`), `ModelsViewModel.Row`.
- Produces:
  ```swift
  @MainActor final class SpeechSourceModel: ObservableObject {
      init(holder: any SettingsHolding, catalog: [LocalModel] = ModelCatalog.all(kind: .tts))
      let holder: any SettingsHolding
      @Published var viewedTab: SpeechSource
      @Published var modelStates: [String: ModelState]
      var activeSource: SpeechSource { get }
      func activate(_ source: SpeechSource)
      func reveal(_ source: SpeechSource)
      func select(modelID: String)
      var ttsModels: [LocalModel] { get }
      var selectedModel: LocalModel? { get }
      var readiness: SpeechReadiness { get }
      var statusHeadline: String { get }
      var statusDetail: String { get }
      func name(of source: SpeechSource) -> String
      func adopt(_ rows: [ModelsViewModel.Row])
  }
  ```

- [ ] **Step 1: Write the failing test**

Create `macos/Tests/MacomprendoTests/UI/SpeechSourceModelTests.swift`:

```swift
import Foundation
import Testing
@testable import Macomprendo

@Suite @MainActor struct SpeechSourceModelTests {

    private func model(_ settings: Settings = .default,
                       catalog: [LocalModel] = []) -> SpeechSourceModel {
        SpeechSourceModel(holder: ScriptedSettingsHolder(settings), catalog: catalog)
    }

    // MARK: - Navigation is not selection

    @Test func theTabShownOnOpenIsTheActiveSource() {
        var settings = Settings.default
        settings.speech.source = .endpoint
        #expect(model(settings).viewedTab == .endpoint)

        settings.speech.source = .local
        #expect(model(settings).viewedTab == .local)
    }

    @Test func movingBetweenTabsChangesNothingButWhatIsOnScreen() {
        var settings = Settings.default
        settings.speech.source = .system
        let tab = model(settings)
        let before = tab.holder.settings

        tab.viewedTab = .local
        tab.viewedTab = .endpoint
        tab.viewedTab = .system

        #expect(tab.holder.settings == before)
        #expect(tab.holder.settings.speech.source == .system)
    }

    @Test func onlyTheSelectorChangesWhatSpeaks() {
        let tab = model()
        tab.viewedTab = .endpoint
        #expect(tab.activeSource == .system)

        tab.activate(.endpoint)
        #expect(tab.activeSource == .endpoint)
        #expect(tab.holder.settings.speech.source == .endpoint)
    }

    @Test func revealingASourceIsNavigationOnly() {
        let tab = model()
        tab.reveal(.local)
        #expect(tab.viewedTab == .local)
        #expect(tab.activeSource == .system)
    }

    // MARK: - Choosing a local voice

    @Test func choosingALocalModelRecordsItWithoutActivatingTheSource() {
        // Same separation as the endpoint sub-tab in Dictation: configuring is not activating.
        let tab = model(.default, catalog: [Self.piper])
        tab.select(modelID: "piper-ru")
        #expect(tab.holder.settings.speech.localModelID == "piper-ru")
        #expect(tab.activeSource == .system)
    }

    @Test func anUnknownModelIDIsIgnored() {
        let tab = model(.default, catalog: [Self.piper])
        tab.select(modelID: "not-in-the-catalog")
        #expect(tab.holder.settings.speech.localModelID == nil)
    }

    @Test func theCatalogListsTTSEntriesOnly() {
        let tab = SpeechSourceModel(holder: ScriptedSettingsHolder())
        #expect(tab.ttsModels.allSatisfy { $0.kind == .tts })
    }

    // MARK: - Status

    @Test func theStatusDescribesTheSelectedSourceNotTheViewedTab() {
        var settings = Settings.default
        settings.speech.source = .system
        let tab = model(settings, catalog: [Self.piper])

        tab.viewedTab = .local          // looking at a source that is not ready
        #expect(tab.readiness == .ready)
        #expect(tab.statusHeadline == "Ready to use")
        #expect(tab.statusDetail.contains("System voices"))
    }

    @Test func aNotReadySourceExplainsItselfInTheStatus() {
        var settings = Settings.default
        settings.speech.source = .local
        settings.speech.localModelID = "piper-ru"
        let tab = model(settings, catalog: [Self.piper])
        tab.modelStates = ["piper-ru": .notDownloaded]

        #expect(tab.statusHeadline == "Not ready")
        #expect(tab.statusDetail.contains("has not been downloaded"))
        #expect(tab.statusDetail.contains("Local TTS"))
    }

    @Test func adoptingRowsTracksADownloadInProgress() {
        var settings = Settings.default
        settings.speech.source = .local
        settings.speech.localModelID = "piper-ru"
        let tab = model(settings, catalog: [Self.piper])

        tab.adopt([ModelsViewModel.Row(model: Self.piper, state: .downloading(fraction: 0.5))])

        #expect(tab.readiness == .notReady(reason: "Downloading… 50%", fix: nil))
    }

    // MARK: - Fixtures

    private static let piper = LocalModel(
        id: "piper-ru",
        displayName: "Piper — Ruslan (Russian)",
        engine: .whisperCpp,      // replaced by .sherpaVits in Plan 2; kind is what matters here
        languages: ["ru"],
        files: [],
        brief: ModelBrief(summary: "", strengths: [], limitations: [], benchmarks: [],
                          sourceURL: URL(string: "https://example.com")!),
        speakerCount: 1,
        archiveSentinel: nil)
}
```

**Note for the implementer:** this task adds `speakerCount` and `archiveSentinel` to `LocalModel` (Step 3), which is what makes the fixture above compile — write Step 3's `LocalModel` change first if you prefer a compiling test file before running it. `LocalEngine` has no TTS case until Plan 2, so the fixture declares `.whisperCpp` and asserts on `kind` only where that is what matters.

- [ ] **Step 2: Run test to verify it fails**

Run: `npm run test:swift`
Expected: FAIL — `cannot find 'SpeechSourceModel' in scope`.

- [ ] **Step 3: Write the implementation**

Create `macos/Sources/Macomprendo/UI/Settings/SpeechSourceModel.swift`:

```swift
import Foundation
import SwiftUI

/// The active-source selector, its status, and sub-tab navigation for Settings ▸ Speech.
///
/// Deliberately the same shape as `DictationTabModel`: the selector is the only control that
/// changes what speaks, and moving between sub-tabs writes nothing. `SpeechTabModel` keeps the
/// things that are about voices rather than about sources — the system voice catalog, the
/// audition phrases and the Keychain write.
@MainActor
final class SpeechSourceModel: ObservableObject {
    /// Which sub-tab is on screen. Pure view state.
    @Published var viewedTab: SpeechSource
    /// Download states for the TTS catalog, adopted from the live `ModelsViewModel` rows so
    /// readiness tracks a download in progress rather than whatever was true on open.
    @Published var modelStates: [String: ModelState] = [:]

    let holder: any SettingsHolding
    private let catalog: [LocalModel]

    init(holder: any SettingsHolding, catalog: [LocalModel] = ModelCatalog.all(kind: .tts)) {
        self.holder = holder
        self.catalog = catalog
        // Open where the active source lives. A read, not a write.
        viewedTab = holder.settings.speech.source
    }

    // MARK: - The selector

    var activeSource: SpeechSource { holder.settings.speech.source }

    /// The one control that changes what speaks.
    func activate(_ source: SpeechSource) {
        guard source != holder.settings.speech.source else { return }
        objectWillChange.send()
        holder.settings.speech.source = source
    }

    /// Brings a source's sub-tab into view so a fix button can point at the thing it is
    /// about. Navigation only — nothing is written.
    func reveal(_ source: SpeechSource) {
        viewedTab = source
    }

    // MARK: - The local catalog

    var ttsModels: [LocalModel] { catalog }

    var selectedModel: LocalModel? {
        guard let id = holder.settings.speech.localModelID else { return nil }
        return catalog.first { $0.id == id }
    }

    /// Records which local voice is configured. Configuring is not activating: the source
    /// becomes live only through `activate(_:)`.
    func select(modelID: String) {
        guard catalog.contains(where: { $0.id == modelID }) else { return }
        objectWillChange.send()
        holder.settings.speech.localModelID = modelID
    }

    // MARK: - Status

    var readiness: SpeechReadiness {
        SpeechReadiness.of(source: activeSource,
                           settings: holder.settings.speech,
                           modelStates: modelStates)
    }

    var statusHeadline: String {
        readiness == .ready ? "Ready to use" : "Not ready"
    }

    var statusDetail: String {
        switch readiness {
        case .ready:
            "\(name(of: activeSource)) will read your selection. Press the Speak hotkey to hear it."
        case .notReady(let reason, _):
            "\(reason) \(name(of: activeSource)) is the selected source, so the Speak hotkey "
                + "will report this instead of speaking."
        }
    }

    /// How a source is named in the selector and its status. The local source names the voice
    /// itself when one is chosen, because "Local TTS" alone does not say what will be heard.
    func name(of source: SpeechSource) -> String {
        switch source {
        case .system, .endpoint:
            return source.displayName
        case .local:
            guard let model = selectedModel else { return source.displayName }
            return "\(source.displayName) · \(model.displayName)"
        }
    }

    /// Takes the download states straight from the live `ModelsViewModel` rows.
    func adopt(_ rows: [ModelsViewModel.Row]) {
        modelStates = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.state) })
    }
}
```

Also add to `LocalModel` in `ModelCatalog.swift`, below `brief`:

```swift
    /// How many speakers the model exposes; 1 for the single-speaker Piper voices and for
    /// every ASR entry, which has no such concept. The Local tab offers a speaker picker
    /// only above 1.
    let speakerCount: Int
    /// For a model downloaded as an archive: the path inside the unpacked directory that
    /// proves the unpack succeeded. `nil` for a model stored as loose files.
    let archiveSentinel: String?
```

and give both a default in a memberwise initialiser written out explicitly (a struct with defaults needs one, since the compiler-generated memberwise init cannot be called with the new arguments omitted from the existing literals):

```swift
    init(id: String,
         displayName: String,
         engine: LocalEngine,
         languages: [String]?,
         files: [ModelFile],
         brief: ModelBrief,
         speakerCount: Int = 1,
         archiveSentinel: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.engine = engine
        self.languages = languages
        self.files = files
        self.brief = brief
        self.speakerCount = speakerCount
        self.archiveSentinel = archiveSentinel
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm run test:swift`
Expected: PASS, 11 new tests, and the existing catalog literals still compile.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources macos/Tests
git commit -m "feat(speech): add the active-source selector model"
```

---

### Task 7: Rebuild `SpeechTab` around the selector

The view work. `SpeechTabModel` is untouched; the view is restructured to `DictationTab`'s layout and the three sub-tabs get their own `@ViewBuilder` sections.

**Files:**
- Modify: `macos/Sources/Macomprendo/UI/Settings/SpeechTab.swift` (the `struct SpeechTab: View` half, lines 141-312; leave `SpeechTabModel` above it alone)
- Modify: `macos/Sources/Macomprendo/UI/Settings/SettingsView.swift:12` (pass the new model)
- Modify: `macos/Sources/Macomprendo/App/AppModel.swift` (own a `speechSourceModel`; find the `speechTabModel` property and mirror it)

**Interfaces:**
- Consumes: `SpeechSourceModel` (Task 6), `SpeechTabModel` (unchanged), `ModelsViewModel` (for the download rows), `SpeechFixAction` (Task 4).
- Produces: `SpeechTab(model:source:models:app:)`.

- [ ] **Step 1: Add the view model to `AppModel`**

`ttsModelsViewModel` already exists from Task 5. Add the selector model beside `speechTabModel` at `macos/Sources/Macomprendo/App/AppModel.swift:32`:

```swift
    lazy var speechSourceModel = SpeechSourceModel(holder: self)
```

- [ ] **Step 2: Rebuild the view body**

Replace `SpeechTab`'s `body` with the Dictation layout:

```swift
struct SpeechTab: View {
    @ObservedObject var model: SpeechTabModel
    @ObservedObject var source: SpeechSourceModel
    @ObservedObject var models: ModelsViewModel
    @ObservedObject var app: AppModel
    @FocusState private var apiKeyFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal)
                .padding(.vertical, 10)

            Divider()

            Picker("", selection: $source.viewedTab) {
                ForEach(SpeechSource.allCases) { candidate in
                    Text(candidate.displayName).tag(candidate)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top])

            Form {
                switch source.viewedTab {
                case .system: systemSection
                case .local: localSection
                case .endpoint: endpointSection
                }
                footerSection
            }
            .formStyle(.grouped)
        }
        .task {
            await models.refresh()
            source.adopt(models.rows)
        }
        .onChange(of: models.rows) { _, rows in source.adopt(rows) }
    }
```

- [ ] **Step 3: Add the header and status block**

```swift
    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            Picker("Active speech source", selection: activeSource) {
                ForEach(SpeechSource.allCases) { candidate in
                    Text(source.name(of: candidate)).tag(candidate)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            statusBlock
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var isReady: Bool { source.readiness == .ready }

    /// The only status on this screen, and it describes the selection rather than whichever
    /// sub-tab happens to be open — for the reason the Dictation tab gives: two status blocks
    /// answer "what happens on the hotkey" twice with no way to tell which answer is real.
    private var statusBlock: some View {
        HStack(alignment: .top, spacing: 8) {
            Icon(isReady ? .success : .warning, size: 14)
                .foregroundStyle(isReady ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.statusHeadline)
                    .font(.callout.weight(.semibold))
                Text(source.statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            fixButton
        }
    }

    @ViewBuilder
    private var fixButton: some View {
        if case .notReady(_, let fix) = source.readiness, let fix {
            switch fix {
            case .downloadModel(let id):
                Button("Download") {
                    source.reveal(.local)
                    models.download(id)
                }
            case .selectModel:
                Button("Choose a voice") { source.reveal(.local) }
            case .fillEndpoint:
                Button("Configure") { source.reveal(.endpoint) }
            case .saveKey:
                Button("Add a key") {
                    source.reveal(.endpoint)
                    apiKeyFocused = true
                }
            }
        }
    }

    private var activeSource: Binding<SpeechSource> {
        Binding(get: { source.activeSource }, set: { source.activate($0) })
    }
```

- [ ] **Step 4: Move the existing sections into `Section` wrappers**

`systemSection` keeps every control it has today (default-voice list, segmentation toggle and its explanation, per-language pickers, the rate/pitch/volume grid) — wrap its contents in `Section("System voices") { ... }` so it sits correctly inside the `Form`. `endpointSection` likewise becomes `Section("Endpoint") { ... }`, keeps its fields, and its `SecureField` gains `.focused($apiKeyFocused)`.

The footer moves into the form as its own section:

```swift
    private var footerSection: some View {
        Section {
            TextField("Preview text", text: $app.settings.speech.previewText, axis: .vertical)
                .lineLimit(2...4)
            Toggle("Play a sample when a voice is selected",
                   isOn: $app.settings.speech.auditionOnSelect)
            HStack {
                Button("Preview") { model.preview() }
                Button("Reload voices") { model.reload() }
                Spacer()
                Text("Hotkey ⌥S reads the current selection; press it again to stop.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Preview")
        } footer: {
            Text("Preview speaks through the active source, so it is what the hotkey will sound like.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
```

- [ ] **Step 5: Write the Local TTS section**

```swift
    private var localSection: some View {
        Section("Voices") {
            if source.ttsModels.isEmpty {
                Text("No local voices are available in this build yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(source.ttsModels) { entry in
                localVoiceRow(entry)
            }

            Text("A local voice reads everything in its own voice. Switching voices for "
                 + "mixed-language text is a System voices feature.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let selected = source.selectedModel {
            Section("Parameters") {
                if selected.speakerCount > 1 {
                    Picker("Speaker", selection: $app.settings.speech.localSpeakerID) {
                        ForEach(0..<selected.speakerCount, id: \.self) { id in
                            Text("Speaker \(id)").tag(id)
                        }
                    }
                }
                HStack {
                    Text("Speed")
                    Slider(value: $app.settings.speech.localSpeed, in: 0.5...2.0)
                }
            }
        }
    }

    @ViewBuilder
    private func localVoiceRow(_ entry: LocalModel) -> some View {
        let state = models.rows.first { $0.id == entry.id }?.state
        let chosen = app.settings.speech.localModelID == entry.id

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.displayName)
                            .fontWeight(chosen ? .semibold : .regular)
                        if chosen { chosenBadge }
                    }
                    Text("\(ModelsViewModel.sizeText(entry.totalSizeBytes)) · "
                         + DictationTabModel.languagesText(entry.languages))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    if !chosen, case .downloaded = state {
                        Button("Use this voice") { source.select(modelID: entry.id) }
                    }
                    localStateView(entry.id, state)
                }
            }
            ModelBriefView(brief: entry.brief)
        }
        .padding(.vertical, 4)
    }

    private var chosenBadge: some View {
        Text("Chosen")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
    }

    @ViewBuilder
    private func localStateView(_ id: String, _ state: ModelState?) -> some View {
        switch state {
        case .none:
            EmptyView()
        case .notDownloaded:
            Button("Download") { models.download(id) }
        case .downloading(let fraction):
            HStack(spacing: 8) {
                ProgressView(value: fraction).frame(width: 90)
                Button("Cancel") { models.cancelDownload(id) }
            }
        case .downloaded:
            HStack(spacing: 8) {
                Label { Text("Downloaded") } icon: { Icon(.success, size: 14) }
                    .foregroundStyle(.green)
                Button("Delete", role: .destructive) { Task { await models.delete(id) } }
            }
        case .failed(let message):
            HStack(spacing: 8) {
                Label { Text(message) } icon: { Icon(.warning, size: 14) }
                    .foregroundStyle(.red)
                    .lineLimit(2)
                Button("Retry") { models.download(id) }
            }
        }
    }
```

**Important:** `models` here is `AppModel.ttsModelsViewModel`, created in Task 5 — the ASR `modelsViewModel` is filtered to `kind: .asr` by Task 2 and would list no TTS rows at all.

- [ ] **Step 6: Wire it up in `SettingsView`**

```swift
            SpeechTab(model: AppRoot.model.speechTabModel,
                      source: AppRoot.model.speechSourceModel,
                      models: AppRoot.model.ttsModelsViewModel,
                      app: AppRoot.model)
                .tabItem { Label { Text("Speech") } icon: { Icon(.speak, size: 16) } }
```

- [ ] **Step 7: Build and run the suite**

Run: `swift build --package-path macos && npm run test:swift`
Expected: build succeeds with no new warnings; all tests pass.

- [ ] **Step 8: Look at it**

Run: `npm run gen && open macos/Macomprendo.xcodeproj` — or build and launch the app per `.agents/skills/macomprendo-build-test/SKILL.md`. Open Settings ▸ Speech and confirm by eye: the selector and one status block sit above three sub-tabs; switching tabs does not change the selector; the System tab looks the way it did before; the Local tab says no voices are available yet; the Endpoint tab's fields are all present. Capture a screenshot for the review.

- [ ] **Step 9: Commit**

```bash
git add macos/Sources
git commit -m "feat(speech): rebuild the Speech tab around an active-source selector"
```

---

### Task 8: Documentation and changelog

**Files:**
- Modify: `CHANGELOG.md` (the `Unreleased` section)
- Modify: `docs/SMOKE_TEST.md`
- Modify: `docs/ARCHITECTURE.md` (the Speech section, if it describes the two-source tab)

- [ ] **Step 1: Add the changelog entry**

Under `## [Unreleased]` → `### Changed`:

```markdown
- Settings ▸ Speech now has an active-source selector with an explicit readiness status above
  three sub-tabs — System voices, Local TTS and Endpoint — matching Settings ▸ Dictation.
  Moving between sub-tabs no longer changes which source speaks.
- The Speak hotkey reports why it cannot speak instead of failing silently when the selected
  source is not ready.
```

- [ ] **Step 2: Add the smoke tests**

Append to the Speech section of `docs/SMOKE_TEST.md`:

```markdown
- [ ] Settings ▸ Speech: switching sub-tabs leaves the selector and the status block unchanged.
- [ ] Selecting Endpoint with no saved API key shows "Not ready" and an "Add a key" button that
      opens the Endpoint tab with the key field focused.
- [ ] With Local TTS selected and no voice chosen, ⌥S shows a toast naming the problem and
      speaks nothing.
- [ ] Preview speaks through the active source, not through the viewed tab.
```

- [ ] **Step 3: Verify the project file is in sync**

Run: `npm run gen && git status --short macos/Macomprendo.xcodeproj`
Expected: no changes. If the regenerated project differs, commit it.

- [ ] **Step 4: Run everything**

Run: `npm run test:swift && npm run test:scripts && swift build --package-path macos`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add CHANGELOG.md docs macos
git commit -m "docs(speech): document the three-source Speech tab"
```

---

## What Plan 2 picks up

Left deliberately undone here, and specified in the spec's § Delivery: the `.archive` file role, `ArchiveExtracting` and the `LocalModelManager` unpack step, `SherpaTTSService`, `SpeechRouter`'s third branch, and the eight catalog entries with real SHA-256 digests. After Plan 1 the Local TTS tab is honest and empty; after Plan 2 it has voices.
