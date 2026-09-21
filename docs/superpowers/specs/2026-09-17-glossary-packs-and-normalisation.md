# Glossary packs and canonical-form normalisation

Status: **approved 2026-09-17.**

Builds on: `ADR-0012-vocabulary-packs-as-plain-text-files`,
`ADR-0013-glossary-reaches-each-backend-differently`, `2026-09-10-corpus-capture.md` (the
`raw_text` column this spec fills), `2026-09-14-glossary-control-dictation.md` (the measurement
this spec is sized against).

## Problem

Dictating about software produces jargon the recogniser mishandles. The control dictation of
2026-09-17 (`ggml-large-v3-turbo`, Russian pinned, 44 observations) sorted the damage:

| Failure | Share | Example |
|---|---|---|
| casing | 39 % | `nvm` -> `NVM`, `auto-till-dry` -> `Auto-Till-Dry` |
| substitution | 18 % | `jq` -> `GQ`, `ruff` -> `RAV` |
| splitting | 16 % | `xcodebuild` -> `Xcode build`, `SafeAreaView` -> `Safe Area View` |
| correct | 16 % | `SwiftUI`, `UIKit`, `git rebase` |
| transliteration | 9 % | `Metro` -> `метро`, `Codegen` -> `код ген` |

Casing and splitting are 55 % of everything, and both are the same defect: **the model heard the
term correctly and wrote it in the wrong shape**. That is not a decoding choice, so no amount of
contextual biasing touches it. It is a text problem with an exact answer.

This spec ships that answer, and the pack format that feeds it. Biasing (the 18 %) and Cyrillic
replacement rules (the 9 %) are separate, later specs; the file format defined here already
carries what they will need.

## Goals

1. A pack format a human and an agent can both read and write without documentation.
2. Factory packs that ship in the bundle and seed a user directory, plus packs the user creates.
3. Normalisation that rewrites recognised terms to their canonical spelling under every backend.
4. The raw transcript preserved in history, so the corpus still measures the model.

## Non-goals

- **Biasing.** `initial_prompt`, hotwords, the prompt budget and its warning are the next spec.
  Nothing here reads a model or a recogniser.
- **Cyrillic replacement rules.** The `TextEditor = текст-эдитор` syntax is parsed and stored by
  this spec, and ignored by it. 9 % of failures, and the only mechanism needing hand-written
  forms.
- **`{vocabulary}` in refine/summarize prompts.** Same spec as biasing; both are about feeding a
  glossary to something, rather than fixing text with it.
- **A structured pack editor.** One `TextEditor` over the file's text, until the hypothesis is
  proven.
- **The post-dictation review window.** Showing which words were rewritten is its own spec; this
  one only produces the ranges it will need.
- **Watching the directory.** Read at launch and when Settings opens, plus a Reload button.
- **Automatic term harvesting from projects.** An agent writes a pack file; the app does not read
  the user's repositories.

## Vocabulary

Defined in `CONTEXT.md`; repeated here because this spec is where the terms become code.

- **Glossary** - every enabled pack's terms plus the user's own list.
- **Term** - one entry, stored in its canonical spelling.
- **Canonical spelling** - how the term must appear in pasted text: `auto-till-dry`, not
  `Auto-Till-Dry`.
- **Pack** - a named, switchable file of terms.
- **Normalisation** - rewriting a recognised term to its canonical spelling when the two match
  once casing and separators are ignored.

## The pack format

One pack per file. A line is a comment (`#`), blank, or a term. The file name is the pack name.

```
# pack: typescript
# Terms the recogniser gets wrong. One per line.
# `term = cyrillic, forms` adds replacement forms for the same term.

jq
nvm
oxlint
xcodebuild
SafeAreaView
auto-till-dry
TextEditor = текст-эдитор, текстэдитор
```

Parsing rules, in full:

- A line whose first non-space character is `#` is a comment. Comments carry no meaning to the
  app; they are documentation for whoever opens the file next, including an agent.
- A term line is its canonical spelling, trimmed of surrounding whitespace. Interior spaces are
  significant: `git rebase` is one term.
- **Lines end with `\n`.** A pack is a Unix text file; a `\r\n` file would leave a carriage
  return on the end of every term, because trimming it would break the byte-identical
  round-trip. Files the app writes always use `\n`, and a hand-written CRLF pack is a
  format violation rather than something the parser repairs.
- `term = form, form` lists Cyrillic forms. This spec parses and stores them; nothing reads them
  yet.
- A duplicate term within a file keeps its first occurrence.
- A malformed line is skipped, not fatal, and reported as a count in the UI: a pack with one bad
  line must still work.

Writing back preserves comments, blank lines and order, because the editor is the file's text.
The app never rewrites a pack file except on Reset or through that editor.

### Which packs are on

`Vocabulary/packs.json`, beside the packs, names what is enabled:

```json
{ "enabled": ["typescript", "python"] }
```

A pack absent from that list is off - **including a file just dropped into the directory**.
Enabling is a deliberate act: an agent that writes a pack also adds its name here, and the
seeded `README.md` says so. A name in `enabled` with no matching file is ignored rather than an
error, so deleting a pack never requires editing the config.

Decoded with `JSONDecoder`; a missing, empty or malformed file reads as "nothing enabled" and is
surfaced as a UI message rather than a throw, because an unparsable config must not take
dictation down with it. **A missing file is not a failure** — that is the state a fresh install
seeds — so it reports no message; empty or malformed bytes report one.

The message must not quote the decoder's error, because that error carries the file's contents
and pack names are user content (invariant 6).

Order inside `enabled` is meaningful: it decides which term wins a key collision, so the config
preserves it and never sorts. Duplicated names are kept verbatim for the same reason a name with
no file is kept — this type has no filesystem and makes no semantic judgements.

Unlike a pack file, `packs.json` does **not** round-trip byte-identically: rewriting it
reformats a hand-compacted file. JSON has no comments to lose, so nothing is destroyed, but the
seeded `README.md` should say so, since the pack format promises the opposite.

This is a deliberate exception to invariant 8: the outcome is a plain message rather than a
`MacomprendoError`, so its wording is not covered by the error-text tests. It carries its own
recovery instruction by hand. If that gap ever matters, the fix is a `MacomprendoError` case
returned — not thrown — by the store.

### Factory packs and user packs

A pack is **factory** when a file of the same name exists in the bundle. The fact is derived at
load time, never stored, so it cannot drift from reality.

| | factory | user |
|---|---|---|
| origin | bundled, seeded on first run | New pack, Duplicate, or dropped in |
| Reset | restores the bundled text | - |
| Delete | - (disable instead; seeding would restore it) | removes the file |
| edit | yes, in place | yes |

New pack asks for a name and writes a file containing only a header:

```
# pack: <name>
# One term per line, in the spelling you want pasted.
# `term = форма, форма` also rewrites those Cyrillic forms to the term.
```

so the first file a user creates already documents the format for the next reader. The name must
be non-empty, free of `/` and `:`, and not collide with an existing pack.

A `README.md` is seeded beside the packs describing both formats - the pack file and
`packs.json` - so the directory explains itself without the app's source.

## Normalisation

Pure text, running after transcription under every backend.

**The key.** A string's normalised key is: lowercased, with every space, hyphen, underscore, dot
and other non-alphanumeric character removed. `Xcode build`, `xcodebuild`, `XcodeBuild`,
`xcode-build` and `MainMenu tscn` all key to their letters alone - so `MainMenu.tscn` and
`MainMenu tscn` share a key, and the canonical spelling restores the dot.

**The match.** Slide a window of 1 to 4 words over the transcript. For each window, compute its
key; if the key equals a glossary term's key, replace the window with that term's canonical
spelling. Longer windows win over shorter ones at the same starting position, so
`Safe Area View` becomes `SafeAreaView` rather than leaving `View` behind.

**A window never crosses a sentence boundary.** Because the key drops dots, `Закрыл Xcode. Build
упал` would otherwise key `Xcode. Build` to `xcodebuild` and produce `Закрыл xcodebuild упал`.
A window stops at `.`, `!`, `?`, `…`, `:`, `;`, a newline, and at an opening or closing bracket
or quotation mark. Multi-word terms are therefore only matched inside one clause, which is where
they are spoken.

**A clause ender only separates when whitespace sits beside it.** This is what lets dotted terms
survive: `MainMenu.tscn` is one matchable word, while `Xcode. Build` and `Xcode .Build` are not.
A newline, a bracket and a quotation mark are absolute — they separate wherever they appear, even
mid-word. Apostrophes (`'`, `’`) are deliberately **not** treated as quotation marks: they live
inside words and would stop windows throughout ordinary prose.

**`:` and `;` stop a window but do not begin a sentence.** They separate clauses, so a term may
not span them, but the word after them carries no sentence capital: `Сказал: Swift хорош` with a
pack holding `swift` becomes `Сказал: swift хорош`. Only `.`, `!`, `?`, `…` and a newline begin a
sentence for the capital rule below.

**The first word of a sentence keeps its capital.** A pack holding `swift` must not turn
`Swift хорош` into `swift хорош`. When a window starts a sentence and the only difference from
the canonical spelling is the case of its first letter, the window is left alone. Any other
difference - interior case, separators, splitting - is still corrected, so `Xcode build упал` at
the start of a sentence becomes `Xcodebuild упал`: the split is fixed and the sentence capital
survives.

**What is deliberately absent:** no edit distance, no phonetic matching, no threshold. Exact key
equality only. Handy's fuzzy corrector exists to cover a failure class that exact matching
settles outright, and its thresholds are the reason it can rewrite a correctly-heard word into a
wrong one.

**Punctuation.** A window's leading and trailing punctuation is detached before keying and
re-attached after - `xcodebuild,` normalises and keeps its comma.

**Short terms are normalised too.** `uv`, `rg`, `jq` are exactly the terms that get capitalised,
and the user put them in a pack deliberately. The cost - `UV` in an unrelated sense being
rewritten - is the user's to avoid by not listing the term.

**The matching is Unicode-aware but script-blind.** A Cyrillic window keys to Cyrillic
characters and will not match a Latin term; that is the 9 % this spec does not address, and it
must not be faked by transliterating inside the key.

**Two terms with one key.** Suppose two packs disagree on how to spell the same key — say
`fast-image` against `FastImage`. (`react-native` versus `React Native` is *not* an example to
copy: the control dictation shows the model writes `React Native` correctly, so by the selection
criterion neither spelling belongs in a factory pack at all, and listing it would rewrite correct
prose.) The
winner is decided by source order, highest first: the manual list, then packs in the order they
appear in `packs.json`. There is no further fallback — a pack absent from `packs.json` is
disabled and contributes no terms, so it cannot take part in a collision. The losing term is
counted and reported in the Glossary section, because a silent collision is a term the user
believes is active and is not.

**The result carries its ranges and their provenance.** `Normalizer` returns the corrected string
*and*, per rewrite: the range in the final string, the original substring, the canonical term, and
the name of the pack that owns it (`nil` for the manual list). The ranges cannot be reconstructed
cheaply from `raw_text`, and the pack name cannot be reconstructed at all once the glossary is
flattened into a keyed set — so the set stores it alongside each term. This is what lets the
post-dictation review window (its own spec) say "typescript · 3 corrections" and make a
misbehaving pack identifiable without opening Settings. A caller that ignores all of it still
gets the plain string.

### What normalisation does to the control dictation

Against the 2026-09-17 transcript, with a pack holding the spoken terms, normalisation fixes
every casing failure (17) and every splitting failure (7): `NVM` -> `nvm`, `Xcode build` ->
`xcodebuild`, `Safe Area View` -> `SafeAreaView`, `Auto-Till-Dry` -> `auto-till-dry`,
`MainMenu TSCN` -> `MainMenu.tscn`. It does not fix `jq` -> `GQ` or `ruff` -> `RAV`, whose keys
differ. That is 24 of 37 — **rows of the failure table, not rewrites in the text.** A term
occurring twice is one row and two rewrites (`xcodebuild` appears twice in transcript 268), so
the two counts agreeing is arithmetic coincidence. A test asserting a rewrite count is not
asserting this figure.

**This number is not evidence, and the spec must not be defended with it.** The failure classes
were derived from that dictation, the factory packs were then filled from the terms in that same
dictation, and the ratio was computed against it. It measures how well a rule fits the data that
produced it. It is kept as a *regression* test - the behaviour is pinned, including the two
failures normalisation must NOT touch - and it is worthless as a forecast.

The honest number requires a **second control dictation**, written from terms that took no part
in designing these rules, dictated after normalisation ships, and scored the same way. Expect it
below 65 %: the first paragraph was, unavoidably, written by someone who already knew what the
rules would catch.

## Factory packs

**Six** packs ship in the bundle: `typescript`, `react-native`, `python`, `go`, `ruby`, `godot`.
An earlier draft said seven, counting "one per active project" — that one cannot ship, because
the app does not know the user's projects. Project vocabulary (`auto-till-dry`, `MatchHUD`,
`MainMenu.tscn`) belongs in a pack the user or their agent writes, which is exactly what
user-created packs are for. Contents are drawn from the harvest of
`~/dev` (2026-09-14) **filtered by the control dictation's criterion**: a term earns its place
only if the recogniser plausibly breaks it. `TypeScript`, `React`, `Python`, `Xcode`, `WebRTC`
are excluded - they come out correct and would only consume the prompt budget the next spec has
to ration. Identifiers nobody says aloud (`Input.parse_input_event`, `golang.org/x/crypto`) are
excluded for the same reason.

Seeding follows `PromptPreset`: on first run each factory pack, plus `README.md`, is copied into
`~/Library/Application Support/Macomprendo/Vocabulary/`. A pack is never overwritten afterwards.
A Reset button per pack restores the bundled version, and that is the only way new factory terms
arrive - identical to the factory-prompt contract. Seeding does not enable anything: `packs.json`
starts empty, and the user picks.

Per invariant 17, the bundled directory must be declared **twice**: `resources:` in
`macos/Package.swift` and a `type: folder, buildPhase: resources` entry in `macos/project.yml`.
Missing the second leaves `swift test` green while the `xcodebuild` bundle ships without packs.

## Settings and UI

```swift
var glossaryEnabled: Bool          // one switch over everything, default false
var glossaryManualTerms: [String]  // the user's own list, outside any pack
```

decoded with `decodeIfPresent` so `currentSchemaVersion` does not move. Pack enablement is **not**
here: it lives in `Vocabulary/packs.json`, per ADR-0012.

Turning the master switch on for the first time offers the recommended packs - the factory ones,
preselected - in a single confirmation, and accepting writes them into `packs.json`. Without
that step the glossary ships inert: the switch defaults off and `packs.json` seeds empty, so
"one button and it works" would in fact be three. The offer appears once; declining leaves
`packs.json` empty and never asks again.

The Dictation tab gains a Glossary section: the master switch, a list of packs with a checkbox
and term count each, a manual-terms field, and Reload / Show in Finder buttons. A factory pack
offers Reset; a user pack offers Delete. New pack and Duplicate create one. Selecting a pack
opens its text in a `TextEditor`; saving writes the file back verbatim. Toggling a checkbox
rewrites `packs.json` and nothing else.

## Wiring

Normalisation runs where the transcript is accepted, before insertion and before history:
`DictationController.transcribeAndInsert` (`:219`, right after trimming) and `DictationCapture`
(`:141`). Both then call `history.append(text:rawText:kind:run:)` with the corrected text as
`text` and the model's output as `rawText` - which is why `corpus-capture` ships first. When
normalisation changes nothing, `rawText` is nil rather than a duplicate of `text`.

`GlossaryStore` is a Service behind a protocol (invariant 2), owning directory reads, seeding and
`packs.json`. `Normalizer` is pure and lives in Core, taking a glossary and a string.
`AppEnvironment` constructs the store; nothing else does.

## Testing

Written first, per invariant 3. Everything here is pure or file-backed, so there is no hardware
glue and no smoke test beyond confirming the bundled packs are present in a built `.app`.

Parsing:
- comments and blank lines ignored; `term = form, form` splits into canonical plus forms; a term
  with no `=` has no forms
- duplicate terms within a file; malformed lines skipped and counted
- round-trip: parse a file and write it back unchanged - byte-for-byte identical

Config:
- a pack absent from `enabled` is off; a freshly written file is off until named
- a name in `enabled` with no file is ignored, not an error
- a missing, empty or malformed `packs.json` reads as nothing enabled and reports a message
- toggling rewrites only `packs.json`, leaving every pack file byte-identical
- turning the master switch on the first time writes the factory pack names; declining leaves
  the config empty and does not ask again

Normalisation:
- casing: `NVM` -> `nvm`, `Auto-Till-Dry` -> `auto-till-dry`, `AutoLoad` -> `Autoload`
- splitting: `Xcode build` -> `xcodebuild`, `Safe Area View` -> `SafeAreaView`,
  `Xcode gen generate` -> `xcodegen generate`
- longest window wins at a given position
- **a window never crosses a sentence boundary**: `Закрыл Xcode. Build упал` is untouched, and
  the same for `!`, `?`, `:`, `;`, a newline, brackets and quotes
- **a sentence's first word keeps its capital** when case is the only difference: `Swift хорош`
  survives a pack holding `swift`, while `Xcode build упал` still becomes `Xcodebuild упал`
- punctuation detached and re-attached: `xcodebuild,` and `(SwiftUI)` survive
- a Cyrillic window never matches a Latin term
- **colliding keys resolve by source order** and the loser is counted
- the returned ranges cover exactly the rewritten spans, and are empty when nothing changed
- **each rewrite names its pack**; a term from the manual list reports `nil`, and a term winning a
  key collision reports the pack that won
- a term not in the glossary is untouched; an empty glossary is the identity function
- **the control-dictation corpus as a regression pin**: feed each of the five transcripts from
  `2026-09-14-glossary-control-dictation.md` with the factory packs enabled and assert the exact
  expected output, including the failures normalisation must NOT fix (`GQ`, `RAV`). This test
  pins behaviour; it does not measure effectiveness, because the rules and the packs were both
  derived from this text.

Store:
- seeding copies bundled packs and `README.md` once, and never overwrites a pack
- seeding leaves `packs.json` empty: nothing is enabled without the user
- factory is derived from the bundle, not stored; New pack rejects a name colliding with a
  bundled pack
- Reset restores one pack from the bundle; Delete removes a user pack and its `enabled` entry
- New pack writes the documenting header; invalid names (empty, `/`, `:`, collision) are refused
- a pack file deleted from disk disappears from the list without error

Wiring:
- with the glossary off, `text` is unchanged and `rawText` is nil
- with it on and a term hit, `text` is corrected and `rawText` holds the model's output
- with it on and no hit, `rawText` is nil

## Follow-up, not optional

A **second control dictation** must be recorded after this ships, from terms that played no part
in designing these rules, and scored by the same table. Until it exists, no claim about how well
normalisation works is supportable - only the claim that it behaves exactly as specified.

## Deliverables

- `Core/GlossaryPack.swift` - the parsed pack, its terms, the parser and serialiser.
- `Core/GlossaryPackConfig.swift` - `packs.json` decoding and encoding.
- `Core/Normalizer.swift` - keying, window matching, and the rewritten ranges.
- `Core/Settings.swift` - `glossaryEnabled`, `glossaryManualTerms`.
- `Services/GlossaryStore.swift` - protocol plus directory-backed implementation.
- `Resources/Vocabulary/*.txt` - seven factory packs, plus `README.md` documenting both formats.
- `macos/Package.swift`, `macos/project.yml` - the resource directory, declared twice.
- `Features/DictationController.swift`, `Features/DictationCapture.swift` - normalise, pass both
  texts.
- `UI/Settings/DictationTab.swift` - the Glossary section and the pack editor.
- `Tests/…/Fakes/FakeGlossaryStore.swift`.
- `docs/SMOKE_TEST.md`, `CHANGELOG.md`, `CONTEXT.md` if a term shifts.

## Open questions

1. **Does the manual list still earn its place?** Now that a user can create packs, the manual
   field is a pack called `personal` with a different UI. Keeping both is defensible - the field
   is one click away, a pack is three - but it is the only glossary source not in a file, and
   dropping it would make "everything is a pack" true without exception.
2. **What happens when a factory pack is edited and the app later ships new factory terms?**
   Reset is the contract, but nothing tells the user a newer version exists. A version comment
   (`# version: 2`) inside the file would allow "this pack has updates" without touching the
   user's copy.
