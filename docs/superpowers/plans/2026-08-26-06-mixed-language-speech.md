# Macomprendo Mixed-Language Speech Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make hotkey #3 (Speak selection) intelligible for text that mixes Cyrillic and Latin
script. Two independent improvements: system voices gain per-script voice switching (offline,
free, on by default), and an optional Gemini-TTS speech source gives natively code-switching
speech to users who supply a Google AI Studio API key.

**Architecture:** Everything stays behind the existing `@MainActor protocol SpeechSynthesizing`.
`AppEnvironment.live()` injects a new `SpeechRouter` that owns both backends and dispatches per
call on `SpeechSettings.source`; `SpeakController`, `TextFeatures`, the "Speaking…" HUD and every
existing controller test are untouched. The Gemini backend is a `@MainActor` class over the
existing `any HTTPClient` seam plus one new OS seam, `AudioPlaying`. All decision-making logic
(script segmentation, utterance planning, voice fallback, text chunking, request building,
response parsing, WAV framing) lives in pure static functions so it is unit-tested without
AVFoundation, without the network and without audio hardware.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI + AppKit, AVFoundation
(`AVSpeechSynthesizer`, `AVAudioPlayer`), Foundation `JSONEncoder`/`JSONDecoder`, swift-testing,
Google Gemini Interactions API (`POST /v1beta/interactions`).

**Spec:** `docs/superpowers/specs/2026-08-26-mixed-language-speech.md`

**Shared interfaces:** `docs/superpowers/plans/2026-08-23-00-file-map-and-interfaces.md` — every
type name used here is taken verbatim from that document (including its Amendments section)
unless listed under "Interface additions beyond the shared map" below.

## Global Constraints

- Swift 6.0, strict concurrency; SwiftUI + AppKit; `platforms: [.macOS(.v14)]`; universal
  (arm64 + x86_64).
- Bundle id `com.dzamataev.macomprendo`; `DEVELOPMENT_TEAM 68QJJA7HK9`; copyright
  "© 2026 Denis Zamataev"; MIT.
- Product/module name `Macomprendo`; `LSUIElement = true`; not sandboxed; hardened runtime.
- No new SPM dependencies. The Gemini backend uses the existing `HTTPClient` seam and
  Foundation JSON coding only.
- Tests: swift-testing (`import Testing`), run with `swift test --package-path macos`.
- Layering (invariant 1): UI → Features → Services/Providers → Core. Every new file below names
  its layer. Concrete services are constructed **only** in `App/AppEnvironment.swift`.
- Every OS-facing thing sits behind a protocol declared next to its default implementation, with
  a double in `macos/Tests/MacomprendoTests/Fakes/`.
- No telemetry. The Gemini endpoint is contacted **only** when the user has selected the Gemini
  source (invariant 9). The API key lives only in the Keychain under account `speech.gemini`
  (invariant 5) and never appears in logs, settings exports or error text.
- Never log selection text, transcript text or LLM/TTS input at default level (invariant 6).
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
   `pwd && git -C /Users/frenzy/dev/macomprendo status --short && git -C /Users/frenzy/dev/macomprendo log --oneline -1`
   and confirm you are in `/Users/frenzy/dev/macomprendo`, that the tree is clean apart from
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
   tests**, all green. This plan adds **80 swift tests**; the final total is **544**.

## Assumed starting point

Plans 1–5 are merged. The following exist and are consumed verbatim: `Settings`,
`SpeechSettings`, `KeychainStoring`/`SystemKeychainStore`/`InMemoryKeychainStore`,
`MacomprendoError`, `ErrorText`, `Log`, `HTTPClient`/`HTTPRequest`/`HTTPResponse`,
`URLSessionHTTPClient`, `EndpointURL`, `WAVEncoder`, `Voice`, `SpeechSynthesizing`,
`AVSpeechService`, `SpeakController`, `Toasting`, `HUDController`/`HUDState.speaking(hint:)`,
`SettingsHolding`, `SpeechTabModel`/`SpeechTab`, `AppModel`, `AppEnvironment.live()`,
`AppEnvironment.fake()`, `ScriptedSpeech`, `ScriptedToaster`, `ScriptedSettingsHolder`,
`FakeHTTPClient`.

## Interface additions beyond the shared map

| Name | File | Layer | Why |
|---|---|---|---|
| `ScriptClass`, `TextRun`, `LanguageSegmenter` | `Services/LanguageSegmenter.swift` | Services | pure script segmentation (spec Part A) |
| `UtterancePlan` | `Services/SpeechService.swift` | Services | testable `(text, voiceID)` pairs so segmentation is unit-tested without AVFoundation |
| `AVSpeechService.qualityRank/languageRank/fallbackVoice(for:in:)/utterancePlan(text:settings:voices:minRunLength:)` | `Services/SpeechService.swift` | Services | pure helpers behind the queueing change |
| `SpeechSynthesizing.onError` | `Services/SpeechService.swift` | Services | backends that can fail need a channel to `SpeakController` |
| `SpeechSynthesizing.voices(for:)` + protocol-extension default | `Services/SpeechService.swift` | Services | the Speech tab lists the voices of the source being configured, not the active one |
| `SpeechSource` + six `SpeechSettings` fields + `SpeechSettings.defaultGeminiModel/defaultGeminiBaseURL/geminiKeychainAccount` | `Core/Settings.swift` | Core | spec "Settings schema" |
| `MacomprendoError.audioPlayback(String)`, `.speechKeyMissing` | `Core/MacomprendoError.swift` | Core | playback and missing-key failures (invariant 8) |
| `PCM16WAV` | `Providers/PCM16WAV.swift` | Providers | 16-bit sibling of `WAVEncoder` (which only takes `[Float]`) |
| `GeminiTextChunker` | `Services/GeminiTextChunker.swift` | Services | the spec calls this `GeminiSpeechService.chunks(of:limit:)`; split into its own file so the pure text logic ships and is reviewed one task before the service |
| `GeminiAudio`, `GeminiTTSParser` | `Providers/GeminiTTSParser.swift` | Providers | the single file a Gemini API shape change touches |
| `AudioPlaying`, `AVAudioPlayerPlayer` | `Services/AudioPlayer.swift` | Services | new OS seam (spec Part B step 4) |
| `GeminiVoices`, `GeminiSpeechService` | `Services/GeminiSpeechService.swift` | Services | the Gemini backend + its embedded voice catalog |
| `SpeechRouter` | `Services/SpeechRouter.swift` | Services | per-call dispatch on `SpeechSettings.source` |
| `FakeAudioPlayer` | `Tests/…/Fakes/FakeAudioPlayer.swift` | Tests | `AudioPlaying` double |
| `ScriptedSpeech.onError/failWith(_:)/availableBySource` | `Tests/…/Fakes/ScriptedSpeech.swift` | Tests | drives the new protocol members |
| `SpeechTabModel.init(speech:holder:keychain:)`, `.source`, `.geminiVoices`, `.apiKeyField`, `.keyStatus`, `.saveAPIKey()`, `.hasAPIKey()`, `.geminiPrivacyCaption` | `UI/Settings/SpeechTab.swift` | UI | spec "UI — Settings ▸ Speech" |

**Deliberate deviations from the spec, all resolved here and reflected in the tasks:**

- The spec says script classification uses `Unicode.Scalar.properties.script`. **That property
  does not exist in the Swift standard library** (verified: `error: value of type
  'Unicode.Scalar.Properties' has no member 'script'`). Task 1 uses
  `Unicode.Scalar.properties.isAlphabetic` plus explicit Unicode block ranges instead.
- The spec gives `SpeechRouter` a `@MainActor () -> Settings` closure. It does not need one:
  `speak(_:settings:)` already receives the whole `SpeechSettings`, which carries `.source`.
  Dropping the closure removes an `AppEnvironment`/`AppModel` coupling and cannot go stale.
  `voices()` therefore returns the **system** catalog and the tab uses `voices(for:)`.
- The spec puts `voices(for:)` "on the router only". It is a `SpeechSynthesizing` requirement
  with a protocol-extension default (`voices()`), so `AppEnvironment.speech` keeps its type and
  `SpeechTabModel` needs no second dependency.
- The spec says the Gemini voice catalog holds 27 names. The live docs list **30**
  (verified at <https://ai.google.dev/gemini-api/docs/speech-generation>); Task 8 embeds all 30.
- The spec's default `geminiModel` is `gemini-2.5-flash-preview-tts`. The documented curl for
  `POST /v1beta/interactions` uses `gemini-3.1-flash-tts-preview`, so that is the default here;
  Task 10 adds a Model text field so a retired model name is fixable without a rebuild.
- The spec wants Gemini Preview errors "inline". `onError` has exactly one owner
  (`SpeakController`), so Preview failures surface as the same HUD toast as hotkey #3 rather than
  as a label inside the tab; a second subscriber would need a multicast seam the spec's non-goals
  do not justify. Task 11's smoke test checks the toast.

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
git -C /Users/frenzy/dev/macomprendo status --short
git -C /Users/frenzy/dev/macomprendo log --oneline -1
```
Expected: you are in `/Users/frenzy/dev/macomprendo`; `status` prints nothing except possibly
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
git -C /Users/frenzy/dev/macomprendo status --short
git -C /Users/frenzy/dev/macomprendo log --oneline -1
```
Expected: clean tree in `/Users/frenzy/dev/macomprendo`; HEAD is
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
git -C /Users/frenzy/dev/macomprendo status --short
git -C /Users/frenzy/dev/macomprendo log --oneline -1
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
        speech.failWith(MacomprendoError.providerUnreachable(endpointName: "Gemini"))

        let expected = ErrorText.describe(MacomprendoError.providerUnreachable(endpointName: "Gemini"))
        #expect(toaster.messages == [expected])
        #expect(expected.contains("Gemini"))
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

### Task 4: `SpeechSource` and the Gemini settings fields

**Files:**
- Modify: `macos/Sources/Macomprendo/Core/Settings.swift` (Core layer)
- Modify: `macos/Tests/MacomprendoTests/Core/SettingsTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  ```swift
  enum SpeechSource: String, Codable, Sendable, CaseIterable, Identifiable {
      case system, gemini
      var id: String { rawValue }
      var displayName: String
  }

  extension SpeechSettings {
      var source: SpeechSource            // default .system
      var geminiVoice: String             // default "Kore"
      var geminiStyle: String             // default ""
      var geminiModel: String             // default SpeechSettings.defaultGeminiModel
      var geminiBaseURL: URL              // default SpeechSettings.defaultGeminiBaseURL
      var geminiAPIKeyRef: String?        // default nil
      static let defaultGeminiModel: String              // "gemini-3.1-flash-tts-preview"
      static let defaultGeminiBaseURL: URL               // https://generativelanguage.googleapis.com
      static let geminiKeychainAccount: String           // "speech.gemini"
  }
  ```

- [ ] **Step 1: Verify the working directory**

```bash
pwd
git -C /Users/frenzy/dev/macomprendo status --short
git -C /Users/frenzy/dev/macomprendo log --oneline -1
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
    #expect(speech.geminiVoice == "Kore")
    #expect(speech.geminiStyle.isEmpty)
    #expect(speech.geminiModel == "gemini-3.1-flash-tts-preview")
    #expect(speech.geminiBaseURL.absoluteString == "https://generativelanguage.googleapis.com")
    #expect(speech.geminiAPIKeyRef == nil)
}

@Test func aSpeechPayloadWithoutTheGeminiFieldsDecodesToDefaults() throws {
    let legacy = """
        {"schemaVersion":1,
         "speech":{"voiceID":"com.apple.voice.compact.en-US.Samantha",
                   "rate":0.42,"pitch":1.3,"volume":0.7}}
        """
    let settings = try Settings.migrate(Data(legacy.utf8))
    #expect(settings.speech.voiceID == "com.apple.voice.compact.en-US.Samantha")
    #expect(settings.speech.rate == 0.42)
    #expect(settings.speech.source == .system)
    #expect(settings.speech.geminiVoice == "Kore")
    #expect(settings.speech.geminiModel == SpeechSettings.defaultGeminiModel)
    #expect(settings.speech.geminiBaseURL == SpeechSettings.defaultGeminiBaseURL)
    #expect(settings.speech.geminiAPIKeyRef == nil)
}

@Test func geminiSpeechFieldsRoundTripThroughJSON() throws {
    var settings = Settings.default
    settings.speech.source = .gemini
    settings.speech.geminiVoice = "Sulafat"
    settings.speech.geminiStyle = "Read slowly and warmly"
    settings.speech.geminiModel = "gemini-2.5-pro-preview-tts"
    settings.speech.geminiBaseURL = URL(string: "https://example.test")!
    settings.speech.geminiAPIKeyRef = SpeechSettings.geminiKeychainAccount

    let encoded = try JSONEncoder().encode(settings)
    let decoded = try Settings.migrate(encoded)

    #expect(decoded.speech == settings.speech)
    // Only the Keychain account name is persisted, never the key (invariant 5).
    #expect(String(decoding: encoded, as: UTF8.self).contains("\"geminiAPIKeyRef\":\"speech.gemini\""))
}

@Test func theGeminiKeychainAccountIsStable() {
    #expect(SpeechSettings.geminiKeychainAccount == "speech.gemini")
    #expect(SpeechSource.allCases.map(\.rawValue) == ["system", "gemini"])
    #expect(SpeechSource.gemini.displayName == "Gemini")
    #expect(SpeechSource.system.displayName == "System voices")
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
    case gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "System voices"
        case .gemini: "Gemini"
        }
    }
}

struct SpeechSettings: Codable, Sendable, Equatable {
    /// The model documented for `POST /v1beta/interactions`; editable in Settings ▸ Speech so
    /// a retired preview name can be fixed without a new build.
    static let defaultGeminiModel = "gemini-3.1-flash-tts-preview"
    static let defaultGeminiBaseURL = URL(string: "https://generativelanguage.googleapis.com")!
    /// Keychain account name for the Google AI Studio key. The key itself never leaves the
    /// Keychain (invariant 5); `geminiAPIKeyRef` only records that one is stored.
    static let geminiKeychainAccount = "speech.gemini"

    var voiceID: String?
    var rate: Float
    var pitch: Float
    var volume: Float
    var source: SpeechSource
    var geminiVoice: String
    var geminiStyle: String
    var geminiModel: String
    var geminiBaseURL: URL
    var geminiAPIKeyRef: String?

    init(voiceID: String? = nil,
         rate: Float = 0.5,
         pitch: Float = 1.0,
         volume: Float = 1.0,
         source: SpeechSource = .system,
         geminiVoice: String = "Kore",
         geminiStyle: String = "",
         geminiModel: String = SpeechSettings.defaultGeminiModel,
         geminiBaseURL: URL = SpeechSettings.defaultGeminiBaseURL,
         geminiAPIKeyRef: String? = nil) {
        self.voiceID = voiceID
        self.rate = rate
        self.pitch = pitch
        self.volume = volume
        self.source = source
        self.geminiVoice = geminiVoice
        self.geminiStyle = geminiStyle
        self.geminiModel = geminiModel
        self.geminiBaseURL = geminiBaseURL
        self.geminiAPIKeyRef = geminiAPIKeyRef
    }
}

extension SpeechSettings {
    /// Hand-written so a document written before the Gemini source existed decodes to the
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
        geminiVoice = try c.decodeIfPresent(String.self, forKey: .geminiVoice) ?? d.geminiVoice
        geminiStyle = try c.decodeIfPresent(String.self, forKey: .geminiStyle) ?? d.geminiStyle
        geminiModel = try c.decodeIfPresent(String.self, forKey: .geminiModel) ?? d.geminiModel
        geminiBaseURL = try c.decodeIfPresent(URL.self, forKey: .geminiBaseURL) ?? d.geminiBaseURL
        geminiAPIKeyRef = try c.decodeIfPresent(String.self, forKey: .geminiAPIKeyRef)
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

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
git commit -m "feat(settings): add the Gemini speech source fields to SpeechSettings"
```

---

### Task 5: `PCM16WAV` and `GeminiTextChunker`

**Files:**
- Create: `macos/Sources/Macomprendo/Providers/PCM16WAV.swift` (Providers layer)
- Create: `macos/Sources/Macomprendo/Services/GeminiTextChunker.swift` (Services layer)
- Test: `macos/Tests/MacomprendoTests/Providers/PCM16WAVTests.swift`
- Test: `macos/Tests/MacomprendoTests/Services/GeminiTextChunkerTests.swift`

**Interfaces:**
- Consumes: nothing (pure Foundation).
- Produces:
  ```swift
  enum PCM16WAV {
      static func data(pcm: Data, sampleRate: Int, channels: Int = 1) -> Data
  }

  enum GeminiTextChunker {
      static let defaultByteLimit: Int                       // 3800
      static let sentenceTerminators: Set<Character>
      static let closingCharacters: Set<Character>
      static func chunks(of text: String, limit: Int = defaultByteLimit) -> [String]
      static func sentences(in text: String) -> [String]
      static func splitOversized(_ sentence: String, limit: Int) -> [String]
      static func splitWord(_ word: String, limit: Int) -> [String]
  }
  ```

> `WAVEncoder` is deliberately not reused: it takes normalised `[Float]` samples and converts
> them, while Gemini hands back bytes that are already signed 16-bit little-endian PCM. Funnelling
> those through `Float` would be a lossy round trip for no benefit.

- [ ] **Step 1: Verify the working directory**

```bash
pwd
git -C /Users/frenzy/dev/macomprendo status --short
git -C /Users/frenzy/dev/macomprendo log --oneline -1
```
Expected: clean tree; HEAD is
`feat(settings): add the Gemini speech source fields to SpeechSettings`.

- [ ] **Step 2: Write the failing tests**

Create `macos/Tests/MacomprendoTests/Providers/PCM16WAVTests.swift`:

```swift
import Foundation
import Testing
@testable import Macomprendo

@Suite struct PCM16WAVTests {
    private func uint32(_ data: Data, at offset: Int) -> UInt32 {
        let bytes = Array(data[offset..<(offset + 4)])
        return UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
    }

    private func uint16(_ data: Data, at offset: Int) -> UInt16 {
        let bytes = Array(data[offset..<(offset + 2)])
        return UInt16(bytes[0]) | UInt16(bytes[1]) << 8
    }

    private func ascii(_ data: Data, at offset: Int) -> String {
        String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
    }

    @Test func theHeaderIsFortyFourBytesOfCanonicalRIFF() {
        let wav = PCM16WAV.data(pcm: Data([1, 2, 3, 4, 5, 6]), sampleRate: 24_000)
        #expect(wav.count == 50)
        #expect(ascii(wav, at: 0) == "RIFF")
        #expect(ascii(wav, at: 8) == "WAVE")
        #expect(ascii(wav, at: 12) == "fmt ")
        #expect(ascii(wav, at: 36) == "data")
        #expect(uint32(wav, at: 4) == 42)          // 36 + dataSize
        #expect(uint32(wav, at: 16) == 16)         // PCM fmt chunk size
        #expect(uint16(wav, at: 20) == 1)          // uncompressed PCM
        #expect(uint16(wav, at: 34) == 16)         // bits per sample
    }

    @Test func theSampleRateAndByteRateAreLittleEndian() {
        let wav = PCM16WAV.data(pcm: Data([0, 0]), sampleRate: 24_000)
        #expect(uint16(wav, at: 22) == 1)                  // channels
        #expect(uint32(wav, at: 24) == 24_000)             // sample rate
        #expect(uint32(wav, at: 28) == 48_000)             // byte rate = rate * blockAlign
        #expect(uint16(wav, at: 32) == 2)                  // block align
        #expect(Array(wav[24..<28]) == [192, 93, 0, 0])
    }

    @Test func thePayloadIsCopiedVerbatim() {
        let pcm = Data([0xFF, 0x7F, 0x00, 0x80])
        let wav = PCM16WAV.data(pcm: pcm, sampleRate: 24_000)
        #expect(Data(wav[44...]) == pcm)
        #expect(uint32(wav, at: 40) == 4)
    }

    @Test func anIncompleteTrailingFrameIsDropped() {
        let wav = PCM16WAV.data(pcm: Data([1, 2, 3]), sampleRate: 24_000)
        #expect(wav.count == 46)
        #expect(uint32(wav, at: 40) == 2)
        #expect(Data(wav[44...]) == Data([1, 2]))
    }

    @Test func emptyPCMStillProducesAValidHeader() {
        let wav = PCM16WAV.data(pcm: Data(), sampleRate: 24_000)
        #expect(wav.count == 44)
        #expect(uint32(wav, at: 40) == 0)
        #expect(uint32(wav, at: 4) == 36)
    }

    @Test func stereoUpdatesBlockAlignAndByteRate() {
        let wav = PCM16WAV.data(pcm: Data([1, 2, 3, 4]), sampleRate: 48_000, channels: 2)
        #expect(uint16(wav, at: 22) == 2)
        #expect(uint16(wav, at: 32) == 4)
        #expect(uint32(wav, at: 28) == 192_000)
        #expect(uint32(wav, at: 40) == 4)
    }
}
```

Create `macos/Tests/MacomprendoTests/Services/GeminiTextChunkerTests.swift`:

```swift
import Foundation
import Testing
@testable import Macomprendo

@Suite struct GeminiTextChunkerTests {
    @Test func shortTextIsOneChunk() {
        #expect(GeminiTextChunker.chunks(of: "One. Two. Three.", limit: 100) == ["One. Two. Three."])
    }

    @Test func blankTextProducesNoChunks() {
        #expect(GeminiTextChunker.chunks(of: "", limit: 100).isEmpty)
        #expect(GeminiTextChunker.chunks(of: "   \n\t ", limit: 100).isEmpty)
    }

    @Test func sentencesAreGroupedUpToTheByteLimit() {
        // "One." + " " + "Two." is exactly 9 bytes; adding "Three." would not fit.
        #expect(GeminiTextChunker.chunks(of: "One. Two. Three.", limit: 9) == ["One. Two.", "Three."])
    }

    @Test func chunkingCountsUTF8BytesNotCharacters() {
        let text = "Привет мир. Как дела?"
        #expect("Привет мир.".utf8.count == 20)
        #expect("Привет мир.".count == 11)
        // 20 + 1 + 16 = 37 bytes would exceed the limit, so the sentences split.
        #expect(GeminiTextChunker.chunks(of: text, limit: 21) == ["Привет мир.", "Как дела?"])
        #expect(GeminiTextChunker.chunks(of: text, limit: 40) == ["Привет мир. Как дела?"])
    }

    @Test func aSentenceLongerThanTheLimitIsSplitAtWordBoundaries() {
        #expect(GeminiTextChunker.chunks(of: "alpha beta gamma delta", limit: 12)
                == ["alpha beta", "gamma delta"])
    }

    @Test func aWordLongerThanTheLimitIsSplitAtCharacterBoundaries() {
        #expect(GeminiTextChunker.chunks(of: "aaaaaaaaaaaa", limit: 5) == ["aaaaa", "aaaaa", "aa"])
        // Cyrillic characters are two bytes each, so a five-byte budget takes two of them.
        #expect(GeminiTextChunker.chunks(of: "ПриветПриветПривет", limit: 10)
                == ["Приве", "тПрив", "етПри", "вет"])
    }

    @Test func noChunkEverExceedsTheLimit() {
        let text = String(repeating: "Мама мыла раму очень тщательно. ", count: 40)
        for limit in [16, 64, 200] {
            let chunks = GeminiTextChunker.chunks(of: text, limit: limit)
            #expect(!chunks.isEmpty)
            #expect(chunks.allSatisfy { $0.utf8.count <= limit }, "limit \(limit)")
        }
    }

    @Test func sentenceSplittingKeepsClosingQuotesAndBreaksOnNewlines() {
        #expect(GeminiTextChunker.sentences(in: "He said \"Stop!\" Then left.\nNew line here")
                == ["He said \"Stop!\"", "Then left.", "New line here"])
    }

    @Test func abbreviationsAreRejoinedWhenTheyFitTheLimit() {
        // "Dr." looks like a sentence end, but the pieces are regrouped into one chunk.
        #expect(GeminiTextChunker.chunks(of: "Dr. Smith went home.", limit: 100)
                == ["Dr. Smith went home."])
    }

    @Test func aZeroLimitProducesNoChunks() {
        #expect(GeminiTextChunker.chunks(of: "anything", limit: 0).isEmpty)
        #expect(GeminiTextChunker.defaultByteLimit == 3800)
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --package-path macos --filter "PCM16WAVTests|GeminiTextChunkerTests"`
Expected: build failure — `error: cannot find 'PCM16WAV' in scope` and
`error: cannot find 'GeminiTextChunker' in scope`.

- [ ] **Step 4: Implement `PCM16WAV`**

Create `macos/Sources/Macomprendo/Providers/PCM16WAV.swift`:

```swift
import Foundation

/// Wraps already-encoded signed 16-bit little-endian PCM in a canonical 44-byte-header WAV
/// file (RIFF/WAVE, one 16-byte `fmt ` chunk, one `data` chunk).
///
/// `WAVEncoder` is the Float32 sibling: it converts normalised samples for the transcription
/// upload path. Gemini already returns 16-bit bytes, so they are framed here instead of being
/// round-tripped through `Float`.
enum PCM16WAV {
    private static let bitsPerSample = 16

    /// - Parameters:
    ///   - pcm: raw little-endian `Int16` samples, interleaved when `channels > 1`.
    ///     An incomplete trailing frame is dropped, so the header never claims bytes the
    ///     file does not have.
    ///   - sampleRate: samples per second, e.g. 24000 for Gemini TTS.
    static func data(pcm: Data, sampleRate: Int, channels: Int = 1) -> Data {
        let blockAlign = max(1, channels) * bitsPerSample / 8
        let dataSize = (pcm.count / blockAlign) * blockAlign
        let samples = pcm.prefix(dataSize)

        var out = Data(capacity: 44 + dataSize)

        // RIFF header
        out.append(ascii: "RIFF")
        out.append(littleEndian: UInt32(36 + dataSize))
        out.append(ascii: "WAVE")

        // fmt chunk (16-byte PCM variant)
        out.append(ascii: "fmt ")
        out.append(littleEndian: UInt32(16))
        out.append(littleEndian: UInt16(1))                     // PCM, uncompressed
        out.append(littleEndian: UInt16(max(1, channels)))
        out.append(littleEndian: UInt32(sampleRate))
        out.append(littleEndian: UInt32(sampleRate * blockAlign))
        out.append(littleEndian: UInt16(blockAlign))
        out.append(littleEndian: UInt16(bitsPerSample))

        // data chunk
        out.append(ascii: "data")
        out.append(littleEndian: UInt32(dataSize))
        out.append(samples)

        return out
    }
}

private extension Data {
    mutating func append(ascii string: String) {
        append(contentsOf: Array(string.utf8))
    }

    mutating func append(littleEndian value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ])
    }

    mutating func append(littleEndian value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }
}
```

- [ ] **Step 5: Implement `GeminiTextChunker`**

Create `macos/Sources/Macomprendo/Services/GeminiTextChunker.swift`:

```swift
import Foundation

/// Splits text into request-sized pieces for the Gemini TTS endpoint. Pure: no state, no I/O.
///
/// Sentences are the preferred boundary, so a chunk seam lands where a speaker would pause.
/// Sentences are regrouped greedily up to the byte budget, which means an abbreviation that
/// looks like a sentence end ("Dr.") only affects *where* a seam could fall, never the text.
/// The limit is counted in UTF-8 bytes, because that is what the API counts and because
/// Cyrillic costs two bytes per character.
enum GeminiTextChunker {
    /// Comfortably under the endpoint's per-request input budget.
    static let defaultByteLimit = 3800

    static let sentenceTerminators: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
    static let closingCharacters: Set<Character> = ["\"", "'", ")", "]", "»", "”", "’"]

    static func chunks(of text: String, limit: Int = defaultByteLimit) -> [String] {
        guard limit > 0 else { return [] }
        var chunks: [String] = []
        var current = ""

        for sentence in sentences(in: text) {
            for piece in splitOversized(sentence, limit: limit) {
                if current.isEmpty {
                    current = piece
                } else if current.utf8.count + 1 + piece.utf8.count <= limit {
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

    /// A sentence over the budget is regrouped at word boundaries.
    static func splitOversized(_ sentence: String, limit: Int) -> [String] {
        guard sentence.utf8.count > limit else { return [sentence] }
        var pieces: [String] = []
        var current = ""
        for word in sentence.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
            for fragment in splitWord(word, limit: limit) {
                if current.isEmpty {
                    current = fragment
                } else if current.utf8.count + 1 + fragment.utf8.count <= limit {
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

    /// A single word over the budget is cut at grapheme boundaries, so every fragment stays
    /// valid UTF-8. A single grapheme wider than `limit` is emitted alone and is the one case
    /// where a fragment can exceed the budget; real limits are thousands of bytes.
    static func splitWord(_ word: String, limit: Int) -> [String] {
        guard word.utf8.count > limit else { return [word] }
        var pieces: [String] = []
        var current = ""
        for character in word {
            if !current.isEmpty, current.utf8.count + String(character).utf8.count > limit {
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

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --package-path macos --filter "PCM16WAVTests|GeminiTextChunkerTests"`
Expected: PASS — 16 tests, 0 failures.

- [ ] **Step 7: Regenerate the Xcode project and check for warnings**

```bash
npm run gen
find macos/Sources macos/Tests -name '*.swift' -exec touch {} +
swift build --package-path macos 2>&1 | grep -c "warning:" || true
```
Expected: `0`.

- [ ] **Step 8: Commit**

```bash
git add macos/Sources/Macomprendo/Providers/PCM16WAV.swift \
        macos/Sources/Macomprendo/Services/GeminiTextChunker.swift \
        macos/Tests/MacomprendoTests/Providers/PCM16WAVTests.swift \
        macos/Tests/MacomprendoTests/Services/GeminiTextChunkerTests.swift \
        macos/Macomprendo.xcodeproj
git commit -m "feat(speech): add 16-bit WAV framing and byte-budget text chunking"
```

---

### Task 6: `GeminiTTSParser`

**Files:**
- Create: `macos/Sources/Macomprendo/Providers/GeminiTTSParser.swift` (Providers layer)
- Test: `macos/Tests/MacomprendoTests/Providers/GeminiTTSParserTests.swift`

**Interfaces:**
- Consumes: `HTTPRequest`, `EndpointURL`, `MacomprendoError`, `PCM16WAV` (Task 5).
- Produces:
  ```swift
  struct GeminiAudio: Equatable, Sendable {
      var data: Data          // decoded audio bytes
      var mimeType: String    // e.g. "audio/l16"
      var sampleRate: Int
      var channels: Int
  }

  enum GeminiTTSParser {
      static let path: String                 // "/v1beta/interactions"
      static let defaultMimeType: String      // "audio/l16"
      static let defaultSampleRate: Int       // 24_000
      static let defaultChannels: Int         // 1
      static func requestBody(model: String, input: String, voice: String) throws -> Data
      static func request(baseURL: URL, apiKey: String, model: String, input: String,
                          voice: String, timeout: TimeInterval) throws -> HTTPRequest
      static func parse(_ body: Data) throws -> GeminiAudio
      static func wav(from audio: GeminiAudio) -> Data
  }
  ```

**API shape — verified 2026-08-26 against the live docs, do not change without re-verifying.**
Primary shape is the **Interactions API**, which is what
<https://ai.google.dev/gemini-api/docs/speech-generation> shows as its only REST sample and which
the Gemini docs call "generally available … recommended for all the latest features and models".

Request (verbatim from the docs' curl):

```
POST https://generativelanguage.googleapis.com/v1beta/interactions
x-goog-api-key: $GEMINI_API_KEY
Content-Type: application/json

{
  "model": "gemini-3.1-flash-tts-preview",
  "input": "Say cheerfully: Have a wonderful day!",
  "response_format": { "type": "audio" },
  "generation_config": { "speech_config": [ { "voice": "Kore" } ] }
}
```

Response. The SDK exposes `interaction.output_audio`, but that field is **synthesised by the SDK**
from `steps` (verified in `googleapis/python-genai`,
`google/genai/_gaos/types/interactions/interaction.py`: "Note: this is added by the SDK", and
`_populate_output_helpers` walks `steps` in reverse looking for a `model_output` step whose
`content` holds a `{"type": "audio"}` block). The wire shape is therefore:

```json
{
  "id": "int_1",
  "model": "gemini-3.1-flash-tts-preview",
  "steps": [
    { "type": "user_input",   "content": [ { "type": "text", "text": "…" } ] },
    { "type": "model_output", "content": [
        { "type": "audio", "data": "<base64>", "mime_type": "audio/l16",
          "sample_rate": 24000, "channels": 1 } ] }
  ]
}
```

`AudioContent` fields (`type`, `data`, `mime_type`, `sample_rate`, `channels`, `uri`) are all
optional except `type`, so the parser defaults `mime_type`/`sample_rate`/`channels` to the
documented 24 kHz mono 16-bit values.

**Contingency, if the endpoint ever stops answering synchronously or the `steps` shape changes:**
switch to `POST {base}/v1beta/models/{model}:generateContent` with body
`{"contents":[{"parts":[{"text": input}]}],"generationConfig":{"responseModalities":["AUDIO"],
"speechConfig":{"voiceConfig":{"prebuiltVoiceConfig":{"voiceName": voice}}}}}` and read the audio
from `candidates[0].content.parts[0].inlineData.data` (mime type in `inlineData.mimeType`, e.g.
`audio/L16;codec=pcm;rate=24000`). The same key and the same models serve it. **Only this file
changes**; `GeminiSpeechService` never sees the difference.

- [ ] **Step 1: Verify the working directory**

```bash
pwd
git -C /Users/frenzy/dev/macomprendo status --short
git -C /Users/frenzy/dev/macomprendo log --oneline -1
```
Expected: clean tree; HEAD is
`feat(speech): add 16-bit WAV framing and byte-budget text chunking`.

- [ ] **Step 2: Write the failing test**

Create `macos/Tests/MacomprendoTests/Providers/GeminiTTSParserTests.swift`:

```swift
import Foundation
import Testing
@testable import Macomprendo

@Suite struct GeminiTTSParserTests {
    private let base = URL(string: "https://generativelanguage.googleapis.com")!

    private func response(_ json: String) -> Data { Data(json.utf8) }

    @Test func theRequestTargetsTheInteractionsEndpointWithTheAPIKeyHeader() throws {
        let request = try GeminiTTSParser.request(baseURL: base,
                                                  apiKey: "AIzaSECRET",
                                                  model: "gemini-3.1-flash-tts-preview",
                                                  input: "Hello",
                                                  voice: "Kore",
                                                  timeout: 60)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString
                == "https://generativelanguage.googleapis.com/v1beta/interactions")
        #expect(request.headers["x-goog-api-key"] == "AIzaSECRET")
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.timeout == 60)
        // The key travels in the header only, never in the body.
        #expect(!String(decoding: request.body ?? Data(), as: UTF8.self).contains("AIzaSECRET"))
    }

    @Test func theRequestBodyMatchesTheDocumentedInteractionsShape() throws {
        let body = try GeminiTTSParser.requestBody(model: "gemini-3.1-flash-tts-preview",
                                                   input: "Hello",
                                                   voice: "Kore")
        #expect(String(decoding: body, as: UTF8.self) == """
            {"generation_config":{"speech_config":[{"voice":"Kore"}]},\
            "input":"Hello","model":"gemini-3.1-flash-tts-preview",\
            "response_format":{"type":"audio"}}
            """)
    }

    @Test func nonASCIIInputIsEncodedAsRawUTF8() throws {
        let body = try GeminiTTSParser.requestBody(model: "m", input: "Cheerful: Привет!", voice: "Sulafat")
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains("\"input\":\"Cheerful: Привет!\""))
        #expect(!text.contains("\\u"))
    }

    @Test func audioIsDecodedFromTheLastModelOutputStep() throws {
        let audio = try GeminiTTSParser.parse(response("""
            {"id":"int_1","model":"gemini-3.1-flash-tts-preview","steps":[
              {"type":"user_input","content":[{"type":"text","text":"hi"}]},
              {"type":"model_output","content":[
                {"type":"text","text":"ignored"},
                {"type":"audio","data":"AQIDBA==","mime_type":"audio/l16",
                 "sample_rate":24000,"channels":1}]}]}
            """))
        #expect(audio == GeminiAudio(data: Data([1, 2, 3, 4]),
                                     mimeType: "audio/l16",
                                     sampleRate: 24_000,
                                     channels: 1))
    }

    @Test func missingFormatFieldsFallBackToTheDocumentedDefaults() throws {
        let audio = try GeminiTTSParser.parse(response("""
            {"steps":[{"type":"model_output","content":[{"type":"audio","data":"AQID"}]}]}
            """))
        #expect(audio.data == Data([1, 2, 3]))
        #expect(audio.mimeType == "audio/l16")
        #expect(audio.sampleRate == 24_000)
        #expect(audio.channels == 1)
    }

    @Test func rawPCMIsFramedAsWAVAndWAVIsPassedThrough() {
        let pcm = GeminiAudio(data: Data([1, 2, 3, 4]), mimeType: "audio/l16",
                              sampleRate: 24_000, channels: 1)
        let framed = GeminiTTSParser.wav(from: pcm)
        #expect(framed.count == 48)
        #expect(String(decoding: framed.prefix(4), as: UTF8.self) == "RIFF")

        let alreadyWAV = GeminiAudio(data: Data([0x52, 0x49, 0x46, 0x46, 9, 9]),
                                     mimeType: "audio/wav", sampleRate: 24_000, channels: 1)
        #expect(GeminiTTSParser.wav(from: alreadyWAV) == alreadyWAV.data)
    }

    @Test func aResponseWithoutAudioIsMalformed() {
        for json in ["{}",
                     #"{"steps":[]}"#,
                     #"{"steps":[{"type":"model_output","content":[{"type":"text","text":"x"}]}]}"#] {
            #expect(throws: MacomprendoError.providerStreamMalformed) {
                _ = try GeminiTTSParser.parse(Data(json.utf8))
            }
        }
    }

    @Test func undecodableOrEmptyAudioIsMalformed() {
        for json in [#"{"steps":[{"type":"model_output","content":[{"type":"audio","data":"!!!!"}]}]}"#,
                     #"{"steps":[{"type":"model_output","content":[{"type":"audio","data":""}]}]}"#,
                     "not json at all"] {
            #expect(throws: MacomprendoError.providerStreamMalformed) {
                _ = try GeminiTTSParser.parse(Data(json.utf8))
            }
        }
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --package-path macos --filter GeminiTTSParserTests`
Expected: build failure — `error: cannot find 'GeminiTTSParser' in scope` and
`error: cannot find 'GeminiAudio' in scope`.

- [ ] **Step 4: Implement the parser**

Create `macos/Sources/Macomprendo/Providers/GeminiTTSParser.swift`:

```swift
import Foundation

/// The audio block a Gemini TTS response carries.
struct GeminiAudio: Equatable, Sendable {
    var data: Data
    var mimeType: String
    var sampleRate: Int
    var channels: Int
}

/// Builds the Gemini TTS request and reads its response. The whole API shape lives here, so a
/// change to it touches exactly one file.
///
/// Shape (verified 2026-08-26 against https://ai.google.dev/gemini-api/docs/speech-generation
/// and the generated types in googleapis/python-genai):
///
///     POST {base}/v1beta/interactions
///     x-goog-api-key: <key>
///     {"model": …, "input": …, "response_format": {"type": "audio"},
///      "generation_config": {"speech_config": [{"voice": …}]}}
///
///     {"steps": [{"type": "model_output",
///                 "content": [{"type": "audio", "data": "<base64>",
///                              "mime_type": "audio/l16", "sample_rate": 24000,
///                              "channels": 1}]}]}
///
/// The SDKs' `interaction.output_audio` convenience field is derived from `steps`, not sent on
/// the wire, so this parser walks `steps` the same way the SDKs do.
enum GeminiTTSParser {
    static let path = "/v1beta/interactions"
    static let defaultMimeType = "audio/l16"
    static let defaultSampleRate = 24_000
    static let defaultChannels = 1

    // MARK: - Request

    private struct Body: Encodable {
        let model: String
        let input: String
        let responseFormat: ResponseFormat
        let generationConfig: GenerationConfig

        enum CodingKeys: String, CodingKey {
            case model, input
            case responseFormat = "response_format"
            case generationConfig = "generation_config"
        }

        struct ResponseFormat: Encodable { let type: String }

        struct GenerationConfig: Encodable {
            let speechConfig: [SpeechVoice]
            enum CodingKeys: String, CodingKey { case speechConfig = "speech_config" }
        }

        struct SpeechVoice: Encodable { let voice: String }
    }

    /// Deterministic key order so the body is assertable byte for byte in tests.
    static func requestBody(model: String, input: String, voice: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Body(model: model,
                                       input: input,
                                       responseFormat: .init(type: "audio"),
                                       generationConfig: .init(speechConfig: [.init(voice: voice)])))
    }

    /// The key goes in the `x-goog-api-key` header and nowhere else (invariant 5).
    static func request(baseURL: URL,
                        apiKey: String,
                        model: String,
                        input: String,
                        voice: String,
                        timeout: TimeInterval) throws -> HTTPRequest {
        HTTPRequest(method: "POST",
                    url: EndpointURL.join(baseURL, path),
                    headers: ["Content-Type": "application/json", "x-goog-api-key": apiKey],
                    body: try requestBody(model: model, input: input, voice: voice),
                    timeout: timeout)
    }

    // MARK: - Response

    private struct Response: Decodable {
        let steps: [Step]?

        struct Step: Decodable {
            let type: String?
            let content: [Content]?

            struct Content: Decodable {
                let type: String?
                let data: String?
                let mimeType: String?
                let sampleRate: Int?
                let channels: Int?

                enum CodingKeys: String, CodingKey {
                    case type, data, channels
                    case mimeType = "mime_type"
                    case sampleRate = "sample_rate"
                }
            }
        }
    }

    static func parse(_ body: Data) throws -> GeminiAudio {
        guard let decoded = try? JSONDecoder().decode(Response.self, from: body) else {
            throw MacomprendoError.providerStreamMalformed
        }
        let audio = (decoded.steps ?? [])
            .reversed()
            .filter { $0.type == "model_output" }
            .compactMap { $0.content?.last { $0.type == "audio" } }
            .first
        guard let audio,
              let encoded = audio.data,
              let bytes = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters]),
              !bytes.isEmpty
        else { throw MacomprendoError.providerStreamMalformed }

        return GeminiAudio(data: bytes,
                           mimeType: audio.mimeType ?? defaultMimeType,
                           sampleRate: audio.sampleRate ?? defaultSampleRate,
                           channels: audio.channels ?? defaultChannels)
    }

    /// Playable bytes: a WAV response is already framed, anything else is raw PCM.
    static func wav(from audio: GeminiAudio) -> Data {
        audio.mimeType.hasPrefix("audio/wav")
            ? audio.data
            : PCM16WAV.data(pcm: audio.data, sampleRate: audio.sampleRate, channels: audio.channels)
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --package-path macos --filter GeminiTTSParserTests`
Expected: PASS — 8 tests, 0 failures.

- [ ] **Step 6: Regenerate the Xcode project and check for warnings**

```bash
npm run gen
find macos/Sources macos/Tests -name '*.swift' -exec touch {} +
swift build --package-path macos 2>&1 | grep -c "warning:" || true
```
Expected: `0`.

- [ ] **Step 7: Commit**

```bash
git add macos/Sources/Macomprendo/Providers/GeminiTTSParser.swift \
        macos/Tests/MacomprendoTests/Providers/GeminiTTSParserTests.swift \
        macos/Macomprendo.xcodeproj
git commit -m "feat(speech): add the Gemini TTS request builder and response parser"
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
      func play(_ wavData: Data) throws
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
git -C /Users/frenzy/dev/macomprendo status --short
git -C /Users/frenzy/dev/macomprendo log --oneline -1
```
Expected: clean tree; HEAD is
`feat(speech): add the Gemini TTS request builder and response parser`.

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

and append this test at the end of the file:

```swift
@Test func theMissingGeminiKeyErrorReadsAsOneSentencePair() {
    #expect(MacomprendoError.speechKeyMissing.errorDescription == "No Gemini API key.")
    #expect(MacomprendoError.speechKeyMissing.recoverySuggestion == "Add one in Settings ▸ Speech.")
    #expect(ErrorText.describe(MacomprendoError.speechKeyMissing)
            == "No Gemini API key. Add one in Settings ▸ Speech.")
    // Playback failures are distinct from recording failures.
    #expect(MacomprendoError.audioPlayback("x").errorDescription?.contains("Playing") == true)
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --package-path macos --filter everyErrorHasDescriptionAndRecovery`
Expected: build failure — `error: type 'MacomprendoError' has no member 'audioPlayback'` and
`error: type 'MacomprendoError' has no member 'speechKeyMissing'`.

(These tests are free functions, not members of a `@Suite` type, so there is no suite name to
filter on — filter on the test function name instead.)

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
            return "No Gemini API key."
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

/// Plays one buffer of WAV data at a time and reports when it is done.
@MainActor protocol AudioPlaying: AnyObject {
    /// Called on the main actor when the current buffer finishes on its own. It is not called
    /// for `stop()`.
    var onFinished: (@MainActor () -> Void)? { get set }
    /// Replaces whatever is playing. Throws `MacomprendoError.audioPlayback` when the bytes
    /// cannot be decoded or the output device refuses to start.
    func play(_ wavData: Data) throws
    func stop()
}

/// Thin `AVAudioPlayer` wrapper. Hardware-bound glue with no logic of its own, so it carries no
/// unit test and is covered by `docs/SMOKE_TEST.md` instead (invariant 3).
@MainActor final class AVAudioPlayerPlayer: NSObject, AudioPlaying {
    var onFinished: (@MainActor () -> Void)?

    private var player: AVAudioPlayer?

    func play(_ wavData: Data) throws {
        stop()
        do {
            let player = try AVAudioPlayer(data: wavData)
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

    func play(_ wavData: Data) throws {
        if let error = playError {
            playError = nil
            throw error
        }
        played.append(wavData)
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
Expected: `Test run with 520 tests … passed`.

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

### Task 8: `GeminiSpeechService`

**Files:**
- Create: `macos/Sources/Macomprendo/Services/GeminiSpeechService.swift` (Services layer)
- Test: `macos/Tests/MacomprendoTests/Services/GeminiSpeechServiceTests.swift`

**Interfaces:**
- Consumes: `SpeechSynthesizing`, `Voice`, `SpeechSettings`, `HTTPClient`, `KeychainStoring`,
  `AudioPlaying` (Task 7), `GeminiTextChunker` (Task 5), `GeminiTTSParser` (Task 6),
  `MacomprendoError`.
- Produces:
  ```swift
  enum GeminiVoices { static let all: [Voice] }        // 30 prebuilt voices, language tag "gemini"

  @MainActor final class GeminiSpeechService: SpeechSynthesizing {
      static let endpointName: String                  // "Gemini"
      static let defaultChunkByteLimit: Int            // 3800
      static let requestTimeout: TimeInterval          // 60
      static func stylePrefix(_ style: String) -> String
      static func mapped(_ error: MacomprendoError) -> MacomprendoError
      static func isCancellation(_ error: Error) -> Bool
      init(http: any HTTPClient,
           keychain: any KeychainStoring,
           player: any AudioPlaying,
           chunkByteLimit: Int = GeminiSpeechService.defaultChunkByteLimit)
      func drain() async                               // async test hook
  }
  ```

> `chunkByteLimit` is injectable purely so the tests can force a multi-chunk queue out of a
> two-word string instead of building a 4 KB fixture. `AppEnvironment` never passes it.

- [ ] **Step 1: Verify the working directory**

```bash
pwd
git -C /Users/frenzy/dev/macomprendo status --short
git -C /Users/frenzy/dev/macomprendo log --oneline -1
```
Expected: clean tree; HEAD is
`feat(speech): add the AudioPlaying seam and playback/key error cases`.

- [ ] **Step 2: Write the failing test**

Create `macos/Tests/MacomprendoTests/Services/GeminiSpeechServiceTests.swift`:

```swift
import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct GeminiSpeechServiceTests {
    private struct Rig {
        let service: GeminiSpeechService
        let http: FakeHTTPClient
        let player: FakeAudioPlayer
        let keychain: InMemoryKeychainStore
    }

    /// A one-chunk Interactions response carrying four bytes of PCM.
    private static let audioResponse = HTTPResponse(status: 200, headers: [:], body: Data("""
        {"steps":[{"type":"model_output","content":[
          {"type":"audio","data":"AQIDBA==","mime_type":"audio/l16",
           "sample_rate":24000,"channels":1}]}]}
        """.utf8))

    /// The default six-byte budget turns "One. Two. Three." into three one-sentence chunks,
    /// which is what makes the queue observable without a 4 KB fixture.
    private func rig(withKey: Bool = true, chunkByteLimit: Int = 6) -> Rig {
        let http = FakeHTTPClient()
        http.response = Self.audioResponse
        let player = FakeAudioPlayer()
        let keychain = InMemoryKeychainStore()
        if withKey { try? keychain.set("AIzaSECRET", account: SpeechSettings.geminiKeychainAccount) }
        return Rig(service: GeminiSpeechService(http: http,
                                                keychain: keychain,
                                                player: player,
                                                chunkByteLimit: chunkByteLimit),
                   http: http, player: player, keychain: keychain)
    }

    private func settings(withKey: Bool = true, style: String = "") -> SpeechSettings {
        SpeechSettings(source: .gemini,
                       geminiVoice: "Kore",
                       geminiStyle: style,
                       geminiAPIKeyRef: withKey ? SpeechSettings.geminiKeychainAccount : nil)
    }

    private func inputs(_ http: FakeHTTPClient) -> [String] {
        http.requests.compactMap { request in
            guard let body = request.body,
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            else { return nil }
            return json["input"] as? String
        }
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
        #expect(r.player.played.count == 3)
        #expect(r.player.played.allSatisfy { String(decoding: $0.prefix(4), as: UTF8.self) == "RIFF" })
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
        #expect(r.player.played.last != nil)
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
        r.http.error = MacomprendoError.providerHTTP(status: 401, body: "API key not valid")
        var errors: [Error] = []
        r.service.onError = { errors.append($0) }

        r.service.speak("One. Two. Three.", settings: settings())
        await r.service.drain()

        #expect(errors.count == 1)
        #expect(errors.first as? MacomprendoError
                == .providerHTTP(status: 401, body: "API key not valid"))
        #expect(r.player.played.isEmpty)
        #expect(!r.service.isSpeaking)
    }

    @Test func transportFailuresAreRenamedToTheGeminiEndpoint() async {
        let r = rig()
        r.http.error = MacomprendoError.providerUnreachable(endpointName: "generativelanguage.googleapis.com")
        var errors: [Error] = []
        r.service.onError = { errors.append($0) }

        r.service.speak("Hello.", settings: settings())
        await r.service.drain()

        #expect(errors.first as? MacomprendoError == .providerUnreachable(endpointName: "Gemini"))
    }

    @Test func theStyleIsPrependedToEveryChunkAndPaidForOutOfTheBudget() async {
        // "Warm: " costs six bytes, leaving ten for the text itself.
        let r = rig(chunkByteLimit: 16)
        r.service.speak("One. Two. Three.", settings: settings(style: "  Warm  "))
        await r.service.drain()

        #expect(inputs(r.http) == ["Warm: One. Two.", "Warm: Three."])
        #expect(GeminiSpeechService.stylePrefix("") == "")
        #expect(GeminiSpeechService.stylePrefix("  ") == "")
        #expect(GeminiSpeechService.stylePrefix("Warm") == "Warm: ")
    }

    @Test func blankTextIsNotSpoken() async {
        let r = rig()
        r.service.speak("   \n ", settings: settings())
        await r.service.drain()

        #expect(r.http.requests.isEmpty)
        #expect(!r.service.isSpeaking)
    }

    @Test func theVoiceCatalogHoldsThePrebuiltGeminiVoices() {
        let r = rig()
        let voices = r.service.voices()
        #expect(voices.count == 30)
        #expect(voices.map(\.id).contains("Kore"))
        #expect(voices.map(\.id).contains("Sulafat"))
        #expect(voices.first?.id == "Zephyr")
        #expect(voices.allSatisfy { $0.language == "gemini" && $0.quality == "premium" })
        #expect(Set(voices.map(\.id)).count == 30)
        #expect(voices.first { $0.id == "Kore" }?.name == "Kore — Firm")
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --package-path macos --filter GeminiSpeechServiceTests`
Expected: build failure — `error: cannot find 'GeminiSpeechService' in scope`.

- [ ] **Step 4: Implement the service**

Create `macos/Sources/Macomprendo/Services/GeminiSpeechService.swift`:

```swift
import Foundation

/// The prebuilt Gemini TTS voices, embedded as data — the API exposes no list endpoint and no
/// network call is made to populate the picker. Names and style descriptors verified
/// 2026-08-26 against https://ai.google.dev/gemini-api/docs/speech-generation. Drift is
/// cosmetic: an unknown name simply produces an HTTP error, surfaced like any other.
enum GeminiVoices {
    static let all: [Voice] = [
        ("Zephyr", "Bright"), ("Puck", "Upbeat"), ("Charon", "Informative"), ("Kore", "Firm"),
        ("Fenrir", "Excitable"), ("Leda", "Youthful"), ("Orus", "Firm"), ("Aoede", "Breezy"),
        ("Callirrhoe", "Easy-going"), ("Autonoe", "Bright"), ("Enceladus", "Breathy"),
        ("Iapetus", "Clear"), ("Umbriel", "Easy-going"), ("Algieba", "Smooth"),
        ("Despina", "Smooth"), ("Erinome", "Clear"), ("Algenib", "Gravelly"),
        ("Rasalgethi", "Informative"), ("Laomedeia", "Upbeat"), ("Achernar", "Soft"),
        ("Alnilam", "Firm"), ("Schedar", "Even"), ("Gacrux", "Mature"),
        ("Pulcherrima", "Forward"), ("Achird", "Friendly"), ("Zubenelgenubi", "Casual"),
        ("Vindemiatrix", "Gentle"), ("Sadachbia", "Lively"), ("Sadaltager", "Knowledgeable"),
        ("Sulafat", "Warm")
    ].map { name, style in
        // `id` is the wire name written into `settings.speech.geminiVoice`; `name` is display
        // only. The "gemini" language tag keeps these out of the system voice groups.
        Voice(id: name, name: "\(name) — \(style)", language: "gemini", quality: "premium")
    }
}

/// Speaks text with Google's Gemini TTS models: one HTTP request per ≤3800-byte chunk, played
/// back sequentially with a single chunk of prefetch, so chunk N+1 is already in flight while
/// chunk N plays. The selection text leaves the machine only while this backend is selected
/// (invariant 9) and is never logged (invariant 6).
@MainActor final class GeminiSpeechService: SpeechSynthesizing {
    /// Shown in `providerUnreachable`; the raw host name would be meaningless to a user.
    static let endpointName = "Gemini"
    static let defaultChunkByteLimit = 3800
    /// Synthesising a few thousand characters is slow; far above the 10 s used for metadata.
    static let requestTimeout: TimeInterval = 60

    private(set) var isSpeaking = false
    var onStateChange: (@MainActor () -> Void)?
    var onError: (@MainActor (Error) -> Void)?

    private let http: any HTTPClient
    private let keychain: any KeychainStoring
    private let player: any AudioPlaying
    /// Injectable only so tests can force a multi-chunk queue out of a short string.
    private let chunkByteLimit: Int
    private var task: Task<Void, Never>?
    private var playback: CheckedContinuation<Void, Error>?
    /// Bumped by every `speak`/`stop` so a superseded task cannot clobber the new state.
    private var generation = 0

    init(http: any HTTPClient,
         keychain: any KeychainStoring,
         player: any AudioPlaying,
         chunkByteLimit: Int = GeminiSpeechService.defaultChunkByteLimit) {
        self.http = http
        self.keychain = keychain
        self.player = player
        self.chunkByteLimit = chunkByteLimit
    }

    func voices() -> [Voice] { GeminiVoices.all }

    func speak(_ text: String, settings: SpeechSettings) {
        cancelCurrent()
        generation += 1
        let generation = self.generation

        // The style instruction is billed against the same byte budget as the text.
        let prefix = Self.stylePrefix(settings.geminiStyle)
        let limit = max(1, chunkByteLimit - prefix.utf8.count)
        let chunks = GeminiTextChunker.chunks(of: text, limit: limit).map { prefix + $0 }
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

    // MARK: - Pure helpers

    /// Gemini TTS has no rate/pitch parameters; the style is a natural-language instruction
    /// prepended to each chunk.
    static func stylePrefix(_ style: String) -> String {
        let trimmed = style.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : trimmed + ": "
    }

    /// `HTTPClient` names the host it could not reach; the user configured "Gemini".
    static func mapped(_ error: MacomprendoError) -> MacomprendoError {
        if case .providerUnreachable = error {
            return .providerUnreachable(endpointName: endpointName)
        }
        return error
    }

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

    /// A missing or blank key fails before anything is sent: unlike the LLM endpoints, Gemini
    /// has no useful unauthenticated behaviour to fall through to.
    private func apiKey(_ settings: SpeechSettings) throws -> String {
        guard let account = settings.geminiAPIKeyRef,
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
            let wav = try await current.value
            try Task.checkCancellation()
            try await playAndWait(wav)
        }
    }

    private func fetch(_ chunk: String, key: String, settings: SpeechSettings) -> Task<Data, Error> {
        let http = self.http
        return Task {
            let request = try GeminiTTSParser.request(baseURL: settings.geminiBaseURL,
                                                      apiKey: key,
                                                      model: settings.geminiModel,
                                                      input: chunk,
                                                      voice: settings.geminiVoice,
                                                      timeout: Self.requestTimeout)
            do {
                let response = try await http.send(request)
                return GeminiTTSParser.wav(from: try GeminiTTSParser.parse(response.body))
            } catch let error as MacomprendoError {
                throw Self.mapped(error)
            }
        }
    }

    private func playAndWait(_ wav: Data) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                playback = continuation
                player.onFinished = { [weak self] in self?.resumePlayback(throwing: nil) }
                do { try player.play(wav) } catch { resumePlayback(throwing: error) }
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

Run: `swift test --package-path macos --filter GeminiSpeechServiceTests`
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
git add macos/Sources/Macomprendo/Services/GeminiSpeechService.swift \
        macos/Tests/MacomprendoTests/Services/GeminiSpeechServiceTests.swift \
        macos/Macomprendo.xcodeproj
git commit -m "feat(speech): add the Gemini TTS speech backend"
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
  `GeminiSpeechService` (Task 8), `AVAudioPlayerPlayer` (Task 7).
- Produces:
  ```swift
  extension SpeechSynthesizing {
      func voices(for source: SpeechSource) -> [Voice]     // protocol requirement + default
  }

  @MainActor final class SpeechRouter: SpeechSynthesizing {
      init(system: any SpeechSynthesizing, gemini: any SpeechSynthesizing)
  }
  ```

- [ ] **Step 1: Verify the working directory**

```bash
pwd
git -C /Users/frenzy/dev/macomprendo status --short
git -C /Users/frenzy/dev/macomprendo log --oneline -1
```
Expected: clean tree; HEAD is `feat(speech): add the Gemini TTS speech backend`.

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
        let gemini: ScriptedSpeech
    }

    private func rig() -> Rig {
        let system = ScriptedSpeech()
        system.available = [Voice(id: "en.alex", name: "Alex", language: "en-US", quality: "default")]
        let gemini = ScriptedSpeech()
        gemini.available = [Voice(id: "Kore", name: "Kore — Firm", language: "gemini", quality: "premium")]
        return Rig(router: SpeechRouter(system: system, gemini: gemini), system: system, gemini: gemini)
    }

    private func settings(_ source: SpeechSource) -> SpeechSettings {
        SpeechSettings(voiceID: "en.alex", source: source)
    }

    @Test func speakGoesToTheSystemBackendByDefault() {
        let r = rig()
        r.router.speak("hello", settings: settings(.system))
        #expect(r.system.spoken.map(\.text) == ["hello"])
        #expect(r.gemini.spoken.isEmpty)
    }

    @Test func speakGoesToTheGeminiBackendWhenSelected() {
        let r = rig()
        r.router.speak("hello", settings: settings(.gemini))
        #expect(r.gemini.spoken.map(\.text) == ["hello"])
        #expect(r.system.spoken.isEmpty)
        // Switching source mid-utterance must not orphan the other backend's audio.
        #expect(r.system.stopCount == 1)
    }

    @Test func stopStopsBothBackends() {
        let r = rig()
        r.router.speak("hello", settings: settings(.gemini))
        r.router.stop()
        #expect(r.system.stopCount == 2)   // once on speak, once on stop
        #expect(r.gemini.stopCount == 1)
    }

    @Test func isSpeakingIsTrueWhenEitherBackendSpeaks() {
        let r = rig()
        #expect(!r.router.isSpeaking)
        r.router.speak("hello", settings: settings(.gemini))
        #expect(r.router.isSpeaking)
        r.gemini.finish()
        #expect(!r.router.isSpeaking)
    }

    @Test func stateChangesFromBothBackendsAreRepublished() {
        let r = rig()
        var changes = 0
        r.router.onStateChange = { changes += 1 }
        r.system.finish()
        r.gemini.finish()
        #expect(changes == 2)
    }

    @Test func errorsFromBothBackendsAreRepublished() {
        let r = rig()
        var errors: [Error] = []
        r.router.onError = { errors.append($0) }
        r.system.failWith(MacomprendoError.audioPlayback("x"))
        r.gemini.failWith(MacomprendoError.speechKeyMissing)
        #expect(errors.count == 2)
        #expect(errors.last as? MacomprendoError == .speechKeyMissing)
    }

    @Test func voicesForASourceIgnoreTheCurrentSelection() {
        let r = rig()
        #expect(r.router.voices(for: .system).map(\.id) == ["en.alex"])
        #expect(r.router.voices(for: .gemini).map(\.id) == ["Kore"])
        // A plain backend only knows its own catalog, whatever source is asked for.
        #expect(r.gemini.voices(for: .system).map(\.id) == ["Kore"])
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
    private let gemini: any SpeechSynthesizing

    init(system: any SpeechSynthesizing, gemini: any SpeechSynthesizing) {
        self.system = system
        self.gemini = gemini
        // Fan-in: both backends report through the router's single pair of hooks.
        for backend in [system, gemini] {
            backend.onStateChange = { [weak self] in self?.onStateChange?() }
            backend.onError = { [weak self] error in self?.onError?(error) }
        }
    }

    var isSpeaking: Bool { system.isSpeaking || gemini.isSpeaking }

    /// The neutral catalog. Settings ▸ Speech asks for a specific source with `voices(for:)`.
    func voices() -> [Voice] { system.voices() }

    func voices(for source: SpeechSource) -> [Voice] { backend(for: source).voices() }

    func speak(_ text: String, settings: SpeechSettings) {
        // Stopping the other backend first means switching the source mid-utterance cannot
        // leave orphaned audio playing behind the new one.
        backend(for: settings.source == .gemini ? .system : .gemini).stop()
        backend(for: settings.source).speak(text, settings: settings)
    }

    func stop() {
        system.stop()
        gemini.stop()
    }

    private func backend(for source: SpeechSource) -> any SpeechSynthesizing {
        source == .gemini ? gemini : system
    }
}
```

- [ ] **Step 6: Build the router in the composition root**

In `macos/Sources/Macomprendo/App/AppEnvironment.swift`, replace the line
`speech: AVSpeechService(),` inside `live()` with:

```swift
            speech: SpeechRouter(
                system: AVSpeechService(),
                gemini: GeminiSpeechService(http: http,
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
git commit -m "feat(speech): route speech to the system or Gemini backend per settings"
```

---

### Task 10: Settings ▸ Speech — source picker and the Gemini section

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
      static let geminiPrivacyCaption: String
      @Published private(set) var groups: [VoiceGroup]
      @Published private(set) var geminiVoices: [Voice]
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
git -C /Users/frenzy/dev/macomprendo status --short
git -C /Users/frenzy/dev/macomprendo log --oneline -1
```
Expected: clean tree; HEAD is
`feat(speech): route speech to the system or Gemini backend per settings`.

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

    private let geminiCatalog = [
        Voice(id: "Kore", name: "Kore — Firm", language: "gemini", quality: "premium"),
        Voice(id: "Puck", name: "Puck — Upbeat", language: "gemini", quality: "premium"),
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
        speech.availableBySource = [.system: voices, .gemini: geminiCatalog]
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

    // MARK: the Gemini source

    @Test func theSourceBindingWritesThroughToSettings() {
        let holder = ScriptedSettingsHolder()
        let tab = model(holder: holder)
        #expect(tab.source == .system)

        tab.source = .gemini

        #expect(holder.settings.speech.source == .gemini)
        #expect(tab.source == .gemini)
    }

    @Test func geminiVoicesComeFromTheGeminiSource() {
        let speech = ScriptedSpeech()
        speech.availableBySource = [.system: voices, .gemini: geminiCatalog]
        let tab = model(speech: speech)
        #expect(tab.geminiVoices.map(\.id) == ["Kore", "Puck"])
        #expect(tab.groups.flatMap { $0.voices.map(\.id) }.sorted() == ["v.en1", "v.en2", "v.fr"])
    }

    @Test func savingAnAPIKeyStoresItInTheKeychainAndRecordsTheReference() throws {
        let holder = ScriptedSettingsHolder()
        let keychain = InMemoryKeychainStore()
        let tab = model(holder: holder, keychain: keychain)

        tab.apiKeyField = "  AIzaSECRET  "
        tab.saveAPIKey()

        #expect(try keychain.get(account: SpeechSettings.geminiKeychainAccount) == "AIzaSECRET")
        #expect(holder.settings.speech.geminiAPIKeyRef == SpeechSettings.geminiKeychainAccount)
        #expect(tab.hasAPIKey())
    }

    @Test func savingAnEmptyKeyDeletesItAndClearsTheReference() throws {
        let holder = ScriptedSettingsHolder()
        let keychain = InMemoryKeychainStore()
        try keychain.set("AIzaOLD", account: SpeechSettings.geminiKeychainAccount)
        holder.settings.speech.geminiAPIKeyRef = SpeechSettings.geminiKeychainAccount
        let tab = model(holder: holder, keychain: keychain)

        tab.apiKeyField = "   "
        tab.saveAPIKey()

        #expect(try keychain.get(account: SpeechSettings.geminiKeychainAccount) == nil)
        #expect(holder.settings.speech.geminiAPIKeyRef == nil)
        #expect(!tab.hasAPIKey())
    }

    @Test func theAPIKeyFieldIsClearedAfterSaving() {
        let tab = model()
        tab.apiKeyField = "AIzaSECRET"
        tab.saveAPIKey()

        #expect(tab.apiKeyField.isEmpty)
        #expect(!tab.keyStatus.isEmpty)
        #expect(!tab.keyStatus.contains("AIza"))
    }

    @Test func thePrivacyCaptionNamesGoogleAndTheFreeTier() {
        #expect(SpeechTabModel.geminiPrivacyCaption == """
            Selected text is sent to Google when this source is active. On the free API tier \
            Google may use submitted text to improve its products.
            """)
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

    static let geminiPrivacyCaption = """
        Selected text is sent to Google when this source is active. On the free API tier \
        Google may use submitted text to improve its products.
        """

    @Published private(set) var groups: [VoiceGroup] = []
    @Published private(set) var geminiVoices: [Voice] = []
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
        geminiVoices = speech.voices(for: .gemini)
    }

    /// For the Gemini source this performs a real network call and therefore doubles as the
    /// connection test; failures arrive as a toast through `SpeakController`'s `onError` hook.
    func preview() {
        speech.speak(Self.sampleText, settings: holder.settings.speech)
    }

    func hasAPIKey() -> Bool {
        holder.settings.speech.geminiAPIKeyRef != nil
    }

    func saveAPIKey() {
        let account = SpeechSettings.geminiKeychainAccount
        let key = apiKeyField.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            try? keychain.delete(account: account)
            holder.settings.speech.geminiAPIKeyRef = nil
            keyStatus = "Key removed."
        } else {
            try? keychain.set(key, account: account)
            holder.settings.speech.geminiAPIKeyRef = account
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
                geminiSection
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

            // Rate, pitch and volume are AVSpeechSynthesizer parameters; Gemini TTS has none.
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

    private var geminiSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Voice").font(.headline)
            List(selection: geminiVoiceSelection) {
                ForEach(model.geminiVoices) { voice in
                    Text(voice.name).tag(voice.id)
                }
            }
            .frame(minHeight: 160)

            Form {
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
                TextField("Style", text: $app.settings.speech.geminiStyle,
                          prompt: Text("e.g. Read this cheerfully"))
                TextField("Model", text: $app.settings.speech.geminiModel)
            }
            .formStyle(.grouped)

            Text(SpeechTabModel.geminiPrivacyCaption)
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

    private var geminiVoiceSelection: Binding<String?> {
        Binding(get: { app.settings.speech.geminiVoice },
                set: { app.settings.speech.geminiVoice = $0 ?? "Kore" })
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
Expected: `Test run with 544 tests … passed`.

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
git commit -m "feat(settings): add a speech source picker and the Gemini section"
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
git -C /Users/frenzy/dev/macomprendo status --short
git -C /Users/frenzy/dev/macomprendo log --oneline -1
```
Expected: clean tree; HEAD is
`feat(settings): add a speech source picker and the Gemini section`.

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

## Gemini speech source (hotkey #3, ⌥S)

Setup: a Google AI Studio API key. Settings ▸ Speech ▸ Speech source = "Gemini".

- [ ] With no key saved, press Preview: a toast reads
      "No Gemini API key. Add one in Settings ▸ Speech." and nothing plays.
- [ ] Paste a **wrong** key, press "Save key", press Preview: a toast names the HTTP status
      returned by Google; nothing plays; the app stays responsive.
- [ ] Paste the real key and press "Save key": the field clears immediately, the caption reads
      "Key saved to the Keychain.", and the key is **not** visible anywhere in the UI.
      Confirm with Keychain Access that an item `speech.gemini` exists for service
      `com.dzamataev.macomprendo`.
- [ ] Press Preview: the sample sentence plays in the selected voice within a few seconds.
- [ ] Change the voice in the list and press Preview again: the voice audibly changes.
- [ ] Type "Read this slowly and sadly" into Style and press Preview: the delivery changes.
      Clear the Style field and press Preview: normal delivery returns.
- [ ] The rate/pitch/volume sliders are **not** shown while Gemini is selected; switch back to
      "System voices" and they reappear.
- [ ] Select a mixed Russian/English paragraph in TextEdit and press ⌥S: it is read by one
      natural voice that switches languages mid-sentence without changing timbre.
- [ ] The "Speaking…" HUD is visible from the moment ⌥S is pressed until the last chunk ends,
      including the gaps between chunks of a long selection.
- [ ] Select five or more paragraphs (over ~4000 characters) and press ⌥S: playback is
      continuous, in order, with only a short gap between chunks.
- [ ] Press ⌥S again mid-audio: playback stops within a second, the HUD disappears, and **no**
      error toast appears.
- [ ] Turn Wi-Fi off and press ⌥S: a toast reads `Could not reach "Gemini".` with its recovery
      suggestion. Turn Wi-Fi back on.
- [ ] Switch the source back to "System voices" while Gemini audio is playing: the Gemini audio
      stops; the next ⌥S uses a system voice.
- [ ] Clear the API key field and press "Save key": the caption reads "Key removed." and the
      Keychain item is gone.
- [ ] Open Console.app filtered on subsystem `com.dzamataev.macomprendo` and repeat a ⌥S with
      Gemini selected: **no** log line contains the selected text or the API key.
```

- [ ] **Step 3: Update the changelog**

In `CHANGELOG.md`, add these bullets at the end of the `### Added` list under `## [Unreleased]`:

```markdown
- Mixed-language speech: a selection that mixes Cyrillic and Latin text is now split at
  script boundaries and read by a matching system voice per stretch, so Russian and
  English in one paragraph are both intelligible. A single foreign word no longer
  switches the voice.
- Optional Gemini speech source: with a Google AI Studio API key, Settings ▸ Speech can
  read selections with Google's Gemini TTS voices, which code-switch naturally. Choose
  from 30 prebuilt voices and add an optional style instruction. The key is stored in the
  login Keychain, and selected text is sent to Google only while this source is active.
```

- [ ] **Step 4: Run the full suite and a release build**

```bash
swift test --package-path macos
```
Expected: `Test run with 544 tests … passed`.

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
| Goal 2 — optional Gemini-TTS source | 4–10 |
| Goal 3 — `SpeakController`, "Speaking…" HUD and hotkey #3 unchanged | 9 (router behind the same protocol; Tasks 3/9 re-run `SpeakControllerTests`/`TextFeaturesTests` unchanged) |
| Goal 4 — failures user-visible with recovery text; text sent to Google only when selected | 3, 7, 8, 9 |
| Part A — `LanguageSegmenter`, `ScriptClass`, `TextRun`, `runs(in:minRunLength:)`, default 20 | 1 |
| Part A — neutral attachment, min-run merging, unknown scripts never crash or flip the voice | 1 |
| Part A — `AVSpeechService.speak` one-utterance fast path, per-run queueing, `fallbackVoice(for:in:)` with premium > enhanced > default, rate/pitch/volume on every utterance, `isSpeaking` until the last utterance finishes | 2 |
| Part B step 1 — chunking at sentence boundaries into ≤3800 UTF-8 bytes, word-boundary split for oversize sentences | 5 |
| Part B step 2 — POST to the Interactions API with `x-goog-api-key`, isolated in `GeminiTTSParser` | 6 |
| Part B step 3 — base64 PCM decode + WAV wrapping in a `PCM16WAV` sibling of `WAVEncoder` | 5, 6 |
| Part B step 4 — `AudioPlaying`/`AVAudioPlayerPlayer`, sequential playback with single prefetch | 7, 8 |
| Part B step 5 — `stop()` cancels the task and the player; `isSpeaking` lifecycle | 8 |
| Part B step 6 — fixed prebuilt voice catalog, no network call | 8 |
| Part B — style prefix ("`<style>: <text>`") | 8 |
| Protocol change — `SpeechSynthesizing.onError`, `SpeakController` toast, `ScriptedSpeech.failWith(_:)` | 3 |
| Router — both backends, per-call dispatch, `stop()` stops both, callback fan-in, `voices(for:)` | 9 |
| Router — `AppEnvironment.live()` builds it, `fake()` untouched | 9 |
| Settings schema — six new fields, all `decodeIfPresent ?? default` | 4 |
| Settings schema — key only in the Keychain under `speech.gemini` | 4, 8, 10 |
| UI — source picker, system section unchanged, Gemini voice picker, SecureField, Style field, Preview, sliders hidden, privacy caption | 10 |
| Errors — missing key, HTTP mapping to endpoint name "Gemini", silent cancellation, one error per queue | 7, 8 |
| Testing — segmenter, static helpers, chunker, parser, service with fakes, router, migration, `SpeakControllerTests` unchanged | 1–10 |
| Testing — hardware/network-bound paths in SMOKE_TEST.md | 11 |
| Open item 1 — re-verify the API shape against live docs | 6 (verified 2026-08-26; sources cited in the task) |
| Open item 2 — `generateContent` contingency documented | 6 |
| Open item 3 — embed the current voice names | 8 (30, not 27) |

**Test-count ledger**

| Task | Suite(s) | New tests | Running total |
|---|---|---|---|
| — | baseline | — | 464 |
| 1 | `LanguageSegmenterTests` | 11 | 475 |
| 2 | `SpeechSegmentationTests` | 11 | 486 |
| 3 | `SpeechServiceTests` (+1), `SpeakControllerTests` (+2) | 3 | 489 |
| 4 | `SettingsTests` (+4) | 4 | 493 |
| 5 | `PCM16WAVTests` (6), `GeminiTextChunkerTests` (10) | 16 | 509 |
| 6 | `GeminiTTSParserTests` | 8 | 517 |
| 7 | `MacomprendoErrorTests` (+2 parameterised cases, +1 test) | 3 | 520 |
| 8 | `GeminiSpeechServiceTests` | 11 | 531 |
| 9 | `SpeechRouterTests` | 7 | 538 |
| 10 | `SpeechTabModelTests` (+6) | 6 | 544 |
| 11 | — | 0 | **544** |

**Verified third-party facts** (checked 2026-08-26, not recalled):

- `Unicode.Scalar.Properties` has **no** `script` member — compiling
  `print(("п" as Unicode.Scalar).properties.script)` fails with
  `error: value of type 'Unicode.Scalar.Properties' has no member 'script'`. Task 1 uses
  `isAlphabetic` + block ranges instead of the spec's suggestion.
- Gemini TTS REST endpoint, headers and request body: the single REST sample on
  <https://ai.google.dev/gemini-api/docs/speech-generation> (Task 6 quotes it verbatim).
- Gemini TTS response wire shape: `steps[].content[]` with `{"type":"audio", "data",
  "mime_type", "sample_rate", "channels"}`, derived from
  `googleapis/python-genai` `google/genai/_gaos/types/interactions/{interaction,audiocontent,
  modeloutputstep}.py` — `output_audio` is documented there as "added by the SDK" and is computed
  by walking `steps`, so it is **not** a wire field.
- TTS model IDs `gemini-3.1-flash-tts-preview`, `gemini-2.5-flash-preview-tts`,
  `gemini-2.5-pro-preview-tts` (<https://ai.google.dev/gemini-api/docs/models>).
- The prebuilt voice list has **30** entries, quoted with their style descriptors in Task 8.
- xcodegen 2.46.0 is installed at `/opt/homebrew/bin/xcodegen`.
- Baseline suite: `Test run with 464 tests in 55 suites passed`.
- The exact JSON emitted by `JSONEncoder` with `[.sortedKeys, .withoutEscapingSlashes]` for the
  request body, and the fact that non-ASCII input is emitted as raw UTF-8 rather than `\u`
  escapes (Task 6's `theRequestBodyMatchesTheDocumentedInteractionsShape` asserts the literal).
- `LanguageSegmenter.runs`, `GeminiTextChunker.chunks`, `PCM16WAV.data`,
  `AVSpeechService.fallbackVoice` and `GeminiTTSParser.parse` were all prototyped and executed
  before this plan was written; every expected value in the tests above is a recorded output, not
  a prediction.
- `GeminiSpeechService`, `AVSpeechService` and `SpeechRouter` as written compile clean under
  `swiftc -swift-version 6 -strict-concurrency=complete` with zero warnings.

**Deliberate deviations** are listed in full under "Interface additions beyond the shared map"
above: the `script` property replacement, the settings-free `SpeechRouter`, `voices(for:)` as a
protocol requirement with a default, 30 voices instead of 27, `gemini-3.1-flash-tts-preview` as
the default model plus a Model text field, `GeminiTextChunker` as its own type rather than
`GeminiSpeechService.chunks(of:limit:)`, and Preview errors arriving as a HUD toast rather than
an inline label. Update `docs/superpowers/specs/2026-08-26-mixed-language-speech.md` to match
once the plan is executed, rather than letting the code drift away from it.
