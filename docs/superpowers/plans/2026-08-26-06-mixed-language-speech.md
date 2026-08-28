# Macomprendo Mixed-Language Speech Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make hotkey #3 (Speak selection) intelligible for text that mixes Cyrillic and Latin
script. Two independent improvements: system voices gain per-script voice switching (offline,
free, on by default), and an optional **endpoint speech source** — any OpenAI-compatible
`/v1/audio/speech` server (OpenAI itself, a reseller such as ProxyAPI, or a local
openedai-speech / Kokoro-FastAPI instance) — reads mixed text with one natively code-switching
voice.

**Architecture:** Everything stays behind the existing `@MainActor protocol SpeechSynthesizing`.
`AppEnvironment.live()` injects a new `SpeechRouter` that owns both backends and dispatches per
call on `SpeechSettings.source`; `SpeakController`, `TextFeatures`, the "Speaking…" HUD and every
existing controller test are untouched. The endpoint backend is a `@MainActor` class over the
existing `any HTTPClient` seam plus one new OS seam, `AudioPlaying`. All decision-making logic
(script segmentation, utterance planning, voice fallback, text chunking, request building, error
mapping) lives in pure static functions so it is unit-tested without AVFoundation, without the
network and without audio hardware.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI + AppKit, AVFoundation
(`AVSpeechSynthesizer`, `AVAudioPlayer`), Foundation `JSONEncoder`, swift-testing, and the
OpenAI-compatible speech shape: `POST {base}/v1/audio/speech` with `Authorization: Bearer <key>`
and a JSON body, whose **response body is the audio file itself** — no envelope, no base64.

**Spec:** `docs/superpowers/specs/2026-08-26-mixed-language-speech.md` (amended 2026-08-26: the
cloud source is an OpenAI-compatible endpoint, not Gemini, which is region-blocked for the user).

**Shared interfaces:** `docs/superpowers/plans/2026-08-23-00-file-map-and-interfaces.md` — every
type name used here is taken verbatim from that document (including its Amendments section)
unless listed under "Interface additions beyond the shared map" below.

## Global Constraints

- Swift 6.0, strict concurrency; SwiftUI + AppKit; `platforms: [.macOS(.v14)]`; universal
  (arm64 + x86_64).
- Bundle id `com.dzamataev.macomprendo`; `DEVELOPMENT_TEAM 68QJJA7HK9`; copyright
  "© 2026 Denis Zamataev"; MIT.
- Product/module name `Macomprendo`; `LSUIElement = true`; not sandboxed; hardened runtime.
- No new SPM dependencies. The endpoint backend uses the existing `HTTPClient` seam and
  Foundation JSON encoding only.
- Tests: swift-testing (`import Testing`), run with `swift test --package-path macos`.
- Layering (invariant 1): UI → Features → Services/Providers → Core. Every new file below names
  its layer. Concrete services are constructed **only** in `App/AppEnvironment.swift`.
- Every OS-facing thing sits behind a protocol declared next to its default implementation, with
  a double in `macos/Tests/MacomprendoTests/Fakes/`.
- No telemetry. The speech endpoint is contacted **only** when the user has selected the endpoint
  source (invariant 9). The API key lives only in the Keychain under account `speech.endpoint`
  (invariant 5) and never appears in logs, settings exports or error text.
- Never log selection text, transcript text or TTS input at default level (invariant 6).
- Every user-visible failure is a `MacomprendoError` with both `errorDescription` and
  `recoverySuggestion` (invariant 8); adding a case means adding both strings **and** a row in
  `macos/Tests/MacomprendoTests/Core/MacomprendoErrorTests.swift`.
- One in-flight task per controller/service; a new `speak` cancels the previous one, and
  cancellation is silent (both `CancellationError` and `MacomprendoError.cancelled`).
- Conventional commits, one commit per task, exactly the `git add` list the task gives.

**Hard-learned project rules — these are not optional:**

1. **`npm run gen` in the same commit.** `macos/project.yml` globs source directories, so the
   committed `macos/Macomprendo.xcodeproj` enumerates file references at generate time. **Every
   task that adds or removes a `.swift` file must run `npm run gen` and include
   `macos/Macomprendo.xcodeproj` in that task's `git add` list.** Tasks that only modify existing
   files must not run it. `brew install xcodegen` is a prerequisite (2.46.0 is what the repo was
   generated with).
2. **Verify your working directory before you start.** Run
   `pwd && git -C <repo> status --short && git -C <repo> log --oneline -1`
   and confirm you are in `<repo>`, that the tree is clean apart from
   untracked `.claude/worktrees/`, and that the previous task's commit is HEAD. Do not start on a
   dirty tree.
3. **Incremental builds hide warnings.** `swift build` only re-emits diagnostics for files it
   recompiles, so a warning introduced two tasks ago stays invisible. Every task's warning check
   must force a full recompile first:
   ```bash
   find macos/Sources macos/Tests -name '*.swift' -exec touch {} +
   swift build --package-path macos 2>&1 | grep -c "warning:" || true
   ```
   Expected output: `0`.
4. **Baseline.** Before Task 1 the suite is **464 swift tests in 55 suites** and **38 node
   tests**, all green. This plan adds **72 swift tests**; the final total is **536**.

## Assumed starting point

Plans 1–5 are merged. The following exist and are consumed verbatim: `Settings`,
`SpeechSettings`, `KeychainStoring`/`SystemKeychainStore`/`InMemoryKeychainStore`,
`MacomprendoError`, `ErrorText`, `Log`, `HTTPClient`/`HTTPRequest`/`HTTPResponse`,
`URLSessionHTTPClient`, `EndpointURL`, `Voice`, `SpeechSynthesizing`, `AVSpeechService`,
`SpeakController`, `Toasting`, `HUDController`/`HUDState.speaking(hint:)`, `SettingsHolding`,
`SpeechTabModel`/`SpeechTab`, `AppModel`, `AppEnvironment.live()`, `AppEnvironment.fake()`,
`ScriptedSpeech`, `ScriptedToaster`, `ScriptedSettingsHolder`, `FakeHTTPClient`.

## Interface additions beyond the shared map

| Name | File | Layer | Why |
|---|---|---|---|
| `ScriptClass`, `TextRun`, `LanguageSegmenter` | `Services/LanguageSegmenter.swift` | Services | pure script segmentation (spec Part A) |
| `UtterancePlan` | `Services/SpeechService.swift` | Services | testable `(text, voiceID)` pairs so segmentation is unit-tested without AVFoundation |
| `AVSpeechService.qualityRank/languageRank/fallbackVoice(for:in:)/utterancePlan(text:settings:voices:minRunLength:)` | `Services/SpeechService.swift` | Services | pure helpers behind the queueing change |
| `SpeechSynthesizing.onError` | `Services/SpeechService.swift` | Services | backends that can fail need a channel to `SpeakController` |
| `SpeechSynthesizing.voices(for:)` + protocol-extension default | `Services/SpeechService.swift` | Services | the Speech tab lists the voices of the source being configured, not the active one |
| `SpeechSource` + six `SpeechSettings` fields + `SpeechSettings.defaultEndpointBaseURL/defaultEndpointModel/defaultEndpointVoice/endpointKeychainAccount` | `Core/Settings.swift` | Core | spec "Settings schema" |
| `MacomprendoError.audioPlayback(String)`, `.speechKeyMissing` | `Core/MacomprendoError.swift` | Core | playback and missing-key failures (invariant 8) |
| `SpeechTextChunker` | `Services/SpeechTextChunker.swift` | Services | the ≤4096-character split, pure and in its own file so it ships and is reviewed one task before the service |
| `SpeechRequestBuilder` | `Providers/SpeechRequestBuilder.swift` | Providers | the one file an API-shape change touches: URL, headers, body, error naming |
| `AudioPlaying`, `AVAudioPlayerPlayer` | `Services/AudioPlayer.swift` | Services | new OS seam (spec Part B step 4) |
| `EndpointVoices`, `EndpointSpeechService` | `Services/EndpointSpeechService.swift` | Services | the endpoint backend + its built-in voice suggestions |
| `SpeechRouter` | `Services/SpeechRouter.swift` | Services | per-call dispatch on `SpeechSettings.source` |
| `FakeAudioPlayer` | `Tests/…/Fakes/FakeAudioPlayer.swift` | Tests | `AudioPlaying` double |
| `ScriptedSpeech.onError/failWith(_:)/availableBySource` | `Tests/…/Fakes/ScriptedSpeech.swift` | Tests | drives the new protocol members |
| `SpeechTabModel.init(speech:holder:keychain:)`, `.source`, `.endpointVoices`, `.apiKeyField`, `.keyStatus`, `.saveAPIKey()`, `.hasAPIKey()`, `.endpointPrivacyCaption` | `UI/Settings/SpeechTab.swift` | UI | spec "UI — Settings ▸ Speech" |

**Deliberate deviations from the spec, all resolved here and reflected in the tasks:**

- The spec's Part A says classification uses "explicit Cyrillic/Latin block ranges" because the
  standard library exposes no `script` property. Confirmed: `Unicode.Scalar.Properties` has no
  `script` member (`error: value of type 'Unicode.Scalar.Properties' has no member 'script'`).
  Task 1 uses `Unicode.Scalar.properties.isAlphabetic` plus block ranges.
- The spec says a short run "merges into its neighbor" without saying which. Task 1 merges into
  the **longer** neighbour and gives the merged run the longer side's script, so
  `"Привет, world!"` reads Russian rather than English.
- The spec's missing-key copy is one sentence. It is split into `errorDescription`
  ("No speech API key.") and `recoverySuggestion` ("Add one in Settings ▸ Speech.") so
  `ErrorText.describe` reproduces the spec sentence verbatim.
- The spec's UI section says the stored key is never read back into the field. `hasAPIKey()`
  reads `endpointAPIKeyRef` from `Settings` — the secret itself only ever moves *into* the
  Keychain.
- `EndpointSpeechService.chunkCharacterLimit` is injectable (defaulted). Production never passes
  it; it exists so tests can force a multi-chunk queue out of a two-word string instead of
  building a 4096-character fixture.
- `SpeechRequestBuilder` uses the existing `EndpointURL.openAI(_:_:)` helper rather than string
  concatenation, so a reseller base such as `https://api.proxyapi.ru/openai` and a local server
  already ending in `/v1` both resolve correctly (verified in Task 6).

---

### Task 1: `LanguageSegmenter`

**Files:**
- Create: `macos/Sources/Macomprendo/Services/LanguageSegmenter.swift` (Services layer)
- Test: `macos/Tests/MacomprendoTests/Services/LanguageSegmenterTests.swift`

**Interfaces:**
- Consumes: nothing (pure Foundation).
- Produces:
  ```swift
  enum ScriptClass: Equatable, Sendable { case cyrillic, latin, neutral }
  struct TextRun: Equatable, Sendable { var text: String; var script: ScriptClass }
  enum LanguageSegmenter {
      static let defaultMinRunLength: Int                     // 20
      static let cyrillicLanguageCodes: Set<String>
      static let otherScriptLanguageCodes: Set<String>
      static func script(of scalar: Unicode.Scalar) -> ScriptClass
      static func script(of character: Character) -> ScriptClass
      static func script(ofLanguage language: String) -> ScriptClass
      static func runs(in text: String, minRunLength: Int = defaultMinRunLength) -> [TextRun]
  }
  ```

- [ ] **Step 1: Verify the working directory**

```bash
pwd
git -C <repo> status --short
git -C <repo> log --oneline -1
```
Expected: you are in `<repo>`; `status` prints nothing except possibly
`?? .claude/worktrees/`.

- [ ] **Step 2: Write the failing test**

Create `macos/Tests/MacomprendoTests/Services/LanguageSegmenterTests.swift`:

```swift
import Foundation
import Testing
@testable import Macomprendo

@Suite struct LanguageSegmenterTests {
    // 52 Cyrillic characters including the trailing ". ", then 41 Latin ones.
    private let mixed = "Это довольно длинное русское предложение для теста. "
        + "Now a long English sentence follows here."

    @Test func emptyTextHasNoRuns() {
        #expect(LanguageSegmenter.runs(in: "", minRunLength: 1).isEmpty)
    }

    @Test func singleScriptTextIsOneRun() {
        let runs = LanguageSegmenter.runs(in: "Hello there, friend.", minRunLength: 1)
        #expect(runs == [TextRun(text: "Hello there, friend.", script: .latin)])
    }

    @Test func neutralCharactersAttachToThePrecedingRun() {
        let runs = LanguageSegmenter.runs(in: "Привет, world!", minRunLength: 1)
        #expect(runs == [TextRun(text: "Привет, ", script: .cyrillic),
                         TextRun(text: "world!", script: .latin)])
    }

    @Test func leadingNeutralCharactersAttachToTheFollowingRun() {
        let runs = LanguageSegmenter.runs(in: "  — Привет", minRunLength: 1)
        #expect(runs == [TextRun(text: "  — Привет", script: .cyrillic)])
    }

    @Test func textWithoutLettersIsOneNeutralRun() {
        let runs = LanguageSegmenter.runs(in: "123 456 …", minRunLength: 1)
        #expect(runs == [TextRun(text: "123 456 …", script: .neutral)])
    }

    @Test func unknownScriptsAreNeutralAndNeverFlipTheVoice() {
        #expect(LanguageSegmenter.script(of: "世" as Character) == .neutral)
        #expect(LanguageSegmenter.script(of: "ع" as Character) == .neutral)
        let runs = LanguageSegmenter.runs(in: "Hello 世界 there", minRunLength: 1)
        #expect(runs == [TextRun(text: "Hello 世界 there", script: .latin)])
    }

    @Test func aShortForeignWordMergesIntoItsNeighbour() {
        let runs = LanguageSegmenter.runs(in: "Я купил новый iPhone вчера в магазине рядом с домом.")
        #expect(runs.count == 1)
        #expect(runs[0].script == .cyrillic)
        #expect(runs[0].text == "Я купил новый iPhone вчера в магазине рядом с домом.")
    }

    @Test func bothScriptsSurviveWhenEachRunIsLongEnough() {
        let runs = LanguageSegmenter.runs(in: mixed)
        #expect(runs.map(\.script) == [.cyrillic, .latin])
        #expect(runs[0].text == "Это довольно длинное русское предложение для теста. ")
        #expect(runs[1].text == "Now a long English sentence follows here.")
    }

    @Test func aShortRunTakesTheLongerNeighboursScript() {
        // "Привет, " is 8 characters, "world!" is 6: both are under the default minimum,
        // so they collapse into one run and the longer side (Cyrillic) wins the voice.
        let runs = LanguageSegmenter.runs(in: "Привет, world!")
        #expect(runs == [TextRun(text: "Привет, world!", script: .cyrillic)])
    }

    @Test func languageTagsAreClassifiedByTheirBaseCode() {
        #expect(LanguageSegmenter.script(ofLanguage: "ru-RU") == .cyrillic)
        #expect(LanguageSegmenter.script(ofLanguage: "uk-UA") == .cyrillic)
        #expect(LanguageSegmenter.script(ofLanguage: "en-US") == .latin)
        #expect(LanguageSegmenter.script(ofLanguage: "fr-CA") == .latin)
        #expect(LanguageSegmenter.script(ofLanguage: "zh-CN") == .neutral)
        #expect(LanguageSegmenter.script(ofLanguage: "") == .latin)
    }

    @Test func scalarClassificationSeparatesLettersFromEverythingElse() {
        #expect(LanguageSegmenter.script(of: "п" as Unicode.Scalar) == .cyrillic)
        #expect(LanguageSegmenter.script(of: "Z" as Unicode.Scalar) == .latin)
        #expect(LanguageSegmenter.script(of: "é" as Unicode.Scalar) == .latin)
        #expect(LanguageSegmenter.script(of: "7" as Unicode.Scalar) == .neutral)
        #expect(LanguageSegmenter.script(of: "×" as Unicode.Scalar) == .neutral)
        #expect(LanguageSegmenter.script(of: " " as Unicode.Scalar) == .neutral)
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --package-path macos --filter LanguageSegmenterTests`
Expected: build failure — `error: cannot find 'LanguageSegmenter' in scope` and
`error: cannot find 'TextRun' in scope`.

- [ ] **Step 4: Implement the segmenter**

Create `macos/Sources/Macomprendo/Services/LanguageSegmenter.swift`:

```swift
import Foundation

enum ScriptClass: Equatable, Sendable { case cyrillic, latin, neutral }

struct TextRun: Equatable, Sendable {
    var text: String
    var script: ScriptClass
}

/// Splits text into maximal runs of one script so a mixed Cyrillic/Latin selection can be
/// read by two different voices. Pure: no state, no I/O.
///
/// - Note: The Swift standard library exposes no `Unicode.Scalar.Properties.script`, so
///   classification is `isAlphabetic` plus explicit Unicode block ranges. Anything that is
///   not a Cyrillic or Latin letter — digits, punctuation, whitespace, Han, Arabic, emoji —
///   is `.neutral`, attaches to a neighbouring run and is therefore read by that run's voice.
///   Scripts outside Cyrillic/Latin never crash and never flip the voice on their own.
enum LanguageSegmenter {
    /// A non-neutral run shorter than this merges into a neighbour, so a single foreign word
    /// ("iPhone" inside a Russian sentence) does not flip the voice for one word.
    static let defaultMinRunLength = 20

    /// Base language codes written in Cyrillic.
    static let cyrillicLanguageCodes: Set<String> = [
        "ab", "ba", "be", "bg", "ce", "cv", "kk", "ky", "mk", "mn",
        "os", "ru", "sr", "tg", "tt", "uk"
    ]

    /// Base language codes written in neither Cyrillic nor Latin. Voices for these languages
    /// are never picked as a fallback for a Latin run.
    static let otherScriptLanguageCodes: Set<String> = [
        "am", "ar", "bn", "el", "fa", "gu", "he", "hi", "hy", "iw", "ja", "ka", "km", "kn",
        "ko", "lo", "ml", "mr", "my", "ne", "pa", "si", "ta", "te", "th", "ur", "yi", "zh"
    ]

    private static let cyrillicRanges: [ClosedRange<UInt32>] = [
        0x0400...0x04FF,   // Cyrillic
        0x0500...0x052F,   // Cyrillic Supplement
        0x1C80...0x1C8F,   // Cyrillic Extended-C
        0x2DE0...0x2DFF,   // Cyrillic Extended-A
        0xA640...0xA69F    // Cyrillic Extended-B
    ]

    private static let latinRanges: [ClosedRange<UInt32>] = [
        0x0041...0x005A,   // A–Z
        0x0061...0x007A,   // a–z
        0x00C0...0x024F,   // Latin-1 Supplement letters, Latin Extended-A/B
        0x1E00...0x1EFF,   // Latin Extended Additional
        0x2C60...0x2C7F    // Latin Extended-C
    ]

    static func script(of scalar: Unicode.Scalar) -> ScriptClass {
        guard scalar.properties.isAlphabetic else { return .neutral }
        let value = scalar.value
        if cyrillicRanges.contains(where: { $0.contains(value) }) { return .cyrillic }
        if latinRanges.contains(where: { $0.contains(value) }) { return .latin }
        return .neutral
    }

    /// A grapheme counts as Cyrillic/Latin when any of its scalars does, so a base letter
    /// plus combining marks ("й" spelled и + U+0306) stays with its letter.
    static func script(of character: Character) -> ScriptClass {
        for scalar in character.unicodeScalars {
            let scriptClass = script(of: scalar)
            if scriptClass != .neutral { return scriptClass }
        }
        return .neutral
    }

    /// The script a BCP-47 tag is written in, by base code. Unknown codes are assumed Latin.
    static func script(ofLanguage language: String) -> ScriptClass {
        let base = language.split(separator: "-").first.map { $0.lowercased() } ?? ""
        if cyrillicLanguageCodes.contains(base) { return .cyrillic }
        if otherScriptLanguageCodes.contains(base) { return .neutral }
        return .latin
    }

    /// Maximal runs of one script. Neutral characters attach to the preceding run, or to the
    /// following one at the start of the text. A run shorter than `minRunLength` merges into
    /// its longer neighbour and the longer side's script wins.
    static func runs(in text: String, minRunLength: Int = defaultMinRunLength) -> [TextRun] {
        guard !text.isEmpty else { return [] }

        var runs: [TextRun] = []
        for character in text {
            let scriptClass = script(of: character)
            guard var last = runs.last else {
                runs.append(TextRun(text: String(character), script: scriptClass))
                continue
            }
            if scriptClass == .neutral || last.script == scriptClass {
                last.text.append(character)                  // neutral joins the current run
                runs[runs.count - 1] = last
            } else if last.script == .neutral {
                last.text.append(character)                  // leading neutrals adopt this script
                last.script = scriptClass
                runs[runs.count - 1] = last
            } else {
                runs.append(TextRun(text: String(character), script: scriptClass))
            }
        }

        // Each iteration removes one run, so this terminates at a single run at the latest.
        while runs.count > 1, let short = shortestIndex(below: minRunLength, in: runs) {
            let left = short - 1
            let right = short + 1
            let mergeLeft: Bool
            if left < 0 {
                mergeLeft = false
            } else if right >= runs.count {
                mergeLeft = true
            } else {
                mergeLeft = runs[left].text.count >= runs[right].text.count
            }
            let first = mergeLeft ? left : short
            let second = mergeLeft ? short : right
            runs[first] = combine(runs[first], runs[second])
            runs.remove(at: second)
        }

        var coalesced: [TextRun] = []
        for run in runs {
            if coalesced.last?.script == run.script {
                coalesced[coalesced.count - 1].text += run.text
            } else {
                coalesced.append(run)
            }
        }
        return coalesced
    }

    private static func shortestIndex(below minRunLength: Int, in runs: [TextRun]) -> Int? {
        var best: Int?
        for index in runs.indices where runs[index].text.count < minRunLength {
            if let current = best, runs[index].text.count >= runs[current].text.count { continue }
            best = index
        }
        return best
    }

    private static func combine(_ first: TextRun, _ second: TextRun) -> TextRun {
        TextRun(text: first.text + second.text,
                script: first.text.count >= second.text.count ? first.script : second.script)
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --package-path macos --filter LanguageSegmenterTests`
Expected: PASS — 11 tests, 0 failures.

- [ ] **Step 6: Regenerate the Xcode project and check for warnings**

```bash
npm run gen
find macos/Sources macos/Tests -name '*.swift' -exec touch {} +
swift build --package-path macos 2>&1 | grep -c "warning:" || true
```
Expected: xcodegen prints `Created project at .../macos/Macomprendo.xcodeproj`, then `0`.

- [ ] **Step 7: Commit**

```bash
git add macos/Sources/Macomprendo/Services/LanguageSegmenter.swift \
        macos/Tests/MacomprendoTests/Services/LanguageSegmenterTests.swift \
        macos/Macomprendo.xcodeproj
git commit -m "feat(speech): add a pure Cyrillic/Latin script segmenter"
```

---

### Task 2: Per-script voice switching in `AVSpeechService`

**Files:**
- Modify: `macos/Sources/Macomprendo/Services/SpeechService.swift` (Services layer)
- Test: `macos/Tests/MacomprendoTests/Services/SpeechSegmentationTests.swift`

**Interfaces:**
- Consumes: `ScriptClass`, `TextRun`, `LanguageSegmenter` (Task 1), `Voice`, `SpeechSettings`.
- Produces:
  ```swift
  struct UtterancePlan: Equatable, Sendable { var text: String; var voiceID: String? }

  extension AVSpeechService {
      nonisolated static func qualityRank(_ quality: String) -> Int
      nonisolated static func languageRank(_ language: String, preferred: String) -> Int
      nonisolated static func fallbackVoice(for script: ScriptClass, in voices: [Voice]) -> Voice?
      nonisolated static func utterancePlan(text: String,
                                            settings: SpeechSettings,
                                            voices: [Voice],
                                            minRunLength: Int = LanguageSegmenter.defaultMinRunLength)
          -> [UtterancePlan]
  }
  ```

> The queueing itself (`AVSpeechSynthesizer.speak` called once per plan entry, `didFinish`
> bookkeeping) is thin AVFoundation glue and is covered by `docs/SMOKE_TEST.md` (Task 11) per
> invariant 3. Everything that *decides* what to queue is pure and is unit-tested here.

- [ ] **Step 1: Verify the working directory**

```bash
pwd
git -C <repo> status --short
git -C <repo> log --oneline -1
```
Expected: clean tree in `<repo>`; HEAD is
`feat(speech): add a pure Cyrillic/Latin script segmenter`.

- [ ] **Step 2: Write the failing test**

Create `macos/Tests/MacomprendoTests/Services/SpeechSegmentationTests.swift`:

```swift
import Foundation
import Testing
@testable import Macomprendo

@Suite struct SpeechSegmentationTests {
    private let voices = [
        Voice(id: "en.alex", name: "Alex", language: "en-US", quality: "default"),
        Voice(id: "en.ava.premium", name: "Ava", language: "en-US", quality: "premium"),
        Voice(id: "en.daniel", name: "Daniel", language: "en-GB", quality: "enhanced"),
        Voice(id: "ru.milena", name: "Milena", language: "ru-RU", quality: "default"),
        Voice(id: "ru.milena.enhanced", name: "Milena", language: "ru-RU", quality: "enhanced"),
        Voice(id: "uk.lesya", name: "Lesya", language: "uk-UA", quality: "premium"),
        Voice(id: "zh.tingting", name: "Tingting", language: "zh-CN", quality: "premium")
    ]

    private let cyrillicPart = "Это довольно длинное русское предложение для теста. "
    private let latinPart = "Now a long English sentence follows here."

    private func settings(_ voiceID: String?) -> SpeechSettings {
        SpeechSettings(voiceID: voiceID, rate: 0.5, pitch: 1, volume: 1)
    }

    // MARK: fallbackVoice

    @Test func cyrillicFallbackPrefersRussianThenQuality() {
        #expect(AVSpeechService.fallbackVoice(for: .cyrillic, in: voices)?.id == "ru.milena.enhanced")
    }

    @Test func latinFallbackPrefersEnglishThenQuality() {
        #expect(AVSpeechService.fallbackVoice(for: .latin, in: voices)?.id == "en.ava.premium")
    }

    @Test func neutralRunsHaveNoFallbackVoice() {
        #expect(AVSpeechService.fallbackVoice(for: .neutral, in: voices) == nil)
    }

    @Test func anEmptyVoiceListHasNoFallbackVoice() {
        #expect(AVSpeechService.fallbackVoice(for: .latin, in: []) == nil)
        #expect(AVSpeechService.fallbackVoice(for: .cyrillic, in: []) == nil)
    }

    @Test func voicesInOtherScriptsAreNeverAFallback() {
        let onlyChinese = [Voice(id: "zh.tingting", name: "Tingting", language: "zh-CN", quality: "premium")]
        #expect(AVSpeechService.fallbackVoice(for: .latin, in: onlyChinese) == nil)
        // A Ukrainian voice is a valid Cyrillic fallback when no Russian one is installed.
        let onlyUkrainian = [Voice(id: "uk.lesya", name: "Lesya", language: "uk-UA", quality: "premium")]
        #expect(AVSpeechService.fallbackVoice(for: .cyrillic, in: onlyUkrainian)?.id == "uk.lesya")
    }

    // MARK: utterancePlan

    @Test func singleScriptTextStaysOneUtterance() {
        let plan = AVSpeechService.utterancePlan(text: latinPart,
                                                 settings: settings("en.alex"),
                                                 voices: voices)
        #expect(plan == [UtterancePlan(text: latinPart, voiceID: "en.alex")])
    }

    @Test func mixedScriptTextSwitchesVoicePerRun() {
        let plan = AVSpeechService.utterancePlan(text: cyrillicPart + latinPart,
                                                 settings: settings("en.alex"),
                                                 voices: voices)
        #expect(plan == [UtterancePlan(text: cyrillicPart, voiceID: "ru.milena.enhanced"),
                         UtterancePlan(text: latinPart, voiceID: "en.alex")])
    }

    @Test func aMissingFallbackVoiceKeepsTheConfiguredVoice() {
        let englishOnly = voices.filter { $0.language.hasPrefix("en") }
        let plan = AVSpeechService.utterancePlan(text: cyrillicPart + latinPart,
                                                 settings: settings("en.alex"),
                                                 voices: englishOnly)
        #expect(plan.map(\.voiceID) == ["en.alex", "en.alex"])
        #expect(plan.map(\.text) == [cyrillicPart, latinPart])
    }

    @Test func textIsSplitEvenWhenNoVoiceIsConfigured() {
        // No configured voice means the configured script is assumed Latin.
        let plan = AVSpeechService.utterancePlan(text: cyrillicPart + latinPart,
                                                 settings: settings(nil),
                                                 voices: voices)
        #expect(plan == [UtterancePlan(text: cyrillicPart, voiceID: "ru.milena.enhanced"),
                         UtterancePlan(text: latinPart, voiceID: nil)])
    }

    @Test func aSingleForeignWordDoesNotSplitTheUtterance() {
        let text = "Я купил новый iPhone вчера в магазине рядом с домом."
        let plan = AVSpeechService.utterancePlan(text: text,
                                                 settings: settings("ru.milena"),
                                                 voices: voices)
        #expect(plan == [UtterancePlan(text: text, voiceID: "ru.milena")])
    }

    @Test func neutralOnlyTextStaysOneUtterance() {
        let plan = AVSpeechService.utterancePlan(text: "123 456 …",
                                                 settings: settings("en.alex"),
                                                 voices: voices)
        #expect(plan == [UtterancePlan(text: "123 456 …", voiceID: "en.alex")])
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --package-path macos --filter SpeechSegmentationTests`
Expected: build failure — `error: type 'AVSpeechService' has no member 'fallbackVoice'` and
`error: cannot find 'UtterancePlan' in scope`.

- [ ] **Step 4: Replace `SpeechService.swift`**

Overwrite `macos/Sources/Macomprendo/Services/SpeechService.swift` with:

```swift
import AVFoundation
import Foundation

struct Voice: Identifiable, Sendable, Equatable {
    let id: String          // AVSpeechSynthesisVoice.identifier
    let name: String
    let language: String    // BCP-47, e.g. "en-US"
    let quality: String     // "default" | "enhanced" | "premium"
}

/// One queued utterance: a stretch of text plus the voice that should read it.
/// Computing the plan is pure, so segmentation is unit-tested without AVFoundation.
struct UtterancePlan: Equatable, Sendable {
    var text: String
    var voiceID: String?
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

    /// The utterances handed to the synthesizer for the current `speak(_:settings:)` call.
    /// `didFinish`/`didCancel` callbacks for anything not in this list belong to a superseded
    /// call and are ignored, so a stop-then-speak race cannot clear the new speaking state.
    private var queued: [AVSpeechUtterance] = []

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // `nonisolated`: pure functions touching no actor-isolated state, so the tests (and any
    // other caller) can invoke them synchronously without hopping to the main actor.
    nonisolated static func qualityLabel(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .enhanced: "enhanced"
        case .premium: "premium"
        default: "default"
        }
    }

    nonisolated static func clampedRate(_ rate: Float) -> Float {
        min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
    }

    nonisolated static func clampedPitch(_ pitch: Float) -> Float { min(max(pitch, 0.5), 2.0) }

    nonisolated static func clampedVolume(_ volume: Float) -> Float { min(max(volume, 0), 1) }

    nonisolated static func qualityRank(_ quality: String) -> Int {
        switch quality {
        case "premium": 2
        case "enhanced": 1
        default: 0
        }
    }

    /// 2 = exactly the preferred tag, 1 = the same base code, 0 = anything else.
    nonisolated static func languageRank(_ language: String, preferred: String) -> Int {
        if language.caseInsensitiveCompare(preferred) == .orderedSame { return 2 }
        func base(_ tag: String) -> String { tag.split(separator: "-").first.map { $0.lowercased() } ?? "" }
        return base(language) == base(preferred) ? 1 : 0
    }

    /// The best installed voice for a script: `ru-RU` for Cyrillic and `en-US` for Latin
    /// first, then any other voice in the same script, preferring premium > enhanced >
    /// default. Ties break on name then identifier so the choice is stable.
    nonisolated static func fallbackVoice(for script: ScriptClass, in voices: [Voice]) -> Voice? {
        guard script != .neutral else { return nil }
        let preferred = script == .cyrillic ? "ru-RU" : "en-US"
        return voices
            .filter { LanguageSegmenter.script(ofLanguage: $0.language) == script }
            .sorted { lhs, rhs in
                let lhsKey = (languageRank(lhs.language, preferred: preferred), qualityRank(lhs.quality))
                let rhsKey = (languageRank(rhs.language, preferred: preferred), qualityRank(rhs.quality))
                if lhsKey != rhsKey { return lhsKey > rhsKey }
                return (lhs.name, lhs.id) < (rhs.name, rhs.id)
            }
            .first
    }

    /// What to enqueue for `text`. When every run matches the configured voice's script the
    /// result is a single utterance holding the original text — byte for byte what the
    /// service did before segmentation existed.
    nonisolated static func utterancePlan(
        text: String,
        settings: SpeechSettings,
        voices: [Voice],
        minRunLength: Int = LanguageSegmenter.defaultMinRunLength
    ) -> [UtterancePlan] {
        guard !text.isEmpty else { return [] }
        let configured = voices.first { $0.id == settings.voiceID }
        let configuredScript = configured.map { LanguageSegmenter.script(ofLanguage: $0.language) } ?? .latin
        let runs = LanguageSegmenter.runs(in: text, minRunLength: minRunLength)
        let needsSwitching = runs.contains { $0.script != .neutral && $0.script != configuredScript }
        guard runs.count > 1, needsSwitching else {
            return [UtterancePlan(text: text, voiceID: settings.voiceID)]
        }
        return runs.map { run in
            guard run.script != .neutral, run.script != configuredScript else {
                return UtterancePlan(text: run.text, voiceID: settings.voiceID)
            }
            return UtterancePlan(text: run.text,
                                 voiceID: fallbackVoice(for: run.script, in: voices)?.id ?? settings.voiceID)
        }
    }

    func voices() -> [Voice] {
        AVSpeechSynthesisVoice.speechVoices().map { voice in
            Voice(id: voice.identifier, name: voice.name, language: voice.language,
                  quality: Self.qualityLabel(voice.quality))
        }
    }

    func speak(_ text: String, settings: SpeechSettings) {
        queued.removeAll()
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let plan = Self.utterancePlan(text: text, settings: settings, voices: voices())
        guard !plan.isEmpty else {
            setSpeaking(false)
            return
        }
        // AVSpeechSynthesizer plays a queue natively, so one `speak` per run is enough.
        queued = plan.map { item in
            let utterance = AVSpeechUtterance(string: item.text)
            if let id = item.voiceID, let voice = AVSpeechSynthesisVoice(identifier: id) {
                utterance.voice = voice
            }
            utterance.rate = Self.clampedRate(settings.rate)
            utterance.pitchMultiplier = Self.clampedPitch(settings.pitch)
            utterance.volume = Self.clampedVolume(settings.volume)
            return utterance
        }
        setSpeaking(true)
        for utterance in queued { synthesizer.speak(utterance) }
    }

    func stop() {
        queued.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
        setSpeaking(false)
    }

    fileprivate func setSpeaking(_ value: Bool) {
        guard isSpeaking != value else { return }
        isSpeaking = value
        onStateChange?()
    }

    /// `isSpeaking` drops only once the *last* queued utterance is done.
    fileprivate func finished(_ token: ObjectIdentifier) {
        guard let index = queued.firstIndex(where: { ObjectIdentifier($0) == token }) else { return }
        queued.remove(at: index)
        if queued.isEmpty { setSpeaking(false) }
    }
}

extension AVSpeechService: AVSpeechSynthesizerDelegate {
    // `AVSpeechUtterance` is not `Sendable`, so the identity token crosses the hop instead
    // of the object itself.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        let token = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.finished(token) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        let token = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.finished(token) }
    }
}
```

- [ ] **Step 5: Run the new and the existing speech tests**

Run: `swift test --package-path macos --filter SpeechSegmentationTests`
Expected: PASS — 11 tests, 0 failures.

Run: `swift test --package-path macos --filter "SpeechServiceTests|SpeakControllerTests"`
Expected: PASS — 12 tests, 0 failures (4 + 8, both suites unchanged by this task).

- [ ] **Step 6: Regenerate the Xcode project and check for warnings**

```bash
npm run gen
find macos/Sources macos/Tests -name '*.swift' -exec touch {} +
swift build --package-path macos 2>&1 | grep -c "warning:" || true
```
Expected: `0`.

- [ ] **Step 7: Commit**

```bash
git add macos/Sources/Macomprendo/Services/SpeechService.swift \
        macos/Tests/MacomprendoTests/Services/SpeechSegmentationTests.swift \
        macos/Macomprendo.xcodeproj
git commit -m "feat(speech): switch system voices per script inside one selection"
```

---

### Task 3: `SpeechSynthesizing.onError` and the `SpeakController` toast

**Files:**
- Modify: `macos/Sources/Macomprendo/Services/SpeechService.swift` (Services layer)
- Modify: `macos/Sources/Macomprendo/Features/SpeakController.swift` (Features layer)
- Modify: `macos/Tests/MacomprendoTests/Fakes/ScriptedSpeech.swift`
- Modify: `macos/Tests/MacomprendoTests/Services/SpeechServiceTests.swift`
- Modify: `macos/Tests/MacomprendoTests/Features/SpeakControllerTests.swift`

**Interfaces:**
- Consumes: `ErrorText`, `Toasting`, `MacomprendoError`.
- Produces: `SpeechSynthesizing.onError: (@MainActor (Error) -> Void)? { get set }`;
  `AVSpeechService.onError` (stored, never called); `ScriptedSpeech.onError` +
  `ScriptedSpeech.failWith(_:)`.

> Ordering contract, relied on by every backend: a failing backend calls `onStateChange` **first**
> (so the "Speaking…" HUD is hidden) and `onError` **second** (so the toast survives the hide).

- [ ] **Step 1: Verify the working directory**

```bash
pwd
git -C <repo> status --short
git -C <repo> log --oneline -1
```
Expected: clean tree; HEAD is
`feat(speech): switch system voices per script inside one selection`.

- [ ] **Step 2: Write the failing tests**

Append to `macos/Tests/MacomprendoTests/Services/SpeechServiceTests.swift`, inside the
`SpeechServiceTests` suite (before its closing `}`):

```swift
    @MainActor
    @Test func theDoubleReportsBackendFailuresAfterClearingTheSpeakingState() {
        let speech = ScriptedSpeech()
        var speakingWhenErrorArrived: Bool?
        speech.onError = { _ in speakingWhenErrorArrived = speech.isSpeaking }

        speech.speak("hello", settings: SpeechSettings())
        #expect(speech.isSpeaking)
        speech.failWith(MacomprendoError.providerHTTP(status: 401, body: "unauthorized"))

        #expect(!speech.isSpeaking)
        #expect(speakingWhenErrorArrived == false)
    }
```

Append to `macos/Tests/MacomprendoTests/Features/SpeakControllerTests.swift`, inside the
`SpeakControllerTests` suite (before its closing `}`):

```swift
    @Test func aBackendErrorHidesTheHUDAndThenToasts() async {
        let (controller, speech, toaster) = make()
        await controller.toggle(text: { "read me" })
        #expect(toaster.states.count == 1)

        speech.failWith(MacomprendoError.providerHTTP(status: 401, body: "bad key"))

        #expect(!controller.isSpeaking)
        #expect(toaster.hideCount == 1)
        #expect(toaster.messages.count == 1)
        #expect(toaster.messages[0].contains("401"))
    }

    @Test func theBackendErrorToastCarriesTheRecoverySuggestion() async {
        let (controller, speech, toaster) = make()
        await controller.toggle(text: { "read me" })
        speech.failWith(MacomprendoError.providerUnreachable(endpointName: "api.openai.com"))

        let expected = ErrorText.describe(
            MacomprendoError.providerUnreachable(endpointName: "api.openai.com"))
        #expect(toaster.messages == [expected])
        #expect(expected.contains("api.openai.com"))
        #expect(!controller.isSpeaking)
    }
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --package-path macos --filter "SpeechServiceTests|SpeakControllerTests"`
Expected: build failure — `error: value of type 'ScriptedSpeech' has no member 'onError'` and
`error: value of type 'ScriptedSpeech' has no member 'failWith'`.

- [ ] **Step 4: Add `onError` to the protocol and to `AVSpeechService`**

In `macos/Sources/Macomprendo/Services/SpeechService.swift`, add the member to the protocol:

```swift
@MainActor protocol SpeechSynthesizing: AnyObject {
    var isSpeaking: Bool { get }
    /// Called whenever `isSpeaking` changes, including when an utterance finishes by itself.
    var onStateChange: (@MainActor () -> Void)? { get set }
    /// Called after `onStateChange` when a backend fails while speaking. Backends never call
    /// it for cancellation. `AVSpeechService` never calls it at all: AVFoundation reports no
    /// errors for local synthesis.
    var onError: (@MainActor (Error) -> Void)? { get set }
    func voices() -> [Voice]
    func speak(_ text: String, settings: SpeechSettings)
    func stop()
}
```

and the stored property to `AVSpeechService`, directly under `var onStateChange`:

```swift
    /// Required by `SpeechSynthesizing`; local synthesis has no failure channel, so this is
    /// stored and never invoked.
    var onError: (@MainActor (Error) -> Void)?
```

- [ ] **Step 5: Wire `SpeakController`**

In `macos/Sources/Macomprendo/Features/SpeakController.swift`, append to `init` right after the
existing `speech.onStateChange = { … }` block:

```swift
        // Surfaced exactly like the controller's own text-read failures. `onStateChange` has
        // already hidden the "Speaking…" HUD by the time this runs, so the toast survives.
        speech.onError = { [weak self] error in
            self?.toaster.toast(ErrorText.describe(error), duration: 2.5)
        }
```

- [ ] **Step 6: Extend `ScriptedSpeech`**

Overwrite `macos/Tests/MacomprendoTests/Fakes/ScriptedSpeech.swift`:

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
    var onError: (@MainActor (Error) -> Void)?
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

    /// Simulates a backend failure. Mirrors the ordering contract every real backend keeps:
    /// state change first (hides the HUD), error second (shows the toast).
    func failWith(_ error: Error) {
        isSpeaking = false
        onStateChange?()
        onError?(error)
    }
}
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `swift test --package-path macos --filter "SpeechServiceTests|SpeakControllerTests"`
Expected: PASS — 15 tests, 0 failures (5 + 10).

- [ ] **Step 8: Check for warnings**

```bash
find macos/Sources macos/Tests -name '*.swift' -exec touch {} +
swift build --package-path macos 2>&1 | grep -c "warning:" || true
```
Expected: `0`. (No `npm run gen`: this task adds no files.)

- [ ] **Step 9: Commit**

```bash
git add macos/Sources/Macomprendo/Services/SpeechService.swift \
        macos/Sources/Macomprendo/Features/SpeakController.swift \
        macos/Tests/MacomprendoTests/Fakes/ScriptedSpeech.swift \
        macos/Tests/MacomprendoTests/Services/SpeechServiceTests.swift \
        macos/Tests/MacomprendoTests/Features/SpeakControllerTests.swift
git commit -m "feat(speech): surface backend failures through SpeakController toasts"
```

---

### Task 4: `SpeechSource` and the endpoint settings fields

**Files:**
- Modify: `macos/Sources/Macomprendo/Core/Settings.swift` (Core layer)
- Modify: `macos/Tests/MacomprendoTests/Core/SettingsTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  ```swift
  enum SpeechSource: String, Codable, Sendable, CaseIterable, Identifiable {
      case system, endpoint
      var id: String { rawValue }
      var displayName: String
  }

  extension SpeechSettings {
      var source: SpeechSource               // default .system
      var endpointBaseURL: URL               // default https://api.openai.com
      var endpointModel: String              // default "gpt-4o-mini-tts"
      var endpointVoice: String              // default "alloy"
      var endpointInstructions: String       // default ""
      var endpointAPIKeyRef: String?         // default nil
      static let defaultEndpointBaseURL: URL
      static let defaultEndpointModel: String
      static let defaultEndpointVoice: String
      static let endpointKeychainAccount: String     // "speech.endpoint"
  }
  ```

- [ ] **Step 1: Verify the working directory**

```bash
pwd
git -C <repo> status --short
git -C <repo> log --oneline -1
```
Expected: clean tree; HEAD is
`feat(speech): surface backend failures through SpeakController toasts`.

- [ ] **Step 2: Write the failing test**

`macos/Tests/MacomprendoTests/Core/SettingsTests.swift` holds free `@Test` functions, not a
`@Suite` type. Append these four at the **end of the file**, at file scope (no indentation):

```swift
@Test func speechSettingsDefaultToTheSystemSource() {
    let speech = Settings.default.speech
    #expect(speech.source == .system)
    #expect(speech.endpointBaseURL.absoluteString == "https://api.openai.com")
    #expect(speech.endpointModel == "gpt-4o-mini-tts")
    #expect(speech.endpointVoice == "alloy")
    #expect(speech.endpointInstructions.isEmpty)
    #expect(speech.endpointAPIKeyRef == nil)
}

@Test func aSpeechPayloadWithoutTheEndpointFieldsDecodesToDefaults() throws {
    let legacy = """
        {"schemaVersion":1,
         "speech":{"voiceID":"com.apple.voice.compact.en-US.Samantha",
                   "rate":0.42,"pitch":1.3,"volume":0.7}}
        """
    let settings = try Settings.migrate(Data(legacy.utf8))
    #expect(settings.speech.voiceID == "com.apple.voice.compact.en-US.Samantha")
    #expect(settings.speech.rate == 0.42)
    #expect(settings.speech.source == .system)
    #expect(settings.speech.endpointBaseURL == SpeechSettings.defaultEndpointBaseURL)
    #expect(settings.speech.endpointModel == SpeechSettings.defaultEndpointModel)
    #expect(settings.speech.endpointVoice == SpeechSettings.defaultEndpointVoice)
    #expect(settings.speech.endpointAPIKeyRef == nil)
}

@Test func endpointSpeechFieldsRoundTripThroughJSON() throws {
    var settings = Settings.default
    settings.speech.source = .endpoint
    settings.speech.endpointBaseURL = URL(string: "https://api.proxyapi.ru/openai")!
    settings.speech.endpointModel = "tts-1-hd"
    settings.speech.endpointVoice = "sage"
    settings.speech.endpointInstructions = "Read slowly and warmly"
    settings.speech.endpointAPIKeyRef = SpeechSettings.endpointKeychainAccount

    let encoded = try JSONEncoder().encode(settings)
    let decoded = try Settings.migrate(encoded)

    #expect(decoded.speech == settings.speech)
    // Only the Keychain account name is persisted, never the key (invariant 5).
    #expect(String(decoding: encoded, as: UTF8.self)
            .contains("\"endpointAPIKeyRef\":\"speech.endpoint\""))
}

@Test func theEndpointKeychainAccountIsStable() {
    #expect(SpeechSettings.endpointKeychainAccount == "speech.endpoint")
    #expect(SpeechSource.allCases.map(\.rawValue) == ["system", "endpoint"])
    #expect(SpeechSource.system.displayName == "System voices")
    #expect(SpeechSource.endpoint.displayName == "Endpoint")
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --package-path macos --filter speechSettingsDefaultToTheSystemSource`
Expected: build failure — `error: value of type 'SpeechSettings' has no member 'source'` and
`error: cannot find 'SpeechSource' in scope`.

- [ ] **Step 4: Extend `SpeechSettings`**

In `macos/Sources/Macomprendo/Core/Settings.swift`, replace the whole `SpeechSettings` struct
with:

```swift
/// Which backend reads text aloud.
enum SpeechSource: String, Codable, Sendable, CaseIterable, Identifiable {
    case system
    case endpoint

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "System voices"
        case .endpoint: "Endpoint"
        }
    }
}

struct SpeechSettings: Codable, Sendable, Equatable {
    /// Any OpenAI-compatible `/v1/audio/speech` server: OpenAI itself, a reseller such as
    /// `https://api.proxyapi.ru/openai`, or a local server on `http://localhost:8000`.
    static let defaultEndpointBaseURL = URL(string: "https://api.openai.com")!
    static let defaultEndpointModel = "gpt-4o-mini-tts"
    static let defaultEndpointVoice = "alloy"
    /// Keychain account name for the speech endpoint's key. The key itself never leaves the
    /// Keychain (invariant 5); `endpointAPIKeyRef` only records that one is stored.
    static let endpointKeychainAccount = "speech.endpoint"

    var voiceID: String?
    var rate: Float
    var pitch: Float
    var volume: Float
    var source: SpeechSource
    var endpointBaseURL: URL
    var endpointModel: String
    var endpointVoice: String
    var endpointInstructions: String
    var endpointAPIKeyRef: String?

    init(voiceID: String? = nil,
         rate: Float = 0.5,
         pitch: Float = 1.0,
         volume: Float = 1.0,
         source: SpeechSource = .system,
         endpointBaseURL: URL = SpeechSettings.defaultEndpointBaseURL,
         endpointModel: String = SpeechSettings.defaultEndpointModel,
         endpointVoice: String = SpeechSettings.defaultEndpointVoice,
         endpointInstructions: String = "",
         endpointAPIKeyRef: String? = nil) {
        self.voiceID = voiceID
        self.rate = rate
        self.pitch = pitch
        self.volume = volume
        self.source = source
        self.endpointBaseURL = endpointBaseURL
        self.endpointModel = endpointModel
        self.endpointVoice = endpointVoice
        self.endpointInstructions = endpointInstructions
        self.endpointAPIKeyRef = endpointAPIKeyRef
    }
}

extension SpeechSettings {
    /// Hand-written so a document written before the endpoint source existed decodes to the
    /// defaults for the new keys instead of throwing. Declared in an extension so the struct
    /// keeps its memberwise initialiser — the same pattern `Settings` uses.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SpeechSettings()
        voiceID = try c.decodeIfPresent(String.self, forKey: .voiceID)
        rate = try c.decodeIfPresent(Float.self, forKey: .rate) ?? d.rate
        pitch = try c.decodeIfPresent(Float.self, forKey: .pitch) ?? d.pitch
        volume = try c.decodeIfPresent(Float.self, forKey: .volume) ?? d.volume
        source = try c.decodeIfPresent(SpeechSource.self, forKey: .source) ?? d.source
        endpointBaseURL = try c.decodeIfPresent(URL.self, forKey: .endpointBaseURL) ?? d.endpointBaseURL
        endpointModel = try c.decodeIfPresent(String.self, forKey: .endpointModel) ?? d.endpointModel
        endpointVoice = try c.decodeIfPresent(String.self, forKey: .endpointVoice) ?? d.endpointVoice
        endpointInstructions = try c.decodeIfPresent(String.self, forKey: .endpointInstructions)
            ?? d.endpointInstructions
        endpointAPIKeyRef = try c.decodeIfPresent(String.self, forKey: .endpointAPIKeyRef)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path macos --filter speechSettingsDefaultToTheSystemSource`
Expected: PASS — 1 test, 0 failures.

Run: `swift test --package-path macos`
Expected: `Test run with 493 tests … passed`.

- [ ] **Step 6: Check for warnings**

```bash
find macos/Sources macos/Tests -name '*.swift' -exec touch {} +
swift build --package-path macos 2>&1 | grep -c "warning:" || true
```
Expected: `0`. (No `npm run gen`: this task adds no files.)

- [ ] **Step 7: Commit**

```bash
git add macos/Sources/Macomprendo/Core/Settings.swift \
        macos/Tests/MacomprendoTests/Core/SettingsTests.swift
git commit -m "feat(settings): add the endpoint speech source fields to SpeechSettings"
```

---

### Task 5: `SpeechTextChunker`

**Files:**
- Create: `macos/Sources/Macomprendo/Services/SpeechTextChunker.swift` (Services layer)
- Test: `macos/Tests/MacomprendoTests/Services/SpeechTextChunkerTests.swift`

**Interfaces:**
- Consumes: nothing (pure Foundation).
- Produces:
  ```swift
  enum SpeechTextChunker {
      static let defaultCharacterLimit: Int                  // 4096
      static let sentenceTerminators: Set<Character>
      static let closingCharacters: Set<Character>
      static func chunks(of text: String, limit: Int = defaultCharacterLimit) -> [String]
      static func sentences(in text: String) -> [String]
      static func splitOversized(_ sentence: String, limit: Int) -> [String]
      static func splitWord(_ word: String, limit: Int) -> [String]
  }
  ```

> The limit is counted in **characters**, not UTF-8 bytes: OpenAI's `/v1/audio/speech` documents
> a 4096-character input cap. Cyrillic therefore costs the same as Latin here, which is the
> opposite of the transcription upload path — the tests pin that down explicitly.

- [ ] **Step 1: Verify the working directory**

```bash
pwd
git -C <repo> status --short
git -C <repo> log --oneline -1
```
Expected: clean tree; HEAD is
`feat(settings): add the endpoint speech source fields to SpeechSettings`.

- [ ] **Step 2: Write the failing test**

Create `macos/Tests/MacomprendoTests/Services/SpeechTextChunkerTests.swift`:

```swift
import Foundation
import Testing
@testable import Macomprendo

@Suite struct SpeechTextChunkerTests {
    @Test func shortTextIsOneChunk() {
        #expect(SpeechTextChunker.chunks(of: "One. Two. Three.", limit: 100) == ["One. Two. Three."])
    }

    @Test func blankTextProducesNoChunks() {
        #expect(SpeechTextChunker.chunks(of: "", limit: 100).isEmpty)
        #expect(SpeechTextChunker.chunks(of: "   \n\t ", limit: 100).isEmpty)
    }

    @Test func sentencesAreGroupedUpToTheLimit() {
        // "One." + " " + "Two." is exactly 9 characters; adding "Three." would not fit.
        #expect(SpeechTextChunker.chunks(of: "One. Two. Three.", limit: 9) == ["One. Two.", "Three."])
    }

    @Test func charactersAreCountedNotUTF8Bytes() {
        let text = "Привет мир. Как дела?"
        #expect("Привет мир.".count == 11)
        #expect("Привет мир.".utf8.count == 20)      // a byte budget would behave differently
        #expect("Как дела?".count == 9)

        // 11 + 1 + 9 = 21 characters: fits at 21, splits at 20.
        #expect(SpeechTextChunker.chunks(of: text, limit: 21) == ["Привет мир. Как дела?"])
        #expect(SpeechTextChunker.chunks(of: text, limit: 20) == ["Привет мир.", "Как дела?"])
        // A limit of 11 still holds the whole first sentence, which is 20 bytes.
        #expect(SpeechTextChunker.chunks(of: "Привет мир.", limit: 11) == ["Привет мир."])
    }

    @Test func aSentenceLongerThanTheLimitIsSplitAtWordBoundaries() {
        #expect(SpeechTextChunker.chunks(of: "alpha beta gamma delta", limit: 12)
                == ["alpha beta", "gamma delta"])
    }

    @Test func aWordLongerThanTheLimitIsSplitAtCharacterBoundaries() {
        #expect(SpeechTextChunker.chunks(of: "aaaaaaaaaaaa", limit: 5) == ["aaaaa", "aaaaa", "aa"])
        #expect("ПриветПриветПривет".count == 18)
        #expect(SpeechTextChunker.chunks(of: "ПриветПриветПривет", limit: 5)
                == ["Приве", "тПрив", "етПри", "вет"])
    }

    @Test func noChunkEverExceedsTheLimit() {
        let text = String(repeating: "Мама мыла раму очень тщательно. ", count: 40)
        for limit in [16, 64, 200] {
            let chunks = SpeechTextChunker.chunks(of: text, limit: limit)
            #expect(!chunks.isEmpty)
            #expect(chunks.allSatisfy { $0.count <= limit }, "limit \(limit)")
        }
    }

    @Test func sentenceSplittingKeepsClosingQuotesAndBreaksOnNewlines() {
        #expect(SpeechTextChunker.sentences(in: "He said \"Stop!\" Then left.\nNew line here")
                == ["He said \"Stop!\"", "Then left.", "New line here"])
    }

    @Test func abbreviationsAreRejoinedWhenTheyFitTheLimit() {
        // "Dr." looks like a sentence end, but the pieces are regrouped into one chunk.
        #expect(SpeechTextChunker.chunks(of: "Dr. Smith went home.", limit: 100)
                == ["Dr. Smith went home."])
    }

    @Test func aZeroLimitProducesNoChunks() {
        #expect(SpeechTextChunker.chunks(of: "anything", limit: 0).isEmpty)
        #expect(SpeechTextChunker.defaultCharacterLimit == 4096)
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --package-path macos --filter SpeechTextChunkerTests`
Expected: build failure — `error: cannot find 'SpeechTextChunker' in scope`.

- [ ] **Step 4: Implement the chunker**

Create `macos/Sources/Macomprendo/Services/SpeechTextChunker.swift`:

```swift
import Foundation

/// Splits text into request-sized pieces for an OpenAI-compatible `/v1/audio/speech` endpoint.
/// Pure: no state, no I/O.
///
/// Sentences are the preferred boundary, so a chunk seam lands where a speaker would pause.
/// Sentences are regrouped greedily up to the limit, which means an abbreviation that looks
/// like a sentence end ("Dr.") only affects *where* a seam could fall, never the text.
///
/// The limit is counted in **characters**: OpenAI documents a 4096-character input cap for
/// this endpoint, so Cyrillic costs the same as Latin here.
enum SpeechTextChunker {
    /// The documented `/v1/audio/speech` input cap.
    static let defaultCharacterLimit = 4096

    static let sentenceTerminators: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
    static let closingCharacters: Set<Character> = ["\"", "'", ")", "]", "»", "”", "’"]

    static func chunks(of text: String, limit: Int = defaultCharacterLimit) -> [String] {
        guard limit > 0 else { return [] }
        var chunks: [String] = []
        var current = ""

        for sentence in sentences(in: text) {
            for piece in splitOversized(sentence, limit: limit) {
                if current.isEmpty {
                    current = piece
                } else if current.count + 1 + piece.count <= limit {
                    current += " " + piece
                } else {
                    chunks.append(current)
                    current = piece
                }
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Sentences, trimmed, keeping any closing quote or bracket that follows the terminator.
    /// A terminator only ends a sentence when whitespace or the end of the text follows it,
    /// and every newline ends one too.
    static func sentences(in text: String) -> [String] {
        let characters = Array(text)
        var sentences: [String] = []
        var start = 0
        var index = 0

        func emit(upTo end: Int) {
            let piece = String(characters[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { sentences.append(piece) }
            start = end
        }

        while index < characters.count {
            let character = characters[index]
            if sentenceTerminators.contains(character) {
                var end = index + 1
                while end < characters.count, closingCharacters.contains(characters[end]) { end += 1 }
                if end >= characters.count || characters[end].isWhitespace {
                    emit(upTo: end)
                    index = end
                    continue
                }
            }
            if character.isNewline { emit(upTo: index + 1) }
            index += 1
        }
        emit(upTo: characters.count)
        return sentences
    }

    /// A sentence over the limit is regrouped at word boundaries.
    static func splitOversized(_ sentence: String, limit: Int) -> [String] {
        guard sentence.count > limit else { return [sentence] }
        var pieces: [String] = []
        var current = ""
        for word in sentence.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
            for fragment in splitWord(word, limit: limit) {
                if current.isEmpty {
                    current = fragment
                } else if current.count + 1 + fragment.count <= limit {
                    current += " " + fragment
                } else {
                    pieces.append(current)
                    current = fragment
                }
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    /// A single word over the limit is cut at grapheme boundaries, so every fragment stays
    /// valid text.
    static func splitWord(_ word: String, limit: Int) -> [String] {
        guard word.count > limit else { return [word] }
        var pieces: [String] = []
        var current = ""
        for character in word {
            if current.count == limit {
                pieces.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --package-path macos --filter SpeechTextChunkerTests`
Expected: PASS — 10 tests, 0 failures.

- [ ] **Step 6: Regenerate the Xcode project and check for warnings**

```bash
npm run gen
find macos/Sources macos/Tests -name '*.swift' -exec touch {} +
swift build --package-path macos 2>&1 | grep -c "warning:" || true
```
Expected: `0`.

- [ ] **Step 7: Commit**

```bash
git add macos/Sources/Macomprendo/Services/SpeechTextChunker.swift \
        macos/Tests/MacomprendoTests/Services/SpeechTextChunkerTests.swift \
        macos/Macomprendo.xcodeproj
git commit -m "feat(speech): add sentence-aware chunking for the speech endpoint"
```

---

### Task 6: `SpeechRequestBuilder`

**Files:**
- Create: `macos/Sources/Macomprendo/Providers/SpeechRequestBuilder.swift` (Providers layer)
- Test: `macos/Tests/MacomprendoTests/Providers/SpeechRequestBuilderTests.swift`

**Interfaces:**
- Consumes: `HTTPRequest`, `EndpointURL`, `MacomprendoError`.
- Produces:
  ```swift
  enum SpeechRequestBuilder {
      static let path: String                  // "/audio/speech" (under EndpointURL's /v1)
      static let responseFormat: String        // "wav"
      static func endpointName(for baseURL: URL) -> String
      static func requestBody(model: String, voice: String, input: String,
                              instructions: String) throws -> Data
      static func request(baseURL: URL, apiKey: String, model: String, voice: String,
                          input: String, instructions: String,
                          timeout: TimeInterval) throws -> HTTPRequest
      static func audio(from response: HTTPResponse) throws -> Data
      static func mapped(_ error: MacomprendoError, baseURL: URL) -> MacomprendoError
  }
  ```

**API shape — the OpenAI-compatible speech endpoint.** This is the whole contract; there is no
envelope to parse:

```
POST {base}/v1/audio/speech
Authorization: Bearer <key>
Content-Type: application/json

{"input":"…","instructions":"…","model":"gpt-4o-mini-tts","response_format":"wav","voice":"alloy"}
```

The **response body is the audio file itself** — no JSON, no base64. `instructions` is omitted
entirely when the user left the Style field empty (older models reject an unknown field less
often than an empty one, and omitting it keeps the body identical to a plain `tts-1` request).
`AVAudioPlayer` sniffs the container in Task 7, so a server that ignores `response_format` and
returns MP3 still plays (spec open item 1).

URL building goes through the existing `EndpointURL.openAI(_:_:)`, which appends `/v1` only when
the base does not already end in it. Verified outputs:

| `endpointBaseURL` | request URL | `endpointName` |
|---|---|---|
| `https://api.openai.com` | `https://api.openai.com/v1/audio/speech` | `api.openai.com` |
| `https://api.openai.com/` | `https://api.openai.com/v1/audio/speech` | `api.openai.com` |
| `https://api.proxyapi.ru/openai` | `https://api.proxyapi.ru/openai/v1/audio/speech` | `api.proxyapi.ru` |
| `http://localhost:8000/v1` | `http://localhost:8000/v1/audio/speech` | `localhost` |

- [ ] **Step 1: Verify the working directory**

```bash
pwd
git -C <repo> status --short
git -C <repo> log --oneline -1
```
Expected: clean tree; HEAD is
`feat(speech): add sentence-aware chunking for the speech endpoint`.

- [ ] **Step 2: Write the failing test**

Create `macos/Tests/MacomprendoTests/Providers/SpeechRequestBuilderTests.swift`:

```swift
import Foundation
import Testing
@testable import Macomprendo

@Suite struct SpeechRequestBuilderTests {
    private let base = URL(string: "https://api.openai.com")!

    @Test func theRequestTargetsTheAudioSpeechEndpointWithABearerToken() throws {
        let request = try SpeechRequestBuilder.request(baseURL: base,
                                                       apiKey: "sk-SECRET",
                                                       model: "gpt-4o-mini-tts",
                                                       voice: "alloy",
                                                       input: "Hello",
                                                       instructions: "",
                                                       timeout: 60)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://api.openai.com/v1/audio/speech")
        #expect(request.headers["Authorization"] == "Bearer sk-SECRET")
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.timeout == 60)
        // The key travels in the header only, never in the body.
        #expect(!String(decoding: request.body ?? Data(), as: UTF8.self).contains("sk-SECRET"))
    }

    @Test func resellerAndLocalBaseURLsResolveCorrectly() throws {
        func url(_ string: String) throws -> String {
            try SpeechRequestBuilder.request(baseURL: URL(string: string)!,
                                             apiKey: "k", model: "m", voice: "v",
                                             input: "i", instructions: "", timeout: 10)
                .url.absoluteString
        }
        #expect(try url("https://api.openai.com/") == "https://api.openai.com/v1/audio/speech")
        #expect(try url("https://api.proxyapi.ru/openai")
                == "https://api.proxyapi.ru/openai/v1/audio/speech")
        #expect(try url("http://localhost:8000/v1") == "http://localhost:8000/v1/audio/speech")
    }

    @Test func theBodyCarriesModelVoiceInputAndFormatAndOmitsEmptyInstructions() throws {
        let body = try SpeechRequestBuilder.requestBody(model: "gpt-4o-mini-tts",
                                                        voice: "alloy",
                                                        input: "Hello",
                                                        instructions: "   ")
        #expect(String(decoding: body, as: UTF8.self) == """
            {"input":"Hello","model":"gpt-4o-mini-tts","response_format":"wav","voice":"alloy"}
            """)
    }

    @Test func instructionsAreSentWhenSetAndNonASCIIStaysRawUTF8() throws {
        let body = try SpeechRequestBuilder.requestBody(model: "gpt-4o-mini-tts",
                                                        voice: "alloy",
                                                        input: "Привет!",
                                                        instructions: "Speak slowly")
        let text = String(decoding: body, as: UTF8.self)
        #expect(text == """
            {"input":"Привет!","instructions":"Speak slowly","model":"gpt-4o-mini-tts",\
            "response_format":"wav","voice":"alloy"}
            """)
        #expect(!text.contains("\\u"))
    }

    @Test func theEndpointNameIsTheConfiguredHostAndTransportErrorsAreRenamed() {
        #expect(SpeechRequestBuilder.endpointName(for: base) == "api.openai.com")
        #expect(SpeechRequestBuilder.endpointName(for: URL(string: "http://localhost:8000")!)
                == "localhost")

        let renamed = SpeechRequestBuilder.mapped(
            .providerUnreachable(endpointName: "whatever"),
            baseURL: URL(string: "https://api.proxyapi.ru/openai")!)
        #expect(renamed == .providerUnreachable(endpointName: "api.proxyapi.ru"))

        // Anything else passes through untouched, including the silent cancellation case.
        #expect(SpeechRequestBuilder.mapped(.providerHTTP(status: 401, body: "bad key"), baseURL: base)
                == .providerHTTP(status: 401, body: "bad key"))
        #expect(SpeechRequestBuilder.mapped(.cancelled, baseURL: base) == .cancelled)
    }

    @Test func anEmptyResponseBodyIsMalformed() throws {
        let audio = try SpeechRequestBuilder.audio(
            from: HTTPResponse(status: 200, headers: [:], body: Data([0x52, 0x49, 0x46, 0x46])))
        #expect(audio == Data([0x52, 0x49, 0x46, 0x46]))

        #expect(throws: MacomprendoError.providerStreamMalformed) {
            _ = try SpeechRequestBuilder.audio(from: HTTPResponse(status: 200, headers: [:], body: Data()))
        }
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --package-path macos --filter SpeechRequestBuilderTests`
Expected: build failure — `error: cannot find 'SpeechRequestBuilder' in scope`.

- [ ] **Step 4: Implement the builder**

Create `macos/Sources/Macomprendo/Providers/SpeechRequestBuilder.swift`:

```swift
import Foundation

/// Builds the request for an OpenAI-compatible `POST /v1/audio/speech` endpoint and names its
/// failures. The whole API shape lives here, so a change to it touches exactly one file.
///
///     POST {base}/v1/audio/speech
///     Authorization: Bearer <key>
///     {"input": …, "instructions": …, "model": …, "response_format": "wav", "voice": …}
///
/// The response body **is** the audio file — no envelope, no base64. `AVAudioPlayer` sniffs the
/// container, so a server that ignores `response_format` and returns MP3 still plays.
enum SpeechRequestBuilder {
    /// Appended under `EndpointURL.openAI`'s `/v1` prefix.
    static let path = "/audio/speech"
    static let responseFormat = "wav"

    /// What the user sees in `providerUnreachable`: the host they configured, not a raw URL.
    static func endpointName(for baseURL: URL) -> String {
        baseURL.host() ?? baseURL.absoluteString
    }

    private struct Body: Encodable {
        let model: String
        let voice: String
        let input: String
        let responseFormat: String
        /// Omitted from the JSON entirely when nil, so a server that does not know the field
        /// sees exactly the body a plain `tts-1` request would send.
        let instructions: String?

        enum CodingKeys: String, CodingKey {
            case model, voice, input, instructions
            case responseFormat = "response_format"
        }
    }

    /// Deterministic key order so the body is assertable byte for byte in tests.
    static func requestBody(model: String,
                            voice: String,
                            input: String,
                            instructions: String) throws -> Data {
        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Body(model: model,
                                       voice: voice,
                                       input: input,
                                       responseFormat: responseFormat,
                                       instructions: trimmed.isEmpty ? nil : trimmed))
    }

    /// The key goes in the `Authorization` header and nowhere else (invariant 5).
    static func request(baseURL: URL,
                        apiKey: String,
                        model: String,
                        voice: String,
                        input: String,
                        instructions: String,
                        timeout: TimeInterval) throws -> HTTPRequest {
        HTTPRequest(method: "POST",
                    url: EndpointURL.openAI(baseURL, path),
                    headers: ["Content-Type": "application/json",
                              "Authorization": "Bearer \(apiKey)"],
                    body: try requestBody(model: model,
                                          voice: voice,
                                          input: input,
                                          instructions: instructions),
                    timeout: timeout)
    }

    /// A 2xx with no bytes is a server that accepted the request and produced nothing; that is
    /// a malformed response, not silence to play.
    static func audio(from response: HTTPResponse) throws -> Data {
        guard !response.body.isEmpty else { throw MacomprendoError.providerStreamMalformed }
        return response.body
    }

    /// `HTTPClient` names the host it could not reach from the URL it was handed; re-derive it
    /// from the configured base so the message matches what the user typed in Settings.
    static func mapped(_ error: MacomprendoError, baseURL: URL) -> MacomprendoError {
        if case .providerUnreachable = error {
            return .providerUnreachable(endpointName: endpointName(for: baseURL))
        }
        return error
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --package-path macos --filter SpeechRequestBuilderTests`
Expected: PASS — 6 tests, 0 failures.

- [ ] **Step 6: Regenerate the Xcode project and check for warnings**

```bash
npm run gen
find macos/Sources macos/Tests -name '*.swift' -exec touch {} +
swift build --package-path macos 2>&1 | grep -c "warning:" || true
```
Expected: `0`.

- [ ] **Step 7: Commit**

```bash
git add macos/Sources/Macomprendo/Providers/SpeechRequestBuilder.swift \
        macos/Tests/MacomprendoTests/Providers/SpeechRequestBuilderTests.swift \
        macos/Macomprendo.xcodeproj
git commit -m "feat(speech): add the OpenAI-compatible speech request builder"
```

---

### Task 7: `AudioPlaying`, `AVAudioPlayerPlayer` and the two new error cases

**Files:**
- Create: `macos/Sources/Macomprendo/Services/AudioPlayer.swift` (Services layer)
- Modify: `macos/Sources/Macomprendo/Core/MacomprendoError.swift` (Core layer)
- Create: `macos/Tests/MacomprendoTests/Fakes/FakeAudioPlayer.swift`
- Modify: `macos/Tests/MacomprendoTests/Core/MacomprendoErrorTests.swift`

**Interfaces:**
- Consumes: `MacomprendoError`.
- Produces:
  ```swift
  @MainActor protocol AudioPlaying: AnyObject {
      var onFinished: (@MainActor () -> Void)? { get set }
      func play(_ audioData: Data) throws
      func stop()
  }
  @MainActor final class AVAudioPlayerPlayer: NSObject, AudioPlaying

  extension MacomprendoError {
      case audioPlayback(String)
      case speechKeyMissing
  }
  ```

> `AVAudioPlayerPlayer` is hardware-bound AVFoundation glue and gets **no unit test** — invariant
> 3. It is exercised by `docs/SMOKE_TEST.md` (Task 11); the seam itself is exercised by Task 8's
> tests through `FakeAudioPlayer`. Everything testable in this task is the Core error copy.

- [ ] **Step 1: Verify the working directory**

```bash
pwd
git -C <repo> status --short
git -C <repo> log --oneline -1
```
Expected: clean tree; HEAD is
`feat(speech): add the OpenAI-compatible speech request builder`.

- [ ] **Step 2: Write the failing test**

In `macos/Tests/MacomprendoTests/Core/MacomprendoErrorTests.swift`, add the two new cases to the
parameterised argument list so it reads:

```swift
@Test(arguments: [
    MacomprendoError.permissionDenied(.microphone),
    .permissionDenied(.accessibility),
    .modelMissing("base"),
    .modelDownloadFailed("timeout"),
    .providerUnreachable(endpointName: "Ollama (local)"),
    .providerHTTP(status: 401, body: "unauthorized"),
    .providerStreamMalformed,
    .audio("no input device"),
    .audioPlayback("format not supported"),
    .speechKeyMissing,
    .noSelection,
    .insertFailed
])
func everyErrorHasDescriptionAndRecovery(error: MacomprendoError) {
    #expect(error.errorDescription?.isEmpty == false)
    #expect(error.recoverySuggestion?.isEmpty == false)
}
```

and append this test at the **end of the file**, at file scope (these are free `@Test`
functions, not members of a `@Suite` type):

```swift
@Test func theMissingSpeechKeyErrorReadsAsOneSentencePair() {
    #expect(MacomprendoError.speechKeyMissing.errorDescription == "No speech API key.")
    #expect(MacomprendoError.speechKeyMissing.recoverySuggestion == "Add one in Settings ▸ Speech.")
    #expect(ErrorText.describe(MacomprendoError.speechKeyMissing)
            == "No speech API key. Add one in Settings ▸ Speech.")
    // Playback failures are distinct from recording failures.
    #expect(MacomprendoError.audioPlayback("x").errorDescription?.contains("Playing") == true)
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --package-path macos --filter everyErrorHasDescriptionAndRecovery`
Expected: build failure — `error: type 'MacomprendoError' has no member 'audioPlayback'` and
`error: type 'MacomprendoError' has no member 'speechKeyMissing'`.

- [ ] **Step 4: Add the error cases**

In `macos/Sources/Macomprendo/Core/MacomprendoError.swift`, add the two cases to the enum
(directly after `case audio(String)`):

```swift
    case audioPlayback(String)
    case speechKeyMissing
```

add to `errorDescription` (after the `.audio` arm):

```swift
        case .audioPlayback(let reason):
            return "Playing the speech audio failed: \(reason)"
        case .speechKeyMissing:
            return "No speech API key."
```

and to `recoverySuggestion` (after the `.audio` arm):

```swift
        case .audioPlayback:
            return "Check that an output device is connected and try again."
        case .speechKeyMissing:
            return "Add one in Settings ▸ Speech."
```

- [ ] **Step 5: Implement the player seam**

Create `macos/Sources/Macomprendo/Services/AudioPlayer.swift`:

```swift
import AVFoundation
import Foundation

/// Plays one buffer of encoded audio at a time and reports when it is done.
@MainActor protocol AudioPlaying: AnyObject {
    /// Called on the main actor when the current buffer finishes on its own. It is not called
    /// for `stop()`.
    var onFinished: (@MainActor () -> Void)? { get set }
    /// Replaces whatever is playing. `AVAudioPlayer` sniffs the container, so WAV, MP3 and the
    /// other formats an OpenAI-compatible server may return all work. Throws
    /// `MacomprendoError.audioPlayback` when the bytes cannot be decoded or the output device
    /// refuses to start.
    func play(_ audioData: Data) throws
    func stop()
}

/// Thin `AVAudioPlayer` wrapper. Hardware-bound glue with no logic of its own, so it carries no
/// unit test and is covered by `docs/SMOKE_TEST.md` instead (invariant 3).
@MainActor final class AVAudioPlayerPlayer: NSObject, AudioPlaying {
    var onFinished: (@MainActor () -> Void)?

    private var player: AVAudioPlayer?

    func play(_ audioData: Data) throws {
        stop()
        do {
            let player = try AVAudioPlayer(data: audioData)
            player.delegate = self
            self.player = player
            guard player.play() else {
                throw MacomprendoError.audioPlayback("the output device refused to start")
            }
        } catch let error as MacomprendoError {
            throw error
        } catch {
            throw MacomprendoError.audioPlayback(error.localizedDescription)
        }
    }

    func stop() {
        player?.stop()
        player?.delegate = nil
        player = nil
    }
}

extension AVAudioPlayerPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.player = nil
            self.onFinished?()
        }
    }
}
```

- [ ] **Step 6: Add the test double**

Create `macos/Tests/MacomprendoTests/Fakes/FakeAudioPlayer.swift`:

```swift
import Foundation
@testable import Macomprendo

@MainActor final class FakeAudioPlayer: AudioPlaying {
    var onFinished: (@MainActor () -> Void)?

    private(set) var played: [Data] = []
    private(set) var stopCount = 0

    /// Thrown by the next `play(_:)` call, then cleared.
    var playError: Error?

    /// `true` (the default) finishes each buffer synchronously, so a whole queue drains in one
    /// `await`. Set to `false` to hold a buffer open and drive it with `finishCurrent()`.
    var finishesImmediately = true

    func play(_ audioData: Data) throws {
        if let error = playError {
            playError = nil
            throw error
        }
        played.append(audioData)
        if finishesImmediately { onFinished?() }
    }

    func stop() { stopCount += 1 }

    /// Simulates the current buffer reaching its end.
    func finishCurrent() { onFinished?() }
}
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `swift test --package-path macos --filter everyErrorHasDescriptionAndRecovery`
Expected: PASS — 12 tests, 0 failures (one per argument in the list).

Run: `swift test --package-path macos`
Expected: `Test run with 512 tests … passed`.

- [ ] **Step 8: Regenerate the Xcode project and check for warnings**

```bash
npm run gen
find macos/Sources macos/Tests -name '*.swift' -exec touch {} +
swift build --package-path macos 2>&1 | grep -c "warning:" || true
```
Expected: `0`.

- [ ] **Step 9: Commit**

```bash
git add macos/Sources/Macomprendo/Services/AudioPlayer.swift \
        macos/Sources/Macomprendo/Core/MacomprendoError.swift \
        macos/Tests/MacomprendoTests/Fakes/FakeAudioPlayer.swift \
        macos/Tests/MacomprendoTests/Core/MacomprendoErrorTests.swift \
        macos/Macomprendo.xcodeproj
git commit -m "feat(speech): add the AudioPlaying seam and playback/key error cases"
```

---

### Task 8: `EndpointSpeechService`

**Files:**
- Create: `macos/Sources/Macomprendo/Services/EndpointSpeechService.swift` (Services layer)
- Test: `macos/Tests/MacomprendoTests/Services/EndpointSpeechServiceTests.swift`

**Interfaces:**
- Consumes: `SpeechSynthesizing`, `Voice`, `SpeechSettings`, `HTTPClient`, `KeychainStoring`,
  `AudioPlaying` (Task 7), `SpeechTextChunker` (Task 5), `SpeechRequestBuilder` (Task 6),
  `MacomprendoError`.
- Produces:
  ```swift
  enum EndpointVoices { static let all: [Voice] }   // 11 OpenAI built-ins, language "endpoint"

  @MainActor final class EndpointSpeechService: SpeechSynthesizing {
      static let defaultChunkCharacterLimit: Int       // SpeechTextChunker.defaultCharacterLimit
      static let requestTimeout: TimeInterval          // 60
      static func isCancellation(_ error: Error) -> Bool
      init(http: any HTTPClient,
           keychain: any KeychainStoring,
           player: any AudioPlaying,
           chunkCharacterLimit: Int = EndpointSpeechService.defaultChunkCharacterLimit)
      func drain() async                               // async test hook
  }
  ```

> `chunkCharacterLimit` is injectable purely so the tests can force a multi-chunk queue out of a
> two-word string instead of building a 4096-character fixture. `AppEnvironment` never passes it.

- [ ] **Step 1: Verify the working directory**

```bash
pwd
git -C <repo> status --short
git -C <repo> log --oneline -1
```
Expected: clean tree; HEAD is
`feat(speech): add the AudioPlaying seam and playback/key error cases`.

- [ ] **Step 2: Write the failing test**

Create `macos/Tests/MacomprendoTests/Services/EndpointSpeechServiceTests.swift`:

```swift
import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct EndpointSpeechServiceTests {
    private struct Rig {
        let service: EndpointSpeechService
        let http: FakeHTTPClient
        let player: FakeAudioPlayer
        let keychain: InMemoryKeychainStore
    }

    /// The endpoint answers with raw audio bytes — a WAV header is enough for the fake player.
    private static let audioResponse = HTTPResponse(status: 200, headers: [:],
                                                    body: Data([0x52, 0x49, 0x46, 0x46, 0x01, 0x02]))

    /// The default six-character budget turns "One. Two. Three." into three one-sentence
    /// chunks, which is what makes the queue observable without a 4096-character fixture.
    private func rig(withKey: Bool = true, chunkCharacterLimit: Int = 6) -> Rig {
        let http = FakeHTTPClient()
        http.response = Self.audioResponse
        let player = FakeAudioPlayer()
        let keychain = InMemoryKeychainStore()
        if withKey { try? keychain.set("sk-SECRET", account: SpeechSettings.endpointKeychainAccount) }
        return Rig(service: EndpointSpeechService(http: http,
                                                  keychain: keychain,
                                                  player: player,
                                                  chunkCharacterLimit: chunkCharacterLimit),
                   http: http, player: player, keychain: keychain)
    }

    private func settings(withKey: Bool = true, instructions: String = "") -> SpeechSettings {
        SpeechSettings(source: .endpoint,
                       endpointVoice: "alloy",
                       endpointInstructions: instructions,
                       endpointAPIKeyRef: withKey ? SpeechSettings.endpointKeychainAccount : nil)
    }

    private func bodies(_ http: FakeHTTPClient) -> [[String: Any]] {
        http.requests.compactMap { request -> [String: Any]? in
            guard let body = request.body,
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            else { return nil }
            return json
        }
    }

    private func inputs(_ http: FakeHTTPClient) -> [String] {
        bodies(http).compactMap { $0["input"] as? String }
    }

    /// Lets the service's task make progress when it is deliberately left mid-queue.
    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    @Test func chunksArePlayedInOrder() async {
        let r = rig()
        r.service.speak("One. Two. Three.", settings: settings())
        await r.service.drain()

        #expect(inputs(r.http) == ["One.", "Two.", "Three."])
        #expect(r.player.played == [Self.audioResponse.body,
                                    Self.audioResponse.body,
                                    Self.audioResponse.body])
        #expect(!r.service.isSpeaking)
    }

    @Test func theNextChunkIsFetchedWhileTheCurrentOnePlays() async {
        let r = rig()
        r.player.finishesImmediately = false
        r.service.speak("One. Two. Three.", settings: settings())
        await settle()

        // Chunk 1 is playing; chunk 2 has already been requested; chunk 3 has not.
        #expect(r.player.played.count == 1)
        #expect(r.http.requests.count == 2)

        r.player.finishCurrent()
        await settle()
        #expect(r.player.played.count == 2)
        #expect(r.http.requests.count == 3)

        r.player.finishCurrent()
        await settle()
        r.player.finishCurrent()
        await r.service.drain()
        #expect(r.player.played.count == 3)
        #expect(r.http.requests.count == 3)
    }

    @Test func isSpeakingStaysTrueUntilTheLastChunkFinishes() async {
        let r = rig()
        r.player.finishesImmediately = false
        var changes = 0
        r.service.onStateChange = { changes += 1 }

        r.service.speak("One. Two.", settings: settings())
        #expect(r.service.isSpeaking)
        await settle()
        #expect(r.service.isSpeaking)

        r.player.finishCurrent()
        await settle()
        #expect(r.service.isSpeaking)

        r.player.finishCurrent()
        await r.service.drain()
        #expect(!r.service.isSpeaking)
        #expect(changes == 2)
    }

    @Test func stopCancelsTheQueueAndStopsThePlayerWithoutAnError() async {
        let r = rig()
        r.player.finishesImmediately = false
        var errors: [Error] = []
        r.service.onError = { errors.append($0) }

        r.service.speak("One. Two. Three.", settings: settings())
        await settle()
        r.service.stop()
        // `stop()` clears the task handle, so `drain()` returns at once; `settle()` gives the
        // superseded task room to unwind and prove it stays silent.
        await r.service.drain()
        await settle()

        #expect(!r.service.isSpeaking)
        #expect(r.player.stopCount >= 1)
        #expect(r.player.played.count == 1)
        #expect(errors.isEmpty)
    }

    @Test func speakingAgainSupersedesTheRunningRequest() async {
        let r = rig()
        r.player.finishesImmediately = false
        r.service.speak("One. Two. Three.", settings: settings())
        await settle()

        r.player.finishesImmediately = true
        r.service.speak("Fresh.", settings: settings())
        await r.service.drain()

        #expect(inputs(r.http).last == "Fresh.")
        #expect(!r.service.isSpeaking)
    }

    @Test func aMissingAPIKeyIsReportedThroughOnError() async {
        let r = rig(withKey: false)
        var errors: [Error] = []
        r.service.onError = { errors.append($0) }

        r.service.speak("Hello.", settings: settings(withKey: false))
        await r.service.drain()

        #expect(errors.count == 1)
        #expect(errors.first as? MacomprendoError == .speechKeyMissing)
        #expect(r.http.requests.isEmpty)
        #expect(r.player.played.isEmpty)
        #expect(!r.service.isSpeaking)
    }

    @Test func anHTTPFailureStopsPlaybackAndReportsOnce() async {
        let r = rig()
        r.http.error = MacomprendoError.providerHTTP(status: 401, body: "invalid_api_key")
        var errors: [Error] = []
        r.service.onError = { errors.append($0) }

        r.service.speak("One. Two. Three.", settings: settings())
        await r.service.drain()

        #expect(errors.count == 1)
        #expect(errors.first as? MacomprendoError
                == .providerHTTP(status: 401, body: "invalid_api_key"))
        #expect(r.player.played.isEmpty)
        #expect(!r.service.isSpeaking)
    }

    @Test func transportFailuresAreRenamedToTheConfiguredHost() async {
        let r = rig()
        r.http.error = MacomprendoError.providerUnreachable(endpointName: "10.0.0.1")
        var errors: [Error] = []
        r.service.onError = { errors.append($0) }

        var configured = settings()
        configured.endpointBaseURL = URL(string: "https://api.proxyapi.ru/openai")!
        r.service.speak("Hello.", settings: configured)
        await r.service.drain()

        #expect(errors.first as? MacomprendoError
                == .providerUnreachable(endpointName: "api.proxyapi.ru"))
    }

    @Test func styleInstructionsTravelWithEveryRequest() async {
        let r = rig()
        r.service.speak("One. Two.", settings: settings(instructions: "  Read slowly  "))
        await r.service.drain()

        #expect(inputs(r.http) == ["One.", "Two."])
        #expect(bodies(r.http).compactMap { $0["instructions"] as? String }
                == ["Read slowly", "Read slowly"])

        // With no style set, the field is absent rather than empty.
        let plain = rig()
        plain.service.speak("One.", settings: settings())
        await plain.service.drain()
        #expect(bodies(plain.http).count == 1)
        #expect(bodies(plain.http)[0].keys.contains("instructions") == false)
    }

    @Test func blankTextIsNotSpoken() async {
        let r = rig()
        r.service.speak("   \n ", settings: settings())
        await r.service.drain()

        #expect(r.http.requests.isEmpty)
        #expect(!r.service.isSpeaking)
    }

    @Test func theVoiceCatalogHoldsTheBuiltInNames() {
        let r = rig()
        let voices = r.service.voices()
        #expect(voices.map(\.id) == ["alloy", "ash", "ballad", "coral", "echo", "fable",
                                     "nova", "onyx", "sage", "shimmer", "verse"])
        #expect(voices.allSatisfy { $0.language == "endpoint" && $0.quality == "premium" })
        #expect(voices.allSatisfy { $0.name == $0.id })
        #expect(voices.map(\.id).contains(SpeechSettings.defaultEndpointVoice))
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --package-path macos --filter EndpointSpeechServiceTests`
Expected: build failure — `error: cannot find 'EndpointSpeechService' in scope`.

- [ ] **Step 4: Implement the service**

Create `macos/Sources/Macomprendo/Services/EndpointSpeechService.swift`:

```swift
import Foundation

/// OpenAI's built-in voice names, embedded as data — the endpoint exposes no list route and no
/// network call is made to populate the picker. The Speech tab treats these as *suggestions*
/// beside a free-form field, because a local server (openedai-speech, Kokoro-FastAPI, an XTTS
/// wrapper) defines its own names. An unknown name simply returns an HTTP error, surfaced like
/// any other.
enum EndpointVoices {
    static let all: [Voice] = [
        "alloy", "ash", "ballad", "coral", "echo", "fable",
        "nova", "onyx", "sage", "shimmer", "verse"
    ].map { name in
        Voice(id: name, name: name, language: "endpoint", quality: "premium")
    }
}

/// Speaks text through any OpenAI-compatible `/v1/audio/speech` server: one HTTP request per
/// ≤4096-character chunk, played back sequentially with a single chunk of prefetch, so chunk
/// N+1 is already in flight while chunk N plays. The selection text leaves the machine only
/// while this backend is selected (invariant 9) and is never logged (invariant 6).
@MainActor final class EndpointSpeechService: SpeechSynthesizing {
    static let defaultChunkCharacterLimit = SpeechTextChunker.defaultCharacterLimit
    /// Synthesising a few thousand characters is slow; far above the 10 s used for metadata.
    static let requestTimeout: TimeInterval = 60

    private(set) var isSpeaking = false
    var onStateChange: (@MainActor () -> Void)?
    var onError: (@MainActor (Error) -> Void)?

    private let http: any HTTPClient
    private let keychain: any KeychainStoring
    private let player: any AudioPlaying
    /// Injectable only so tests can force a multi-chunk queue out of a short string.
    private let chunkCharacterLimit: Int
    private var task: Task<Void, Never>?
    private var playback: CheckedContinuation<Void, Error>?
    /// Bumped by every `speak`/`stop` so a superseded task cannot clobber the new state.
    private var generation = 0

    init(http: any HTTPClient,
         keychain: any KeychainStoring,
         player: any AudioPlaying,
         chunkCharacterLimit: Int = EndpointSpeechService.defaultChunkCharacterLimit) {
        self.http = http
        self.keychain = keychain
        self.player = player
        self.chunkCharacterLimit = chunkCharacterLimit
    }

    func voices() -> [Voice] { EndpointVoices.all }

    func speak(_ text: String, settings: SpeechSettings) {
        cancelCurrent()
        generation += 1
        let generation = self.generation

        let chunks = SpeechTextChunker.chunks(of: text, limit: chunkCharacterLimit)
        guard !chunks.isEmpty else { return }

        setSpeaking(true)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.play(chunks: chunks, settings: settings)
                self.finish(generation: generation, error: nil)
            } catch {
                self.finish(generation: generation, error: error)
            }
        }
    }

    func stop() {
        generation += 1
        cancelCurrent()
        setSpeaking(false)
    }

    /// Awaits the in-flight speech task. Used by tests.
    func drain() async { _ = await task?.value }

    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? MacomprendoError) == .cancelled
    }

    // MARK: - Private

    private func cancelCurrent() {
        task?.cancel()
        task = nil
        resumePlayback(throwing: MacomprendoError.cancelled)
        player.stop()
    }

    private func finish(generation: Int, error: Error?) {
        guard generation == self.generation else { return }   // a newer speak owns the state
        setSpeaking(false)
        guard let error, !Self.isCancellation(error) else { return }
        player.stop()
        onError?(error)
    }

    private func setSpeaking(_ value: Bool) {
        guard isSpeaking != value else { return }
        isSpeaking = value
        onStateChange?()
    }

    /// A missing or blank key fails before anything is sent. A local server without auth is
    /// still reachable: save any non-empty placeholder key (documented in Settings ▸ Speech),
    /// which beats an extra "no auth" toggle.
    private func apiKey(_ settings: SpeechSettings) throws -> String {
        guard let account = settings.endpointAPIKeyRef,
              let key = try? keychain.get(account: account),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw MacomprendoError.speechKeyMissing }
        return key
    }

    private func play(chunks: [String], settings: SpeechSettings) async throws {
        let key = try apiKey(settings)
        var next: Task<Data, Error>? = fetch(chunks[0], key: key, settings: settings)
        defer { next?.cancel() }                              // never orphan a prefetch

        for index in chunks.indices {
            guard let current = next else { break }
            next = index + 1 < chunks.count
                ? fetch(chunks[index + 1], key: key, settings: settings)
                : nil
            let audio = try await current.value
            try Task.checkCancellation()
            try await playAndWait(audio)
        }
    }

    private func fetch(_ chunk: String, key: String, settings: SpeechSettings) -> Task<Data, Error> {
        let http = self.http
        return Task {
            let request = try SpeechRequestBuilder.request(baseURL: settings.endpointBaseURL,
                                                           apiKey: key,
                                                           model: settings.endpointModel,
                                                           voice: settings.endpointVoice,
                                                           input: chunk,
                                                           instructions: settings.endpointInstructions,
                                                           timeout: Self.requestTimeout)
            do {
                let response = try await http.send(request)
                return try SpeechRequestBuilder.audio(from: response)
            } catch let error as MacomprendoError {
                throw SpeechRequestBuilder.mapped(error, baseURL: settings.endpointBaseURL)
            }
        }
    }

    private func playAndWait(_ audio: Data) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                playback = continuation
                player.onFinished = { [weak self] in self?.resumePlayback(throwing: nil) }
                do { try player.play(audio) } catch { resumePlayback(throwing: error) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.player.stop()
                self?.resumePlayback(throwing: CancellationError())
            }
        }
    }

    private func resumePlayback(throwing error: Error?) {
        guard let continuation = playback else { return }
        playback = nil
        player.onFinished = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --package-path macos --filter EndpointSpeechServiceTests`
Expected: PASS — 11 tests, 0 failures.

- [ ] **Step 6: Regenerate the Xcode project and check for warnings**

```bash
npm run gen
find macos/Sources macos/Tests -name '*.swift' -exec touch {} +
swift build --package-path macos 2>&1 | grep -c "warning:" || true
```
Expected: `0`.

- [ ] **Step 7: Commit**

```bash
git add macos/Sources/Macomprendo/Services/EndpointSpeechService.swift \
        macos/Tests/MacomprendoTests/Services/EndpointSpeechServiceTests.swift \
        macos/Macomprendo.xcodeproj
git commit -m "feat(speech): add the OpenAI-compatible endpoint speech backend"
```

---

### Task 9: `SpeechRouter` and `AppEnvironment` wiring

**Files:**
- Create: `macos/Sources/Macomprendo/Services/SpeechRouter.swift` (Services layer)
- Modify: `macos/Sources/Macomprendo/Services/SpeechService.swift` (Services layer)
- Modify: `macos/Sources/Macomprendo/App/AppEnvironment.swift` (App layer, composition root)
- Test: `macos/Tests/MacomprendoTests/Services/SpeechRouterTests.swift`

**Interfaces:**
- Consumes: `SpeechSynthesizing`, `SpeechSource` (Task 4), `AVSpeechService`,
  `EndpointSpeechService` (Task 8), `AVAudioPlayerPlayer` (Task 7).
- Produces:
  ```swift
  extension SpeechSynthesizing {
      func voices(for source: SpeechSource) -> [Voice]     // protocol requirement + default
  }

  @MainActor final class SpeechRouter: SpeechSynthesizing {
      init(system: any SpeechSynthesizing, endpoint: any SpeechSynthesizing)
  }
  ```

- [ ] **Step 1: Verify the working directory**

```bash
pwd
git -C <repo> status --short
git -C <repo> log --oneline -1
```
Expected: clean tree; HEAD is
`feat(speech): add the OpenAI-compatible endpoint speech backend`.

- [ ] **Step 2: Write the failing test**

Create `macos/Tests/MacomprendoTests/Services/SpeechRouterTests.swift`:

```swift
import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct SpeechRouterTests {
    private struct Rig {
        let router: SpeechRouter
        let system: ScriptedSpeech
        let endpoint: ScriptedSpeech
    }

    private func rig() -> Rig {
        let system = ScriptedSpeech()
        system.available = [Voice(id: "en.alex", name: "Alex", language: "en-US", quality: "default")]
        let endpoint = ScriptedSpeech()
        endpoint.available = [Voice(id: "alloy", name: "alloy", language: "endpoint", quality: "premium")]
        return Rig(router: SpeechRouter(system: system, endpoint: endpoint),
                   system: system, endpoint: endpoint)
    }

    private func settings(_ source: SpeechSource) -> SpeechSettings {
        SpeechSettings(voiceID: "en.alex", source: source)
    }

    @Test func speakGoesToTheSystemBackendByDefault() {
        let r = rig()
        r.router.speak("hello", settings: settings(.system))
        #expect(r.system.spoken.map(\.text) == ["hello"])
        #expect(r.endpoint.spoken.isEmpty)
    }

    @Test func speakGoesToTheEndpointBackendWhenSelected() {
        let r = rig()
        r.router.speak("hello", settings: settings(.endpoint))
        #expect(r.endpoint.spoken.map(\.text) == ["hello"])
        #expect(r.system.spoken.isEmpty)
        // Switching source mid-utterance must not orphan the other backend's audio.
        #expect(r.system.stopCount == 1)
    }

    @Test func stopStopsBothBackends() {
        let r = rig()
        r.router.speak("hello", settings: settings(.endpoint))
        r.router.stop()
        #expect(r.system.stopCount == 2)   // once on speak, once on stop
        #expect(r.endpoint.stopCount == 1)
    }

    @Test func isSpeakingIsTrueWhenEitherBackendSpeaks() {
        let r = rig()
        #expect(!r.router.isSpeaking)
        r.router.speak("hello", settings: settings(.endpoint))
        #expect(r.router.isSpeaking)
        r.endpoint.finish()
        #expect(!r.router.isSpeaking)
    }

    @Test func stateChangesFromBothBackendsAreRepublished() {
        let r = rig()
        var changes = 0
        r.router.onStateChange = { changes += 1 }
        r.system.finish()
        r.endpoint.finish()
        #expect(changes == 2)
    }

    @Test func errorsFromBothBackendsAreRepublished() {
        let r = rig()
        var errors: [Error] = []
        r.router.onError = { errors.append($0) }
        r.system.failWith(MacomprendoError.audioPlayback("x"))
        r.endpoint.failWith(MacomprendoError.speechKeyMissing)
        #expect(errors.count == 2)
        #expect(errors.last as? MacomprendoError == .speechKeyMissing)
    }

    @Test func voicesForASourceIgnoreTheCurrentSelection() {
        let r = rig()
        #expect(r.router.voices(for: .system).map(\.id) == ["en.alex"])
        #expect(r.router.voices(for: .endpoint).map(\.id) == ["alloy"])
        // A plain backend only knows its own catalog, whatever source is asked for.
        #expect(r.endpoint.voices(for: .system).map(\.id) == ["alloy"])
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --package-path macos --filter SpeechRouterTests`
Expected: build failure — `error: cannot find 'SpeechRouter' in scope`.

- [ ] **Step 4: Add `voices(for:)` to the protocol**

In `macos/Sources/Macomprendo/Services/SpeechService.swift`, add the requirement to the protocol
directly after `func voices() -> [Voice]`:

```swift
    /// The catalog of one backend, whether or not it is the active one. The Speech tab lists
    /// the voices of the source being configured, which is not always the source in use.
    func voices(for source: SpeechSource) -> [Voice]
```

and add this extension directly under the protocol declaration:

```swift
extension SpeechSynthesizing {
    /// A single backend only knows its own voices; only `SpeechRouter` overrides this.
    func voices(for source: SpeechSource) -> [Voice] { voices() }
}
```

- [ ] **Step 5: Implement the router**

Create `macos/Sources/Macomprendo/Services/SpeechRouter.swift`:

```swift
import Foundation

/// Dispatches every call to the backend named by `SpeechSettings.source`, so `SpeakController`
/// keeps receiving one `any SpeechSynthesizing` and knows nothing about the split.
///
/// The source is read from the `SpeechSettings` the caller already passes, so there is no
/// settings closure that could go stale and no coupling back to `AppModel`.
@MainActor final class SpeechRouter: SpeechSynthesizing {
    var onStateChange: (@MainActor () -> Void)?
    var onError: (@MainActor (Error) -> Void)?

    private let system: any SpeechSynthesizing
    private let endpoint: any SpeechSynthesizing

    init(system: any SpeechSynthesizing, endpoint: any SpeechSynthesizing) {
        self.system = system
        self.endpoint = endpoint
        // Fan-in: both backends report through the router's single pair of hooks.
        for backend in [system, endpoint] {
            backend.onStateChange = { [weak self] in self?.onStateChange?() }
            backend.onError = { [weak self] error in self?.onError?(error) }
        }
    }

    var isSpeaking: Bool { system.isSpeaking || endpoint.isSpeaking }

    /// The neutral catalog. Settings ▸ Speech asks for a specific source with `voices(for:)`.
    func voices() -> [Voice] { system.voices() }

    func voices(for source: SpeechSource) -> [Voice] { backend(for: source).voices() }

    func speak(_ text: String, settings: SpeechSettings) {
        // Stopping the other backend first means switching the source mid-utterance cannot
        // leave orphaned audio playing behind the new one.
        backend(for: settings.source == .endpoint ? .system : .endpoint).stop()
        backend(for: settings.source).speak(text, settings: settings)
    }

    func stop() {
        system.stop()
        endpoint.stop()
    }

    private func backend(for source: SpeechSource) -> any SpeechSynthesizing {
        source == .endpoint ? endpoint : system
    }
}
```

- [ ] **Step 6: Build the router in the composition root**

In `macos/Sources/Macomprendo/App/AppEnvironment.swift`, replace the line
`speech: AVSpeechService(),` inside `live()` with:

```swift
            speech: SpeechRouter(
                system: AVSpeechService(),
                endpoint: EndpointSpeechService(http: http,
                                                keychain: keychain,
                                                player: AVAudioPlayerPlayer())),
```

`AppEnvironment.fake()` is **not** changed: tests keep injecting `ScriptedSpeech`, which is why
`SpeakControllerTests` and `TextFeaturesTests` need no edits.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `swift test --package-path macos --filter SpeechRouterTests`
Expected: PASS — 7 tests, 0 failures.

Run: `swift test --package-path macos --filter "SpeakControllerTests|TextFeaturesTests|SpeechTabModelTests"`
Expected: PASS — all green, 0 failures (these suites prove the seam held).

- [ ] **Step 8: Regenerate the Xcode project and check for warnings**

```bash
npm run gen
find macos/Sources macos/Tests -name '*.swift' -exec touch {} +
swift build --package-path macos 2>&1 | grep -c "warning:" || true
```
Expected: `0`.

- [ ] **Step 9: Commit**

```bash
git add macos/Sources/Macomprendo/Services/SpeechRouter.swift \
        macos/Sources/Macomprendo/Services/SpeechService.swift \
        macos/Sources/Macomprendo/App/AppEnvironment.swift \
        macos/Tests/MacomprendoTests/Services/SpeechRouterTests.swift \
        macos/Macomprendo.xcodeproj
git commit -m "feat(speech): route speech to the system or endpoint backend per settings"
```

---

### Task 10: Settings ▸ Speech — source picker and the endpoint section

**Files:**
- Modify: `macos/Sources/Macomprendo/UI/Settings/SpeechTab.swift` (UI layer)
- Modify: `macos/Sources/Macomprendo/App/AppModel.swift` (App layer)
- Modify: `macos/Tests/MacomprendoTests/Fakes/ScriptedSpeech.swift`
- Test (rewrite): `macos/Tests/MacomprendoTests/UI/SpeechTabModelTests.swift`

**Interfaces:**
- Consumes: `SpeechSynthesizing.voices(for:)` (Task 9), `SpeechSource`/`SpeechSettings` (Task 4),
  `SettingsHolding`, `KeychainStoring`.
- Produces:
  ```swift
  @MainActor final class SpeechTabModel: ObservableObject {
      struct VoiceGroup: Identifiable, Equatable { … }          // unchanged
      static let sampleText: String                              // unchanged
      static let endpointPrivacyCaption: String
      @Published private(set) var groups: [VoiceGroup]
      @Published private(set) var endpointVoices: [Voice]
      @Published var apiKeyField: String
      @Published private(set) var keyStatus: String
      var source: SpeechSource { get set }
      init(speech: any SpeechSynthesizing, holder: any SettingsHolding, keychain: any KeychainStoring)
      func reload()
      func preview()
      func saveAPIKey()
      func hasAPIKey() -> Bool
      static func group(_ voices: [Voice]) -> [VoiceGroup]      // unchanged
  }
  struct SpeechTab: View { init(model: SpeechTabModel, app: AppModel) }
  ```

> The SecureField deliberately does **not** read the stored key back into memory the way the
> Providers tab does. `hasAPIKey()` drives the "A key is saved." caption instead, so the secret
> only ever moves in one direction (invariant 5).

- [ ] **Step 1: Verify the working directory**

```bash
pwd
git -C <repo> status --short
git -C <repo> log --oneline -1
```
Expected: clean tree; HEAD is
`feat(speech): route speech to the system or endpoint backend per settings`.

- [ ] **Step 2: Write the failing test**

Overwrite `macos/Tests/MacomprendoTests/UI/SpeechTabModelTests.swift`:

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

    private let endpointCatalog = [
        Voice(id: "alloy", name: "alloy", language: "endpoint", quality: "premium"),
        Voice(id: "sage", name: "sage", language: "endpoint", quality: "premium"),
    ]

    private func model(speech: ScriptedSpeech = ScriptedSpeech(),
                       holder: ScriptedSettingsHolder = ScriptedSettingsHolder(),
                       keychain: InMemoryKeychainStore = InMemoryKeychainStore())
        -> SpeechTabModel {
        SpeechTabModel(speech: speech, holder: holder, keychain: keychain)
    }

    // MARK: existing behaviour

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
        speech.availableBySource = [.system: voices, .endpoint: endpointCatalog]
        let tab = model(speech: speech)
        #expect(tab.groups.count == 2)

        speech.availableBySource[.system] = [voices[0]]
        tab.reload()
        #expect(tab.groups.count == 1)
    }

    @Test func previewSpeaksTheSampleWithTheCurrentSettings() {
        let speech = ScriptedSpeech()
        let holder = ScriptedSettingsHolder()
        holder.settings.speech = SpeechSettings(voiceID: "v.en1", rate: 0.7, pitch: 1.2, volume: 0.8)
        let tab = model(speech: speech, holder: holder)

        tab.preview()

        #expect(speech.spoken.count == 1)
        #expect(speech.spoken[0].text == SpeechTabModel.sampleText)
        #expect(speech.spoken[0].settings.voiceID == "v.en1")
        #expect(speech.spoken[0].settings.rate == 0.7)
    }

    // MARK: the endpoint source

    @Test func theSourceBindingWritesThroughToSettings() {
        let holder = ScriptedSettingsHolder()
        let tab = model(holder: holder)
        #expect(tab.source == .system)

        tab.source = .endpoint

        #expect(holder.settings.speech.source == .endpoint)
        #expect(tab.source == .endpoint)
    }

    @Test func endpointVoicesComeFromTheEndpointSource() {
        let speech = ScriptedSpeech()
        speech.availableBySource = [.system: voices, .endpoint: endpointCatalog]
        let tab = model(speech: speech)
        #expect(tab.endpointVoices.map(\.id) == ["alloy", "sage"])
        #expect(tab.groups.flatMap { $0.voices.map(\.id) }.sorted() == ["v.en1", "v.en2", "v.fr"])
    }

    @Test func savingAnAPIKeyStoresItInTheKeychainAndRecordsTheReference() throws {
        let holder = ScriptedSettingsHolder()
        let keychain = InMemoryKeychainStore()
        let tab = model(holder: holder, keychain: keychain)

        tab.apiKeyField = "  sk-SECRET  "
        tab.saveAPIKey()

        #expect(try keychain.get(account: SpeechSettings.endpointKeychainAccount) == "sk-SECRET")
        #expect(holder.settings.speech.endpointAPIKeyRef == SpeechSettings.endpointKeychainAccount)
        #expect(tab.hasAPIKey())
    }

    @Test func savingAnEmptyKeyDeletesItAndClearsTheReference() throws {
        let holder = ScriptedSettingsHolder()
        let keychain = InMemoryKeychainStore()
        try keychain.set("sk-OLD", account: SpeechSettings.endpointKeychainAccount)
        holder.settings.speech.endpointAPIKeyRef = SpeechSettings.endpointKeychainAccount
        let tab = model(holder: holder, keychain: keychain)

        tab.apiKeyField = "   "
        tab.saveAPIKey()

        #expect(try keychain.get(account: SpeechSettings.endpointKeychainAccount) == nil)
        #expect(holder.settings.speech.endpointAPIKeyRef == nil)
        #expect(!tab.hasAPIKey())
    }

    @Test func theAPIKeyFieldIsClearedAfterSaving() {
        let tab = model()
        tab.apiKeyField = "sk-SECRET"
        tab.saveAPIKey()

        #expect(tab.apiKeyField.isEmpty)
        #expect(!tab.keyStatus.isEmpty)
        #expect(!tab.keyStatus.contains("sk-"))
    }

    @Test func thePrivacyCaptionNamesTheConfiguredServer() {
        #expect(SpeechTabModel.endpointPrivacyCaption
                == "Selected text is sent to the configured server when this source is active.")
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --package-path macos --filter SpeechTabModelTests`
Expected: build failure — `error: extra argument 'keychain' in call` and
`error: value of type 'ScriptedSpeech' has no member 'availableBySource'`.

- [ ] **Step 4: Give `ScriptedSpeech` per-source catalogs**

In `macos/Tests/MacomprendoTests/Fakes/ScriptedSpeech.swift`, add the property next to
`var available: [Voice] = []`:

```swift
    /// Per-source catalogs for the Speech tab. Falls back to `available` for a source that is
    /// not listed, so tests that only care about one list keep working.
    var availableBySource: [SpeechSource: [Voice]] = [:]
```

and add the method next to `func voices() -> [Voice]`:

```swift
    func voices(for source: SpeechSource) -> [Voice] { availableBySource[source] ?? available }
```

- [ ] **Step 5: Rewrite the Speech tab**

Overwrite `macos/Sources/Macomprendo/UI/Settings/SpeechTab.swift`:

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

    static let endpointPrivacyCaption =
        "Selected text is sent to the configured server when this source is active."

    @Published private(set) var groups: [VoiceGroup] = []
    @Published private(set) var endpointVoices: [Voice] = []
    /// Write-only: the stored key is never read back into memory (invariant 5).
    @Published var apiKeyField = ""
    @Published private(set) var keyStatus = ""

    private let speech: any SpeechSynthesizing
    private let holder: any SettingsHolding
    private let keychain: any KeychainStoring

    init(speech: any SpeechSynthesizing,
         holder: any SettingsHolding,
         keychain: any KeychainStoring) {
        self.speech = speech
        self.holder = holder
        self.keychain = keychain
        reload()
    }

    var source: SpeechSource {
        get { holder.settings.speech.source }
        set {
            guard holder.settings.speech.source != newValue else { return }
            objectWillChange.send()
            holder.settings.speech.source = newValue
        }
    }

    func reload() {
        groups = Self.group(speech.voices(for: .system))
        endpointVoices = speech.voices(for: .endpoint)
    }

    /// For the endpoint source this performs a real network call and therefore doubles as the
    /// connection test; failures arrive as a toast through `SpeakController`'s `onError` hook.
    func preview() {
        speech.speak(Self.sampleText, settings: holder.settings.speech)
    }

    func hasAPIKey() -> Bool {
        holder.settings.speech.endpointAPIKeyRef != nil
    }

    func saveAPIKey() {
        let account = SpeechSettings.endpointKeychainAccount
        let key = apiKeyField.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            try? keychain.delete(account: account)
            holder.settings.speech.endpointAPIKeyRef = nil
            keyStatus = "Key removed."
        } else {
            try? keychain.set(key, account: account)
            holder.settings.speech.endpointAPIKeyRef = account
            keyStatus = "Key saved to the Keychain."
        }
        apiKeyField = ""
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
            Picker("Speech source", selection: sourceSelection) {
                ForEach(SpeechSource.allCases) { source in
                    Text(source.displayName).tag(source)
                }
            }
            .pickerStyle(.segmented)

            if app.settings.speech.source == .system {
                systemSection
            } else {
                endpointSection
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

    private var systemSection: some View {
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

    private var endpointSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                TextField("Base URL", text: baseURLSelection,
                          prompt: Text("https://api.openai.com"))
                TextField("Model", text: $app.settings.speech.endpointModel)

                // Free-form: local servers (openedai-speech, Kokoro-FastAPI) define their own
                // names, so the built-ins are offered as a menu rather than a closed picker.
                HStack {
                    TextField("Voice", text: $app.settings.speech.endpointVoice)
                    Menu("Built-in") {
                        ForEach(model.endpointVoices) { voice in
                            Button(voice.name) { app.settings.speech.endpointVoice = voice.id }
                        }
                    }
                    .fixedSize()
                }

                SecureField("API key", text: $model.apiKeyField)
                    .onSubmit { model.saveAPIKey() }
                HStack {
                    Button("Save key") { model.saveAPIKey() }
                    if !model.keyStatus.isEmpty {
                        Text(model.keyStatus).font(.caption).foregroundStyle(.secondary)
                    } else if model.hasAPIKey() {
                        Text("A key is saved.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("A local server without authentication still needs a non-empty key here.")
                    .font(.caption).foregroundStyle(.secondary)

                TextField("Style instructions", text: $app.settings.speech.endpointInstructions,
                          prompt: Text("e.g. Read this cheerfully"))
            }
            .formStyle(.grouped)

            Text(SpeechTabModel.endpointPrivacyCaption)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sourceSelection: Binding<SpeechSource> {
        Binding(get: { app.settings.speech.source },
                set: { app.settings.speech.source = $0 })
    }

    private var voiceSelection: Binding<String?> {
        Binding(get: { app.settings.speech.voiceID },
                set: { app.settings.speech.voiceID = $0 })
    }

    /// Keeps the last valid URL when the user is mid-edit and the text does not parse.
    private var baseURLSelection: Binding<String> {
        Binding(get: { app.settings.speech.endpointBaseURL.absoluteString },
                set: { newValue in
                    guard let url = URL(string: newValue) else { return }
                    app.settings.speech.endpointBaseURL = url
                })
    }
}
```

- [ ] **Step 6: Update the composition in `AppModel`**

In `macos/Sources/Macomprendo/App/AppModel.swift`, replace the `speechTabModel` line with:

```swift
    lazy var speechTabModel = SpeechTabModel(speech: env.speech, holder: self, keychain: keychain)
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `swift test --package-path macos --filter SpeechTabModelTests`
Expected: PASS — 10 tests, 0 failures.

Run: `swift test --package-path macos`
Expected: `Test run with 536 tests … passed`.

- [ ] **Step 8: Check for warnings**

```bash
find macos/Sources macos/Tests -name '*.swift' -exec touch {} +
swift build --package-path macos 2>&1 | grep -c "warning:" || true
```
Expected: `0`. (No `npm run gen`: this task adds no files.)

- [ ] **Step 9: Commit**

```bash
git add macos/Sources/Macomprendo/UI/Settings/SpeechTab.swift \
        macos/Sources/Macomprendo/App/AppModel.swift \
        macos/Tests/MacomprendoTests/Fakes/ScriptedSpeech.swift \
        macos/Tests/MacomprendoTests/UI/SpeechTabModelTests.swift
git commit -m "feat(settings): add a speech source picker and the endpoint section"
```

---

### Task 11: Smoke tests, changelog and the full suite

**Files:**
- Modify: `docs/SMOKE_TEST.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: the shipped behaviour of Tasks 1–10. Produces no code.

- [ ] **Step 1: Verify the working directory**

```bash
pwd
git -C <repo> status --short
git -C <repo> log --oneline -1
```
Expected: clean tree; HEAD is
`feat(settings): add a speech source picker and the endpoint section`.

- [ ] **Step 2: Append the smoke-test sections**

Append to `docs/SMOKE_TEST.md` (after the existing `## Settings ▸ Refine & Summarize` section):

```markdown
## Mixed-language speech, system voices (hotkey #3, ⌥S)

Setup: in Settings ▸ Speech pick "System voices" and an **English** voice (e.g. Samantha).
Install a Russian voice first if none is present (System Settings ▸ Accessibility ▸ Spoken
Content ▸ System Voice ▸ Manage Voices…).

- [ ] Select a paragraph that is entirely English and press ⌥S: it reads exactly as before —
      one continuous utterance, no seam, no pause at the start.
- [ ] Select a paragraph with a long Russian sentence followed by a long English sentence and
      press ⌥S: **both** languages are intelligible and the voice audibly changes at the
      script boundary, not mid-word.
- [ ] The "Speaking…" HUD stays up for the *whole* passage, including across the voice switch,
      and disappears only when the last sentence ends.
- [ ] Press ⌥S again mid-passage: playback stops immediately, the HUD disappears, and the
      remaining sentences are not read.
- [ ] Select a Russian sentence containing one English word ("Я купил новый iPhone вчера…")
      and press ⌥S: the whole sentence is read by the Russian voice — the voice does **not**
      flip for the single word.
- [ ] Select text containing Chinese or Arabic characters mixed into English and press ⌥S:
      nothing crashes; the foreign characters are read (or skipped) by the surrounding voice.
- [ ] Remove every Russian voice from the system, then repeat the mixed selection: it still
      reads without crashing, using the configured voice throughout.

## Endpoint speech source (hotkey #3, ⌥S)

Setup: Settings ▸ Speech ▸ Speech source = "Endpoint", and either an OpenAI-compatible API key
(OpenAI itself or a reseller such as `https://api.proxyapi.ru/openai`) or a local server on
`http://localhost:8000`.

- [ ] With no key saved, press Preview: a toast reads
      "No speech API key. Add one in Settings ▸ Speech." and nothing plays.
- [ ] Paste a **wrong** key, press "Save key", press Preview: a toast names the HTTP status the
      server returned; nothing plays; the app stays responsive.
- [ ] Paste the real key and press "Save key": the field clears immediately, the caption reads
      "Key saved to the Keychain.", and the key is **not** visible anywhere in the UI.
      Confirm with Keychain Access that an item `speech.endpoint` exists for service
      `com.dzamataev.macomprendo`.
- [ ] Press Preview: the sample sentence plays in the configured voice within a few seconds.
- [ ] Pick a different name from the "Built-in" menu and press Preview: the voice audibly
      changes. Type a name the server does not know and press Preview: a toast names the HTTP
      error.
- [ ] Type "Read this slowly and sadly" into Style instructions and press Preview with
      `gpt-4o-mini-tts`: the delivery changes. Clear the field and press Preview: normal
      delivery returns.
- [ ] The rate/pitch/volume sliders are **not** shown while Endpoint is selected; switch back to
      "System voices" and they reappear.
- [ ] Select a mixed Russian/English paragraph in TextEdit and press ⌥S: it is read by one
      natural voice that switches languages mid-sentence without changing timbre.
- [ ] The "Speaking…" HUD is visible from the moment ⌥S is pressed until the last chunk ends,
      including the gaps between chunks of a long selection.
- [ ] Select five or more paragraphs (over ~4000 characters) and press ⌥S: playback is
      continuous, in order, with only a short gap between chunks.
- [ ] Press ⌥S again mid-audio: playback stops within a second, the HUD disappears, and **no**
      error toast appears.
- [ ] Turn Wi-Fi off and press ⌥S: a toast reads `Could not reach "<your host>".` — the host
      you typed into Base URL, not a raw URL — with its recovery suggestion. Turn Wi-Fi back on.
- [ ] Point Base URL at a local server that returns MP3 instead of WAV (openedai-speech with
      `response_format` ignored): audio still plays.
- [ ] Switch the source back to "System voices" while endpoint audio is playing: the endpoint
      audio stops; the next ⌥S uses a system voice.
- [ ] Clear the API key field and press "Save key": the caption reads "Key removed." and the
      Keychain item is gone.
- [ ] Open Console.app filtered on subsystem `com.dzamataev.macomprendo` and repeat a ⌥S with
      the endpoint source selected: **no** log line contains the selected text or the API key.
```

- [ ] **Step 3: Update the changelog**

In `CHANGELOG.md`, add these bullets at the end of the `### Added` list under `## [Unreleased]`:

```markdown
- Mixed-language speech: a selection that mixes Cyrillic and Latin text is now split at
  script boundaries and read by a matching system voice per stretch, so Russian and
  English in one paragraph are both intelligible. A single foreign word no longer
  switches the voice.
- Optional endpoint speech source: Settings ▸ Speech can now read selections through any
  OpenAI-compatible `/v1/audio/speech` server — OpenAI, a reseller, or a local TTS server —
  whose voices code-switch naturally. Base URL, model, voice and free-form style
  instructions are all editable; the API key is stored in the login Keychain, and selected
  text is sent to the configured server only while this source is active.
```

- [ ] **Step 4: Run the full suite and a release build**

```bash
swift test --package-path macos
```
Expected: `Test run with 536 tests … passed`.

```bash
npm run test:scripts
```
Expected: `# pass 38`, `# fail 0`.

```bash
npm run gen
git status --short
```
Expected: `npm run gen` is a no-op — `git status --short` prints nothing (apart from the two
docs files you just edited and possibly `?? .claude/worktrees/`).

```bash
find macos/Sources macos/Tests -name '*.swift' -exec touch {} +
swift build --package-path macos 2>&1 | grep -c "warning:" || true
```
Expected: `0`.

```bash
xcodebuild -project macos/Macomprendo.xcodeproj -scheme Macomprendo \
  -configuration Release -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add docs/SMOKE_TEST.md CHANGELOG.md
git commit -m "docs: add smoke tests and changelog for mixed-language speech"
```

---

## Self-review notes

**Spec coverage**

| Spec item | Task |
|---|---|
| Goal 1 — mixed Cyrillic/Latin intelligible with system voices, offline, free | 1, 2 |
| Goal 2 — optional endpoint speech source, OpenAI-compatible `/v1/audio/speech` | 4–10 |
| Goal 3 — `SpeakController`, "Speaking…" HUD and hotkey #3 unchanged | 9 (router behind the same protocol; Tasks 3/9 re-run `SpeakControllerTests`/`TextFeaturesTests` unchanged) |
| Goal 4 — failures user-visible with recovery text; text sent to the network only when the endpoint source is selected | 3, 7, 8, 9 |
| Part A — `LanguageSegmenter`, `ScriptClass`, `TextRun`, `runs(in:minRunLength:)`, default 20 | 1 |
| Part A — neutral attachment, min-run merging, non-Cyrillic/Latin scripts never crash or flip the voice | 1 |
| Part A — `AVSpeechService.speak` one-utterance fast path, per-run queueing, `fallbackVoice(for:in:)` with premium > enhanced > default, rate/pitch/volume on every utterance, `isSpeaking` until the last utterance finishes | 2 |
| Part B step 1 — sentence-boundary chunking at ≤4096 characters, word-boundary split for oversize sentences | 5 |
| Part B step 2 — `POST {base}/v1/audio/speech`, `Authorization: Bearer`, JSON body, `instructions` omitted when empty, isolated in `SpeechRequestBuilder` | 6 |
| Part B step 3 — the response body *is* the audio; no PCM/WAV conversion helper | 6, 7 (no decoding type exists in this plan at all — the bytes go straight from `HTTPResponse.body` to `AudioPlaying.play`) |
| Part B step 4 — `AudioPlaying.play(_ audioData:)` / `AVAudioPlayerPlayer`, sequential playback with single prefetch | 7, 8 |
| Part B step 5 — `stop()` cancels the task and the player; `isSpeaking` lifecycle | 8 |
| Part B step 6 — the 11 built-in voice names as `Voice` values plus a free-form field | 8, 10 |
| Part B — `endpointInstructions` sent as the standard `instructions` field | 6, 8 |
| Protocol change — `SpeechSynthesizing.onError`, `SpeakController` toast, `ScriptedSpeech.failWith(_:)` | 3 |
| Router — both backends, dispatch on `settings.source`, `stop()` stops both, callback fan-in, `voices(for:)` as a requirement with an extension default | 9 |
| Router — `AppEnvironment.live()` builds it, `fake()` untouched | 9 |
| Settings schema — six new fields, all `decodeIfPresent ?? default` | 4 |
| Settings schema — key only in the Keychain under `speech.endpoint`; base URL user-editable | 4, 8, 10 |
| UI — source picker, system section unchanged, Base URL / Model / free-form Voice with built-in menu / SecureField / Style instructions / Preview, sliders hidden, privacy caption | 10 |
| Errors — missing key copy, HTTP mapping to the configured host, `audioPlayback`, silent cancellation, one error per queue | 6, 7, 8 |
| Testing — segmenter, static helpers, chunker, request builder, service with fakes, router, migration, `SpeakControllerTests` unchanged | 1–10 |
| Testing — hardware/network-bound paths in SMOKE_TEST.md | 11 |
| Open item 1 — servers that ignore `response_format` and return MP3 | 7 (`AVAudioPlayer` sniffs the container; documented on the protocol), 11 (smoke check) |
| Open item 2 — the voice list is cosmetic; an unknown name returns an HTTP error | 8, 10, 11 |

**Test-count ledger**

| Task | Suite(s) | New tests | Running total |
|---|---|---|---|
| — | baseline | — | 464 |
| 1 | `LanguageSegmenterTests` | 11 | 475 |
| 2 | `SpeechSegmentationTests` | 11 | 486 |
| 3 | `SpeechServiceTests` (+1), `SpeakControllerTests` (+2) | 3 | 489 |
| 4 | `SettingsTests` (+4) | 4 | 493 |
| 5 | `SpeechTextChunkerTests` | 10 | 503 |
| 6 | `SpeechRequestBuilderTests` | 6 | 509 |
| 7 | `MacomprendoErrorTests` (+2 parameterised cases, +1 test) | 3 | 512 |
| 8 | `EndpointSpeechServiceTests` | 11 | 523 |
| 9 | `SpeechRouterTests` | 7 | 530 |
| 10 | `SpeechTabModelTests` (+6) | 6 | 536 |
| 11 | — | 0 | **536** |

Six new suite files: `LanguageSegmenterTests`, `SpeechSegmentationTests`,
`SpeechTextChunkerTests`, `SpeechRequestBuilderTests`, `EndpointSpeechServiceTests`,
`SpeechRouterTests`. `SettingsTests.swift` and `MacomprendoErrorTests.swift` hold **free `@Test`
functions**, not `@Suite` types — that is why Tasks 4 and 7 filter on a test-function name rather
than a suite name.

**Verified facts** (checked 2026-08-26, not recalled):

- `Unicode.Scalar.Properties` has **no** `script` member — compiling
  `print(("п" as Unicode.Scalar).properties.script)` fails with
  `error: value of type 'Unicode.Scalar.Properties' has no member 'script'`. Task 1 uses
  `isAlphabetic` + block ranges, which is also what the amended spec now says.
- `EndpointURL.openAI(_:_:)` resolves all four base-URL shapes in Task 6's table, and
  `URL.host()` yields `api.openai.com` / `api.proxyapi.ru` / `localhost` for them.
- The exact JSON `JSONEncoder` emits with `[.sortedKeys, .withoutEscapingSlashes]` for the
  request body, with and without `instructions`, and the fact that non-ASCII input is emitted as
  raw UTF-8 rather than `\u` escapes (Task 6 asserts both literals).
- `SpeechTextChunker`'s **character** accounting: `"Привет мир."` is 11 characters and 20 UTF-8
  bytes, so `limit: 21` keeps `"Привет мир. Как дела?"` whole while `limit: 20` splits it — the
  test that distinguishes character from byte budgeting. Every chunker expectation in Task 5 and
  every fixture in Task 8 (`limit: 6` → `["One.", "Two.", "Three."]`) is a recorded prototype
  output.
- `LanguageSegmenter.runs`, `AVSpeechService.fallbackVoice` and the chunker were prototyped and
  executed before this plan was written; the expectations are recordings, not predictions.
- `EndpointSpeechService`, `AVSpeechService` and `SpeechRouter` as written compile clean under
  `swiftc -swift-version 6 -strict-concurrency=complete` with zero warnings, including the
  `withTaskCancellationHandler` + `withCheckedThrowingContinuation` pairing and the
  MainActor-isolated default arguments in the test helpers.
- xcodegen 2.46.0 is installed at `/opt/homebrew/bin/xcodegen`.
- Baseline suite: `Test run with 464 tests in 55 suites passed`.

**Deliberate deviations** are listed in full under "Interface additions beyond the shared map"
above: the `script`-property replacement, the merge-into-the-longer-neighbour rule, the split of
the missing-key sentence into description + recovery, the write-only API key field, the
injectable `chunkCharacterLimit`, and using `EndpointURL.openAI` for URL building. Update
`docs/superpowers/specs/2026-08-26-mixed-language-speech.md` to match once the plan is executed,
rather than letting the code drift away from it.
