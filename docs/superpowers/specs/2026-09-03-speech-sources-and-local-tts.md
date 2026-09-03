# Speech: three sources, an explicit selector, and a local neural TTS engine

Status: approved 2026-09-03.
Builds on: `2026-08-28-settings-languages-and-voices-design.md` (the Speech tab as it stands),
`2026-08-31-transcription-backends-catalog-design.md` (the Dictation tab this one mirrors, and
the catalog / download / readiness machinery it introduced).

## Problem

Settings ▸ Speech and Settings ▸ Dictation answer the same question — *what happens when I
press the hotkey* — and answer it in two different shapes.

Dictation states the answer: an active-model selector at the top, one status block that says
ready or not-ready-because-X, and sub-tabs below that are pure navigation. Speech leaves it
implicit: a two-way segmented control both *is* the selection and *is* the navigation, so the
screen shows the settings of whatever is active and there is no way to look at the other
source's configuration without switching to it. Nothing on the screen says whether the active
source can actually speak.

Concretely:

1. **Configuring means activating.** Moving the segmented control to Endpoint makes the
   endpoint live. Reading its settings and reading what will run are the same act, which is
   the surprise the Dictation redesign deliberately removed.
2. **No readiness anywhere.** An endpoint with no API key saved looks exactly like a
   configured one. The failure arrives at ⌥S, as a toast, at the moment the user wanted
   speech.
3. **`preview()` doubles as the connection test.** For the endpoint source it performs a real,
   billed request, and it is the only way to find out whether the server answers. A test and a
   sample are different intentions and should be different buttons.
4. **Only two backends, both unsatisfying for offline Russian.** macOS system voices are
   available offline but dated; the endpoint is good but sends the selected text to a server
   and needs a key. sherpa-onnx — already vendored, already signed, already shipping in the
   bundle for GigaAM — exposes `SherpaOnnxCreateOfflineTts` and a catalog of Piper and Kokoro
   voices that run locally. The framework is present and unused for TTS.

## Goals

1. Settings ▸ Speech gets the Dictation shape: an **active-source selector** with **one status
   block** at the top, and **three sub-tabs** below — System voices, Local TTS, Endpoint —
   that are pure navigation.
2. A third speech source: **Local TTS**, sherpa-onnx `OfflineTts`, with downloadable models
   listed and managed the way Dictation lists ASR models.
3. **Readiness is explicit** for every source, with the reason and the action that fixes it.
4. The existing model catalog and downloader are **generalised from ASR to local models**
   rather than duplicated for TTS.

## Non-goals (YAGNI)

- **A probe gate for the speech endpoint.** See § Readiness: an endpoint is ready when it is
  configured. The Test button stays as diagnostics, not as a gate.
- **Mixed-language voice switching for Local TTS.** Segmentation and the language → voice map
  remain a System-only feature, stated as such on the Local tab. A Local model reads
  everything in its own voice; where a model is multi-speaker, the speaker is chosen on its
  tab.
- **Voice cloning, streaming synthesis, per-word highlighting.** Not needed by any flow.
- **Matcha / Zipvoice / Kitten model families.** Matcha needs a separate vocoder file, which
  is a second concept for one extra English voice. The catalog can grow later.
- **Several saved endpoint configurations.** Speech keeps one endpoint, as today.
- **Localizing the UI.** English, like the rest of the app.

## The catalog, generalised from ASR to local models

`Services/ModelCatalog.swift` stops being ASR-specific. The changes are deliberately
mechanical, so the Dictation tab keeps working unchanged in behaviour:

```swift
enum ModelKind: String, Sendable { case asr, tts }

/// Which local runtime opens a model. Was `ASREngine`.
enum LocalEngine: String, Codable, Sendable, CaseIterable {
    case whisperCpp, gigaAM          // ASR
    case sherpaVits, sherpaKokoro    // TTS

    var kind: ModelKind {
        switch self {
        case .whisperCpp, .gigaAM: .asr
        case .sherpaVits, .sherpaKokoro: .tts
        }
    }
}

enum ModelFileRole: String, Sendable, CaseIterable {
    case ggml, ctcModel, encoder, decoder, joiner, tokens
    /// A `.tar.bz2` holding the whole model directory. Verified as one file, then
    /// unpacked into `models/<model-id>/`.
    case archive
}
```

`LocalASRModel` becomes `LocalModel`, with `engine: LocalEngine` and one new field:

```swift
struct LocalModel: Identifiable, Sendable, Equatable {
    let id: String
    let displayName: String
    let engine: LocalEngine
    let languages: [String]?
    let files: [ModelFile]
    let brief: ModelBrief
    /// How many speakers the model exposes; 1 for the single-speaker Piper voices and for
    /// every ASR entry, which has no such concept. The Local tab offers a speaker picker
    /// only above 1.
    let speakerCount: Int
    /// For an `.archive` model: the path inside the unpacked directory that proves the
    /// unpack succeeded, and the file the engine opens.
    let archiveSentinel: String?

    var kind: ModelKind { engine.kind }
}
```

`ModelBrief` is unchanged and used for both kinds. A TTS entry carries an empty `benchmarks`
array — there is no published WER for a voice — and states its real limits in `limitations`
("one speaker", "Russian only", "348 MB on disk").

`ModelCatalog.all` now returns both kinds. Every existing caller is narrowed to
`ModelCatalog.all(kind: .asr)`: `DictationTabModel`, `ModelsViewModel`'s default argument,
`OnboardingViewModel`, `HUDController`. This is the one place where the generalisation can
leak a TTS model into a transcription list, so it gets an explicit test per call site.

### Archive downloads

sherpa's TTS models are published as `.tar.bz2` archives containing an ONNX model, a token
table and — for every Piper voice — an `espeak-ng-data/` directory of roughly 400 files. Per-
file downloads are therefore not an option: the catalog would need hundreds of literals per
model and one HTTP request each.

`LocalModelManager` gains one step, and nothing else changes: after a `.archive` file has been
downloaded and its SHA-256 verified exactly like any other file, it is unpacked into
`models/<model-id>/` and the archive is deleted. Resume via HTTP `Range` against
`<fileName>.partial`, per-file verification, atomic moves, and the rejection of a second
concurrent download for the same id all carry over untouched.

Unpacking goes through a protocol, so it is fake-able and the manager stays unit-testable:

```swift
protocol ArchiveExtracting: Sendable {
    /// Unpacks `archive` so that its single top-level directory's contents land in
    /// `destination`. Throws `MacomprendoError.modelDownloadFailed` on any failure.
    func extract(_ archive: URL, into destination: URL) async throws
}
```

The live implementation shells out to `/usr/bin/tar -xjf`, which is present on every macOS and
already handles bzip2. The app is not sandboxed (`Macomprendo.entitlements` sets
`app-sandbox` to false), so spawning it is allowed.

A `.archive` model counts as `.downloaded` only when `models/<model-id>/<archiveSentinel>`
exists. A directory left half-unpacked by a crash therefore reads as not-downloaded and is
re-fetched, rather than being opened and failing inside the C API.

`ResolvedLocalModel` gains the unpacked location; which files live inside it is the engine's
knowledge, not the manager's:

```swift
struct ResolvedLocalModel: Sendable, Equatable {
    let engine: LocalEngine
    let files: [ModelFileRole: URL]
    /// `models/<model-id>/` for an archive model, `nil` otherwise.
    let directory: URL?
}
```

`delete(_:)` removes the directory for an archive model and the individual files otherwise.
Disk usage keeps summing `totalSizeBytes` of downloaded models; for an archive entry that
figure is the unpacked size, not the compressed one, since that is what occupies the disk.

### Catalog contents

Eight entries, all verified to exist and sized by a HEAD request against the
`k2-fsa/sherpa-onnx` `tts-models` release on 2026-09-03:

| id | engine | languages | speakers | archive | notes |
|---|---|---|---|---|---|
| `vits-piper-ru_RU-ruslan-medium` | sherpaVits | ru | 1 | 64 MB | male |
| `vits-piper-ru_RU-irina-medium` | sherpaVits | ru | 1 | 64 MB | female |
| `vits-piper-ru_RU-dmitri-medium` | sherpaVits | ru | 1 | 64 MB | male |
| `vits-piper-ru_RU-denis-medium` | sherpaVits | ru | 1 | 64 MB | male |
| `vits-piper-en_US-lessac-medium` | sherpaVits | en | 1 | 64 MB | male, US |
| `vits-piper-en_US-libritts_r-medium` | sherpaVits | en | 904 | 78 MB | US, exercises the speaker picker |
| `vits-piper-en_GB-alba-medium` | sherpaVits | en | 1 | 64 MB | female, GB |
| `kokoro-multi-lang-v1_1` | sherpaKokoro | zh, en | 103 | 348 MB | the one large entry |

Kokoro is the only model above 100 MB and the only one whose brief must lead with its size.
It is kept because it is the only multi-speaker, multi-language local option; its `limitations`
state plainly that it covers Chinese and English only — **not** Russian — so nobody downloads
348 MB expecting a Russian voice.

Sizes above are the compressed archives. Per-archive SHA-256 digests are placeholders in
source and filled in by `scripts/fetch-model-hashes.mjs`, which already rewrites `ModelFile`
literals in place and needs only to accept the new `.archive` role.

## Settings schema

`SpeechSource` gains a third flat case. Flat, with no associated values, because the selector
picks a *source* and each source's configuration lives in its own fields — an id inside the
enum would be a second place to store what `localModelID` already stores.

```swift
enum SpeechSource: String, Codable, Sendable, CaseIterable, Identifiable {
    case system, local, endpoint
}
```

Documents written before this change hold `"system"` or `"endpoint"`; both still decode.
`SpeechSettings` gains three fields, all read through the existing hand-written
`init(from:)` with `decodeIfPresent` and a default, so `currentSchemaVersion` does **not**
move:

```swift
var localModelID: String?    // a catalog id; nil means no model chosen yet
var localSpeakerID: Int      // 0 for the single-speaker Piper voices
var localSpeed: Float        // sherpa's OfflineTts speed; 1.0 is as recorded
```

Which fields belong to which source is currently implicit and becomes an explicit comment in
`SpeechSettings`, because getting it wrong is how a slider ends up doing nothing:

- **System only:** `voiceID`, `rate`, `pitch`, `volume`, `voiceByLanguage`, `segmentationEnabled`
- **Local only:** `localModelID`, `localSpeakerID`, `localSpeed`
- **Endpoint only:** `endpointBaseURL`, `endpointModel`, `endpointVoice`, `endpointInstructions`,
  `endpointAPIKeyRef`
- **Shared by the whole tab:** `source`, `previewText`, `auditionOnSelect`

Dictation needed `lastTranscriptionEndpointID` / `lastTranscriptionEndpointModel` to separate
"configured" from "active". Speech needs no equivalent: each source already owns distinct
fields, and `source` merely names whose configuration is live. Editing the Endpoint tab cannot
activate it, because those keys are not the ones `source` reads.

## Readiness

A sibling of `BackendReadiness`, not an extension of it: that type switches on
`TranscriptionSource` and this one on `SpeechSource`, and a generic covering both would add a
type parameter to save three lines.

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
}
```

Computed on demand, never stored:

- **System** — always `.ready`. A `nil` `voiceID` is not a failure: AVFoundation falls back to
  the system default voice and speech is heard.
- **Local** — `.ready` when `localModelID` names a catalog entry whose state is `.downloaded`.
  No id yet → `.selectModel`; not downloaded or failed → `.downloadModel(id:)`; downloading →
  not ready with the percentage and no fix button.
- **Endpoint** — `.ready` when `endpointBaseURL`, `endpointModel` and `endpointVoice` are all
  non-blank **and** `endpointAPIKeyRef` is set. Missing key → `.saveKey`; missing field →
  `.fillEndpoint`.

### Why the endpoint needs no successful probe

Dictation requires one: its readiness claims the `/v1/audio/transcriptions` route works, and
only a request proves that. Speech deliberately makes the weaker, honest claim "this source is
configured", for two reasons. A speech probe is a real synthesis request — billed, and slow
enough on a large model that a settings screen would sit spinning. And a wrong key surfaces
immediately and harmlessly at the first ⌥S, through the `onError` toast that already exists,
where a wrong transcription endpoint surfaces after the user has already spoken and lost the
dictation.

The Test button therefore stays, and stays diagnostics: it performs one short synthesis and
writes its verdict to a caption beside itself ("The server answered." / the error text). It
never feeds `SpeechReadiness`. The status wording makes the weaker claim explicit — "Endpoint
is configured" rather than "verified" — so the two tabs cannot be read as promising the same
thing.

## `SherpaTTSService`

`Services/SherpaTTSService.swift`, a `@MainActor final class` conforming to the existing
`SpeechSynthesizing`. The protocol does not change.

The recognizer-equivalent is created lazily on the first `speak` and stays resident; changing
`localModelID` disposes it and builds the next one. The opaque `SherpaOnnxOfflineTts` pointer
lives in a small `final class` box so `deinit` can call `SherpaOnnxDestroyOfflineTts` without
fighting actor isolation — the same shape `GigaAMTranscriber` uses.

Configuration fills a zero-initialised `SherpaOnnxOfflineTtsConfig`, setting only
`model.vits.{model,tokens,data_dir}` for `.sherpaVits` or
`model.kokoro.{model,voices,tokens,data_dir}` for `.sherpaKokoro`, from
`ResolvedLocalModel.directory`. Paths bridge through nested `withCString`, because the C
struct borrows the pointers for the duration of the call.

Synthesis returns float32 samples plus a sample rate. Both already have a home:
`WAVEncoder.encode(pcm:sampleRate:)` wraps them and the existing `AudioPlaying` plays them, so
the whole "bytes → sound → `onFinished` → pause/resume/stop" path is reused from
`EndpointSpeechService`, generation counters included.

Long text is split with the existing `SpeechTextChunker`, for a different reason than the
endpoint's: not an API limit but time-to-first-sound, since synthesising several thousand
characters on CPU takes seconds and ⌥S must start speaking promptly. Chunk N plays while
N+1 synthesises, on a single background task — sherpa's recognizer must not be called
concurrently from two threads.

Per invariant 3 the C calls are thin glue covered by `SMOKE_TEST.md`. What is unit-tested is
pulled out as pure helpers, mirroring `WhisperParams`: building the config description from a
`LocalModel` plus `SpeechSettings` (which file roles each engine wants, where the speaker id
and speed go), and the mapping of failures to `MacomprendoError`.

`SpeechRouter` gains the third backend. `backend(for:)` becomes a three-way switch, and
`speak` stops the two inactive backends instead of "the other one".

### Errors

No new `MacomprendoError` cases:

- files or unpacked directory absent → `.modelMissing(id)`
- `SherpaOnnxCreateOfflineTts` returning `nil` → `.modelMissing(id)`, exactly as
  `whisper_init_from_file_with_params` returning `nil` already does
- playback failure → the existing `.audioPlayback`
- a failed download or a failed unpack → `.modelDownloadFailed(...)`

## The Speech tab

The layout is `DictationTab`'s, deliberately, so the two screens teach each other:

```
┌───────────────────────────────────────────────────────────┐
│ Active speech source  [ Local TTS       ▾ ]   ✅ Ready    │
│                                          Piper — Ruslan…  │
├───────────────────────────────────────────────────────────┤
│  [ System voices | Local TTS | Endpoint ]                 │
│  ┌─────────────────────────────────────────────────────┐  │
│  │ (the viewed source's own settings)                  │  │
│  └─────────────────────────────────────────────────────┘  │
│  Preview text […]   ☑ Play a sample when a voice is picked│
│  [Preview] [Reload voices]      Hotkey ⌥S reads the …     │
└───────────────────────────────────────────────────────────┘
```

The selector is the only control that changes what speaks. Moving between sub-tabs changes
only what is on screen. All three sources are always listed — unlike Dictation, which hides
unready models, because there are three fixed sources here rather than a catalog, and hiding
one would leave a menu with no explanation of what is missing. A source that is not ready is
listed and marked, and the status block says why.

Selecting a not-ready source is therefore possible, and must not fail silently. `SpeakController`
checks `SpeechReadiness` before it speaks: when the active source is not ready it raises the
readiness reason as a `MacomprendoError` through the existing `onError` toast and speaks
nothing. Falling back to System voices would be worse — the user would hear speech and never
learn that the source they chose is broken.

The footer (preview text, audition toggle, Preview / Reload, the ⌥S hint) sits below the form
and stays shared: it is about the tab, not about one source. `Preview` speaks through whatever
is *active*, which is the honest reading of a button that answers "what will I hear".

### The status block

One block, beside the selector, describing the **selected** source rather than the viewed tab
— for the reason the Dictation spec gives: two status blocks answer "what happens on the
hotkey" twice with no way to tell which answer is real. Ready shows a green check and names
what will speak; not-ready shows the reason and a button wired to the `SpeechFixAction`, which
first reveals the tab that owns the problem, then acts (download the model, focus the API key
field).

### Inside the sub-tabs

1. **System voices** — exactly today's content: default-voice list, the mixed-language
   segmentation toggle with its explanation, the per-language voice map, and the rate / pitch /
   volume sliders.
2. **Local TTS** — one row per catalog entry: name, size, languages, the brief, and the
   download / cancel / delete control, with a "Use this voice" shortcut on a downloaded row
   that sets the selector. Below the list, the selected model's own parameters: a speaker
   picker shown only when `speakerCount > 1`, and a speed slider. A short line states that
   mixed-language voice switching is a System-voices feature and that a local model reads
   everything in its own voice.
3. **Endpoint** — today's form (base URL, model, voice with the built-in menu, API key, style
   instructions), plus the Test button with its caption and the existing privacy line.

### View models

`SpeechTabModel` keeps what it is good at — voice groups, the audition phrases, the Keychain
write — and a new `SpeechSourceModel` takes the selector, readiness, sub-tab navigation and
the model-state adoption, mirroring `DictationTabModel` field for field. Splitting rather than
growing keeps each file focused; `SpeechTab.swift` is already 312 lines and gains three tabs.

## Testing

Unit tests, written first, with fakes from `Tests/…/Fakes`:

- `SpeechReadiness` for every source and every failure mode, including a Local model mid-download
- the endpoint's readiness is **unaffected** by a failed or absent Test result
- catalog invariants extended to TTS: an `.archive` entry has exactly one file and a non-nil
  `archiveSentinel`; ids and local file names stay unique across both kinds; every
  `.sherpaVits` / `.sherpaKokoro` entry declares `speakerCount >= 1`
- `ModelCatalog.all(kind:)` partitions the catalog, and each narrowed call site
  (`DictationTabModel`, `ModelsViewModel`, `OnboardingViewModel`, `HUDController`) sees ASR
  entries only
- archive download against `StubHTTPClient` with a fake `ArchiveExtracting`: verify-then-unpack
  order, the archive deleted afterwards, `.downloaded` only once the sentinel exists, a failed
  unpack surfacing as `.modelDownloadFailed`, resume from a `.partial` still working
- `delete(_:)` removing the unpacked directory, and disk usage counting the unpacked size
- `SpeechSettings` decoding a pre-change document: `source` "endpoint" survives, the three new
  fields take their defaults
- the sherpa config description built from each engine's `LocalModel` + `SpeechSettings`
- `SpeechRouter` dispatching to the third backend, and stopping both others on `speak`
- sub-tab navigation writes nothing; only the selector writes `speech.source`

Smoke tests added to `docs/SMOKE_TEST.md`:

- each catalog entry downloads, unpacks, loads and speaks
- a Russian Piper voice reads Russian text; Kokoro reads English with a chosen speaker id
- switching the active source mid-utterance stops the previous backend
- pause / resume / stop behave the same across all three sources
- a signed release build speaks through the local engine from the assembled `.app`

## Delivery

Two plans, so the first is shippable on its own:

1. **The tab and the catalog generalisation** — `ModelKind` / `LocalEngine` / `LocalModel`,
   the narrowed call sites, `SpeechSource.local`, the three settings fields, `SpeechReadiness`,
   `SpeechSourceModel`, and the rebuilt `SpeechTab` with all three sub-tabs. Local TTS lists
   its catalog and reports itself not-ready honestly; selecting it is possible only once a
   model is downloaded, which the second plan makes possible.
2. **The engine** — `.archive` role, `ArchiveExtracting`, the `LocalModelManager` unpack step,
   `SherpaTTSService`, the `SpeechRouter` third branch, and the catalog's eight entries with
   real digests.

## Deliverables

- `Services/ModelCatalog.swift`, `Services/ModelManager.swift`, `Services/ArchiveExtractor.swift`
- `Services/SherpaTTSService.swift`, `Services/SpeechRouter.swift`
- `Features/SpeechReadiness.swift`
- `Core/Settings.swift`
- `UI/Settings/SpeechTab.swift`, `UI/Settings/SpeechSourceModel.swift`,
  `UI/Settings/ModelsViewModel.swift`, `UI/Settings/DictationTabModel.swift`
- `UI/Onboarding/OnboardingViewModel.swift`, `UI/RecordingHUD/HUDController.swift`
- `scripts/fetch-model-hashes.mjs` and its tests
- `docs/SMOKE_TEST.md`, `CHANGELOG.md`
