# Transcription backends: a real catalog, GigaAM, and a tabbed Dictation setup

Status: approved 2026-08-31.
Builds on: `2026-08-23-macomprendo-design.md` (§ transcription, `TranscriptionProvider`),
`2026-08-28-settings-languages-and-voices-design.md` (the Models tab folded into Dictation).

## Problem

Transcription has exactly one local engine and one remote shape, and the UI reflects that
narrowness rather than the user's actual choice:

1. `whisper.cpp` is the only local engine. On Russian — the language this user dictates in
   most — it is beaten by open, MIT-licensed, locally-runnable models from Sber's GigaAM
   family, by a wide margin on some benchmarks.
2. `ModelCatalog` hard-codes the assumption "one model = one `ggml-*.bin`". Every non-whisper
   ASR model is a set of files (a transducer is four), so the assumption blocks any second
   engine before the engine itself is even considered.
3. `TranscriptionSource.local(modelID:)` carries no notion of *which engine* opens the model.
   `ProviderFactory` therefore always builds a `WhisperCppTranscriber`.
4. The Dictation tab presents nine whisper models as bare names and sizes. Nothing says what
   a model is good at, which languages it handles, or how it compares to the alternatives, so
   the choice is uninformed.
5. There is no notion of "is this backend actually usable right now". A model that was never
   downloaded and an endpoint that was never reached both fail at hotkey-press time.
6. The recording HUD never says which model is about to run, so a misconfiguration is
   invisible until the transcript comes back wrong.

## Goals

1. A second local engine, GigaAM, running through sherpa-onnx, alongside whisper.cpp.
2. A catalog that models multi-file models and per-model engines, with whisper as a
   one-file special case rather than the built-in assumption.
3. Every catalog entry carries a brief: what it is good at, its limitations, the languages
   it handles, and published benchmark numbers with a source link.
4. The Dictation tab gets an explicit active-model selector listing only backends that are
   ready to use, above three sub-tabs — whisper.cpp, GigaAM, OpenAI endpoint — for browsing
   and configuring each backend. Navigation and selection are separate.
5. One status block beside the selector states readiness explicitly: ready to use, or not
   ready with the reason and the action that fixes it.
6. The HUD shows the active model's name while recording and transcribing.

## Non-goals (YAGNI)

- **Switching models from the HUD.** Deferred deliberately. The HUD is a
  `.nonactivatingPanel` with `canBecomeKey: false` created with `ignoresMouseEvents = true`,
  so accepting input means both flipping `ignoresMouse` and adding a global key monitor for
  hold mode. Worth doing later; not needed to make the catalog useful.
- **Streaming / partial results.** GigaAM v3 and sherpa-onnx both support it. The current
  flow is batch (record, then transcribe) and partial results are a different protocol.
- **GigaAM-Emo**, the emotion model. Nothing in the app consumes emotion labels.
- **The cloud GigaChat API.** Out of scope in both directions: it is a chat API, and its
  OAuth token exchange plus Russian root certificates do not fit `Endpoint`'s static-key model.
- **Replacing whisper.cpp.** It stays the multilingual default; GigaAM is strictly additive.
- **Localizing the UI.** Briefs and benchmark labels are English, like every other string.
- **A language picker for GigaAM.** The models take no language parameter (see § Parameters).

## Engine and catalog data model

`Services/ModelCatalog.swift` is rewritten. `WhisperModel` becomes `LocalASRModel`:

```swift
enum ASREngine: String, Codable, Sendable, CaseIterable {
    case whisperCpp
    case gigaAM
}

enum ModelFileRole: String, Sendable, CaseIterable {
    case ggml       // whisper.cpp
    case ctcModel   // sherpa NeMo CTC
    case encoder, decoder, joiner   // sherpa transducer
    case tokens
}

struct ModelFile: Sendable, Equatable {
    let role: ModelFileRole
    /// The name this file is stored under locally. Chosen by us, NOT taken from the
    /// download URL: several upstream repositories publish different models under the
    /// identical basenames `model.int8.onnx` and `tokens.txt`.
    let fileName: String
    let sizeBytes: Int64
    let sha256: String
    let downloadURL: URL
}

struct Benchmark: Sendable, Equatable {
    let language: String
    let dataset: String     // "FLEURS", "Common Voice"
    let metric: String      // "WER %" — lower is better
    let value: Double
    /// Published numbers for other models on the same row, for context.
    let comparedTo: [String: Double]
}

struct ModelBrief: Sendable, Equatable {
    let summary: String
    let strengths: [String]
    let limitations: [String]
    let benchmarks: [Benchmark]
    /// Where the numbers come from. Rendered as a link so they can be re-checked.
    let sourceURL: URL
}

struct LocalASRModel: Identifiable, Sendable, Equatable {
    let id: String
    let displayName: String
    let engine: ASREngine
    /// `nil` means multilingual with no fixed list (whisper). A non-nil list is the set
    /// of languages the publisher reports ASR quality for.
    let languages: [String]?
    let files: [ModelFile]
    let brief: ModelBrief

    var totalSizeBytes: Int64 { files.reduce(0) { $0 + $1.sizeBytes } }
    func file(_ role: ModelFileRole) -> ModelFile? { files.first { $0.role == role } }
}
```

Benchmark numbers are published third-party measurements, not something this app measures.
They are rendered with their `sourceURL` visible for exactly that reason.

### Local file naming

Whisper entries keep their current `ggml-<id>.bin` names, so models already on disk are
found and nothing is re-downloaded. GigaAM entries are stored as `<model-id>-<role>.<ext>`,
e.g. `gigaam-v3-e2e-ctc-model.onnx` and `gigaam-v3-e2e-ctc-tokens.txt`. The store therefore
stays flat, collisions are impossible, and no on-disk migration is needed.

### Catalog contents

whisper.cpp keeps its nine existing entries; each gains a `ModelBrief`. GigaAM adds four,
all MIT-licensed and all int8 for size:

| id | languages | punctuation | files | approx. size | source repo |
|---|---|---|---|---|---|
| `gigaam-v3-e2e-ctc` | ru | yes | model, tokens | 225 MB | `csukuangfj/sherpa-onnx-nemo-ctc-punct-giga-am-v3-russian-2025-12-16` |
| `gigaam-v3-e2e-rnnt` | ru | yes | encoder, decoder, joiner, tokens | 232 MB | `csukuangfj/sherpa-onnx-nemo-transducer-punct-giga-am-v3-russian-2025-12-16` |
| `gigaam-multilingual-ctc` | ru, en, kk, ky, uz | no | model, tokens | 225 MB | `iaa2005/GigaAM-Multilingual-sherpa-onnx-ctc` |
| `gigaam-multilingual-large-ctc` | ru, en, kk, ky, uz | no | model, tokens | 592 MB | `iaa2005/GigaAM-Multilingual-sherpa-onnx-ctc` (`large/`) |

The two v3 entries come from the sherpa-onnx maintainer's own repositories. The two
multilingual entries have no official sherpa export and come from a community conversion —
their provenance is pinned by per-file SHA-256, and `SMOKE_TEST.md` gets an explicit item
that each one loads and transcribes, because nobody upstream has verified their embedded
ONNX metadata for us.

Sizes and hashes are placeholders in source and are filled in by
`scripts/fetch-model-hashes.mjs`, as they are today.

The briefs must state, at minimum: that `gigaam-multilingual-*` produce text with no
punctuation and no capitalisation; that whisper large-v3 is markedly better than GigaAM
Multilingual on English (FLEURS WER 3.9 vs 12.2 / 9.4); and that GigaAM Multilingual Large
is the best of the family on Russian but is 592 MB and slower on CPU.

## The sherpa-onnx binary

A new local package `macos/Packages/SherpaOnnxBinary` mirrors `WhisperBinary`: a
`binaryTarget` with `url` + `checksum` pointing at the official
`sherpa-onnx-v1.13.4-macos-shared-onnxruntime-static.xcframework.zip`, exposed as the
product `SherpaOnnx`.

The `-shared-onnxruntime-static` variant is chosen deliberately. Its `SherpaOnnxC.framework`
is a universal (`arm64` + `x86_64`) dynamic framework whose only dylib dependencies are
Foundation, libSystem, libc++ and CoreFoundation — onnxruntime is linked in statically, so
there is no second dylib to ship, sign, or discover.

`scripts/build-app.mjs` needs no change: it already discovers `*.framework` next to the
built executable, copies it into `Contents/Frameworks`, adds
`@executable_path/../Frameworks` to the executable's rpath, and signs nested code
innermost-out. This path is exercised for the first time by this change, so the plan
includes a real signed build plus `codesign --verify --deep --strict` before the work is
considered done. This decision is recorded as `ADR-0009-sherpa-onnx-gigaam.md`, extending
the reasoning of ADR-0007.

## `GigaAMTranscriber`

`Providers/GigaAMTranscriber.swift`, an `actor` conforming to the existing
`TranscriptionProvider`. **The protocol does not change**: sherpa-onnx consumes float32
samples at 16 kHz, which is exactly what `AudioRecorder` already produces for whisper.

It mirrors `WhisperCppTranscriber` in structure: the recognizer is created lazily on first
`transcribe` and stays resident; the opaque pointer lives in a small `final class` box so
`deinit` can call `SherpaOnnxDestroyOfflineRecognizer` without fighting actor isolation.

Construction fills a zero-initialised `SherpaOnnxOfflineRecognizerConfig`, setting only
`model_config.nemo_ctc.model` (CTC entries) or `model_config.transducer.{encoder,decoder,joiner}`
(transducer entries), plus `model_config.tokens`. Paths are bridged through nested
`withCString`, because the C struct borrows the pointers for the duration of the call.

Per invariant 3 this C glue stays thin and is covered by `SMOKE_TEST.md`, not by unit tests.
The parts that *are* unit-tested are pulled out as pure helpers, mirroring
`WhisperTextAssembler` and `WhisperParams`.

### Parameters

whisper.cpp accepts a spoken language (including `auto`), a thread count, and a `translate`
flag currently pinned to `false`. GigaAM accepts none of these: the v3 models are Russian
only, the multilingual models decode character-wise across their five languages without a
language hint, and decoding is greedy. The GigaAM sub-tab therefore states plainly that
there is nothing to configure rather than showing a language picker that does nothing.
`transcribe(_:sampleRate:language:)` ignores its `language` argument for GigaAM; it does not
throw, because failing a dictation over a setting the UI does not offer would be worse.

## `ProviderFactory` and `ModelManaging`

`ModelState.downloaded(URL)` loses its payload and becomes plain `.downloaded`. The URL it
carried was the single model file, which no longer exists as a concept; every consumer that
needs paths goes through `resolved(_:)` instead, so the state enum stays about state.

`ModelManaging` loses `localURL(for:)` and gains a resolution that carries the engine:

```swift
struct ResolvedLocalModel: Sendable, Equatable {
    let engine: ASREngine
    let files: [ModelFileRole: URL]
}

func resolved(_ id: String) async -> ResolvedLocalModel?
```

`ProviderFactory.transcriber(for:endpoints:models:)` keeps its signature and switches on the
resolved engine:

- `.whisperCpp` → `WhisperCppTranscriber(modelURL:)` from the `.ggml` role
- `.gigaAM` → `GigaAMTranscriber(files:)`

`TranscriptionSource` is unchanged: `.local(modelID:)` still identifies a model by id, and
the engine is a property of the catalog entry rather than of the setting.

`WhisperModelManager` is renamed `LocalModelManager` and generalised to file sets. Download
progress is the completed fraction of the set's total bytes; each file is verified against
its own SHA-256; a model reports `.downloaded` only when every file in the set is present.
Resume via HTTP `Range` against `<fileName>.partial`, atomic moves, and the rejection of a
second concurrent download for the same id all carry over unchanged in behaviour.

## Readiness

```swift
enum BackendReadiness: Sendable, Equatable {
    case ready
    case notReady(reason: String, fix: FixAction?)
}

struct EndpointProbeTarget: Sendable, Equatable {
    let id: UUID
    let model: String
}

enum FixAction: Sendable, Equatable {
    case download(modelID: String)
    case testEndpoint(EndpointProbeTarget)
    case selectModel
}

enum EndpointProbeResult: Sendable, Equatable {
    case succeeded(EndpointProbeTarget)
    case failed(target: EndpointProbeTarget?, message: String)
}
```

Computed, never stored. A local model is ready when every file is on disk. An endpoint is
ready only when a probe has succeeded in this session for that exact endpoint UUID and model.
Successes and request failures retain that target, so neither readiness nor a Fix button can
be redirected by configuring another endpoint. A failure is targetless only when incomplete
configuration prevented any request from being made.

The endpoint probe posts a one-second WAV to `/v1/audio/transcriptions`: a quiet, deterministic
440 Hz tone rather than digital silence, since a server's VAD or no-speech filter can reject pure
silence and turn a working endpoint into a false "not ready". `ProvidersViewModel` already probes
LLM endpoints with `listModels()`, but that only proves reachability and credentials — it does not
prove the transcription route exists. A status that says "ready" must mean the thing that will run
at hotkey-press time has run.

## Settings schema

`transcriptionSource` keeps its shape and remains the single record of what will transcribe.
One addition lets the endpoint sub-tab configure a server **without** making it active:

```swift
var lastTranscriptionEndpointID: UUID?    // endpoint configured for transcription
var lastTranscriptionEndpointModel: String?
```

It is stored as its two components rather than as a `TranscriptionSource?`, because only one
of that enum's cases would ever be valid in the field and a type that can hold an impossible
value invites the bug of writing one.

Both decode through the existing hand-written `init(from:)` with `decodeIfPresent` and a
default, exactly as `SpeechSettings` does, so `currentSchemaVersion` does **not** move.

An earlier draft of this design also carried `lastModelByEngine: [String: String]`, to restore
a per-engine selection when returning to a sub-tab. Separating navigation from selection (see
below) removed the only thing that read it, and it is deleted rather than left as a field
nothing writes for a reason nobody remembers.

## The Dictation tab

An **active-model selector** sits at the top, above the sub-tabs, with a single status block
beside it. Below them, three sub-tabs — **whisper.cpp**, **GigaAM**, **OpenAI endpoint** —
for browsing and configuring each backend.

### Selection is explicit, and separate from navigation

The selector is the only control that changes what transcribes. Moving between sub-tabs
changes nothing but what is on screen.

This replaces an earlier design in which the active sub-tab *was* the selection. That version
gave a navigation control a persistent side effect, and the cost was not hypothetical: with no
per-engine memory recorded yet, opening the GigaAM tab to read a brief and returning to
whisper.cpp silently replaced Large v3 Turbo with the catalog's first entry, Tiny — a model
the user had never chosen and almost certainly had not downloaded. Rather than mitigate that
with warnings, the design separates the two concerns, and the whole class of surprise goes
with it.

### What the selector lists

Every backend that is **ready to use**: a local model whose every file is on disk, and the
endpoint if its probe has succeeded.

Two cases the list must still handle, because `transcriptionSource` outlives readiness:

- **The active source is no longer ready** — its files were deleted, or the endpoint has not
  been probed this session. It stays in the list, marked as not ready. A `Picker` whose
  selection is absent from its options has no defined rendering, and silently dropping the
  user's setting from view is worse than showing it with its problem.
- **Nothing is ready at all** — a fresh install with no model downloaded. The selector is
  disabled and reads "No model is ready — download one below", which is honest where an empty
  menu is merely puzzling.

### The status block

One block, next to the selector, describing the **selected** model rather than the sub-tab
being viewed: `Ready to use ✅` with a line naming what dictation will use, or `Not ready ❌`
with the reason and a button wired to the `FixAction`.

There is deliberately no per-tab status. Two status blocks on one screen would answer the
question "what runs when I press the hotkey" twice, and a reader has no way to tell which
answer is the real one. Whether an individual model is usable is already visible on its own
row, through the download / cancel / delete control.

### Inside a sub-tab

1. **Models** — one row per catalog entry: name, size, languages, the brief (summary,
   strengths, limitations), a benchmark table with its source link, and the
   download / cancel / delete control. A row can be made active from here, which sets the
   selector; it is a shortcut for the selector, not a second source of truth.
2. **Parameters** — whisper.cpp: spoken language, thread count, and the `translate` flag now
   surfaced. GigaAM: a sentence explaining that the models take no parameters.

The OpenAI endpoint sub-tab keeps the endpoint picker and model field it has today and gains
the probe button. Configuring an endpoint there records it in the settings above; it becomes
active only when chosen in the selector.

## The HUD caption

`HUDController` gains the active model's display name, read from settings, and `HUDView`
renders it as a dim caption at the bottom in the `.recording` and `.transcribing` states
only. It is not shown while `.speaking`: that state belongs to text-to-speech, where a
transcription model name would be actively misleading. `HUDLayout.size` grows from
260 × 92 to 260 × 108.

For an endpoint source the caption reads `OpenAI endpoint · <model>`; for a local model it
is the catalog `displayName`.

## Errors

No new `MacomprendoError` cases. The mapping mirrors whisper's:

- files absent from disk → `.modelMissing(id)`
- `SherpaOnnxCreateOfflineRecognizer` returning `nil` → `.modelMissing(id)`, as
  `whisper_init_from_file_with_params` returning `nil` already does
- a sample rate other than 16 kHz, or a decode failure → `.audio(...)`
- a failed download → `.modelDownloadFailed(...)`
- a failed endpoint probe → the existing `.providerHTTP` / `.providerUnreachable`

## Testing

Unit tests, written first, with fakes from `Tests/…/Fakes`:

- multi-file download against `StubHTTPClient`: progress aggregated across the set,
  per-file SHA-256 verification, resume from a partial, rejection of a concurrent download
  of the same id, and `.downloaded` only once every file is present
- `ProviderFactory` dispatch: a fake `ModelManaging` returning each engine yields the right
  provider type
- catalog invariants: every entry's file roles form a valid set for its engine (CTC needs
  `ctcModel` + `tokens`; transducer needs `encoder` + `decoder` + `joiner` + `tokens`;
  whisper needs exactly `ggml`), ids are unique, and local file names are unique across the
  whole catalog
- `BackendReadiness` derivation for each source kind, including the endpoint-never-probed case
- the HUD caption string for local and endpoint sources, and its absence in `.speaking`
- sub-tab navigation leaves `transcriptionSource` unchanged, while only the active-model
  selector writes it; endpoint configuration writes only the two `lastTranscriptionEndpoint*`
  fields
- `ModelsViewModel` rows and disk usage for multi-file models
- `scripts/__tests__` coverage for `fetch-model-hashes.mjs` rewriting the new literal shape

Smoke tests added to `docs/SMOKE_TEST.md`:

- each of the four GigaAM entries downloads, loads, and transcribes Russian speech
- `gigaam-multilingual-ctc` transcribes a non-Russian language from its list
- punctuation is present with `gigaam-v3-e2e-*` and absent with `gigaam-multilingual-*`
- switching models between dictations releases the previous recognizer
- a signed release build launches, `codesign --verify --deep --strict` passes, and
  transcription works from the assembled `.app`

## Deliverables

- `macos/Packages/SherpaOnnxBinary/Package.swift`
- `Providers/GigaAMTranscriber.swift`, `Providers/ProviderFactory.swift`
- `Services/ModelCatalog.swift`, `Services/ModelManager.swift`
- `Core/Settings.swift`
- `UI/Settings/DictationTab.swift`, `UI/Settings/ModelsViewModel.swift`
- `UI/RecordingHUD/{HUDController,HUDView,HUDWindowPresenter}.swift`
- `scripts/fetch-model-hashes.mjs` and its tests
- `docs/adr/0009-sherpa-onnx-gigaam.md`
- `docs/SMOKE_TEST.md`, `DISTRIBUTING.md`, `CHANGELOG.md`
