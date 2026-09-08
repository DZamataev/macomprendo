# Local TTS mixed-language voice switching

Status: design approved in chat; written specification awaiting review.

Builds on:

- `2026-08-28-settings-languages-and-voices-design.md` for the shipped System voice-switching behavior;
- `2026-09-03-speech-sources-and-local-tts.md` for the Local TTS catalog, downloader, runtime, and Speech tab.

This specification supersedes only the earlier Local-TTS non-goal that said one Local model reads the whole text. The three-source selector, readiness rules, and no-System-fallback rule remain unchanged.

## Problem

System voices can switch voices inside mixed-language text. The implementation splits text into script runs, detects the language of substantial runs, applies an optional language-to-voice mapping, and otherwise picks an installed voice for the script. Local TTS currently sends every chunk to one `localModelID + localSpeakerID`, even when a suitable downloaded Russian, English, or Chinese model exists.

The Local tab also presents one flat catalog. Once more than one language is available, that makes comparison and mapping harder: users need to see which voices can read each language, and a multilingual model such as Kokoro needs to be available from every language it supports.

The Local implementation must gain equivalent mixed-language behavior without sharing System-specific voice identifiers or accidentally making optional mapped models part of source readiness.

## Goals

1. Group Local TTS catalog entries by supported base language.
2. Add an independent Local toggle named **Switch voices for mixed-language text**.
3. Let each language map to a Local **model + speaker** pair.
4. Make `Auto` choose a suitable downloaded Local model and fall back to the default Local voice when none exists.
5. Reuse the shipped script segmentation, short-fragment threshold, and language detection behavior.
6. Avoid repeatedly loading native sherpa-onnx models when text alternates between two languages.
7. Preserve pause, resume, stop, cancellation, chunk prefetch, readiness, and the prohibition on Local-to-System fallback.

## Non-goals

- Per-language speed. `localSpeed` remains one Local TTS setting.
- Automatically downloading a model from a mapping picker.
- Showing undownloaded models in language mapping pickers.
- Guessing friendly names for sherpa speaker IDs; multi-speaker models keep `Speaker 0`, `Speaker 1`, and so on.
- Adding languages or model archives to the production catalog.
- Mixed-language switching for Endpoint speech.
- Unbounded native-model retention or a new user-facing cache setting.

## Vocabulary and persisted settings

A Local voice is not just a model. Kokoro and LibriTTS expose multiple speakers, and the same Kokoro model may use different speakers for English and Chinese. The persisted value is therefore explicit:

```swift
struct LocalVoiceSelection: Codable, Sendable, Equatable, Hashable {
    var modelID: String
    var speakerID: Int
}
```

`SpeechSettings` gains:

```swift
var localSegmentationEnabled: Bool
var localVoiceByLanguage: [String: LocalVoiceSelection]
```

Keys are lowercased base BCP-47 codes (`en`, `ru`, `zh`), matching `LanguageDetecting` and the existing System map.

Defaults preserve current behavior:

```swift
localSegmentationEnabled = false
localVoiceByLanguage = [:]
```

The existing `localModelID + localSpeakerID` pair remains the **default Local voice**. `localSpeed` remains global to Local TTS.

The hand-written decoder uses `decodeIfPresent`, so documents written before this feature decode with the defaults and `Settings.currentSchemaVersion` does not move. System fields remain independent:

- System only: `voiceID`, `rate`, `pitch`, `volume`, `voiceByLanguage`, `segmentationEnabled`;
- Local only: `localModelID`, `localSpeakerID`, `localSpeed`, `localVoiceByLanguage`, `localSegmentationEnabled`;
- Endpoint only and shared fields remain as currently documented.

## Shared mixed-language planner

The existing hard behavior is shared; backend-specific voice ranking is not.

A new `MixedLanguageSpeechPlanner` owns:

- calling `LanguageSegmenter.runs(in:minRunLength:)`;
- preserving the current minimum-letter rule before language detection;
- attaching neutral text through `LanguageSegmenter` rather than creating punctuation-only voice switches;
- optionally calling `LanguageDetecting` for substantial runs;
- resolving each run through a backend-provided closure;
- coalescing adjacent runs that resolve to the same `Hashable` selection;
- collapsing the whole text back to its original bytes when every run resolves to one selection.

Conceptually:

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
        separateHan: Bool = false,
        resolve: (TextRun, String?) -> Selection
    ) -> [PlannedSpeechRun<Selection>]
}
```

### System compatibility

`AVSpeechService.utterancePlan` delegates segmentation/coalescing to the shared planner and keeps its current resolver unchanged:

- an explicit valid `voiceByLanguage` entry wins;
- otherwise the configured System voice remains on its script;
- another installed System voice is selected for the other script;
- language detection is skipped when the System map is empty, as today.

Existing System segmentation tests are behavior-preservation tests for this extraction. This feature must not change System output plans.

The shared planner keeps its default segmentation byte-for-byte compatible with System speech.
Local speech opts into separating Han runs so downloaded Chinese voices can be resolved without
making every unsupported alphabetic script equivalent to Chinese.

## Local voice availability snapshot

`SherpaTTSService` builds one availability snapshot at the start of each `speak`:

1. Iterate the TTS catalog in its stable production order.
2. Call `ModelManaging.resolved(_:)` for each entry.
3. Keep only entries that resolve to an extracted directory with the expected engine.
4. Record the model metadata and resolved directory together.

This is the runtime source of truth. The service does not consume `ModelsViewModel.rows`, so hotkey speech does not depend on whether Settings is open or on a stale UI snapshot.

The configured default model must still resolve or Local speech fails with `.modelMissing(defaultModelID)`, exactly as today. Additional mapped/automatic voices are optional.

## Local resolver

For every analyzed run, resolution returns a `LocalVoiceSelection`. Persisted values are validated before use:

- the model exists in the TTS catalog;
- it is present in the downloaded snapshot;
- its declared languages include the mapping key;
- `speakerID` is clamped to `0 ..< speakerCount`.

For a detected base language, the order is:

1. valid explicit `localVoiceByLanguage[language]`;
2. default Local voice if its model declares that language;
3. first downloaded model declaring that language, in stable catalog order;
4. for an uncertain language, a downloaded model whose declared language uses the run's script, preferring the default when it belongs to that script;
5. default Local voice.

A neutral run always uses the default. A stale mapping to a deleted or incompatible model behaves as `Auto`; it does not fail the utterance and does not make Local unready.

The resolver never chooses an undownloaded model and never chooses System speech.

## Queue construction and playback

Local planning precedes character chunking:

1. Produce coalesced text runs with `LocalVoiceSelection`.
2. Resolve each distinct model to its engine and directory from the availability snapshot.
3. Split each run with `SpeechTextChunker`.
4. Emit queue items carrying both text and a full `LocalTTSConfiguration`.

Adjacent items with the same selection may still be separate because of the character limit; their ordering and text concatenation must equal the planner output.

The current playback state machine remains one operation:

- generation is serialized by the generator actor;
- item N+1 starts generating while item N plays;
- pause can hold a generated buffer before playback;
- resume plays the held buffer or resumes the player;
- stop and a superseding `speak` cancel generation and playback for the entire mixed queue;
- a late result from an older generation cannot change state or play audio;
- any real Local generation/playback error stops the queue and is reported once.

No run-level error falls back to another source.

## Native sherpa model cache

The current `SherpaSpeechGenerator` caches one `SherpaTTSModelIdentity`. Alternating `ru → en → ru` would otherwise destroy and recreate a native model at each boundary.

Replace that slot with a bounded LRU cache of **two** identities and loaded handles:

- a hit promotes the identity to most recently used;
- a miss loads the model and inserts it;
- inserting a third identity evicts the least recently used handle;
- actor isolation continues to serialize all generation calls;
- speaker and speed are generation parameters and do not create separate cache entries;
- `SherpaTTSHandleBox.deinit` remains the destruction boundary.

Two handles cover the common two-language case and keep memory bounded. English and Chinese selections using Kokoro share one handle even when they use different speaker IDs.

## Local TTS UI

### Grouped catalog

The flat Local catalog becomes language sections based on `LocalModel.languages` and the same base-code/localized-name helpers used for System groups:

- Russian;
- English;
- Chinese.

A model appears in every language it declares. Kokoro therefore appears in both English and Chinese. Repeated rows use the same model ID and the same live `ModelState`; Download, progress, Cancel, Retry, Delete, and Chosen state stay synchronized.

Catalog grouping does not imply that a model is downloaded. Every production Local TTS model remains discoverable and downloadable here.

### Default Local voice

The existing `Use this voice` action continues to update `localModelID` and clamps `localSpeakerID`. The selected model's speaker picker and the global speed slider remain the default-voice parameters.

When audition-on-select is enabled, choosing a default Local model or changing its speaker plays the language-appropriate sample using a temporary settings copy. It does not activate Local as the app's speech source.

### Local mixed-language controls

Below the catalog/default parameters:

```text
[ ] Switch voices for mixed-language text

Voice per language
English  Voice [Auto / downloaded compatible models]  Speaker […]
Russian  Voice [Auto / downloaded compatible models]
Chinese  Voice [Auto / Kokoro]                        Speaker […]
```

Rules:

- the toggle binds only to `localSegmentationEnabled`;
- the mapping block is disabled while the toggle is off;
- only languages with at least one downloaded compatible model are shown;
- each Voice picker contains `Auto` plus downloaded compatible models;
- selecting a model writes `LocalVoiceSelection(modelID:, speakerID: 0)`;
- selecting Auto removes the key;
- a Speaker picker appears only for an explicit mapped model with `speakerCount > 1`;
- changing it writes the speaker to that language's mapping;
- one Kokoro model may have different speaker IDs under English and Chinese;
- a stale mapping renders as Auto without silently rewriting settings merely because the view appeared.

Catalog rows and mapping choices use separate derived collections: all models for catalog groups, downloaded models for mapping groups.

### Local audition

Selecting an explicit mapped model or speaker auditions `SpeechTabModel.auditionPhrases[language]` when audition-on-select is enabled. The temporary settings copy has:

- `source = .local`;
- the selected `localModelID` and `localSpeakerID`;
- `localSegmentationEnabled = false`.

The persisted active source and default Local selection are unchanged. Preview remains different: it always speaks through the active source and applies its real segmentation settings.

## Readiness and deletion

`SpeechReadiness` does not expand into aggregate readiness. Local remains ready when its default `localModelID` is downloaded. Optional mappings do not need to be downloaded to declare the source ready because stale mappings fall through to Auto/default.

Deleting a mapped model:

- updates live UI rows;
- removes it from picker candidates;
- makes the picker display Auto through validation;
- leaves persisted stale data harmless until the user writes another choice;
- does not silently activate or download anything.

Deleting the default model continues to make Local not ready, as today.

## Components and ownership

- `Core/Settings.swift`: `LocalVoiceSelection` and backward-compatible fields.
- `Services/MixedLanguageSpeechPlanner.swift`: shared segmentation/detection/coalescing seam.
- `Services/SpeechService.swift`: System resolver delegates to the planner without behavior change.
- `Services/LocalSpeechService.swift`: downloaded snapshot, Local resolver, per-item configurations and mixed queue.
- `Services/SherpaTTSService.swift`: two-entry LRU native-handle cache.
- `UI/Settings/SpeechTab.swift`: the existing `SpeechTabModel` owns pure grouping, downloaded
  mapping choices, settings mutations, and audition; the view owns only rendering and bindings.
- `UI/Settings/SpeechTab.swift`: grouped sections and Local controls only; no availability or fallback policy in the view.
- `App/AppEnvironment.swift`: inject the existing `LanguageDetecting` dependency into Local speech construction if the shared planner requires it. Concrete construction remains here.

Tests mirror these layers. No new OS-facing service is introduced.

## Test plan and agreed seams

Tests are written as vertical RED → GREEN slices against these agreed seams:

1. **Settings seam**
   - defaults preserve one-voice behavior;
   - model+speaker mappings round-trip;
   - legacy payloads decode with Local switching off and an empty map;
   - System and Local settings remain independent.

2. **Shared planner seam**
   - empty/single-script/mixed-script plans;
   - short Latin fragments in Cyrillic remain unsplit as shipped;
   - neutral punctuation placement;
   - language detection threshold;
   - adjacent identical selections collapse to the original text;
   - existing System plan fixtures remain byte-for-byte equal.

3. **Local resolver seam**
   - explicit mapping wins;
   - stale, incompatible, and undownloaded mappings are ignored;
   - default compatible model wins before another automatic model;
   - exact-language Auto precedes script fallback;
   - no suitable candidate falls back to default;
   - speaker IDs clamp independently for each language.

4. **Local service seam**
   - availability comes from `ModelManaging`, not UI state;
   - `ru → en → ru` generates with the expected three configurations and text order;
   - planning occurs before chunking;
   - next configuration prefetches while the previous audio plays;
   - pause/resume/stop and superseding speech cover a mixed queue;
   - a missing optional mapping model falls back, while a missing default fails.

5. **Generator cache seam**
   - same model with another speaker reuses one handle;
   - two model identities are reused across alternation;
   - a third identity evicts the least recently used;
   - a failed load does not poison or evict a valid hit incorrectly.

6. **UI model seam**
   - Russian/English/Chinese groups are stable and localized;
   - Kokoro appears in both English and Chinese;
   - mapping choices contain downloaded models only;
   - selecting Auto/model/speaker performs the exact settings mutation;
   - stale mapping reads as Auto;
   - Local audition uses the requested language/model/speaker with segmentation disabled and does not change the active source.

7. **Integration and manual seam**
   - existing opt-in real Piper smoke remains green;
   - add a deterministic fake mixed-language service test rather than downloading two archives in the default suite;
   - update `docs/SMOKE_TEST.md` for real Russian/English switching, Auto, explicit mappings, different Kokoro speakers, deletion fallback, and pause/stop mid-transition.

## Acceptance criteria

- The Local catalog is grouped by language; Kokoro appears under English and Chinese with synchronized state.
- The Local toggle is independent and defaults off for existing users.
- Per-language controls expose only downloaded compatible models and persist model+speaker.
- Mixed Russian/English text switches Local models with the shipped short-fragment behavior.
- Auto never downloads a model and never routes to System.
- A missing optional mapped model falls back; a missing default model keeps Local not ready or produces `.modelMissing` if removed concurrently.
- Alternating between two models reuses both native handles.
- Playback ordering, prefetch, pause, resume, stop, and cancellation remain correct.
- System voice-switching plans do not change.
- `CHANGELOG.md`, the older Local TTS spec, and `docs/SMOKE_TEST.md` no longer claim Local switching is unsupported.
- Full Swift/script suites, Swift build, XcodeGen synchronization, and unsigned Release xcodebuild pass.
