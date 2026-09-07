# Local TTS download and sherpa-onnx runtime — Plan 2

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` task-by-task. Every implementation task is RED → GREEN → review → commit.

**Goal:** Make the Local TTS source real: ship eight verified Piper/Kokoro catalog entries, download and atomically extract their archives, synthesize through the vendored sherpa-onnx OfflineTts C API, play generated audio, and route System / Local / Endpoint without fallback.

**Architecture:** Extend the existing shared `LocalModelManager`; do not create a second downloader. Archive extraction is an OS-facing `ArchiveExtracting` protocol with a `/usr/bin/tar` implementation that stages before replacement. `SherpaTTSService` remains the `@MainActor SpeechSynthesizing` façade. A serial worker owns the opaque C handle off the main actor, caches it per model, calls `SherpaOnnxOfflineTtsGenerateWithConfig`, copies samples into Swift memory, then destroys the C result. `SpeechRouter` becomes an explicit three-way router. Concrete services are composed only in `AppEnvironment`.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI/AppKit, `SherpaOnnxC`, `/usr/bin/tar`, swift-testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-09-03-speech-sources-and-local-tts.md`

## Verified upstream facts

- C header: vendored `c-api.h` provides `SherpaOnnxCreateOfflineTts`, non-deprecated `SherpaOnnxOfflineTtsGenerateWithConfig`, `SherpaOnnxDestroyOfflineTtsGeneratedAudio`, and `SherpaOnnxDestroyOfflineTts`.
- Piper archives contain one top-level directory, `<voice>.onnx`, `tokens.txt`, and `espeak-ng-data/`.
- Kokoro v1.1 contains one top-level directory, `model.onnx`, `voices.bin`, `tokens.txt`, `espeak-ng-data/`, `lexicon-*.txt`, `dict/`, and normalization FSTs.
- Release asset sizes/digests were read from GitHub release tag `tts-models` on 2026-09-07; Task 1 pins those values exactly.

## Global constraints

- Keep the active-source readiness gates added by Plan 1; never silently route Local to System.
- TDD every behavior. The C call itself stays thin and receives a smoke test because it cannot be usefully faked at that boundary.
- Do not block `MainActor` during model loading or generation.
- One in-flight utterance per service. A new `speak` or `stop` cancels prior queued work and stops its player.
- Verify downloaded bytes against pinned SHA-256 before extraction. Keep the verified archive after extraction failure so retry need not redownload; delete it only after the engine sentinel exists.
- Extract into a unique staging directory and publish with a same-volume move; never expose a partly extracted model as downloaded.
- Never log input text or generated speech content at default privacy.
- All user-visible errors are `MacomprendoError` values with description and recovery suggestion.
- No new dependency. No changes to endpoint/network behavior.
- Final gates: `npm run test:swift`, `npm run test:scripts`, `swift build --package-path macos`, `npm run gen`, `git diff --check`, and a signed installed-app smoke test through Peekaboo.

---

### Task 1: Add the eight pinned TTS catalog entries

**Files:**
- Modify: `macos/Sources/Macomprendo/Services/ModelCatalog.swift`
- Modify: `macos/Sources/Macomprendo/Providers/ProviderFactory.swift` (only to keep ASR construction exhaustive and reject TTS engines)
- Modify: `scripts/lib/model-hashes.mjs`
- Modify: matching fixtures/tests under `scripts/__tests__/`
- Modify: `macos/Tests/MacomprendoTests/Services/ModelCatalogTests.swift`
- Modify: `macos/Tests/MacomprendoTests/UI/SpeechSourceModelTests.swift`

**Produces:** `.sherpaVits` and `.sherpaKokoro` engine cases with `.tts` kind; `.archive` file role; eight `LocalModel` entries with archive sentinel and speaker count.

- [ ] Add failing catalog tests: ASR/TTS partitioning; exactly eight TTS IDs; every TTS entry has one `.archive` with a 64-hex SHA; engine kind is `.tts`; Piper speaker counts are `1` except `libritts_r` (`904`); Kokoro is `103`; sentinels are the model files.
- [ ] Run `npm run test:swift` and capture the expected compile/assertion failure.
- [ ] Add engine/file-role cases and catalog entries using these exact assets:
  - `kokoro-multi-lang-v1_1.tar.bz2`, `364816464`, `a3f4c73d043860e3fd2e5b06f36795eb81de0fc8e8de6df703245edddd87dbad`
  - `vits-piper-en_GB-alba-medium.tar.bz2`, `67212349`, `fcd45962906933eec4431d3688f7d74aaac8713c87c6717f91fd3b23463aa1a1`
  - `vits-piper-ru_RU-ruslan-medium.tar.bz2`, `67210684`, `0690b1cad01f86e8db9ba988af24898bdc1af774e23cb2e46b9c730269b6fd83`
  - `vits-piper-en_US-libritts_r-medium.tar.bz2`, `82038311`, `10dc268f3e371696d721486123e2705a9fc1faa113491979fde4d88dba1f1b1c`
  - `vits-piper-ru_RU-irina-medium.tar.bz2`, `67153308`, `1fc0f54e5e084fe287c07909f2f6e0ba6d857864cf800e3ab80286a4e8233008`
  - `vits-piper-ru_RU-dmitri-medium.tar.bz2`, `67188551`, `c86d0803737de13d441923ff3b3f309482fab8d7af3ec85949942809eb9a3660`
  - `vits-piper-en_US-lessac-medium.tar.bz2`, `67230653`, `9e3febfacf0abf4270172d2958bcec246032b7e88efc2720840cc80c93de334e`
  - `vits-piper-ru_RU-denis-medium.tar.bz2`, `67190991`, `efa4c18e0b5e32b81d1b6df36b9d312831e5d545200e27848ef926a4cd930300`
- [ ] Use archive URL `https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/<asset>` and sentinel `<locale>-<voice>-medium.onnx` for Piper (`en_US-libritts_r-medium.onnx` for LibriTTS-R), `model.onnx` for Kokoro.
- [ ] Update the hash-parser engine/role mappings and fixtures so `npm run test:scripts` understands the new source vocabulary; do not teach it to invent digests.
- [ ] Run affected Swift tests plus `npm run test:scripts`; make GREEN.
- [ ] Review scope and commit `feat(models): add verified local TTS catalog entries`.

---

### Task 2: Add staged tar.bz2 extraction behind a protocol

**Files:**
- Create: `macos/Sources/Macomprendo/Services/ArchiveExtractor.swift`
- Create: `macos/Tests/MacomprendoTests/Services/ArchiveExtractorTests.swift`
- Modify: `macos/Sources/Macomprendo/Core/MacomprendoError.swift`
- Modify: `macos/Tests/MacomprendoTests/Core/MacomprendoErrorTests.swift`

**Produces:** `protocol ArchiveExtracting: Sendable` and live `TarArchiveExtractor`.

- [ ] Write failing tests that build a tiny one-root `.tar.bz2`: extracted children land directly at destination; a non-archive/malformed archive throws `modelDownloadFailed`; multiple top-level roots are rejected; an existing destination is replaced only after successful extraction.
- [ ] Run the targeted suite and observe RED.
- [ ] Implement `/usr/bin/tar` listing and extraction into `<destination>.extracting-<UUID>`; reject absolute paths, `..` components, empty/multiple top-level roots; remove staging with `defer`.
- [ ] Capture stderr only for diagnostics, but map it to `MacomprendoError.modelDownloadFailed(modelID)` without exposing arbitrary archive text to users.
- [ ] Move the sole extracted root to destination on the same volume. On failure, preserve the prior destination.
- [ ] Make tests GREEN and run `swift build --package-path macos`.
- [ ] Review and commit `feat(models): extract model archives atomically`.

---

### Task 3: Teach LocalModelManager the archive lifecycle

**Files:**
- Modify: `macos/Sources/Macomprendo/Services/ModelManager.swift`
- Modify: `macos/Tests/MacomprendoTests/Services/LocalModelManagerTests.swift`
- Modify/Create fake under: `macos/Tests/MacomprendoTests/Fakes/`

**Produces:** archive-aware download/state/delete/resolve behavior and `ResolvedLocalModel.directory`.

- [ ] Add a fake `ArchiveExtracting` implementation and failing manager tests for: verified archive extraction; no downloaded state before sentinel; archive deletion only after success; retry reuses a verified archive after extraction failure; extracted directory deletion; `.partial` cleanup; resolved directory and engine; concurrent same-ID download still rejected.
- [ ] Run targeted tests and observe RED.
- [ ] Inject `any ArchiveExtracting` with `TarArchiveExtractor` as the production default.
- [ ] For archive models, consider the model complete only when `<modelsDirectory>/<model.id>/<archiveSentinel>` exists. A bare archive must never produce `.downloaded`.
- [ ] Download/hash as today. Then extract to the model directory, validate the sentinel, remove the verified archive, and emit `.downloaded`.
- [ ] Preserve the archive on extraction/sentinel failure. Map all visible failures to `MacomprendoError` and `.failed(message)`.
- [ ] Extend `resolved(_:)` with `directory`; extend `delete(_:)` to remove directory, archive, and partial archive safely.
- [ ] Make targeted and full model-manager suites GREEN.
- [ ] Review and commit `feat(models): manage archived local models`.

---

### Task 4: Build pure sherpa TTS configuration and the serial C worker

**Files:**
- Create: `macos/Sources/Macomprendo/Services/SherpaTTSGenerator.swift`
- Create: `macos/Tests/MacomprendoTests/Services/SherpaTTSGeneratorTests.swift`
- Modify: `macos/Sources/Macomprendo/Core/MacomprendoError.swift`
- Modify: `macos/Tests/MacomprendoTests/Core/MacomprendoErrorTests.swift`

**Produces:** `GeneratedSpeechAudio`, `LocalSpeechGenerating`, pure `SherpaTTSConfiguration`, and production serial sherpa generator.

- [ ] Add error cases and tests for missing selected/downloaded model, OfflineTts initialization failure, and generation failure; each gets description/recovery text.
- [ ] Add RED tests for configuration derivation from `ResolvedLocalModel`: Piper model/tokens/data-dir paths; Kokoro model/voices/tokens/data-dir/lexicon/dict/FST paths; unsupported ASR engines rejected; speaker ID and speed clamp.
- [ ] Add RED orchestration tests through a fake C/runtime seam: first model creates one handle; same model reuses it; changing model destroys/recreates; generated samples are copied before C result destruction; failure and cancellation do not return audio.
- [ ] Implement a serial off-main worker owning an opaque pointer box. The box destroys the handle exactly once in `deinit`; pointer state never crosses actor isolation unprotected.
- [ ] Build `SherpaOnnxOfflineTtsConfig` for VITS or Kokoro with C strings scoped across `SherpaOnnxCreateOfflineTts`.
- [ ] Call `SherpaOnnxOfflineTtsGenerateWithConfig` with `SherpaOnnxGenerationConfig(sid:speed:...)`, copy `samples[0..<n]`, capture `sample_rate`, and destroy generated audio on all paths.
- [ ] Check cancellation after synchronous C work and before publishing results. Never log text.
- [ ] Make tests/build GREEN; review strict-concurrency diagnostics.
- [ ] Commit `feat(speech): add the sherpa local TTS generator`.

---

### Task 5: Add the local SpeechSynthesizing service

**Files:**
- Create: `macos/Sources/Macomprendo/Services/SherpaTTSService.swift`
- Create: `macos/Tests/MacomprendoTests/Services/SherpaTTSServiceTests.swift`
- Add fake generator under: `macos/Tests/MacomprendoTests/Fakes/`

**Produces:** `@MainActor final class SherpaTTSService: SpeechSynthesizing`.

- [ ] Write RED tests for blank input; chunk order; `localModelID`/`localSpeakerID`/`localSpeed` forwarding; WAV encoding/playback; state callbacks; generation/playback errors; superseding speak; stop; pause before generation completes; pause/resume during playback; cancellation dropping stale generated audio.
- [ ] Mirror the proven Endpoint service state machine, but generate each chunk through `LocalSpeechGenerating` and encode float samples with existing `WAVEncoder` before `AudioPlaying.play`.
- [ ] Keep generation off main through the generator actor. Maintain one generation token/task and reject stale completions.
- [ ] `stop()` cancels queued work and stops playback immediately; cancellation is silent. `voices()` returns `[]` because model/speaker selection belongs to `SpeechSourceModel`.
- [ ] Make targeted suite GREEN and mutation-check at least router selection, stop cancellation, and stale-completion guards.
- [ ] Review and commit `feat(speech): play local sherpa TTS`.

---

### Task 6: Route and compose System / Local / Endpoint explicitly

**Files:**
- Modify: `macos/Sources/Macomprendo/Services/SpeechRouter.swift`
- Modify: `macos/Tests/MacomprendoTests/Services/SpeechRouterTests.swift`
- Modify: `macos/Sources/Macomprendo/App/AppEnvironment.swift`
- Modify: `macos/Tests/MacomprendoTests/App/AppEnvironmentTests.swift` if present; otherwise keep composition glue covered by build/smoke test.

**Produces:** three-way speech routing with no fallback.

- [ ] Rewrite router tests RED-first with `system`, `local`, and `endpoint` fakes: exact backend receives `speak`; inactive two stop; aggregate speaking/paused state and callbacks include all three; `stop` reaches all; pause/resume target active backend; `voices(for:)` remains source-specific.
- [ ] Replace the binary conditional with an exhaustive `switch SpeechSource` and track the active backend/source.
- [ ] In `AppEnvironment`, construct a dedicated local `AudioPlaying`, generator with the shared `LocalModelManager`, `SherpaTTSService`, and inject it into `SpeechRouter`. Never construct concrete services in UI/features.
- [ ] Make router tests and `swift build --package-path macos` GREEN.
- [ ] Review and commit `feat(speech): route local TTS without fallback`.

---

### Task 7: Harden Local TTS selection and readiness transitions

**Files:**
- Modify: `macos/Sources/Macomprendo/UI/Settings/SpeechSourceModel.swift`
- Modify: `macos/Sources/Macomprendo/UI/Settings/SpeechTab.swift` only if live rows do not already refresh after extraction
- Modify: `macos/Tests/MacomprendoTests/UI/SpeechSourceModelTests.swift`
- Modify: `macos/Tests/MacomprendoTests/UI/SpeechTabModelTests.swift`
- Modify: `macos/Tests/MacomprendoTests/Features/SpeechReadinessTests.swift` as needed

- [ ] Add RED tests: switching from a 103/904-speaker model to one speaker resets `localSpeakerID` to `0`; selecting a model never activates Local implicitly; a completed extraction makes selected Local ready; deletion makes it not-ready; Preview forwards the selected model/speaker/speed and never falls back.
- [ ] Implement the smallest model/UI changes needed. Clamp stale persisted speaker IDs both when selecting and at generation boundary.
- [ ] Verify the Local tab lists all eight models, downloaded state updates without reopening Settings, and the model-specific speaker picker range is valid.
- [ ] Make affected tests GREEN; review and commit `fix(speech): keep local voice selection valid`.

---

### Task 8: Document, build, install, and smoke-test real local speech

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `docs/ARCHITECTURE.md`
- Modify: `docs/SMOKE_TEST.md`
- Modify: original spec if implementation details legitimately changed
- Regenerate: `macos/Macomprendo.xcodeproj`

- [ ] Update Unreleased and docs with archive verification/extraction, local generator lifecycle, supported models, model size, privacy/offline behavior, and no-fallback guarantee.
- [ ] Add manual smoke steps: download one small Russian Piper archive; verify progress/readiness; select it; preview; hotkey speak selection; pause/resume/stop; restart and reuse installed model; delete and confirm not-ready; verify System and Endpoint remain unchanged.
- [ ] Run `npm run test:swift` (all), `npm run test:scripts`, `swift build --package-path macos`, `npm run gen`, `git diff --check`; require zero failures and no generated-project diff after generation.
- [ ] Run `npm run install-app:signed` from the worktree, then verify the installed code signature and launch state.
- [ ] Use Peekaboo for UI acceptance. Download the Piper Russian model through the UI and capture Local tab states before/during/after. Trigger Preview and verify no error toast and active playback state. Because hearing audio is subjective, report that final audible-quality confirmation remains for the user unless a recorded output is inspected.
- [ ] Run an adversarial whole-branch review. Fix every Critical/Important finding, rerun scoped tests, then repeat all final gates.
- [ ] Commit `docs(speech): document local TTS` (or keep docs in the final fix commit if review requires code changes).

## Definition of done

- [ ] Eight TTS assets have exact upstream SHA-256 and archive metadata.
- [ ] A partial or failed extraction can never appear ready.
- [ ] OfflineTts creation/generation does not run on MainActor.
- [ ] Local source routes only to Local, with no System fallback in hotkey or Preview.
- [ ] Cancellation, pause/resume, stale completion, and model-switch lifecycle are tested.
- [ ] Full Swift/script/build/gen gates pass.
- [ ] Signed installed app passes UI smoke test with a real downloaded Piper model.
