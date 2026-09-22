# Post-dictation review: showing what the glossary changed

Status: **approved 2026-09-17.**

Builds on: `ADR-0013-glossary-reaches-each-backend-differently`,
`2026-09-17-glossary-packs-and-normalisation.md` (which produces the ranges this spec renders).

## Problem

Normalisation rewrites the text between the model and the user's document, silently. That is the
point of it, and it is also its danger: when a rule fires wrongly — `UV` in an unrelated sense
collapsing to `uv`, a two-letter term eating a real word — the user sees a document that does not
match what they said and has no way to learn why. The transcript in history holds `raw_text`, but
nothing surfaces it at the moment it matters.

The glossary is also unfalsifiable from the user's chair. "Did the dictionary help today?" has no
answer if its work is invisible. Seeing which words it touched, as they are touched, is what turns
a feature into something the user can judge and tune.

## Goals

1. After a dictation whose text the glossary changed, show the inserted text with the changed
   spans marked.
2. Never take focus from the application the text was inserted into.
3. Stay out of the way: nothing appears when nothing changed.

## Non-goals

- **Undoing a correction.** Clicking a marked word to revert it means editing text already
  delivered to another application, through a second round of simulated keys at a position we do
  not know. Out of scope, and probably out of scope permanently.
- **Jumping to the rule.** Opening the pack that owns a term is cheap and useful, and still not
  this iteration.
- **Showing the raw transcript side by side.** One line, with the original available on hover.
- **A history of reviews.** The history window already stores both texts; this is a transient
  signal, not a log.
- **Showing anything for refine, summarize or speak.** Dictation only, where the glossary runs.

## Behaviour

**When it appears.** Only when normalisation reported at least one changed range. With the
glossary off, or with no term hit, nothing is shown — so on a quiet day the feature is invisible,
and its appearance is itself information.

**Where.** Top of the screen the mouse is on, in the band immediately below the recording HUD's
own, reusing `FloatingPanel`
(`UI/Components/FloatingPanel.swift`): borderless, `.nonactivatingPanel`, `canBecomeKey` false,
`level = .floating`, `collectionBehavior` spanning spaces. It cannot share the HUD's placement:
a successful insertion ends by showing the `Inserted` HUD, which is ordered front last and would
sit on top of the text this panel exists to show. The panel flags are not a preference — the
insertion path simulates ⌘V into the frontmost application, so a panel that becomes key would
redirect the paste into itself. The existing panel already guarantees it cannot.

**What it shows.** The inserted text, wrapped, with each changed span marked. Marking is a green
underline plus the term's canonical spelling in the surrounding weight — not a colour swap, which
reads as an error state. Hovering a marked span shows what the model originally produced.

A caption names the packs that fired: `typescript · 3 corrections`, or
`typescript, personal · 4 corrections` when several contributed. The normalisation result carries
the owning pack per rewrite, so this costs nothing to render and makes a misbehaving pack
identifiable without opening Settings. Terms from the manual list report no pack and are captioned
`manual`.

**How long.** Auto-hides after 4 seconds, the timing `HUDController.autoHideDuration` already uses
for `.error`, because this is text to read rather than a status to glance at. The timer pauses
while the pointer is over the panel and restarts on exit. A new dictation replaces the content
immediately: the previous correction is no longer interesting.

**Mouse.** `FloatingPanel` defaults to `ignoresMouse: true`; this panel passes `false`, because
hovering is how the original text is read. That is the one behavioural difference from the HUD,
and it means the panel must not sit under the text caret — same top-of-screen rule the HUD
already follows, one band lower.

**When it goes.** Besides the timer, the start of the next dictation takes it down. Every exit
from a cycle other than a successful insert with at least one rewrite — nothing heard, a
cancellation, a failed transcription, a failed insert, a dictation the glossary did not change —
presents nothing of its own, so without a dismissal at the recording boundary the previous
dictation's corrections would keep describing text the user has moved past.

## Wiring

`DictationController` already holds the normalisation result (text plus ranges, per the
normalisation spec) at the point it calls `inserter.insert`. After a successful insertion, and
only if ranges are non-empty, it asks the presenter to show them.

The presenter is a protocol in the shape `HUDPresenting` already has:

```swift
@MainActor
protocol CorrectionReviewPresenting: AnyObject {
    func present(_ review: CorrectionReview)
    func dismiss()
}
```

with `CorrectionReview` a pure value: the final text and, per rewrite, its range in that text, the
original substring, the canonical term, and the owning pack name (`nil` for the manual list). The
value is built directly from the normalisation result and adds nothing to it. `AppEnvironment` constructs the window-backed implementation; tests inject a
fake and assert what was presented, so every decision about *whether* and *what* is unit-tested
and only the `NSPanel` itself is smoke-tested (invariant 3).

`HUDController` is deliberately not extended with a new `HUDState` case. The HUD's states are all
transient status; this panel holds readable text with hover behaviour and a different lifetime,
and folding it in would make one controller serve two purposes.

## Testing

Unit, with a fake presenter:

- ranges empty → nothing presented
- glossary off → nothing presented, even when the text contains glossary terms
- one changed range → presented once, with that range and its original substring
- several ranges in one transcript → all present, in document order
- presentation happens after insertion, not before: a failed insert presents nothing
- a second dictation replaces rather than stacks
- starting a dictation dismisses a panel still on screen, including when that dictation never
  presents one of its own (transcription failure, nothing heard, no rewrite)
- the review value carries the original substring for each range, so hover has data without
  re-reading the database
- the caption lists each contributing pack once, in first-occurrence order, and counts every
  rewrite; a manual-list term captions as `manual`

Pure:

- range mapping survives a correction that changes length (`Safe Area View` → `SafeAreaView`
  shortens the text; the reported ranges must index the *final* string, not the original)

Smoke (`docs/SMOKE_TEST.md`), because `NSPanel` behaviour is not unit-testable:

- dictate into TextEdit with a glossary hit: the text lands in TextEdit, the panel appears, and
  the TextEdit caret still blinks — focus never moved
- hovering the panel holds it open; moving away lets it fade
- dictating again while the panel is visible replaces its content
- the panel is visible above a full-screen application

## Deliverables

- `Core/CorrectionReview.swift` — the value: final text, ranges, originals, terms, pack names.
- `UI/CorrectionReview/CorrectionReviewView.swift` — the marked-text rendering.
- `UI/CorrectionReview/CorrectionReviewPresenter.swift` — `FloatingPanel` host, auto-hide,
  hover pause.
- `Features/DictationController.swift` — present after a successful insert.
- `App/AppEnvironment.swift` — construction.
- `Tests/…/Fakes/FakeCorrectionReviewPresenter.swift`.
- `docs/SMOKE_TEST.md`, `CHANGELOG.md`.

## Open questions

1. *(decided 2026-09-17)* 4 seconds, tuned later if it reads short. The hover pause covers a user
   who is looking; a duration proportional to the number of corrections is a one-line change once
   the panel exists, and there is no point guessing at it before using the thing.
2. *(resolved 2026-09-17)* The panel names the packs that fired. The normalisation spec now
   carries the owning pack per rewrite, so the caption is free to render.
