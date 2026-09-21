# Corpus Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make saved dictation recordings optionally lossless, record what produced each
transcript, and add the `raw_text` column that glossary normalisation will need before it can
overwrite `text`.

**Architecture:** `Settings` gains a format enum decoded with the established `decodeIfPresent`
pattern. The audio encoder keeps its protocol seam and takes a format. The SQLite store migrates
to schema 3 with five nullable columns and widens `append`/`fetchPage`. A pure `TranscriptionRun`
value is derived at the two call sites that already hold the settings snapshot, so neither
controller gains a `ModelCatalog` dependency.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI, AVFoundation, system SQLite3, Swift Testing,
SwiftPM, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-09-10-corpus-capture.md`
**ADRs:** `0011-saved-dictation-audio` (amended here), `0013-glossary-reaches-each-backend-differently`

## Global Constraints

- macOS 14+, Swift 6 strict concurrency; controllers and views are `@MainActor`, the SQLite
  connection stays actor-isolated.
- Dependencies point downward only: UI → Features → Services/Providers → Core. Construct the
  concrete encoder only in `AppEnvironment`.
- Default behaviour does not change: `savedRecordingFormat` defaults to `.aac` and every new
  column is nullable.
- **The app has no released users.** Backwards compatibility is a concern for exactly one
  database — the developer's own, at `~/Library/Application Support/Macomprendo/`, which holds
  the control dictation the glossary design rests on. Migrate 2 → 3 and create 3 from empty;
  do not invest in paths no database can be in.
- `Settings.currentSchemaVersion` must NOT move. `savedRecordingFormat` is decoded with
  `decodeIfPresent` and an unknown string falls back to `.aac` rather than throwing — the pattern
  `SpeechSettings` already uses.
- The stored file extension stays `.m4a` for both formats, so `audio_file`,
  `DictationHistoryController.saveRecording` (`"\(entry.id).m4a"`) and the player are untouched.
- `raw_text` is NULL for every row written by this work. Nothing normalises text yet; the column
  exists so the glossary spec needs no schema 4.
- `engine` is written as the string `sherpaOfflineASR` only after ADR-0014's rename lands. Until
  then this plan writes whatever `LocalEngine.rawValue` currently is (`gigaAM`), and readers must
  accept both. Do NOT rename `LocalEngine` in this plan.
- Never log transcript text at default level; error text must not contain transcript content.
- Every new user-visible failure is a `MacomprendoError` with description and recovery text.
- TDD is mandatory: add each failing test, observe the expected RED, then add the minimum
  production code.
- `macos/project.yml` stays the Xcode source of truth; regenerate the committed project after
  source changes.

## File map

- `Core/Settings.swift`: `SavedRecordingFormat`, its property, default, and legacy decoding.
- `Core/DictationHistoryEntry.swift`: `rawText` and the run fields on the entry;
  `TranscriptionRun`.
- `Providers/DictationAudioEncoder.swift`: format-aware encoder (protocol + implementation).
- `Services/DictationHistoryStore.swift`: schema 3 migration, widened `append` and `fetchPage`.
- `Features/DictationHistoryController.swift`: passes `rawText` and `run` through.
- `Features/DictationController.swift` (`:225`), `Features/DictationCapture.swift` (`:141`):
  build `TranscriptionRun` at the call site.
- `UI/Settings/GeneralTab.swift`: the `Recording quality` picker and corrected size wording.
- `App/AppEnvironment.swift`: encoder construction with the settings format.
- `Tests/MacomprendoTests/Fakes/FakeDictationAudioEncoder.swift`: records the requested format.
- `docs/adr/0011-saved-dictation-audio.md`, `docs/SMOKE_TEST.md`, `CHANGELOG.md`.

---

### Task 1: `SavedRecordingFormat` in Settings

**Files:**
- Modify: `macos/Sources/Macomprendo/Core/Settings.swift`
- Modify: `macos/Tests/MacomprendoTests/Core/SettingsTests.swift`

**Interfaces:**
- Produces: `SavedRecordingFormat`, `Settings.savedRecordingFormat`.
- Consumes: the hand-written `Settings.init(from:)` and its `decodeIfPresent` convention.

- [ ] **Step 1: Write failing Settings tests**

Prove the default, the absent-key path, and that an unknown string does not throw:

```swift
@Test func savedRecordingFormatDefaultsToAAC() {
    #expect(Settings.default.savedRecordingFormat == .aac)
}

@Test func settingsWithoutFormatKeyDecodeToAAC() throws {
    // a document written before this feature
    let json = #"{"schemaVersion":2}"#.data(using: .utf8)!
    let settings = try JSONDecoder().decode(Settings.self, from: json)
    #expect(settings.savedRecordingFormat == .aac)
}

@Test func unknownFormatStringDecodesToAACRatherThanThrowing() throws {
    let json = #"{"schemaVersion":2,"savedRecordingFormat":"flac"}"#.data(using: .utf8)!
    let settings = try JSONDecoder().decode(Settings.self, from: json)
    #expect(settings.savedRecordingFormat == .aac)
}

@Test func savedRecordingFormatRoundTrips() throws {
    var settings = Settings.default
    settings.savedRecordingFormat = .lossless
    let data = try JSONEncoder().encode(settings)
    #expect(try JSONDecoder().decode(Settings.self, from: data).savedRecordingFormat == .lossless)
}
```

- [ ] **Step 2: Add the enum and the property**

```swift
enum SavedRecordingFormat: String, Codable, Sendable, CaseIterable {
    case aac        // 48 kbit/s, ~0.35 MB/min — the default
    case lossless   // ALAC 16-bit, ~1.11 MB/min
}
```

Add `var savedRecordingFormat: SavedRecordingFormat`, `.aac` in `Settings.default`, and in
`init(from:)` decode it as a `String?` mapped through `SavedRecordingFormat(rawValue:) ?? .aac`
so an unknown value cannot throw. `currentSchemaVersion` stays at 2.

- [ ] **Step 3: Run `npm run test:swift` and confirm green**

---

### Task 2: A format-aware audio encoder

**Files:**
- Modify: `macos/Sources/Macomprendo/Providers/DictationAudioEncoder.swift`
- Modify: `macos/Tests/MacomprendoTests/Providers/DictationAudioEncoderTests.swift`
- Modify: `macos/Tests/MacomprendoTests/Fakes/FakeDictationAudioEncoder.swift`

**Interfaces:**
- Produces: `DictationAudioEncoding.encode(_:sampleRate:format:to:)`, a
  `DictationAudioEncoder` holding the AVFoundation writer for both formats.
- Consumes: `SavedRecordingFormat`.

- [ ] **Step 1: Write the failing encoder tests**

The existing tests call `encode(_:sampleRate:to:)`; widen them and add format coverage. The
real encoder is AVFoundation glue, so unit tests assert what can be asserted cheaply —
that both formats produce a readable `.m4a` whose `AVURLAsset` reports the expected format id,
and that the lossless file is materially larger for the same PCM:

```swift
@Test func losslessProducesAnAppleLosslessFile() async throws {
    let url = temporaryURL(extension: "m4a")
    try await DictationAudioEncoder().encode(toneSamples(seconds: 1),
                                             sampleRate: 16_000, format: .lossless, to: url)
    #expect(try audioFormatID(of: url) == kAudioFormatAppleLossless)
}

@Test func aacRemainsTheSmallerFile() async throws { /* both formats, compare byte counts */ }
```

- [ ] **Step 2: Widen the protocol and the fake**

`FakeDictationAudioEncoder.Request` gains `format: SavedRecordingFormat` so controller tests can
assert which format was asked for. Every existing construction of `Request` in tests must be
updated — this is the change with the widest test-file reach in this task.

- [ ] **Step 3: Implement both formats**

Rename `AACDictationAudioEncoder` to `DictationAudioEncoder` and select output settings by
format: `kAudioFormatMPEG4AAC` with `AVEncoderBitRateKey` for `.aac`,
`kAudioFormatAppleLossless` for `.lossless` (no bit rate key; ALAC rejects it). Everything else —
the `AVAssetWriter` setup, the chunked append loop, the readiness poll, the failure cleanup —
is unchanged.

- [ ] **Step 4: Run `npm run test:swift` and confirm green**

---

### Task 3: Schema 3 — columns and migration

**Files:**
- Modify: `macos/Sources/Macomprendo/Core/DictationHistoryEntry.swift`
- Modify: `macos/Sources/Macomprendo/Services/DictationHistoryStore.swift`
- Modify: `macos/Tests/MacomprendoTests/Services/DictationHistoryStoreTests.swift`
- Modify: `macos/Tests/MacomprendoTests/Core/DictationHistoryEntryTests.swift`

**Interfaces:**
- Produces: `TranscriptionRun`, `DictationHistoryEntry.rawText` and its run fields,
  `DictationHistoryStoring.append(text:rawText:kind:run:at:)`.
- Consumes: the existing `connection()` migration ladder and `fetchPage` row decoding.

- [ ] **Step 1: Write the failing migration and round-trip tests**

The app has no released users, so only two arrival paths actually exist and only they get tests:
an empty database (every fresh install) and a version 2 database (the developer's own, at
`~/Library/Application Support/Macomprendo/dictation-history.sqlite3` — 269 rows plus the
control dictation the glossary design rests on; it must survive).

Keep the `version == 1` branch in the ladder untouched and untested: no database was ever
written at version 1, and deleting the branch is a bigger diff than leaving it.

```swift
@Test func migratesVersionTwoDatabaseToThree() async throws {
    // open a v2 database with one row, reopen through the store, assert:
    //   PRAGMA user_version == 3, the row survives, raw_text/model_id/... read as NULL
}

@Test func createsVersionThreeFromEmpty() async throws { /* 0 → 3 */ }

@Test func versionFourStillRequiresConfirmedReset() async throws {
    // guard is `version >= 0 && version <= 3`; a v4 file must set requiresConfirmedReset
}

@Test func appendPersistsBothTextsAndTheRun() async throws {
    let run = TranscriptionRun(modelID: "ggml-large-v3-turbo", engine: "whisperCpp",
                               language: "ru", appVersion: "0.2.0")
    let entry = try await store.append(text: "npm run build", rawText: "NPM run build",
                                       kind: .dictation, run: run, at: date)
    let page = try await store.fetchPage(beforeID: nil, limit: 10)
    #expect(page.entries.first?.rawText == "NPM run build")
    #expect(page.entries.first?.modelID == "ggml-large-v3-turbo")
}

@Test func nilRawTextRoundTripsAsNull() async throws { /* rawText: nil reads back nil */ }
```

- [ ] **Step 2: Extend the entry value**

`DictationHistoryEntry` gains `rawText: String?`, `modelID: String?`, `engine: String?`,
`language: String?`, `appVersion: String?`, all defaulted to `nil` in the memberwise initialiser
so existing construction sites keep compiling. Add `TranscriptionRun` in the same file.

- [ ] **Step 3: Migrate the schema**

In `connection()`: widen the guard to `version <= 3`, add the five columns to the `version == 0`
CREATE, and add a `version == 2` branch issuing the five `ALTER TABLE` statements plus
`PRAGMA user_version = 3`. Leave the `version == 1` branch as it is — it now lands on 2 rather
than 3, which is harmless because no version 1 database exists.

Before running this against the developer's own database, copy it:
`cp ~/Library/Application\ Support/Macomprendo/dictation-history.sqlite3{,.bak}`. It holds the
control dictation (`id` 264–268) that ADR-0013 was derived from.

- [ ] **Step 4: Widen `append` and `fetchPage`**

`append` binds nine parameters instead of three; `fetchPage` selects and decodes the new columns
by index. `text` keeps its non-empty CHECK; `raw_text` has none, because a model may legitimately
return something that trims to empty while the pasted text does not.

- [ ] **Step 5: Run `npm run test:swift` and confirm green**

---

### Task 4: Deriving `TranscriptionRun` at the call sites

**Files:**
- Modify: `macos/Sources/Macomprendo/Features/DictationHistoryController.swift`
- Modify: `macos/Sources/Macomprendo/Features/DictationController.swift`
- Modify: `macos/Sources/Macomprendo/Features/DictationCapture.swift`
- Modify: the matching test files and `Fakes/FakeDictationHistoryStore.swift`

**Interfaces:**
- Produces: `TranscriptionRun.from(_ source: TranscriptionSource, language:, appVersion:)`,
  a pure static function.
- Consumes: `Settings.transcriptionSource`, `Settings.transcriptionLanguage`, `ModelCatalog`
  only inside that function's caller — not inside the controllers.

- [ ] **Step 1: Write the failing derivation tests**

```swift
@Test func localSourceYieldsItsCatalogEngine() {
    let run = TranscriptionRun.from(.local(modelID: "gigaam-v3-e2e-ctc"),
                                    language: "ru", appVersion: "0.2.0")
    #expect(run.modelID == "gigaam-v3-e2e-ctc")
    #expect(run.engine == "gigaAM")   // becomes sherpaOfflineASR after ADR-0014
}

@Test func endpointSourceYieldsItsConfiguredModel() {
    let run = TranscriptionRun.from(.endpoint(id: id, model: "whisper-1"),
                                    language: nil, appVersion: "0.2.0")
    #expect(run.engine == "endpoint")
    #expect(run.modelID == "whisper-1")
    #expect(run.language == nil)      // nil means auto, and must stay nil, not ""
}

@Test func shortDictationRecordsNoModel() async {
    // shortDictationInsertsOK short-circuits to "OK" without running a model
    // (DictationController.swift:203-206). The row must carry modelID == nil and
    // engine == nil, or the corpus attributes text to a model that never saw the audio.
}
```

- [ ] **Step 2: Add the derivation and widen the controller**

`DictationHistoryController.append(text:kind:)` becomes
`append(text:rawText:kind:run:)`; `record(text:kind:)` keeps its shape and passes
`rawText: nil, run: nil`. The controller still trims and drops empties before storing.

- [ ] **Step 3: Build the run at both call sites**

`DictationController.transcribeAndInsert` and `DictationCapture` each already hold the settings
snapshot; each builds a `TranscriptionRun` and passes `rawText: nil` (nothing rewrites text yet).
The short-dictation branch passes no run.

- [ ] **Step 4: Run `npm run test:swift` and confirm green**

---

### Task 5: The `Recording quality` picker

**Files:**
- Modify: `macos/Sources/Macomprendo/UI/Settings/GeneralTab.swift`
- Modify: `macos/Sources/Macomprendo/App/AppEnvironment.swift`
- Modify: the matching test files

**Interfaces:**
- Produces: the picker and the corrected disk-usage wording.
- Consumes: `Settings.savedRecordingFormat`, `SavedAudioModel.recordingToggleIsEnabled`.

- [ ] **Step 1: Write the failing wiring test**

Assert that the encoder is asked for the format currently in settings — the fake from Task 2
records it, so this is a controller-level test, not a UI one.

- [ ] **Step 2: Add the picker**

In `GeneralTab`, directly under `Toggle("Save the original recording")` (line 44) and above
`Picker("Keep history for")` (line 47):

```swift
Picker("Recording quality", selection: $model.settings.savedRecordingFormat) {
    Text("Compressed (AAC, ~0.35 MB/min)").tag(SavedRecordingFormat.aac)
    Text("Lossless (ALAC, ~1.11 MB/min)").tag(SavedRecordingFormat.lossless)
}
.disabled(!SavedAudioModel.recordingToggleIsEnabled(model.settings))
```

The rates live in the option labels, not a caption. Re-read the existing caption at line 38 and
any size warning mentioning AAC's rate, and correct anything that now states one format as if it
were the only one.

- [ ] **Step 3: Run `npm run test:swift` and confirm green**

---

### Task 6: Documentation and verification

**Files:**
- Modify: `docs/adr/0011-saved-dictation-audio.md`
- Modify: `docs/SMOKE_TEST.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Amend ADR-0011**

Add a short amendment note: files-not-blobs, `AVAssetWriter` and `.m4a` all still hold; "AAC
always" becomes "AAC by default", with a pointer to this spec.

- [ ] **Step 2: Add smoke-test steps**

- With lossless on, a dictation produces an `.m4a` that `afinfo` reports as Apple Lossless, and
  playback from the history window works.
- Switching format between two dictations leaves both playable.
- The `Saved audio:` figure tracks the larger files.

- [ ] **Step 3: CHANGELOG under `Unreleased`**

User-visible: the recording-quality choice. The schema columns are not user-visible and need no
entry.

- [ ] **Step 4: Full verification**

Run `npm run test:swift`, `npm run test:scripts`, `npm run audit`,
`swift build --package-path macos` (no new warnings), and `npm run gen` (must be a no-op).
Then run the smoke steps on a signed local build via `npm run install-app:signed`.
