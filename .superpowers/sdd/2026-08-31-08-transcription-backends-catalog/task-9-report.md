# Task 9 report — The Dictation tab as three backend sub-tabs

Commit: `dda8243 feat(settings): give Dictation one sub-tab per transcription backend`
Branch: `feat/transcription-backends-catalog` (no branches or worktrees created)

## What I implemented

- **`UI/Settings/DictationTabModel.swift`** (new). The brief's Step-3 code is present
  **verbatim** — I machine-checked that every line of the brief's block appears in the file,
  in order (`brief lines not found in order: 0`). Everything else is additive and sits in a
  `// MARK: - What the view renders` extension or between existing members:
  - `selectedModelID`, `indicator(for:) -> TabIndicator {.ready,.notReady,.inactive}`
  - `languagesText(_:)`, `threadChoices(processorCount:)`, `threadLabel(_:processorCount:)`
  - `benchmarkValue(_:)`, `comparisonText(_:)`
  - `adopt(_ rows: [ModelsViewModel.Row])` — keeps `modelStates` in step with live downloads
  - `select(endpointID:)`, `select(endpointModel:)` — write `lastTranscriptionEndpointID` /
    `lastTranscriptionEndpointModel` (this task is their only writer) and drop a stale probe
  - `isProbing`, `probeEndpoint(using:)`, `probeCaption`
- **`UI/Settings/ModelBriefView.swift`** (new). Summary, `Icon(.success)`/`Icon(.warning)`
  bullets at 11 pt, a benchmark grid (`language · dataset · metric · this model · published
  elsewhere`) inside a horizontal `ScrollView`, and `Link("Source", …)`. No benchmarks → no
  table.
- **`UI/Settings/DictationTab.swift`** (rebuilt). Segmented sub-tab picker → pinned status
  block → `Form` with Models + Parameters (local tabs) or Endpoint. `stateCaption` kept, with
  the one wording change the ambiguity list mandated; `ModelsViewModelTests` updated to match.
- **Whisper parameter plumbing** (see judgment call 1): `WhisperOptions{threads, translate}`,
  `WhisperParams.make(…, options:)`, `WhisperCppTranscriber(modelURL:options:)` with a
  `nonisolated let options`, `ProviderFactory.transcriber(…, whisper:)`, and two new `Settings`
  fields `whisperThreads: Int?` / `whisperTranslate: Bool`, read by `AppModel`'s
  `transcriberProvider`.
- `AppModel` gains `lazy var dictationTabModel`; `SettingsView` passes it and
  `modelsViewModel` into `DictationTab`.

No new `MacomprendoError` cases. No new icons (reused `.success` / `.warning`). No
`Image(systemName:)` anywhere in the new views.

## Judgment calls (where the brief gave prose, not code)

1. **I plumbed the whisper thread count and `translate` flag end to end, adding two
   `Settings` fields.** The brief and the spec both say to surface them; neither says where
   they are stored — the spec's "Settings schema" section lists only the two per-engine
   selection keys. A control that does not reach the transcriber would be a lie, so I added
   `whisperThreads`/`whisperTranslate`, decoded with `decodeIfPresent` + default (so
   `currentSchemaVersion` stays 2, as with the Task 8 keys), and threaded them through
   `ProviderFactory` as a defaulted `whisper: WhisperOptions` argument so no existing caller
   or test changed. **This is the largest scope decision in the task and the one most worth a
   second opinion.**
2. **The status block is pinned above the scrolling `Form`, not filed at the bottom of it.**
   The spec orders the local tab as Models → Parameters → Status. On the whisper tab that
   means nine model rows each carrying a brief before the status line: it would sit far below
   the fold, i.e. exactly the "discoverable only by dictating" failure the design is supposed
   to prevent. I kept the spec's content and moved its position. Deliberate deviation.
3. **The sub-tab indicator is three-state, not two.** `isReady(tab)`-style two-state marking
   would put a warning icon on the two tabs that merely are not selected, reading as "these
   are broken". `indicator(for:)` returns `.inactive` for them and they render as plain text;
   only the active tab carries `Icon(.success)` or `Icon(.warning)`.
4. **`@ObservedObject`, not `@StateObject`.** The brief's skeleton declares
   `@StateObject private var tab: DictationTabModel` with no initialiser, which does not
   compile. The object is owned by `AppModel` (like `speechTabModel` / `promptsTabModel`), so
   `@ObservedObject` is the honest annotation. `DictationTab` also takes
   `@ObservedObject var models: ModelsViewModel`: the old code read
   `model.modelsViewModel.rows` without observing it, so download progress had no reliable
   path to a re-render.
5. **I did not add `objectWillChange.send()` to `select(tab:)` / `select(modelID:)`** even
   though `SpeechTabModel` does that in its setter, because the brief's code is a verbatim
   requirement and `AppModel`'s `@Published settings` already drives the re-render.
6. **Row layout.** Each row is: name + an "Active" capsule when selected, `size · languages`,
   the state caption *only for the selected row* (it is the sentence about the configured
   model, and repeating it on twelve other rows is noise), a `Use this model` button when not
   selected — wording chosen to state the side effect — the download/cancel/delete control,
   then the brief. The `.downloaded` control now says "Downloaded" rather than "Ready", so it
   does not compete with the status block's "Ready to use".
7. **`languagesText`** uses a fixed `en_US` locale rather than `Locale.current`: the UI is
   English throughout, and it makes the assertion deterministic on a non-English machine.
   `nil`/empty → "90+ languages" per the ambiguity list.
8. **Benchmarks** render one decimal and sort `comparedTo` by name (a dictionary's order is
   not stable across launches), with the header column named "Published elsewhere" to keep
   clear that the numbers are third-party.
9. **Probe wiring.** The view never builds a provider: it hands
   `AppModel.transcriberProvider` to `tab.probeEndpoint(using:)`, which casts to
   `OpenAICompatibleTranscriber`, calls `probe()`, and records `.succeeded` /
   `.failed(ErrorText.describe(error))`. A non-endpoint source yields an explicit failure
   message instead of a false success.
10. **Changing the endpoint or its model clears `endpointProbe`.** A probe proves that *that*
    server answered on *that* model; keeping it after a change would produce exactly the false
    "ready" the probe exists to prevent. Not in the brief; covered by two tests.
11. **`select(tab:)` deliberately does not seed `lastTranscriptionEndpointID`** (brief code is
    verbatim). Consequence: if the user never touches the endpoint picker, returning to the
    tab falls back to `endpoints.first`, which is the same endpoint it chose the first time —
    so the behaviour is consistent. One of my tests originally asserted otherwise; I rewrote
    the test to exercise the real flow (the user picks an endpoint) rather than weakening the
    brief's code. Called out here because it is a behavioural edge, not a silent fix.

## TDD evidence

**RED (cycle 1 — the brief's tests, written first):**

```
$ swift test --package-path macos --filter DictationTabModelTests
/Users/frenzy/dev/macomprendo/macos/Tests/MacomprendoTests/UI/DictationTabModelTests.swift:8:9: error: cannot find 'DictationTabModel' in scope
    |         `- error: cannot find 'DictationTabModel' in scope
…
error: cannot find 'DictationBackendTab' in scope
error: fatalError
```

That is the failure the brief predicts — the type does not exist yet; 60 `error:` lines, all
consequences of the two missing types.

**GREEN (cycle 1):**

```
$ swift test --package-path macos --filter DictationTabModelTests
✔ Suite DictationTabModelTests passed after 0.003 seconds.
✔ Test run with 11 tests in 1 suite passed after 0.003 seconds.
```

**RED (cycle 2 — whisper parameters):**

```
$ swift test --package-path macos --filter 'WhisperCppTranscriberTests|ProviderFactoryTests|SettingsTests|DictationTabModelTests'
error: cannot find 'WhisperOptions' in scope
error: extra argument 'options' in call
error: extra argument 'whisper' in call
error: value of type 'WhisperCppTranscriber' has no member 'options'
error: value of type 'Settings' has no member 'whisperThreads'
error: value of type 'Settings' has no member 'whisperTranslate'
```

**GREEN (cycle 2):** `✔ Test run with 72 tests in 4 suites passed after 0.004 seconds.`

**RED (cycle 3 — view-facing helpers, live states, probe):**

```
error: type 'DictationTabModel' has no member 'benchmarkValue'
error: type 'DictationTabModel' has no member 'comparisonText'
error: value of type 'DictationTabModel' has no member 'adopt'
error: value of type 'DictationTabModel' has no member 'isProbing'
error: value of type 'DictationTabModel' has no member 'probeEndpoint'
```

**GREEN (cycle 3):** `✔ Test run with 23 tests in 1 suite passed after 0.008 seconds.`

**RED (cycle 4 — endpoint memory):**

```
error: incorrect argument label in call (have 'endpointModel:', expected 'modelID:')
error: no exact matches in call to instance method 'select'
```

**GREEN (cycle 4):** after implementing, one test failed for a real reason —
`returningToTheEndpointTabRestoresTheEndpointAndModelLastUsed` restored the model but not the
endpoint id, because the fixture set `transcriptionSource` directly and so never wrote
`lastTranscriptionEndpointID`. See judgment call 11; the test now drives the real flow.
Final: `✔ Test run with 30 tests in 1 suite passed after 0.009 seconds.`

## Verification (literal output)

```
$ npm run test:swift
✔ Test run with 742 tests in 75 suites passed after 0.567 seconds.
```

(705 before this task + 37 new: 30 in `DictationTabModelTests`, 4 in
`WhisperCppTranscriberTests`, 1 in `ProviderFactoryTests`, 2 in `SettingsTests`. 705 + 37 =
742. No pre-existing test regressed; the previously flaky
`levelUpdatesStillReachTheHUDAfterAnEarlierRecordingHitTheCap()` passed on every run here.)

```
$ npm run test:scripts
1..228
# tests 228
# suites 0
# pass 228
# fail 0
```

```
$ touch <every source file I changed> && swift build --package-path macos 2>&1 | grep -Ei "warning|error"
grep-exit=1        # i.e. no warnings and no errors on a rebuild of all changed files
$ swift build --package-path macos
Build complete! (1.58s)
```

```
$ npm run gen
⚙️  Generating project...
⚙️  Writing project...
Created project at /Users/frenzy/dev/macomprendo/macos/Macomprendo.xcodeproj
$ git diff --stat macos/Macomprendo.xcodeproj/project.pbxproj
 macos/Macomprendo.xcodeproj/project.pbxproj | 12 ++++++++++++
 1 file changed, 12 insertions(+)
--- second run ---
$ npm run gen
⚙️  Generating project...
⚙️  Writing project...
Created project at /Users/frenzy/dev/macomprendo/macos/Macomprendo.xcodeproj
$ git diff --stat macos/Macomprendo.xcodeproj/project.pbxproj
 macos/Macomprendo.xcodeproj/project.pbxproj | 12 ++++++++++++
 1 file changed, 12 insertions(+)
```

Both runs produce the identical 12-line diff — the file ref + build file entries for
`DictationTabModel.swift`, `ModelBriefView.swift` and `DictationTabModelTests.swift`, and
nothing else. Both runs were actually executed; the regenerated `.xcodeproj` is in the commit.
Test output is otherwise clean (only the usual `ggml_metal_*` init lines from the linked
whisper build).

## What I could not see, and what a human should look at

I wrote this SwiftUI without running the app — nothing here has been on a screen. Specific
things to check in `Settings ▸ Dictation`:

1. **The readiness icon inside the segmented control.** `Label { Text } icon: { Icon }` in a
   `.segmented` picker may render as text only on macOS 14, which would silently drop the
   per-tab indicator (the pinned status block still carries the message, so this degrades
   rather than breaks). If it drops, the fallback is worth designing deliberately — a custom
   pill bar rather than a `Picker`.
2. **The benchmark grid** — it is a `Grid` inside a horizontal `ScrollView` inside a `Form`
   row. Check the five columns line up, that the horizontal scroll does not fight the form's
   vertical scroll, and that the multilingual models' five benchmark rows are all visible.
3. **Row density.** The whisper tab now lists nine rows each with a summary, up to three
   strengths and three limitations. It may be very long; the human may prefer the brief
   collapsed behind a disclosure for non-selected rows.
4. **The status block's wording and prominence** — it is the whole mitigation for the tab
   switch changing the backend. Does it actually read that way at a glance?
5. **The "Threads" picker** on a machine with many cores lists one row per core, which may be
   a long menu (a `Stepper` might read better).
6. **Whether `translate` behaves as expected in a real dictation** (invariant 3 says this glue
   is smoke-test territory; `docs/SMOKE_TEST.md` is Task 11's file, so I added no step there).

## Files changed

- new `macos/Sources/Macomprendo/UI/Settings/DictationTabModel.swift`
- new `macos/Sources/Macomprendo/UI/Settings/ModelBriefView.swift`
- new `macos/Tests/MacomprendoTests/UI/DictationTabModelTests.swift`
- `macos/Sources/Macomprendo/UI/Settings/DictationTab.swift` (rebuilt)
- `macos/Sources/Macomprendo/UI/Settings/SettingsView.swift`
- `macos/Sources/Macomprendo/App/AppModel.swift`
- `macos/Sources/Macomprendo/Core/Settings.swift`
- `macos/Sources/Macomprendo/Providers/WhisperCppTranscriber.swift`
- `macos/Sources/Macomprendo/Providers/ProviderFactory.swift`
- `macos/Tests/MacomprendoTests/Core/SettingsTests.swift`
- `macos/Tests/MacomprendoTests/Providers/WhisperCppTranscriberTests.swift`
- `macos/Tests/MacomprendoTests/Providers/ProviderFactoryTests.swift`
- `macos/Tests/MacomprendoTests/UI/ModelsViewModelTests.swift` (the mandated caption change)
- `macos/Macomprendo.xcodeproj/project.pbxproj` (regenerated)

## Self-review findings (and what I changed because of them)

- *Is the side effect legible?* Not as originally written — the status block was at the bottom
  of a nine-row scroll. Moved it above the form (judgment call 2).
- *Does every not-ready state offer its fix?* Yes: `.download` → Download, `.testEndpoint` →
  Test, `.selectModel` → "Name a model", which focuses the model field via `@FocusState`.
  `.downloading` carries `fix: nil` by design and shows no button.
- *Is decision logic stranded in the view?* Two places were: the probe caption (moved to
  `DictationTabModel.probeCaption` with a test) and the two-state tab indicator (replaced with
  the tested `indicator(for:)`). What is left in the view is layout, bindings and the
  brief-mandated `stateCaption`.
- *Are the unflattering facts still on screen?* Yes — every strength and limitation is
  rendered with `fixedSize(vertical:)` and no `lineLimit`, so "Russian only — other languages
  come out as nonsense" and "No punctuation and no capitalisation" wrap rather than truncate.
  Benchmarks include the rows where GigaAM loses to Whisper (English 12.2 vs 3.9).
- *A stale probe could claim readiness after switching endpoints* — found while writing the
  endpoint bindings, fixed and covered by two tests.
- *Test output pristine?* Yes; no stray prints, no skipped tests.

## Concerns

1. **The `WhisperOptions` plumbing is scope beyond "the screen"** and touches Core, Providers
   and App. I believe it is required (a parameter control that changes nothing would be worse
   than none), but if the human partner disagrees, the whisper Parameters section can lose the
   two controls and the plumbing can be reverted as a unit — nothing else depends on it.
2. **The screen is unverified visually.** See the six items above.
3. **`ModelState` has no dedicated "verifying" state**, so a very large GigaAM download shows
   `Downloading… 100%` while hashes are checked. Pre-existing, unchanged by this task.
4. `docs/SMOKE_TEST.md` line 260 ("The speech-model list is here and the Models tab is gone")
   is still broadly true but now describes a three-sub-tab screen; Task 11 owns that file.

---

## Fix round 1 — endpoint configuration does not activate a source

### Change

- `configuredEndpointID` and `configuredEndpointModel` now read only the endpoint
  configuration settings (`lastTranscriptionEndpointID` / `lastTranscriptionEndpointModel`),
  never `transcriptionSource`.
- `select(endpointID:)` and `select(endpointModel:)` now update only those configuration
  settings and clear a stale probe. `activate(_:)` remains the only assignment to
  `transcriptionSource` in `DictationTabModel`.
- Replaced the test that incorrectly required an active source to follow configuration edits
  with separate regression tests for endpoint-id and model edits. The endpoint-active fixture
  now reflects the state produced by explicit selector activation: both remembered configuration
  values are populated.

### TDD evidence

**RED:**

```
$ swift test --package-path macos --filter DictationTabModelTests
✘ Test configuringAnAlreadyActiveEndpointsIDLeavesTheActiveSourceUnchanged()
Expectation failed: transcriptionSource was changed from the active endpoint id to the newly configured id.
✘ Test configuringAnAlreadyActiveEndpointsModelLeavesTheActiveSourceUnchanged()
Expectation failed: transcriptionSource model was changed from "whisper-1" to "gpt-4o-transcribe".
✘ Test run with 35 tests in 1 suite failed after 0.008 seconds with 2 issues.
```

The new tests failed for the intended behavior: both configuration setters rewrote the active
endpoint source.

**GREEN:**

```
$ swift test --package-path macos --filter DictationTabModelTests
✔ Suite DictationTabModelTests passed after 0.008 seconds.
✔ Test run with 35 tests in 1 suite passed after 0.008 seconds.

$ npm run test:swift
✔ Test run with 749 tests in 75 suites passed after 0.618 seconds.
```

### Files

- `macos/Sources/Macomprendo/UI/Settings/DictationTabModel.swift`
- `macos/Tests/MacomprendoTests/UI/DictationTabModelTests.swift`

### Self-review

- `rg 'transcriptionSource\\s*=' DictationTabModel.swift` finds exactly one assignment, in
  `activate(_:)`, the explicit selector path.
- The focused and full Swift suites pass; `git diff --check` is clean.
- The deferred Minor warning-icon finding was not touched.

---

# Fix report — the sub-tab readiness indicator cannot silently disappear

Commit: `2875e67 fix(settings): put the sub-tab readiness marker in the tab's own title`

## What I changed and why

The coordinator was right that "degrades rather than breaks" is not good enough when the
thing that degrades is the warning itself. `Label { Text } icon: { Icon }` inside a
`.segmented` Picker may render title-only on macOS, which would have dropped half the
mitigation for tab-as-selection with nothing on screen to say so.

The marker is now part of the tab's own title string, which a segmented control always
renders:

- `DictationTabModel.TabIndicator.marker` — `"✅"` for `.ready`, `"❌"` for `.notReady`,
  `""` for `.inactive`. The empty case is deliberate and commented: an unconfigured backend
  must not look broken, or a fresh install would show three alarming tabs.
- `DictationTabModel.tabTitle(for:)` — composes `"GigaAM ✅"` / `"GigaAM ❌"` / `"whisper.cpp"`.
  Which marker a tab gets is still decided by the already-tested `indicator(for:)`; this only
  turns that decision into the string the control draws.
- `DictationTab` lost its `tabLabel(_:)` `@ViewBuilder` entirely; the picker body is now
  `Text(tab.tabTitle(for: candidate)).tag(candidate)`. The view holds no branching about
  readiness at all any more.
- `Icon(.success)` / `Icon(.warning)` remain in the status banner and the per-row download
  controls, where they are plain views in an `HStack`/`Label` and render normally. No
  `Image(systemName:)` was introduced.

The emoji vocabulary matches the spec's own `Ready to use ✅` / `Not ready ❌`.

## New test (the change did add model logic)

`DictationTabModelTests.theSubTabTitleCarriesItsOwnReadinessMarker` — asserts the active tab's
title carries `✅` when its model is downloaded and `❌` when it is not, and that the two
inactive tabs carry no marker at all. It also documents *why* the marker is in the string.

## Commands and output

```
$ swift test --package-path macos --filter DictationTabModelTests
✔ Suite DictationTabModelTests passed after 0.007 seconds.
✔ Test run with 31 tests in 1 suite passed after 0.008 seconds.
```

```
$ npm run test:swift
✔ Test run with 743 tests in 75 suites passed after 0.559 seconds.
```

(742 → 743: exactly the one new test. Nothing regressed.)

```
$ npm run test:scripts
# tests 228
# pass 228
# fail 0
```

```
$ touch macos/Sources/Macomprendo/UI/Settings/DictationTab.swift \
        macos/Sources/Macomprendo/UI/Settings/DictationTabModel.swift
$ swift build --package-path macos 2>&1 | grep -Ei "warning:|error:"
grep-exit=1        # no warnings, no errors
$ swift build --package-path macos
Build complete! (0.09s)
```

```
$ npm run gen
⚙️  Writing project...
Created project at /Users/frenzy/dev/macomprendo/macos/Macomprendo.xcodeproj
$ git status --short
 M macos/Sources/Macomprendo/UI/Settings/DictationTab.swift
 M macos/Sources/Macomprendo/UI/Settings/DictationTabModel.swift
 M macos/Tests/MacomprendoTests/UI/DictationTabModelTests.swift
```

No file was added, and `project.pbxproj` is untouched by the regen — `npm run gen` is a no-op
here, as expected.

## Files changed in this fix

- `macos/Sources/Macomprendo/UI/Settings/DictationTabModel.swift`
- `macos/Sources/Macomprendo/UI/Settings/DictationTab.swift`
- `macos/Tests/MacomprendoTests/UI/DictationTabModelTests.swift`

## What remains for a human to look at

Item 1 of my original list ("does the icon render inside the segmented control?") is now moot —
the marker is a character in the title, so it renders wherever the title does. Items 2–6 stand
unchanged: the benchmark grid inside the form, the length of the whisper tab, whether the
status block reads as intended at a glance, the length of the Threads menu on a many-core
machine, and a real dictation with `translate` on.

One aesthetic point I cannot judge without seeing it: `"GigaAM ✅"` renders the emoji in
colour, which is louder than the monochrome `Icon` set the rest of the app uses. If that reads
as out of place, the same `marker` property can become `"●"` / `"▲"` or any other always-
rendering glyph without touching the view or the tests' structure.

---

# Fix report — round 1, cut short (items 2 and 4 only)

Commit: `6854c4c fix(dictation): clamp the whisper thread count at both ends`

## State of items 1 and 3 when I stopped

Nothing from either is committed, and nothing from either is in the working tree.

- **Item 1 (seed the outgoing engine in `select(tab:)`)** — never started. No code, no test.
- **Item 3 (probe carries the probed `(id, model)`)** — I had written only the *test* side: an
  updated `BackendReadinessTests` with `.succeeded(id:model:)` payloads plus a new
  `aProbeOfADifferentServerOrModelCountsAsUntested`. No production code was touched — I had not
  yet changed `EndpointProbeResult`, `BackendReadiness.of`, or `probeEndpoint`. I reverted that
  file with `git checkout -- macos/Tests/MacomprendoTests/Features/BackendReadinessTests.swift`;
  `git status` afterwards showed only the item-2 test still modified.

For the record, the shape I was about to build, in case any of it is useful when the redesign
lands: change `EndpointProbeResult.succeeded` to `succeeded(id: UUID, model: String)`, record
it in `probeEndpoint` from the *configured* source rather than from the provider, and do the
comparison inside `BackendReadiness.of` — which already receives the source and is already
unit-tested — so a mismatch falls through to the existing "has not been tested yet" branch and
every future caller inherits the check. With the active model moving out of the sub-tabs, the
"which selection was probed" question probably belongs to that new selector instead.

## What I did change

**Item 2 — clamp `whisperThreads` at the top as well as the bottom.** `WhisperParams.make`'s
inline `max(1, …)` became a named helper, so the automatic path and the explicit path are
visibly different rules rather than one expression doing both:

```swift
private static func threadCount(_ requested: Int?, processorCount: Int) -> Int {
    guard let requested else { return max(1, processorCount - 2) }
    return min(max(1, requested), max(1, processorCount))
}
```

The `max(1, processorCount)` ceiling matters: clamping the automatic path against a raw
`processorCount` of 0 would have produced 0 threads on a machine that reports no cores.

**Item 4 — the view stops re-deciding what the model states.** `parametersSection` now branches
on `tab.activeTab.parameterSummary.isEmpty` instead of `tab.activeTab == .whisperCpp`, with a
comment noting that only the two local tabs reach it (the outer switch routes `.endpoint` to
its own section). Pure rendering change — no new model logic, so no test was invented for it.

## New test

`WhisperCppTranscriberTests.clampsAnExplicitThreadCountToTheCoresTheMachineHas` — covers the
upper end the way the existing tests cover 0 and −4: 100 000 on a 10-core machine → 10, 64 on a
1-core machine → 1, and 64 on a machine reporting 0 cores → 1.

RED before the fix (`swift test --package-path macos --filter WhisperCppTranscriberTests`):

```
✘ Test clampsAnExplicitThreadCountToTheCoresTheMachineHas() recorded an issue at WhisperCppTranscriberTests.swift:56:9: Expectation failed
✘ Test clampsAnExplicitThreadCountToTheCoresTheMachineHas() failed after 0.001 seconds with 3 issues.
```

All three assertions failed — the old code returned the requested count unchanged.

## Commands and output

```
$ swift test --package-path macos --filter WhisperCppTranscriberTests
✔ Suite WhisperCppTranscriberTests passed after 0.001 seconds.
✔ Test run with 19 tests in 1 suite passed after 0.001 seconds.
```

```
$ npm run test:swift
✔ Test run with 744 tests in 75 suites passed after 0.564 seconds.
```

(743 → 744: the one new test. Nothing regressed.)

```
$ touch macos/Sources/Macomprendo/UI/Settings/DictationTab.swift \
        macos/Sources/Macomprendo/Providers/WhisperCppTranscriber.swift
$ swift build --package-path macos 2>&1 | grep -Ei "warning:|error:"
grep-exit=1        # no warnings, no errors
$ swift build --package-path macos
Build complete! (0.08s)
```

No files were added, so `npm run gen` was not re-run in this round; `project.pbxproj` is
untouched.

## Files changed in this round

- `macos/Sources/Macomprendo/Providers/WhisperCppTranscriber.swift`
- `macos/Sources/Macomprendo/UI/Settings/DictationTab.swift`
- `macos/Tests/MacomprendoTests/Providers/WhisperCppTranscriberTests.swift`

---

# Fix report — round 2, the selection/navigation redesign (HANDOFF)

Commit: `5bd0178 refactor(settings): make model selection explicit and separate from navigation`
Stopped in **case 1**: the redesign is complete, the tree builds, both suites are green, and
`git status` is clean at `5bd0178`. Nothing is half-applied and nothing was reverted.

## The seven items

| # | Item | State |
|---|---|---|
| 1 | `select(tab:)` stops writing settings | **Done** — the method is gone entirely |
| 2 | Selector lists what is ready, keeps an unready active source, disables when nothing is ready | **Done** |
| 3 | One status block beside the selector, per-tab status removed | **Done** |
| 4 | Delete `lastModelByEngine` | **Done, fully** — field, default, `init(from:)` line and every test |
| 5 | Row "Use this model" as a shortcut for the selector | **Done** |
| 6 | Tab titles lose their readiness markers | **Done** — `TabIndicator`, `marker`, `indicator(for:)` and `tabTitle(for:)` all deleted |
| 7 | Probe carries the `(id, model)` it proved | **Done** |

Nothing was started and left unfinished; nothing was skipped.

### 1 — navigation writes nothing

`select(tab:)` is deleted. `DictationTabModel` gained `@Published var viewedTab`, initialised
in `init` from `Self.tab(of: holder.settings.transcriptionSource, in: catalog)` — a read. The
view binds the segmented picker straight to `$tab.viewedTab`. There is now no code path from
tab navigation to `Settings` at all, which is stronger than a guard: the downgrade-to-Tiny
sequence cannot be written.

`reveal(_ source:)` was added so a fix button can bring the relevant sub-tab into view
(Download switches to the model's tab, "Name a model" to the endpoint tab). Navigation only.

### 2 — the selector

```swift
struct SelectableSource: Identifiable, Equatable, Sendable {
    let source: TranscriptionSource
    let name: String
    let isReady: Bool
    var id: TranscriptionSource { source }
    var menuTitle: String { isReady ? name : "\(name) — not ready" }
}
```

`selectableSources` = every catalog model whose `isReady(.local(...))` holds, then the
configured endpoint if it is ready, then the active source appended as `isReady: false` if it
is not already in the list. `hasReadySource` / `selectorCaption` ("No model is ready — download
one below.", empty when the selector is usable) drive the disabled state.

`isReady(_ source:)` delegates to `BackendReadiness.of`, so the list and the status block
cannot disagree — one rule, one implementation.

`TranscriptionSource` gained `Hashable` (one word, synthesised) so the `Picker` can tag rows
with the source itself instead of a stringly-typed stand-in.

### 3 — one status block

The block moved into a header `HStack` beside the selector and now describes
`holder.settings.transcriptionSource`. There is no per-tab status of any kind.

### 4 — `lastModelByEngine`

Fully gone: the stored property, its line in `Settings.default`, its `decodeIfPresent` line in
`init(from:)`, and the two `SettingsTests` assertions that covered it (inside
`aDocumentWithoutTheNewSelectionKeysDecodesToEmptyDefaults` and
`theSelectionKeysSurviveARoundTrip`, both of which still exist and still cover the two
endpoint keys). `grep -rn "lastModelByEngine" macos/ --include='*.swift'` returns nothing.
`currentSchemaVersion` is still 2 — a removed key is simply ignored by `decodeIfPresent`.

`lastTranscriptionEndpointID` / `lastTranscriptionEndpointModel` stay and gained their new
purpose; the doc comment in `Settings.swift` was rewritten to say so.

### 5 — the row shortcut

`select(modelID:)` now just calls `activate(.local(modelID:))`. The button is offered **only
for a downloaded, non-active row**, which keeps the story coherent: you cannot activate
something that cannot run, so the only unready entry the selector ever shows is one that
*became* unready. A judgment call — the alternative (always offer it) is defensible too.

### 6 — `indicator(for:)` and the tab-title markers

Both deleted, along with `TabIndicator` and its `marker`. Nothing reads them; the segmented
picker renders plain `Text(candidate.title)`. Their two tests are deleted (listed below).

### 7 — the probe payload

```swift
enum EndpointProbeResult: Sendable, Equatable {
    case succeeded(id: UUID, model: String)
    case failed(String)
}
```

`BackendReadiness.of` matches `case .succeeded(let probedID, let probedModel) where probedID == id
&& probedModel == model` for `.ready`, and folds `case .succeeded, nil` into the existing "has
not been tested yet" branch — a mismatched success reads exactly like never having tested.
That is the one decision point, so the selector, the status block and any future caller all
inherit it.

## Bug I found in self-review, and fixed

**The Test button could never test an endpoint that was not already active.** `probeEndpoint`
took `AppModel.transcriberProvider`, which builds from `transcriptionSource`; with a local
model active — the normal case while configuring an endpoint — the cast to
`OpenAICompatibleTranscriber` failed and the probe reported "not an endpoint". The redesign
created this: under the old design the endpoint tab *was* the active source.

The signature is now
`probeEndpoint(using provider: (TranscriptionSource) async throws -> any TranscriptionProvider)`:
the model decides *what* to probe (its `configuredEndpoint`) and the caller only says how to
build a provider for a given source. `AppModel` gained
`transcriber(for source:) async throws -> any TranscriptionProvider`, so the view still never
constructs a provider. Two tests cover it, including one asserting the closure is handed the
configured endpoint while a local model stays active.

`configuredEndpointID` also falls back to `endpoints.first?.id`, so the Test button reaches the
server the picker is showing rather than reporting that nothing is configured.

## Every `DictationTabModel` test changed or deleted

Deleted (they asserted behaviour the redesign removes):

| Test | Why |
|---|---|
| `selectingATabMakesItsRememberedModelTheConfiguredSource` | tabs no longer configure anything |
| `selectingATabWithNoRememberedModelFallsBackToItsFirstEntry` | that fallback is the Tiny bug |
| `returningToATabRestoresWhatWasChosenThereRatherThanTheDefault` | per-tab restore is gone with `lastModelByEngine` |
| `selectingTheAlreadyActiveTabChangesNothing` | subsumed by `movingBetweenSubTabsChangesNothingButWhatIsOnScreen` |
| `onlyTheActiveTabCanShowAsReady`, `theActiveTabSaysSoEvenWhenItCannotRun` | `indicator(for:)` deleted |
| `theSubTabTitleCarriesItsOwnReadinessMarker` | tab titles carry no marker |

Renamed / rewritten:

| Was | Now | Why |
|---|---|---|
| `theActiveTabFollowsTheConfiguredSource` | `theSubTabShownOnOpenIsTheOneTheActiveModelBelongsTo` | same read, no write |
| `selectingAModelRecordsItAsThatEnginesRememberedChoice` | `activatingAModelMakesItTheConfiguredSource` + `theRowShortcutIsTheSelectorAndNotASecondSourceOfTruth` | the `lastModelByEngine` half is gone |
| `aReadyTabSaysThisIsTheActiveDictationModel` | `aReadySelectionSaysThisIsTheActiveDictationModel` | status is about the selection |
| `anUnreadyTabExplainsWhatIsWrongAndThatDictationWillFail` | `anUnreadySelectionExplains…` | same |
| `choosingAnEndpointRemembersItForNextTime`, `namingAnEndpointModelRemembersItForNextTime`, `returningToTheEndpointTabRestoresTheEndpointAndModelLastUsed` | `choosingAnEndpointRecordsItWithoutMakingItTheSource`, `editingTheAlreadyActiveEndpointKeepsTheSourceInStep` | configuring ≠ activating |
| `aSuccessfulProbeMarksTheEndpointReady` | `aSuccessfulProbeRecordsWhichServerAndModelItProved` | the payload |
| `probingSomethingThatIsNotAnEndpoint…` | same name, endpoint fixture | it now needs a configured endpoint to get past the new guard |

Kept unchanged: `eachTabListsOnlyItsOwnEnginesModels`, `anEndpointSourceIsNamedByItsModel`,
`gigaAMReportsThatItHasNoParametersToConfigure`, the two probe-invalidation tests, and all the
rendering helpers (`languagesText`, `threadChoices`, `threadLabel`, `benchmarkValue`,
`comparisonText`, `adopt`, `probeCaption`).

New: `movingBetweenSubTabsChangesNothingButWhatIsOnScreen`,
`theStatusBlockDescribesTheSelectionRatherThanTheTabBeingViewed`,
`theSelectorListsEveryDownloadedModelAndNothingElse`,
`theSelectorKeepsTheActiveSourceEvenWhenItIsNoLongerReady`,
`theSelectorIsDisabledAndSaysSoWhenNothingIsReady`, `theSelectorOffersAProbedEndpoint`,
`theSelectorDoesNotCallAnEndpointReadyOnAProbeOfAnotherServer`,
`aConfiguredButInactiveEndpointJoinsTheListOnceItHasBeenProbed`,
`theProbeTestsTheConfiguredEndpointEvenWhileALocalModelIsActive`,
`probingWithNoEndpointConfiguredSaysSoRatherThanReachingForTheActiveSource`,
`theSelectedModelIDIsNilOnAnEndpointSource`. In `BackendReadinessTests`:
`aProbeOfADifferentServerOrModelCountsAsUntested`.

## Verification

```
$ swift test --package-path macos --filter DictationTabModelTests
✔ Test run with 34 tests in 1 suite passed after 0.010 seconds.
$ swift test --package-path macos --filter 'DictationTabModelTests|BackendReadinessTests|SettingsTests'
✔ Test run with 64 tests in 3 suites passed after 0.008 seconds.
$ npm run test:swift
✔ Test run with 748 tests in 75 suites passed after 0.596 seconds.
$ npm run test:scripts
# tests 228
# pass 228
# fail 0
$ touch <every changed source> && swift build --package-path macos 2>&1 | grep -Ei "warning:|error:"
grep-exit=1        # no warnings, no errors
$ swift build --package-path macos
Build complete! (0.08s)
$ npm run gen && git status --short
# project.pbxproj untouched — no files were added this round
```

746 → 748 after the two probe tests; the round started from 744 and ends at 748 with six brief
tests deleted and thirteen added.

RED evidence for the redesign: the rewritten test file failed to compile against the old model
with exactly the new API missing —

```
error: value of type 'DictationTabModel' has no member 'viewedTab'
error: value of type 'DictationTabModel' has no member 'activate'
error: value of type 'DictationTabModel' has no member 'selectableSources'
error: value of type 'DictationTabModel' has no member 'hasReadySource'
error: value of type 'DictationTabModel' has no member 'selectorCaption'
error: enum case 'succeeded' has no associated values
```

and the probe bug's test failed on the closure arity before the fix.

## What a human should look at on screen

The selector is now the most important control and I have never seen it.

1. **The header row.** Selector on the left, status on the right, each `maxWidth: .infinity`.
   At 760 pt that should be roughly half and half, but a long status sentence ("… has not been
   downloaded yet. Large v3 Turbo is the selected backend, so dictation will fail until this is
   fixed.") may make the row tall and unbalanced. It may want to be stacked instead.
2. **The disabled selector on a fresh install.** It shows the active-but-unready entry
   ("Large v3 Turbo — not ready") greyed out, with "No model is ready — download one below."
   underneath. I chose that over an empty menu so the user's own setting stays visible; check it
   reads as informative rather than broken.
3. **The `Picker` label.** `Picker("Active model", …)` outside a `Form` renders label + menu
   inline; verify the label is actually visible and not clipped by the status block.
4. **Menu titles.** "OpenAI endpoint · whisper-1" and "GigaAM Multilingual Large CTC" are long;
   check the menu is not absurdly wide.
5. **The endpoint sub-tab's explanation** — "Configuring it here does not switch to it — once
   its test passes it joins the Active model list above." That sentence carries the whole
   configure-vs-activate distinction; if it does not land, the tab will confuse.
6. Everything from the first report that still stands: the benchmark grid inside the form, the
   length of the whisper tab, the Threads menu on a many-core machine, and a real dictation with
   `translate` on.

## Deferred, untouched (from the coordinator's list)

`languagesText` reused for a single benchmark language code; the not-ready state stated three
times on the selected row; `isProbing` never asserted mid-flight. Left for the whole-branch
review as instructed.
