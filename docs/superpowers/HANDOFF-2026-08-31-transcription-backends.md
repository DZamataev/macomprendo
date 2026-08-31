# Handoff — transcription backends catalog

Paused 2026-08-31. Branch `feat/transcription-backends-catalog`, 15 commits on top of `main`.

**Read these three, in order, before touching anything:**

1. `docs/superpowers/specs/2026-08-31-transcription-backends-catalog-design.md` — the design of record. Amended twice mid-flight; it is current.
2. `docs/superpowers/plans/2026-08-31-08-transcription-backends-catalog.md` — the 11-task plan. **Tasks 9's text is now partly superseded by the spec** (see Task 9 below).
3. `.superpowers/sdd/2026-08-31-08-transcription-backends-catalog/progress.md` — the ledger. Every task's outcome, every deferred minor, every ruling.

## Where the work stands

| Task | State |
|---|---|
| 1 Catalog data model | complete, review clean |
| 2 Multi-file downloads | complete, review clean, 1 fix round |
| 3 Vendor sherpa-onnx | complete, review clean |
| 4 `GigaAMTranscriber` | complete, review clean |
| 5 Factory engine dispatch | complete, review clean |
| 6 GigaAM entries + hash script | complete, review clean, 1 fix round |
| 7 Readiness + endpoint probe | complete, review clean, 1 fix round |
| 8 Per-engine selection memory | complete, review clean — **but see the redesign** |
| 9 Tabbed Dictation settings | **IN FLIGHT, redesigned mid-task** |
| 10 HUD model caption | not started |
| 11 ADR, docs, signed build | not started |

Suites at the pause: **744 Swift / 75 suites**, **228 Node**, `swift build` clean, `npm run gen` a no-op.
Baseline when this started was 661 Swift / 218 Node.

## The one thing a newcomer will get wrong

**Task 9 was redesigned by the user partway through, and the plan file still describes the old design.** The spec is right; the plan is stale on this task only.

- **Old design:** the active sub-tab *was* the selection. Opening a tab changed what transcribed.
- **New design:** an explicit active-model selector above the tabs, listing only ready-to-use backends. Tabs are pure navigation.

The change was not cosmetic. Under the old design, with no per-engine memory recorded yet, opening the GigaAM tab to read a brief and returning to whisper.cpp silently replaced Large v3 Turbo with the catalog's first entry, **Tiny** — a model the user never chose and almost certainly had not downloaded. Separating navigation from selection removes the class instead of warning about it.

Consequences already decided and recorded in the spec:

- `Settings.lastModelByEngine` is **deleted** — its only reader was per-tab restore. `lastTranscriptionEndpointID` / `lastTranscriptionEndpointModel` **stay**, and gain a clearer purpose: configuring an endpoint without activating it. This partly undoes Task 8, which is fine; Task 8 shipped what the design asked for at the time.
- One status block beside the selector, describing the **selected** model. No per-tab status.
- The selector always lists the current selection even when it is not ready (a `Picker` whose selection is absent from its options has no defined rendering), and is disabled with "No model is ready — download one below" when nothing qualifies.
- Tab-title readiness markers go away; they meant "this tab is your backend", which is no longer true of any tab.

Ruling **R9** in the ledger (seed the outgoing engine in `select(tab:)`) is **superseded** — that bug cannot occur once tabs stop writing settings. Do not implement it.

## What has never been verified, and cannot be from here

1. **The C decode path has never executed.** No real `.onnx` exists in the repo, so every GigaAM test exercises planning logic and input guards — never `SherpaOnnxCreateOfflineRecognizer` or the decode calls. A green suite says nothing about whether transcription works. **Task 11's smoke test is the first real proof.**
2. **Nobody has seen the Dictation screen.** It was written without running the app, and this environment has no macOS screenshot capability. Named risks: the benchmark `Grid` inside a horizontal `ScrollView` inside a grouped `Form`; the whisper tab's length with nine briefed rows; whether the status banner reads as "this is your backend" at a glance; the Threads menu on a many-core machine; and ✅/❌ emoji against an otherwise monochrome icon set.
3. **The dynamic-framework path in `scripts/build-app.mjs` has never run.** whisper's slices are static, so `listFrameworks` has always returned empty. `SherpaOnnxC.framework` is the first. Task 11 covers it with a real signed build plus `codesign --verify --deep --strict`.
4. **The RNN-T transducer path** depends on sherpa selecting the NeMo implementation from the encoder's ONNX metadata. Verified present (`model_type=EncDecRNNTBPEModel`, `vocab_size=1024`, `subsampling_factor=4`) but never exercised. If CTC transcribes and RNN-T returns garbage in the smoke test, that metadata is the place to look.

## Deferred minors

17 recorded in the ledger, all marked `minor (deferred)`. The final whole-branch review is supposed to triage which must be fixed before merge. The ones with the most substance:

- `ModelCatalog.swift` grew 138 → 231 lines carrying six type declarations plus two per-engine data blocks with very different churn rates; a split into a types file plus one file per engine was recommended.
- The resume-a-partial-set download path has no test.
- `isComplete` uses `allSatisfy`, so an empty file set reports `.downloaded`; guarded today only by a catalog test asserting `files.count == 1`, which Task 4/6 already relaxed in spirit.
- The gzip/`Content-Length` quirk on the hash script's HEAD-only path is documented only in a report, not in the code.
- A corrupt-but-present model file maps to `.modelMissing`, whose recovery text says "download it".

## Out-of-band work done during this branch

A pre-existing flaky test was diagnosed and fixed here (`0700719`) because it produced false failures on every verification run. `levelUpdatesStillReachTheHUDAfterAnEarlierRecordingHitTheCap` waited on `inserter.inserted`, which is populated two statements before the cycle clears `isInserting` and settles `state`; the test then pressed the hotkey, `begin()`'s `guard !isInserting` returned without assigning a task, and the following `await activeTask?.value` awaited the previous cycle. Both affected sites now wait on the terminal state. Verified over four consecutive rebuild-then-test cycles.

A session was spawned from a chip carrying an **earlier, wrong** diagnosis of that same test (it proposed waiting for `.recording`, which would have timed out since no task is ever started in that window). If that session is still open it should be stopped or corrected.

## Product observation, not fixed

`DictationController.begin()`'s `guard !isInserting` drops the hotkey press **silently** — no toast, no HUD feedback. A user pressing dictate right after a paste gets nothing at all. The guard is deliberate and documented; its silence may not be.

## How to resume

Re-enter with `superpowers:subagent-driven-development`, pointed at the plan. The ledger's identity line names the plan file; tasks with a `complete (commits …)` line are done and must not be re-dispatched. Resume at Task 9, whose brief needs regenerating from the amended spec rather than from the stale plan text — or amend the plan's Task 9 first, which is the tidier option.
