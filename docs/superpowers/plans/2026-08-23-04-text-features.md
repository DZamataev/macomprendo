# Macomprendo Text Features (Refine, Summarize, Speak) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make hotkeys #2–#5 (Dictate & Refine, Speak selection, Summarize selection, Refine selection) work end-to-end: read the selection, run it through a user-editable prompt preset on an LLM endpoint, stream the result into a floating Quick Panel, speak text aloud, and manage voices and presets in Settings.

**Architecture:** Everything OS-facing sits behind a protocol (`AXReading`, `SpeechSynthesizing`, `QuickPanelHosting`) so the three new `@MainActor` controllers are pure state machines that can be driven by scripted test doubles. Prompt presets are plain `Codable` data in `Settings` with a pure renderer/validator on top. `TextFeatures` is a single routing object that `AppModel` forwards non-dictation hotkey events to, which keeps the edit to Plan 3's `AppModel` down to one line.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI + AppKit, AVFoundation (`AVSpeechSynthesizer`), ApplicationServices (Accessibility API), swift-testing, Plan 1's `Icon`/`AppIcon` seam over vendored Phosphor SVGs.

**Spec:** `docs/superpowers/specs/2026-08-23-macomprendo-design.md` (§3.4 except dictation, §3.5 Quick Panel + Speech/Prompts tabs, §3.6, §4, §5)

**Shared interfaces:** `docs/superpowers/plans/2026-08-23-00-file-map-and-interfaces.md` — every type name used here is taken verbatim from that document unless listed under "Interface additions" below.

## Global Constraints

- Swift 6.0, strict concurrency; SwiftUI + AppKit; `platforms: [.macOS(.v14)]`; universal (arm64 + x86_64).
- Bundle id `com.dzamataev.macomprendo`; `DEVELOPMENT_TEAM 68QJJA7HK9`; copyright "© 2026 Denis Zamataev"; MIT.
- Product/module name `Macomprendo`; `LSUIElement = true`; not sandboxed; hardened runtime.
- SPM deps ONLY: whisper.cpp as a prebuilt xcframework via local package `macos/Packages/WhisperBinary` (product `Whisper`, module `whisper`; upstream has no Package.swift), `https://github.com/sindresorhus/KeyboardShortcuts` (from 2.0.0). Icons: Phosphor SVGs vendored from npm `@phosphor-icons/core` via `scripts/sync-icons.mjs` — the `phosphor-icons/swift` package is NOT used (breaks `swift build`).
- Tests: swift-testing (`import Testing`), run with `swift test --package-path macos`.
- No telemetry. API keys only in Keychain. Never log transcript/LLM text at default level.
- Pasteboard is always restored after a simulated ⌘C/⌘V.
- One in-flight action per controller; a new hotkey press cancels the previous task.
- Every failure surfaces as user-visible text with a recovery suggestion; nothing fails silently.

## Assumed starting point

Plans 1–3 are merged. Everything in the file map exists **except** the files this plan
creates. In particular these already exist and are used verbatim:
`Settings`, `PromptPreset`/`PresetKind` (struct only, no behaviour), `MacomprendoError`,
`PasteboardProtocol`/`PasteboardSnapshot`, `KeySimulating`, `AudioRecording`,
`TranscriptionProvider`, `PermissionsChecking`, `FrontmostAppTracking`, `TextInserting`,
`LLMProvider`/`ChatMessage`/`ChatOptions`, `ProviderFactory`, `HotkeyAction`/`HotkeyEvent`,
`HUDController`/`HUDState`, `DictationController`, `AppModel`, `AppEnvironment`,
`SettingsView` with the General/Hotkeys/Dictation/Providers/Models tabs.

## Interface additions beyond the file map

These types are new; they are defined in full inside the tasks below and stay inside this
plan's layer.

| Name | File | Why |
|---|---|---|
| `PresetError` | `Features/Prompts/PromptPreset.swift` | typed error for `Settings.deletePreset(id:)` |
| `Settings` preset helpers | `Features/Prompts/PromptPreset.swift` | `presets(of:)`, `preset(id:)`, `defaultPreset(for:)`, `defaultPresetID(for:)`, `setDefaultPreset(id:for:)`, `addPreset(_:)`, `updatePreset(_:)`, `deletePreset(id:)`, `movePreset(id:to:)` |
| `Toasting` | `Features/Toasting.swift` | one-method view of `HUDController` so controllers are testable without AppKit |
| `LLMTarget`, `FeatureConfigError` | `Features/LLMTarget.swift` | provider+model pair and the "not configured" error |
| widened `ErrorText.describe(_:)` | Plan 3's `ErrorText` file | it only handled `MacomprendoError`; now any `LocalizedError` plus `CancellationError` |
| `AppEnvironment.pasteboard/keySimulator/ax/speech/quickPanelHost` | `App/AppEnvironment.swift` | the services the new controllers need; `quickPanelHost` is nil in tests so no NSPanel is built |
| `AppModel.llmTarget(for:)`, `.textFeatures`, `.speechTabModel`, `.promptsTabModel` | `App/AppModel.swift` | composition, following Plan 3's `lazy var modelsViewModel` pattern |
| `SettingsHolding` | `App/SettingsHolding.swift` | read/write `Settings` from view models and the panel controller |
| `DictationCapture` | `Features/DictationCapture.swift` | mic → transcript state machine reused by `RefineController` |
| `QuickPanelHosting`, `QuickPanelWindow`, `FloatingPanelHost` | `UI/QuickPanel/...` | thin AppKit shell behind a protocol |
| `SpeechSynthesizing.onStateChange` | `Services/SpeechService.swift` | protocol is `@MainActor` and gains a change callback |
| `RefineController.handle(_:)`, `.drain()`; `SummarizeController.drain()` | Features | hotkey hold/toggle routing; async test hook |
| `SpeechTabModel`, `PromptsTabModel` | `UI/Settings/...` | testable view models |

---

### Task 1: Preset helpers on `Settings`

**Files:**
- Modify: `macos/Sources/Macomprendo/Features/Prompts/PromptPreset.swift`
- Test: `macos/Tests/MacomprendoTests/Features/PresetStoreTests.swift`

**Interfaces:**
- Consumes: `Settings`, `PromptPreset`, `PresetKind` (Plan 1).
- Produces: `PresetError`; `PresetKind.displayName`; `Settings.presets(of:)`, `preset(id:)`,
  `defaultPreset(for:)`, `defaultPresetID(for:)`, `setDefaultPreset(id:for:)`,
  `addPreset(_:) -> PromptPreset`, `updatePreset(_:)`, `deletePreset(id:) throws`,
  `movePreset(id:to:)`.

- [ ] **Step 1: Write the failing test**

Create `macos/Tests/MacomprendoTests/Features/PresetStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import Macomprendo

@Suite struct PresetStoreTests {
    private func preset(_ name: String, _ kind: PresetKind, _ order: Int) -> PromptPreset {
        PromptPreset(id: UUID(), kind: kind, name: name, systemPrompt: "sys",
                     userTemplate: "{text}", isFactory: false, sortOrder: order)
    }

    @Test func presetsOfKindAreSortedBySortOrder() {
        var s = Settings.default
        let b = preset("b", .refine, 1), a = preset("a", .refine, 0), z = preset("z", .summarize, 0)
        s.presets = [b, z, a]
        #expect(s.presets(of: .refine).map(\.name) == ["a", "b"])
        #expect(s.presets(of: .summarize).map(\.name) == ["z"])
    }

    @Test func addPresetAppendsAtEndOfItsKindAndBecomesDefaultWhenFirst() {
        var s = Settings.default
        s.presets = []
        s.defaultRefinePresetID = nil
        let first = s.addPreset(preset("first", .refine, 99))
        #expect(first.sortOrder == 0)
        #expect(s.defaultRefinePresetID == first.id)
        let second = s.addPreset(preset("second", .refine, 99))
        #expect(second.sortOrder == 1)
        #expect(s.defaultRefinePresetID == first.id)
    }

    @Test func defaultPresetFallsBackToFirstOfKind() {
        var s = Settings.default
        let a = preset("a", .refine, 0)
        s.presets = [a]
        s.defaultRefinePresetID = UUID()          // dangling
        #expect(s.defaultPreset(for: .refine)?.id == a.id)
    }

    @Test func deletingTheLastPresetOfAKindIsRefused() {
        var s = Settings.default
        let only = preset("only", .refine, 0)
        s.presets = [only]
        #expect(throws: PresetError.lastOfKind(.refine)) { try s.deletePreset(id: only.id) }
        #expect(s.presets.count == 1)
    }

    @Test func deletingTheDefaultMovesDefaultToFirstRemaining() throws {
        var s = Settings.default
        let a = preset("a", .refine, 0), b = preset("b", .refine, 1)
        s.presets = [a, b]
        s.defaultRefinePresetID = a.id
        try s.deletePreset(id: a.id)
        #expect(s.defaultRefinePresetID == b.id)
        #expect(s.presets(of: .refine).map(\.name) == ["b"])
    }

    @Test func deletingAnUnknownIDThrowsNotFound() {
        var s = Settings.default
        s.presets = [preset("a", .refine, 0), preset("b", .refine, 1)]
        #expect(throws: PresetError.notFound) { try s.deletePreset(id: UUID()) }
    }

    @Test func movePresetRenumbersOnlyItsOwnKind() {
        var s = Settings.default
        let a = preset("a", .refine, 0), b = preset("b", .refine, 1), c = preset("c", .refine, 2)
        let keep = preset("keep", .summarize, 7)
        s.presets = [a, b, c, keep]
        s.movePreset(id: c.id, to: 0)
        #expect(s.presets(of: .refine).map(\.name) == ["c", "a", "b"])
        #expect(s.preset(id: keep.id)?.sortOrder == 7)
    }

    @Test func updatePresetReplacesByID() {
        var s = Settings.default
        var a = preset("a", .refine, 0)
        s.presets = [a]
        a.name = "renamed"
        s.updatePreset(a)
        #expect(s.preset(id: a.id)?.name == "renamed")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path macos --filter PresetStoreTests`
Expected: build failure — `error: value of type 'Settings' has no member 'presets(of:)'` and
`error: cannot find 'PresetError' in scope`.

- [ ] **Step 3: Implement the helpers**

Append to `macos/Sources/Macomprendo/Features/Prompts/PromptPreset.swift` (keep the existing
`PresetKind` / `PromptPreset` declarations untouched):

```swift
enum PresetError: Error, LocalizedError, Equatable, Sendable {
    case lastOfKind(PresetKind)
    case notFound

    var errorDescription: String? {
        switch self {
        case .lastOfKind(let kind): "At least one \(kind.displayName.lowercased()) preset must exist."
        case .notFound: "That preset no longer exists."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .lastOfKind: "Add another preset first, then delete this one."
        case .notFound: "Reopen Settings and try again."
        }
    }
}

extension PresetKind {
    var displayName: String {
        switch self {
        case .refine: "Refine"
        case .summarize: "Summarize"
        }
    }
}

extension Settings {
    /// Presets of one kind, ordered by `sortOrder` (ties keep their storage order).
    func presets(of kind: PresetKind) -> [PromptPreset] {
        presets.enumerated()
            .filter { $0.element.kind == kind }
            .sorted { ($0.element.sortOrder, $0.offset) < ($1.element.sortOrder, $1.offset) }
            .map(\.element)
    }

    func preset(id: UUID) -> PromptPreset? { presets.first { $0.id == id } }

    func defaultPresetID(for kind: PresetKind) -> UUID? {
        switch kind {
        case .refine: defaultRefinePresetID
        case .summarize: defaultSummarizePresetID
        }
    }

    /// The configured default, or the first preset of that kind when the ID is missing/dangling.
    func defaultPreset(for kind: PresetKind) -> PromptPreset? {
        if let id = defaultPresetID(for: kind), let found = preset(id: id), found.kind == kind {
            return found
        }
        return presets(of: kind).first
    }

    mutating func setDefaultPreset(id: UUID, for kind: PresetKind) {
        switch kind {
        case .refine: defaultRefinePresetID = id
        case .summarize: defaultSummarizePresetID = id
        }
    }

    /// Appends the preset at the end of its kind and returns the stored value.
    @discardableResult
    mutating func addPreset(_ preset: PromptPreset) -> PromptPreset {
        var stored = preset
        stored.sortOrder = (presets(of: stored.kind).map(\.sortOrder).max() ?? -1) + 1
        presets.append(stored)
        if defaultPresetID(for: stored.kind) == nil { setDefaultPreset(id: stored.id, for: stored.kind) }
        return stored
    }

    mutating func updatePreset(_ preset: PromptPreset) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index] = preset
    }

    mutating func deletePreset(id: UUID) throws {
        guard let victim = preset(id: id) else { throw PresetError.notFound }
        guard presets(of: victim.kind).count > 1 else { throw PresetError.lastOfKind(victim.kind) }
        presets.removeAll { $0.id == id }
        if defaultPresetID(for: victim.kind) == id, let replacement = presets(of: victim.kind).first {
            setDefaultPreset(id: replacement.id, for: victim.kind)
        }
    }

    /// Moves a preset to `index` within its own kind and renumbers that kind 0..<n.
    mutating func movePreset(id: UUID, to index: Int) {
        guard let moved = preset(id: id) else { return }
        var ordered = presets(of: moved.kind)
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

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --package-path macos --filter PresetStoreTests`
Expected: PASS — 8 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Macomprendo/Features/Prompts/PromptPreset.swift \
        macos/Tests/MacomprendoTests/Features/PresetStoreTests.swift
git commit -m "feat(presets): add preset CRUD helpers to Settings"
```

---

### Task 2: Factory presets

**Files:**
- Create: `macos/Sources/Macomprendo/Features/Prompts/FactoryPresets.swift`
- Modify: `macos/Sources/Macomprendo/App/AppModel.swift`
- Test: `macos/Tests/MacomprendoTests/Features/FactoryPresetsTests.swift`

**Interfaces:**
- Consumes: Task 1's `Settings` helpers.
- Produces: `FactoryPresets.systemPrompt`, `FactoryPresets.ID.*` (fixed UUIDs),
  `FactoryPresets.defaultRefineID`, `FactoryPresets.defaultSummarizeID`,
  `FactoryPresets.all()`, `.refine()`, `.summarize()`, `.seed(into:)`, `.restoreMissing(into:)`.

- [ ] **Step 1: Write the failing test**

Create `macos/Tests/MacomprendoTests/Features/FactoryPresetsTests.swift`:

```swift
import Foundation
import Testing
@testable import Macomprendo

@Suite struct FactoryPresetsTests {
    @Test func allContainsSevenRefineAndFourSummarizePresets() {
        #expect(FactoryPresets.refine().count == 7)
        #expect(FactoryPresets.summarize().count == 4)
        #expect(FactoryPresets.all().count == 11)
        #expect(FactoryPresets.refine().allSatisfy { $0.kind == .refine && $0.isFactory })
        #expect(FactoryPresets.summarize().allSatisfy { $0.kind == .summarize && $0.isFactory })
    }

    @Test func namesMatchTheSpec() {
        #expect(FactoryPresets.refine().map(\.name)
                == ["Clean up", "Formal", "Casual", "Shorten", "Expand", "Fix grammar", "Translate"])
        #expect(FactoryPresets.summarize().map(\.name)
                == ["Brief", "Bullets", "TL;DR", "Key actions"])
    }

    @Test func everyFactoryTemplateContainsTextPlaceholderAndTranslateUsesLanguage() {
        #expect(FactoryPresets.all().allSatisfy { $0.userTemplate.contains("{text}") })
        let translate = FactoryPresets.all().first { $0.id == FactoryPresets.ID.translate }
        #expect(translate?.userTemplate.contains("{language}") == true)
    }

    @Test func idsAreStableAcrossCalls() {
        #expect(FactoryPresets.all().map(\.id) == FactoryPresets.all().map(\.id))
        #expect(FactoryPresets.all().first?.id == FactoryPresets.ID.cleanUp)
    }

    @Test func seedOnlyRunsOnceAndSetsDefaults() {
        var s = Settings.default
        s.presets = []
        s.presetsSeeded = false
        FactoryPresets.seed(into: &s)
        #expect(s.presets.count == 11)
        #expect(s.presetsSeeded)
        #expect(s.defaultRefinePresetID == FactoryPresets.ID.cleanUp)
        #expect(s.defaultSummarizePresetID == FactoryPresets.ID.brief)

        s.presets.removeAll { $0.id == FactoryPresets.ID.formal }
        FactoryPresets.seed(into: &s)                 // second call is a no-op
        #expect(s.presets.count == 10)
    }

    @Test func restoreMissingReaddsFactoryPresetsWithoutTouchingCustomOnes() {
        var s = Settings.default
        s.presets = []
        s.presetsSeeded = false
        FactoryPresets.seed(into: &s)
        let custom = s.addPreset(PromptPreset(id: UUID(), kind: .refine, name: "Mine",
                                              systemPrompt: "s", userTemplate: "{text}",
                                              isFactory: false, sortOrder: 0))
        s.presets.removeAll { $0.id == FactoryPresets.ID.casual }
        s.presets.removeAll { $0.id == FactoryPresets.ID.tldr }

        FactoryPresets.restoreMissing(into: &s)

        #expect(s.preset(id: FactoryPresets.ID.casual) != nil)
        #expect(s.preset(id: FactoryPresets.ID.tldr) != nil)
        #expect(s.preset(id: custom.id)?.name == "Mine")
        #expect(s.presets.filter { $0.id == custom.id }.count == 1)
        #expect(s.presets(of: .refine).last?.id == FactoryPresets.ID.casual)   // appended at the end
    }

    @Test func restoreMissingRepairsADanglingDefault() {
        var s = Settings.default
        s.presets = []
        s.presetsSeeded = false
        FactoryPresets.seed(into: &s)
        s.defaultRefinePresetID = UUID()
        FactoryPresets.restoreMissing(into: &s)
        #expect(s.defaultRefinePresetID == FactoryPresets.ID.cleanUp)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path macos --filter FactoryPresetsTests`
Expected: build failure — `error: cannot find 'FactoryPresets' in scope`.

- [ ] **Step 3: Implement `FactoryPresets`**

Create `macos/Sources/Macomprendo/Features/Prompts/FactoryPresets.swift`:

```swift
import Foundation

/// The presets shipped with the app. They are seeded once into `Settings.presets` and are
/// ordinary user data afterwards: editable, reorderable and deletable. The IDs are fixed so
/// `restoreMissing(into:)` can tell "deleted factory preset" from "custom preset".
enum FactoryPresets {
    static let systemPrompt = """
        You are a careful writing assistant. Process the user's text exactly as instructed. \
        Return only the resulting text — no commentary, no explanation, no quotation marks \
        around the output and no markdown code fences.
        """

    enum ID {
        static let cleanUp = UUID(uuidString: "F0000000-0000-0000-0000-000000000001")!
        static let formal = UUID(uuidString: "F0000000-0000-0000-0000-000000000002")!
        static let casual = UUID(uuidString: "F0000000-0000-0000-0000-000000000003")!
        static let shorten = UUID(uuidString: "F0000000-0000-0000-0000-000000000004")!
        static let expand = UUID(uuidString: "F0000000-0000-0000-0000-000000000005")!
        static let fixGrammar = UUID(uuidString: "F0000000-0000-0000-0000-000000000006")!
        static let translate = UUID(uuidString: "F0000000-0000-0000-0000-000000000007")!
        static let brief = UUID(uuidString: "F0000000-0000-0000-0000-000000000101")!
        static let bullets = UUID(uuidString: "F0000000-0000-0000-0000-000000000102")!
        static let tldr = UUID(uuidString: "F0000000-0000-0000-0000-000000000103")!
        static let keyActions = UUID(uuidString: "F0000000-0000-0000-0000-000000000104")!
    }

    static let defaultRefineID = ID.cleanUp
    static let defaultSummarizeID = ID.brief

    static func all() -> [PromptPreset] { refine() + summarize() }

    static func refine() -> [PromptPreset] {
        [
            make(ID.cleanUp, .refine, 0, "Clean up", """
                Clean up the following text. Remove filler words, false starts and stutters, and \
                fix punctuation and capitalization. Keep the meaning, the tone and the original language.
                {instruction}

                {text}
                """),
            make(ID.formal, .refine, 1, "Formal", """
                Rewrite the following text in a formal, professional register. Keep the meaning \
                and the original language.
                {instruction}

                {text}
                """),
            make(ID.casual, .refine, 2, "Casual", """
                Rewrite the following text in a relaxed, conversational register. Keep the meaning \
                and the original language.
                {instruction}

                {text}
                """),
            make(ID.shorten, .refine, 3, "Shorten", """
                Rewrite the following text so it is significantly shorter while keeping every \
                important point. Keep the original language.
                {instruction}

                {text}
                """),
            make(ID.expand, .refine, 4, "Expand", """
                Expand the following text with more detail and clearer structure. Do not invent \
                facts. Keep the original language.
                {instruction}

                {text}
                """),
            make(ID.fixGrammar, .refine, 5, "Fix grammar", """
                Correct spelling, grammar and punctuation in the following text. Change nothing \
                else — keep the wording, the tone and the original language.
                {instruction}

                {text}
                """),
            make(ID.translate, .refine, 6, "Translate", """
                Translate the following text into {language}. Preserve the tone and the formatting.
                {instruction}

                {text}
                """),
        ]
    }

    static func summarize() -> [PromptPreset] {
        [
            make(ID.brief, .summarize, 0, "Brief", """
                Summarize the following text in two or three sentences.
                {instruction}

                {text}
                """),
            make(ID.bullets, .summarize, 1, "Bullets", """
                Summarize the following text as at most six concise bullet points, one line each, \
                each starting with "- ".
                {instruction}

                {text}
                """),
            make(ID.tldr, .summarize, 2, "TL;DR", """
                Give a one-sentence TL;DR of the following text.
                {instruction}

                {text}
                """),
            make(ID.keyActions, .summarize, 3, "Key actions", """
                List the concrete action items in the following text as a numbered list. \
                If there are none, answer exactly "No action items."
                {instruction}

                {text}
                """),
        ]
    }

    /// First-run seeding. Does nothing once `presetsSeeded` is true.
    static func seed(into settings: inout Settings) {
        guard !settings.presetsSeeded else { return }
        settings.presets = all()
        settings.presetsSeeded = true
        settings.defaultRefinePresetID = defaultRefineID
        settings.defaultSummarizePresetID = defaultSummarizeID
    }

    /// Re-adds factory presets the user deleted, appended at the end of their kind.
    /// Existing presets — factory or custom — are never modified.
    static func restoreMissing(into settings: inout Settings) {
        let existing = Set(settings.presets.map(\.id))
        for factory in all() where !existing.contains(factory.id) {
            settings.addPreset(factory)
        }
        settings.presetsSeeded = true
        for kind in PresetKind.allCases {
            let current = settings.defaultPresetID(for: kind)
            if current == nil || settings.preset(id: current!) == nil,
               let first = settings.presets(of: kind).first {
                settings.setDefaultPreset(id: first.id, for: kind)
            }
        }
    }

    private static func make(_ id: UUID, _ kind: PresetKind, _ order: Int,
                             _ name: String, _ template: String) -> PromptPreset {
        PromptPreset(id: id, kind: kind, name: name, systemPrompt: systemPrompt,
                     userTemplate: template, isFactory: true, sortOrder: order)
    }
}
```

Note: `restoreMissing` uses `addPreset`, which already appends at `max(sortOrder) + 1` for the
kind, so a restored preset lands at the end of its list and no existing `sortOrder` changes.
The dangling-default repair prefers `ID.cleanUp` in the seeded case because it is the first
refine preset by `sortOrder`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --package-path macos --filter FactoryPresetsTests`
Expected: PASS — 7 tests, 0 failures.

- [ ] **Step 5: Seed on launch**

Open `macos/Sources/Macomprendo/App/AppModel.swift` and add these four lines at the very end
of `init(store:keychain:)`, after `settings` has been loaded:

```swift
        var seeded = settings
        FactoryPresets.seed(into: &seeded)
        if seeded != settings { settings = seeded }
```

(The `if` keeps the `didSet` persist hook from firing on every launch; `Settings` is `Equatable`.)

- [ ] **Step 6: Verify the build**

Run: `swift build --package-path macos`
Expected: `Build complete!`

- [ ] **Step 7: Commit**

```bash
git add macos/Sources/Macomprendo/Features/Prompts/FactoryPresets.swift \
        macos/Sources/Macomprendo/App/AppModel.swift \
        macos/Tests/MacomprendoTests/Features/FactoryPresetsTests.swift
git commit -m "feat(presets): seed factory refine and summarize presets"
```

---

### Task 3: `PromptRenderer`

**Files:**
- Create: `macos/Sources/Macomprendo/Features/Prompts/PromptRenderer.swift`
- Test: `macos/Tests/MacomprendoTests/Features/PromptRendererTests.swift`

**Interfaces:**
- Consumes: `PromptPreset`, `ChatMessage`/`ChatRole` (Plan 2), `FactoryPresets` (Task 2).
- Produces: `RenderedPrompt { var messages: [ChatMessage] }`,
  `PromptRenderer.validate(_:) -> [String]`,
  `PromptRenderer.render(_:text:instruction:language:) -> RenderedPrompt`,
  `PromptRenderer.placeholders(in:) -> Set<String>`,
  `PromptRenderer.knownPlaceholders`, `PromptRenderer.defaultLanguage`.

- [ ] **Step 1: Write the failing test**

Create `macos/Tests/MacomprendoTests/Features/PromptRendererTests.swift`:

```swift
import Foundation
import Testing
@testable import Macomprendo

@Suite struct PromptRendererTests {
    private func preset(system: String = "SYS",
                        template: String = "Do it.\n{instruction}\n\n{text}",
                        name: String = "P") -> PromptPreset {
        PromptPreset(id: UUID(), kind: .refine, name: name, systemPrompt: system,
                     userTemplate: template, isFactory: false, sortOrder: 0)
    }

    // MARK: validate

    @Test func validAllPresetsFromTheFactoryHaveNoProblems() {
        for factory in FactoryPresets.all() {
            #expect(PromptRenderer.validate(factory).isEmpty, "\(factory.name) should validate")
        }
    }

    @Test func missingTextPlaceholderIsAProblem() {
        let problems = PromptRenderer.validate(preset(template: "Just do something"))
        #expect(problems.contains("The user template must contain {text}."))
    }

    @Test func unknownPlaceholderIsFlagged() {
        let problems = PromptRenderer.validate(preset(template: "{text} {tone}"))
        #expect(problems.contains { $0.contains("{tone}") })
    }

    @Test func emptyNameIsAProblem() {
        let problems = PromptRenderer.validate(preset(name: "   "))
        #expect(problems.contains("Name must not be empty."))
    }

    @Test func unknownPlaceholderInSystemPromptIsFlagged() {
        let problems = PromptRenderer.validate(preset(system: "Speak like {robot}"))
        #expect(problems.contains { $0.contains("{robot}") && $0.contains("system prompt") })
    }

    @Test func placeholdersAreExtractedIgnoringNonIdentifierBraces() {
        #expect(PromptRenderer.placeholders(in: "{text} and {instruction} and { not this }")
                == ["text", "instruction"])
    }

    // MARK: render

    @Test func systemAndUserMessagesAreProduced() {
        let r = PromptRenderer.render(preset(), text: "hello", instruction: "be nice", language: nil)
        #expect(r.messages.count == 2)
        #expect(r.messages[0] == ChatMessage(role: .system, content: "SYS"))
        #expect(r.messages[1].role == .user)
        #expect(r.messages[1].content == "Do it.\nbe nice\n\nhello")
    }

    @Test func emptyInstructionRemovesItsLine() {
        let r = PromptRenderer.render(preset(), text: "hello", instruction: "   ", language: nil)
        #expect(r.messages[1].content == "Do it.\n\nhello")
    }

    @Test func nilInstructionRemovesItsLine() {
        let r = PromptRenderer.render(preset(), text: "hello", instruction: nil, language: nil)
        #expect(r.messages[1].content == "Do it.\n\nhello")
    }

    @Test func aLineHoldingBothTextAndInstructionIsKept() {
        let p = preset(template: "Rewrite {text} {instruction}")
        let r = PromptRenderer.render(p, text: "hi", instruction: nil, language: nil)
        #expect(r.messages[1].content == "Rewrite hi ")
    }

    @Test func languageDefaultsToEnglishWhenMissing() {
        let p = preset(template: "Into {language}: {text}")
        #expect(PromptRenderer.render(p, text: "x", instruction: nil, language: nil)
                .messages[1].content == "Into English: x")
        #expect(PromptRenderer.render(p, text: "x", instruction: nil, language: "Spanish")
                .messages[1].content == "Into Spanish: x")
    }

    @Test func emptySystemPromptYieldsOnlyTheUserMessage() {
        let r = PromptRenderer.render(preset(system: "  "), text: "x", instruction: nil, language: nil)
        #expect(r.messages.count == 1)
        #expect(r.messages[0].role == .user)
    }

    @Test func placeholdersInsideTheUserTextAreNotSubstituted() {
        let r = PromptRenderer.render(preset(), text: "say {instruction} now", instruction: "loud", language: nil)
        #expect(r.messages[1].content == "Do it.\nloud\n\nsay {instruction} now")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path macos --filter PromptRendererTests`
Expected: build failure — `error: cannot find 'PromptRenderer' in scope`.

- [ ] **Step 3: Implement `PromptRenderer`**

Create `macos/Sources/Macomprendo/Features/Prompts/PromptRenderer.swift`:

```swift
import Foundation

struct RenderedPrompt: Equatable, Sendable {
    var messages: [ChatMessage]
}

/// Pure validation + substitution for prompt templates. No I/O, no state.
enum PromptRenderer {
    static let knownPlaceholders: Set<String> = ["text", "instruction", "language"]
    static let defaultLanguage = "English"

    /// Returns a list of user-facing problems; an empty array means the preset is usable.
    static func validate(_ preset: PromptPreset) -> [String] {
        var problems: [String] = []
        if preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems.append("Name must not be empty.")
        }
        if !preset.userTemplate.contains("{text}") {
            problems.append("The user template must contain {text}.")
        }
        for name in placeholders(in: preset.userTemplate).subtracting(knownPlaceholders).sorted() {
            problems.append("Unknown placeholder {\(name)}. Supported: {text}, {instruction}, {language}.")
        }
        for name in placeholders(in: preset.systemPrompt).subtracting(knownPlaceholders).sorted() {
            problems.append("Unknown placeholder {\(name)} in the system prompt. Supported: {text}, {instruction}, {language}.")
        }
        return problems
    }

    /// Every `{identifier}` occurrence; braces around anything else are ignored.
    static func placeholders(in template: String) -> Set<String> {
        var found: Set<String> = []
        var rest = template[...]
        while let open = rest.firstIndex(of: "{") {
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "}") else { break }
            let name = String(rest[afterOpen..<close])
            if !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                found.insert(name)
            }
            rest = rest[rest.index(after: close)...]
        }
        return found
    }

    /// Substitutes the placeholders and builds the chat messages.
    ///
    /// - A template line that mentions `{instruction}` but not `{text}` is dropped entirely when
    ///   the instruction is nil or blank, so an unused instruction never leaves an empty line.
    /// - `{language}` falls back to `defaultLanguage`.
    /// - `{text}` is substituted last so placeholder-looking text from the user is left alone.
    static func render(_ preset: PromptPreset, text: String,
                       instruction: String?, language: String?) -> RenderedPrompt {
        let instruction = (instruction ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawLanguage = (language ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let language = rawLanguage.isEmpty ? defaultLanguage : rawLanguage

        var lines: [String] = []
        for line in preset.userTemplate.components(separatedBy: "\n") {
            if instruction.isEmpty, line.contains("{instruction}"), !line.contains("{text}") { continue }
            lines.append(line
                .replacingOccurrences(of: "{instruction}", with: instruction)
                .replacingOccurrences(of: "{language}", with: language)
                .replacingOccurrences(of: "{text}", with: text))
        }

        var messages: [ChatMessage] = []
        let system = preset.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty { messages.append(ChatMessage(role: .system, content: system)) }
        messages.append(ChatMessage(role: .user, content: lines.joined(separator: "\n")))
        return RenderedPrompt(messages: messages)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --package-path macos --filter PromptRendererTests`
Expected: PASS — 13 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Macomprendo/Features/Prompts/PromptRenderer.swift \
        macos/Tests/MacomprendoTests/Features/PromptRendererTests.swift
git commit -m "feat(presets): add prompt template validation and rendering"
```

---

### Task 4: `SelectedTextService` (AX read + ⌘C fallback)

**Files:**
- Create: `macos/Sources/Macomprendo/Services/SelectedTextService.swift`
- Create: `macos/Tests/MacomprendoTests/Fakes/ScriptedPasteboard.swift`
- Create: `macos/Tests/MacomprendoTests/Fakes/ScriptedKeySimulator.swift`
- Create: `macos/Tests/MacomprendoTests/Fakes/ScriptedAXReader.swift`
- Test: `macos/Tests/MacomprendoTests/Services/SelectedTextServiceTests.swift`

**Interfaces:**
- Consumes: `PasteboardProtocol`, `PasteboardSnapshot`, `KeySimulating`, `MacomprendoError` (Plans 1/3).
- Produces: `protocol SelectedTextReading: Sendable { func read() async throws -> String }`,
  `protocol AXReading: Sendable { func focusedSelectedText() -> String? }`,
  `struct SystemAXReader: AXReading`,
  `struct AXSelectedTextService: SelectedTextReading` with
  `init(ax:pasteboard:keySimulator:copyTimeout:pollInterval:)`.

> Test doubles: this plan ships its own doubles named `Scripted*` so its tests never depend on
> the internal shape of Plan 3's `Fake*` doubles. Both can coexist in the test target.

- [ ] **Step 1: Make `PasteboardProtocol` `Sendable`**

`AXSelectedTextService` is a `Sendable` struct holding `any PasteboardProtocol`, so the protocol
must be `Sendable`. Open `macos/Sources/Macomprendo/Core/Pasteboard.swift` and confirm the
declaration reads:

```swift
protocol PasteboardProtocol: AnyObject, Sendable {
```

If `Sendable` is missing, add it (Plan 3's `PasteTextInserter` — also a `Sendable` struct holding
a pasteboard — needs the same). Then run `swift build --package-path macos` and confirm
`Build complete!`; `SystemPasteboard` and `FakePasteboard` may need `@unchecked Sendable` and an
internal `NSLock` if the compiler flags them.

- [ ] **Step 2: Write the test doubles**

Create `macos/Tests/MacomprendoTests/Fakes/ScriptedPasteboard.swift`:

```swift
import Foundation
@testable import Macomprendo

/// In-memory `PasteboardProtocol` with a change counter that behaves like NSPasteboard's.
final class ScriptedPasteboard: PasteboardProtocol, @unchecked Sendable {
    static let utf8Type = "public.utf8-plain-text"

    private let lock = NSLock()
    private var items: [[String: Data]] = []
    private var count = 0
    private var restores = 0

    init(initialString: String? = nil) {
        if let initialString { writeString(initialString) }
    }

    var changeCount: Int { lock.withLock { count } }
    var restoreCount: Int { lock.withLock { restores } }

    func readString() -> String? {
        lock.withLock {
            items.last?[Self.utf8Type].flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    func writeString(_ s: String) {
        lock.withLock {
            items = [[Self.utf8Type: Data(s.utf8)]]
            count += 1
        }
    }

    func snapshot() -> PasteboardSnapshot {
        PasteboardSnapshot(items: lock.withLock { items })
    }

    func restore(_ snapshot: PasteboardSnapshot) {
        lock.withLock {
            items = snapshot.items
            count += 1
            restores += 1
        }
    }
}
```

Create `macos/Tests/MacomprendoTests/Fakes/ScriptedKeySimulator.swift`:

```swift
import Foundation
@testable import Macomprendo

/// Records ⌘-key presses and lets a test simulate the side effect of the press.
final class ScriptedKeySimulator: KeySimulating, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [Character] = []

    /// Called on every press — e.g. to write text into a `ScriptedPasteboard`.
    var onPress: (@Sendable (Character) -> Void)?

    var presses: [Character] { lock.withLock { keys } }

    func pressCommand(_ key: Character) async {
        lock.withLock { keys.append(key) }
        onPress?(key)
    }
}
```

Create `macos/Tests/MacomprendoTests/Fakes/ScriptedAXReader.swift`:

```swift
import Foundation
@testable import Macomprendo

struct ScriptedAXReader: AXReading {
    var text: String?
    func focusedSelectedText() -> String? { text }
}
```

- [ ] **Step 3: Write the failing test**

Create `macos/Tests/MacomprendoTests/Services/SelectedTextServiceTests.swift`:

```swift
import Foundation
import Testing
@testable import Macomprendo

@Suite struct SelectedTextServiceTests {
    private func service(ax: String?, pasteboard: ScriptedPasteboard,
                         keys: ScriptedKeySimulator) -> AXSelectedTextService {
        AXSelectedTextService(ax: ScriptedAXReader(text: ax), pasteboard: pasteboard,
                              keySimulator: keys, copyTimeout: 0.05, pollInterval: 0.005)
    }

    @Test func accessibilityTextIsReturnedWithoutTouchingThePasteboard() async throws {
        let pasteboard = ScriptedPasteboard(initialString: "user clipboard")
        let keys = ScriptedKeySimulator()
        let text = try await service(ax: "  selected words \n", pasteboard: pasteboard, keys: keys).read()
        #expect(text == "selected words")
        #expect(keys.presses.isEmpty)
        #expect(pasteboard.readString() == "user clipboard")
    }

    @Test func fallsBackToCommandCAndRestoresThePasteboard() async throws {
        let pasteboard = ScriptedPasteboard(initialString: "user clipboard")
        let keys = ScriptedKeySimulator()
        keys.onPress = { key in if key == "c" { pasteboard.writeString("copied selection") } }

        let text = try await service(ax: nil, pasteboard: pasteboard, keys: keys).read()

        #expect(text == "copied selection")
        #expect(keys.presses == ["c"])
        #expect(pasteboard.readString() == "user clipboard")
        #expect(pasteboard.restoreCount == 1)
    }

    @Test func whitespaceOnlyAccessibilityTextFallsBackToCopy() async throws {
        let pasteboard = ScriptedPasteboard(initialString: "clip")
        let keys = ScriptedKeySimulator()
        keys.onPress = { _ in pasteboard.writeString("from copy") }
        let text = try await service(ax: "   ", pasteboard: pasteboard, keys: keys).read()
        #expect(text == "from copy")
        #expect(keys.presses == ["c"])
    }

    @Test func throwsNoSelectionWhenNothingIsCopied() async {
        let pasteboard = ScriptedPasteboard(initialString: "clip")
        let keys = ScriptedKeySimulator()          // no onPress: the change count never moves
        await #expect(throws: MacomprendoError.noSelection) {
            try await service(ax: nil, pasteboard: pasteboard, keys: keys).read()
        }
        #expect(pasteboard.readString() == "clip")
        #expect(pasteboard.restoreCount == 1)
    }

    @Test func throwsNoSelectionWhenTheCopiedTextIsBlank() async {
        let pasteboard = ScriptedPasteboard(initialString: "clip")
        let keys = ScriptedKeySimulator()
        keys.onPress = { _ in pasteboard.writeString("   \n ") }
        await #expect(throws: MacomprendoError.noSelection) {
            try await service(ax: nil, pasteboard: pasteboard, keys: keys).read()
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `swift test --package-path macos --filter SelectedTextServiceTests`
Expected: build failure — `error: cannot find 'AXSelectedTextService' in scope`.

- [ ] **Step 5: Implement the service**

Create `macos/Sources/Macomprendo/Services/SelectedTextService.swift`:

```swift
import ApplicationServices
import Foundation

protocol SelectedTextReading: Sendable {
    /// The current selection, trimmed. Throws `MacomprendoError.noSelection` when there is none.
    func read() async throws -> String
}

protocol AXReading: Sendable {
    /// `kAXSelectedTextAttribute` of the system-wide focused element, or nil when unavailable.
    func focusedSelectedText() -> String?
}

struct SystemAXReader: AXReading {
    func focusedSelectedText() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString,
                                            &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return nil }

        // Safe: the CFTypeID check above proves this is an AXUIElement.
        let element = focusedRef as! AXUIElement
        var selectedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                            &selectedRef) == .success,
              let text = selectedRef as? String
        else { return nil }
        return text
    }
}

/// Reads the selection through the Accessibility API, falling back to a simulated ⌘C.
/// The fallback snapshots the pasteboard first and always restores it.
struct AXSelectedTextService: SelectedTextReading {
    private let ax: any AXReading
    private let pasteboard: any PasteboardProtocol
    private let keySimulator: any KeySimulating
    private let copyTimeout: TimeInterval
    private let pollInterval: TimeInterval

    init(ax: any AXReading,
         pasteboard: any PasteboardProtocol,
         keySimulator: any KeySimulating,
         copyTimeout: TimeInterval = 0.3,
         pollInterval: TimeInterval = 0.02) {
        self.ax = ax
        self.pasteboard = pasteboard
        self.keySimulator = keySimulator
        self.copyTimeout = copyTimeout
        self.pollInterval = pollInterval
    }

    func read() async throws -> String {
        if let direct = ax.focusedSelectedText() {
            let trimmed = direct.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return try await readViaCopy()
    }

    private func readViaCopy() async throws -> String {
        let snapshot = pasteboard.snapshot()
        let before = pasteboard.changeCount

        await keySimulator.pressCommand("c")

        var copied: String?
        var waited: TimeInterval = 0
        while waited < copyTimeout {
            if pasteboard.changeCount != before {
                copied = pasteboard.readString()
                break
            }
            try? await Task.sleep(for: .seconds(pollInterval))
            waited += pollInterval
        }

        pasteboard.restore(snapshot)

        let trimmed = (copied ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MacomprendoError.noSelection }
        return trimmed
    }
}
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `swift test --package-path macos --filter SelectedTextServiceTests`
Expected: PASS — 5 tests, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add macos/Sources/Macomprendo/Services/SelectedTextService.swift \
        macos/Sources/Macomprendo/Core/Pasteboard.swift \
        macos/Tests/MacomprendoTests/Fakes/ScriptedPasteboard.swift \
        macos/Tests/MacomprendoTests/Fakes/ScriptedKeySimulator.swift \
        macos/Tests/MacomprendoTests/Fakes/ScriptedAXReader.swift \
        macos/Tests/MacomprendoTests/Services/SelectedTextServiceTests.swift
git commit -m "feat(services): read the selection via AX with a clipboard fallback"
```

---

### Task 5: `SpeechService`

**Files:**
- Create: `macos/Sources/Macomprendo/Services/SpeechService.swift`
- Create: `macos/Tests/MacomprendoTests/Fakes/ScriptedSpeech.swift`
- Test: `macos/Tests/MacomprendoTests/Services/SpeechServiceTests.swift`

**Interfaces:**
- Consumes: `SpeechSettings` (Plan 1).
- Produces: `struct Voice: Identifiable, Sendable, Equatable { let id, name, language, quality: String }`,
  `@MainActor protocol SpeechSynthesizing: AnyObject` with
  `var isSpeaking: Bool { get }`, `var onStateChange: (@MainActor () -> Void)? { get set }`,
  `func voices() -> [Voice]`, `func speak(_:settings:)`, `func stop()`;
  `@MainActor final class AVSpeechService: NSObject, SpeechSynthesizing` plus the pure helpers
  `AVSpeechService.qualityLabel(_:)`, `.clampedRate(_:)`, `.clampedPitch(_:)`, `.clampedVolume(_:)`.

> Deviation from the map: `SpeechSynthesizing` is `@MainActor` (AVFoundation's synthesizer and
> every consumer are main-actor bound) and gains `onStateChange` so controllers learn when the
> utterance finishes on its own.

- [ ] **Step 1: Write the test double**

Create `macos/Tests/MacomprendoTests/Fakes/ScriptedSpeech.swift`:

```swift
import Foundation
@testable import Macomprendo

@MainActor final class ScriptedSpeech: SpeechSynthesizing {
    struct Spoken: Equatable {
        var text: String
        var settings: SpeechSettings
    }

    var isSpeaking = false
    var onStateChange: (@MainActor () -> Void)?
    var available: [Voice] = []
    private(set) var spoken: [Spoken] = []
    private(set) var stopCount = 0

    func voices() -> [Voice] { available }

    func speak(_ text: String, settings: SpeechSettings) {
        spoken.append(Spoken(text: text, settings: settings))
        isSpeaking = true
        onStateChange?()
    }

    func stop() {
        stopCount += 1
        isSpeaking = false
        onStateChange?()
    }

    /// Simulates the synthesizer reaching the end of the utterance.
    func finish() {
        isSpeaking = false
        onStateChange?()
    }
}
```

- [ ] **Step 2: Write the failing test**

Create `macos/Tests/MacomprendoTests/Services/SpeechServiceTests.swift`:

```swift
import AVFoundation
import Foundation
import Testing
@testable import Macomprendo

@Suite struct SpeechServiceTests {
    @Test func qualityLabelsCoverTheThreeAVQualities() {
        #expect(AVSpeechService.qualityLabel(.default) == "default")
        #expect(AVSpeechService.qualityLabel(.enhanced) == "enhanced")
        #expect(AVSpeechService.qualityLabel(.premium) == "premium")
    }

    @Test func rateIsClampedToTheAVRange() {
        #expect(AVSpeechService.clampedRate(-1) == AVSpeechUtteranceMinimumSpeechRate)
        #expect(AVSpeechService.clampedRate(99) == AVSpeechUtteranceMaximumSpeechRate)
        #expect(AVSpeechService.clampedRate(0.5) == 0.5)
    }

    @Test func pitchAndVolumeAreClamped() {
        #expect(AVSpeechService.clampedPitch(0.1) == 0.5)
        #expect(AVSpeechService.clampedPitch(9) == 2.0)
        #expect(AVSpeechService.clampedPitch(1.0) == 1.0)
        #expect(AVSpeechService.clampedVolume(-2) == 0)
        #expect(AVSpeechService.clampedVolume(5) == 1)
        #expect(AVSpeechService.clampedVolume(0.4) == 0.4)
    }

    @MainActor
    @Test func theDoubleRecordsSpeakAndStop() {
        let speech = ScriptedSpeech()
        var changes = 0
        speech.onStateChange = { changes += 1 }

        speech.speak("hello", settings: SpeechSettings(voiceID: "v", rate: 0.5, pitch: 1, volume: 1))
        #expect(speech.isSpeaking)
        #expect(speech.spoken.map(\.text) == ["hello"])

        speech.stop()
        #expect(!speech.isSpeaking)
        #expect(speech.stopCount == 1)
        #expect(changes == 2)
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --package-path macos --filter SpeechServiceTests`
Expected: build failure — `error: cannot find 'AVSpeechService' in scope`.

- [ ] **Step 4: Implement the service**

Create `macos/Sources/Macomprendo/Services/SpeechService.swift`:

```swift
import AVFoundation
import Foundation

struct Voice: Identifiable, Sendable, Equatable {
    let id: String          // AVSpeechSynthesisVoice.identifier
    let name: String
    let language: String    // BCP-47, e.g. "en-US"
    let quality: String     // "default" | "enhanced" | "premium"
}

@MainActor protocol SpeechSynthesizing: AnyObject {
    var isSpeaking: Bool { get }
    /// Called whenever `isSpeaking` changes, including when an utterance finishes by itself.
    var onStateChange: (@MainActor () -> Void)? { get set }
    func voices() -> [Voice]
    func speak(_ text: String, settings: SpeechSettings)
    func stop()
}

@MainActor final class AVSpeechService: NSObject, SpeechSynthesizing {
    private let synthesizer = AVSpeechSynthesizer()
    private(set) var isSpeaking = false
    var onStateChange: (@MainActor () -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    static func qualityLabel(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .enhanced: "enhanced"
        case .premium: "premium"
        default: "default"
        }
    }

    static func clampedRate(_ rate: Float) -> Float {
        min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
    }

    static func clampedPitch(_ pitch: Float) -> Float { min(max(pitch, 0.5), 2.0) }

    static func clampedVolume(_ volume: Float) -> Float { min(max(volume, 0), 1) }

    func voices() -> [Voice] {
        AVSpeechSynthesisVoice.speechVoices().map { voice in
            Voice(id: voice.identifier, name: voice.name, language: voice.language,
                  quality: Self.qualityLabel(voice.quality))
        }
    }

    func speak(_ text: String, settings: SpeechSettings) {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: text)
        if let id = settings.voiceID, let voice = AVSpeechSynthesisVoice(identifier: id) {
            utterance.voice = voice
        }
        utterance.rate = Self.clampedRate(settings.rate)
        utterance.pitchMultiplier = Self.clampedPitch(settings.pitch)
        utterance.volume = Self.clampedVolume(settings.volume)
        setSpeaking(true)
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        setSpeaking(false)
    }

    fileprivate func setSpeaking(_ value: Bool) {
        guard isSpeaking != value else { return }
        isSpeaking = value
        onStateChange?()
    }
}

extension AVSpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.setSpeaking(false) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.setSpeaking(false) }
    }
}
```

The delegate methods are `nonisolated` and hop to the main actor; they deliberately capture
nothing but `self` (a `@MainActor` class, therefore implicitly `Sendable`).

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --package-path macos --filter SpeechServiceTests`
Expected: PASS — 4 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add macos/Sources/Macomprendo/Services/SpeechService.swift \
        macos/Tests/MacomprendoTests/Fakes/ScriptedSpeech.swift \
        macos/Tests/MacomprendoTests/Services/SpeechServiceTests.swift
git commit -m "feat(services): add AVSpeechSynthesizer-backed speech service"
```

---

### Task 6: Feature support types (`Toasting`, `LLMTarget`, `SettingsHolding`)

**Files:**
- Create: `macos/Sources/Macomprendo/Features/Toasting.swift`
- Create: `macos/Sources/Macomprendo/Features/LLMTarget.swift`
- Create: `macos/Sources/Macomprendo/App/SettingsHolding.swift`
- Modify: the file declaring `enum ErrorText` (Plan 3 put it beside `DictationController`; find it with
  `grep -rn "enum ErrorText" macos/Sources`)
- Create: `macos/Tests/MacomprendoTests/Fakes/ScriptedToaster.swift`
- Create: `macos/Tests/MacomprendoTests/Fakes/ScriptedSettingsHolder.swift`
- Test: `macos/Tests/MacomprendoTests/Features/ErrorTextTests.swift`

**Interfaces:**
- Consumes: `HUDController` (Plan 3), `LLMProvider` (Plan 2), `Settings`, `PresetKind`, `MacomprendoError`.
- Produces:
  `@MainActor protocol Toasting: AnyObject { func toast(_ message: String, duration: TimeInterval) }`
  (with `extension HUDController: Toasting {}`);
  `struct LLMTarget: Sendable { let provider: any LLMProvider; let model: String }`;
  `enum FeatureConfigError: Error, LocalizedError, Equatable { case llmNotConfigured(PresetKind), noPreset(PresetKind) }`;
  a widened `ErrorText.describe(_:)` (Plan 3's version only understands `MacomprendoError`);
  `@MainActor protocol SettingsHolding: AnyObject { var settings: Settings { get set } }`
  (with `extension AppModel: SettingsHolding {}`).

- [ ] **Step 1: Write the failing test**

Create `macos/Tests/MacomprendoTests/Features/ErrorTextTests.swift`:

```swift
import Foundation
import Testing
@testable import Macomprendo

@Suite struct ErrorTextTests {
    @Test func localizedErrorsGetDescriptionAndRecovery() {
        let text = ErrorText.describe(MacomprendoError.noSelection)
        #expect(text.contains(MacomprendoError.noSelection.errorDescription ?? "!"))
        if let recovery = MacomprendoError.noSelection.recoverySuggestion {
            #expect(text.contains(recovery))
        }
    }

    @Test func cancellationBecomesAShortMessage() {
        #expect(ErrorText.describe(CancellationError()) == "Cancelled.")
    }

    @Test func configErrorsNameTheFeature() {
        let text = ErrorText.describe(FeatureConfigError.llmNotConfigured(.summarize))
        #expect(text.contains("Summarize"))
        #expect(text.contains("Settings"))
    }

    @Test func missingPresetErrorNamesTheFeature() {
        let text = ErrorText.describe(FeatureConfigError.noPreset(.refine))
        #expect(text.contains("Refine"))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path macos --filter ErrorTextTests`
Expected: build failure — `error: cannot find 'FeatureConfigError' in scope` (Plan 3's `ErrorText`
exists but knows nothing about the new error types).

- [ ] **Step 3: Create the support types**

Create `macos/Sources/Macomprendo/Features/Toasting.swift`:

```swift
import Foundation

/// The one thing controllers need from the HUD. Keeps them testable without AppKit.
@MainActor protocol Toasting: AnyObject {
    func toast(_ message: String, duration: TimeInterval)
}

extension HUDController: Toasting {}
```

Create `macos/Sources/Macomprendo/Features/LLMTarget.swift`:

```swift
import Foundation

/// A provider plus the model name to call on it.
struct LLMTarget: Sendable {
    let provider: any LLMProvider
    let model: String
}

enum FeatureConfigError: Error, LocalizedError, Equatable, Sendable {
    case llmNotConfigured(PresetKind)
    case noPreset(PresetKind)

    var errorDescription: String? {
        switch self {
        case .llmNotConfigured(let kind): "No endpoint and model chosen for \(kind.displayName)."
        case .noPreset(let kind): "No \(kind.displayName) preset is available."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .llmNotConfigured: "Pick an endpoint and a model in Settings ▸ Refine & Summarize."
        case .noPreset: "Add a preset in Settings ▸ Refine & Summarize, or restore the factory presets."
        }
    }
}

```

Then widen Plan 3's `ErrorText` so it also handles `FeatureConfigError`, `PresetError` and
cancellation. Replace its whole body with:

```swift
/// Turns any error into the one-line text shown in a toast or the panel's error banner.
enum ErrorText {
    static func describe(_ error: Error) -> String {
        if error is CancellationError { return "Cancelled." }
        if let localized = error as? LocalizedError {
            let parts = [localized.errorDescription, localized.recoverySuggestion].compactMap { $0 }
            if !parts.isEmpty { return parts.joined(separator: " ") }
        }
        return error.localizedDescription
    }
}
```

Create `macos/Sources/Macomprendo/App/SettingsHolding.swift`:

```swift
import Foundation

/// Read/write access to the live `Settings` for view models and the Quick Panel controller.
@MainActor protocol SettingsHolding: AnyObject {
    var settings: Settings { get set }
}

extension AppModel: SettingsHolding {}
```

- [ ] **Step 4: Create the test doubles**

Create `macos/Tests/MacomprendoTests/Fakes/ScriptedToaster.swift`:

```swift
import Foundation
@testable import Macomprendo

@MainActor final class ScriptedToaster: Toasting {
    private(set) var messages: [String] = []
    func toast(_ message: String, duration: TimeInterval) { messages.append(message) }
}
```

Create `macos/Tests/MacomprendoTests/Fakes/ScriptedSettingsHolder.swift`:

```swift
import Foundation
@testable import Macomprendo

@MainActor final class ScriptedSettingsHolder: SettingsHolding {
    var settings: Settings

    init(_ settings: Settings = .default) {
        self.settings = settings
    }

    /// `Settings.default` with the factory presets already seeded.
    static func seeded() -> ScriptedSettingsHolder {
        var s = Settings.default
        s.presets = []
        s.presetsSeeded = false
        FactoryPresets.seed(into: &s)
        return ScriptedSettingsHolder(s)
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --package-path macos --filter ErrorTextTests`
Expected: PASS — 4 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add macos/Sources/Macomprendo/Features/Toasting.swift \
        macos/Sources/Macomprendo/Features/LLMTarget.swift \
        macos/Sources/Macomprendo/App/SettingsHolding.swift \
        macos/Tests/MacomprendoTests/Fakes/ScriptedToaster.swift \
        macos/Tests/MacomprendoTests/Fakes/ScriptedSettingsHolder.swift \
        macos/Tests/MacomprendoTests/Features/ErrorTextTests.swift
git commit -m "feat(features): add toasting, LLM target and settings-holder protocols"
```

---

### Task 7: `SpeakController`

**Files:**
- Create: `macos/Sources/Macomprendo/Features/SpeakController.swift`
- Test: `macos/Tests/MacomprendoTests/Features/SpeakControllerTests.swift`

**Interfaces:**
- Consumes: `SpeechSynthesizing`, `ScriptedSpeech` (Task 5), `Toasting`, `ErrorText` (Task 6), `Settings`.
- Produces:
  ```swift
  @MainActor final class SpeakController: ObservableObject {
      @Published private(set) var isSpeaking: Bool
      init(speech: any SpeechSynthesizing, toaster: any Toasting,
           settings: @escaping @MainActor () -> Settings)
      func toggle(text: () async throws -> String) async
  }
  ```

- [ ] **Step 1: Write the failing test**

Create `macos/Tests/MacomprendoTests/Features/SpeakControllerTests.swift`:

```swift
import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct SpeakControllerTests {
    private func make(_ speechSettings: SpeechSettings = SpeechSettings(voiceID: "com.apple.voice.x",
                                                                        rate: 0.6, pitch: 1.1, volume: 0.9))
        -> (SpeakController, ScriptedSpeech, ScriptedToaster) {
        let speech = ScriptedSpeech()
        let toaster = ScriptedToaster()
        var settings = Settings.default
        settings.speech = speechSettings
        let controller = SpeakController(speech: speech, toaster: toaster, settings: { settings })
        return (controller, speech, toaster)
    }

    @Test func speaksTheSuppliedTextWithTheConfiguredVoice() async {
        let (controller, speech, toaster) = make()
        await controller.toggle(text: { "  read me  " })
        #expect(speech.spoken.count == 1)
        #expect(speech.spoken[0].text == "read me")
        #expect(speech.spoken[0].settings.voiceID == "com.apple.voice.x")
        #expect(speech.spoken[0].settings.rate == 0.6)
        #expect(controller.isSpeaking)
        #expect(toaster.messages.isEmpty)
    }

    @Test func togglingWhileSpeakingStops() async {
        let (controller, speech, _) = make()
        await controller.toggle(text: { "first" })
        await controller.toggle(text: { Issue.record("must not read again"); return "" })
        #expect(speech.stopCount == 1)
        #expect(speech.spoken.count == 1)
        #expect(!controller.isSpeaking)
    }

    @Test func noSelectionErrorBecomesAToast() async {
        let (controller, speech, toaster) = make()
        await controller.toggle(text: { throw MacomprendoError.noSelection })
        #expect(speech.spoken.isEmpty)
        #expect(toaster.messages.count == 1)
        #expect(toaster.messages[0].contains(MacomprendoError.noSelection.errorDescription ?? "!"))
    }

    @Test func blankTextIsReportedAsNoSelection() async {
        let (controller, speech, toaster) = make()
        await controller.toggle(text: { "   \n" })
        #expect(speech.spoken.isEmpty)
        #expect(toaster.messages.count == 1)
    }

    @Test func finishingNaturallyClearsTheSpeakingFlag() async {
        let (controller, speech, _) = make()
        await controller.toggle(text: { "hello" })
        #expect(controller.isSpeaking)
        speech.finish()
        #expect(!controller.isSpeaking)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path macos --filter SpeakControllerTests`
Expected: build failure — `error: cannot find 'SpeakController' in scope`.

- [ ] **Step 3: Implement the controller**

Create `macos/Sources/Macomprendo/Features/SpeakController.swift`:

```swift
import Foundation

/// Hotkey #3. Pressing the hotkey while speaking stops; otherwise it reads the supplied text.
@MainActor final class SpeakController: ObservableObject {
    @Published private(set) var isSpeaking = false

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
            self.isSpeaking = self.speech.isSpeaking
        }
    }

    /// `text` is evaluated only when we are about to start speaking, so the selection is not
    /// read (and no ⌘C is simulated) when the hotkey is used to stop.
    func toggle(text: () async throws -> String) async {
        if speech.isSpeaking {
            speech.stop()
            isSpeaking = false
            return
        }
        do {
            let raw = try await text()
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                toaster.toast(ErrorText.describe(MacomprendoError.noSelection), duration: 2.0)
                return
            }
            speech.speak(trimmed, settings: settings().speech)
            isSpeaking = speech.isSpeaking
        } catch {
            toaster.toast(ErrorText.describe(error), duration: 2.5)
        }
    }
}
```

Note on the spec's "sentence-level progress in the HUD": `HUDState` (Plan 3) has no case for
speech progress, so this plan shows no HUD while speaking and only toasts failures. Adding a
progress case is a `HUDState` change and is intentionally out of scope.

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --package-path macos --filter SpeakControllerTests`
Expected: PASS — 5 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Macomprendo/Features/SpeakController.swift \
        macos/Tests/MacomprendoTests/Features/SpeakControllerTests.swift
git commit -m "feat(speak): add SpeakController toggle behaviour"
```

---

### Task 8: `QuickPanelController` and its AppKit host

**Files:**
- Create: `macos/Sources/Macomprendo/UI/QuickPanel/QuickPanelController.swift`
- Create: `macos/Sources/Macomprendo/UI/QuickPanel/FloatingPanelHost.swift`
- Create: `macos/Tests/MacomprendoTests/Fakes/ScriptedPanelHost.swift`
- Test: `macos/Tests/MacomprendoTests/UI/QuickPanelControllerTests.swift`

**Interfaces:**
- Consumes: `SettingsHolding` (Task 6), `Settings.quickPanelFrames` (Plan 1).
- Produces:
  ```swift
  enum QuickPanelLayout: Equatable, Sendable { case refine, summary }
  @MainActor protocol QuickPanelHosting: AnyObject {
      var onEscape: (@MainActor () -> Void)? { get set }
      var onFrameChange: (@MainActor (CGRect) -> Void)? { get set }
      var isVisible: Bool { get }
      func show(frame: CGRect)
      func hide()
  }
  @MainActor final class QuickPanelController: ObservableObject {
      @Published private(set) var layout: QuickPanelLayout
      @Published private(set) var isVisible: Bool
      static let panelSize: CGSize          // 680 × 420
      static let topInset: CGFloat          // 80
      init(holder: any SettingsHolding)
      func attach(_ host: any QuickPanelHosting)
      static func screenKey(name: String, frame: CGRect) -> String
      static func defaultFrame(inScreenFrame: CGRect) -> CGRect
      func present(layout: QuickPanelLayout, on screen: NSScreen?)
      func present(layout: QuickPanelLayout, screenName: String, screenFrame: CGRect)
      func dismiss()
  }
  @MainActor final class FloatingPanelHost<Content: View>: NSObject, QuickPanelHosting {
      init(rootView: Content)
  }
  ```
- The host is attached after construction (`attach(_:)`) because the SwiftUI root view needs the
  controllers, and the controllers need this panel — `attach` breaks that cycle.

- [ ] **Step 1: Write the test double**

Create `macos/Tests/MacomprendoTests/Fakes/ScriptedPanelHost.swift`:

```swift
import Foundation
@testable import Macomprendo

@MainActor final class ScriptedPanelHost: QuickPanelHosting {
    var onEscape: (@MainActor () -> Void)?
    var onFrameChange: (@MainActor (CGRect) -> Void)?
    private(set) var isVisible = false
    private(set) var shownFrames: [CGRect] = []
    private(set) var hideCount = 0

    func show(frame: CGRect) {
        shownFrames.append(frame)
        isVisible = true
    }

    func hide() {
        isVisible = false
        hideCount += 1
    }

    /// Simulates the user pressing Esc in the panel.
    func pressEscape() { onEscape?() }

    /// Simulates the user dragging or resizing the panel.
    func dragTo(_ frame: CGRect) { onFrameChange?(frame) }
}
```

- [ ] **Step 2: Write the failing test**

Create `macos/Tests/MacomprendoTests/UI/QuickPanelControllerTests.swift`:

```swift
import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct QuickPanelControllerTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    private func make() -> (QuickPanelController, ScriptedPanelHost, ScriptedSettingsHolder) {
        let holder = ScriptedSettingsHolder()
        let host = ScriptedPanelHost()
        let controller = QuickPanelController(holder: holder)
        controller.attach(host)
        return (controller, host, holder)
    }

    @Test func screenKeyIsStableAndDoesNotUseSwiftHashing() {
        let a = QuickPanelController.screenKey(name: "Built-in Retina Display", frame: screen)
        let b = QuickPanelController.screenKey(name: "Built-in Retina Display", frame: screen)
        #expect(a == b)
        #expect(a == "Built-in Retina Display#0,0,1440x900")
        #expect(a != QuickPanelController.screenKey(name: "Studio Display", frame: screen))
    }

    @Test func defaultFrameIsTopCentreAndSixEightyByFourTwenty() {
        let frame = QuickPanelController.defaultFrame(inScreenFrame: screen)
        #expect(frame.width == 680)
        #expect(frame.height == 420)
        #expect(frame.midX == screen.midX)
        #expect(frame.maxY == screen.maxY - 80)
    }

    @Test func presentShowsTheHostWithTheDefaultFrame() {
        let (controller, host, _) = make()
        controller.present(layout: .summary, screenName: "S1", screenFrame: screen)
        #expect(controller.isVisible)
        #expect(controller.layout == .summary)
        #expect(host.shownFrames == [QuickPanelController.defaultFrame(inScreenFrame: screen)])
    }

    @Test func aRememberedFrameIsReusedForTheSameScreen() {
        let (controller, host, holder) = make()
        let remembered = CGRect(x: 10, y: 20, width: 700, height: 500)
        holder.settings.quickPanelFrames[
            QuickPanelController.screenKey(name: "S1", frame: screen)] = remembered
        controller.present(layout: .refine, screenName: "S1", screenFrame: screen)
        #expect(host.shownFrames == [remembered])
    }

    @Test func draggingThePanelPersistsTheFramePerScreen() {
        let (controller, host, holder) = make()
        controller.present(layout: .refine, screenName: "S1", screenFrame: screen)
        let moved = CGRect(x: 100, y: 200, width: 680, height: 420)
        host.dragTo(moved)
        let key = QuickPanelController.screenKey(name: "S1", frame: screen)
        #expect(holder.settings.quickPanelFrames[key] == moved)
    }

    @Test func escapeDismissesThePanel() {
        let (controller, host, _) = make()
        controller.present(layout: .refine, screenName: "S1", screenFrame: screen)
        host.pressEscape()
        #expect(!controller.isVisible)
        #expect(host.hideCount == 1)
    }

    @Test func presentingTwiceKeepsOneVisiblePanelAndUpdatesTheLayout() {
        let (controller, host, _) = make()
        controller.present(layout: .refine, screenName: "S1", screenFrame: screen)
        controller.present(layout: .summary, screenName: "S1", screenFrame: screen)
        #expect(controller.layout == .summary)
        #expect(host.shownFrames.count == 2)
        #expect(host.hideCount == 0)
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --package-path macos --filter QuickPanelControllerTests`
Expected: build failure — `error: cannot find 'QuickPanelController' in scope`.

- [ ] **Step 4: Implement the controller**

Create `macos/Sources/Macomprendo/UI/QuickPanel/QuickPanelController.swift`:

```swift
import AppKit
import Foundation

enum QuickPanelLayout: Equatable, Sendable {
    case refine
    case summary
}

/// The AppKit window behind the Quick Panel, kept behind a protocol so the controller is testable.
@MainActor protocol QuickPanelHosting: AnyObject {
    var onEscape: (@MainActor () -> Void)? { get set }
    var onFrameChange: (@MainActor (CGRect) -> Void)? { get set }
    var isVisible: Bool { get }
    func show(frame: CGRect)
    func hide()
}

/// Owns the Quick Panel's visibility, current layout and per-screen frame memory.
@MainActor final class QuickPanelController: ObservableObject {
    static let panelSize = CGSize(width: 680, height: 420)
    static let topInset: CGFloat = 80

    @Published private(set) var layout: QuickPanelLayout = .refine
    @Published private(set) var isVisible = false

    private let holder: any SettingsHolding
    private var host: (any QuickPanelHosting)?
    private var currentScreenKey: String?

    init(holder: any SettingsHolding) {
        self.holder = holder
    }

    /// Called by the composition root once the SwiftUI content (which needs the controllers) exists.
    func attach(_ host: any QuickPanelHosting) {
        self.host = host
        host.onEscape = { [weak self] in self?.dismiss() }
        host.onFrameChange = { [weak self] frame in self?.rememberFrame(frame) }
    }

    /// Stable across launches — deliberately not `hashValue`, whose seed changes per process.
    static func screenKey(name: String, frame: CGRect) -> String {
        "\(name)#\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width))x\(Int(frame.height))"
    }

    static func defaultFrame(inScreenFrame screenFrame: CGRect) -> CGRect {
        CGRect(x: screenFrame.midX - panelSize.width / 2,
               y: screenFrame.maxY - panelSize.height - topInset,
               width: panelSize.width,
               height: panelSize.height)
    }

    func present(layout: QuickPanelLayout, on screen: NSScreen?) {
        let target = screen ?? NSScreen.main
        present(layout: layout,
                screenName: target?.localizedName ?? "default",
                screenFrame: target?.visibleFrame ?? CGRect(origin: .zero, size: Self.panelSize))
    }

    func present(layout: QuickPanelLayout, screenName: String, screenFrame: CGRect) {
        self.layout = layout
        let key = Self.screenKey(name: screenName, frame: screenFrame)
        currentScreenKey = key
        let frame = holder.settings.quickPanelFrames[key] ?? Self.defaultFrame(inScreenFrame: screenFrame)
        host?.show(frame: frame)
        isVisible = true
    }

    func dismiss() {
        host?.hide()
        isVisible = false
    }

    private func rememberFrame(_ frame: CGRect) {
        guard let key = currentScreenKey else { return }
        holder.settings.quickPanelFrames[key] = frame
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --package-path macos --filter QuickPanelControllerTests`
Expected: PASS — 7 tests, 0 failures.

- [ ] **Step 6: Implement the AppKit host**

Create `macos/Sources/Macomprendo/UI/QuickPanel/FloatingPanelHost.swift`:

```swift
import AppKit
import SwiftUI

/// A floating panel that *can* become key (unlike the recording HUD's non-activating panel),
/// so the user can type in the instruction field and edit the text areas.
final class QuickPanelWindow: NSPanel {
    var onEscape: (@MainActor () -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

@MainActor final class FloatingPanelHost<Content: View>: NSObject, QuickPanelHosting, NSWindowDelegate {
    var onEscape: (@MainActor () -> Void)?
    var onFrameChange: (@MainActor (CGRect) -> Void)?

    private let window: QuickPanelWindow

    var isVisible: Bool { window.isVisible }

    init(rootView: Content) {
        window = QuickPanelWindow(
            contentRect: NSRect(origin: .zero, size: QuickPanelController.panelSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        super.init()
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.contentView = NSHostingView(rootView: rootView)
        window.delegate = self
        window.onEscape = { [weak self] in self?.onEscape?() }
    }

    func show(frame: CGRect) {
        window.setFrame(frame, display: true)
        // orderFrontRegardless keeps the source app active; the panel becomes key on first click.
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }

    func windowDidMove(_ notification: Notification) { onFrameChange?(window.frame) }
    func windowDidResize(_ notification: Notification) { onFrameChange?(window.frame) }
}
```

- [ ] **Step 7: Verify the build**

Run: `swift build --package-path macos`
Expected: `Build complete!`

- [ ] **Step 8: Commit**

```bash
git add macos/Sources/Macomprendo/UI/QuickPanel/QuickPanelController.swift \
        macos/Sources/Macomprendo/UI/QuickPanel/FloatingPanelHost.swift \
        macos/Tests/MacomprendoTests/Fakes/ScriptedPanelHost.swift \
        macos/Tests/MacomprendoTests/UI/QuickPanelControllerTests.swift
git commit -m "feat(quickpanel): add panel controller with per-screen frame memory"
```

---

### Task 9: `DictationCapture`

**Files:**
- Create: `macos/Sources/Macomprendo/Features/DictationCapture.swift`
- Create: `macos/Tests/MacomprendoTests/Fakes/ScriptedRecorder.swift`
- Create: `macos/Tests/MacomprendoTests/Fakes/ScriptedTranscriber.swift`
- Create: `macos/Tests/MacomprendoTests/Fakes/ScriptedPermissions.swift`
- Test: `macos/Tests/MacomprendoTests/Features/DictationCaptureTests.swift`

**Interfaces:**
- Consumes: `AudioRecording`, `TranscriptionProvider`, `PermissionsChecking`, `HotkeyEvent`,
  `DictationMode`, `MacomprendoError`.
- Produces:
  ```swift
  @MainActor final class DictationCapture {
      enum State: Equatable, Sendable { case idle, recording, transcribing }
      private(set) var state: State
      var onStateChange: (@MainActor (State) -> Void)?
      var onTranscript: (@MainActor (String) -> Void)?
      var onError: (@MainActor (Error) -> Void)?
      init(recorder: any AudioRecording,
           transcriberProvider: @escaping @Sendable () async throws -> any TranscriptionProvider,
           permissions: any PermissionsChecking,
           mode: @escaping @MainActor () -> DictationMode,
           language: @escaping @MainActor () -> String?)
      func handle(_ event: HotkeyEvent)
      func cancel()
      func drain() async
  }
  ```

> `DictationController` (Plan 3) keeps its own copy of this logic — this plan does not refactor
> it, so Plan 3's tests stay green. `DictationCapture` exists so `RefineController` can reuse the
> mic → transcript half of hotkey #2 without depending on `DictationController`.

- [ ] **Step 1: Write the test doubles**

Create `macos/Tests/MacomprendoTests/Fakes/ScriptedRecorder.swift`:

```swift
import Foundation
@testable import Macomprendo

final class ScriptedRecorder: AudioRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var recording = false
    private var starts = 0
    private var stops = 0

    var samples: [Float] = [0.1, -0.1, 0.2]
    var startError: MacomprendoError?

    let level: AsyncStream<Float> = AsyncStream { $0.finish() }

    var startCount: Int { lock.withLock { starts } }
    var stopCount: Int { lock.withLock { stops } }

    func start() async throws {
        if let startError { throw startError }
        lock.withLock { recording = true; starts += 1 }
    }

    func stop() async -> [Float] {
        lock.withLock { recording = false; stops += 1 }
        return samples
    }

    var isRecording: Bool { get async { lock.withLock { recording } } }
}
```

Create `macos/Tests/MacomprendoTests/Fakes/ScriptedTranscriber.swift`:

```swift
import Foundation
@testable import Macomprendo

struct ScriptedTranscriber: TranscriptionProvider {
    var text: String = "hello world"
    var failure: MacomprendoError?

    func transcribe(_ pcm: [Float], sampleRate: Int, language: String?) async throws -> String {
        if let failure { throw failure }
        return text
    }
}
```

Create `macos/Tests/MacomprendoTests/Fakes/ScriptedPermissions.swift`:

```swift
import Foundation
@testable import Macomprendo

struct ScriptedPermissions: PermissionsChecking {
    var current: PermissionStatus = .granted
    var afterRequest: PermissionStatus = .granted

    func status(of kind: PermissionKind) async -> PermissionStatus { current }
    func request(_ kind: PermissionKind) async -> PermissionStatus { afterRequest }
    func openSystemSettings(for kind: PermissionKind) {}
}
```

- [ ] **Step 2: Write the failing test**

Create `macos/Tests/MacomprendoTests/Features/DictationCaptureTests.swift`:

```swift
import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite final class DictationCaptureTests {
    private var transcripts: [String] = []
    private var errors: [Error] = []

    private func make(mode: DictationMode = .hold,
                      recorder: ScriptedRecorder = ScriptedRecorder(),
                      transcriber: ScriptedTranscriber = ScriptedTranscriber(),
                      permissions: ScriptedPermissions = ScriptedPermissions()) -> DictationCapture {
        let capture = DictationCapture(
            recorder: recorder,
            transcriberProvider: { transcriber },
            permissions: permissions,
            mode: { mode },
            language: { "en" })
        capture.onTranscript = { [weak self] in self?.transcripts.append($0) }
        capture.onError = { [weak self] in self?.errors.append($0) }
        return capture
    }

    @Test func holdModeRecordsOnKeyDownAndTranscribesOnKeyUp() async {
        let recorder = ScriptedRecorder()
        let capture = make(mode: .hold, recorder: recorder)

        capture.handle(.keyDown(.dictateAndRefine))
        #expect(capture.state == .recording)
        await capture.drain()
        #expect(recorder.startCount == 1)

        capture.handle(.keyUp(.dictateAndRefine))
        await capture.drain()
        #expect(recorder.stopCount == 1)
        #expect(transcripts == ["hello world"])
        #expect(capture.state == .idle)
        #expect(errors.isEmpty)
    }

    @Test func toggleModeStartsAndStopsOnSuccessivePresses() async {
        let recorder = ScriptedRecorder()
        let capture = make(mode: .toggle, recorder: recorder)

        capture.handle(.keyDown(.dictateAndRefine))
        capture.handle(.keyUp(.dictateAndRefine))          // ignored in toggle mode
        await capture.drain()
        #expect(capture.state == .recording)
        #expect(recorder.stopCount == 0)

        capture.handle(.keyDown(.dictateAndRefine))
        await capture.drain()
        #expect(transcripts == ["hello world"])
        #expect(capture.state == .idle)
    }

    @Test func blankTranscriptIsReportedAsNothingHeard() async {
        let capture = make(transcriber: ScriptedTranscriber(text: "   "))
        capture.handle(.keyDown(.dictateAndRefine))
        capture.handle(.keyUp(.dictateAndRefine))
        await capture.drain()
        #expect(transcripts.isEmpty)
        #expect(errors.count == 1)
        #expect(errors.first as? MacomprendoError == MacomprendoError.audio("Nothing heard."))
    }

    @Test func deniedMicrophonePermissionIsReported() async {
        let recorder = ScriptedRecorder()
        let capture = make(recorder: recorder,
                           permissions: ScriptedPermissions(current: .denied, afterRequest: .denied))
        capture.handle(.keyDown(.dictateAndRefine))
        await capture.drain()
        #expect(recorder.startCount == 0)
        #expect(errors.first as? MacomprendoError == MacomprendoError.permissionDenied(.microphone))
        #expect(capture.state == .idle)
    }

    @Test func transcriberFailureIsReportedAndStateReturnsToIdle() async {
        let capture = make(transcriber: ScriptedTranscriber(failure: .providerUnreachable(endpointName: "Ollama (local)")))
        capture.handle(.keyDown(.dictateAndRefine))
        capture.handle(.keyUp(.dictateAndRefine))
        await capture.drain()
        #expect(transcripts.isEmpty)
        #expect(errors.first as? MacomprendoError
                == MacomprendoError.providerUnreachable(endpointName: "Ollama (local)"))
        #expect(capture.state == .idle)
    }

    @Test func cancelDuringRecordingProducesNoTranscript() async {
        let recorder = ScriptedRecorder()
        let capture = make(recorder: recorder)
        capture.handle(.keyDown(.dictateAndRefine))
        await capture.drain()
        capture.cancel()
        await capture.drain()
        #expect(capture.state == .idle)
        #expect(transcripts.isEmpty)
        #expect(errors.isEmpty)
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --package-path macos --filter DictationCaptureTests`
Expected: build failure — `error: cannot find 'DictationCapture' in scope`.

- [ ] **Step 4: Implement `DictationCapture`**

Create `macos/Sources/Macomprendo/Features/DictationCapture.swift`:

```swift
import Foundation

/// Microphone → transcript, with the hold/toggle hotkey semantics.
/// Reused by `RefineController` for hotkey #2 (Dictate & Refine).
@MainActor final class DictationCapture {
    enum State: Equatable, Sendable {
        case idle
        case recording
        case transcribing
    }

    private(set) var state: State = .idle

    var onStateChange: (@MainActor (State) -> Void)?
    var onTranscript: (@MainActor (String) -> Void)?
    var onError: (@MainActor (Error) -> Void)?

    private let recorder: any AudioRecording
    private let transcriberProvider: @Sendable () async throws -> any TranscriptionProvider
    private let permissions: any PermissionsChecking
    private let mode: @MainActor () -> DictationMode
    private let language: @MainActor () -> String?
    private var task: Task<Void, Never>?

    init(recorder: any AudioRecording,
         transcriberProvider: @escaping @Sendable () async throws -> any TranscriptionProvider,
         permissions: any PermissionsChecking,
         mode: @escaping @MainActor () -> DictationMode,
         language: @escaping @MainActor () -> String?) {
        self.recorder = recorder
        self.transcriberProvider = transcriberProvider
        self.permissions = permissions
        self.mode = mode
        self.language = language
    }

    func handle(_ event: HotkeyEvent) {
        switch (event, mode()) {
        case (.keyDown, .hold):
            startRecording()
        case (.keyUp, .hold):
            finishRecording()
        case (.keyDown, .toggle):
            switch state {
            case .idle: startRecording()
            case .recording: finishRecording()
            case .transcribing: cancel()
            }
        case (.keyUp, .toggle):
            break
        }
    }

    func cancel() {
        task?.cancel()
        let recorder = self.recorder
        task = Task { _ = await recorder.stop() }
        setState(.idle)
    }

    /// Awaits the in-flight capture task. Used by tests and by callers that need to sequence work.
    func drain() async {
        _ = await task?.value
    }

    private func startRecording() {
        guard state == .idle else { return }
        setState(.recording)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if await self.permissions.status(of: .microphone) != .granted {
                    let granted = await self.permissions.request(.microphone)
                    guard granted == .granted else { throw MacomprendoError.permissionDenied(.microphone) }
                }
                try await self.recorder.start()
            } catch {
                self.setState(.idle)
                self.onError?(error)
            }
        }
    }

    private func finishRecording() {
        guard state == .recording else { return }
        setState(.transcribing)
        let previous = task
        task = Task { [weak self] in
            guard let self else { return }
            _ = await previous?.value              // let start() settle before stopping
            let samples = await self.recorder.stop()
            do {
                try Task.checkCancellation()
                guard !samples.isEmpty else { throw MacomprendoError.audio("Nothing heard.") }
                let transcriber = try await self.transcriberProvider()
                let raw = try await transcriber.transcribe(samples, sampleRate: 16_000,
                                                           language: self.language())
                try Task.checkCancellation()
                self.setState(.idle)
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw MacomprendoError.audio("Nothing heard.") }
                self.onTranscript?(text)
            } catch {
                self.setState(.idle)
                if !(error is CancellationError) { self.onError?(error) }
            }
        }
    }

    private func setState(_ new: State) {
        guard state != new else { return }
        state = new
        onStateChange?(new)
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --package-path macos --filter DictationCaptureTests`
Expected: PASS — 6 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add macos/Sources/Macomprendo/Features/DictationCapture.swift \
        macos/Tests/MacomprendoTests/Fakes/ScriptedRecorder.swift \
        macos/Tests/MacomprendoTests/Fakes/ScriptedTranscriber.swift \
        macos/Tests/MacomprendoTests/Fakes/ScriptedPermissions.swift \
        macos/Tests/MacomprendoTests/Features/DictationCaptureTests.swift
git commit -m "feat(features): add reusable microphone capture state machine"
```

---

### Task 10: `RefineController`

**Files:**
- Create: `macos/Sources/Macomprendo/Features/RefineController.swift`
- Create: `macos/Tests/MacomprendoTests/Fakes/ScriptedLLMProvider.swift`
- Create: `macos/Tests/MacomprendoTests/Fakes/ScriptedInserter.swift`
- Create: `macos/Tests/MacomprendoTests/Fakes/ScriptedTracker.swift`
- Test: `macos/Tests/MacomprendoTests/Features/RefineControllerTests.swift`

**Interfaces:**
- Consumes: `DictationCapture` (Task 9), `QuickPanelController` (Task 8), `LLMTarget`,
  `FeatureConfigError`, `ErrorText`, `Toasting` (Task 6), `PromptRenderer` (Task 3),
  `PasteboardProtocol`, `TextInserting`, `FrontmostAppTracking`, `LLMProvider`, `ChatOptions`.
- Produces:
  ```swift
  enum RefineSource: Equatable, Sendable { case dictation, selection(String) }
  enum RefineSide: Equatable, Sendable { case original, refined }
  @MainActor final class RefineController: ObservableObject {
      @Published var original: String
      @Published var refined: String
      @Published var isStreaming: Bool
      @Published var selectedPresetID: UUID?
      @Published var instruction: String
      @Published var error: String?
      @Published private(set) var isCapturing: Bool
      init(capture: DictationCapture,
           llm: @escaping @MainActor () throws -> LLMTarget,
           panel: QuickPanelController,
           pasteboard: any PasteboardProtocol,
           inserter: any TextInserting,
           tracker: any FrontmostAppTracking,
           toaster: any Toasting,
           settings: @escaping @MainActor () -> Settings)
      func handle(_ event: HotkeyEvent)
      func start(source: RefineSource)
      func rerun()
      func stop()
      func copy(_ side: RefineSide)
      func insert(_ side: RefineSide) async
      func drain() async
  }
  ```

- [ ] **Step 1: Write the test doubles**

Create `macos/Tests/MacomprendoTests/Fakes/ScriptedLLMProvider.swift`:

```swift
import Foundation
@testable import Macomprendo

struct ChatCall: Equatable {
    var messages: [ChatMessage]
    var model: String
}

/// Thread-safe recorder shared by the value-type provider and the test.
final class LLMCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ChatCall] = []

    var calls: [ChatCall] { lock.withLock { recorded } }

    func record(_ call: ChatCall) { lock.withLock { recorded.append(call) } }
}

/// Yields `deltas` in order, then finishes — or throws `failure` after the deltas.
struct ScriptedLLMProvider: LLMProvider {
    var endpoint: Endpoint = .ollamaLocal()
    var deltas: [String] = []
    var failure: MacomprendoError?
    /// Pause before each delta, so a test can cancel mid-stream.
    var delayPerDelta: Duration = .zero
    var recorder = LLMCallRecorder()

    func listModels() async throws -> [String] { ["scripted-model"] }

    func chat(_ messages: [ChatMessage], model: String,
              options: ChatOptions) -> AsyncThrowingStream<String, Error> {
        recorder.record(ChatCall(messages: messages, model: model))
        let deltas = self.deltas
        let failure = self.failure
        let delay = self.delayPerDelta
        return AsyncThrowingStream { continuation in
            let task = Task {
                for delta in deltas {
                    if delay > .zero { try? await Task.sleep(for: delay) }
                    if Task.isCancelled {
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                    continuation.yield(delta)
                }
                continuation.finish(throwing: failure)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
```

Create `macos/Tests/MacomprendoTests/Fakes/ScriptedInserter.swift`:

```swift
import Foundation
@testable import Macomprendo

final class ScriptedInserter: TextInserting, @unchecked Sendable {
    struct Call: Equatable {
        var text: String
        var app: FrontmostApp?
        var method: InsertMethod
    }

    private let lock = NSLock()
    private var recorded: [Call] = []

    var failure: MacomprendoError?

    var calls: [Call] { lock.withLock { recorded } }

    func insert(_ text: String, into app: FrontmostApp?, method: InsertMethod) async throws {
        if let failure { throw failure }
        lock.withLock { recorded.append(Call(text: text, app: app, method: method)) }
    }
}
```

Create `macos/Tests/MacomprendoTests/Fakes/ScriptedTracker.swift`:

```swift
import Foundation
@testable import Macomprendo

struct ScriptedTracker: FrontmostAppTracking {
    var app: FrontmostApp? = FrontmostApp(pid: 42, bundleID: "com.example.editor", name: "Editor")

    func capture() -> FrontmostApp? { app }
    func activate(_ app: FrontmostApp) async -> Bool { true }
}
```

- [ ] **Step 2: Write the failing test**

Create `macos/Tests/MacomprendoTests/Features/RefineControllerTests.swift`:

```swift
import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct RefineControllerTests {
    struct Rig {
        let controller: RefineController
        let panel: QuickPanelController
        let host: ScriptedPanelHost
        let pasteboard: ScriptedPasteboard
        let inserter: ScriptedInserter
        let toaster: ScriptedToaster
        let recorder: LLMCallRecorder
        let holder: ScriptedSettingsHolder
    }

    private func makeRig(deltas: [String] = ["Hello", " there"],
                         failure: MacomprendoError? = nil,
                         delayPerDelta: Duration = .zero,
                         configured: Bool = true) -> Rig {
        let holder = ScriptedSettingsHolder.seeded()
        let host = ScriptedPanelHost()
        let panel = QuickPanelController(holder: holder)
        panel.attach(host)

        let recorder = LLMCallRecorder()
        let provider = ScriptedLLMProvider(deltas: deltas, failure: failure,
                                           delayPerDelta: delayPerDelta, recorder: recorder)
        let pasteboard = ScriptedPasteboard()
        let inserter = ScriptedInserter()
        let toaster = ScriptedToaster()

        let capture = DictationCapture(
            recorder: ScriptedRecorder(),
            transcriberProvider: { ScriptedTranscriber(text: "spoken words") },
            permissions: ScriptedPermissions(),
            mode: { .hold },
            language: { "en" })

        let controller = RefineController(
            capture: capture,
            llm: {
                guard configured else { throw FeatureConfigError.llmNotConfigured(.refine) }
                return LLMTarget(provider: provider, model: "qwen2.5:1.5b")
            },
            panel: panel,
            pasteboard: pasteboard,
            inserter: inserter,
            tracker: ScriptedTracker(),
            toaster: toaster,
            settings: { holder.settings })

        return Rig(controller: controller, panel: panel, host: host, pasteboard: pasteboard,
                   inserter: inserter, toaster: toaster, recorder: recorder, holder: holder)
    }

    @Test func startingFromASelectionOpensThePanelAndStreamsTheResult() async {
        let rig = makeRig()
        rig.controller.start(source: .selection("  raw text  "))
        #expect(rig.controller.original == "raw text")
        #expect(rig.panel.isVisible)
        #expect(rig.panel.layout == .refine)
        #expect(rig.controller.isStreaming)

        await rig.controller.drain()

        #expect(rig.controller.refined == "Hello there")
        #expect(!rig.controller.isStreaming)
        #expect(rig.controller.error == nil)
    }

    @Test func theRenderedPromptUsesTheDefaultPresetAndTheInstruction() async {
        let rig = makeRig()
        rig.controller.instruction = "keep it short"
        rig.controller.start(source: .selection("raw text"))
        await rig.controller.drain()

        let call = rig.recorder.calls.last
        #expect(call?.model == "qwen2.5:1.5b")
        #expect(call?.messages.first?.role == .system)
        #expect(call?.messages.last?.content.contains("keep it short") == true)
        #expect(call?.messages.last?.content.contains("raw text") == true)
        #expect(rig.controller.selectedPresetID == FactoryPresets.ID.cleanUp)
    }

    @Test func changingThePresetAndRerunningSendsANewRequest() async {
        let rig = makeRig()
        rig.controller.start(source: .selection("raw text"))
        await rig.controller.drain()

        rig.controller.selectedPresetID = FactoryPresets.ID.shorten
        rig.controller.instruction = "two sentences"
        rig.controller.rerun()
        await rig.controller.drain()

        #expect(rig.recorder.calls.count == 2)
        #expect(rig.recorder.calls[1].messages.last?.content.contains("significantly shorter") == true)
        #expect(rig.recorder.calls[1].messages.last?.content.contains("two sentences") == true)
        #expect(rig.controller.refined == "Hello there")     // reset then refilled
    }

    @Test func providerFailureShowsAnErrorBanner() async {
        let rig = makeRig(deltas: [], failure: .providerUnreachable(endpointName: "Ollama (local)"))
        rig.controller.start(source: .selection("raw"))
        await rig.controller.drain()

        #expect(!rig.controller.isStreaming)
        #expect(rig.controller.error?.contains(
            MacomprendoError.providerUnreachable(endpointName: "Ollama (local)").errorDescription ?? "!") == true)
    }

    @Test func aMissingLLMConfigurationIsReportedInTheBanner() async {
        let rig = makeRig(configured: false)
        rig.controller.start(source: .selection("raw"))
        await rig.controller.drain()
        #expect(rig.controller.error?.contains("Refine") == true)
        #expect(!rig.controller.isStreaming)
    }

    @Test func stopCancelsTheStreamAndKeepsThePartialText() async {
        let rig = makeRig(deltas: ["a", "b", "c"], delayPerDelta: .milliseconds(40))
        rig.controller.start(source: .selection("raw"))
        try? await Task.sleep(for: .milliseconds(60))
        rig.controller.stop()
        await rig.controller.drain()

        #expect(!rig.controller.isStreaming)
        #expect(rig.controller.refined.count < 3)
        #expect(rig.controller.error == nil)            // cancellation is not an error
    }

    @Test func copyPutsTheChosenSideOnThePasteboardAndKeepsThePanelOpen() async {
        let rig = makeRig()
        rig.controller.start(source: .selection("raw text"))
        await rig.controller.drain()

        rig.controller.copy(.original)
        #expect(rig.pasteboard.readString() == "raw text")
        rig.controller.copy(.refined)
        #expect(rig.pasteboard.readString() == "Hello there")
        #expect(rig.toaster.messages.count == 2)
        #expect(rig.panel.isVisible)
    }

    @Test func insertPastesIntoTheRememberedAppAndClosesThePanel() async {
        let rig = makeRig()
        rig.controller.start(source: .selection("raw text"))
        await rig.controller.drain()

        await rig.controller.insert(.refined)

        #expect(rig.inserter.calls == [ScriptedInserter.Call(
            text: "Hello there",
            app: FrontmostApp(pid: 42, bundleID: "com.example.editor", name: "Editor"),
            method: Settings.default.insertMethod)])
        #expect(!rig.panel.isVisible)
    }

    @Test func aFailedInsertToastsAndLeavesThePanelOpen() async {
        let rig = makeRig()
        rig.inserter.failure = .insertFailed
        rig.controller.start(source: .selection("raw text"))
        await rig.controller.drain()

        await rig.controller.insert(.original)

        #expect(rig.toaster.messages.count == 1)
        #expect(rig.panel.isVisible)
    }

    @Test func dictationSourceFillsOriginalFromTheTranscript() async {
        let rig = makeRig()
        rig.controller.handle(.keyDown(.dictateAndRefine))
        rig.controller.handle(.keyUp(.dictateAndRefine))
        await rig.controller.drainCapture()
        await rig.controller.drain()

        #expect(rig.controller.original == "spoken words")
        #expect(rig.panel.isVisible)
        #expect(rig.controller.refined == "Hello there")
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --package-path macos --filter RefineControllerTests`
Expected: build failure — `error: cannot find 'RefineController' in scope`.

- [ ] **Step 4: Implement the controller**

Create `macos/Sources/Macomprendo/Features/RefineController.swift`:

```swift
import AppKit
import Foundation

enum RefineSource: Equatable, Sendable {
    case dictation
    case selection(String)
}

enum RefineSide: Equatable, Sendable {
    case original
    case refined
}

/// Hotkeys #2 (Dictate & Refine) and #5 (Refine selection).
@MainActor final class RefineController: ObservableObject {
    @Published var original: String = ""
    @Published var refined: String = ""
    @Published var isStreaming: Bool = false
    @Published var selectedPresetID: UUID?
    @Published var instruction: String = ""
    @Published var error: String?
    @Published private(set) var isCapturing: Bool = false

    private let capture: DictationCapture
    private let llm: @MainActor () throws -> LLMTarget
    private let panel: QuickPanelController
    private let pasteboard: any PasteboardProtocol
    private let inserter: any TextInserting
    private let tracker: any FrontmostAppTracking
    private let toaster: any Toasting
    private let settings: @MainActor () -> Settings

    private var streamTask: Task<Void, Never>?
    /// Bumped on every re-run so a cancelled stream cannot clobber the new one's state.
    private var streamGeneration = 0
    /// The app that was frontmost when the hotkey fired; Insert pastes back into it.
    private var target: FrontmostApp?

    init(capture: DictationCapture,
         llm: @escaping @MainActor () throws -> LLMTarget,
         panel: QuickPanelController,
         pasteboard: any PasteboardProtocol,
         inserter: any TextInserting,
         tracker: any FrontmostAppTracking,
         toaster: any Toasting,
         settings: @escaping @MainActor () -> Settings) {
        self.capture = capture
        self.llm = llm
        self.panel = panel
        self.pasteboard = pasteboard
        self.inserter = inserter
        self.tracker = tracker
        self.toaster = toaster
        self.settings = settings

        capture.onTranscript = { [weak self] text in self?.beginRefine(with: text) }
        capture.onError = { [weak self] error in
            self?.toaster.toast(ErrorText.describe(error), duration: 2.5)
        }
        capture.onStateChange = { [weak self] state in self?.isCapturing = state != .idle }
    }

    // MARK: Starting

    /// Hold/toggle routing for hotkey #2.
    func handle(_ event: HotkeyEvent) {
        if case .keyDown = event { target = tracker.capture() }
        capture.handle(event)
    }

    func start(source: RefineSource) {
        switch source {
        case .dictation:
            target = tracker.capture()
            capture.handle(.keyDown(.dictateAndRefine))
        case .selection(let text):
            target = tracker.capture()
            beginRefine(with: text)
        }
    }

    private func beginRefine(with text: String) {
        original = text.trimmingCharacters(in: .whitespacesAndNewlines)
        refined = ""
        error = nil
        if selectedPresetID == nil {
            selectedPresetID = settings().defaultPreset(for: .refine)?.id
        }
        panel.present(layout: .refine, on: NSScreen.main)
        rerun()
    }

    // MARK: Streaming

    func rerun() {
        streamTask?.cancel()
        streamGeneration += 1
        let generation = streamGeneration
        isStreaming = true
        refined = ""
        error = nil
        streamTask = Task { [weak self] in await self?.runStream(generation: generation) }
    }

    func stop() {
        streamTask?.cancel()
        isStreaming = false
    }

    /// Awaits the in-flight stream. Used by tests.
    func drain() async {
        _ = await streamTask?.value
    }

    /// Awaits the in-flight microphone capture. Used by tests.
    func drainCapture() async {
        await capture.drain()
    }

    private func runStream(generation: Int) async {
        defer { if generation == streamGeneration { isStreaming = false } }
        let current = settings()

        let chosen: PromptPreset?
        if let id = selectedPresetID, let found = current.preset(id: id), found.kind == .refine {
            chosen = found
        } else {
            chosen = current.defaultPreset(for: .refine)
        }
        guard let preset = chosen else {
            error = ErrorText.describe(FeatureConfigError.noPreset(.refine))
            return
        }

        let problems = PromptRenderer.validate(preset)
        guard problems.isEmpty else {
            error = problems.joined(separator: " ")
            return
        }

        let prompt = PromptRenderer.render(preset, text: original,
                                           instruction: instruction,
                                           language: Self.uiLanguageName())
        do {
            let target = try llm()
            for try await delta in target.provider.chat(prompt.messages, model: target.model,
                                                        options: ChatOptions()) {
                guard generation == streamGeneration else { return }
                refined += delta
            }
        } catch is CancellationError {
            // The user pressed Stop or started a re-run: keep whatever streamed so far.
        } catch MacomprendoError.cancelled {
        } catch {
            if generation == streamGeneration { self.error = ErrorText.describe(error) }
        }
    }

    /// Target language for the Translate preset: the app's UI language unless the user types
    /// something else into the instruction field.
    static func uiLanguageName() -> String {
        let locale = Locale.current
        guard let code = locale.language.languageCode?.identifier,
              let name = locale.localizedString(forLanguageCode: code)
        else { return PromptRenderer.defaultLanguage }
        return name
    }

    // MARK: Actions

    func copy(_ side: RefineSide) {
        pasteboard.writeString(text(for: side))
        toaster.toast("Copied.", duration: 1.2)
    }

    func insert(_ side: RefineSide) async {
        let value = text(for: side)
        guard !value.isEmpty else {
            toaster.toast("Nothing to insert yet.", duration: 1.5)
            return
        }
        do {
            try await inserter.insert(value, into: target, method: settings().insertMethod)
            panel.dismiss()
        } catch {
            toaster.toast(ErrorText.describe(error), duration: 2.5)
        }
    }

    private func text(for side: RefineSide) -> String {
        switch side {
        case .original: original
        case .refined: refined
        }
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --package-path macos --filter RefineControllerTests`
Expected: PASS — 10 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add macos/Sources/Macomprendo/Features/RefineController.swift \
        macos/Tests/MacomprendoTests/Fakes/ScriptedLLMProvider.swift \
        macos/Tests/MacomprendoTests/Fakes/ScriptedInserter.swift \
        macos/Tests/MacomprendoTests/Fakes/ScriptedTracker.swift \
        macos/Tests/MacomprendoTests/Features/RefineControllerTests.swift
git commit -m "feat(refine): stream refined text into the quick panel"
```

---

### Task 11: `SummarizeController`

**Files:**
- Create: `macos/Sources/Macomprendo/Features/SummarizeController.swift`
- Test: `macos/Tests/MacomprendoTests/Features/SummarizeControllerTests.swift`

**Interfaces:**
- Consumes: the same collaborators as Task 10 (no microphone capture).
- Produces:
  ```swift
  @MainActor final class SummarizeController: ObservableObject {
      @Published var source: String
      @Published var summary: String
      @Published var isStreaming: Bool
      @Published var selectedPresetID: UUID?
      @Published var instruction: String
      @Published var error: String?
      init(llm: @escaping @MainActor () throws -> LLMTarget,
           panel: QuickPanelController,
           pasteboard: any PasteboardProtocol,
           inserter: any TextInserting,
           tracker: any FrontmostAppTracking,
           toaster: any Toasting,
           settings: @escaping @MainActor () -> Settings)
      func start(text: String)
      func rerun()
      func stop()
      func copy()
      func replaceSelection() async
      func drain() async
  }
  ```

- [ ] **Step 1: Write the failing test**

Create `macos/Tests/MacomprendoTests/Features/SummarizeControllerTests.swift`:

```swift
import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct SummarizeControllerTests {
    struct Rig {
        let controller: SummarizeController
        let panel: QuickPanelController
        let pasteboard: ScriptedPasteboard
        let inserter: ScriptedInserter
        let toaster: ScriptedToaster
        let recorder: LLMCallRecorder
        let holder: ScriptedSettingsHolder
    }

    private func makeRig(deltas: [String] = ["Short", " summary"],
                         failure: MacomprendoError? = nil,
                         delayPerDelta: Duration = .zero) -> Rig {
        let holder = ScriptedSettingsHolder.seeded()
        let panel = QuickPanelController(holder: holder)
        panel.attach(ScriptedPanelHost())

        let recorder = LLMCallRecorder()
        let provider = ScriptedLLMProvider(deltas: deltas, failure: failure,
                                           delayPerDelta: delayPerDelta, recorder: recorder)
        let pasteboard = ScriptedPasteboard()
        let inserter = ScriptedInserter()
        let toaster = ScriptedToaster()

        let controller = SummarizeController(
            llm: { LLMTarget(provider: provider, model: "qwen2.5:1.5b") },
            panel: panel,
            pasteboard: pasteboard,
            inserter: inserter,
            tracker: ScriptedTracker(),
            toaster: toaster,
            settings: { holder.settings })

        return Rig(controller: controller, panel: panel, pasteboard: pasteboard,
                   inserter: inserter, toaster: toaster, recorder: recorder, holder: holder)
    }

    @Test func startOpensTheSummaryLayoutAndStreams() async {
        let rig = makeRig()
        rig.controller.start(text: "  a long article  ")
        #expect(rig.controller.source == "a long article")
        #expect(rig.panel.isVisible)
        #expect(rig.panel.layout == .summary)

        await rig.controller.drain()

        #expect(rig.controller.summary == "Short summary")
        #expect(!rig.controller.isStreaming)
        #expect(rig.controller.selectedPresetID == FactoryPresets.ID.brief)
    }

    @Test func theBriefPresetTemplateIsUsed() async {
        let rig = makeRig()
        rig.controller.start(text: "a long article")
        await rig.controller.drain()
        let user = rig.recorder.calls.last?.messages.last?.content
        #expect(user?.contains("two or three sentences") == true)
        #expect(user?.contains("a long article") == true)
    }

    @Test func switchingToBulletsAndRerunningResends() async {
        let rig = makeRig()
        rig.controller.start(text: "a long article")
        await rig.controller.drain()

        rig.controller.selectedPresetID = FactoryPresets.ID.bullets
        rig.controller.rerun()
        await rig.controller.drain()

        #expect(rig.recorder.calls.count == 2)
        #expect(rig.recorder.calls[1].messages.last?.content.contains("bullet points") == true)
    }

    @Test func providerFailureIsShownInTheBanner() async {
        let rig = makeRig(deltas: [], failure: .providerHTTP(status: 500, body: "boom"))
        rig.controller.start(text: "text")
        await rig.controller.drain()
        #expect(rig.controller.error != nil)
        #expect(!rig.controller.isStreaming)
    }

    @Test func stopKeepsThePartialSummary() async {
        let rig = makeRig(deltas: ["x", "y", "z"], delayPerDelta: .milliseconds(40))
        rig.controller.start(text: "text")
        try? await Task.sleep(for: .milliseconds(60))
        rig.controller.stop()
        await rig.controller.drain()
        #expect(!rig.controller.isStreaming)
        #expect(rig.controller.summary.count < 3)
        #expect(rig.controller.error == nil)
    }

    @Test func copyWritesTheSummaryAndKeepsThePanelOpen() async {
        let rig = makeRig()
        rig.controller.start(text: "text")
        await rig.controller.drain()
        rig.controller.copy()
        #expect(rig.pasteboard.readString() == "Short summary")
        #expect(rig.toaster.messages.count == 1)
        #expect(rig.panel.isVisible)
    }

    @Test func replaceSelectionPastesTheSummaryAndClosesThePanel() async {
        let rig = makeRig()
        rig.controller.start(text: "text")
        await rig.controller.drain()

        await rig.controller.replaceSelection()

        #expect(rig.inserter.calls.count == 1)
        #expect(rig.inserter.calls[0].text == "Short summary")
        #expect(rig.inserter.calls[0].app?.name == "Editor")
        #expect(!rig.panel.isVisible)
    }

    @Test func replaceSelectionBeforeAnySummaryToastsInstead() async {
        let rig = makeRig(deltas: [], delayPerDelta: .milliseconds(200))
        rig.controller.start(text: "text")
        await rig.controller.replaceSelection()
        #expect(rig.inserter.calls.isEmpty)
        #expect(rig.toaster.messages.count == 1)
        rig.controller.stop()
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path macos --filter SummarizeControllerTests`
Expected: build failure — `error: cannot find 'SummarizeController' in scope`.

- [ ] **Step 3: Implement the controller**

Create `macos/Sources/Macomprendo/Features/SummarizeController.swift`:

```swift
import AppKit
import Foundation

/// Hotkey #4. Selected text in, streamed summary out, Copy or Replace selection.
@MainActor final class SummarizeController: ObservableObject {
    @Published var source: String = ""
    @Published var summary: String = ""
    @Published var isStreaming: Bool = false
    @Published var selectedPresetID: UUID?
    @Published var instruction: String = ""
    @Published var error: String?

    private let llm: @MainActor () throws -> LLMTarget
    private let panel: QuickPanelController
    private let pasteboard: any PasteboardProtocol
    private let inserter: any TextInserting
    private let tracker: any FrontmostAppTracking
    private let toaster: any Toasting
    private let settings: @MainActor () -> Settings

    private var streamTask: Task<Void, Never>?
    private var streamGeneration = 0
    private var target: FrontmostApp?

    init(llm: @escaping @MainActor () throws -> LLMTarget,
         panel: QuickPanelController,
         pasteboard: any PasteboardProtocol,
         inserter: any TextInserting,
         tracker: any FrontmostAppTracking,
         toaster: any Toasting,
         settings: @escaping @MainActor () -> Settings) {
        self.llm = llm
        self.panel = panel
        self.pasteboard = pasteboard
        self.inserter = inserter
        self.tracker = tracker
        self.toaster = toaster
        self.settings = settings
    }

    func start(text: String) {
        target = tracker.capture()
        source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        summary = ""
        error = nil
        if selectedPresetID == nil {
            selectedPresetID = settings().defaultPreset(for: .summarize)?.id
        }
        panel.present(layout: .summary, on: NSScreen.main)
        rerun()
    }

    func rerun() {
        streamTask?.cancel()
        streamGeneration += 1
        let generation = streamGeneration
        isStreaming = true
        summary = ""
        error = nil
        streamTask = Task { [weak self] in await self?.runStream(generation: generation) }
    }

    func stop() {
        streamTask?.cancel()
        isStreaming = false
    }

    /// Awaits the in-flight stream. Used by tests.
    func drain() async {
        _ = await streamTask?.value
    }

    private func runStream(generation: Int) async {
        defer { if generation == streamGeneration { isStreaming = false } }
        let current = settings()

        let chosen: PromptPreset?
        if let id = selectedPresetID, let found = current.preset(id: id), found.kind == .summarize {
            chosen = found
        } else {
            chosen = current.defaultPreset(for: .summarize)
        }
        guard let preset = chosen else {
            error = ErrorText.describe(FeatureConfigError.noPreset(.summarize))
            return
        }

        let problems = PromptRenderer.validate(preset)
        guard problems.isEmpty else {
            error = problems.joined(separator: " ")
            return
        }

        let prompt = PromptRenderer.render(preset, text: source,
                                           instruction: instruction,
                                           language: RefineController.uiLanguageName())
        do {
            let target = try llm()
            for try await delta in target.provider.chat(prompt.messages, model: target.model,
                                                        options: ChatOptions()) {
                guard generation == streamGeneration else { return }
                summary += delta
            }
        } catch is CancellationError {
        } catch MacomprendoError.cancelled {
        } catch {
            if generation == streamGeneration { self.error = ErrorText.describe(error) }
        }
    }

    func copy() {
        pasteboard.writeString(summary)
        toaster.toast("Copied.", duration: 1.2)
    }

    /// The selection is still selected in the source app, so pasting replaces it.
    func replaceSelection() async {
        guard !summary.isEmpty else {
            toaster.toast("Nothing to insert yet.", duration: 1.5)
            return
        }
        do {
            try await inserter.insert(summary, into: target, method: settings().insertMethod)
            panel.dismiss()
        } catch {
            toaster.toast(ErrorText.describe(error), duration: 2.5)
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --package-path macos --filter SummarizeControllerTests`
Expected: PASS — 8 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Macomprendo/Features/SummarizeController.swift \
        macos/Tests/MacomprendoTests/Features/SummarizeControllerTests.swift
git commit -m "feat(summarize): stream summaries into the quick panel"
```

---

### Task 12: Quick Panel SwiftUI layouts

**Files:**
- Create: `macos/Sources/Macomprendo/UI/QuickPanel/QuickPanelView.swift`
- Create: `macos/Sources/Macomprendo/UI/QuickPanel/RefineLayout.swift`
- Create: `macos/Sources/Macomprendo/UI/QuickPanel/SummaryLayout.swift`

**Interfaces:**
- Consumes: `QuickPanelController`, `RefineController`, `SummarizeController`, `AppModel`,
  `Settings.presets(of:)`.
- Produces: `struct QuickPanelView: View`, `struct RefineLayout: View`, `struct SummaryLayout: View`
  — all initialised with `(panel:refine:summarize:app:)`, `(controller:presets:)`,
  `(controller:presets:)` respectively.

**Icon facts (Plan 1):** never `import PhosphorSwift` in feature code. Use the seam
`Components/Icon.swift`: `Icon(.copy, size: 14)`, where `enum AppIcon: String` already has the
cases `microphone, waveform, speakerHigh, stop, play, sparkle, textAa, clipboardText,
arrowSquareIn, copy, gear, keyboard, downloadSimple, trash, checkCircle, warningCircle, x, plus,
minus, arrowsClockwise, cloud, cpu, listBullets, magicWand` (rendered from vendored Phosphor SVGs).
Icons used here: `.copy`, `.arrowSquareIn` (insert/replace), `.arrowsClockwise` (re-run), `.stop`,
`.warningCircle`, `.textAa`.

- [ ] **Step 1: Write the switching container**

Create `macos/Sources/Macomprendo/UI/QuickPanel/QuickPanelView.swift`:

```swift
import SwiftUI

/// Root of the floating panel: picks the layout the controller is currently presenting.
struct QuickPanelView: View {
    @ObservedObject var panel: QuickPanelController
    @ObservedObject var refine: RefineController
    @ObservedObject var summarize: SummarizeController
    @ObservedObject var app: AppModel

    var body: some View {
        Group {
            switch panel.layout {
            case .refine:
                RefineLayout(controller: refine, presets: app.settings.presets(of: .refine))
            case .summary:
                SummaryLayout(controller: summarize, presets: app.settings.presets(of: .summarize))
            }
        }
        .frame(minWidth: 520, minHeight: 300)
        .background(.thinMaterial)
    }
}
```

- [ ] **Step 2: Write the refine layout**

Create `macos/Sources/Macomprendo/UI/QuickPanel/RefineLayout.swift`:

```swift
import SwiftUI

/// Original | Refined side by side, both editable, with per-side Copy and Insert.
struct RefineLayout: View {
    @ObservedObject var controller: RefineController
    let presets: [PromptPreset]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let error = controller.error { errorBanner(error) }
            HStack(spacing: 0) {
                pane(title: "Original", text: $controller.original, side: .original)
                Divider()
                pane(title: "Refined", text: $controller.refined, side: .refined)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $controller.selectedPresetID) {
                ForEach(presets) { preset in
                    Text(preset.name).tag(Optional(preset.id))
                }
            }
            .labelsHidden()
            .frame(width: 160)
            .onChange(of: controller.selectedPresetID) { _, _ in controller.rerun() }

            TextField("Extra instruction (⌘↩ to run again)", text: $controller.instruction)
                .textFieldStyle(.roundedBorder)
                .onSubmit { controller.rerun() }

            if controller.isStreaming {
                ProgressView().controlSize(.small)
                Button { controller.stop() } label: {
                    Icon(.stop, size: 14)
                }
                .help("Stop streaming")
            } else {
                Button { controller.rerun() } label: {
                    Icon(.arrowsClockwise, size: 14)
                }
                .help("Run again (⌘↩)")
            }

            // Invisible button that owns the ⌘↩ shortcut for the whole panel.
            Button("") { controller.rerun() }
                .keyboardShortcut(.return, modifiers: .command)
                .opacity(0)
                .frame(width: 0)
        }
        .padding(10)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Icon(.warningCircle, size: 14)
            Text(message).font(.callout).textSelection(.enabled)
            Spacer()
        }
        .foregroundStyle(.red)
        .padding(8)
        .background(Color.red.opacity(0.08))
    }

    private func pane(title: String, text: Binding<String>, side: RefineSide) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { controller.copy(side) } label: {
                    Icon(.copy, size: 14)
                }
                .help("Copy \(title.lowercased())")
                Button { Task { await controller.insert(side) } } label: {
                    Icon(.arrowSquareIn, size: 14)
                }
                .help("Insert \(title.lowercased()) into the previous app")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            TextEditor(text: text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 6)
        }
        .frame(maxWidth: .infinity)
    }
}
```

- [ ] **Step 3: Write the summary layout**

Create `macos/Sources/Macomprendo/UI/QuickPanel/SummaryLayout.swift`:

```swift
import SwiftUI

/// One pane with the streamed summary; Copy or Replace the selection in the source app.
struct SummaryLayout: View {
    @ObservedObject var controller: SummarizeController
    let presets: [PromptPreset]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let error = controller.error { errorBanner(error) }
            TextEditor(text: $controller.summary)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 10)
            Divider()
            footer
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Icon(.textAa, size: 14)
                .foregroundStyle(.secondary)

            Picker("", selection: $controller.selectedPresetID) {
                ForEach(presets) { preset in
                    Text(preset.name).tag(Optional(preset.id))
                }
            }
            .labelsHidden()
            .frame(width: 160)
            .onChange(of: controller.selectedPresetID) { _, _ in controller.rerun() }

            TextField("Extra instruction (⌘↩ to run again)", text: $controller.instruction)
                .textFieldStyle(.roundedBorder)
                .onSubmit { controller.rerun() }

            if controller.isStreaming {
                ProgressView().controlSize(.small)
                Button { controller.stop() } label: {
                    Icon(.stop, size: 14)
                }
                .help("Stop streaming")
            } else {
                Button { controller.rerun() } label: {
                    Icon(.arrowsClockwise, size: 14)
                }
                .help("Run again (⌘↩)")
            }

            Button("") { controller.rerun() }
                .keyboardShortcut(.return, modifiers: .command)
                .opacity(0)
                .frame(width: 0)
        }
        .padding(10)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Icon(.warningCircle, size: 14)
            Text(message).font(.callout).textSelection(.enabled)
            Spacer()
        }
        .foregroundStyle(.red)
        .padding(8)
        .background(Color.red.opacity(0.08))
    }

    private var footer: some View {
        HStack {
            Text("\(controller.source.count) characters summarized")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button { controller.copy() } label: {
                Label { Text("Copy") } icon: {
                    Icon(.copy, size: 14)
                }
            }
            Button { Task { await controller.replaceSelection() } } label: {
                Label { Text("Replace selection") } icon: {
                    Icon(.arrowSquareIn, size: 14)
                }
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(10)
    }
}
```

- [ ] **Step 4: Verify the build**

Run: `swift build --package-path macos`
Expected: `Build complete!`
If the compiler reports an unknown `AppIcon` case, add it to `enum AppIcon` in
`macos/Sources/Macomprendo/UI/Components/Icon.swift` together with its vendored SVG, following the
cases Plan 1 created there.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Macomprendo/UI/QuickPanel/QuickPanelView.swift \
        macos/Sources/Macomprendo/UI/QuickPanel/RefineLayout.swift \
        macos/Sources/Macomprendo/UI/QuickPanel/SummaryLayout.swift
git commit -m "feat(quickpanel): add refine and summary layouts"
```

---

### Task 13: Routing (`TextFeatures`) and app wiring

**Files:**
- Create: `macos/Sources/Macomprendo/App/TextFeatures.swift`
- Modify: `macos/Sources/Macomprendo/App/AppModel.swift`
- Modify: `macos/Sources/Macomprendo/App/AppEnvironment.swift`
- Modify: Plan 3's test-only `AppEnvironment.fake(...)` in `macos/Tests/MacomprendoTests/Fakes/`
- Test: `macos/Tests/MacomprendoTests/App/TextFeaturesTests.swift`

**Interfaces:**
- Consumes: every controller from Tasks 7–11, `AXSelectedTextService` (Task 4),
  `AVSpeechService` (Task 5), `ProviderFactory` (Plan 2), `HUDController` (Plan 3).
- Produces:
  ```swift
  @MainActor final class TextFeatures {
      let quickPanel: QuickPanelController
      let refine: RefineController
      let summarize: SummarizeController
      let speak: SpeakController
      init(quickPanel:refine:summarize:speak:selectedText:toaster:)
      func handle(_ event: HotkeyEvent)
      func drain() async
      static func live(model: AppModel, env: AppEnvironment, hud: HUDController,
                       transcriberProvider: @escaping @Sendable () async throws -> any TranscriptionProvider) -> TextFeatures
  }
  extension AppModel { func llmTarget(for kind: PresetKind) throws -> LLMTarget }
  ```
- `AppModel` gains `private(set) var textFeatures: TextFeatures?`, built in `start()`.
- `AppEnvironment` gains `pasteboard`, `keySimulator`, `ax`, `speech`, `quickPanelHost`.

- [ ] **Step 1: Write the failing test**

Create `macos/Tests/MacomprendoTests/App/TextFeaturesTests.swift`:

```swift
import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct TextFeaturesTests {
    struct Rig {
        let features: TextFeatures
        let speech: ScriptedSpeech
        let toaster: ScriptedToaster
        let panelHost: ScriptedPanelHost
        let keys: ScriptedKeySimulator
    }

    private func makeRig(selection: String?) -> Rig {
        let holder = ScriptedSettingsHolder.seeded()
        let host = ScriptedPanelHost()
        let panel = QuickPanelController(holder: holder)
        panel.attach(host)

        let provider = ScriptedLLMProvider(deltas: ["ok"], recorder: LLMCallRecorder())
        let pasteboard = ScriptedPasteboard(initialString: "clip")
        let keys = ScriptedKeySimulator()
        let toaster = ScriptedToaster()
        let speech = ScriptedSpeech()

        let capture = DictationCapture(
            recorder: ScriptedRecorder(),
            transcriberProvider: { ScriptedTranscriber(text: "spoken") },
            permissions: ScriptedPermissions(),
            mode: { .hold },
            language: { nil })

        let refine = RefineController(
            capture: capture,
            llm: { LLMTarget(provider: provider, model: "m") },
            panel: panel, pasteboard: pasteboard, inserter: ScriptedInserter(),
            tracker: ScriptedTracker(), toaster: toaster, settings: { holder.settings })

        let summarize = SummarizeController(
            llm: { LLMTarget(provider: provider, model: "m") },
            panel: panel, pasteboard: pasteboard, inserter: ScriptedInserter(),
            tracker: ScriptedTracker(), toaster: toaster, settings: { holder.settings })

        let speak = SpeakController(speech: speech, toaster: toaster, settings: { holder.settings })

        let selectedText = AXSelectedTextService(
            ax: ScriptedAXReader(text: selection), pasteboard: pasteboard,
            keySimulator: keys, copyTimeout: 0.02, pollInterval: 0.005)

        let features = TextFeatures(quickPanel: panel, refine: refine, summarize: summarize,
                                    speak: speak, selectedText: selectedText, toaster: toaster)
        return Rig(features: features, speech: speech, toaster: toaster, panelHost: host, keys: keys)
    }

    @Test func summarizeHotkeyReadsTheSelectionAndOpensTheSummaryPanel() async {
        let rig = makeRig(selection: "an article")
        rig.features.handle(.keyDown(.summarize))
        await rig.features.drain()
        await rig.features.summarize.drain()

        #expect(rig.features.summarize.source == "an article")
        #expect(rig.features.quickPanel.layout == .summary)
        #expect(rig.features.quickPanel.isVisible)
    }

    @Test func refineSelectionHotkeyOpensTheRefinePanel() async {
        let rig = makeRig(selection: "some prose")
        rig.features.handle(.keyDown(.refineSelection))
        await rig.features.drain()
        await rig.features.refine.drain()

        #expect(rig.features.refine.original == "some prose")
        #expect(rig.features.quickPanel.layout == .refine)
    }

    @Test func speakHotkeySpeaksTheSelectionAndTheSecondPressStops() async {
        let rig = makeRig(selection: "read this")
        rig.features.handle(.keyDown(.speak))
        await rig.features.drain()
        #expect(rig.speech.spoken.map(\.text) == ["read this"])

        rig.features.handle(.keyDown(.speak))
        await rig.features.drain()
        #expect(rig.speech.stopCount == 1)
        #expect(rig.speech.spoken.count == 1)
    }

    @Test func anEmptySelectionToastsAndOpensNothing() async {
        let rig = makeRig(selection: nil)          // no AX text, no ⌘C result either
        rig.features.handle(.keyDown(.summarize))
        await rig.features.drain()

        #expect(rig.toaster.messages.count == 1)
        #expect(rig.toaster.messages[0].contains(MacomprendoError.noSelection.errorDescription ?? "!"))
        #expect(!rig.features.quickPanel.isVisible)
    }

    @Test func dictateAndRefineIsRoutedToTheRefineControllerAsHoldAndRelease() async {
        let rig = makeRig(selection: nil)
        rig.features.handle(.keyDown(.dictateAndRefine))
        rig.features.handle(.keyUp(.dictateAndRefine))
        await rig.features.refine.drainCapture()
        await rig.features.refine.drain()

        #expect(rig.features.refine.original == "spoken")
        #expect(rig.features.quickPanel.isVisible)
        #expect(rig.keys.presses.isEmpty)          // the microphone path never touches the clipboard
    }

    @Test func plainDictateHotkeyIsIgnoredHere() async {
        let rig = makeRig(selection: "text")
        rig.features.handle(.keyDown(.dictate))
        rig.features.handle(.keyUp(.dictate))
        await rig.features.drain()
        #expect(!rig.features.quickPanel.isVisible)
        #expect(rig.speech.spoken.isEmpty)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path macos --filter TextFeaturesTests`
Expected: build failure — `error: cannot find 'TextFeatures' in scope`.

- [ ] **Step 3: Implement `TextFeatures`**

Create `macos/Sources/Macomprendo/App/TextFeatures.swift`:

```swift
import AppKit
import Foundation

/// Owns hotkeys #2–#5 and the Quick Panel. `AppModel` forwards every non-dictation
/// `HotkeyEvent` here.
@MainActor final class TextFeatures {
    let quickPanel: QuickPanelController
    let refine: RefineController
    let summarize: SummarizeController
    let speak: SpeakController

    private let selectedText: any SelectedTextReading
    private let toaster: any Toasting
    private var task: Task<Void, Never>?

    init(quickPanel: QuickPanelController,
         refine: RefineController,
         summarize: SummarizeController,
         speak: SpeakController,
         selectedText: any SelectedTextReading,
         toaster: any Toasting) {
        self.quickPanel = quickPanel
        self.refine = refine
        self.summarize = summarize
        self.speak = speak
        self.selectedText = selectedText
        self.toaster = toaster
    }

    func handle(_ event: HotkeyEvent) {
        switch event {
        case .keyDown(.dictateAndRefine), .keyUp(.dictateAndRefine):
            refine.handle(event)

        case .keyDown(.refineSelection):
            withSelection { [weak self] text in self?.refine.start(source: .selection(text)) }

        case .keyDown(.summarize):
            withSelection { [weak self] text in self?.summarize.start(text: text) }

        case .keyDown(.speak):
            task = Task { [weak self] in
                guard let self else { return }
                // `toggle` only evaluates the closure when it is about to start speaking, so a
                // second press stops without simulating ⌘C.
                await self.speak.toggle(text: { try await self.selectedText.read() })
            }

        case .keyDown(.dictate), .keyUp(.dictate),
             .keyUp(.speak), .keyUp(.summarize), .keyUp(.refineSelection):
            break
        }
    }

    /// Awaits the in-flight selection read / speech toggle. Used by tests.
    func drain() async {
        _ = await task?.value
    }

    private func withSelection(_ body: @escaping @MainActor (String) -> Void) {
        task = Task { [weak self] in
            guard let self else { return }
            do {
                body(try await self.selectedText.read())
            } catch {
                self.toaster.toast(ErrorText.describe(error), duration: 2.5)
            }
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --package-path macos --filter TextFeaturesTests`
Expected: PASS — 6 tests, 0 failures.

- [ ] **Step 5: Add the composition root helper**

Append to `macos/Sources/Macomprendo/App/TextFeatures.swift`:

```swift
extension AppModel {
    /// The provider + model configured for one feature in Settings ▸ Refine & Summarize.
    func llmTarget(for kind: PresetKind) throws -> LLMTarget {
        let selection: LLMSelection?
        switch kind {
        case .refine: selection = settings.refineLLM
        case .summarize: selection = settings.summarizeLLM
        }
        guard let selection, !selection.model.isEmpty,
              let endpoint = settings.endpoints.first(where: { $0.id == selection.endpointID })
        else { throw FeatureConfigError.llmNotConfigured(kind) }
        return LLMTarget(provider: try env.factory.llm(for: endpoint), model: selection.model)
    }
}

extension TextFeatures {
    /// Builds the real object graph, including the floating panel window when the environment
    /// supplies a host factory (it is nil in `AppEnvironment.fake()`, so tests build no windows).
    static func live(model: AppModel,
                     env: AppEnvironment,
                     hud: HUDController,
                     transcriberProvider: @escaping @Sendable () async throws -> any TranscriptionProvider)
        -> TextFeatures {

        let quickPanel = QuickPanelController(holder: model)

        let capture = DictationCapture(
            recorder: env.recorder,
            transcriberProvider: transcriberProvider,
            permissions: env.permissions,
            mode: { model.settings.dictationMode },
            language: { model.settings.transcriptionLanguage })

        let refine = RefineController(
            capture: capture,
            llm: { try model.llmTarget(for: .refine) },
            panel: quickPanel,
            pasteboard: env.pasteboard,
            inserter: env.inserter,
            tracker: env.tracker,
            toaster: hud,
            settings: { model.settings })

        let summarize = SummarizeController(
            llm: { try model.llmTarget(for: .summarize) },
            panel: quickPanel,
            pasteboard: env.pasteboard,
            inserter: env.inserter,
            tracker: env.tracker,
            toaster: hud,
            settings: { model.settings })

        let speak = SpeakController(speech: env.speech, toaster: hud, settings: { model.settings })

        let selectedText = AXSelectedTextService(ax: env.ax,
                                                 pasteboard: env.pasteboard,
                                                 keySimulator: env.keySimulator)

        let features = TextFeatures(quickPanel: quickPanel, refine: refine, summarize: summarize,
                                    speak: speak, selectedText: selectedText, toaster: hud)

        // The panel's content needs the controllers, so the window is built last and attached.
        if let makeHost = env.quickPanelHost {
            quickPanel.attach(makeHost(QuickPanelView(panel: quickPanel, refine: refine,
                                                      summarize: summarize, app: model)))
        }
        return features
    }
}
```

- [ ] **Step 6: Extend `AppEnvironment`**

Open `macos/Sources/Macomprendo/App/AppEnvironment.swift`. Plan 3's struct has `hotkeys`,
`recorder`, `inserter`, `tracker`, `permissions`, `models`, `http`, `keychain`, `factory`,
`hudPresenter`, `ollamaDetector`. Add five properties after `ollamaDetector`:

```swift
    var pasteboard: any PasteboardProtocol
    var keySimulator: any KeySimulating
    var ax: any AXReading
    var speech: any SpeechSynthesizing
    /// nil in tests: no NSPanel is created and the Quick Panel controller stays headless.
    var quickPanelHost: (@MainActor (QuickPanelView) -> any QuickPanelHosting)?
```

and fill them in `live()` (the pasteboard and key simulator are the same instances
`PasteTextInserter` already uses there — reuse the locals rather than making new ones):

```swift
        pasteboard: pasteboard,
        keySimulator: keySimulator,
        ax: SystemAXReader(),
        speech: AVSpeechService(),
        quickPanelHost: { view in FloatingPanelHost(rootView: view) }
```

Then open the test-only `AppEnvironment.fake(...)` (Plan 3 defined it in
`macos/Tests/MacomprendoTests/Fakes/`) and give the five new parameters defaults:

```swift
        pasteboard: any PasteboardProtocol = ScriptedPasteboard(),
        keySimulator: any KeySimulating = ScriptedKeySimulator(),
        ax: any AXReading = ScriptedAXReader(text: nil),
        speech: any SpeechSynthesizing = ScriptedSpeech(),
        quickPanelHost: (@MainActor (QuickPanelView) -> any QuickPanelHosting)? = nil
```

`AppEnvironment.fake()` is `@MainActor`; if Plan 3 declared it non-isolated, add `@MainActor`
now — `ScriptedSpeech` is main-actor isolated.

- [ ] **Step 7: Route the hotkeys in `AppModel`**

Open `macos/Sources/Macomprendo/App/AppModel.swift`.

1. Add a stored property right after `let transcriberProvider`:

```swift
    private(set) var textFeatures: TextFeatures?
```

2. At the top of `start()`, before the hotkey enablement loop, build it once:

```swift
        if textFeatures == nil {
            textFeatures = TextFeatures.live(model: self, env: env, hud: hud,
                                             transcriberProvider: transcriberProvider)
        }
```

3. In `route(_:)`, replace

```swift
        default:
            break   // Plan 4 adds dictateAndRefine, speak, summarize, refineSelection
```

with

```swift
        default:
            textFeatures?.handle(event)
```

Plan 3's `AppModelTests.ignoresActionsThatAreNotImplementedYet` still passes: with the fake
environment `.keyDown(.speak)` and `.keyDown(.summarize)` find no selection, so they only toast
and `model.dictation.state` stays `.idle`. Rename that test to
`routesSelectionActionsToTheTextFeatures` and extend it if you prefer, but do not delete it.

- [ ] **Step 8: Run the whole suite**

Run: `swift test --package-path macos`
Expected: all suites pass, 0 failures.

- [ ] **Step 9: Manual verification (hardware paths)**

```bash
node scripts/build-app.mjs      # or: npm run build
open build/Macomprendo.app      # path per Plan 1's build script output
```

In System Settings ▸ Privacy & Security, confirm Macomprendo has Accessibility and Microphone
permission, make sure Ollama is running (`ollama serve`) with `qwen2.5:1.5b` pulled, then check:

1. Select a sentence in TextEdit, press ⌥M → the Quick Panel opens top-center with a streaming
   summary; "Replace selection" swaps the selected sentence for the summary.
2. Select a sentence, press ⌥S → it is read aloud; press ⌥S again → it stops immediately.
3. Press ⌥⇧Space, dictate a sentence, release → the panel opens with Original filled and Refined
   streaming; edit the instruction, press ⌘↩ → it re-runs; press Insert on the refined side → the
   text lands in the previously focused app and the panel closes.
4. Drag the panel to a new position, dismiss with Esc, trigger it again → it reopens where you
   left it.
5. Copy something to the clipboard, trigger ⌥M in an app without AX selection support (e.g.
   Terminal), and confirm the clipboard still holds your original content afterwards.

- [ ] **Step 10: Commit**

```bash
git add macos/Sources/Macomprendo/App/TextFeatures.swift \
        macos/Sources/Macomprendo/App/AppModel.swift \
        macos/Sources/Macomprendo/App/AppEnvironment.swift \
        macos/Tests/MacomprendoTests/App/TextFeaturesTests.swift
git commit -m "feat(app): route selection hotkeys to the text feature controllers"
```

---

### Task 14: Settings ▸ Speech tab

**Files:**
- Create: `macos/Sources/Macomprendo/UI/Settings/SpeechTab.swift`
- Modify: `macos/Sources/Macomprendo/App/AppModel.swift`, `macos/Sources/Macomprendo/UI/Settings/SettingsView.swift`
- Test: `macos/Tests/MacomprendoTests/UI/SpeechTabModelTests.swift`

**Interfaces:**
- Consumes: `Voice`, `SpeechSynthesizing` (Task 5), `SettingsHolding` (Task 6).
- Produces:
  ```swift
  @MainActor final class SpeechTabModel: ObservableObject {
      struct VoiceGroup: Identifiable, Equatable { let language: String; let displayName: String; let voices: [Voice]; var id: String { language } }
      @Published private(set) var groups: [VoiceGroup]
      init(speech: any SpeechSynthesizing, holder: any SettingsHolding)
      func reload()
      func preview()
      static func group(_ voices: [Voice]) -> [VoiceGroup]
      static let sampleText: String
  }
  struct SpeechTab: View { init(model: SpeechTabModel, app: AppModel) }
  ```

- [ ] **Step 1: Write the failing test**

Create `macos/Tests/MacomprendoTests/UI/SpeechTabModelTests.swift`:

```swift
import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct SpeechTabModelTests {
    private let voices = [
        Voice(id: "v.fr", name: "Amélie", language: "fr-FR", quality: "premium"),
        Voice(id: "v.en2", name: "Alex", language: "en-US", quality: "default"),
        Voice(id: "v.en1", name: "Ava", language: "en-US", quality: "enhanced"),
    ]

    @Test func voicesAreGroupedByLanguageAndSortedByName() {
        let groups = SpeechTabModel.group(voices)
        #expect(groups.map(\.language) == ["en-US", "fr-FR"])
        #expect(groups[0].voices.map(\.name) == ["Alex", "Ava"])
        #expect(groups[0].displayName.contains("English"))
        #expect(groups[1].voices.map(\.name) == ["Amélie"])
    }

    @Test func groupingAnEmptyListYieldsNoGroups() {
        #expect(SpeechTabModel.group([]).isEmpty)
    }

    @Test func reloadPublishesTheServiceVoices() {
        let speech = ScriptedSpeech()
        speech.available = voices
        let model = SpeechTabModel(speech: speech, holder: ScriptedSettingsHolder())
        #expect(model.groups.count == 2)

        speech.available = [voices[0]]
        model.reload()
        #expect(model.groups.count == 1)
    }

    @Test func previewSpeaksTheSampleWithTheCurrentSettings() {
        let speech = ScriptedSpeech()
        let holder = ScriptedSettingsHolder()
        holder.settings.speech = SpeechSettings(voiceID: "v.en1", rate: 0.7, pitch: 1.2, volume: 0.8)
        let model = SpeechTabModel(speech: speech, holder: holder)

        model.preview()

        #expect(speech.spoken.count == 1)
        #expect(speech.spoken[0].text == SpeechTabModel.sampleText)
        #expect(speech.spoken[0].settings.voiceID == "v.en1")
        #expect(speech.spoken[0].settings.rate == 0.7)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path macos --filter SpeechTabModelTests`
Expected: build failure — `error: cannot find 'SpeechTabModel' in scope`.

- [ ] **Step 3: Implement the tab**

Create `macos/Sources/Macomprendo/UI/Settings/SpeechTab.swift`:

```swift
import SwiftUI

@MainActor final class SpeechTabModel: ObservableObject {
    struct VoiceGroup: Identifiable, Equatable {
        let language: String        // BCP-47, e.g. "en-US"
        let displayName: String     // "English (United States)"
        let voices: [Voice]
        var id: String { language }
    }

    static let sampleText = "Macomprendo can read your selected text out loud."

    @Published private(set) var groups: [VoiceGroup] = []

    private let speech: any SpeechSynthesizing
    private let holder: any SettingsHolding

    init(speech: any SpeechSynthesizing, holder: any SettingsHolding) {
        self.speech = speech
        self.holder = holder
        reload()
    }

    func reload() {
        groups = Self.group(speech.voices())
    }

    func preview() {
        speech.speak(Self.sampleText, settings: holder.settings.speech)
    }

    static func group(_ voices: [Voice]) -> [VoiceGroup] {
        Dictionary(grouping: voices, by: \.language)
            .map { language, voices in
                VoiceGroup(language: language,
                           displayName: Locale.current.localizedString(forIdentifier: language) ?? language,
                           voices: voices.sorted { ($0.name, $0.id) < ($1.name, $1.id) })
            }
            .sorted { ($0.displayName, $0.language) < ($1.displayName, $1.language) }
    }
}

struct SpeechTab: View {
    @ObservedObject var model: SpeechTabModel
    @ObservedObject var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Voice").font(.headline)
            List(selection: voiceSelection) {
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

            HStack {
                Button("Preview") { model.preview() }
                Button("Reload voices") { model.reload() }
                Spacer()
                Text("Hotkey ⌥S reads the current selection; press it again to stop.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    private var voiceSelection: Binding<String?> {
        Binding(get: { app.settings.speech.voiceID },
                set: { app.settings.speech.voiceID = $0 })
    }
}
```

- [ ] **Step 4: Register the tab**

Following Plan 3's pattern for `modelsViewModel`, add the view model to
`macos/Sources/Macomprendo/App/AppModel.swift` right after `lazy var modelsViewModel`:

```swift
    lazy var speechTabModel = SpeechTabModel(speech: env.speech, holder: self)
```

Then open `macos/Sources/Macomprendo/UI/Settings/SettingsView.swift` and add the tab to the
existing `TabView`, after the Dictation tab (Plan 3's tabs take no arguments and reach the model
through `AppRoot.model`):

```swift
            SpeechTab(model: AppRoot.model.speechTabModel, app: AppRoot.model)
                .tabItem { Label("Speech", systemImage: "speaker.wave.2") }
```

- [ ] **Step 5: Run the test and the build**

Run: `swift test --package-path macos --filter SpeechTabModelTests`
Expected: PASS — 4 tests, 0 failures.

Run: `swift build --package-path macos`
Expected: `Build complete!`

- [ ] **Step 6: Commit**

```bash
git add macos/Sources/Macomprendo/UI/Settings/SpeechTab.swift \
        macos/Sources/Macomprendo/App/AppModel.swift \
        macos/Sources/Macomprendo/UI/Settings/SettingsView.swift \
        macos/Tests/MacomprendoTests/UI/SpeechTabModelTests.swift
git commit -m "feat(settings): add the Speech tab with voice picker and preview"
```

---

### Task 15: Settings ▸ Refine & Summarize tab

**Files:**
- Create: `macos/Sources/Macomprendo/UI/Settings/PromptsTab.swift`
- Modify: `macos/Sources/Macomprendo/App/AppModel.swift`, `macos/Sources/Macomprendo/UI/Settings/SettingsView.swift`
- Test: `macos/Tests/MacomprendoTests/UI/PromptsTabModelTests.swift`

**Interfaces:**
- Consumes: `Settings` preset helpers (Task 1), `FactoryPresets` (Task 2), `PromptRenderer` (Task 3),
  `LLMTarget`/`ErrorText` (Task 6), `SettingsHolding` (Task 6).
- Produces:
  ```swift
  @MainActor final class PromptsTabModel: ObservableObject {
      @Published var kind: PresetKind
      @Published private(set) var selectedID: UUID?
      @Published var draft: PromptPreset?
      @Published private(set) var problems: [String]
      @Published private(set) var testOutput: String
      @Published private(set) var isTesting: Bool
      @Published private(set) var testError: String?
      @Published private(set) var availableModels: [String]
      @Published private(set) var modelsError: String?
      @Published var lastError: String?
      var presets: [PromptPreset] { get }
      var selection: LLMSelection? { get set }
      static let sampleText: String
      init(holder: any SettingsHolding, llm: @escaping @MainActor (PresetKind) throws -> LLMTarget)
      func select(_ id: UUID?)
      func save()
      func add()
      func duplicate()
      func delete()
      func move(from: IndexSet, to: Int)
      func makeDefault()
      func restoreFactory()
      func runTest()
      func stopTest()
      func drainTest() async
      func loadModels() async
  }
  struct PromptsTab: View { init(model: PromptsTabModel, app: AppModel) }
  ```

- [ ] **Step 1: Write the failing test**

Create `macos/Tests/MacomprendoTests/UI/PromptsTabModelTests.swift`:

```swift
import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct PromptsTabModelTests {
    private func make(deltas: [String] = ["tested"], failure: MacomprendoError? = nil)
        -> (PromptsTabModel, ScriptedSettingsHolder, LLMCallRecorder) {
        let holder = ScriptedSettingsHolder.seeded()
        let recorder = LLMCallRecorder()
        let provider = ScriptedLLMProvider(deltas: deltas, failure: failure, recorder: recorder)
        let model = PromptsTabModel(holder: holder,
                                    llm: { _ in LLMTarget(provider: provider, model: "m") })
        return (model, holder, recorder)
    }

    @Test func startsOnRefineWithTheFirstPresetSelected() {
        let (model, _, _) = make()
        #expect(model.kind == .refine)
        #expect(model.presets.count == 7)
        #expect(model.selectedID == FactoryPresets.ID.cleanUp)
        #expect(model.draft?.name == "Clean up")
        #expect(model.problems.isEmpty)
    }

    @Test func switchingKindSelectsThatKindsFirstPreset() {
        let (model, _, _) = make()
        model.kind = .summarize
        #expect(model.presets.count == 4)
        #expect(model.selectedID == FactoryPresets.ID.brief)
    }

    @Test func editingTheDraftAndSavingWritesThrough() {
        let (model, holder, _) = make()
        model.draft?.name = "Tidy up"
        model.save()
        #expect(holder.settings.preset(id: FactoryPresets.ID.cleanUp)?.name == "Tidy up")
    }

    @Test func validationProblemsAreRepublishedOnSave() {
        let (model, _, _) = make()
        model.draft?.userTemplate = "no placeholder here"
        model.save()
        #expect(model.problems.contains("The user template must contain {text}."))
    }

    @Test func addCreatesACustomPresetOfTheCurrentKindAndSelectsIt() {
        let (model, holder, _) = make()
        model.add()
        #expect(holder.settings.presets(of: .refine).count == 8)
        #expect(model.draft?.isFactory == false)
        #expect(model.draft?.id == model.selectedID)
        #expect(model.presets.last?.id == model.selectedID)
    }

    @Test func duplicateCopiesTheSelectionAsANonFactoryPreset() {
        let (model, holder, _) = make()
        model.duplicate()
        #expect(holder.settings.presets(of: .refine).count == 8)
        #expect(model.draft?.name == "Clean up copy")
        #expect(model.draft?.isFactory == false)
        #expect(model.draft?.userTemplate == FactoryPresets.refine()[0].userTemplate)
    }

    @Test func deleteRemovesTheSelectionAndSelectsAnother() {
        let (model, holder, _) = make()
        model.delete()
        #expect(holder.settings.preset(id: FactoryPresets.ID.cleanUp) == nil)
        #expect(model.selectedID == FactoryPresets.ID.formal)
        #expect(model.lastError == nil)
    }

    @Test func deletingTheLastPresetOfAKindPublishesAnError() {
        let (model, holder, _) = make()
        while holder.settings.presets(of: .refine).count > 1 { model.delete() }
        model.delete()
        #expect(holder.settings.presets(of: .refine).count == 1)
        #expect(model.lastError?.contains("At least one") == true)
    }

    @Test func moveReordersWithinTheKind() {
        let (model, _, _) = make()
        model.move(from: IndexSet(integer: 6), to: 0)     // Translate to the top
        #expect(model.presets.first?.id == FactoryPresets.ID.translate)
    }

    @Test func makeDefaultUpdatesSettings() {
        let (model, holder, _) = make()
        model.select(FactoryPresets.ID.formal)
        model.makeDefault()
        #expect(holder.settings.defaultRefinePresetID == FactoryPresets.ID.formal)
    }

    @Test func restoreFactoryReaddsDeletedFactoryPresets() {
        let (model, holder, _) = make()
        model.delete()                                   // removes Clean up
        model.restoreFactory()
        #expect(holder.settings.preset(id: FactoryPresets.ID.cleanUp) != nil)
        #expect(holder.settings.presets(of: .refine).count == 7)
    }

    @Test func testWithSampleTextStreamsIntoTheOutputBox() async {
        let (model, _, recorder) = make(deltas: ["Ti", "dy"])
        model.runTest()
        await model.drainTest()
        #expect(model.testOutput == "Tidy")
        #expect(!model.isTesting)
        #expect(model.testError == nil)
        #expect(recorder.calls.last?.messages.last?.content.contains(PromptsTabModel.sampleText) == true)
    }

    @Test func aFailingTestShowsTheProviderError() async {
        let (model, _, _) = make(deltas: [], failure: .providerUnreachable(endpointName: "Ollama (local)"))
        model.runTest()
        await model.drainTest()
        #expect(model.testError != nil)
        #expect(!model.isTesting)
    }

    @Test func loadModelsPublishesTheProviderList() async {
        let (model, _, _) = make()
        await model.loadModels()
        #expect(model.availableModels == ["scripted-model"])
        #expect(model.modelsError == nil)
    }

    @Test func selectionReadsAndWritesThePerFeatureLLMChoice() {
        let (model, holder, _) = make()
        let endpointID = holder.settings.endpoints[0].id
        model.selection = LLMSelection(endpointID: endpointID, model: "llama3.2")
        #expect(holder.settings.refineLLM == LLMSelection(endpointID: endpointID, model: "llama3.2"))
        model.kind = .summarize
        model.selection = LLMSelection(endpointID: endpointID, model: "qwen2.5:1.5b")
        #expect(holder.settings.summarizeLLM?.model == "qwen2.5:1.5b")
        #expect(holder.settings.refineLLM?.model == "llama3.2")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path macos --filter PromptsTabModelTests`
Expected: build failure — `error: cannot find 'PromptsTabModel' in scope`.

- [ ] **Step 3: Implement the view model**

Create `macos/Sources/Macomprendo/UI/Settings/PromptsTab.swift` with the view model first:

```swift
import SwiftUI

@MainActor final class PromptsTabModel: ObservableObject {
    static let sampleText = """
        so um i think we should probably ship the thing on friday, uh, unless the tests \
        are still red — anyway can you tell marta and also book the room
        """

    @Published var kind: PresetKind = .refine {
        didSet { if kind != oldValue { select(presets.first?.id) } }
    }
    @Published private(set) var selectedID: UUID?
    @Published var draft: PromptPreset?
    @Published private(set) var problems: [String] = []
    @Published private(set) var testOutput: String = ""
    @Published private(set) var isTesting = false
    @Published private(set) var testError: String?
    @Published private(set) var availableModels: [String] = []
    @Published private(set) var modelsError: String?
    @Published var lastError: String?

    private let holder: any SettingsHolding
    private let llm: @MainActor (PresetKind) throws -> LLMTarget
    private var testTask: Task<Void, Never>?

    init(holder: any SettingsHolding,
         llm: @escaping @MainActor (PresetKind) throws -> LLMTarget) {
        self.holder = holder
        self.llm = llm
        select(holder.settings.presets(of: kind).first?.id)
    }

    var presets: [PromptPreset] { holder.settings.presets(of: kind) }

    var defaultPresetID: UUID? { holder.settings.defaultPresetID(for: kind) }

    /// The endpoint + model chosen for the current feature.
    var selection: LLMSelection? {
        get {
            switch kind {
            case .refine: holder.settings.refineLLM
            case .summarize: holder.settings.summarizeLLM
            }
        }
        set {
            switch kind {
            case .refine: holder.settings.refineLLM = newValue
            case .summarize: holder.settings.summarizeLLM = newValue
            }
        }
    }

    // MARK: Selection & editing

    func select(_ id: UUID?) {
        selectedID = id
        draft = id.flatMap { holder.settings.preset(id: $0) }
        problems = draft.map { PromptRenderer.validate($0) } ?? []
        lastError = nil
    }

    func save() {
        guard let draft else { return }
        holder.settings.updatePreset(draft)
        problems = PromptRenderer.validate(draft)
    }

    func add() {
        let new = PromptPreset(id: UUID(), kind: kind, name: "New preset",
                               systemPrompt: FactoryPresets.systemPrompt,
                               userTemplate: "{instruction}\n\n{text}",
                               isFactory: false, sortOrder: 0)
        let stored = holder.settings.addPreset(new)
        select(stored.id)
    }

    func duplicate() {
        guard let source = draft else { return }
        var copy = source
        copy.id = UUID()
        copy.name = source.name + " copy"
        copy.isFactory = false
        let stored = holder.settings.addPreset(copy)
        select(stored.id)
    }

    func delete() {
        guard let id = selectedID else { return }
        do {
            try holder.settings.deletePreset(id: id)
            select(presets.first?.id)
        } catch {
            lastError = ErrorText.describe(error)
        }
    }

    func move(from offsets: IndexSet, to destination: Int) {
        guard let from = offsets.first else { return }
        let ordered = presets
        guard from < ordered.count else { return }
        holder.settings.movePreset(id: ordered[from].id,
                                   to: destination > from ? destination - 1 : destination)
    }

    func makeDefault() {
        guard let id = selectedID else { return }
        holder.settings.setDefaultPreset(id: id, for: kind)
    }

    func restoreFactory() {
        var settings = holder.settings
        FactoryPresets.restoreMissing(into: &settings)
        holder.settings = settings
        select(selectedID ?? presets.first?.id)
    }

    // MARK: Test run

    func runTest() {
        guard let draft else { return }
        testTask?.cancel()
        testOutput = ""
        testError = nil
        isTesting = true
        let prompt = PromptRenderer.render(draft, text: Self.sampleText,
                                           instruction: nil, language: nil)
        let kind = self.kind
        testTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isTesting = false }
            do {
                let target = try self.llm(kind)
                for try await delta in target.provider.chat(prompt.messages, model: target.model,
                                                            options: ChatOptions()) {
                    self.testOutput += delta
                }
            } catch is CancellationError {
            } catch {
                self.testError = ErrorText.describe(error)
            }
        }
    }

    func stopTest() {
        testTask?.cancel()
        isTesting = false
    }

    /// Awaits the in-flight test stream. Used by tests.
    func drainTest() async {
        _ = await testTask?.value
    }

    func loadModels() async {
        do {
            availableModels = try await llm(kind).provider.listModels()
            modelsError = nil
        } catch {
            availableModels = []
            modelsError = ErrorText.describe(error)
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --package-path macos --filter PromptsTabModelTests`
Expected: PASS — 15 tests, 0 failures.

- [ ] **Step 5: Add the view**

Append to `macos/Sources/Macomprendo/UI/Settings/PromptsTab.swift`:

```swift
struct PromptsTab: View {
    @ObservedObject var model: PromptsTabModel
    @ObservedObject var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Feature", selection: $model.kind) {
                ForEach(PresetKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            endpointRow

            HStack(alignment: .top, spacing: 12) {
                presetList
                editor
            }
        }
        .padding(20)
        .task(id: model.kind) { await model.loadModels() }
    }

    private var endpointRow: some View {
        HStack {
            Picker("Endpoint", selection: endpointBinding) {
                ForEach(app.settings.endpoints) { endpoint in
                    Text(endpoint.name).tag(Optional(endpoint.id))
                }
            }
            .frame(width: 240)

            Picker("Model", selection: modelBinding) {
                ForEach(model.availableModels, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .frame(width: 260)

            Button("Reload") { Task { await model.loadModels() } }

            if let error = model.modelsError {
                Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2)
            }
        }
    }

    private var presetList: some View {
        VStack(spacing: 6) {
            List(selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
                ForEach(model.presets) { preset in
                    HStack {
                        Text(preset.name)
                        if preset.id == model.defaultPresetID {
                            Text("DEFAULT").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .tag(preset.id)
                }
                .onMove { model.move(from: $0, to: $1) }
            }
            .frame(width: 220, minHeight: 260)

            HStack {
                Button("＋") { model.add() }.help("Add a preset")
                Button("⧉") { model.duplicate() }.help("Duplicate")
                Button("－") { model.delete() }.help("Delete")
                Spacer()
                Button("Make default") { model.makeDefault() }
            }
            .font(.caption)

            Button("Restore factory presets") { model.restoreFactory() }
                .font(.caption)

            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private var editor: some View {
        if let draft = Binding($model.draft) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Name", text: draft.name)
                    .onSubmit { model.save() }

                Text("System prompt").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: draft.systemPrompt)
                    .frame(height: 70)
                    .border(.separator)

                Text("User template — must contain {text}; may use {instruction} and {language}")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: draft.userTemplate)
                    .frame(height: 110)
                    .border(.separator)

                if model.problems.isEmpty {
                    Text("Template looks good.").font(.caption).foregroundStyle(.green)
                } else {
                    ForEach(model.problems, id: \.self) { problem in
                        Text(problem).font(.caption).foregroundStyle(.red)
                    }
                }

                HStack {
                    Button("Save") { model.save() }
                    if model.isTesting {
                        Button("Stop") { model.stopTest() }
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Test with sample text") { model.save(); model.runTest() }
                    }
                }

                Text(model.testError ?? model.testOutput)
                    .font(.callout)
                    .foregroundStyle(model.testError == nil ? .primary : .red)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
                    .textSelection(.enabled)
                    .padding(6)
                    .background(Color.secondary.opacity(0.08))
            }
        } else {
            Text("Select a preset.").foregroundStyle(.secondary)
        }
    }

    private var endpointBinding: Binding<UUID?> {
        Binding(get: { model.selection?.endpointID },
                set: { id in
                    guard let id else { return }
                    model.selection = LLMSelection(endpointID: id,
                                                   model: model.selection?.model ?? "")
                })
    }

    private var modelBinding: Binding<String> {
        Binding(get: { model.selection?.model ?? "" },
                set: { name in
                    guard let endpointID = model.selection?.endpointID
                            ?? app.settings.endpoints.first?.id else { return }
                    model.selection = LLMSelection(endpointID: endpointID, model: name)
                })
    }
}
```

- [ ] **Step 6: Register the tab**

Add the view model to `macos/Sources/Macomprendo/App/AppModel.swift`, right after
`lazy var speechTabModel` (`llmTarget(for:)` was added to `AppModel` in Task 13):

```swift
    lazy var promptsTabModel = PromptsTabModel(
        holder: self,
        llm: { [unowned self] kind in try self.llmTarget(for: kind) })
```

Then open `macos/Sources/Macomprendo/UI/Settings/SettingsView.swift` and add, after the Speech tab:

```swift
            PromptsTab(model: AppRoot.model.promptsTabModel, app: AppRoot.model)
                .tabItem { Label("Refine & Summarize", systemImage: "text.badge.star") }
```

Note: `Core/Settings` shadows SwiftUI's `Settings` scene, so if you touch the scene declaration in
`MacomprendoApp.swift` write `SwiftUI.Settings { … }`.

- [ ] **Step 7: Run the full suite and build**

Run: `swift test --package-path macos`
Expected: all suites pass, 0 failures.

Run: `swift build --package-path macos`
Expected: `Build complete!`

- [ ] **Step 8: Manual verification**

Launch the app, open Settings ▸ Refine & Summarize and confirm:
1. Both feature segments list their presets; the default is marked.
2. Editing a template to remove `{text}` shows the red validation line immediately after Save.
3. "Test with sample text" streams a cleaned-up version of the sample into the read-only box.
4. Deleting presets down to one and pressing delete again shows "At least one refine preset…".
5. "Restore factory presets" brings the deleted ones back without duplicating custom presets.
6. The preset picker in the Quick Panel shows the same list and order.

- [ ] **Step 9: Commit**

```bash
git add macos/Sources/Macomprendo/UI/Settings/PromptsTab.swift \
        macos/Sources/Macomprendo/App/AppModel.swift \
        macos/Sources/Macomprendo/UI/Settings/SettingsView.swift \
        macos/Tests/MacomprendoTests/UI/PromptsTabModelTests.swift
git commit -m "feat(settings): add the Refine & Summarize preset manager"
```

---

### Task 16: Smoke-test checklist for the text features

**Files:**
- Modify (or create): `docs/SMOKE_TEST.md`

**Interfaces:**
- Consumes: the shipped behaviour of Tasks 4–15. Produces no code.

- [ ] **Step 1: Make sure the file exists**

Run: `ls docs/SMOKE_TEST.md`
If it does not exist (Plan 5 owns its final form), create it with exactly this preamble:

```markdown
# Macomprendo — Manual Smoke Test

Run this checklist on a clean machine state before every release. Hardware- and OS-bound
paths (microphone, Accessibility, CGEvent, NSPanel, speech synthesis) are not unit-tested;
this document is their coverage.

**Setup:** Developer ID build installed in `/Applications`, Microphone and Accessibility
permissions granted, Ollama running with `qwen2.5:1.5b` pulled, TextEdit open with a
paragraph of text.
```

- [ ] **Step 2: Append the text-feature sections**

Append to `docs/SMOKE_TEST.md`:

```markdown
## Refine selection (hotkey #5, unassigned by default)

Assign a shortcut in Settings ▸ Hotkeys first.

- [ ] Select a sentence in TextEdit and press the shortcut. The Quick Panel opens top-center
      of the screen holding the mouse, 680×420, above the frontmost window, and TextEdit stays
      the active app (its title bar keeps colour).
- [ ] "Original" shows exactly the selected text; "Refined" fills in progressively; the
      spinner and Stop button are visible while it streams.
- [ ] Press Stop mid-stream: streaming halts, the partial text stays, no error banner appears.
- [ ] Type "make it one sentence" in the instruction field and press ⌘↩: "Refined" clears and
      re-streams.
- [ ] Change the preset picker to "Formal": it re-runs automatically.
- [ ] Click "Copy" on the Refined side: a "Copied." toast appears and the panel stays open;
      ⌘V in TextEdit pastes the refined text.
- [ ] Click "Insert" on the Refined side: TextEdit comes forward, the selected text is
      replaced by the refined version, and the panel closes.
- [ ] Reopen the panel, drag it to the bottom-left, press Esc, reopen: it appears where it was
      dragged. On a second display it remembers a separate position.
- [ ] Stop Ollama (`pkill ollama`) and trigger the hotkey: a red banner names the endpoint and
      suggests starting Ollama or choosing another endpoint. Restart Ollama afterwards.

## Dictate & Refine (hotkey #2, ⌥⇧Space)

- [ ] With Dictation mode = Hold: hold ⌥⇧Space, say two sentences, release. The recording HUD
      shows a live level meter, then the Quick Panel opens with "Original" holding the
      transcript and "Refined" streaming.
- [ ] With Dictation mode = Toggle: press once to start, press again to stop; same result.
- [ ] Say nothing and release: a "Nothing heard." toast appears and no panel opens.
- [ ] Click Insert on either side: the text lands in the app that was frontmost when the
      hotkey fired (not in the panel), and the panel closes.
- [ ] Deny microphone permission in System Settings, trigger the hotkey: the permission error
      toast appears with a link to the correct System Settings pane. Re-grant afterwards.

## Summarize selection (hotkey #4, ⌥M)

- [ ] Select three paragraphs in Safari and press ⌥M: the Quick Panel opens in the single-pane
      summary layout with the "Brief" preset and streams a summary.
- [ ] Switch the preset to "Bullets": it re-runs and produces a bullet list.
- [ ] Press "Copy": a toast appears, the panel stays open, ⌘V pastes the summary.
- [ ] In TextEdit, select a paragraph, press ⌥M, then "Replace selection": the selected
      paragraph is replaced by the summary and the panel closes.
- [ ] Press ⌥M with nothing selected: a "nothing selected" toast appears, no panel opens.
- [ ] Copy something to the clipboard, then press ⌥M in an app without Accessibility selection
      support (Terminal): the summary is produced via the ⌘C fallback **and** the clipboard
      still holds what you copied before.

## Speak selection (hotkey #3, ⌥S)

- [ ] Select a paragraph and press ⌥S: it is read aloud with the voice chosen in
      Settings ▸ Speech.
- [ ] Press ⌥S again while it is speaking: it stops immediately and does **not** re-read the
      selection or touch the clipboard.
- [ ] Let an utterance finish on its own, then press ⌥S again: it starts speaking again.
- [ ] Press ⌥S with nothing selected: a "nothing selected" toast appears, nothing is spoken.
- [ ] Change rate, pitch and volume in Settings ▸ Speech and press "Preview": the change is
      audible; the next ⌥S uses the new values.

## Settings ▸ Speech

- [ ] Voices are grouped by language with the system language's group listed under its
      localized name; enhanced/premium voices carry a quality badge.
- [ ] Selecting a voice persists across an app restart.

## Settings ▸ Refine & Summarize

- [ ] Each feature segment shows its own endpoint + model picker; "Reload" repopulates the
      model list from the endpoint (and shows an orange message when it is unreachable).
- [ ] Both preset lists show the factory presets in order with the default marked.
- [ ] Add, rename, duplicate, reorder (drag) and delete presets; all changes survive an app
      restart and appear in the Quick Panel's picker in the same order.
- [ ] Remove `{text}` from a template: a red validation line appears; the Quick Panel shows the
      same message in its error banner instead of calling the model.
- [ ] "Test with sample text" streams a result into the read-only box; "Stop" halts it.
- [ ] Delete presets until one remains, then delete again: "At least one refine preset must
      exist." is shown and nothing is deleted.
- [ ] Delete the default preset: the default moves to the first remaining preset.
- [ ] "Restore factory presets" re-adds every deleted factory preset at the end of its list and
      leaves custom presets untouched (no duplicates).
```

- [ ] **Step 3: Commit**

```bash
git add docs/SMOKE_TEST.md
git commit -m "docs: add smoke tests for refine, summarize and speak"
```

---

## Self-review notes

**Spec coverage**

| Spec item | Task |
|---|---|
| §3.2 `SelectedTextReading` / `AXSelectedTextService` with ⌘C fallback | 4 |
| §3.2 `SpeechSynthesizing` / `AVSpeechService` | 5 |
| §3.4 `RefineController` (dictation + selection sources, re-run, copy/insert) | 9, 10 |
| §3.4 `SummarizeController` (copy / replace selection) | 11 |
| §3.4 `SpeakController` (toggle stops) | 7 |
| §3.5 Quick Panel: 680×420 top-center, per-screen frame memory, Esc, key on click, stays open while streaming, two layouts, streaming indicator, stop, error banner | 8, 12 |
| §3.5 Settings ▸ Speech (voices by language, quality badge, sliders, preview) | 14 |
| §3.5 Settings ▸ Refine & Summarize (endpoint+model per feature, preset manager, editor, live validation, test run, default picker, restore) | 15 |
| §3.6 Preset model, factory list, seeding, restore-missing, last-preset guard, default reassignment, `PromptRenderer` | 1, 2, 3 |
| §4 Speak/Summarize/Refine-selection flow (`read()` → toast on empty → controller) | 13 |
| §5 Pasteboard restore, one in-flight task per controller, errors with recovery text | 4, 10, 11 |
| §6 Unit coverage for renderer, factory presets, controllers with fakes | 1–11, 14, 15 |
| Manual coverage for AX/CGEvent/NSPanel/AVSpeech | 13, 15, 16 |

**Deliberate deviations**, all listed in the "Interface additions" table:
`SpeechSynthesizing` is `@MainActor` and has `onStateChange`; `QuickPanelController` gains
`attach(_:)` plus a screen-name/frame overload of `present` so it is testable without `NSScreen`;
controllers take `any Toasting` instead of the concrete `HUDController`; the LLM provider+model
pair travels as `LLMTarget`; `RefineController` gains `handle(_:)` for hold/toggle routing and
`drain()`/`drainCapture()` as async test hooks. Sentence-level speech progress in the HUD is not
implemented because `HUDState` (Plan 3) has no case for it. `DictationController` is not
refactored onto `DictationCapture`; the duplication is intentional so Plan 3's tests are untouched.
