# Mixed-language speech: script segmentation + OpenAI-compatible speech source

Status: approved 2026-08-26; amended 2026-08-26 — the cloud source is an OpenAI-compatible
`/v1/audio/speech` endpoint instead of Gemini-TTS (Gemini's API is region-blocked for the
user; the OpenAI-compatible shape works with resellers such as ProxyAPI, with local servers
such as openedai-speech / Kokoro-FastAPI / XTTS wrappers, and with OpenAI itself).
Builds on: `2026-08-23-macomprendo-design.md` §3.2 (`SpeechSynthesizing`), §3.4 (`SpeakController`), §3.5 (Settings ▸ Speech).

## Problem

Speaking a selection that mixes Cyrillic and Latin text through one `AVSpeechSynthesisVoice`
produces garbage: a voice reads only its own language and mangles or skips the other script.
`AVSpeechService.speak` currently builds a single utterance with the configured voice.

## Goals

1. Mixed Cyrillic/Latin selections are intelligible with **system voices, offline, free**
   (per-script voice switching).
2. An optional **endpoint speech source** — any OpenAI-compatible `/v1/audio/speech` server —
   gives natural, native code-switching speech (e.g. `gpt-4o-mini-tts` through a reseller,
   or a local TTS server).
3. `SpeakController`, the Speaking… HUD, and hotkey #3 behavior are unchanged.
4. Failures are user-visible with recovery text (invariant 8); the selection text is sent to
   the network **only** when the user has chosen the endpoint source (invariant 9: only
   user-configured endpoints).

## Non-goals (YAGNI)

- Streaming audio playback (sequential chunk playback is sufficient).
- Gemini/Vertex, Yandex SpeechKit, or any vendor-specific provider (the OpenAI-compatible
  shape covers resellers and local servers; a dedicated provider is a separate feature).
- A user-facing "secondary voice" setting for segmentation (the fallback voice is auto-picked).
- Caching synthesized audio; voice cloning; sentence-level progress highlighting.

## Architecture

Everything sits behind the existing `@MainActor protocol SpeechSynthesizing`. A new router
implementation delegates to the system or endpoint backend per settings; `SpeakController`
keeps receiving a single `any SpeechSynthesizing`.

```
SpeakController ──> SpeechRouter: SpeechSynthesizing
                        ├─ AVSpeechService           (+ per-script segmentation)
                        └─ EndpointSpeechService     (HTTPClient → audio bytes → AudioPlaying)
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
    ///
    /// Merging is ASYMMETRIC, because the failure modes are asymmetric: a Russian voice
    /// reads Latin text with an accent but intelligibly, while an English voice reading
    /// Cyrillic collapses into character spelling ("Cyrillic letter E…"). Therefore:
    /// - A LATIN run with fewer than `minRunLength` LETTERS merges into a neighboring
    ///   Cyrillic run ("iPhone", "Merge" inside a Russian sentence stay with the Russian
    ///   voice — accented but intelligible).
    /// - A CYRILLIC run NEVER merges into a Latin neighbor, no matter how short: even a
    ///   single Russian word gets its own Cyrillic run (a brief voice switch beats
    ///   letter-spelling).
    /// - Run length for merge decisions counts ONLY letters — attached neutral characters
    ///   (digits, punctuation, whitespace) never influence the comparison, so
    ///   "(swift 538/538, node 38/38)" is a 17-letter Latin run, not a 39-character one.
    static func runs(in text: String, minRunLength: Int) -> [TextRun]
}
```

Default `minRunLength`: 6 letters.

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

Script classification: character-class check over scalars (the standard library exposes no
`script` property; classification uses explicit Cyrillic/Latin block ranges) — Cyrillic
scalars → `.cyrillic`; Latin scalars → `.latin`; everything else (digits, punctuation,
whitespace, and any other script: Han, Arabic, …) → `.neutral`, which attaches to the
neighboring run and is therefore read by that run's voice. Explicitly: scripts outside
Cyrillic/Latin never crash and never flip the voice on their own.

### Part B — endpoint speech source (OpenAI-compatible)

**`EndpointSpeechService`** — `macos/Sources/Macomprendo/Services/EndpointSpeechService.swift`,
`@MainActor final class`, conforms to `SpeechSynthesizing`.

Pipeline per `speak(text, settings)`:

1. **Chunk** the text at sentence boundaries into ≤4096-character chunks (the OpenAI input
   limit) via the pure `SpeechTextChunker.chunks(of:limit:)` (a single sentence longer than
   the limit is split at word boundaries).
2. For each chunk, **POST** via the existing `any HTTPClient` seam to
   `{baseURL}/v1/audio/speech` with `Authorization: Bearer <key>` and JSON body
   `{"model": <model>, "voice": <voice>, "input": <chunk>,
   "response_format": "wav", "instructions": <style, omitted when empty>}`.
   The request building and error mapping live in one small `SpeechRequestBuilder` type.
3. The response body **is the audio bytes** (no envelope, no base64). `AVAudioPlayer`
   sniffs the container, so a server that ignores `response_format` and returns MP3 still
   plays. No PCM/WAV conversion helper is needed.
4. **Play** chunks sequentially through a new OS-facing seam:

```swift
@MainActor protocol AudioPlaying: AnyObject {
    var onFinished: (@MainActor () -> Void)? { get set }
    func play(_ audioData: Data) throws
    func stop()
}
final class AVAudioPlayerPlayer: AudioPlaying   // thin AVAudioPlayer wrapper + delegate
```

   While chunk N plays, chunk N+1's request runs (single prefetch, not a queue of N).
5. `stop()` cancels the in-flight task and stops the player. `isSpeaking` is true from the
   first `speak` until the last chunk finishes, errors, or `stop()`.
6. `voices()` returns the OpenAI built-in voice names as `Voice` values (alloy, ash, ballad,
   coral, echo, fable, nova, onyx, sage, shimmer, verse; language tag "endpoint", quality
   "premium"); the UI also accepts a free-form voice name because local servers define their
   own (see UI).

Style: `settings.speech.endpointInstructions`, when non-empty, is sent as the standard
`instructions` field (supported by `gpt-4o-mini-tts`; servers that ignore it simply ignore it).

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
final class`, conforms to `SpeechSynthesizing`. Holds both backends; `speak(_:settings:)`
delegates by `settings.source` (the settings argument already carries it — no stored
settings closure, so routing cannot go stale). `stop()` stops **both** backends (switching
the source mid-utterance must not orphan audio). `onStateChange`/`onError` are fan-in: the
router subscribes to both backends and republishes.

The Speech tab needs both backends' voice lists: `SpeechSynthesizing` gains
`func voices(for source: SpeechSource) -> [Voice]` with a protocol-extension default that
returns `voices()`; only the router overrides it to route by the argument.

`AppEnvironment.speech` keeps its type (`any SpeechSynthesizing`) and `live()` builds
`SpeechRouter(system: AVSpeechService(), endpoint: EndpointSpeechService(http:…, keychain:…,
player:…))`. `fake()` keeps injecting `ScriptedSpeech` — controller tests are untouched.

## Settings schema

`SpeechSettings` gains (all `decodeIfPresent ?? default`, existing documents keep working):

| Field | Type | Default |
|---|---|---|
| `source` | `SpeechSource` (`.system` / `.endpoint`) | `.system` |
| `endpointBaseURL` | `URL` | `https://api.openai.com` |
| `endpointModel` | `String` | `"gpt-4o-mini-tts"` |
| `endpointVoice` | `String` | `"alloy"` |
| `endpointInstructions` | `String` | `""` |
| `endpointAPIKeyRef` | `String?` | `nil` (Keychain account name, e.g. `"speech.endpoint"`) |

The key itself lives only in the Keychain (invariant 5) via the existing `KeychainStoring`
seam. It never appears in logs, exports, or error text. The base URL is user-editable — a
reseller (e.g. `https://api.proxyapi.ru/openai`) or a local server (`http://localhost:8000`)
drops in without code changes.

## UI — Settings ▸ Speech

- A "Speech source" picker (System voices / Endpoint) at the top.
- **System** selected → the tab is exactly today's UI (voice list, sliders, preview).
- **Endpoint** selected → Base URL field, Model field, Voice field (free-form text with a
  menu of the 11 OpenAI built-in names as suggestions), a `SecureField` for the API key
  (save/delete round-trips the Keychain; the stored key is never read back into the field —
  a "key saved" caption reflects presence), a "Style instructions" field, and Preview (a real
  network call, doubling as the connection test; errors surface as the standard toast).
  Rate/pitch/volume sliders are hidden.
- A caption under the Endpoint section: "Selected text is sent to the configured server when
  this source is active."
- `SpeechTabModel` grows a source binding and per-source voice loading; it stays the only
  view model (no second tab).

## Error handling

- Missing/empty API key with the endpoint source selected → user-visible failure
  ("No speech API key. Add one in Settings ▸ Speech." with recovery text) via `onError` →
  toast. A local server without auth is still reachable by saving an arbitrary non-empty key;
  documenting that beats an extra "no auth" toggle (YAGNI).
- HTTP failures map to the existing `providerUnreachable(endpointName:)` /
  `providerHTTP(status:body:)` cases (endpoint name = the configured host). Body text is
  never logged at default level.
- Playback failures → `MacomprendoError.audioPlayback(String)` (new case; reusing `.audio`
  would produce recording-flavored copy).
- Cancellation (stop / new speak) is silent — both `CancellationError` and provider-originated
  `MacomprendoError.cancelled` (established codebase rule).
- Mid-queue chunk failure: stop playback, surface the error once, return to idle.

## Testing

Unit (swift-testing, fakes only — no network, no audio hardware):
- `LanguageSegmenter`: run splitting, neutral attachment, min-run merging, empty/one-script
  fast path, non-Cyrillic/Latin scripts.
- `AVSpeechService` static helpers: `fallbackVoice(for:in:)` quality preference; segmentation
  → utterance plan (extract the plan computation as a pure helper returning
  `[(text, voiceID)]` so it is testable without AVFoundation).
- `SpeechTextChunker.chunks(of:limit:)`: boundaries, oversize sentences, character accounting.
- `SpeechRequestBuilder`: URL/header/body encoding (instructions omitted when empty),
  HTTP-error mapping.
- `EndpointSpeechService` with `FakeHTTPClient` + `FakeAudioPlayer`: sequential chunk
  playback, prefetch, stop mid-queue, error mid-queue, key-missing error, isSpeaking
  lifecycle, onStateChange/onError firing.
- `SpeechRouter`: delegation by `settings.source`, stop-stops-both, callback fan-in,
  `voices(for:)`.
- Settings migration: old `speech` payload without the new fields decodes to defaults.
- `SpeakControllerTests` unchanged (proves the seam held).

Hardware/network-bound (SMOKE_TEST.md additions):
- Mixed ru/en selection with a system English voice → both languages intelligible, voice
  switches at script boundaries.
- Endpoint source against a real server (reseller or local): preview works; mixed selection
  reads natively; ⌥S stops mid-audio; missing-key and wrong-key paths show the toasts;
  Speaking… HUD shows for the whole utterance.

## Open items for the implementation plan

1. Some OpenAI-compatible servers ignore `response_format` and return MP3 — playback must not
   assume WAV (covered: `AVAudioPlayer` sniffs the container; the fake player just records
   bytes).
2. The 11-voice suggestion list is cosmetic data; an unknown voice name returns an HTTP error
   surfaced normally.
