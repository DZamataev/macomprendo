# Replacement rules: rewriting listed forms to their term

Status: **approved 2026-09-28.**

Builds on: `2026-09-17-glossary-packs-and-normalisation.md` (the pack format and the normaliser
this spec extends), `ADR-0013-glossary-reaches-each-backend-differently` (mechanism 3, which this
spec narrows), `2026-09-28-cyrillic-forms-control-dictation.md` (the corpus and the measurement
every decision below is drawn from).

## Problem

The recogniser sometimes writes a term the way it sounds in Russian: `пайтест`, `вебпак`,
`хенд-офф`, `байсинг`. Sometimes it garbles a Russian word that is itself jargon: `рамбуке` for
`ранбуке`. Normalisation cannot reach either, because it only matches spellings with the same
letters.

The purpose is text **a person reads** — issues, commits, messages. An agent reading a transcript
understands `пайтест` perfectly well; a colleague reading an issue should see `pytest`.

## What the measurement decided

From the corpus (entries 446–453) and the rest of the history (440 entries, about 115 with
content):

1. **It is rare.** About one hit per twelve contentful dictations. Worth having, not worth
   complexity.
2. **Most Russified jargon must stay as it is.** `конфиг`, `промпт`, `стейдж`, `по ранбуку`,
   `канбан-доске` read naturally; rewriting them to Latin makes the text worse. So **nothing is
   rewritten unless the user listed it.**
3. **Stem matching breaks ordinary speech.** ADR-0013's "stem of four or more characters plus up to
   three of inflection" would have rewritten `редиску`, `редиски`, `реакцию` and `реактор` in a
   single paragraph. Forms are matched **whole**, and every inflection the user wants caught is
   listed.
4. **Dropping the ending matches what the model already does.** In 8 of 12 inflected mentions the
   model itself wrote `в PyTest`, `с Redis`. A form therefore becomes the term with no ending.
5. **The target is not always Latin.** `рамбуке` → `ранбуке` and `гид-репозиторий` →
   `git-репозиторий` are garbles inside Cyrillic. The left side of a rule is any spelling; for a
   Cyrillic target the ending survives because the whole inflected form is listed on both sides
   (`ранбуке = рамбуке`).
6. **Homographs are the author's business.** `метро`, `под`, `питон` mean both things. Listing a
   one-word form that is also an ordinary word is allowed; the `README.md` and the new-pack header
   warn about it and recommend the multi-word form (`pod install = под инсталл`).

## The rule

The pack format is unchanged: `term = form, form`. The parser already stores the forms
(`GlossaryTerm.cyrillicForms`); this spec makes the glossary read them.

**A form is another spelling of its term's key.** Each form is keyed with the same
`Glossary.key(for:)` normalisation uses — lowercased, separators dropped — and added to the keyed
set pointing at its term's canonical spelling. Nothing else changes: the same windows of one to
four words, the same longest-window-first, the same sentence boundaries, the same punctuation
handling, the same provenance on each rewrite.

Consequences, all of which are exact rather than fuzzy:

- `вебпака` matches only a listed `вебпака`. `вебпак` does not match `вебпака`.
- A form is case- and separator-insensitive like everything else: `текст-эдитор`, `Текст эдитор`
  and `текстэдитор` are one form.
- A multi-word form works across words (`под инсталл`), up to four words, and never across a
  sentence boundary.
- The form's field name stays `cyrillicForms` in code. It is not renamed: a form may be written in
  any script, but renaming a field used by the parser, the serialiser and their tests is a diff
  this spec does not need.

**`ё` keys as `е`.** The recogniser writes `ё` inconsistently (`нашёл` in 453, `еще` in 449), so a
form must not care which one it got. This applies to the key, and therefore to normalisation of
Latin terms too — harmlessly, since no Latin letter is involved.

**Collisions follow the existing order.** A form enters the keyed set at its term's position: the
manual list first (which has no forms), then packs in `packs.json` order, and within a pack each
term's own spelling before its forms. A form losing to a *different* term counts as an inert term
for its pack, exactly as a losing term does. A form that keys the same as its own term, or as
another form of the same term, is redundant and counted as nothing.

**The sentence capital gives way to an interior capital.** Normalisation keeps a sentence's first
capital on a rewrite (`Xcode build упал` → `Xcodebuild упал`). Forms make that rule produce
`JQuery`, `IOS` and `MacOS` whenever such a term opens a sentence — a spelling no one has ever
written. So the capital is kept only when the canonical spelling has no uppercase letter after its
first character. `Джейкьюери.` → `jQuery.`; `Пайтест.` → `Pytest.` as before.

## Non-goals

- **Suggesting forms from history.** Rejected: low precision (about 20 useful words in 117
  candidates), and a curated pack is short enough to write by hand.
- **Warning when a form is an ordinary Russian word.** Rejected by the user; documented in the
  README instead.
- **Stem or prefix matching, transliteration, edit distance.** Every one of them fails the
  corpus's trap paragraph.
- **Changing the factory packs.** No form is added to a bundled pack in this spec. The forms that
  matter are the user's own (`хенд-офф`, `байсинг`, `ранбуке`), and factory forms would move the
  control-dictation regression pin for no measured gain.
- **Renaming `cyrillicForms`** — see above.

## UI

None beyond documentation. Rules are written in the pack editor that already exists; rewrites
already reach the post-dictation review panel with their pack name, and the Glossary section's
inert count already covers a form that loses a collision.

## Testing

Pure, in `NormalizerTests.swift` and `GlossaryPackTests.swift`'s neighbours:

- a listed form is rewritten to its term, whole, and the ending is dropped
  (`с вебпаком` → `с webpack`)
- an unlisted inflection is untouched (`вебпака` with only `вебпак` listed)
- **the corpus trap paragraph** (entry 452) with rules `Redis = редис`, `React = реакт`,
  `Django = джанго`: `редиску`, `редиски`, `реакция`, `реактор` untouched; `Джанго` rewritten,
  because the author listed it — pinned so the cost of a homograph is visible in a test
- a multi-word form rewrites across words and keeps the second sentence untouched
  (`сделал под инсталл. Под диваном.` → `сделал pod install. Под диваном.`)
- a Cyrillic target keeps its listed ending (`в рамбуке` → `в ранбуке`)
- a form is case- and separator-insensitive (`Текст эдитор` → `TextEditor`)
- `ё` and `е` key alike, in forms and in text
- a rewrite from a form carries the pack name and the original text
- collisions: a form losing to another term is counted inert for its pack; a form keying the same
  as its own term, or as a sibling form, is not counted
- the sentence capital: `Джейкьюери. Всё` → `jQuery. Всё`; `Пайтест упал` → `Pytest упал`
- a term with no forms behaves exactly as before — the existing suites run unchanged, including the
  control-dictation regression pin

## Deliverables

- `Core/Glossary.swift` — forms enter the keyed set; `ё` keys as `е`.
- `Core/Normalizer.swift` — the sentence-capital condition.
- `Core/GlossaryPack.swift` — the doc comment no longer says nothing reads the forms.
- `Services/GlossaryStore.swift` — the new-pack header states the rule and the homograph warning.
- `Resources/Vocabulary/README.md` — the forms section rewritten: live, whole-word, list each
  ending, prefer multi-word forms for ordinary words.
- `CONTEXT.md` — **Replacement rule** no longer says "Cyrillic".
- `docs/adr/0013-…` — mechanism 3 amended: whole forms, not stems, with the corpus as the reason.
- `CHANGELOG.md` — `Unreleased`.
- `docs/SMOKE_TEST.md` — one dictation through a user pack with a form.
