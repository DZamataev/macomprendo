# Settings rework: hotkeys in the menu, per-language prompts and voices, dock icon, panel playback

Status: approved 2026-08-28.
Builds on: `2026-08-23-macomprendo-design.md` (§3.5 Settings, §4 prompt presets),
`2026-08-26-mixed-language-speech.md` (`LanguageSegmenter`, `AVSpeechService.utterancePlan`,
`SpeechRouter`).

## Problem

Six unrelated-looking complaints share two roots — settings that do not carry the user's
language, and UI that hides what the app is actually doing:

1. The menubar menu lists the five actions with checkmarks but never says which key fires
   them, so the menu cannot be used to remember a hotkey.
2. "Models" is a whole tab holding one list that only matters while configuring dictation,
   and the Dictation tab has to send the user there with a caption.
3. Speech picks the per-script fallback voice by itself (`ru-RU` for Cyrillic, `en-US` for
   Latin). The user cannot say which voice reads which language, cannot change the preview
   text, and is never told that segmentation exists — let alone switch it off.
4. Refine and Summarize prompts exist only in English, and the language of the result is
   whatever the model infers. There is no persisted notion of "the language I work in".
5. The app is `LSUIElement`, so the onboarding wizard and the Settings window live without a
   Dock icon: they vanish behind other windows with no way to bring them back except the
   menubar.
6. The Quick Panel can copy or insert its text but cannot read it aloud. Hearing a refined
   sentence or a summary means dismissing the panel, reselecting the text and pressing the
   Speak hotkey. Speech itself is also all-or-nothing: it can be started and stopped, never
   paused.

## Goals

1. The menubar menu shows each action's current shortcut next to its checkmark.
2. The Models tab is gone; its content is a section of the Dictation tab.
3. System speech gets an explicit voice per language, an editable preview text, a plain
   explanation of the segmentation, a switch that turns segmentation off, and an option to
   audition a voice the moment it is picked.
4. Refine and Summarize get a persisted working language with its own factory prompt set,
   switchable from Settings *and* from the Quick Panel windows.
5. A Dock icon appears while the onboarding wizard or the Settings window is open and
   disappears when the last of them closes.
6. The Quick Panel can speak, pause, resume and stop its own text, on both speech sources.

## Non-goals (YAGNI)

- Migrating existing settings documents. The app has not shipped; a document written by an
  older build loses its presets and re-seeds. No migration code beyond decoding a missing
  key to its default.
- Localizing the app's own UI. Only prompt content is per-language; menus, labels and error
  text stay English.
- Per-language transcription prompts, or coupling `transcriptionLanguage` to
  `promptLanguage`. They stay independent settings.
- Segmentation for the endpoint speech source. The server-side model code-switches natively.
- A Dock icon for the HUD or the Quick Panel. They are `NSPanel`s and never own the icon.
- Seeking, scrubbing or skipping within speech, and any progress indicator. See Part 6 for
  why this is deferred rather than merely unbuilt.

## Settings schema

`Settings.currentSchemaVersion` goes 1 → 2. Every new key decodes to its default through the
hand-written `init(from:)` that `Settings` and `SpeechSettings` already use, and
`PromptPreset` gains one of the same shape.

| Type | Change |
|---|---|
| `PromptPreset` | **+** `language: String` — base code (`en`, `ru`, …). Missing in a stored preset → `"en"`. |
| `Settings` | **+** `promptLanguage: String` — the working language for Refine & Summarize. Default: the OS language's base code when it is one of the seven, else `"en"`. |
| `Settings` | **−** `presetsSeeded: Bool` **+** `seededPromptLanguages: [String]` — which languages have been seeded. |
| `Settings` | **−** `defaultRefinePresetID` / `defaultSummarizePresetID` **+** `defaultPresetIDs: [String: UUID]` keyed `"<kind>.<language>"`, e.g. `"refine.ru"`. |
| `SpeechSettings` | **+** `voiceByLanguage: [String: String]` — base language code → voice identifier. An absent key means "pick automatically". |
| `SpeechSettings` | **+** `segmentationEnabled: Bool` — default `true` (today's behaviour). |
| `SpeechSettings` | **+** `previewText: String` — default is deliberately mixed-script, so the Preview button demonstrates segmentation: `"Macomprendo can read your selected text out loud. Макомпрендо читает выделенный текст вслух."` |
| `SpeechSettings` | **+** `auditionOnSelect: Bool` — default `true`. |

`voiceByLanguage` is keyed by the **base** code (`ru`, not `ru-RU`) because that is what
language detection returns; the Speech tab groups the installed regional variants under one
base-language row.

Accessor changes on `Settings` (every call site updated):

```swift
func presets(of kind: PresetKind, language: String) -> [PromptPreset]
func defaultPreset(for kind: PresetKind, language: String) -> PromptPreset?
mutating func setDefaultPreset(id: UUID, for kind: PresetKind, language: String)
```

`addPreset`, `updatePreset`, `deletePreset` and `movePreset` keep their signatures; ordering
and the "at least one of a kind must exist" rule now apply within a kind **and** language.

## Part 1 — hotkeys in the menubar menu

`MenuBarView`'s per-action row becomes a `Toggle` whose label is an `HStack` of the display
name, a `Spacer`, and the shortcut in `.secondary`. The shortcut string comes from
`KeyboardShortcuts.getShortcut(for: .forAction(action))?.description` — `"⌥Space"`,
`"⌥⇧Space"` — and reads `"not set"` when no shortcut is bound (`refineSelection` ships
unbound today).

Formatting lives in a pure, testable helper next to `HotkeyAction`:

```swift
extension HotkeyAction {
    /// `shortcut` is the description from KeyboardShortcuts, or nil when unbound.
    func menuTrailing(shortcut: String?) -> String
}
```

*Amended after execution.* The design first drafted this as
`static func menuLabel(name:shortcut:) -> (title:, trailing:)`. The title half was never used —
the row already renders the action's display name itself — so what shipped is the instance
method above, returning only the trailing text (`"⌥Space"`, or `"not set"` for an unbound or
blank shortcut).

The library's `shortcutByNameDidChange` notification is `internal` and unavailable to us, and
it is not needed: `MenuBarExtra` re-evaluates the menu body each time the menu opens, so a
shortcut changed in Settings ▸ Hotkeys shows up the next time the menu is opened.

## Part 2 — the Models tab moves into Dictation

`ModelsTab.swift` is deleted and the tab is removed from `SettingsView`. `DictationTab` gains
a `Section("Speech models")` below "Transcription source" holding what `ModelsTabContent`
rendered: one row per catalogue entry with its size and state control (Download / progress +
Cancel / Ready + Delete / error + Retry), the disk-usage line and the Refresh button.

`ModelsViewModel` is unchanged. The rows render as a plain `ForEach` inside the `Section`
rather than a nested `List`, which behaves badly inside a `Form`. The two captions in
`DictationTab` that currently say "in the Models tab" now point below.

## Part 3 — per-language voices, editable preview, segmentation switch

### Language detection

A new protocol next to its default implementation, `Services/LanguageDetector.swift`:

```swift
protocol LanguageDetecting: Sendable {
    /// Base language code ("ru", "en", "de"), or nil when the text is too short or unclear.
    func dominantLanguage(of text: String) -> String?
}

struct NLLanguageDetector: LanguageDetecting { /* NLLanguageRecognizer */ }
```

`Tests/…/Fakes/ScriptedLanguageDetector.swift` returns a scripted answer per input so
`utterancePlan` stays deterministic and testable without NaturalLanguage.

### The utterance plan

`AVSpeechService.utterancePlan` stays `nonisolated static` and pure; the detector arrives as
a parameter. `LanguageSegmenter` is **not** changed — its asymmetric merge rules solve a
different problem (not flipping the voice for one short foreign word) and still apply.

1. `settings.segmentationEnabled == false` → one utterance with the whole text and
   `settings.voiceID`. Byte for byte the behaviour from before segmentation existed.
2. Otherwise split with `LanguageSegmenter.runs(in:)` as today.
3. A neutral run (digits, punctuation) keeps `settings.voiceID` and is never detected.
4. When `voiceByLanguage` is empty, detection is skipped for every run: it exists only to key
   that map, so asking `NLLanguageRecognizer` per run on the main actor would be pure cost in
   the default configuration.
5. Otherwise, for each non-neutral run with at least `AVSpeechService.minDetectionLetters` (12)
   letters, ask the detector for a language. Shorter runs skip detection —
   `NLLanguageRecognizer` guesses on short input, and a wrong guess is worse than the
   script-based fallback.
6. The run's voice is the first of: `voiceByLanguage[detected]` when that voice is installed →
   **`settings.voiceID` when the run is in the configured voice's own script** →
   `fallbackVoice(for: run.script, in: voices)` (today's automatic pick) → `settings.voiceID`.
7. If every run resolved to the **same** voice, emit a single utterance holding the original
   text — the existing optimisation, widened so that two languages mapped to one voice also
   collapse instead of producing an audible boundary per run.

The per-language map therefore **replaces the automatic pick where the user made one** and
leaves it in place everywhere else.

*Amended after execution.* Step 6's middle clause was missing from the four-item list this
spec first carried; the code has always had it, and it is what keeps a Latin run on a
deliberately chosen Latin default instead of substituting `fallbackVoice`'s idea of the best
`en-US` voice. Steps 3, 4 and the "same voice" wording in 7 record what shipped.

### The 12-letter threshold and what it actually gates

The threshold in step 5 gates the **map lookup**, not merely detection, and that is wider than
it first reads. Any Latin run under 12 letters falls through to `settings.voiceID`: a user who
mapped `es` to a Spanish voice hears their English default read "Buenos días" (10 letters),
with no mixed-language sentence involved at all.

This is deliberate and stays. Below a dozen letters `NLLanguageRecognizer` guesses, and a
confidently wrong guess picks a worse voice — for a whole sentence — than the script-based
fallback does for a fragment. It is written down here so it is not rediscovered as a bug. A
cheap future refinement that keeps the same rationale: for a run below the threshold, reuse the
language detected for the nearest same-script run in the same text, and fall back to script
only when there is none. Neither the threshold nor the fallback chain changes in this
iteration.

### Speech tab, system source

The pane becomes scrollable and contains, in this order:

- **Default voice** — the existing grouped voice list, writing `voiceID`. It is the voice for
  languages with no mapping and the only voice when segmentation is off.
- **Switch voices for mixed-language text** — the `segmentationEnabled` toggle, with prose
  under it explaining that text is cut into runs of a single script, each run's language is
  detected, and the run is read by the voice mapped to that language; and that short Latin
  fragments inside Cyrillic text deliberately stay on the Cyrillic voice.
- **Voice per language** — one row per base language that has installed voices. Each row is a
  picker of "Auto" plus every voice in that language, regional variants included (`en-US` and
  `en-GB` sit under one "English" row). `SpeechTabModel.group` regroups from the full tag to
  the base code; `VoiceGroup.language` becomes the base code and `displayName` its localized
  name. Dimmed, heading included, while segmentation is off.
- **Preview** — `previewText` in an editable `TextField(axis: .vertical)`, next to the
  existing Preview button. `SpeechTabModel.sampleText` stops being a constant and becomes the
  default value of the field.
- **Play a sample when a voice is selected** — the `auditionOnSelect` toggle.

*Amended after execution.* The toggle sits above "Voice per language" rather than below it, so
the explanation of what switching means is read before the map it controls, and the dimming it
causes is visible in the section directly under it.

Nothing above is shown for the endpoint source, which keeps its current form.

### Auditioning a voice

When `auditionOnSelect` is on, picking a voice — in "Default voice" or in a per-language row
— immediately speaks a short phrase in that voice. This needs no new protocol method:
`SpeechTabModel` copies the current `SpeechSettings`, sets `source = .system`,
`voiceID = <the picked voice>` and `segmentationEnabled = false`, and calls the existing
`speak(_:settings:)`. Forcing `segmentationEnabled = false` is what guarantees the phrase is
heard in the picked voice rather than being re-segmented away from it.

The phrase comes from a small table keyed by base language, covering the seven languages the
prompt sets cover; for any other language the voice's own name is spoken, which is what macOS
System Settings does. Auditions are only triggered by user interaction, never by loading the
tab; `AVSpeechService.speak` already stops the synthesizer first, so rapid switching cancels
the previous audition.

## Part 4 — per-language prompts for Refine and Summarize

### Roles, languages and stable IDs

`FactoryPresets.Role` — 12 cases. `PromptLanguage` — 7 cases, displayed by endonym. A
preset's UUID is derived from the pair, so the set is stable without a hand-written table:

```
F0000000-0000-0000-<language slot>-<role slot>
```

| Role | Kind | Slot |
|---|---|---|
| `cleanUp` | refine | `000000000001` |
| `formal` | refine | `000000000002` |
| `casual` | refine | `000000000003` |
| `shorten` | refine | `000000000004` |
| `expand` | refine | `000000000005` |
| `fixGrammar` | refine | `000000000006` |
| `translate` | refine | `000000000007` |
| `translateAndOrganize` | refine | `000000000008` |
| `brief` | summarize | `000000000101` |
| `bullets` | summarize | `000000000102` |
| `tldr` | summarize | `000000000103` |
| `keyActions` | summarize | `000000000104` |

| Language | Code | Slot |
|---|---|---|
| English | `en` | `0000` |
| Русский | `ru` | `0001` |
| Español | `es` | `0002` |
| Deutsch | `de` | `0003` |
| Français | `fr` | `0004` |
| Português | `pt` | `0005` |
| 中文 | `zh` | `0006` |

English is slot `0000`, so all eleven IDs that `FactoryPresets` already ships keep exactly the
values they have today and `restoreMissing` keeps telling a deleted factory preset from a
custom one without special-casing.

`translateAndOrganize` is new: translate the text and tidy its structure at the same time.

### Template content

One file per language, `Features/Prompts/Factory/FactoryPresets+<Language>.swift`, each
supplying that language's `systemPrompt` and, per role, a name and a user template — all
written in that language, preset names included. Swift source rather than a bundled JSON
resource: the templates stay compile-checked, and no new load-failure path is introduced
(invariant 8).

Content rules:

- Every role except the two translating ones states, in its own language, that the original
  language of the text must be preserved.
- `translate` is the only template that keeps the `{language}` placeholder, and it resolves to
  the **OS** language rather than to `promptLanguage`. This is intentional, not an oversight:
  Translate means "put this into the language I read my Mac in", which is the one target that
  needs no further input; the preset whose target is the working language is
  `translateAndOrganize`, which names it literally. The consequence — the Russian Translate
  preset on an English Mac reads «Переведи … на English» — is accepted, and the user retains
  the instruction field for any other target.
- `translateAndOrganize` translates into the preset's **own** language, written literally in
  the template rather than through a placeholder. The Russian one says "переведи на русский и
  приведи в порядок структуру".
- `{instruction}` and `{text}` behave exactly as today. `PromptRenderer` and its validation
  are unchanged.

### Seeding

`FactoryPresets.seed(into:)` seeds every language absent from `seededPromptLanguages` and
appends it to that list, so adding an eighth language later is one new file plus one enum
case. It is the **authority** for a language's presets existing, and it is idempotent per
preset **ID**, not merely per `seededPromptLanguages` entry: a document written before that key
existed already holds the eleven English presets (they decode with `language == "en"`) and
would otherwise have them seeded a second time. It also reads which kinds already have a
default before adding anything, so `addPreset`'s "claim the default when there is none" rule
cannot hand it to whichever preset happened to be missing.

`restoreMissing(into:)` restores missing factory presets across all seven languages and repairs
a dangling default for every `kind × language` pair. It sits behind the "Restore factory
presets" button and runs only on demand; its own `seededPromptLanguages` repair is a
belt-and-braces no-op for any document `seed` has seen.

### Settings ▸ Refine & Summarize

`PromptsTab` gains a language picker beside the existing Refine/Summarize control. The list,
the editor, the default marker and the test run all operate within the shown language.
`add()` and `duplicate()` create the preset in the shown language. `restoreFactory()`
restores across all languages.

The shown language is read from `Settings.promptLanguage` on every access rather than cached in
the tab's model: the Quick Panel's globe menu writes the same setting, so a copy taken when the
tab was built would leave it listing another language's presets.

*Known limitation, deliberately not fixed here.* `PromptsTabModel.runTest()` renders
`PromptsTabModel.sampleText` — an English scrap of dictation — whatever language is shown. So
"Test with sample text" on the Russian "Причесать" preset exercises the Russian prompt against
English input. The prompt itself is what is under test and the run is still informative, so
per-language sample text is left for a later iteration rather than added in a fix wave.

### The Quick Panel windows

`RefineLayout` and `SummaryLayout` get a compact language menu (globe icon) to the left of the
preset picker. Choosing a language:

1. writes `settings.promptLanguage`, so the choice is persisted and survives a relaunch;
2. moves `selectedPresetID` to that language's default preset for the kind;
3. reruns **once**, so one click reprocesses the same text with the other language's prompt
   set. The preset picker is bound through the controller rather than through
   `.onChange(of: selectedPresetID)`, which would also fire for the programmatic write in step
   2 and start a second, immediately cancelled stream.

A language can also be switched in Settings while the panel is closed, and `selectedPresetID`
outlives a panel session — so the rule for "which preset does this run use" is that a stored
selection counts only while it matches the controller's kind **and** `promptLanguage`,
otherwise that language's default wins. It is applied both when the panel opens and when a run
starts, and it lives in one place, `PromptLanguageSwitching`, which both controllers adopt.

To write settings, `RefineController` and `SummarizeController` swap their
`settings: @MainActor () -> Settings` parameter for `holder: any SettingsHolding` — the
pattern `SpeechTabModel`, `PromptsTabModel` and `QuickPanelController` already use, with
`ScriptedSettingsHolder` already available to the tests. In `TextFeatures.live` this is one
line per controller.

## Part 5 — the Dock icon

A new OS-facing protocol beside its implementation, `Services/ActivationPolicyService.swift`:

```swift
@MainActor protocol ActivationPolicyControlling: AnyObject {
    func setDockIconVisible(_ visible: Bool)
}
```

The default implementation calls `NSApp.setActivationPolicy(.regular)` / `.accessory`.

Above it, `Features/DockIconCoordinator.swift` holds the policy:

```swift
@MainActor final class DockIconCoordinator {
    enum Owner: Hashable { case settings, onboarding }
    func open(_ owner: Owner)     // → setDockIconVisible(true)
    func close(_ owner: Owner)    // → setDockIconVisible(!owners.isEmpty)
}
```

The owner set — rather than a boolean — is what keeps the icon alive when both windows are
open and only one closes. The coordinator is pure logic tested against a fake; all AppKit
lives in the service. It is constructed in `AppEnvironment` like every other service.

Wiring: `OnboardingWindowController` calls `open(.onboarding)` when it shows the window and
`close(.onboarding)` from a new `NSWindowDelegate.windowWillClose`. The `open(.settings)` /
`close(.settings)` pair hangs off the SwiftUI `Settings` scene in `MacomprendoApp.swift`, as
`.onAppear` / `.onDisappear` modifiers on the scene's content — not inside `SettingsView`,
which is also the view under test and has no business owning an app-wide activation policy.

**Known risk.** A SwiftUI `Settings` scene exposes no window handle, and `.onDisappear` on it
is not a guaranteed contract. If a live run shows it does not fire on close, the fallback is a
thin glue object observing `NSWindow.willCloseNotification` and reconciling against
`NSApp.windows`. This is verified in `docs/SMOKE_TEST.md`, not by a unit test.

## Part 6 — playback controls in the Quick Panel

### What the two backends can actually do

The scope here is set by a hard asymmetry between the backends, so it is recorded rather than
rediscovered later.

*Pause is cheap on both.* `AVSpeechSynthesizer` has `pauseSpeaking(at:)` / `continueSpeaking()`
and pauses its whole queue, which is what segmentation produces. `EndpointSpeechService` plays
through `AVAudioPlayer`, whose `pause()` preserves `currentTime`.

*Seeking is not available at all on system voices.* `AVSpeechSynthesizer` exposes no position
and accepts no position: the only progress signal is the delegate callback
`willSpeakRangeOfSpeechString`, which reports a character range just before speaking it.
Rewinding could only be emulated as "stop and start again from sentence N" — a jump, not a
scrub. The endpoint backend has the opposite shape: `currentTime` is writable, so scrubbing
inside a chunk is trivial, but a chunk holds up to 4096 characters and moving past its edge
means re-issuing a paid, slow HTTP request. A single seek control cannot sit honestly on top
of both, so seeking, skipping and the progress indicator that would drive them are all
deferred as one decision.

This iteration therefore ships exactly Play, Pause, Resume and Stop, which behave identically
on both sources.

### Protocol changes

```swift
@MainActor protocol SpeechSynthesizing: AnyObject {
    // …existing members…
    /// True only while speech has been started and then paused. `isSpeaking` stays true.
    var isPaused: Bool { get }
    func pause()
    func resume()
}

@MainActor protocol AudioPlaying: AnyObject {
    // …existing members…
    var isPaused: Bool { get }
    func pause()
    func resume()
}
```

`isPaused` is a sub-state of `isSpeaking`, not a sibling: a paused utterance is still the
in-flight one, so `isSpeaking` remains true and the existing "one in-flight task per
controller" rule (invariant 7) is untouched. `pause()` on an idle backend and `resume()` on a
backend that is not paused are both no-ops, matching how `stop()` already behaves.

`AVSpeechService` forwards to `pauseSpeaking(at: .word)` / `continueSpeaking()`.
`EndpointSpeechService` forwards to the player; its one-chunk prefetch keeps running while
paused, which is harmless — the fetched chunk simply waits. `SpeechRouter` forwards to the
backend named by the settings it was last asked to speak with, and reports `isPaused` as the
disjunction of both, mirroring how it already reports `isSpeaking`.

### `SpeakController`

Playback started from a panel and playback started by hotkey #3 must be the same in-flight
job, so pressing ⌥S while the panel is speaking stops it rather than starting a second one.
The controller therefore grows an explicit notion of who asked:

```swift
enum SpeakSource: Hashable { case hotkey, refineOriginal, refineRefined, summary }

@Published private(set) var isSpeaking: Bool
@Published private(set) var isPaused: Bool
@Published private(set) var active: SpeakSource?   // nil when idle

func speak(_ text: String, from source: SpeakSource)
func pauseOrResume()
func stop()
```

`toggle(text:)` keeps its signature and its hotkey behaviour, now recording `.hotkey` as the
active source. Starting playback from any source supersedes whatever was playing.

The HUD is shown only when `active == .hotkey`. A panel-initiated read keeps the HUD hidden:
the panel has its own controls, and a floating "Speaking…" HUD over it would be noise. Errors
still surface as toasts on every path.

Because a panel read has no HUD, it must not outlive the panel: dismissing the panel — with
Esc, or as part of Insert / Replace selection, which dismiss on their way out — stops playback
whenever `active != .hotkey`. Dismissing is a "done here" gesture, and continuing to read with
no visible control and no way to stop but ⌥S is more surprising than falling silent. A hotkey
read that merely overlaps the panel owns the HUD and the hotkey and is left alone.
`QuickPanelController` takes this as a closure at construction; it never learns about
`SpeakController` (UI must not reach into Features).

### Layout changes

`SummaryLayout`'s footer gains a speech control beside Copy and Replace selection.
`RefineLayout` puts one in each pane header beside Copy and Insert, because the panel shows
two texts and "read this aloud" has to name one of them.

Each control renders from `(controller.active, controller.isPaused)` compared against its own
`SpeakSource`:

| State for this control | Icon | Action |
|---|---|---|
| not the active source | Speak | `speak(text, from: mySource)` |
| active, playing | Pause | `pauseOrResume()` |
| active, paused | Resume | `pauseOrResume()` |

A Stop button sits beside it whenever this control is the active source. Speaking blank text
toasts the existing "nothing to read" message rather than starting.

One icon is added to `Resources/Icons/icons.json` for this part — `pause` — per invariant 12;
`play` and `stop` are already vendored. The language switcher in Part 4 adds `globe`.

## Testing

Unit tests (`swift-testing`, mirroring the source tree):

- `HotkeyAction.menuTrailing` for a bound and an unbound shortcut.
- Factory set integrity: 7 × 12 presets, IDs unique, English IDs unchanged from the shipped
  values, every template passes `PromptRenderer.validate`, no template except `translate`
  contains `{language}`, every template contains `{text}`.
- `seed` / `restoreMissing`: seeding per language, re-seeding is a no-op, a deleted factory
  preset comes back, a dangling default is repaired per `kind × language`.
- `presets(of:language:)`, `defaultPreset(for:language:)`, `defaultPresetIDs` round-tripping
  through JSON.
- `utterancePlan` with `ScriptedLanguageDetector`: the map wins over the automatic pick, an
  unmapped language falls back to `fallbackVoice`, runs under 12 letters skip detection,
  `segmentationEnabled == false` yields exactly one utterance, an all-same-voice plan
  collapses to one utterance holding the original text.
- `SpeechTabModel.group` keyed by base code, with regional variants inside one group.
- The audition settings copy: `source == .system`, `segmentationEnabled == false`, the picked
  `voiceID`.
- `DockIconCoordinator` against a fake policy: open/open/close keeps the icon, the second
  close hides it, closing an owner that was never opened is a no-op.
- `RefineController` / `SummarizeController` language switching through
  `ScriptedSettingsHolder`: `promptLanguage` is written, the preset moves to the new
  language's default, a rerun is triggered.
- `SpeakController` playback: `speak(from:)` sets `active`, `pauseOrResume` flips `isPaused`
  both ways, `stop` clears both, a second source supersedes the first, the hotkey stops
  panel playback instead of starting a second job, the HUD appears only for `.hotkey`, and
  blank text toasts instead of starting.
- `SpeechRouter` forwarding of `pause` / `resume` / `isPaused` to the backend named by the
  settings it last spoke with, with `ScriptedSpeech` extended to record the calls.

`docs/SMOKE_TEST.md` gains rows for what cannot be unit-tested: the Dock icon appearing and
disappearing with each window, hearing the preview and the audition, the menubar menu showing
the shortcut a user just rebound, switching language live in a Quick Panel window, and
pausing and resuming panel playback on both speech sources — the one place where the two
backends could diverge in feel.
