# Glossary Packs and Normalisation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the glossary — plain-text packs in a user directory, a `packs.json` naming what is
on, and canonical-form normalisation that rewrites recognised terms under every backend.

**Architecture:** `GlossaryPack` and `Normalizer` are pure Core types with no I/O. `GlossaryStore`
is a Service behind a protocol, owning the directory, seeding, and `packs.json`. The two dictation
controllers call the normaliser between transcription and insertion, and pass both texts to
history.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI, Foundation, Swift Testing, SwiftPM, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-09-17-glossary-packs-and-normalisation.md`
**ADRs:** `0012-vocabulary-packs-as-plain-text-files`, `0013-glossary-reaches-each-backend-differently`
**Depends on:** `2026-09-17-01-corpus-capture.md` — `raw_text` must exist before normalisation can
overwrite `text`. Do not start this plan until that one is merged.

## Global Constraints

- macOS 14+, Swift 6 strict concurrency; controllers and views are `@MainActor`, the store is an
  actor or a `Sendable` value type.
- Dependencies point downward only: UI → Features → Services → Core. `Normalizer` and
  `GlossaryPack` import nothing above Core. Construct `GlossaryStore` only in `AppEnvironment`.
- `Settings.currentSchemaVersion` must NOT move: `glossaryEnabled` and `glossaryManualTerms` are
  decoded with `decodeIfPresent`.
- The pack file format is a published contract (ADR-0012). Parsing must tolerate anything without
  throwing: a malformed line is skipped and counted, never fatal.
- The app writes a pack file only on Reset or through the editor. Toggling a pack rewrites
  `packs.json` and nothing else.
- Seeding never enables anything. `packs.json` starts empty; the first-run offer is the only path
  that fills it, and declining must not ask again.
- Never log transcript text at default level; glossary terms are user content and follow the same
  rule.
- Every new user-visible failure is a `MacomprendoError` with description and recovery text. An
  unreadable `packs.json` is a message, not a thrown error — dictation must keep working.
- TDD is mandatory: add each failing test, observe the expected RED, then the minimum production
  code.
- Invariant 17: the bundled `Resources/Vocabulary` directory must be declared in **both**
  `macos/Package.swift` (`resources:`) and `macos/project.yml` (`excludes:` plus a
  `type: folder, buildPhase: resources` entry). Check the existing `Resources/Icons` lines as the
  template — there are three places, not two.

## File map

- `Core/GlossaryPack.swift`: the parsed pack, its terms, the line parser and serialiser.
- `Core/GlossaryPackConfig.swift`: `packs.json` decoding and encoding.
- `Core/Glossary.swift`: the flattened keyed set built from packs plus the manual list, carrying
  each term's owning pack.
- `Core/Normalizer.swift`: keying, window matching, rewrites with ranges and provenance.
- `Core/Settings.swift`: `glossaryEnabled`, `glossaryManualTerms`.
- `Services/GlossaryStore.swift`: protocol plus directory-backed implementation.
- `Resources/Vocabulary/*.txt` + `README.md`: the bundled factory packs.
- `Features/DictationController.swift`, `Features/DictationCapture.swift`: normalise, pass both
  texts to history.
- `UI/Settings/DictationTab.swift`: the Glossary section and the pack editor.
- `App/AppEnvironment.swift`: store construction.
- `Tests/…/Fakes/FakeGlossaryStore.swift`.

---

### Task 1: The pack file format

**Files:**
- Create: `macos/Sources/Macomprendo/Core/GlossaryPack.swift`
- Create: `macos/Tests/MacomprendoTests/Core/GlossaryPackTests.swift`

**Interfaces:**
- Produces: `GlossaryTerm` (canonical spelling plus Cyrillic forms), `GlossaryPack` (name, terms,
  skipped-line count), `GlossaryPack.parse(_:name:)`, `GlossaryPack.serialise`.
- Consumes: nothing.

**Done — commit `6744de3`.** 15 tests. Two findings worth carrying forward:
- Byte-identical round-trip is implemented by keeping the parsed source text on the pack and
  dropping it in `terms.didSet` when a term actually changes. Later tasks must not assume
  `serialise()` renders from `terms`; it usually returns the original file.
- A form list of only separators (`jq = , ,`) parses as a valid term with zero forms, which the
  spec does not decide either way. Left untested deliberately rather than pinning a guess.

- [ ] **Step 1: Write failing parser tests**

```swift
@Test func parsesTermsAndIgnoresCommentsAndBlanks() {
    let pack = GlossaryPack.parse("""
    # pack: typescript
    # a comment

    jq
    git rebase
    """, name: "typescript")
    #expect(pack.terms.map(\.canonical) == ["jq", "git rebase"])
}

@Test func parsesCyrillicForms() {
    let pack = GlossaryPack.parse("TextEditor = текст-эдитор, текстэдитор", name: "p")
    #expect(pack.terms.first?.canonical == "TextEditor")
    #expect(pack.terms.first?.cyrillicForms == ["текст-эдитор", "текстэдитор"])
}

@Test func duplicateTermKeepsTheFirst() { /* two `jq` lines yield one term */ }
@Test func malformedLinesAreSkippedAndCounted() { /* e.g. a line that is only `=` */ }
@Test func roundTripIsByteIdentical() {
    // parse a file with comments, blank lines and odd spacing, serialise it, compare to input
}
```

- [ ] **Step 2: Implement the parser**

Interior whitespace is significant (`git rebase` is one term); surrounding whitespace is trimmed.
A line is malformed when it has an `=` with an empty left or right side. Serialisation returns the
original text unless a term was changed, because the editor writes the file's text directly.

- [ ] **Step 3: Run `npm run test:swift` and confirm green**

---

### Task 2: `packs.json`

**Files:**
- Create: `macos/Sources/Macomprendo/Core/GlossaryPackConfig.swift`
- Create: `macos/Tests/MacomprendoTests/Core/GlossaryPackConfigTests.swift`

**Interfaces:**
- Produces: `GlossaryPackConfig` with `enabled: [String]`, `decode(from:) -> Outcome` (the
  config plus an optional message — decoding never throws), and `encoded() -> Data`.

**Done — commit `dd9b00f`.** 12 tests. Carry forward:
- A **missing** file reports no message (it is the seeded state); empty or malformed bytes do.
- The message never quotes the decoder error, which would leak file contents (invariant 6).
- `packs.json` does not round-trip byte-identically, unlike a pack file. Say so in the README
  of Task 4.
- The message is a plain `String`, not a `MacomprendoError`, so invariant 8's error-text tests
  do not cover its wording. Task 5 decides whether the store upgrades it.

- [ ] **Step 1: Write failing config tests**

```swift
@Test func decodesTheEnabledNamesInFileOrder() { /* the happy path, which this list forgot */ }
@Test func missingFileMeansNothingEnabled() { /* nil data -> empty, no throw, NO message */ }
@Test func malformedJSONMeansNothingEnabledAndReportsAMessage() { /* garbage -> empty + message */ }
@Test func unknownNamesAreKeptNotDropped() {
    // a name with no file is ignored at use time, but must survive a round trip:
    // deleting a pack must not require editing the config, and re-adding it must restore it
}
@Test func roundTrips() { /* encode/decode */ }
```

- [ ] **Step 2: Implement**

A plain `Codable` struct. Decoding failures return an empty config plus a message rather than
throwing; the caller surfaces it in the UI.

- [ ] **Step 3: Run `npm run test:swift` and confirm green**

---

### Task 3: The normaliser

**Files:**
- Create: `macos/Sources/Macomprendo/Core/Glossary.swift`
- Create: `macos/Sources/Macomprendo/Core/Normalizer.swift`
- Create: `macos/Tests/MacomprendoTests/Core/NormalizerTests.swift`

**Interfaces:**
- Produces: `Glossary` (keyed set with per-term pack provenance and collision counting),
  `Normalizer.normalise(_:with:) -> NormalisationResult` where the result carries the text and,
  per rewrite, `range`, `original`, `term`, `packName: String?`.
- Consumes: `GlossaryPack`, the manual term list.

This is the task the whole spec rests on. Write every test in the spec's Normalisation list before
any implementation; they are cheap and they are the specification.

- [ ] **Step 1: Write the failing keying and collision tests**

```swift
@Test func keyIgnoresCaseAndSeparators() {
    #expect(Glossary.key(for: "Xcode build") == Glossary.key(for: "xcodebuild"))
    #expect(Glossary.key(for: "MainMenu.tscn") == Glossary.key(for: "MainMenu tscn"))
}

@Test func collidingKeysResolveBySourceOrderAndCountTheLoser() {
    // manual > packs, in packs.json order. No alphabetical fallback exists:
    // a pack absent from packs.json is disabled and contributes no terms at all.
}
```

- [ ] **Step 2: Write the failing matching tests**

Casing, splitting, longest-window-wins, punctuation detach/reattach, the Cyrillic script gate,
empty glossary as identity — one test each, exactly as the spec lists them.

- [ ] **Step 3: Write the failing boundary tests**

These two are the ones that will be got wrong if written after the implementation:

```swift
@Test func aWindowNeverCrossesASentenceBoundary() {
    // "Закрыл Xcode. Build упал" must stay untouched with `xcodebuild` in the glossary;
    // likewise across ! ? : ; newline, and brackets/quotes
}

@Test func aSentencesFirstWordKeepsItsCapital() {
    // pack holds `swift`: "Swift хорош" survives untouched
    // pack holds `xcodebuild`: "Xcode build упал" becomes "Xcodebuild упал" —
    // the split is fixed and the sentence capital is preserved
}
```

- [ ] **Step 4: Write the failing provenance tests**

Ranges index the **final** string, not the input — `Safe Area View` → `SafeAreaView` shortens it.
Each rewrite names its pack; a manual term reports `nil`.

- [ ] **Step 5: Implement `Glossary` and `Normalizer`**

Build the keyed set once per glossary change, not per dictation. The matcher is a single forward
pass with a 4→1 window at each position.

**Done — commit `9dd9d65`.** 995 lines, 72 tests. Carry forward:
- A clause ender separates only with whitespace beside it (`MainMenu.tscn` survives,
  `Xcode. Build` does not); newlines, brackets and quotes separate unconditionally. Apostrophes
  are not quotes.
- `:` and `;` stop a window but do not begin a sentence, so no capital is protected after them.
- The regression pin builds its pack **by hand** from the control dictation's table. **Task 4
  must repoint it at the real factory packs** — otherwise it keeps passing while the shipped
  packs drift away from it.

- [ ] **Step 6: Add the control-dictation regression test**

Feed the five transcripts from `2026-09-14-glossary-control-dictation.md` and assert the exact
expected output, including `GQ` and `RAV` staying wrong. Name the test so its nature is obvious —
`controlDictationRegressionPin`, not `measuresEffectiveness`: the rules and packs were derived
from this text, and the test pins behaviour rather than proving value.

- [ ] **Step 7: Run `npm run test:swift` and confirm green**

---

### Task 4: Factory packs as a bundled resource

**Files:**
- Create: `macos/Sources/Macomprendo/Resources/Vocabulary/{typescript,react-native,python,go,ruby,godot}.txt`
- Create: `macos/Sources/Macomprendo/Resources/Vocabulary/README.md`
- Modify: `macos/Package.swift`, `macos/project.yml`
- Create: `macos/Tests/MacomprendoTests/Resources/FactoryPackResourceTests.swift`

- [ ] **Step 1: Write the failing resource test**

Assert every factory pack is present in `ResourceBundle.current`, parses without skipped lines, and
holds at least one term. This is what catches invariant 17 being half-done.

**Done — commit `604e31c`.** Six packs, 22-28 terms each, 1228 tests green, `npm run gen` a
no-op. Carry forward:
- The pin could NOT be repointed at factory packs alone. A third of its rewrites come from
  project terms (`auto-till-dry`, `MatchHUD`, `MainMenu.tscn`, `TextEditor`) that must never be
  factory terms. It now uses the six factory packs **plus** a personal list standing in for the
  user's own pack, with a comment saying why. The plan's "repoint that test at them" was not
  achievable as written.
- `FactoryPackFixture` reads bundled packs by name and lives in the **test target**. That is
  production behaviour belonging to `GlossaryStore` — **Task 5 must replace the fixture, not
  duplicate it**, or the app ends up with two bundle readers.
- `react-native` is deliberately NOT a term in the react-native pack: the dictation proves the
  model writes `React Native` correctly, so listing it would rewrite correct prose. The spec's
  collision example used those two spellings and invited exactly that mistake; the spec has been
  repaired.

- [ ] **Step 2: Write the pack contents**


Filter the `~/dev` harvest by the control dictation's criterion: a term belongs only if the
recogniser plausibly breaks it. Exclude what comes out correct (`TypeScript`, `React`, `Python`,
`Xcode`, `WebRTC`) and anything nobody says aloud (`Input.parse_input_event`,
`golang.org/x/crypto`). Expect roughly a quarter of the harvested list to survive.

- [ ] **Step 3: Write `README.md`**

Both formats — the pack file and `packs.json` — with a worked example of each, and the explicit
statement that a new file is **off** until its name is added to `packs.json`. This file is the
agent-facing contract; write it for a reader who has never seen the app.

- [ ] **Step 4: Declare the directory in both places**

`Package.swift`: add `.copy("Resources/Vocabulary")` to `resources:`.
`project.yml`: add `"Resources/Vocabulary"` to the target's `excludes:` **and** a
`- path: Sources/Macomprendo/Resources/Vocabulary` / `type: folder` / `buildPhase: resources`
entry. Then `npm run gen` and commit the regenerated project.

- [ ] **Step 5: Run `npm run test:swift`, then `xcodebuild` and confirm the packs are in the bundle**

`swift test` passing is not enough here — that is exactly the failure invariant 17 describes.

---

### Task 5: `GlossaryStore`

**Files:**
- Create: `macos/Sources/Macomprendo/Services/GlossaryStore.swift`
- Create: `macos/Tests/MacomprendoTests/Services/GlossaryStoreTests.swift`
- Create: `macos/Tests/MacomprendoTests/Fakes/FakeGlossaryStore.swift`

**Interfaces:**
- Produces: `GlossaryStoring` with load, reload, seed, create, duplicate, delete, reset, write,
  and enable/disable.
- Consumes: `GlossaryPack`, `GlossaryPackConfig`, `ResourceBundle`.

- [ ] **Step 1: Write the failing store tests**

Every bullet in the spec's Store list, each against a temporary directory:

```swift
@Test func seedingCopiesPacksAndReadmeOnceAndNeverOverwrites() async throws
@Test func seedingLeavesTheConfigEmpty() async throws
@Test func factoryIsDerivedFromTheBundleNotStored() async throws
@Test func newPackRejectsInvalidAndCollidingNames() async throws
@Test func togglingRewritesOnlyTheConfig() async throws {
    // assert every pack file is byte-identical afterwards
}
@Test func deletedPackFileDisappearsWithoutError() async throws
@Test func resetRestoresOnePackFromTheBundle() async throws
```

- [ ] **Step 2: Implement the store**

Directory at `~/Library/Application Support/Macomprendo/Vocabulary/`, created with the same
`0o700` permissions the history store uses. A pack is factory when a same-named file exists in
`ResourceBundle.current`.

- [ ] **Step 3: Run `npm run test:swift` and confirm green**

---

### Task 6: Wiring into dictation

**Files:**
- Modify: `macos/Sources/Macomprendo/Core/Settings.swift`
- Modify: `macos/Sources/Macomprendo/Features/DictationController.swift`
- Modify: `macos/Sources/Macomprendo/Features/DictationCapture.swift`
- Modify: `macos/Sources/Macomprendo/App/AppEnvironment.swift`
- Modify: the matching test files

- [ ] **Step 1: Write the failing settings and wiring tests**

`glossaryEnabled` defaults false and decodes from a document without the key;
`glossaryManualTerms` likewise. Then the three wiring cases: off → text unchanged and `rawText`
nil; on with a hit → text corrected and `rawText` holds the model output; on without a hit →
`rawText` nil.

- [ ] **Step 2: Normalise at the two call sites**

`DictationController.transcribeAndInsert` right after trimming (`:219`), and `DictationCapture`
(`:141`). Pass the corrected text to `inserter.insert` and both texts to
`history.append(text:rawText:kind:run:)`.

- [ ] **Step 3: Run `npm run test:swift` and confirm green**

---

### Task 7: The Glossary section in Settings

**Files:**
- Modify: `macos/Sources/Macomprendo/UI/Settings/DictationTab.swift`
- Modify: the matching test files

- [ ] **Step 1: Write the failing first-run-offer test**

Turning the master switch on the first time writes the factory pack names into `packs.json`;
declining leaves it empty and does not ask again. This is view-model logic, so it is a unit test,
not a UI test.

- [ ] **Step 2: Build the section**

Master switch, pack list with checkbox and term count, Reset (factory) or Delete (user) per pack,
New pack and Duplicate, the manual-terms field, Reload and Show in Finder. Selecting a pack opens
its text in a `TextEditor`; saving writes the file back verbatim. Surface the skipped-line count
and any collision count — both exist so the user can see a pack that is not doing what they think.

- [ ] **Step 3: Run `npm run test:swift` and confirm green**

---

### Task 8: Documentation and verification

**Files:**
- Modify: `docs/SMOKE_TEST.md`, `CHANGELOG.md`, `CONTEXT.md`

- [ ] **Step 1: Smoke-test steps**

The bundled packs appear in a fresh install's Vocabulary directory; a pack dropped in by hand
shows up after Reload and stays off until enabled; dictating a term in an enabled pack pastes the
canonical spelling.

- [ ] **Step 2: CHANGELOG under `Unreleased`**

- [ ] **Step 3: Full verification**

`npm run test:swift`, `npm run test:scripts`, `npm run audit`,
`swift build --package-path macos` (no new warnings), `npm run gen` (no-op), then
`npm run install-app:signed` and the smoke steps.

- [ ] **Step 4: Record the second control dictation**

Per the spec's "Follow-up, not optional": dictate a new paragraph built from terms that played no
part in designing these rules, score it by the same table as
`2026-09-14-glossary-control-dictation.md`, and write the result into a new spec file. Until this
exists, the 24/37 figure must not be quoted as evidence anywhere.
