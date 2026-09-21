# Post-Dictation Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After a dictation the glossary changed, show the inserted text in a floating panel with
the rewritten spans marked and the packs that fired named — without ever taking focus from the
application the text went into.

**Architecture:** A pure `CorrectionReview` value built from the normalisation result. A presenter
behind a protocol, shaped like the existing `HUDPresenting`, so every decision about whether and
what to show is unit-tested with a fake and only the `NSPanel` is smoke-tested. The panel reuses
`FloatingPanel`, which is already non-activating.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI, AppKit, Swift Testing, SwiftPM.

**Spec:** `docs/superpowers/specs/2026-09-17-post-dictation-review.md`
**Depends on:** `2026-09-17-02-glossary-packs-and-normalisation.md` — the normalisation result with
ranges and pack provenance is this plan's only input. Nothing here can be built before it.

## Global Constraints

- macOS 14+, Swift 6 strict concurrency; the presenter and view are `@MainActor`,
  `CorrectionReview` is a `Sendable` value.
- Dependencies point downward only: UI → Features → Core. Construct the window-backed presenter
  only in `AppEnvironment`.
- **The panel must never become key.** Insertion simulates ⌘V into the frontmost application; a
  panel that takes focus redirects the paste into itself. `FloatingPanel` already guarantees this
  (`canBecomeKey` false, `.nonactivatingPanel`) — do not build a new window type, and do not add
  `.titled` to its style mask.
- The panel appears only when normalisation reported at least one rewrite. Glossary off, or no
  hit, means nothing is shown.
- Presentation happens **after** a successful insertion, never before — a failed insert shows
  nothing.
- Per invariant 3, `NSPanel` behaviour is smoke-tested, not unit-tested. Everything upstream of it
  is unit-tested with a fake presenter.
- Never log transcript text at default level. The review value holds transcript content and must
  not reach a log line.

## File map

- `Core/CorrectionReview.swift`: the value — final text, and per rewrite the range, original,
  term, and owning pack name.
- `UI/CorrectionReview/CorrectionReviewView.swift`: marked-text rendering and the caption.
- `UI/CorrectionReview/CorrectionReviewPresenter.swift`: `FloatingPanel` host, auto-hide, hover
  pause.
- `Features/DictationController.swift`: present after a successful insert.
- `App/AppEnvironment.swift`: construction.
- `Tests/…/Fakes/FakeCorrectionReviewPresenter.swift`.

---

### Task 1: The review value

**Files:**
- Create: `macos/Sources/Macomprendo/Core/CorrectionReview.swift`
- Create: `macos/Tests/MacomprendoTests/Core/CorrectionReviewTests.swift`

**Interfaces:**
- Produces: `CorrectionReview` with `text: String` and `rewrites: [Rewrite]`, each carrying
  `range: Range<String.Index>`, `original: String`, `term: String`, `packName: String?`; plus the
  derived caption.
- Consumes: `NormalisationResult` from the glossary plan.

- [ ] **Step 1: Write the failing value tests**

```swift
@Test func isBuiltDirectlyFromTheNormalisationResult() {
    // no recomputation, no re-reading the glossary: the value is a projection
}

@Test func captionListsEachPackOnceInFirstOccurrenceOrder() {
    // two typescript rewrites and one personal -> "typescript, personal · 3 corrections"
}

@Test func manualTermsCaptionAsManual() {
    // packName nil -> "manual"
}

@Test func rangesIndexTheFinalText() {
    // `Safe Area View` -> `SafeAreaView` shortens the string; every range must be valid
    // against `text`, which is the correctness condition the view depends on
}
```

- [ ] **Step 2: Implement**

A plain value plus a pure caption function. No I/O, no dependencies above Core.

- [ ] **Step 3: Run `npm run test:swift` and confirm green**

---

### Task 2: The presenter protocol and the decision to show

**Files:**
- Create: `macos/Sources/Macomprendo/UI/CorrectionReview/CorrectionReviewPresenter.swift`
  (protocol only in this task)
- Create: `macos/Tests/MacomprendoTests/Fakes/FakeCorrectionReviewPresenter.swift`
- Modify: `macos/Sources/Macomprendo/Features/DictationController.swift`
- Modify: `macos/Tests/MacomprendoTests/Features/DictationControllerTests.swift`

**Interfaces:**
- Produces: `CorrectionReviewPresenting` with `present(_:)` and `dismiss()`.
- Consumes: `CorrectionReview`.

- [ ] **Step 1: Write the failing controller tests**

Every bullet in the spec's unit list, against the fake:

```swift
@Test func noRewritesPresentsNothing() async
@Test func glossaryOffPresentsNothing() async          // even when the text contains terms
@Test func oneRewritePresentsItWithItsOriginal() async
@Test func severalRewritesArePresentedInDocumentOrder() async
@Test func aFailedInsertPresentsNothing() async        // presentation follows insertion
@Test func aSecondDictationReplacesRatherThanStacks() async
```

- [ ] **Step 2: Add the protocol and the call**

`DictationController` holds the normalisation result at the point it calls `inserter.insert`.
After a successful insert, and only when `rewrites` is non-empty, build the review and present it.
The presenter is optional, as `HUDPresenting` is, so tests can omit it.

- [ ] **Step 3: Run `npm run test:swift` and confirm green**

---

### Task 3: The panel

**Files:**
- Modify: `macos/Sources/Macomprendo/UI/CorrectionReview/CorrectionReviewPresenter.swift`
- Create: `macos/Sources/Macomprendo/UI/CorrectionReview/CorrectionReviewView.swift`
- Modify: `macos/Sources/Macomprendo/App/AppEnvironment.swift`

**Interfaces:**
- Produces: the window-backed presenter and the SwiftUI view.
- Consumes: `FloatingPanel`, `CorrectionReview`.

- [ ] **Step 1: Build the view**

The text, wrapped, with each rewrite underlined green in the surrounding weight — not a colour
swap, which reads as an error. Hover on a marked span shows the original. The caption sits below.
Use `AttributedString` built from the ranges rather than splitting the text into views, so
wrapping behaves.

- [ ] **Step 2: Build the presenter**

`FloatingPanel(contentRect:ignoresMouse: false)` — mouse events are needed for hover, which is the
one behavioural difference from the HUD. Place it where the recording HUD sits, which is already
chosen to avoid the text caret. Auto-hide after 4 seconds; pause the timer while the pointer is
inside and restart on exit; `present` while visible replaces the content and restarts the timer.

- [ ] **Step 3: Wire it in `AppEnvironment`**

- [ ] **Step 4: Run `npm run test:swift` and confirm green**

---

### Task 4: Smoke tests and documentation

**Files:**
- Modify: `docs/SMOKE_TEST.md`, `CHANGELOG.md`

- [ ] **Step 1: Add the smoke steps**

- Dictate into TextEdit with a glossary hit: the text lands in TextEdit, the panel appears, and
  **the TextEdit caret still blinks** — this is the step that proves focus never moved, and it is
  the one that must never be skipped.
- Hovering the panel holds it open; moving away lets it fade.
- Dictating again while the panel is visible replaces its content.
- The panel is visible above a full-screen application.

- [ ] **Step 2: CHANGELOG under `Unreleased`**

- [ ] **Step 3: Full verification**

`npm run test:swift`, `npm run test:scripts`, `npm run audit`,
`swift build --package-path macos` (no new warnings), `npm run gen` (no-op), then
`npm run install-app:signed` and the smoke steps.

- [ ] **Step 4: Judge the timing**

Use it for a day before touching the 4-second duration. If it reads short, the spec's suggestion —
2 s plus 1 s per rewrite, capped — is a one-line change. Do not tune it before using it.
