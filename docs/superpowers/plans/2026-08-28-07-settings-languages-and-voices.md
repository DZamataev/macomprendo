# Settings rework: languages, voices, dock icon, panel playback — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Refine, Summarize and Speech a persisted working language with its own prompt
set and voice map, fold the Models tab into Dictation, show hotkeys in the menubar menu, show
a Dock icon while a real window is open, and let the Quick Panel play, pause and stop speech.

**Architecture:** Everything hangs off two new pieces of persisted state — `Settings.promptLanguage`
and `SpeechSettings.voiceByLanguage` — plus two new OS-facing protocols (`LanguageDetecting`,
`ActivationPolicyControlling`) with fakes. Factory prompt presets stop being a hand-written list
and become the cross product of a `Role` enum and a `PromptLanguage` enum, with one content file
per language and deterministic UUIDs so the eleven IDs already shipped keep their values.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI + AppKit, swift-testing, AVFoundation
(`AVSpeechSynthesizer`, `AVAudioPlayer`), NaturalLanguage (`NLLanguageRecognizer`),
`KeyboardShortcuts` package, Node ≥ 20 for `npm run sync-icons`.

**Spec:** `docs/superpowers/specs/2026-08-28-settings-languages-and-voices-design.md`

## Global Constraints

- macOS 14+, Swift 6 strict concurrency. Providers are `Sendable`; controllers are `@MainActor`.
- Layers point downward: UI → Features → Services/Providers → Core. Concrete services are only
  constructed in `AppEnvironment`.
- Everything OS-facing sits behind a protocol declared next to its default implementation, with
  a double in `macos/Tests/MacomprendoTests/Fakes`.
- TDD: the failing test is written and run before the implementation. Hardware-bound glue
  (`AVSpeechSynthesizer`, `AVAudioPlayer`, `NSApp`, `NSWindow`) stays thin and is covered by
  `docs/SMOKE_TEST.md` instead.
- Secrets never leave the Keychain; transcript and LLM text are never logged at default level.
- Every user-visible failure is a `MacomprendoError` with `errorDescription` and
  `recoverySuggestion`.
- Icons come from `Icon(.case)`. A new icon means: add it to
  `macos/Sources/Macomprendo/Resources/Icons/icons.json`, run `npm run sync-icons`, add the
  `AppIcon` case **and** its `fallbackSymbol`, and commit the SVG.
- `macos/project.yml` is the source of truth for the Xcode project. No file added by this plan
  needs a `project.yml` edit — it already points at `Sources/Macomprendo` — but **xcodegen
  expands that directory into an explicit file list in the generated `.xcodeproj`**, so any
  task that CREATES a source or test file must run `npm run gen` and commit the regenerated
  project in the same commit. `git diff --exit-code macos/Macomprendo.xcodeproj` after
  `npm run gen` is the check. `swift test` uses `Package.swift` and passes either way, so a
  stale project only surfaces in an Xcode or Release build — verify it explicitly rather than
  inferring it from a green test run.
- Commands: `npm run test:swift`, `npm run test:scripts`, `swift build --package-path macos`.
- Conventional commit messages.
- **No settings migration.** The app has not shipped. A document written by an older build
  decodes missing keys to their defaults and re-seeds; losing old presets is acceptable.
- The seven prompt languages, in this order, with these slots — this ordering is frozen because
  it determines preset UUIDs: `en` `0000`, `ru` `0001`, `es` `0002`, `de` `0003`, `fr` `0004`,
  `pt` `0005`, `zh` `0006`.

## File Structure

**Created**

| File | Responsibility |
|---|---|
| `macos/Sources/Macomprendo/Features/Prompts/PromptLanguage.swift` | The seven languages: code, UUID slot, endonym, OS-language default. Sits beside `PromptPreset`, which is where `PresetKind` already lives even though `Core/Settings.swift` references it. |
| `macos/Sources/Macomprendo/Features/Prompts/Factory/FactoryPresetContent.swift` | The per-language content record: one system prompt plus a name and template per role. |
| `macos/Sources/Macomprendo/Features/Prompts/Factory/FactoryPresets+English.swift` … `+Chinese.swift` | Seven content files, one per language. |
| `macos/Sources/Macomprendo/Services/LanguageDetector.swift` | `LanguageDetecting` + `NLLanguageDetector`. |
| `macos/Sources/Macomprendo/Services/ActivationPolicyService.swift` | `ActivationPolicyControlling` + `NSAppActivationPolicy`. |
| `macos/Sources/Macomprendo/Features/DockIconCoordinator.swift` | Ref-counted owner set deciding whether the Dock icon is visible. |
| `macos/Tests/MacomprendoTests/Fakes/ScriptedLanguageDetector.swift` | Scripted detector. |
| `macos/Tests/MacomprendoTests/Fakes/FakeActivationPolicy.swift` | Records `setDockIconVisible` calls. |
| `macos/Tests/MacomprendoTests/Features/PromptLanguageTests.swift`, `DockIconCoordinatorTests.swift` | |
| `macos/Tests/MacomprendoTests/Services/LanguageDetectorTests.swift` | |
| `macos/Tests/MacomprendoTests/UI/MenuBarLabelTests.swift` | |

**Modified**

| File | Change |
|---|---|
| `Core/Settings.swift` | Schema v2: `promptLanguage`, `seededPromptLanguages`, `defaultPresetIDs`; the three removed keys; new `SpeechSettings` fields. |
| `Features/Prompts/PromptPreset.swift` | `language` field, hand-written `init(from:)`, language-aware accessors. |
| `Features/Prompts/FactoryPresets.swift` | Becomes the Role × Language assembler. |
| `Services/LanguageSegmenter.swift` | `letterCount` becomes internal. |
| `Services/SpeechService.swift` | Detector-driven `utterancePlan`, `pause`/`resume`/`isPaused`. |
| `Services/SpeechRouter.swift`, `Services/EndpointSpeechService.swift`, `Services/AudioPlayer.swift` | Pause/resume plumbing. |
| `Services/HotkeyService.swift` | `HotkeyAction.menuLabel`. |
| `Features/SpeakController.swift` | `SpeakSource`, pause/stop, HUD suppression for panel playback. |
| `Features/RefineController.swift`, `Features/SummarizeController.swift` | `SettingsHolding` instead of a read-only closure; `promptLanguage`. |
| `App/AppEnvironment.swift`, `App/TextFeatures.swift`, `App/MacomprendoApp.swift` | Wiring. |
| `UI/MenuBar/MenuBarView.swift`, `UI/Settings/SettingsView.swift`, `UI/Settings/DictationTab.swift`, `UI/Settings/SpeechTab.swift`, `UI/Settings/PromptsTab.swift`, `UI/QuickPanel/*.swift`, `UI/Onboarding/OnboardingWindowController.swift`, `UI/Components/Icon.swift` | UI. |
| `Resources/Icons/icons.json` | `pause`, `globe`. |

**Deleted:** `UI/Settings/ModelsTab.swift`.

---

### Task 1: `PromptLanguage`

Pure, additive, nothing else depends on it yet.

**Files:**
- Create: `macos/Sources/Macomprendo/Features/Prompts/PromptLanguage.swift`
- Test: `macos/Tests/MacomprendoTests/Features/PromptLanguageTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum PromptLanguage: String, CaseIterable, Sendable, Identifiable` with cases
  `english russian spanish german french portuguese chinese`; `var code: String`,
  `var slot: String`, `var displayName: String`, `static var systemDefault: PromptLanguage`,
  `static func named(_ code: String) -> PromptLanguage?`.

- [ ] **Step 1: Write the failing test**

Create `macos/Tests/MacomprendoTests/Features/PromptLanguageTests.swift`:

```swift
import Foundation
import Testing
@testable import Macomprendo

@Suite struct PromptLanguageTests {
    @Test func codesAndSlotsAreFrozenInOrder() {
        #expect(PromptLanguage.allCases.map(\.code) == ["en", "ru", "es", "de", "fr", "pt", "zh"])
        #expect(PromptLanguage.allCases.map(\.slot) == ["0000", "0001", "0002", "0003", "0004", "0005", "0006"])
    }

    @Test func slotsAreFourHexDigitsAndUnique() {
        let slots = PromptLanguage.allCases.map(\.slot)
        #expect(Set(slots).count == slots.count)
        #expect(slots.allSatisfy { $0.count == 4 && $0.allSatisfy(\.isHexDigit) })
    }

    @Test func displayNamesAreEndonyms() {
        #expect(PromptLanguage.allCases.map(\.displayName)
                == ["English", "Русский", "Español", "Deutsch", "Français", "Português", "中文"])
    }

    @Test func namedResolvesKnownCodesOnly() {
        #expect(PromptLanguage.named("ru") == .russian)
        #expect(PromptLanguage.named("zh") == .chinese)
        #expect(PromptLanguage.named("ru-RU") == nil)
        #expect(PromptLanguage.named("uk") == nil)
    }

    @Test func systemDefaultIsAlwaysOneOfTheSeven() {
        #expect(PromptLanguage.allCases.contains(PromptLanguage.systemDefault))
    }

    @Test func resolvingALocaleFallsBackToEnglish() {
        #expect(PromptLanguage.resolve(languageCode: "de") == .german)
        #expect(PromptLanguage.resolve(languageCode: "uk") == .english)
        #expect(PromptLanguage.resolve(languageCode: nil) == .english)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm run test:swift`
Expected: FAIL — `cannot find 'PromptLanguage' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `macos/Sources/Macomprendo/Features/Prompts/PromptLanguage.swift`:

```swift
import Foundation

/// The languages the factory prompt set ships in. The order and the slots are frozen: the
/// slot is part of every factory preset's UUID, so renumbering would orphan stored presets.
///
/// Declared beside `PromptPreset` rather than in `Core` for the same reason `PresetKind` is:
/// `Core/Settings.swift` already stores prompt types by value.
enum PromptLanguage: String, CaseIterable, Sendable, Identifiable {
    case english = "en"
    case russian = "ru"
    case spanish = "es"
    case german = "de"
    case french = "fr"
    case portuguese = "pt"
    case chinese = "zh"

    var id: String { rawValue }

    /// The base BCP-47 code stored in `PromptPreset.language` and `Settings.promptLanguage`.
    var code: String { rawValue }

    /// The four hex digits this language contributes to a factory preset's UUID.
    var slot: String {
        switch self {
        case .english: "0000"
        case .russian: "0001"
        case .spanish: "0002"
        case .german: "0003"
        case .french: "0004"
        case .portuguese: "0005"
        case .chinese: "0006"
        }
    }

    /// The endonym: the picker lists a language the way its own speakers write it, so it is
    /// readable to the person who wants it regardless of the app's UI language.
    var displayName: String {
        switch self {
        case .english: "English"
        case .russian: "Русский"
        case .spanish: "Español"
        case .german: "Deutsch"
        case .french: "Français"
        case .portuguese: "Português"
        case .chinese: "中文"
        }
    }

    /// Exact match on a base code. Region-qualified tags ("ru-RU") are deliberately rejected;
    /// callers strip the region first.
    static func named(_ code: String) -> PromptLanguage? { PromptLanguage(rawValue: code) }

    /// The shipped language for a base code, falling back to English for anything unsupported.
    static func resolve(languageCode: String?) -> PromptLanguage {
        guard let languageCode else { return .english }
        return named(languageCode) ?? .english
    }

    /// The language a fresh install starts in.
    static var systemDefault: PromptLanguage {
        resolve(languageCode: Locale.current.language.languageCode?.identifier)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm run test:swift`
Expected: PASS, no new warnings from `swift build --package-path macos`.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Macomprendo/Features/Prompts/PromptLanguage.swift macos/Tests/MacomprendoTests/Features/PromptLanguageTests.swift
git commit -m "feat(prompts): add PromptLanguage with frozen codes and UUID slots"
```

---

### Task 2: Settings schema v2 — language-aware presets

The whole schema change lands at once; it cannot be half-applied. `FactoryPresets` keeps its
literal English content in this task and is restructured in Task 3.

**Files:**
- Modify: `macos/Sources/Macomprendo/Core/Settings.swift`
- Modify: `macos/Sources/Macomprendo/Features/Prompts/PromptPreset.swift`
- Modify: `macos/Sources/Macomprendo/Features/Prompts/FactoryPresets.swift`
- Modify: `macos/Sources/Macomprendo/UI/Settings/PromptsTab.swift`
- Modify: `macos/Sources/Macomprendo/Features/RefineController.swift:runStream`,
  `macos/Sources/Macomprendo/Features/SummarizeController.swift:start`
- Modify: `macos/Sources/Macomprendo/UI/QuickPanel/QuickPanelView.swift`
- Modify: `macos/Tests/MacomprendoTests/Fakes/ScriptedSettingsHolder.swift`
- Test: `macos/Tests/MacomprendoTests/Core/SettingsTests.swift`,
  `macos/Tests/MacomprendoTests/Features/PresetStoreTests.swift`

**Interfaces:**
- Consumes: `PromptLanguage` (Task 1).
- Produces:
  - `PromptPreset.language: String`, and `init(id:kind:language:name:systemPrompt:userTemplate:isFactory:sortOrder:)`
  - `Settings.promptLanguage: String`, `Settings.seededPromptLanguages: [String]`,
    `Settings.defaultPresetIDs: [String: UUID]`
  - `Settings.presetKey(_ kind: PresetKind, _ language: String) -> String`
  - `Settings.presets(of:language:) -> [PromptPreset]`,
    `Settings.defaultPresetID(for:language:) -> UUID?`,
    `Settings.defaultPreset(for:language:) -> PromptPreset?`,
    `Settings.setDefaultPreset(id:for:language:)`
  - `SpeechSettings.voiceByLanguage: [String: String]`, `.segmentationEnabled: Bool`,
    `.previewText: String`, `.auditionOnSelect: Bool`
  - `FactoryPresets.seed(into:)` and `.restoreMissing(into:)` keep their names and become
    language-aware.

- [ ] **Step 1: Write the failing tests**

Append to `macos/Tests/MacomprendoTests/Core/SettingsTests.swift`:

```swift
@Suite struct SettingsSchemaV2Tests {
    @Test func defaultsCarryTheNewKeys() {
        let d = Settings.default
        #expect(Settings.currentSchemaVersion == 2)
        #expect(d.promptLanguage == PromptLanguage.systemDefault.code)
        #expect(d.seededPromptLanguages.isEmpty)
        #expect(d.defaultPresetIDs.isEmpty)
        #expect(d.speech.voiceByLanguage.isEmpty)
        #expect(d.speech.segmentationEnabled)
        #expect(d.speech.auditionOnSelect)
        #expect(d.speech.previewText.contains("Macomprendo"))
    }

    @Test func previewTextIsMixedScriptSoItDemonstratesSegmentation() {
        let text = SpeechSettings().previewText
        let scripts = Set(LanguageSegmenter.runs(in: text).map(\.script))
        #expect(scripts.contains(.latin))
        #expect(scripts.contains(.cyrillic))
    }

    @Test func aDocumentWithoutTheNewKeysDecodesToDefaults() throws {
        let json = Data(#"{"schemaVersion":1}"#.utf8)
        let settings = try Settings.migrate(json)
        #expect(settings.schemaVersion == 2)
        #expect(settings.promptLanguage == PromptLanguage.systemDefault.code)
        #expect(settings.seededPromptLanguages.isEmpty)
        #expect(settings.speech.segmentationEnabled)
    }

    @Test func aPresetWithoutALanguageDecodesAsEnglish() throws {
        let json = Data("""
            {"id":"F0000000-0000-0000-0000-000000000001","kind":"refine","name":"Clean up",
             "systemPrompt":"s","userTemplate":"{text}","isFactory":true,"sortOrder":0}
            """.utf8)
        let preset = try JSONDecoder().decode(PromptPreset.self, from: json)
        #expect(preset.language == "en")
    }

    @Test func newKeysSurviveARoundTrip() throws {
        var settings = Settings.default
        settings.promptLanguage = "ru"
        settings.seededPromptLanguages = ["en", "ru"]
        settings.defaultPresetIDs = [Settings.presetKey(.refine, "ru"): FactoryPresets.ID.cleanUp]
        settings.speech.voiceByLanguage = ["ru": "ru.milena", "en": "en.alex"]
        settings.speech.segmentationEnabled = false
        settings.speech.auditionOnSelect = false
        settings.speech.previewText = "hi"
        let data = try JSONEncoder().encode(settings)
        #expect(try Settings.migrate(data) == settings)
    }
}
```

Append to `macos/Tests/MacomprendoTests/Features/PresetStoreTests.swift`:

```swift
@Suite struct LanguageAwarePresetStoreTests {
    private func preset(_ kind: PresetKind, _ language: String, _ name: String) -> PromptPreset {
        PromptPreset(kind: kind, language: language, name: name, systemPrompt: "s",
                     userTemplate: "{text}", isFactory: false, sortOrder: 0)
    }

    @Test func presetsAreFilteredByKindAndLanguage() {
        var s = Settings.default
        s.presets = []
        s.addPreset(preset(.refine, "en", "A"))
        s.addPreset(preset(.refine, "ru", "Б"))
        s.addPreset(preset(.summarize, "ru", "В"))
        #expect(s.presets(of: .refine, language: "en").map(\.name) == ["A"])
        #expect(s.presets(of: .refine, language: "ru").map(\.name) == ["Б"])
        #expect(s.presets(of: .summarize, language: "ru").map(\.name) == ["В"])
        #expect(s.presets(of: .summarize, language: "en").isEmpty)
    }

    @Test func sortOrderIsNumberedWithinOneKindAndLanguage() {
        var s = Settings.default
        s.presets = []
        let first = s.addPreset(preset(.refine, "ru", "1"))
        let second = s.addPreset(preset(.refine, "ru", "2"))
        let other = s.addPreset(preset(.refine, "en", "x"))
        #expect(first.sortOrder == 0)
        #expect(second.sortOrder == 1)
        #expect(other.sortOrder == 0)
    }

    @Test func eachKindAndLanguageKeepsItsOwnDefault() {
        var s = Settings.default
        s.presets = []
        let en = s.addPreset(preset(.refine, "en", "A"))
        let ru = s.addPreset(preset(.refine, "ru", "Б"))
        #expect(s.defaultPreset(for: .refine, language: "en")?.id == en.id)
        #expect(s.defaultPreset(for: .refine, language: "ru")?.id == ru.id)
        let second = s.addPreset(preset(.refine, "ru", "Г"))
        s.setDefaultPreset(id: second.id, for: .refine, language: "ru")
        #expect(s.defaultPreset(for: .refine, language: "ru")?.id == second.id)
        #expect(s.defaultPreset(for: .refine, language: "en")?.id == en.id)
    }

    @Test func aDanglingDefaultFallsBackToTheFirstOfThatLanguage() {
        var s = Settings.default
        s.presets = []
        let first = s.addPreset(preset(.refine, "ru", "Б"))
        s.defaultPresetIDs[Settings.presetKey(.refine, "ru")] = UUID()
        #expect(s.defaultPreset(for: .refine, language: "ru")?.id == first.id)
    }

    @Test func theLastPresetOfAKindAndLanguageCannotBeDeleted() {
        var s = Settings.default
        s.presets = []
        let only = s.addPreset(preset(.refine, "ru", "Б"))
        s.addPreset(preset(.refine, "en", "A"))
        #expect(throws: PresetError.lastOfKind(.refine)) { try s.deletePreset(id: only.id) }
    }

    @Test func deletingTheDefaultPromotesTheNextOfTheSameLanguage() throws {
        var s = Settings.default
        s.presets = []
        let first = s.addPreset(preset(.refine, "ru", "Б"))
        let second = s.addPreset(preset(.refine, "ru", "Г"))
        try s.deletePreset(id: first.id)
        #expect(s.defaultPreset(for: .refine, language: "ru")?.id == second.id)
    }

    @Test func movingReordersOnlyWithinOneLanguage() {
        var s = Settings.default
        s.presets = []
        let a = s.addPreset(preset(.refine, "ru", "1"))
        let b = s.addPreset(preset(.refine, "ru", "2"))
        let en = s.addPreset(preset(.refine, "en", "x"))
        s.movePreset(id: b.id, to: 0)
        #expect(s.presets(of: .refine, language: "ru").map(\.id) == [b.id, a.id])
        #expect(s.preset(id: en.id)?.sortOrder == 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npm run test:swift`
Expected: FAIL — the compiler rejects `presets(of:language:)`, `presetKey`, the new
`PromptPreset` initialiser, and the new `SpeechSettings` members.

- [ ] **Step 3: Add `language` to `PromptPreset`**

In `macos/Sources/Macomprendo/Features/Prompts/PromptPreset.swift`, add the stored property and
widen the initialiser:

```swift
struct PromptPreset: Codable, Sendable, Identifiable, Equatable {
    var id: UUID
    var kind: PresetKind
    /// Base language code from `PromptLanguage`. Decides which set the preset belongs to.
    var language: String
    var name: String
    var systemPrompt: String
    /// Must contain "{text}". May also contain "{instruction}" and "{language}".
    var userTemplate: String
    var isFactory: Bool
    var sortOrder: Int

    init(id: UUID = UUID(), kind: PresetKind, language: String = PromptLanguage.english.code,
         name: String, systemPrompt: String, userTemplate: String, isFactory: Bool, sortOrder: Int) {
        self.id = id
        self.kind = kind
        self.language = language
        self.name = name
        self.systemPrompt = systemPrompt
        self.userTemplate = userTemplate
        self.isFactory = isFactory
        self.sortOrder = sortOrder
    }
}

extension PromptPreset {
    /// Hand-written so a preset stored before languages existed decodes as English instead of
    /// throwing. In an extension so the struct keeps its memberwise initialiser — the pattern
    /// `Settings` and `SpeechSettings` already use.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(PresetKind.self, forKey: .kind)
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? PromptLanguage.english.code
        name = try c.decode(String.self, forKey: .name)
        systemPrompt = try c.decode(String.self, forKey: .systemPrompt)
        userTemplate = try c.decode(String.self, forKey: .userTemplate)
        isFactory = try c.decode(Bool.self, forKey: .isFactory)
        sortOrder = try c.decode(Int.self, forKey: .sortOrder)
    }
}
```

- [ ] **Step 4: Make the `Settings` preset accessors language-aware**

Replace the whole `extension Settings` block at the bottom of `PromptPreset.swift` with:

```swift
extension Settings {
    /// Key for `defaultPresetIDs`, e.g. "refine.ru".
    static func presetKey(_ kind: PresetKind, _ language: String) -> String {
        "\(kind.rawValue).\(language)"
    }

    /// Presets of one kind and language, ordered by `sortOrder` (ties keep storage order).
    func presets(of kind: PresetKind, language: String) -> [PromptPreset] {
        presets.enumerated()
            .filter { $0.element.kind == kind && $0.element.language == language }
            .sorted { ($0.element.sortOrder, $0.offset) < ($1.element.sortOrder, $1.offset) }
            .map(\.element)
    }

    func preset(id: UUID) -> PromptPreset? { presets.first { $0.id == id } }

    func defaultPresetID(for kind: PresetKind, language: String) -> UUID? {
        defaultPresetIDs[Settings.presetKey(kind, language)]
    }

    /// The configured default, or the first preset of that kind and language when the ID is
    /// missing or dangling.
    func defaultPreset(for kind: PresetKind, language: String) -> PromptPreset? {
        if let id = defaultPresetID(for: kind, language: language), let found = preset(id: id),
           found.kind == kind, found.language == language {
            return found
        }
        return presets(of: kind, language: language).first
    }

    mutating func setDefaultPreset(id: UUID, for kind: PresetKind, language: String) {
        defaultPresetIDs[Settings.presetKey(kind, language)] = id
    }

    /// Appends the preset at the end of its kind *and* language, and returns the stored value.
    @discardableResult
    mutating func addPreset(_ preset: PromptPreset) -> PromptPreset {
        var stored = preset
        stored.sortOrder = (presets(of: stored.kind, language: stored.language)
            .map(\.sortOrder).max() ?? -1) + 1
        presets.append(stored)
        if defaultPresetID(for: stored.kind, language: stored.language) == nil {
            setDefaultPreset(id: stored.id, for: stored.kind, language: stored.language)
        }
        return stored
    }

    mutating func updatePreset(_ preset: PromptPreset) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index] = preset
    }

    /// The "at least one must remain" rule is scoped to a kind *and* language: deleting the
    /// last Russian refine preset would leave that language unusable even though English
    /// still has seven.
    mutating func deletePreset(id: UUID) throws {
        guard let victim = preset(id: id) else { throw PresetError.notFound }
        guard presets(of: victim.kind, language: victim.language).count > 1 else {
            throw PresetError.lastOfKind(victim.kind)
        }
        presets.removeAll { $0.id == id }
        if defaultPresetID(for: victim.kind, language: victim.language) == id,
           let replacement = presets(of: victim.kind, language: victim.language).first {
            setDefaultPreset(id: replacement.id, for: victim.kind, language: victim.language)
        }
    }

    /// Moves a preset within its own kind and language and renumbers that group 0..<n.
    mutating func movePreset(id: UUID, to index: Int) {
        guard let moved = preset(id: id) else { return }
        var ordered = presets(of: moved.kind, language: moved.language)
        guard let from = ordered.firstIndex(where: { $0.id == id }) else { return }
        let item = ordered.remove(at: from)
        ordered.insert(item, at: min(max(index, 0), ordered.count))
        for (newOrder, preset) in ordered.enumerated() {
            guard let slot = presets.firstIndex(where: { $0.id == preset.id }) else { continue }
            presets[slot].sortOrder = newOrder
        }
    }
}
```

- [ ] **Step 5: Change the `Settings` document**

In `macos/Sources/Macomprendo/Core/Settings.swift`:

Add to `SpeechSettings` (stored properties, memberwise defaults, and `init(from:)`):

```swift
    static let defaultPreviewText =
        "Macomprendo can read your selected text out loud. "
        + "Макомпрендо читает выделенный текст вслух."

    /// Base language code → voice identifier. An absent key means "pick automatically".
    var voiceByLanguage: [String: String]
    var segmentationEnabled: Bool
    var previewText: String
    var auditionOnSelect: Bool
```

with initialiser defaults `voiceByLanguage: [:]`, `segmentationEnabled: true`,
`previewText: SpeechSettings.defaultPreviewText`, `auditionOnSelect: true`, and in `init(from:)`:

```swift
        voiceByLanguage = try c.decodeIfPresent([String: String].self, forKey: .voiceByLanguage)
            ?? d.voiceByLanguage
        segmentationEnabled = try c.decodeIfPresent(Bool.self, forKey: .segmentationEnabled)
            ?? d.segmentationEnabled
        previewText = try c.decodeIfPresent(String.self, forKey: .previewText) ?? d.previewText
        auditionOnSelect = try c.decodeIfPresent(Bool.self, forKey: .auditionOnSelect)
            ?? d.auditionOnSelect
```

In `Settings`: bump `currentSchemaVersion` to `2`; delete `presetsSeeded`,
`defaultRefinePresetID` and `defaultSummarizePresetID` (property, `default` value and
`init(from:)` line for each); add

```swift
    /// The working language for Refine & Summarize.
    var promptLanguage: String
    /// Languages whose factory presets have already been seeded.
    var seededPromptLanguages: [String]
    /// Key: `Settings.presetKey(kind, language)`.
    var defaultPresetIDs: [String: UUID]
```

with `default` values `promptLanguage: PromptLanguage.systemDefault.code`,
`seededPromptLanguages: []`, `defaultPresetIDs: [:]`, and in `init(from:)`:

```swift
        promptLanguage = try c.decodeIfPresent(String.self, forKey: .promptLanguage) ?? d.promptLanguage
        seededPromptLanguages = try c.decodeIfPresent([String].self, forKey: .seededPromptLanguages)
            ?? d.seededPromptLanguages
        defaultPresetIDs = try c.decodeIfPresent([String: UUID].self, forKey: .defaultPresetIDs)
            ?? d.defaultPresetIDs
```

- [ ] **Step 6: Make `FactoryPresets` language-aware without changing its content yet**

In `macos/Sources/Macomprendo/Features/Prompts/FactoryPresets.swift`, pass
`language: PromptLanguage.english.code` in `make(...)`, and replace `seed`/`restoreMissing`:

```swift
    /// Seeds every language that has not been seeded yet. Adding a language later is one new
    /// content file plus one enum case — this loop then picks it up on the next launch.
    static func seed(into settings: inout Settings) {
        for language in PromptLanguage.allCases
        where !settings.seededPromptLanguages.contains(language.code) {
            let seeded = presets(for: language)
            // A language with no content is not "seeded": marking it so would permanently
            // suppress its presets once the content arrives.
            guard !seeded.isEmpty else { continue }
            for preset in seeded { settings.addPreset(preset) }
            settings.seededPromptLanguages.append(language.code)
        }
    }

    /// Re-adds factory presets the user deleted, in every language, and repairs a dangling
    /// default for every kind × language pair. Existing presets are never modified.
    static func restoreMissing(into settings: inout Settings) {
        let existing = Set(settings.presets.map(\.id))
        for factory in all() where !existing.contains(factory.id) { settings.addPreset(factory) }
        for language in PromptLanguage.allCases {
            // Same rule as `seed`: a language only counts as seeded once it actually holds
            // presets. Marking an empty language seeded would suppress its content forever.
            let hasPresets = PresetKind.allCases.contains {
                !settings.presets(of: $0, language: language.code).isEmpty
            }
            if hasPresets, !settings.seededPromptLanguages.contains(language.code) {
                settings.seededPromptLanguages.append(language.code)
            }
            for kind in PresetKind.allCases {
                let current = settings.defaultPresetID(for: kind, language: language.code)
                if current == nil || settings.preset(id: current!) == nil,
                   let first = settings.presets(of: kind, language: language.code).first {
                    settings.setDefaultPreset(id: first.id, for: kind, language: language.code)
                }
            }
        }
    }
```

Until Task 3 lands, add a temporary bridge so this compiles with English-only content:

```swift
    /// Replaced by the Role × Language assembler in Task 3.
    static func presets(for language: PromptLanguage) -> [PromptPreset] {
        language == .english ? all() : []
    }
```

- [ ] **Step 7: Update the call sites**

- `PromptsTabModel`: add `@Published private(set) var language: PromptLanguage = .english`
  (its writer arrives in Task 6, so no `didSet` here),
  change `var presets` to `holder.settings.presets(of: kind, language: language.code)`,
  `var defaultPresetID` to `holder.settings.defaultPresetID(for: kind, language: language.code)`,
  `makeDefault()` to `setDefaultPreset(id: id, for: kind, language: language.code)`, and
  `add()`/`duplicate()` to stamp `language: language.code`. In `init`, set
  `language = PromptLanguage.resolve(languageCode: holder.settings.promptLanguage)` before the
  first `select(...)`.
- `RefineController.runStream`: `current.defaultPreset(for: .refine, language: current.promptLanguage)`
  and the same language in the `chosen` guard.
- `RefineController.beginRefine` and `SummarizeController.start`:
  `settings().defaultPreset(for: <kind>, language: settings().promptLanguage)?.id`.
- `SummarizeController.runStream`: the same two changes as `RefineController.runStream`.
- `QuickPanelView`: `app.settings.presets(of: .refine, language: app.settings.promptLanguage)`
  and the summarize equivalent.
- `ScriptedSettingsHolder.seeded()`: replace `s.presetsSeeded = false` with
  `s.seededPromptLanguages = []`.
- Every existing test that referenced `presetsSeeded`, `defaultRefinePresetID`,
  `defaultSummarizePresetID`, `presets(of:)` or `defaultPreset(for:)` gets the language
  argument (`"en"` unless the test is about another language).

- [ ] **Step 8: Run tests to verify they pass**

Run: `npm run test:swift && swift build --package-path macos`
Expected: PASS, no new warnings.

- [ ] **Step 9: Commit**

```bash
git add macos/Sources/Macomprendo macos/Tests/MacomprendoTests
git commit -m "feat(settings): schema v2 with language-scoped prompt presets"
```

---

### Task 3: Factory presets as Role × Language, English content extracted

**Files:**
- Create: `macos/Sources/Macomprendo/Features/Prompts/Factory/FactoryPresetContent.swift`
- Create: `macos/Sources/Macomprendo/Features/Prompts/Factory/FactoryPresets+English.swift`
- Modify: `macos/Sources/Macomprendo/Features/Prompts/FactoryPresets.swift`
- Test: `macos/Tests/MacomprendoTests/Features/FactoryPresetsTests.swift`

**Interfaces:**
- Consumes: `PromptLanguage` (Task 1), `PromptPreset.language` (Task 2).
- Produces:
  - `FactoryPresets.Role: String, CaseIterable, Sendable` with `var kind: PresetKind` and
    `var slot: String`
  - `FactoryPresets.presetID(role:language:) -> UUID`
  - `FactoryPresets.presets(for: PromptLanguage) -> [PromptPreset]` (replaces the Task 2 bridge)
  - `struct FactoryPresetContent: Sendable` with `systemPrompt: String` and
    `entries: [FactoryPresets.Role: Entry]`, `struct Entry: Sendable { var name: String; var template: String }`
  - `PromptLanguage.content: FactoryPresetContent`
  - `FactoryPresets.ID` is deleted; `defaultRefineID`/`defaultSummarizeID` are deleted (the
    default now falls out of insertion order in `addPreset`).

- [ ] **Step 1: Write the failing test**

Replace the body of `macos/Tests/MacomprendoTests/Features/FactoryPresetsTests.swift` with:

```swift
import Foundation
import Testing
@testable import Macomprendo

@Suite struct FactoryPresetsTests {
    /// Every language must cover every role. `entries` is a dictionary, so this test is the
    /// thing that catches a forgotten role in a new content file.
    @Test func everyLanguageCoversEveryRole() {
        for language in PromptLanguage.allCases {
            let roles = Set(language.content.entries.keys)
            #expect(roles == Set(FactoryPresets.Role.allCases),
                    "\(language.code) is missing \(Set(FactoryPresets.Role.allCases).subtracting(roles))")
        }
    }

    @Test func roleSlotsAreTwelveHexDigitsAndUnique() {
        let slots = FactoryPresets.Role.allCases.map(\.slot)
        #expect(slots.count == 12)
        #expect(Set(slots).count == 12)
        #expect(slots.allSatisfy { $0.count == 12 && $0.allSatisfy(\.isHexDigit) })
    }

    @Test func englishIDsAreUnchangedFromTheShippedValues() {
        func id(_ role: FactoryPresets.Role) -> UUID {
            FactoryPresets.presetID(role: role, language: .english)
        }
        #expect(id(.cleanUp) == UUID(uuidString: "F0000000-0000-0000-0000-000000000001"))
        #expect(id(.formal) == UUID(uuidString: "F0000000-0000-0000-0000-000000000002"))
        #expect(id(.casual) == UUID(uuidString: "F0000000-0000-0000-0000-000000000003"))
        #expect(id(.shorten) == UUID(uuidString: "F0000000-0000-0000-0000-000000000004"))
        #expect(id(.expand) == UUID(uuidString: "F0000000-0000-0000-0000-000000000005"))
        #expect(id(.fixGrammar) == UUID(uuidString: "F0000000-0000-0000-0000-000000000006"))
        #expect(id(.translate) == UUID(uuidString: "F0000000-0000-0000-0000-000000000007"))
        #expect(id(.brief) == UUID(uuidString: "F0000000-0000-0000-0000-000000000101"))
        #expect(id(.bullets) == UUID(uuidString: "F0000000-0000-0000-0000-000000000102"))
        #expect(id(.tldr) == UUID(uuidString: "F0000000-0000-0000-0000-000000000103"))
        #expect(id(.keyActions) == UUID(uuidString: "F0000000-0000-0000-0000-000000000104"))
    }

    @Test func translateAndOrganizeIsTheOneNewEnglishID() {
        #expect(FactoryPresets.presetID(role: .translateAndOrganize, language: .english)
                == UUID(uuidString: "F0000000-0000-0000-0000-000000000008"))
    }

    @Test func idsAreUniqueAcrossTheWholeSet() {
        let ids = FactoryPresets.all().map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func everyPresetIsValidAndCarriesItsLanguage() {
        for language in PromptLanguage.allCases {
            let presets = FactoryPresets.presets(for: language)
            #expect(presets.count == 12)
            for preset in presets {
                #expect(preset.language == language.code)
                #expect(preset.isFactory)
                #expect(PromptRenderer.validate(preset).isEmpty,
                        "\(language.code)/\(preset.name): \(PromptRenderer.validate(preset))")
                #expect(preset.userTemplate.contains("{text}"))
            }
        }
    }

    /// The OS language is only meaningful for plain Translate. Every other template either
    /// preserves the original language or names its target literally.
    @Test func onlyTranslateUsesTheLanguagePlaceholder() {
        for language in PromptLanguage.allCases {
            for role in FactoryPresets.Role.allCases {
                let template = language.content.entries[role]!.template
                #expect(template.contains("{language}") == (role == .translate),
                        "\(language.code)/\(role.rawValue)")
            }
        }
    }

    @Test func rolesSplitEightRefineAndFourSummarize() {
        #expect(FactoryPresets.Role.allCases.filter { $0.kind == .refine }.count == 8)
        #expect(FactoryPresets.Role.allCases.filter { $0.kind == .summarize }.count == 4)
    }

    @Test func sortOrderRestartsAtZeroForEachKind() {
        let presets = FactoryPresets.presets(for: .english)
        #expect(presets.filter { $0.kind == .refine }.map(\.sortOrder) == Array(0..<8))
        #expect(presets.filter { $0.kind == .summarize }.map(\.sortOrder) == Array(0..<4))
    }

    @Test func seedFillsEveryLanguageOnceAndSetsPerLanguageDefaults() {
        var s = Settings.default
        s.presets = []
        s.seededPromptLanguages = []
        FactoryPresets.seed(into: &s)
        #expect(s.presets.count == 12 * PromptLanguage.allCases.count)
        #expect(s.seededPromptLanguages == PromptLanguage.allCases.map(\.code))
        for language in PromptLanguage.allCases {
            #expect(s.defaultPreset(for: .refine, language: language.code)?.id
                    == FactoryPresets.presetID(role: .cleanUp, language: language))
            #expect(s.defaultPreset(for: .summarize, language: language.code)?.id
                    == FactoryPresets.presetID(role: .brief, language: language))
        }
        let before = s
        FactoryPresets.seed(into: &s)
        #expect(s == before)
    }

    @Test func restoreMissingBringsBackADeletedFactoryPresetInItsOwnLanguage() throws {
        var s = Settings.default
        s.presets = []
        s.seededPromptLanguages = []
        FactoryPresets.seed(into: &s)
        let victim = FactoryPresets.presetID(role: .bullets, language: .russian)
        try s.deletePreset(id: victim)
        #expect(s.preset(id: victim) == nil)
        FactoryPresets.restoreMissing(into: &s)
        #expect(s.preset(id: victim)?.language == "ru")
        #expect(s.presets.count == 12 * PromptLanguage.allCases.count)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npm run test:swift`
Expected: FAIL — `FactoryPresets.Role`, `presetID(role:language:)` and `PromptLanguage.content`
do not exist.

- [ ] **Step 3: Create the content record**

Create `macos/Sources/Macomprendo/Features/Prompts/Factory/FactoryPresetContent.swift`:

```swift
import Foundation

/// One language's factory prompt content. `entries` is keyed by role; completeness is enforced
/// by `FactoryPresetsTests.everyLanguageCoversEveryRole` rather than by the type system,
/// because a dictionary literal keeps the content files flat and readable.
struct FactoryPresetContent: Sendable {
    struct Entry: Sendable {
        var name: String
        var template: String
    }

    var systemPrompt: String
    var entries: [FactoryPresets.Role: Entry]
}

extension PromptLanguage {
    var content: FactoryPresetContent {
        switch self {
        case .english: .english
        // Only English has content in this task. Task 4 splits `.russian` out and Task 5 the
        // remaining five, so the build stays green at every step and no language is ever
        // left without content.
        case .russian, .spanish, .german, .french, .portuguese, .chinese: .english
        }
    }
}
```

Write exactly the switch above — do not add the other six cases yet, they have nothing to
point at. The `everyLanguageCoversEveryRole` test passes throughout, and
`onlyTranslateUsesTheLanguagePlaceholder` passes too because English satisfies it.

- [ ] **Step 4: Rewrite `FactoryPresets` as the assembler**

Replace the whole of `macos/Sources/Macomprendo/Features/Prompts/FactoryPresets.swift`:

```swift
import Foundation

/// The presets shipped with the app. They are seeded once per language into `Settings.presets`
/// and are ordinary user data afterwards: editable, reorderable and deletable.
///
/// A preset's UUID is derived from its role and language rather than written by hand, so
/// `restoreMissing(into:)` can still tell "deleted factory preset" from "custom preset" across
/// seven languages. English is slot `0000`, which keeps the eleven IDs that shipped before
/// languages existed at exactly the values they had.
enum FactoryPresets {
    enum Role: String, CaseIterable, Sendable {
        case cleanUp, formal, casual, shorten, expand, fixGrammar, translate, translateAndOrganize
        case brief, bullets, tldr, keyActions

        var kind: PresetKind {
            switch self {
            case .cleanUp, .formal, .casual, .shorten, .expand, .fixGrammar, .translate,
                 .translateAndOrganize:
                .refine
            case .brief, .bullets, .tldr, .keyActions:
                .summarize
            }
        }

        /// The twelve hex digits this role contributes to a factory preset's UUID.
        var slot: String {
            switch self {
            case .cleanUp: "000000000001"
            case .formal: "000000000002"
            case .casual: "000000000003"
            case .shorten: "000000000004"
            case .expand: "000000000005"
            case .fixGrammar: "000000000006"
            case .translate: "000000000007"
            case .translateAndOrganize: "000000000008"
            case .brief: "000000000101"
            case .bullets: "000000000102"
            case .tldr: "000000000103"
            case .keyActions: "000000000104"
            }
        }
    }

    /// Deterministic and total: both slots are compile-time constants of the right width, so
    /// the string always parses.
    static func presetID(role: Role, language: PromptLanguage) -> UUID {
        UUID(uuidString: "F0000000-0000-0000-\(language.slot)-\(role.slot)")!
    }

    static func all() -> [PromptPreset] {
        PromptLanguage.allCases.flatMap { presets(for: $0) }
    }

    /// One language's twelve presets, `sortOrder` restarting at 0 for each kind.
    static func presets(for language: PromptLanguage) -> [PromptPreset] {
        let content = language.content
        var orders: [PresetKind: Int] = [:]
        return Role.allCases.compactMap { role in
            guard let entry = content.entries[role] else { return nil }
            let order = orders[role.kind, default: 0]
            orders[role.kind] = order + 1
            return PromptPreset(id: presetID(role: role, language: language),
                                kind: role.kind,
                                language: language.code,
                                name: entry.name,
                                systemPrompt: content.systemPrompt,
                                userTemplate: entry.template,
                                isFactory: true,
                                sortOrder: order)
        }
    }

    /// Seeds every language that has not been seeded yet. Adding a language later is one new
    /// content file plus one enum case — this loop then picks it up on the next launch.
    static func seed(into settings: inout Settings) {
        for language in PromptLanguage.allCases
        where !settings.seededPromptLanguages.contains(language.code) {
            let seeded = presets(for: language)
            // A language with no content is not "seeded": marking it so would permanently
            // suppress its presets once the content arrives.
            guard !seeded.isEmpty else { continue }
            for preset in seeded { settings.addPreset(preset) }
            settings.seededPromptLanguages.append(language.code)
        }
    }

    /// Re-adds factory presets the user deleted, in every language, and repairs a dangling
    /// default for every kind × language pair. Existing presets are never modified.
    static func restoreMissing(into settings: inout Settings) {
        let existing = Set(settings.presets.map(\.id))
        for factory in all() where !existing.contains(factory.id) { settings.addPreset(factory) }
        for language in PromptLanguage.allCases {
            // Same rule as `seed`: a language only counts as seeded once it actually holds
            // presets. Marking an empty language seeded would suppress its content forever.
            let hasPresets = PresetKind.allCases.contains {
                !settings.presets(of: $0, language: language.code).isEmpty
            }
            if hasPresets, !settings.seededPromptLanguages.contains(language.code) {
                settings.seededPromptLanguages.append(language.code)
            }
            for kind in PresetKind.allCases {
                let current = settings.defaultPresetID(for: kind, language: language.code)
                if current == nil || settings.preset(id: current!) == nil,
                   let first = settings.presets(of: kind, language: language.code).first {
                    settings.setDefaultPreset(id: first.id, for: kind, language: language.code)
                }
            }
        }
    }
}
```

- [ ] **Step 5: Write the English content file**

Create `macos/Sources/Macomprendo/Features/Prompts/Factory/FactoryPresets+English.swift`:

```swift
import Foundation

extension FactoryPresetContent {
    static let english = FactoryPresetContent(
        systemPrompt: """
            You are a careful writing assistant. Process the user's text exactly as instructed. \
            Return only the resulting text — no commentary, no explanation, no quotation marks \
            around the output and no markdown code fences.
            """,
        entries: [
            .cleanUp: .init(name: "Clean up", template: """
                Clean up the following text. Remove filler words, false starts and stutters, and \
                fix punctuation and capitalization. Keep the meaning, the tone and the original language.
                {instruction}

                {text}
                """),
            .formal: .init(name: "Formal", template: """
                Rewrite the following text in a formal, professional register. Keep the meaning \
                and the original language.
                {instruction}

                {text}
                """),
            .casual: .init(name: "Casual", template: """
                Rewrite the following text in a relaxed, conversational register. Keep the meaning \
                and the original language.
                {instruction}

                {text}
                """),
            .shorten: .init(name: "Shorten", template: """
                Rewrite the following text so it is significantly shorter while keeping every \
                important point. Keep the original language.
                {instruction}

                {text}
                """),
            .expand: .init(name: "Expand", template: """
                Expand the following text with more detail and clearer structure. Do not invent \
                facts. Keep the original language.
                {instruction}

                {text}
                """),
            .fixGrammar: .init(name: "Fix grammar", template: """
                Correct spelling, grammar and punctuation in the following text. Change nothing \
                else — keep the wording, the tone and the original language.
                {instruction}

                {text}
                """),
            .translate: .init(name: "Translate", template: """
                Translate the following text into {language}. Preserve the tone and the formatting.
                {instruction}

                {text}
                """),
            .translateAndOrganize: .init(name: "Translate & organize", template: """
                Translate the following text into English, then organize the result: group \
                related points together, add short headings or a list where they make the text \
                easier to follow, and remove repetition. Do not invent facts and do not drop \
                information.
                {instruction}

                {text}
                """),
            .brief: .init(name: "Brief", template: """
                Summarize the following text in two or three sentences. Write the summary in the \
                language of the text.
                {instruction}

                {text}
                """),
            .bullets: .init(name: "Bullets", template: """
                Summarize the following text as at most six concise bullet points, one line each, \
                each starting with "- ". Write them in the language of the text.
                {instruction}

                {text}
                """),
            .tldr: .init(name: "TL;DR", template: """
                Give a one-sentence TL;DR of the following text, in the language of the text.
                {instruction}

                {text}
                """),
            .keyActions: .init(name: "Key actions", template: """
                List the concrete action items in the following text as a numbered list, in the \
                language of the text. If there are none, answer exactly "No action items."
                {instruction}

                {text}
                """),
        ])
}
```

- [ ] **Step 6: Delete the Task 2 bridge**

Remove the temporary `presets(for:)` bridge added in Task 2 Step 6 — Step 4 above replaced it.
Also delete every remaining reference to `FactoryPresets.ID`, `defaultRefineID` and
`defaultSummarizeID`; in tests, replace them with `FactoryPresets.presetID(role:language:)`.

- [ ] **Step 7: Run tests to verify they pass**

Run: `npm run test:swift && swift build --package-path macos`
Expected: PASS. `everyLanguageCoversEveryRole` passes because the six unwritten languages still
resolve to the English content.

- [ ] **Step 8: Commit**

```bash
git add macos/Sources/Macomprendo/Features/Prompts macos/Tests/MacomprendoTests/Features/FactoryPresetsTests.swift
git commit -m "feat(prompts): derive factory presets from role and language"
```

---

### Task 4: Russian content

The worked example for every translated set: same twelve roles, same placeholders, prose
written natively rather than transliterated from English.

**Files:**
- Create: `macos/Sources/Macomprendo/Features/Prompts/Factory/FactoryPresets+Russian.swift`
- Modify: `macos/Sources/Macomprendo/Features/Prompts/Factory/FactoryPresetContent.swift`
- Test: `macos/Tests/MacomprendoTests/Features/FactoryPresetsTests.swift` (add one test)

**Interfaces:**
- Consumes: `FactoryPresetContent`, `FactoryPresets.Role` (Task 3).
- Produces: `FactoryPresetContent.russian`.

- [ ] **Step 1: Write the failing test**

Add to `FactoryPresetsTests`:

```swift
    @Test func russianContentIsWrittenInRussian() {
        let content = PromptLanguage.russian.content
        #expect(content.systemPrompt != PromptLanguage.english.content.systemPrompt)
        for role in FactoryPresets.Role.allCases {
            let entry = content.entries[role]!
            #expect(entry.template.contains(where: { LanguageSegmenter.script(of: $0) == .cyrillic }),
                    "ru/\(role.rawValue) has no Cyrillic text")
        }
        #expect(content.entries[.translateAndOrganize]!.name == "Перевести и систематизировать")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm run test:swift`
Expected: FAIL — Russian still resolves to the English content, so `systemPrompt` matches
English and the Cyrillic assertion fails.

- [ ] **Step 3: Write the Russian content file**

Create `macos/Sources/Macomprendo/Features/Prompts/Factory/FactoryPresets+Russian.swift`:

```swift
import Foundation

extension FactoryPresetContent {
    static let russian = FactoryPresetContent(
        systemPrompt: """
            Ты внимательный помощник по работе с текстом. Обработай текст пользователя ровно так, \
            как сказано в инструкции. Верни только результат — без комментариев, без пояснений, \
            без кавычек вокруг результата и без markdown-ограждений.
            """,
        entries: [
            .cleanUp: .init(name: "Причесать", template: """
                Приведи следующий текст в порядок. Убери слова-паразиты, оборванные начала и \
                запинки, исправь пунктуацию и заглавные буквы. Сохрани смысл, тон и язык оригинала.
                {instruction}

                {text}
                """),
            .formal: .init(name: "Официально", template: """
                Перепиши следующий текст в официальном, деловом стиле. Сохрани смысл и язык оригинала.
                {instruction}

                {text}
                """),
            .casual: .init(name: "Неформально", template: """
                Перепиши следующий текст в свободном, разговорном стиле. Сохрани смысл и язык оригинала.
                {instruction}

                {text}
                """),
            .shorten: .init(name: "Сократить", template: """
                Перепиши следующий текст заметно короче, сохранив все важные мысли. Сохрани язык \
                оригинала.
                {instruction}

                {text}
                """),
            .expand: .init(name: "Развернуть", template: """
                Разверни следующий текст: добавь подробностей и более ясную структуру. Не выдумывай \
                фактов. Сохрани язык оригинала.
                {instruction}

                {text}
                """),
            .fixGrammar: .init(name: "Исправить грамматику", template: """
                Исправь орфографию, грамматику и пунктуацию в следующем тексте. Больше ничего не \
                меняй — сохрани формулировки, тон и язык оригинала.
                {instruction}

                {text}
                """),
            .translate: .init(name: "Перевести", template: """
                Переведи следующий текст на {language}. Сохрани тон и форматирование.
                {instruction}

                {text}
                """),
            .translateAndOrganize: .init(name: "Перевести и систематизировать", template: """
                Переведи следующий текст на русский, а затем систематизируй результат: сгруппируй \
                связанные мысли, добавь короткие заголовки или список там, где это облегчает чтение, \
                убери повторы. Не выдумывай фактов и не теряй информацию.
                {instruction}

                {text}
                """),
            .brief: .init(name: "Кратко", template: """
                Изложи следующий текст в двух-трёх предложениях. Пиши на языке исходного текста.
                {instruction}

                {text}
                """),
            .bullets: .init(name: "Списком", template: """
                Изложи следующий текст не более чем шестью краткими пунктами, по одной строке \
                каждый, каждый начинается с «- ». Пиши на языке исходного текста.
                {instruction}

                {text}
                """),
            .tldr: .init(name: "TL;DR", template: """
                Дай TL;DR следующего текста одним предложением, на языке исходного текста.
                {instruction}

                {text}
                """),
            .keyActions: .init(name: "Действия", template: """
                Выпиши конкретные задачи из следующего текста нумерованным списком, на языке \
                исходного текста. Если задач нет, ответь ровно «Задач нет».
                {instruction}

                {text}
                """),
        ])
}
```

- [ ] **Step 4: Point the switch at it**

In `FactoryPresetContent.swift`, split `.russian` out of the temporary group:

```swift
        case .russian: .russian
        case .spanish, .german, .french, .portuguese, .chinese: .english
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `npm run test:swift`
Expected: PASS, including `onlyTranslateUsesTheLanguagePlaceholder` — the Russian
`translateAndOrganize` names Russian literally and carries no `{language}`.

- [ ] **Step 6: Commit**

```bash
git add macos/Sources/Macomprendo/Features/Prompts/Factory macos/Tests/MacomprendoTests/Features/FactoryPresetsTests.swift
git commit -m "feat(prompts): add the Russian factory prompt set"
```

---

### Task 5: The five remaining content sets

Spanish, German, French, Portuguese and Chinese. One task rather than five, because the five
files are the same structure with different prose and are verified by one shared test.

**Files:**
- Create: `FactoryPresets+Spanish.swift`, `+German.swift`, `+French.swift`, `+Portuguese.swift`,
  `+Chinese.swift` under `macos/Sources/Macomprendo/Features/Prompts/Factory/`
- Modify: `macos/Sources/Macomprendo/Features/Prompts/Factory/FactoryPresetContent.swift`
- Test: `macos/Tests/MacomprendoTests/Features/FactoryPresetsTests.swift`

**Interfaces:**
- Consumes: `FactoryPresetContent`, `FactoryPresets.Role` (Task 3).
- Produces: `FactoryPresetContent.spanish`, `.german`, `.french`, `.portuguese`, `.chinese`.

**Preset names — the part that is not a mechanical translation:**

| Role | Español | Deutsch | Français | Português | 中文 |
|---|---|---|---|---|---|
| `cleanUp` | Limpiar | Aufräumen | Nettoyer | Limpar | 整理 |
| `formal` | Formal | Förmlich | Formel | Formal | 正式 |
| `casual` | Coloquial | Locker | Familier | Coloquial | 口语 |
| `shorten` | Acortar | Kürzen | Raccourcir | Encurtar | 缩短 |
| `expand` | Ampliar | Erweitern | Développer | Expandir | 扩展 |
| `fixGrammar` | Corregir gramática | Grammatik korrigieren | Corriger la grammaire | Corrigir gramática | 修正语法 |
| `translate` | Traducir | Übersetzen | Traduire | Traduzir | 翻译 |
| `translateAndOrganize` | Traducir y organizar | Übersetzen und ordnen | Traduire et organiser | Traduzir e organizar | 翻译并整理 |
| `brief` | Breve | Kurzfassung | Bref | Resumo | 简述 |
| `bullets` | Viñetas | Stichpunkte | Puces | Tópicos | 要点 |
| `tldr` | TL;DR | TL;DR | TL;DR | TL;DR | 一句话总结 |
| `keyActions` | Acciones clave | Aufgaben | Actions clés | Ações | 待办事项 |

**Template bodies:** translate the English body from
`FactoryPresets+English.swift` sentence for sentence into the file's language. Three rules bind
the translation, and each is enforced by a test:

1. `{text}`, `{instruction}` and the blank line between them are copied verbatim, never
   translated or reordered.
2. `translate` is the only template that keeps `{language}`.
3. `translateAndOrganize` names its own language literally — "al español", "ins Deutsche",
   "en français", "para português", "翻译成中文" — never through a placeholder.

The `systemPrompt` is likewise the English one translated, and must differ from the English
string.

> **Why this task states an instruction instead of quoting sixty templates.** Everywhere else
> this plan quotes the exact code to write. Here the deliverable *is* natural-language prose:
> quoting each translated template in the plan would duplicate, word for word, the file the
> task creates, in five languages. The parts that are decisions rather than translation — the
> preset names, the three binding rules, the source text — are all above, and the tests in
> Step 1 fail on any file that is left as English or loses a placeholder. Do not treat this as
> licence to improvise elsewhere in the plan.

- [ ] **Step 1: Write the failing test**

Replace `russianContentIsWrittenInRussian` in `FactoryPresetsTests` with a test covering every
translated language, and add the structural test:

```swift
    @Test func everyTranslatedSetIsWrittenNativelyAndKeepsItsNames() {
        let expectedTranslateAndOrganize: [PromptLanguage: String] = [
            .russian: "Перевести и систематизировать",
            .spanish: "Traducir y organizar",
            .german: "Übersetzen und ordnen",
            .french: "Traduire et organiser",
            .portuguese: "Traduzir e organizar",
            .chinese: "翻译并整理"
        ]
        for (language, name) in expectedTranslateAndOrganize {
            let content = language.content
            #expect(content.systemPrompt != PromptLanguage.english.content.systemPrompt,
                    "\(language.code) still uses the English system prompt")
            #expect(content.entries[.translateAndOrganize]!.name == name)
            for role in FactoryPresets.Role.allCases {
                let english = PromptLanguage.english.content.entries[role]!.template
                #expect(content.entries[role]!.template != english,
                        "\(language.code)/\(role.rawValue) is still the English template")
            }
        }
    }

    @Test func everyTemplateKeepsThePlaceholderBlockVerbatim() {
        for language in PromptLanguage.allCases {
            for role in FactoryPresets.Role.allCases {
                let template = language.content.entries[role]!.template
                #expect(template.hasSuffix("{instruction}\n\n{text}"),
                        "\(language.code)/\(role.rawValue) does not end with the placeholder block")
            }
        }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npm run test:swift`
Expected: FAIL — the five languages still resolve to the English content, so both the
`systemPrompt` and the per-role template comparisons match English.

- [ ] **Step 3: Write the five content files**

Each file mirrors `FactoryPresets+Russian.swift` exactly in shape:

```swift
import Foundation

extension FactoryPresetContent {
    static let spanish = FactoryPresetContent(
        systemPrompt: """
            <the English system prompt, in Spanish>
            """,
        entries: [
            .cleanUp: .init(name: "Limpiar", template: """
                <the English cleanUp body, in Spanish>
                {instruction}

                {text}
                """),
            // …the remaining eleven roles, names from the table above…
        ])
}
```

and likewise `german`, `french`, `portuguese`, `chinese`.

- [ ] **Step 4: Point the switch at them**

In `FactoryPresetContent.swift`, replace the temporary group with the real cases so the switch
reads:

```swift
        case .english: .english
        case .russian: .russian
        case .spanish: .spanish
        case .german: .german
        case .french: .french
        case .portuguese: .portuguese
        case .chinese: .chinese
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `npm run test:swift && swift build --package-path macos`
Expected: PASS — 84 presets, all valid, unique IDs, `{language}` only in the seven `translate`
templates.

- [ ] **Step 6: Commit**

```bash
git add macos/Sources/Macomprendo/Features/Prompts/Factory macos/Tests/MacomprendoTests/Features/FactoryPresetsTests.swift
git commit -m "feat(prompts): add the Spanish, German, French, Portuguese and Chinese prompt sets"
```

---

### Task 6: Language picker in Settings ▸ Refine & Summarize

`PromptsTabModel.language` was added in Task 2 Step 7; this task gives it a control and pins
its behaviour down with tests.

**Files:**
- Modify: `macos/Sources/Macomprendo/UI/Settings/PromptsTab.swift`
- Test: `macos/Tests/MacomprendoTests/UI/PromptsTabModelTests.swift`

**Interfaces:**
- Consumes: `PromptsTabModel.language: PromptLanguage`, `Settings.presets(of:language:)`.
- Produces: nothing new; `PromptsTabModel.language` is now also written by
  `PromptsTabModel.setLanguage(_:)`, which persists the choice.

- [ ] **Step 1: Write the failing test**

Add to `PromptsTabModelTests`:

```swift
    @Test func switchingLanguageShowsThatLanguagesPresetsAndPersistsTheChoice() {
        let holder = ScriptedSettingsHolder.seeded()
        holder.settings.promptLanguage = "en"
        let model = PromptsTabModel(holder: holder, llm: { _ in throw FeatureConfigError.noPreset(.refine) })
        #expect(model.presets.allSatisfy { $0.language == "en" })

        model.setLanguage(.russian)
        #expect(holder.settings.promptLanguage == "ru")
        #expect(model.presets.count == 8)
        #expect(model.presets.allSatisfy { $0.language == "ru" })
        #expect(model.selectedID == FactoryPresets.presetID(role: .cleanUp, language: .russian))
    }

    @Test func addingAPresetStampsTheShownLanguage() {
        let holder = ScriptedSettingsHolder.seeded()
        let model = PromptsTabModel(holder: holder, llm: { _ in throw FeatureConfigError.noPreset(.refine) })
        model.setLanguage(.german)
        model.add()
        #expect(model.draft?.language == "de")
        #expect(holder.settings.presets(of: .refine, language: "de").count == 9)
    }

    @Test func restoringFactoryPresetsCoversEveryLanguage() throws {
        let holder = ScriptedSettingsHolder.seeded()
        try holder.settings.deletePreset(id: FactoryPresets.presetID(role: .tldr, language: .french))
        let model = PromptsTabModel(holder: holder, llm: { _ in throw FeatureConfigError.noPreset(.refine) })
        model.restoreFactory()
        #expect(holder.settings.preset(id: FactoryPresets.presetID(role: .tldr, language: .french)) != nil)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npm run test:swift`
Expected: FAIL — `setLanguage` does not exist.

- [ ] **Step 3: Add `setLanguage` to the model**

In `PromptsTabModel`, make `language` private(set) and add the writer, so the choice always
reaches `Settings`:

```swift
    @Published private(set) var language: PromptLanguage = .english

    /// Persists the choice: the Quick Panel reads the same `Settings.promptLanguage`.
    func setLanguage(_ newValue: PromptLanguage) {
        guard newValue != language else { return }
        language = newValue
        holder.settings.promptLanguage = newValue.code
        select(presets.first?.id)
    }
```

- [ ] **Step 4: Add the picker to the view**

In `PromptsTab.body`, replace the standalone `Picker("Feature", …)` with a row holding both
controls, and re-key the models `task` so switching either one reloads:

```swift
            HStack(spacing: 12) {
                Picker("Feature", selection: $model.kind) {
                    ForEach(PresetKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)

                Picker("Language", selection: Binding(get: { model.language },
                                                      set: { model.setLanguage($0) })) {
                    ForEach(PromptLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .frame(width: 220)

                Spacer()
            }
```

and change the modifier to `.task(id: model.kind) { await model.loadModels() }` → unchanged
(the endpoint and model list are per kind, not per language).

- [ ] **Step 5: Run tests to verify they pass**

Run: `npm run test:swift && swift build --package-path macos`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add macos/Sources/Macomprendo/UI/Settings/PromptsTab.swift macos/Tests/MacomprendoTests/UI/PromptsTabModelTests.swift
git commit -m "feat(settings): pick the prompt language in Refine & Summarize"
```

---

### Task 7: Language switcher in the Quick Panel

**Files:**
- Modify: `macos/Sources/Macomprendo/Features/RefineController.swift`
- Modify: `macos/Sources/Macomprendo/Features/SummarizeController.swift`
- Modify: `macos/Sources/Macomprendo/App/TextFeatures.swift:live`
- Modify: `macos/Sources/Macomprendo/UI/QuickPanel/RefineLayout.swift`,
  `macos/Sources/Macomprendo/UI/QuickPanel/SummaryLayout.swift`
- Modify: `macos/Sources/Macomprendo/Resources/Icons/icons.json`,
  `macos/Sources/Macomprendo/UI/Components/Icon.swift`
- Modify: `macos/Tests/MacomprendoTests/App/TextFeaturesTests.swift:40,45`
- Test: `macos/Tests/MacomprendoTests/Features/RefineControllerTests.swift`,
  `macos/Tests/MacomprendoTests/Features/SummarizeControllerTests.swift`

**Interfaces:**
- Consumes: `SettingsHolding`, `ScriptedSettingsHolder`, `Settings.promptLanguage`.
- Produces:
  - `RefineController.init(capture:llm:panel:pasteboard:inserter:tracker:toaster:holder:)` —
    the trailing `settings:` closure becomes `holder: any SettingsHolding`
  - `SummarizeController.init(llm:panel:pasteboard:inserter:tracker:toaster:holder:)` — same
  - `RefineController.promptLanguage: String { get set }`,
    `SummarizeController.promptLanguage: String { get set }`
  - `AppIcon.globe`

- [ ] **Step 1: Write the failing test**

Add to `RefineControllerTests` (and the mirror image to `SummarizeControllerTests`, using
`summarize`, `.summarize` and `controller.summary`):

```swift
    @Test func switchingLanguagePersistsItPicksTheNewDefaultAndReruns() async {
        let holder = ScriptedSettingsHolder.seeded()
        holder.settings.promptLanguage = "en"
        let (controller, provider, _) = make(holder: holder)
        controller.start(source: .selection("hello"))
        await controller.drain()
        let runsBefore = provider.recorder.calls.count

        controller.promptLanguage = "ru"
        await controller.drain()

        #expect(holder.settings.promptLanguage == "ru")
        #expect(controller.selectedPresetID
                == FactoryPresets.presetID(role: .cleanUp, language: .russian))
        #expect(provider.recorder.calls.count > runsBefore)
        let sent = provider.recorder.calls.last!.messages
        #expect(sent.contains { $0.content.contains("Приведи следующий текст в порядок") })
    }

    @Test func settingTheSameLanguageDoesNotRerun() async {
        let holder = ScriptedSettingsHolder.seeded()
        holder.settings.promptLanguage = "ru"
        let (controller, provider, _) = make(holder: holder)
        controller.start(source: .selection("привет"))
        await controller.drain()
        let runs = provider.recorder.calls.count
        controller.promptLanguage = "ru"
        await controller.drain()
        #expect(provider.recorder.calls.count == runs)
    }
```

Update the suite's existing `make(...)` helper to take `holder: ScriptedSettingsHolder = .seeded()`
and pass it as the controller's `holder:` argument, and adjust every other test in the file that
constructed the controller with `settings: { … }`. `ScriptedLLMProvider` already records every
call through `recorder.calls` (`[ChatCall]`, each with `messages` and `model`), so no fake
needs changing — make sure the helper returns the provider so the test can read it.

- [ ] **Step 2: Run tests to verify they fail**

Run: `npm run test:swift`
Expected: FAIL — `RefineController` has no `holder:` parameter and no `promptLanguage`.

- [ ] **Step 3: Swap the settings closure for a holder**

In `RefineController`, replace `private let settings: @MainActor () -> Settings` with
`private let holder: any SettingsHolding`, change the initialiser parameter to
`holder: any SettingsHolding`, and replace every `settings()` call with `holder.settings`.
Then add:

```swift
    /// The working language for the whole Refine & Summarize feature. Writing it moves the
    /// selection to the new language's default preset and reruns, so one click reprocesses the
    /// same text with the other language's prompt set.
    var promptLanguage: String {
        get { holder.settings.promptLanguage }
        set {
            guard holder.settings.promptLanguage != newValue else { return }
            objectWillChange.send()
            holder.settings.promptLanguage = newValue
            selectedPresetID = holder.settings.defaultPreset(for: .refine, language: newValue)?.id
            rerun()
        }
    }
```

Do exactly the same in `SummarizeController`, with `.summarize` in the `defaultPreset` call.

In `TextFeatures.live`, replace `settings: { model.settings }` with `holder: model` for both
controllers. `SpeakController` keeps its `settings:` closure — it is not changed by this task.

`macos/Tests/MacomprendoTests/App/TextFeaturesTests.swift` also builds both controllers, at
lines 40 and 45: replace `settings: { holder.settings }` with `holder: holder` there. Line 47
builds the `SpeakController` and stays as it is.

- [ ] **Step 4: Add the globe icon**

Add `{ "name": "globe", "weight": "regular" }` to
`macos/Sources/Macomprendo/Resources/Icons/icons.json`, then:

```bash
npm run sync-icons
```

Add to `AppIcon`: `case globe = "globe"` and, in `fallbackSymbol`, `case .globe: return "globe"`.

- [ ] **Step 5: Add the switcher to both toolbars**

In `RefineLayout.toolbar`, insert before the preset `Picker`:

```swift
            Menu {
                ForEach(PromptLanguage.allCases) { language in
                    Button(language.displayName) { controller.promptLanguage = language.code }
                }
            } label: {
                Icon(.globe, size: 14)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Prompt language")
```

Insert the identical block into `SummaryLayout.toolbar`, after the `Icon(.summarize, size: 14)`
and before the preset `Picker`.

- [ ] **Step 6: Run tests to verify they pass**

Run: `npm run test:swift && npm run test:scripts && swift build --package-path macos`
Expected: PASS. `npm run test:scripts` covers `sync-icons`; confirm `git status` shows the new
`globe.svg` as added.

- [ ] **Step 7: Commit**

```bash
git add macos/Sources/Macomprendo macos/Tests/MacomprendoTests
git commit -m "feat(quick-panel): switch the prompt language from the panel"
```

---

### Task 8: Hotkeys in the menubar menu

**Files:**
- Modify: `macos/Sources/Macomprendo/Services/HotkeyService.swift`
- Modify: `macos/Sources/Macomprendo/UI/MenuBar/MenuBarView.swift`
- Test: `macos/Tests/MacomprendoTests/UI/MenuBarLabelTests.swift` (create)

**Interfaces:**
- Consumes: `HotkeyAction`, `KeyboardShortcuts.getShortcut(for:)`.
- Produces: `HotkeyAction.menuTrailing(shortcut: String?) -> String` and
  `HotkeyAction.currentShortcutText() -> String?` (the `@MainActor` bridge to the library).

- [ ] **Step 1: Write the failing test**

Create `macos/Tests/MacomprendoTests/UI/MenuBarLabelTests.swift`:

```swift
import Foundation
import Testing
@testable import Macomprendo

@Suite struct MenuBarLabelTests {
    @Test func aBoundShortcutIsShownAsIs() {
        #expect(HotkeyAction.dictate.menuTrailing(shortcut: "⌥Space") == "⌥Space")
        #expect(HotkeyAction.dictateAndRefine.menuTrailing(shortcut: "⌥⇧Space") == "⌥⇧Space")
    }

    @Test func anUnboundShortcutSaysSoRatherThanShowingNothing() {
        #expect(HotkeyAction.refineSelection.menuTrailing(shortcut: nil) == "not set")
        #expect(HotkeyAction.refineSelection.menuTrailing(shortcut: "") == "not set")
        #expect(HotkeyAction.refineSelection.menuTrailing(shortcut: "   ") == "not set")
    }

    @Test func everyActionStillHasADisplayName() {
        #expect(HotkeyAction.allCases.allSatisfy { !$0.displayName.isEmpty })
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm run test:swift`
Expected: FAIL — `value of type 'HotkeyAction' has no member 'menuTrailing'`.

- [ ] **Step 3: Add the formatting helpers**

In `macos/Sources/Macomprendo/Services/HotkeyService.swift`, extend `HotkeyAction`:

```swift
extension HotkeyAction {
    static let unboundShortcutText = "not set"

    /// The trailing text of this action's menu row. Pure, so it is unit-tested without
    /// AppKit or the KeyboardShortcuts package.
    func menuTrailing(shortcut: String?) -> String {
        let trimmed = (shortcut ?? "").trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? Self.unboundShortcutText : trimmed
    }

    /// The shortcut currently bound to this action, as the library renders it ("⌥Space").
    /// Read at menu-build time: `MenuBarExtra` re-evaluates its body every time the menu
    /// opens, so a shortcut rebound in Settings ▸ Hotkeys shows up on the next open. The
    /// library's `shortcutByNameDidChange` notification is internal and cannot be observed.
    @MainActor
    func currentShortcutText() -> String? {
        KeyboardShortcuts.getShortcut(for: .forAction(self))?.description
    }
}
```

- [ ] **Step 4: Show it in the menu**

In `macos/Sources/Macomprendo/UI/MenuBar/MenuBarView.swift`, replace the `ForEach` body:

```swift
        ForEach(HotkeyAction.allCases, id: \.self) { action in
            Toggle(isOn: Binding(
                get: { model.isEnabled(action) },
                set: { model.setEnabled(action, $0) })) {
                    HStack {
                        Text(action.displayName)
                        Spacer()
                        Text(action.menuTrailing(shortcut: action.currentShortcutText()))
                            .foregroundStyle(.secondary)
                    }
                }
        }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `npm run test:swift && swift build --package-path macos`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add macos/Sources/Macomprendo/Services/HotkeyService.swift macos/Sources/Macomprendo/UI/MenuBar/MenuBarView.swift macos/Tests/MacomprendoTests/UI/MenuBarLabelTests.swift
git commit -m "feat(menubar): show each action's current hotkey beside its checkmark"
```

---

### Task 9: Fold the Models tab into Dictation

**Files:**
- Delete: `macos/Sources/Macomprendo/UI/Settings/ModelsTab.swift`
- Modify: `macos/Sources/Macomprendo/UI/Settings/SettingsView.swift`
- Modify: `macos/Sources/Macomprendo/UI/Settings/DictationTab.swift`
- Test: `macos/Tests/MacomprendoTests/UI/ModelsViewModelTests.swift`

**Interfaces:**
- Consumes: `ModelsViewModel` (`rows`, `diskUsageText`, `sizeText(_:)`, `download(_:)`,
  `cancelDownload(_:)`, `delete(_:)`, `refresh()`), unchanged.
- Produces: nothing new. `ModelsTab` and `ModelsTabContent` cease to exist.

- [ ] **Step 1: Write the failing test**

`ModelsViewModel` does not change, so the test that must exist is about the caption
`DictationTab` shows for a model's state, which is currently the only prose that points at the
deleted tab. Extract it and test it. Add to `ModelsViewModelTests`:

```swift
    @Test func stateCaptionsNoLongerPointAtADeletedTab() {
        #expect(DictationTab.stateCaption(for: nil) == "Checking…")
        #expect(DictationTab.stateCaption(for: .notDownloaded)
                == "Not downloaded — download it under Speech models below.")
        #expect(DictationTab.stateCaption(for: .downloading(fraction: 0.42)) == "Downloading… 42%")
        #expect(DictationTab.stateCaption(for: .downloaded) == "Ready.")
        #expect(DictationTab.stateCaption(for: .failed("boom")) == "boom")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm run test:swift`
Expected: FAIL — `DictationTab` has no static `stateCaption(for:)`.

- [ ] **Step 3: Extract the caption and drop the cross-reference**

In `DictationTab`, replace the instance method `stateDescription(for:)` with a static, pure one
and update its two call sites:

```swift
    /// Pure, so the wording is unit-tested. `nil` means the row has not been read yet.
    /// `ModelState` is the top-level enum from `ModelManager`, the same one `ModelsViewModel.Row`
    /// stores.
    static func stateCaption(for state: ModelState?) -> String {
        switch state {
        case .none: "Checking…"
        case .notDownloaded: "Not downloaded — download it under Speech models below."
        case .downloading(let fraction): "Downloading… \(Int(fraction * 100))%"
        case .downloaded: "Ready."
        case .failed(let message): message
        }
    }
```

Call it as
`Text(Self.stateCaption(for: model.modelsViewModel.rows.first(where: { $0.id == modelID })?.state))`
and delete the `Text("Download and delete models in the Models tab.")` line.

- [ ] **Step 4: Move the model list into the Dictation form**

Add to `DictationTab.body`, after the `Section("Language")`:

```swift
            Section("Speech models") {
                Text("Models are stored in ~/Library/Application Support/Macomprendo/models.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Plain rows, not a nested List: a List inside a Form scrolls independently
                // and clips its own content.
                ForEach(model.modelsViewModel.rows) { row in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.model.displayName)
                            Text(ModelsViewModel.sizeText(row.model.sizeBytes))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        modelStateView(row)
                    }
                    .padding(.vertical, 2)
                }

                HStack {
                    Text("Disk usage: \(model.modelsViewModel.diskUsageText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh") { Task { await model.modelsViewModel.refresh() } }
                }
            }
```

and move `stateView(_:)` from the deleted `ModelsTabContent` into `DictationTab` verbatim,
renamed `modelStateView(_:)`, with `viewModel.` replaced by `model.modelsViewModel.`.

- [ ] **Step 5: Delete the tab**

Delete `macos/Sources/Macomprendo/UI/Settings/ModelsTab.swift` and remove these two lines from
`SettingsView.body`:

```swift
            ModelsTab()
                .tabItem { Label { Text("Models") } icon: { Icon(.download, size: 16) } }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `npm run test:swift && npm run gen && git diff --exit-code macos/Macomprendo.xcodeproj`
Expected: PASS, and `npm run gen` leaves the project unchanged.

- [ ] **Step 7: Commit**

```bash
git add -A macos/Sources/Macomprendo/UI/Settings macos/Tests/MacomprendoTests/UI/ModelsViewModelTests.swift
git commit -m "refactor(settings): move speech models into the Dictation tab"
```

---

### Task 10: `LanguageDetecting`

**Files:**
- Create: `macos/Sources/Macomprendo/Services/LanguageDetector.swift`
- Create: `macos/Tests/MacomprendoTests/Fakes/ScriptedLanguageDetector.swift`
- Create: `macos/Tests/MacomprendoTests/Services/LanguageDetectorTests.swift`
- Modify: `macos/Sources/Macomprendo/Services/LanguageSegmenter.swift`

**Interfaces:**
- Consumes: `LanguageSegmenter.script(of:)`.
- Produces:
  - `protocol LanguageDetecting: Sendable { func dominantLanguage(of text: String) -> String? }`
  - `struct NLLanguageDetector: LanguageDetecting`
  - `LanguageSegmenter.letterCount(_ text: String) -> Int` (was private, on `TextRun`)
  - `ScriptedLanguageDetector` with `var answers: [String: String]` and
    `private(set) var asked: [String]`

- [ ] **Step 1: Write the failing test**

Create `macos/Tests/MacomprendoTests/Services/LanguageDetectorTests.swift`:

```swift
import Foundation
import Testing
@testable import Macomprendo

@Suite struct LanguageDetectorTests {
    private let detector = NLLanguageDetector()

    @Test func detectsABaseCodeForAConfidentSample() {
        #expect(detector.dominantLanguage(of: "Это довольно длинное русское предложение.") == "ru")
        #expect(detector.dominantLanguage(of: "This is a reasonably long English sentence.") == "en")
        #expect(detector.dominantLanguage(of: "Dies ist ein ziemlich langer deutscher Satz.") == "de")
    }

    /// NLLanguage uses script-qualified tags for Chinese ("zh-Hans"); the map is keyed by base
    /// codes, so the region and script are stripped.
    @Test func stripsTheScriptOrRegionSubtag() {
        let language = detector.dominantLanguage(of: "这是一个相当长的中文句子。")
        #expect(language == "zh")
    }

    @Test func returnsNilForTextWithNoLanguage() {
        #expect(detector.dominantLanguage(of: "") == nil)
        #expect(detector.dominantLanguage(of: "12345 67890") == nil)
    }
}

@Suite struct LetterCountTests {
    @Test func countsOnlyCyrillicAndLatinLetters() {
        #expect(LanguageSegmenter.letterCount("(swift 538/538, node 38/38)") == 9)
        #expect(LanguageSegmenter.letterCount("Привет, мир!") == 9)
        #expect(LanguageSegmenter.letterCount("123 …") == 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npm run test:swift`
Expected: FAIL — `NLLanguageDetector` and `LanguageSegmenter.letterCount(_:)` do not exist.

- [ ] **Step 3: Open up `letterCount`**

In `macos/Sources/Macomprendo/Services/LanguageSegmenter.swift`, add the string-taking version
and make the existing private helper delegate to it:

```swift
    /// Counts only letters (Cyrillic or Latin), ignoring digits, punctuation and whitespace.
    /// Internal because the speech planner uses it to decide whether a run is long enough for
    /// language detection to be trustworthy.
    static func letterCount(_ text: String) -> Int {
        text.reduce(into: 0) { count, character in
            if script(of: character) != .neutral { count += 1 }
        }
    }

    private static func letterCount(_ run: TextRun) -> Int { letterCount(run.text) }
```

- [ ] **Step 4: Write the detector**

Create `macos/Sources/Macomprendo/Services/LanguageDetector.swift`:

```swift
import Foundation
import NaturalLanguage

/// Names the language of a stretch of text. Behind a protocol so the speech planner stays a
/// pure function that tests can drive deterministically (invariant 2).
protocol LanguageDetecting: Sendable {
    /// A base BCP-47 code ("ru", "en", "zh"), or nil when the text is empty, has no letters,
    /// or the recognizer is undecided.
    func dominantLanguage(of text: String) -> String?
}

struct NLLanguageDetector: LanguageDetecting {
    func dominantLanguage(of text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage, language != .undetermined else {
            return nil
        }
        // NLLanguage tags Chinese as "zh-Hans"/"zh-Hant"; the voice map is keyed by base code.
        return language.rawValue.split(separator: "-").first.map(String.init)
    }
}
```

- [ ] **Step 5: Write the fake**

Create `macos/Tests/MacomprendoTests/Fakes/ScriptedLanguageDetector.swift`:

```swift
import Foundation
@testable import Macomprendo

/// Answers from a table keyed by the exact text it is asked about, so a segmentation test
/// controls the detected language of every run without depending on NaturalLanguage.
final class ScriptedLanguageDetector: LanguageDetecting, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: String]
    private var questions: [String] = []

    /// Text that is not in the table is reported as undetectable.
    init(_ answers: [String: String] = [:]) {
        self.answers = answers
    }

    /// Every text the planner asked about, in order.
    var asked: [String] { lock.withLock { questions } }

    func dominantLanguage(of text: String) -> String? {
        lock.withLock {
            questions.append(text)
            return answers[text]
        }
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `npm run test:swift`
Expected: PASS. If `detectsABaseCodeForAConfidentSample` is flaky on a machine with unusual
language assets, lengthen the samples rather than loosening the assertion — a detector that
cannot name a full sentence is a real defect for this feature.

- [ ] **Step 7: Commit**

```bash
git add macos/Sources/Macomprendo/Services macos/Tests/MacomprendoTests
git commit -m "feat(speech): add LanguageDetecting behind a protocol"
```

---

### Task 11: Voice per language in the utterance plan

**Files:**
- Modify: `macos/Sources/Macomprendo/Services/SpeechService.swift`
- Modify: `macos/Sources/Macomprendo/App/AppEnvironment.swift:live`
- Test: `macos/Tests/MacomprendoTests/Services/SpeechSegmentationTests.swift`

**Interfaces:**
- Consumes: `LanguageDetecting`, `ScriptedLanguageDetector`, `LanguageSegmenter.letterCount(_:)`,
  `SpeechSettings.voiceByLanguage`, `.segmentationEnabled`.
- Produces:
  - `AVSpeechService.minDetectionLetters: Int` (12)
  - `AVSpeechService.utterancePlan(text:settings:voices:detector:minRunLength:) -> [UtterancePlan]`
  - `AVSpeechService.init(detector: any LanguageDetecting = NLLanguageDetector())`

- [ ] **Step 1: Write the failing test**

Add to `SpeechSegmentationTests` (the suite's `voices` and `settings(_:)` helpers already exist;
add a `settings(_:map:segmentation:)` overload):

```swift
    private func settings(_ voiceID: String?,
                          map: [String: String] = [:],
                          segmentation: Bool = true) -> SpeechSettings {
        var s = SpeechSettings(voiceID: voiceID, rate: 0.5, pitch: 1, volume: 1)
        s.voiceByLanguage = map
        s.segmentationEnabled = segmentation
        return s
    }

    @Test func segmentationOffProducesExactlyOneUtteranceWithTheDefaultVoice() {
        let text = cyrillicPart + latinPart
        let plan = AVSpeechService.utterancePlan(
            text: text,
            settings: settings("en.alex", segmentation: false),
            voices: voices,
            detector: ScriptedLanguageDetector(["anything": "ru"]))
        #expect(plan == [UtterancePlan(text: text, voiceID: "en.alex")])
    }

    @Test func aMappedLanguageWinsOverTheAutomaticFallback() {
        let runs = LanguageSegmenter.runs(in: cyrillicPart + latinPart)
        let detector = ScriptedLanguageDetector(Dictionary(uniqueKeysWithValues: runs.map {
            ($0.text, $0.script == .cyrillic ? "ru" : "en")
        }))
        let plan = AVSpeechService.utterancePlan(
            text: cyrillicPart + latinPart,
            settings: settings("en.alex", map: ["ru": "ru.milena"]),
            voices: voices,
            detector: detector)
        // Without the map the Cyrillic run would take the enhanced Milena via fallbackVoice.
        #expect(plan.first(where: { $0.text.contains("русское") })?.voiceID == "ru.milena")
    }

    @Test func anUnmappedLanguageStillUsesTheAutomaticFallback() {
        let runs = LanguageSegmenter.runs(in: cyrillicPart + latinPart)
        let detector = ScriptedLanguageDetector(Dictionary(uniqueKeysWithValues: runs.map {
            ($0.text, $0.script == .cyrillic ? "ru" : "en")
        }))
        let plan = AVSpeechService.utterancePlan(
            text: cyrillicPart + latinPart,
            settings: settings("en.alex"),
            voices: voices,
            detector: detector)
        #expect(plan.first(where: { $0.text.contains("русское") })?.voiceID == "ru.milena.enhanced")
    }

    @Test func aMappedVoiceThatIsNotInstalledIsIgnored() {
        let runs = LanguageSegmenter.runs(in: cyrillicPart + latinPart)
        let detector = ScriptedLanguageDetector(Dictionary(uniqueKeysWithValues: runs.map {
            ($0.text, $0.script == .cyrillic ? "ru" : "en")
        }))
        let plan = AVSpeechService.utterancePlan(
            text: cyrillicPart + latinPart,
            settings: settings("en.alex", map: ["ru": "ru.uninstalled"]),
            voices: voices,
            detector: detector)
        #expect(plan.first(where: { $0.text.contains("русское") })?.voiceID == "ru.milena.enhanced")
    }

    /// "Привет." is a 6-letter Cyrillic run, and Cyrillic runs never merge into a Latin
    /// neighbour — so it survives as its own run and is below the threshold, while the long
    /// Latin run is above it. Asserting both halves is what makes this test fail against a
    /// broken threshold instead of passing vacuously on an empty question list.
    @Test func onlyRunsLongEnoughToBeTrustworthyAreSentToTheDetector() {
        let detector = ScriptedLanguageDetector()
        _ = AVSpeechService.utterancePlan(
            text: "Привет. This is a reasonably long English sentence here.",
            settings: settings("en.alex", map: ["ru": "ru.milena"]),
            voices: voices,
            detector: detector)
        #expect(detector.asked.count == 1)
        #expect(detector.asked.first?.contains("reasonably") == true)
        #expect(detector.asked.allSatisfy {
            LanguageSegmenter.letterCount($0) >= AVSpeechService.minDetectionLetters
        })
    }

    @Test func aPlanThatResolvesToOneVoiceCollapsesToTheOriginalText() {
        let text = "Now a long English sentence follows here and continues."
        let plan = AVSpeechService.utterancePlan(
            text: text,
            settings: settings("en.alex"),
            voices: voices,
            detector: ScriptedLanguageDetector([text: "en"]))
        #expect(plan == [UtterancePlan(text: text, voiceID: "en.alex")])
    }

    @Test func emptyTextProducesNoUtterances() {
        #expect(AVSpeechService.utterancePlan(text: "", settings: settings("en.alex"),
                                              voices: voices,
                                              detector: ScriptedLanguageDetector()).isEmpty)
    }
```

Every existing call to `utterancePlan(text:settings:voices:)` in this suite gains
`detector: ScriptedLanguageDetector()` — with an empty table the detector never answers, so
those tests keep exercising exactly the script-based fallback they were written for.

- [ ] **Step 2: Run tests to verify they fail**

Run: `npm run test:swift`
Expected: FAIL — `utterancePlan` has no `detector:` parameter and `minDetectionLetters` does not
exist.

- [ ] **Step 3: Rewrite the planner**

In `macos/Sources/Macomprendo/Services/SpeechService.swift`, replace `utterancePlan` and add
its helper:

```swift
    /// A run shorter than this many letters is not sent to the detector: `NLLanguageRecognizer`
    /// guesses on short input, and a wrong guess picks a worse voice than the script-based
    /// fallback would.
    nonisolated static let minDetectionLetters = 12

    /// What to enqueue for `text`.
    ///
    /// When segmentation is switched off, or when every run resolves to the configured voice,
    /// the result is a single utterance holding the original text — byte for byte what the
    /// service did before segmentation existed.
    nonisolated static func utterancePlan(
        text: String,
        settings: SpeechSettings,
        voices: [Voice],
        detector: any LanguageDetecting,
        minRunLength: Int = LanguageSegmenter.defaultMinRunLength
    ) -> [UtterancePlan] {
        guard !text.isEmpty else { return [] }
        guard settings.segmentationEnabled else {
            return [UtterancePlan(text: text, voiceID: settings.voiceID)]
        }
        let configured = voices.first { $0.id == settings.voiceID }
        let configuredScript = configured.map { LanguageSegmenter.script(ofLanguage: $0.language) } ?? .latin
        let plan = LanguageSegmenter.runs(in: text, minRunLength: minRunLength).map { run in
            UtterancePlan(text: run.text,
                          voiceID: voiceID(for: run, settings: settings, voices: voices,
                                           configuredScript: configuredScript, detector: detector))
        }
        guard plan.contains(where: { $0.voiceID != settings.voiceID }) else {
            return [UtterancePlan(text: text, voiceID: settings.voiceID)]
        }
        return plan
    }

    /// The user's mapping wins wherever they made one; everything else keeps the automatic
    /// per-script pick that shipped with segmentation.
    nonisolated static func voiceID(for run: TextRun,
                                    settings: SpeechSettings,
                                    voices: [Voice],
                                    configuredScript: ScriptClass,
                                    detector: any LanguageDetecting) -> String? {
        guard run.script != .neutral else { return settings.voiceID }
        if LanguageSegmenter.letterCount(run.text) >= minDetectionLetters,
           let language = detector.dominantLanguage(of: run.text),
           let mapped = settings.voiceByLanguage[language],
           voices.contains(where: { $0.id == mapped }) {
            return mapped
        }
        if run.script == configuredScript { return settings.voiceID }
        return fallbackVoice(for: run.script, in: voices)?.id ?? settings.voiceID
    }
```

- [ ] **Step 4: Store a detector on the service**

In `AVSpeechService`, add the stored dependency and use it in `speak`:

```swift
    private let detector: any LanguageDetecting

    init(detector: any LanguageDetecting = NLLanguageDetector()) {
        self.detector = detector
        super.init()
        synthesizer.delegate = self
    }
```

and in `speak(_:settings:)` replace the plan line with:

```swift
        let plan = Self.utterancePlan(text: text, settings: settings, voices: voices(),
                                      detector: detector)
```

`AppEnvironment.live()` keeps `AVSpeechService()` — the default argument supplies the real
detector, and no concrete service is constructed outside the composition root.

- [ ] **Step 5: Run tests to verify they pass**

Run: `npm run test:swift && swift build --package-path macos`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add macos/Sources/Macomprendo/Services/SpeechService.swift macos/Tests/MacomprendoTests/Services/SpeechSegmentationTests.swift
git commit -m "feat(speech): honour the per-language voice map when planning utterances"
```

---

### Task 12: Speech tab — per-language voices, editable preview, audition

**Files:**
- Modify: `macos/Sources/Macomprendo/UI/Settings/SpeechTab.swift`
- Test: `macos/Tests/MacomprendoTests/UI/SpeechTabModelTests.swift`

**Interfaces:**
- Consumes: `SpeechSettings.voiceByLanguage`, `.segmentationEnabled`, `.previewText`,
  `.auditionOnSelect`; `ScriptedSpeech`.
- Produces:
  - `SpeechTabModel.baseCode(_ tag: String) -> String`
  - `SpeechTabModel.group(_:) -> [VoiceGroup]` now keyed by base code
  - `SpeechTabModel.setDefaultVoice(_ voiceID: String?)`
  - `SpeechTabModel.setVoice(_ voiceID: String?, forLanguage: String)`
  - `SpeechTabModel.auditionPhrase(for voiceID: String) -> String`
  - `SpeechTabModel.auditionPhrases: [String: String]`
  - `SpeechTabModel.sampleText` is deleted in favour of `SpeechSettings.defaultPreviewText`

- [ ] **Step 1: Write the failing test**

Add to `SpeechTabModelTests`:

```swift
    private let catalog = [
        Voice(id: "en.alex", name: "Alex", language: "en-US", quality: "default"),
        Voice(id: "en.daniel", name: "Daniel", language: "en-GB", quality: "enhanced"),
        Voice(id: "ru.milena", name: "Milena", language: "ru-RU", quality: "default"),
        Voice(id: "uk.lesya", name: "Lesya", language: "uk-UA", quality: "premium")
    ]

    @Test func regionalVariantsShareOneLanguageGroup() {
        let groups = SpeechTabModel.group(catalog)
        #expect(groups.map(\.language).sorted() == ["en", "ru", "uk"])
        let english = groups.first { $0.language == "en" }!
        #expect(english.voices.map(\.id) == ["en.alex", "en.daniel"])
    }

    @Test func baseCodeStripsRegionAndScript() {
        #expect(SpeechTabModel.baseCode("ru-RU") == "ru")
        #expect(SpeechTabModel.baseCode("zh-Hans-CN") == "zh")
        #expect(SpeechTabModel.baseCode("EN") == "en")
    }

    @Test func mappingAVoiceToALanguagePersistsAndClearingRemovesTheKey() {
        let (model, _, holder) = make(voices: catalog)
        model.setVoice("ru.milena", forLanguage: "ru")
        #expect(holder.settings.speech.voiceByLanguage == ["ru": "ru.milena"])
        model.setVoice(nil, forLanguage: "ru")
        #expect(holder.settings.speech.voiceByLanguage.isEmpty)
    }

    @Test func selectingAVoiceAuditionsItWithSegmentationOff() {
        let (model, speech, holder) = make(voices: catalog)
        holder.settings.speech.auditionOnSelect = true
        holder.settings.speech.source = .endpoint
        model.setVoice("ru.milena", forLanguage: "ru")
        #expect(speech.spoken.count == 1)
        let spoken = speech.spoken[0]
        #expect(spoken.text == "Вот так звучит мой голос.")
        #expect(spoken.settings.voiceID == "ru.milena")
        #expect(spoken.settings.source == .system)
        #expect(spoken.settings.segmentationEnabled == false)
    }

    @Test func auditionIsSilentWhenTheToggleIsOff() {
        let (model, speech, holder) = make(voices: catalog)
        holder.settings.speech.auditionOnSelect = false
        model.setDefaultVoice("en.alex")
        #expect(holder.settings.speech.voiceID == "en.alex")
        #expect(speech.spoken.isEmpty)
    }

    @Test func anUnknownLanguageIsAuditionedWithTheVoicesOwnName() {
        let (model, _, _) = make(voices: catalog)
        #expect(model.auditionPhrase(for: "uk.lesya") == "Lesya")
        #expect(model.auditionPhrase(for: "en.alex") == "This is how I sound.")
    }

    @Test func previewSpeaksTheEditablePreviewText() {
        let (model, speech, holder) = make(voices: catalog)
        holder.settings.speech.previewText = "проверка check"
        model.preview()
        #expect(speech.spoken.map(\.text) == ["проверка check"])
    }
```

The suite's helper is `model(speech:holder:keychain:) -> SpeechTabModel`. Add a second helper
beside it that returns the pieces these tests assert on, and seeds the system catalog:

```swift
    private func make(voices: [Voice])
        -> (SpeechTabModel, ScriptedSpeech, ScriptedSettingsHolder) {
        let speech = ScriptedSpeech()
        speech.available = voices
        speech.availableBySource[.system] = voices
        let holder = ScriptedSettingsHolder()
        return (SpeechTabModel(speech: speech, holder: holder, keychain: InMemoryKeychainStore()),
                speech, holder)
    }
```

The suite's existing `voicesAreGroupedByLanguageAndSortedByName` asserts
`groups.map(\.language) == ["en-US", "fr-FR"]`; update it to `["en", "fr"]`, which is the whole
point of the regrouping.

- [ ] **Step 2: Run tests to verify they fail**

Run: `npm run test:swift`
Expected: FAIL — `baseCode`, `setVoice(_:forLanguage:)`, `setDefaultVoice`, `auditionPhrase` do
not exist, and `group` still keys on the full tag.

- [ ] **Step 3: Regroup by base code and add the writers**

In `SpeechTabModel`:

```swift
    /// A short line per language so a voice can be judged on its own language, not on English.
    /// Anything else is auditioned with the voice's own name, the way System Settings does.
    static let auditionPhrases: [String: String] = [
        "en": "This is how I sound.",
        "ru": "Вот так звучит мой голос.",
        "es": "Así suena mi voz.",
        "de": "So klingt meine Stimme.",
        "fr": "Voici comment sonne ma voix.",
        "pt": "É assim que soa a minha voz.",
        "zh": "这就是我的声音。"
    ]

    /// The base code of a BCP-47 tag: "ru-RU" and "zh-Hans-CN" become "ru" and "zh". The voice
    /// map is keyed this way because that is what `LanguageDetecting` returns.
    static func baseCode(_ tag: String) -> String {
        tag.split(separator: "-").first.map { $0.lowercased() } ?? tag.lowercased()
    }

    static func group(_ voices: [Voice]) -> [VoiceGroup] {
        Dictionary(grouping: voices, by: { baseCode($0.language) })
            .map { code, voices in
                VoiceGroup(language: code,
                           displayName: Locale.current.localizedString(forLanguageCode: code) ?? code,
                           voices: voices.sorted { ($0.name, $0.id) < ($1.name, $1.id) })
            }
            .sorted { ($0.displayName, $0.language) < ($1.displayName, $1.language) }
    }

    func voice(forLanguage language: String) -> String? {
        holder.settings.speech.voiceByLanguage[language]
    }

    /// nil clears the mapping, which puts that language back on the automatic pick.
    func setVoice(_ voiceID: String?, forLanguage language: String) {
        objectWillChange.send()
        holder.settings.speech.voiceByLanguage[language] = voiceID
        if let voiceID { audition(voiceID) }
    }

    func setDefaultVoice(_ voiceID: String?) {
        objectWillChange.send()
        holder.settings.speech.voiceID = voiceID
        if let voiceID { audition(voiceID) }
    }

    /// Forces the system source and switches segmentation off, so the phrase is guaranteed to
    /// be heard in the voice that was just picked instead of being re-segmented away from it.
    /// Needs no new protocol method: `SpeechRouter` reads the source from these settings.
    private func audition(_ voiceID: String) {
        guard holder.settings.speech.auditionOnSelect else { return }
        var settings = holder.settings.speech
        settings.source = .system
        settings.voiceID = voiceID
        settings.segmentationEnabled = false
        speech.speak(auditionPhrase(for: voiceID), settings: settings)
    }

    func auditionPhrase(for voiceID: String) -> String {
        guard let voice = speech.voices(for: .system).first(where: { $0.id == voiceID }) else {
            return ""
        }
        return Self.auditionPhrases[Self.baseCode(voice.language)] ?? voice.name
    }
```

Delete `static let sampleText` and change `preview()` to:

```swift
    func preview() {
        speech.speak(holder.settings.speech.previewText, settings: holder.settings.speech)
    }
```

Update any test or view still referencing `SpeechTabModel.sampleText` to
`SpeechSettings.defaultPreviewText`.

- [ ] **Step 4: Rebuild the system section of the view**

In `SpeechTab`, wrap the whole `VStack` in a `ScrollView` and replace `systemSection` with:

```swift
    private var systemSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Default voice").font(.headline)
            Text("Used for languages you have not mapped, and for everything when voice "
                 + "switching is off.")
                .font(.caption).foregroundStyle(.secondary)
            List(selection: Binding(get: { app.settings.speech.voiceID },
                                    set: { model.setDefaultVoice($0) })) {
                ForEach(model.groups) { group in
                    Section(group.displayName) {
                        ForEach(group.voices) { voice in
                            HStack {
                                Text(voice.name)
                                if voice.quality != "default" {
                                    Text(voice.quality.uppercased())
                                        .font(.caption2)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Color.accentColor.opacity(0.18))
                                        .clipShape(Capsule())
                                }
                                Spacer()
                            }
                            .tag(voice.id)
                        }
                    }
                }
            }
            .frame(minHeight: 200)

            Toggle("Switch voices for mixed-language text",
                   isOn: $app.settings.speech.segmentationEnabled)
            Text("""
                Text is cut into runs of a single script, each run's language is detected, and \
                the run is read by the voice you mapped to that language. Short Latin fragments \
                inside Cyrillic text stay on the Cyrillic voice on purpose, so one foreign word \
                does not flip the voice mid-sentence.
                """)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Voice per language").font(.headline)
            ForEach(model.groups) { group in
                Picker(group.displayName, selection: Binding(
                    get: { model.voice(forLanguage: group.language) },
                    set: { model.setVoice($0, forLanguage: group.language) })) {
                        Text("Auto").tag(String?.none)
                        ForEach(group.voices) { voice in
                            Text(voice.name).tag(Optional(voice.id))
                        }
                    }
            }
            .disabled(!app.settings.speech.segmentationEnabled)

            // Rate, pitch and volume are AVSpeechSynthesizer parameters; the endpoint takes
            // free-form "Style instructions" instead.
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Rate")
                    Slider(value: $app.settings.speech.rate, in: 0...1)
                }
                GridRow {
                    Text("Pitch")
                    Slider(value: $app.settings.speech.pitch, in: 0.5...2.0)
                }
                GridRow {
                    Text("Volume")
                    Slider(value: $app.settings.speech.volume, in: 0...1)
                }
            }
        }
    }
```

and replace the bottom `HStack` with:

```swift
            VStack(alignment: .leading, spacing: 8) {
                Text("Preview text").font(.headline)
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
            }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `npm run test:swift && swift build --package-path macos`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add macos/Sources/Macomprendo/UI/Settings/SpeechTab.swift macos/Tests/MacomprendoTests/UI/SpeechTabModelTests.swift
git commit -m "feat(speech): map a voice per language, edit the preview text, audition on select"
```

---

### Task 13: `ActivationPolicyControlling` and `DockIconCoordinator`

**Files:**
- Create: `macos/Sources/Macomprendo/Services/ActivationPolicyService.swift`
- Create: `macos/Sources/Macomprendo/Features/DockIconCoordinator.swift`
- Create: `macos/Tests/MacomprendoTests/Fakes/FakeActivationPolicy.swift`
- Create: `macos/Tests/MacomprendoTests/Features/DockIconCoordinatorTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `@MainActor protocol ActivationPolicyControlling: AnyObject { func setDockIconVisible(_ visible: Bool) }`
  - `@MainActor final class NSAppActivationPolicy: ActivationPolicyControlling`
  - `@MainActor final class DockIconCoordinator` with
    `enum Owner: Hashable, Sendable { case settings, onboarding }`, `init(policy:)`,
    `open(_:)`, `close(_:)`, `var owners: Set<Owner> { get }`
  - `FakeActivationPolicy` with `private(set) var calls: [Bool]`

- [ ] **Step 1: Write the failing test**

Create `macos/Tests/MacomprendoTests/Features/DockIconCoordinatorTests.swift`:

```swift
import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct DockIconCoordinatorTests {
    private func make() -> (DockIconCoordinator, FakeActivationPolicy) {
        let policy = FakeActivationPolicy()
        return (DockIconCoordinator(policy: policy), policy)
    }

    @Test func openingTheFirstWindowShowsTheIcon() {
        let (coordinator, policy) = make()
        coordinator.open(.settings)
        #expect(policy.calls == [true])
    }

    @Test func closingTheLastWindowHidesIt() {
        let (coordinator, policy) = make()
        coordinator.open(.settings)
        coordinator.close(.settings)
        #expect(policy.calls == [true, false])
        #expect(coordinator.owners.isEmpty)
    }

    /// The whole reason for a set rather than a flag: closing one of two windows must not
    /// take the icon away from the other.
    @Test func closingOneOfTwoOwnersKeepsTheIcon() {
        let (coordinator, policy) = make()
        coordinator.open(.settings)
        coordinator.open(.onboarding)
        coordinator.close(.settings)
        // No policy call at all: the icon was already visible and must stay visible. Calling
        // the policy again would re-run NSApp.activate and steal focus.
        #expect(policy.calls == [true])
        #expect(coordinator.owners == [.onboarding])
        coordinator.close(.onboarding)
        #expect(policy.calls == [true, false])
    }

    @Test func openingTheSameOwnerTwiceCallsThePolicyOnce() {
        let (coordinator, policy) = make()
        coordinator.open(.settings)
        coordinator.open(.settings)
        #expect(policy.calls == [true])
    }

    @Test func closingAnOwnerThatWasNeverOpenedDoesNothing() {
        let (coordinator, policy) = make()
        coordinator.close(.onboarding)
        #expect(policy.calls.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm run test:swift`
Expected: FAIL — `DockIconCoordinator` and `FakeActivationPolicy` do not exist.

- [ ] **Step 3: Write the service, the coordinator and the fake**

Create `macos/Sources/Macomprendo/Services/ActivationPolicyService.swift`:

```swift
import AppKit

/// Shows or hides the Dock icon of an `LSUIElement` app.
@MainActor protocol ActivationPolicyControlling: AnyObject {
    func setDockIconVisible(_ visible: Bool)
}

/// Hardware/AppKit glue with no logic of its own, so it carries no unit test and is covered by
/// `docs/SMOKE_TEST.md` instead (invariant 3).
@MainActor final class NSAppActivationPolicy: ActivationPolicyControlling {
    func setDockIconVisible(_ visible: Bool) {
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
        // Becoming `.regular` does not by itself put the app in front or install its menu bar.
        if visible { NSApp.activate(ignoringOtherApps: true) }
    }
}
```

Create `macos/Sources/Macomprendo/Features/DockIconCoordinator.swift`:

```swift
import Foundation

/// Decides whether the Dock icon is visible. A set of owners rather than a flag, because the
/// onboarding wizard and the Settings window can be open at once and closing one must not take
/// the icon away from the other. The HUD and the Quick Panel are `NSPanel`s and are never
/// owners.
@MainActor final class DockIconCoordinator {
    enum Owner: Hashable, Sendable {
        case settings
        case onboarding
    }

    private(set) var owners: Set<Owner> = []
    private let policy: any ActivationPolicyControlling

    init(policy: any ActivationPolicyControlling) {
        self.policy = policy
    }

    /// The policy is called ONLY on a real visibility transition, in both directions.
    /// `NSAppActivationPolicy.setDockIconVisible(true)` also calls
    /// `NSApp.activate(ignoringOtherApps:)`, so re-asserting visibility while another owner
    /// is still open would yank focus to this app at the moment the user closed a window —
    /// while they were working in a different app entirely.
    func open(_ owner: Owner) {
        let wasEmpty = owners.isEmpty
        guard owners.insert(owner).inserted, wasEmpty else { return }
        policy.setDockIconVisible(true)
    }

    func close(_ owner: Owner) {
        guard owners.remove(owner) != nil, owners.isEmpty else { return }
        policy.setDockIconVisible(false)
    }
}
```

Create `macos/Tests/MacomprendoTests/Fakes/FakeActivationPolicy.swift`:

```swift
import Foundation
@testable import Macomprendo

@MainActor final class FakeActivationPolicy: ActivationPolicyControlling {
    private(set) var calls: [Bool] = []

    func setDockIconVisible(_ visible: Bool) { calls.append(visible) }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm run test:swift && swift build --package-path macos`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Macomprendo/Services/ActivationPolicyService.swift macos/Sources/Macomprendo/Features/DockIconCoordinator.swift macos/Tests/MacomprendoTests
git commit -m "feat(app): add a ref-counted Dock icon coordinator"
```

---

### Task 14: Wire the Dock icon to the two windows

Window lifecycle is AppKit/SwiftUI glue, so it is thin and covered by the smoke test.

**Files:**
- Modify: `macos/Sources/Macomprendo/App/AppEnvironment.swift`
- Modify: `macos/Sources/Macomprendo/App/AppModel.swift`
- Modify: `macos/Sources/Macomprendo/UI/Onboarding/OnboardingWindowController.swift`
- Modify: `macos/Sources/Macomprendo/App/MacomprendoApp.swift`
- Modify: `macos/Tests/MacomprendoTests/Fakes/FakeEnvironment.swift`
- Modify: `docs/SMOKE_TEST.md`

**Interfaces:**
- Consumes: `DockIconCoordinator`, `ActivationPolicyControlling` (Task 13).
- Produces: `AppEnvironment.activationPolicy: any ActivationPolicyControlling`,
  `AppModel.dockIcon: DockIconCoordinator`.

- [ ] **Step 1: Add the service to the composition root**

In `AppEnvironment`, add the stored property `var activationPolicy: any ActivationPolicyControlling`
and pass `activationPolicy: NSAppActivationPolicy()` in `live()`. In
`macos/Tests/MacomprendoTests/Fakes/FakeEnvironment.swift`, pass `FakeActivationPolicy()` in
`AppEnvironment.fake()` so every existing test keeps compiling.

In `AppModel`, add:

```swift
    lazy var dockIcon = DockIconCoordinator(policy: env.activationPolicy)
```

- [ ] **Step 2: Own the icon from the onboarding window**

In `OnboardingWindowController`, keep a delegate so the close is observed, and take/release the
owner around it:

```swift
/// Keeps the Dock icon alive for as long as the wizard's window is on screen. An `NSWindow`
/// does not retain its delegate, so the controller holds it.
@MainActor
private final class OnboardingWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: @MainActor () -> Void

    init(onClose: @escaping @MainActor () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) { onClose() }
}
```

and inside the enum add `private static var delegate: OnboardingWindowDelegate?`, then in
`show(model:)`, after `window.isReleasedWhenClosed = false`:

```swift
        let delegate = OnboardingWindowDelegate { [weak model] in
            model?.dockIcon.close(.onboarding)
        }
        window.delegate = delegate
        self.delegate = delegate
        model.dockIcon.open(.onboarding)
```

The early-return branch (window already built) also calls `model.dockIcon.open(.onboarding)`;
`open` is idempotent, so a second call while the window is up is a no-op.

- [ ] **Step 3: Own the icon from the Settings window**

In `MacomprendoApp.body`, attach the lifecycle to the settings scene's root view:

```swift
        SwiftUI.Settings {
            SettingsView()
                .environmentObject(model)
                .onAppear { model.dockIcon.open(.settings) }
                .onDisappear { model.dockIcon.close(.settings) }
        }
```

- [ ] **Step 4: Record the risk in the smoke test**

Add to `docs/SMOKE_TEST.md`:

| Step | Expected |
|---|---|
| Open Settings from the menubar | A Dock icon appears while the window is up |
| Close the Settings window | The Dock icon disappears; the menubar item stays |
| Open "Check permissions…", then Settings, then close Settings | The Dock icon stays while the wizard is still open |
| Close the wizard too | The Dock icon disappears |

with this note underneath:

> `.onDisappear` on a SwiftUI `Settings` scene is not a documented contract. If closing the
> Settings window leaves the Dock icon behind, replace the `.onAppear`/`.onDisappear` pair with
> a glue object observing `NSWindow.willCloseNotification` and reconciling against
> `NSApp.windows`; the `DockIconCoordinator` API does not change.

- [ ] **Step 5: Verify**

Run: `npm run test:swift && swift build --package-path macos`
Expected: PASS. Then build and launch the app and walk the four smoke-test rows above.

- [ ] **Step 6: Commit**

```bash
git add macos/Sources/Macomprendo macos/Tests/MacomprendoTests/Fakes/FakeEnvironment.swift docs/SMOKE_TEST.md
git commit -m "feat(app): show a Dock icon while the wizard or Settings is open"
```

---

### Task 15: Pause and resume on both speech backends

**Files:**
- Modify: `macos/Sources/Macomprendo/Services/SpeechService.swift`
- Modify: `macos/Sources/Macomprendo/Services/AudioPlayer.swift`
- Modify: `macos/Sources/Macomprendo/Services/EndpointSpeechService.swift`
- Modify: `macos/Sources/Macomprendo/Services/SpeechRouter.swift`
- Modify: `macos/Tests/MacomprendoTests/Fakes/ScriptedSpeech.swift`,
  `macos/Tests/MacomprendoTests/Fakes/FakeAudioPlayer.swift`
- Test: `macos/Tests/MacomprendoTests/Services/SpeechRouterTests.swift`,
  `macos/Tests/MacomprendoTests/Services/EndpointSpeechServiceTests.swift`

**Interfaces:**
- Consumes: `SpeechSynthesizing`, `AudioPlaying`.
- Produces:
  - `SpeechSynthesizing.isPaused: Bool`, `.pause()`, `.resume()`
  - `AudioPlaying.isPaused: Bool`, `.pause()`, `.resume()`
  - `ScriptedSpeech.pauseCount`, `.resumeCount`, and a settable `isPaused`
  - `FakeAudioPlayer.pauseCount`, `.resumeCount`

- [ ] **Step 1: Write the failing tests**

Add to `SpeechRouterTests`:

```swift
    @Test func pauseAndResumeGoToTheBackendThatIsSpeaking() {
        let system = ScriptedSpeech()
        let endpoint = ScriptedSpeech()
        let router = SpeechRouter(system: system, endpoint: endpoint)
        var settings = SpeechSettings()
        settings.source = .endpoint

        router.speak("hello", settings: settings)
        router.pause()
        #expect(endpoint.pauseCount == 1)
        #expect(system.pauseCount == 0)

        endpoint.isPaused = true
        #expect(router.isPaused)

        router.resume()
        #expect(endpoint.resumeCount == 1)
        #expect(system.resumeCount == 0)
    }

    @Test func pausingBeforeAnythingIsSpokenTargetsTheSystemBackend() {
        let system = ScriptedSpeech()
        let endpoint = ScriptedSpeech()
        let router = SpeechRouter(system: system, endpoint: endpoint)
        router.pause()
        #expect(system.pauseCount == 1)
        #expect(endpoint.pauseCount == 0)
    }
```

Add to `EndpointSpeechServiceTests`:

```swift
    @Test func pauseAndResumeDriveThePlayerAndReportState() {
        let r = rig()
        r.service.speak("One. Two. Three.", settings: settings())
        r.service.pause()
        #expect(r.player.pauseCount == 1)
        #expect(r.service.isPaused)
        r.service.resume()
        #expect(r.player.resumeCount == 1)
        #expect(!r.service.isPaused)
    }

    @Test func stoppingWhilePausedClearsThePausedState() {
        let r = rig()
        r.service.speak("One. Two. Three.", settings: settings())
        r.service.pause()
        r.service.stop()
        #expect(!r.service.isPaused)
        #expect(!r.service.isSpeaking)
    }

    @Test func pausingWhenIdleIsANoOp() {
        let r = rig()
        r.service.pause()
        #expect(r.player.pauseCount == 0)
        #expect(!r.service.isPaused)
    }
```

The suite's existing `rig(withKey:chunkCharacterLimit:) -> Rig` already exposes `service` and
`player`, so no helper changes are needed.

- [ ] **Step 2: Run tests to verify they fail**

Run: `npm run test:swift`
Expected: FAIL — `pause`, `resume` and `isPaused` do not exist on the protocols or the fakes.

- [ ] **Step 3: Widen the two protocols**

In `SpeechService.swift`, add to `SpeechSynthesizing`:

```swift
    /// True only while speech has been started and then paused. `isSpeaking` stays true, so a
    /// paused utterance is still the one in-flight job (invariant 7).
    var isPaused: Bool { get }
    /// No-op when nothing is speaking, or when already paused.
    func pause()
    /// No-op when not paused.
    func resume()
```

In `AudioPlayer.swift`, add to `AudioPlaying`:

```swift
    var isPaused: Bool { get }
    /// No-op when nothing is playing. Keeps the playhead so `resume()` continues.
    func pause()
    func resume()
```

- [ ] **Step 4: Implement on `AVSpeechService`**

```swift
    var isPaused: Bool { synthesizer.isPaused }

    func pause() {
        guard synthesizer.isSpeaking, !synthesizer.isPaused else { return }
        // `.word` rather than `.immediate` so the current word finishes: resuming mid-word
        // restarts the word and sounds like a stutter.
        synthesizer.pauseSpeaking(at: .word)
        onStateChange?()
    }

    func resume() {
        guard synthesizer.isPaused else { return }
        synthesizer.continueSpeaking()
        onStateChange?()
    }
```

`stop()` already calls `stopSpeaking(at: .immediate)`, which clears the paused state.

- [ ] **Step 5: Implement on `AVAudioPlayerPlayer`**

```swift
    private(set) var isPaused = false

    func pause() {
        guard let player, player.isPlaying else { return }
        player.pause()
        isPaused = true
    }

    func resume() {
        guard let player, isPaused else { return }
        player.play()
        isPaused = false
    }
```

and set `isPaused = false` at the top of `play(_:)` and in `stop()`.

- [ ] **Step 6: Implement on `EndpointSpeechService`**

```swift
    private(set) var isPaused = false

    /// `speak` returns before the first chunk has been synthesised, so a pause can land while
    /// the audio is still in flight. `player.pause()` is a no-op then — there is nothing
    /// playing yet — so `playAndWait` must hold the finished chunk back instead of starting
    /// it, or the pause the user asked for is silently ignored and the sound starts anyway.
    private var heldAudio: Data?

    func pause() {
        guard isSpeaking, !isPaused else { return }
        player.pause()
        isPaused = true
        onStateChange?()
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        if let audio = heldAudio {
            heldAudio = nil
            do { try player.play(audio) } catch { resumePlayback(throwing: error) }
        } else {
            player.resume()
        }
        onStateChange?()
    }
```

Set `isPaused = false` in `stop()` and at the top of `speak(_:settings:)`. The one-chunk
prefetch keeps running while paused, which is harmless: the fetched chunk simply waits for the
playback continuation.

- [ ] **Step 7: Implement on `SpeechRouter`**

The router must remember which backend it last spoke with, because `pause()` carries no
settings:

```swift
    /// The source of the most recent `speak`. `pause`/`resume` carry no settings, so this is
    /// the only way to know which backend owns the current utterance.
    private var activeSource: SpeechSource = .system

    var isPaused: Bool { system.isPaused || endpoint.isPaused }

    func pause() { backend(for: activeSource).pause() }

    func resume() { backend(for: activeSource).resume() }
```

and set `activeSource = settings.source` as the first line of `speak(_:settings:)`.

- [ ] **Step 8: Extend the fakes**

In `ScriptedSpeech`, add `var isPaused = false`, `private(set) var pauseCount = 0`,
`private(set) var resumeCount = 0`, and:

```swift
    func pause() {
        pauseCount += 1
        isPaused = true
        onStateChange?()
    }

    func resume() {
        resumeCount += 1
        isPaused = false
        onStateChange?()
    }
```

and set `isPaused = false` in `speak`, `stop`, `finish` and `failWith`.

In `FakeAudioPlayer`, add `private(set) var isPaused = false`,
`private(set) var pauseCount = 0`, `private(set) var resumeCount = 0`, with `pause()` and
`resume()` incrementing them and flipping `isPaused`, and `isPaused = false` in `play` and
`stop`.

- [ ] **Step 9: Run tests to verify they pass**

Run: `npm run test:swift && swift build --package-path macos`
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add macos/Sources/Macomprendo/Services macos/Tests/MacomprendoTests
git commit -m "feat(speech): pause and resume on both speech backends"
```

---

### Task 16: `SpeakController` owns playback for the panel too

**Files:**
- Modify: `macos/Sources/Macomprendo/Features/SpeakController.swift`
- Test: `macos/Tests/MacomprendoTests/Features/SpeakControllerTests.swift`

**Interfaces:**
- Consumes: `SpeechSynthesizing.pause/resume/isPaused` (Task 15), `Toasting`.
- Produces:
  - `enum SpeakSource: Hashable, Sendable { case hotkey, refineOriginal, refineRefined, summary }`
  - `SpeakController.isPaused: Bool` (published, read-only)
  - `SpeakController.active: SpeakSource?` (published, read-only)
  - `SpeakController.speak(_ text: String, from source: SpeakSource)`
  - `SpeakController.pauseOrResume()`
  - `SpeakController.stop()`
  - `toggle(text:)` keeps its signature

- [ ] **Step 1: Write the failing test**

Add to `SpeakControllerTests`:

```swift
    @Test func speakingFromAPanelRecordsTheSourceAndKeepsTheHUDHidden() {
        let (controller, speech, toaster) = make()
        controller.speak("summary text", from: .summary)
        #expect(speech.spoken.map(\.text) == ["summary text"])
        #expect(controller.active == .summary)
        #expect(controller.isSpeaking)
        #expect(toaster.states.isEmpty)
    }

    @Test func theHotkeyStillShowsTheHUD() async {
        let (controller, _, toaster) = make()
        await controller.toggle(text: { "selection" })
        #expect(controller.active == .hotkey)
        #expect(toaster.states.contains { if case .speaking = $0 { return true } else { return false } })
    }

    @Test func pauseAndResumeFlipTheFlagAndDriveTheBackend() {
        let (controller, speech, _) = make()
        controller.speak("text", from: .refineRefined)
        controller.pauseOrResume()
        #expect(speech.pauseCount == 1)
        #expect(controller.isPaused)
        #expect(controller.isSpeaking)
        controller.pauseOrResume()
        #expect(speech.resumeCount == 1)
        #expect(!controller.isPaused)
    }

    @Test func pausingWhenNothingIsSpeakingIsANoOp() {
        let (controller, speech, _) = make()
        controller.pauseOrResume()
        #expect(speech.pauseCount == 0)
        #expect(!controller.isPaused)
    }

    @Test func stopClearsEverything() {
        let (controller, speech, _) = make()
        controller.speak("text", from: .summary)
        controller.pauseOrResume()
        controller.stop()
        #expect(speech.stopCount == 1)
        #expect(!controller.isSpeaking)
        #expect(!controller.isPaused)
        #expect(controller.active == nil)
    }

    @Test func aSecondSourceSupersedesTheFirst() {
        let (controller, speech, _) = make()
        controller.speak("original", from: .refineOriginal)
        controller.speak("refined", from: .refineRefined)
        #expect(controller.active == .refineRefined)
        #expect(speech.spoken.map(\.text) == ["original", "refined"])
    }

    /// One in-flight job (invariant 7): ⌥S while the panel is speaking stops it rather than
    /// starting a second read.
    @Test func theHotkeyStopsPanelPlayback() async {
        let (controller, speech, _) = make()
        controller.speak("panel text", from: .summary)
        await controller.toggle(text: { Issue.record("must not read the selection"); return "" })
        #expect(speech.stopCount == 1)
        #expect(controller.active == nil)
        #expect(!controller.isSpeaking)
    }

    @Test func speakingBlankTextToastsInsteadOfStarting() {
        let (controller, speech, toaster) = make()
        controller.speak("   \n ", from: .summary)
        #expect(speech.spoken.isEmpty)
        #expect(controller.active == nil)
        #expect(!toaster.messages.isEmpty)
    }

    @Test func theBackendFinishingOnItsOwnClearsTheSource() {
        let (controller, speech, _) = make()
        controller.speak("text", from: .summary)
        speech.finish()
        #expect(controller.active == nil)
        #expect(!controller.isSpeaking)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npm run test:swift`
Expected: FAIL — `SpeakSource`, `speak(_:from:)`, `pauseOrResume`, `stop` and `active` do not
exist.

- [ ] **Step 3: Rewrite the controller**

Replace the body of `macos/Sources/Macomprendo/Features/SpeakController.swift`:

```swift
import Foundation

/// Who asked for the current playback. The Quick Panel shows two texts, so "read this aloud"
/// has to name one of them; the hotkey is its own source so only it shows the HUD.
enum SpeakSource: Hashable, Sendable {
    case hotkey
    case refineOriginal
    case refineRefined
    case summary
}

/// Hotkey #3 and the Quick Panel's playback controls. There is one in-flight read at a time
/// (invariant 7): starting from any source supersedes whatever was playing, and the hotkey
/// stops panel playback rather than starting a second read.
@MainActor final class SpeakController: ObservableObject {
    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false
    @Published private(set) var active: SpeakSource?

    /// Shown under "Speaking…" in the HUD.
    static let stopHint = "Press the Speak hotkey again to stop."

    private let speech: any SpeechSynthesizing
    private let toaster: any Toasting
    private let settings: @MainActor () -> Settings

    init(speech: any SpeechSynthesizing,
         toaster: any Toasting,
         settings: @escaping @MainActor () -> Settings) {
        self.speech = speech
        self.toaster = toaster
        self.settings = settings
        speech.onStateChange = { [weak self] in
            guard let self else { return }
            let speaking = self.speech.isSpeaking
            self.isSpeaking = speaking
            self.isPaused = speaking && self.speech.isPaused
            if !speaking { self.active = nil }
            // Panel playback has its own controls on screen; a floating HUD over the panel
            // would be noise, so only the hotkey path shows it.
            if speaking, self.active == .hotkey {
                self.toaster.show(.speaking(hint: Self.stopHint))
            } else {
                self.toaster.hide()
            }
        }
        // Surfaced exactly like the controller's own text-read failures. `onStateChange` has
        // already hidden the "Speaking…" HUD by the time this runs, so the toast survives.
        speech.onError = { [weak self] error in
            self?.toaster.toast(ErrorText.describe(error), duration: 2.5)
        }
    }

    /// `text` is evaluated only when we are about to start speaking, so the selection is not
    /// read (and no ⌘C is simulated) when the hotkey is used to stop.
    func toggle(text: () async throws -> String) async {
        if speech.isSpeaking {
            stop()
            return
        }
        do {
            speak(try await text(), from: .hotkey)
        } catch {
            toaster.toast(ErrorText.describe(error), duration: 2.5)
        }
    }

    /// Starts reading `text`, superseding any playback already in progress.
    func speak(_ text: String, from source: SpeakSource) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            toaster.toast(ErrorText.describe(MacomprendoError.noSelection), duration: 2.0)
            return
        }
        // Set before speaking: the backend calls `onStateChange` synchronously from `speak`,
        // and that closure decides whether to show the HUD from `active`.
        active = source
        isPaused = false
        speech.speak(trimmed, settings: settings().speech)
        isSpeaking = speech.isSpeaking
    }

    func pauseOrResume() {
        guard isSpeaking else { return }
        if speech.isPaused { speech.resume() } else { speech.pause() }
        isPaused = speech.isPaused
    }

    func stop() {
        speech.stop()
        isSpeaking = false
        isPaused = false
        active = nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm run test:swift && swift build --package-path macos`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Macomprendo/Features/SpeakController.swift macos/Tests/MacomprendoTests/Features/SpeakControllerTests.swift
git commit -m "feat(speech): let any source drive playback, with pause and stop"
```

---

### Task 17: Playback controls in the Quick Panel

**Files:**
- Modify: `macos/Sources/Macomprendo/UI/QuickPanel/QuickPanelView.swift`
- Modify: `macos/Sources/Macomprendo/UI/QuickPanel/RefineLayout.swift`
- Modify: `macos/Sources/Macomprendo/UI/QuickPanel/SummaryLayout.swift`
- Modify: `macos/Sources/Macomprendo/App/TextFeatures.swift:live`
- Modify: `macos/Sources/Macomprendo/Resources/Icons/icons.json`,
  `macos/Sources/Macomprendo/UI/Components/Icon.swift`
- Test: `macos/Tests/MacomprendoTests/UI/IconTests.swift`

**Interfaces:**
- Consumes: `SpeakController.speak(_:from:)`, `.pauseOrResume()`, `.stop()`, `.active`,
  `.isPaused` (Task 16).
- Produces: `AppIcon.pause`; `QuickPanelView.init(panel:refine:summarize:speak:app:)`;
  `RefineLayout(controller:presets:speak:)`; `SummaryLayout(controller:presets:speak:)`.

- [ ] **Step 1: Write the failing test**

`IconTests` already asserts that every `AppIcon` case resolves to a bundled SVG; adding the case
makes it fail until the SVG is vendored. Add the explicit assertion too:

```swift
    @Test func playbackIconsAreVendored() {
        #expect(AppIcon.pause.resourceURL() != nil)
        #expect(AppIcon.play.resourceURL() != nil)
        #expect(AppIcon.stop.resourceURL() != nil)
        #expect(AppIcon.globe.resourceURL() != nil)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm run test:swift`
Expected: FAIL — `AppIcon` has no `pause`.

- [ ] **Step 3: Vendor the pause icon**

Add `{ "name": "pause", "weight": "regular" }` to
`macos/Sources/Macomprendo/Resources/Icons/icons.json`, then:

```bash
npm run sync-icons
```

Add `case pause = "pause"` to `AppIcon` and `case .pause: return "pause.fill"` to
`fallbackSymbol`. (`play`, `stop` and `globe` are already vendored — `globe` by Task 7.)

- [ ] **Step 4: Pass the speak controller into the panel**

In `QuickPanelView`, add `@ObservedObject var speak: SpeakController` and forward it:

```swift
            case .refine:
                RefineLayout(controller: refine,
                             presets: app.settings.presets(of: .refine,
                                                           language: app.settings.promptLanguage),
                             speak: speak)
            case .summary:
                SummaryLayout(controller: summarize,
                              presets: app.settings.presets(of: .summarize,
                                                            language: app.settings.promptLanguage),
                              speak: speak)
```

In `TextFeatures.live`, change the panel construction to
`QuickPanelView(panel: quickPanel, refine: refine, summarize: summarize, speak: speak, app: model)`.

- [ ] **Step 5: Add the shared control**

Create the control once and use it from both layouts. Add to `RefineLayout.swift`, above the
struct:

```swift
/// Play / Pause / Resume plus Stop for one text in the Quick Panel. Seeking is deliberately
/// absent: `AVSpeechSynthesizer` exposes no position, so a scrubber could not behave the same
/// on both speech sources (see the spec's Part 6).
struct SpeechControls: View {
    @ObservedObject var speak: SpeakController
    let source: SpeakSource
    let text: () -> String

    private var isActive: Bool { speak.active == source }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                if isActive {
                    speak.pauseOrResume()
                } else {
                    speak.speak(text(), from: source)
                }
            } label: {
                Icon(icon, size: 14)
            }
            .help(helpText)

            if isActive {
                Button { speak.stop() } label: {
                    Icon(.stop, size: 14)
                }
                .help("Stop reading")
            }
        }
    }

    private var icon: AppIcon {
        guard isActive else { return .speak }
        return speak.isPaused ? .play : .pause
    }

    private var helpText: String {
        guard isActive else { return "Read aloud" }
        return speak.isPaused ? "Resume reading" : "Pause reading"
    }
}
```

- [ ] **Step 6: Use it in both layouts**

`RefineLayout` gains `@ObservedObject var speak: SpeakController`, and `pane(title:text:side:)`
gains a `source: SpeakSource` parameter. In the pane header, between the title `Spacer()` and
the Copy button:

```swift
                SpeechControls(speak: speak, source: source, text: { text.wrappedValue })
```

Call it as `pane(title: "Original", text: $controller.original, side: .original, source: .refineOriginal)`
and `pane(title: "Refined", text: $controller.refined, side: .refined, source: .refineRefined)`.

`SummaryLayout` gains `@ObservedObject var speak: SpeakController`, and its `footer` gains,
before the Copy button:

```swift
            SpeechControls(speak: speak, source: .summary, text: { controller.summary })
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `npm run test:swift && npm run test:scripts && swift build --package-path macos`
Expected: PASS, and `git status` shows `pause.svg` added.

- [ ] **Step 8: Commit**

```bash
git add macos/Sources/Macomprendo macos/Tests/MacomprendoTests/UI/IconTests.swift
git commit -m "feat(quick-panel): read the panel's text aloud with pause and stop"
```

---

### Task 18: Documentation

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `docs/SMOKE_TEST.md`
- Modify: `docs/ARCHITECTURE.md`
- Modify: `AGENTS.md`

**Interfaces:**
- Consumes: everything above.
- Produces: no code.

- [ ] **Step 1: Add the smoke-test rows**

Add to `docs/SMOKE_TEST.md` (the Dock icon rows landed in Task 14):

| Step | Expected |
|---|---|
| Rebind "Refine selection" in Settings ▸ Hotkeys, then open the menubar menu | The new shortcut is shown beside the action; unbound actions read "not set" |
| Settings ▸ Dictation | The speech-model list is here and the Models tab is gone |
| Settings ▸ Speech, pick a voice under "Voice per language" | A short phrase is heard immediately in that voice and in that language |
| Turn off "Play a sample when a voice is selected", pick another voice | Nothing is heard |
| Edit the preview text, press Preview | The edited text is read, switching voices at the script boundary |
| Turn off "Switch voices for mixed-language text", press Preview | The whole text is read by the default voice, in one go |
| Refine a selection, press the speak button in the Refined pane | The refined text is read; no "Speaking…" HUD appears over the panel |
| Press pause, then resume, on both speech sources | Playback stops and continues where it left off, identically on both |
| While the panel is reading, press ⌥S | Playback stops; the selection is not re-read |
| Switch the language in the panel's globe menu | The preset list becomes that language's and the text is reprocessed |

- [ ] **Step 2: Update the changelog**

Add under `Unreleased`:

```markdown
### Added
- The menubar menu shows each action's current hotkey.
- Refine and Summarize have a working language, switchable from Settings and from the Quick
  Panel, with factory prompt sets in English, Russian, Spanish, German, French, Portuguese and
  Chinese, plus a new "Translate & organize" preset.
- Settings ▸ Speech maps a voice to each installed language, takes an editable preview text,
  explains how mixed-script text is split, can switch that splitting off, and plays a sample
  when a voice is picked.
- A Dock icon appears while the permissions wizard or the Settings window is open.
- The Quick Panel can read its text aloud, with pause, resume and stop.

### Changed
- The Models tab is gone; speech models are configured in Settings ▸ Dictation.
- The four summarize presets now state explicitly that the summary is written in the language
  of the text, instead of leaving it to the model to infer.
```

Both entries under Changed and the "Translate & organize" clause under Added describe changes
that became user-visible partway through the branch (Task 3), not at the end. They are recorded
here rather than in their own task because the branch merges as one unit; the changelog has to
read as one feature, not as eighteen partial entries that supersede each other.

- [ ] **Step 3: Update the architecture notes**

In `docs/ARCHITECTURE.md`, add `LanguageDetecting` and `ActivationPolicyControlling` to the list
of OS-facing protocols, and note that factory prompt presets are the cross product of
`FactoryPresets.Role` and `PromptLanguage` with UUIDs derived from their two slots.

- [ ] **Step 4: Update the agent instructions**

In `AGENTS.md` (never `CLAUDE.md` — it is a symlink), update the project map: the
`Features/Prompts` row mentions `Factory/` holding one content file per language, and the
Settings-tab list drops "Models".

- [ ] **Step 5: Strip this plan's task numbers out of shipped code**

Plan task numbers are meaningless once the branch merges. Run

```bash
grep -rn "Task [0-9]" macos/Sources/Macomprendo
```

and rewrite every comment this branch introduced so it says what the code does instead of which
task added it — at minimum `UI/Settings/PromptsTab.swift:12`, whose comment still says "Its
writer arrives in Task 6" although `setLanguage` is forty lines below it. Leave the older
`Plan N` references alone: they predate this branch and rewriting them is not this plan's work.

- [ ] **Step 6: Verify**

Run: `npm run test:swift && npm run test:scripts && npm run gen && git diff --exit-code macos/Macomprendo.xcodeproj`
Expected: everything green and `npm run gen` a no-op.

- [ ] **Step 7: Commit**

```bash
git add CHANGELOG.md docs AGENTS.md macos/Sources/Macomprendo
git commit -m "docs: record the settings rework"
```
