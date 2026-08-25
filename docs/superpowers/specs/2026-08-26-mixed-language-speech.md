# Mixed-language speech: script segmentation + Gemini-TTS source

Status: approved 2026-08-26 (design discussed and accepted in-session).
Builds on: `2026-08-23-macomprendo-design.md` §3.2 (`SpeechSynthesizing`), §3.4 (`SpeakController`), §3.5 (Settings ▸ Speech).

## Problem

Speaking a selection that mixes Cyrillic and Latin text through one `AVSpeechSynthesisVoice`
produces garbage: a voice reads only its own language and mangles or skips the other script.
`AVSpeechService.speak` currently builds a single utterance with the configured voice.

## Goals

1. Mixed Cyrillic/Latin selections are intelligible with **system voices, offline, free**
   (per-script voice switching).
2. An optional **Gemini-TTS speech source** gives natural, native code-switching speech for
   users with a Google AI Studio API key.
3. `SpeakController`, the Speaking… HUD, and hotkey #3 behavior are unchanged.
4. Failures are user-visible with recovery text (invariant 8); the selection text is sent to
   Google **only** when the user has chosen the Gemini source (invariant 9: only
   user-configured endpoints).

## Non-goals (YAGNI)

- Streaming audio playback (sequential chunk playback is sufficient).
- Vertex AI / Google Cloud service-account auth (AI Studio API key only).
- A user-facing "secondary voice" setting for segmentation (the fallback voice is auto-picked).
- Caching synthesized audio; voice cloning; a Yandex/other provider (separate feature if wanted).
- Sentence-level progress highlighting.

## Architecture

Everything sits behind the existing `@MainActor protocol SpeechSynthesizing`. A new router
implementation delegates to the system or Gemini backend per settings; `SpeakController`
keeps receiving a single `any SpeechSynthesizing`.

```
SpeakController ──> SpeechRouter: SpeechSynthesizing
                        ├─ AVSpeechService        (+ per-script segmentation)
                        └─ GeminiSpeechService    (HTTPClient → PCM → AudioPlaying)
```

### Part A — script segmentation for system voices

**`LanguageSegmenter`** — `macos/Sources/Macomprendo/Services/LanguageSegmenter.swift`,
a pure `enum` (no state, no I/O):

```swift
enum ScriptClass: Equatable, Sendable { case cyrillic, latin, neutral }
struct TextRun: Equatable, Sendable { var text: String; var script: ScriptClass }
enum LanguageSegmenter {
    /// Maximal runs of one script. `neutral` characters (digits, punctuation, whitespace)
    /// attach to the preceding run (or the following one at the start of text).
    /// A non-neutral run shorter than `minRunLength` merges into its neighbor so single
    /// foreign words ("iPhone") do not flip the voice.
    static func runs(in text: String, minRunLength: Int) -> [TextRun]
}
```

Default `minRunLength`: 20 characters.

**`AVSpeechService.speak`** changes: compute runs; if every run matches the chosen voice's
script, behave exactly as today (one utterance). Otherwise enqueue one utterance per run on
the one `AVSpeechSynthesizer` (it plays a queue natively):

- Runs matching the configured voice's language script use the configured voice.
- Other runs use an auto-picked voice: best installed voice for `ru-RU` (Cyrillic runs) or
  the configured voice's language / `en-US` (Latin runs), preferring premium > enhanced >
  default quality. Picking is a pure static helper (`fallbackVoice(for:in:)`) over `[Voice]`
  so it is unit-testable.
- `rate`/`pitch`/`volume` apply to every utterance. `isSpeaking` stays true until the last
  utterance finishes (`didFinish` fires per utterance; the service flips state only when the
  synthesizer reports no more speech).

Script classification: `Unicode.Scalar.properties.script`-based check — Cyrillic scalars →
`.cyrillic`; Latin scalars → `.latin`; everything else (digits, punctuation, whitespace, and
any other script: Han, Arabic, …) → `.neutral`, which attaches to the neighboring run and is
therefore read by that run's voice. Explicitly: scripts outside Cyrillic/Latin never crash
and never flip the voice on their own.

### Part B — Gemini-TTS source

**`GeminiSpeechService`** — `macos/Sources/Macomprendo/Services/GeminiSpeechService.swift`,
`@MainActor final class`, conforms to `SpeechSynthesizing`.

Pipeline per `speak(text, settings)`:

1. **Chunk** the text at sentence boundaries into ≤3800 UTF-8-byte chunks
   (`GeminiSpeechService.chunks(of:limit:)`, pure, testable; a single sentence longer than
   the limit is split at word boundaries).
2. For each chunk, **POST** via the existing `any HTTPClient` seam to the Gemini
   **Interactions API**: `{baseURL}/v1beta/interactions`, header `x-goog-api-key: <key>`,
   JSON body `{"model": <model>, "input": <stylePrefix + chunk>,
   "response_format": {"type": "audio"},
   "generation_config": {"speech_config": [{"voice": <voice>}]}}`.
   The exact request/response shape MUST be re-verified against the live docs during
   implementation (the API is new in 2026); the parsing lives in one small
   `GeminiTTSParser` type so a shape change touches one file.
3. **Decode** the base64 PCM (24 kHz, 16-bit, mono) from the response
   (`interaction.output_audio.data`) and wrap it in a WAV container
   (`PCM16WAV.data(pcm:sampleRate:)` — a small sibling of the existing `WAVEncoder`, which
   handles Float32 input and is not reused for 16-bit).
4. **Play** chunks sequentially through a new OS-facing seam:

```swift
@MainActor protocol AudioPlaying: AnyObject {
    var onFinished: (@MainActor () -> Void)? { get set }
    func play(_ wavData: Data) throws
    func stop()
}
final class AVAudioPlayerPlayer: AudioPlaying   // thin AVAudioPlayer wrapper + delegate
```

   While chunk N plays, chunk N+1's request runs (single prefetch, not a queue of N).
5. `stop()` cancels the in-flight task and stops the player. `isSpeaking` is true from the
   first `speak` until the last chunk finishes, errors, or `stop()`.
6. `voices()` returns the fixed catalog of prebuilt Gemini voices (name + "gemini" language
   tag + quality "premium"): Kore, Puck, Charon, Enceladus, Sulafat, Callirrhoe, … (the full
   27-name list is embedded as data; no network call).

Style: `settings.speech.geminiStyle`, when non-empty, is prepended to the chunk as a natural-
language instruction ("<style>: <text>") — Gemini-TTS has no rate/pitch parameters.

### Protocol change

`SpeechSynthesizing` gains one member; `AVSpeechService` never calls it:

```swift
var onError: (@MainActor (Error) -> Void)? { get set }
```

`SpeakController` sets it in `init` and surfaces errors exactly like its existing text-read
failures: `toaster.toast(ErrorText.describe(error), duration: 2.5)`; the state-change hook
already hides the Speaking… HUD when `isSpeaking` drops. `ScriptedSpeech` gains the property
plus a `failWith(_:)` test hook.

### Router

**`SpeechRouter`** — `macos/Sources/Macomprendo/Services/SpeechRouter.swift`, `@MainActor
final class`, conforms to `SpeechSynthesizing`. Holds both backends plus a
`@MainActor () -> Settings` closure; every call delegates to the backend selected by
`settings.speech.source` at call time. `stop()` stops **both** backends (switching the source
mid-utterance must not orphan audio). `onStateChange`/`onError` are fan-in: the router
subscribes to both backends and republishes.

`AppEnvironment.speech` keeps its type (`any SpeechSynthesizing`) and `live()` builds
`SpeechRouter(system: AVSpeechService(), gemini: GeminiSpeechService(http:…, keychain:…),
settings:…)`. `fake()` keeps injecting `ScriptedSpeech` — controller tests are untouched.
The Speech tab needs both backends' voice lists, so `AppEnvironment` also exposes the router
as `speechRouter` or the tab model receives per-source voice arrays via the router
(`voices()` already routes by the *current* source; the tab shows the list for the source
being configured — add `func voices(for source: SpeechSource) -> [Voice]` on the router only).

## Settings schema

`SpeechSettings` gains (all `decodeIfPresent ?? default`, existing documents keep working):

| Field | Type | Default |
|---|---|---|
| `source` | `SpeechSource` (`.system` / `.gemini`) | `.system` |
| `geminiVoice` | `String` | `"Kore"` |
| `geminiStyle` | `String` | `""` |
| `geminiModel` | `String` | `"gemini-2.5-flash-preview-tts"` |
| `geminiBaseURL` | `URL` | `https://generativelanguage.googleapis.com` |
| `geminiAPIKeyRef` | `String?` | `nil` (Keychain account name, e.g. `"speech.gemini"`) |

The key itself lives only in the Keychain (invariant 5) via the existing `KeychainStoring`
seam. It never appears in logs, exports, or error text.

## UI — Settings ▸ Speech

- A "Speech source" picker (System voices / Gemini) at the top.
- **System** selected → the tab is exactly today's UI (voice list, sliders, preview).
- **Gemini** selected → voice picker over the 27 prebuilt voices, a `SecureField` for the
  API key (save/delete round-trips the Keychain, same interaction as the Providers tab),
  a "Style" text field, and Preview (which performs a real network call and therefore also
  serves as the connection test; errors appear inline). Rate/pitch/volume sliders are hidden.
- A caption under the Gemini section: "Selected text is sent to Google when this source is
  active. On the free API tier Google may use submitted text to improve its products."
- `SpeechTabModel` grows a source binding and per-source voice loading; it stays the only
  view model (no second tab).

## Error handling

- Missing/empty API key with Gemini selected → `MacomprendoError`-style user-visible failure
  ("No Gemini API key. Add one in Settings ▸ Speech.") via `onError` → toast.
- HTTP failures map to the existing `providerUnreachable(endpointName:)` /
  `providerHTTP(status:body:)` cases (endpoint name "Gemini"). Body text is never logged at
  default level.
- Cancellation (stop / new speak) is silent — both `CancellationError` and provider-originated
  `MacomprendoError.cancelled` (established codebase rule).
- Mid-queue chunk failure: stop playback, surface the error once, return to idle.

## Testing

Unit (swift-testing, fakes only — no network, no audio hardware):
- `LanguageSegmenter`: run splitting, neutral attachment, min-run merging, empty/one-script
  fast path, unknown scripts.
- `AVSpeechService` static helpers: `fallbackVoice(for:in:)` quality preference; segmentation
  → utterance plan (extract the plan computation as a pure helper returning
  `[(text, voiceID)]` so it is testable without AVFoundation).
- `GeminiSpeechService.chunks(of:limit:)`: boundaries, oversize sentences, UTF-8 byte
  accounting for Cyrillic.
- `GeminiTTSParser`: request body encoding, response decoding, malformed-response error.
- `GeminiSpeechService` with `FakeHTTPClient` + `FakeAudioPlayer`: sequential chunk playback,
  prefetch, stop mid-queue, error mid-queue, key-missing error, isSpeaking lifecycle,
  onStateChange/onError firing.
- `SpeechRouter`: delegation by source, stop-stops-both, callback fan-in, `voices(for:)`.
- Settings migration: old `speech` payload without the new fields decodes to defaults.
- `SpeakControllerTests` unchanged (proves the seam held).

Hardware/network-bound (SMOKE_TEST.md additions):
- Mixed ru/en selection with a system English voice → both languages intelligible, voice
  switches at script boundaries.
- Gemini source with a real key: preview works; mixed selection reads natively; Esc/⌥S stops
  mid-audio; missing-key and wrong-key paths show the toasts; Speaking… HUD shows for the
  whole utterance.

## Open items for the implementation plan

1. Re-verify the Interactions API request/response JSON against live docs at implementation
   time; adjust `GeminiTTSParser` only.
2. The `interactions` route may require polling/streaming for long inputs — if the simple
   request/response shape cannot return audio synchronously, fall back to the
   `models/{model}:generateContent` shape (`responseModalities: ["AUDIO"]`,
   `speechConfig.voiceConfig.prebuiltVoiceConfig.voiceName`, audio in
   `candidates[0].content.parts[0].inlineData.data`), which serves the same key and models.
   The parser seam isolates this decision.
3. Voice catalog: embed the current 27 names; drift is cosmetic (an unknown name returns an
   HTTP error surfaced normally).
