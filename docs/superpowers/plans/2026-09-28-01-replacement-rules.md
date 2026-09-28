# Replacement Rules Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A pack line `term = form, form` rewrites each listed form, matched whole, to the term.

**Architecture:** Forms become extra keys in `Glossary`'s keyed set, pointing at their term's
canonical spelling. `Normalizer` is untouched except for one condition on the sentence capital.
No new types, no UI, no new files outside tests.

**Tech Stack:** Swift 6, Swift Testing, SwiftPM.

**Spec:** `docs/superpowers/specs/2026-09-28-replacement-rules.md`
**Evidence:** `docs/superpowers/specs/2026-09-28-cyrillic-forms-control-dictation.md`

## Global Constraints

- The main checkout carries uncommitted microphone-picker work, including hunks in
  `CHANGELOG.md` and `docs/SMOKE_TEST.md`. Commit only the hunks this plan adds
  (`git add -p`), and never stage anything else.
- Do not rename `GlossaryTerm.cyrillicForms`.
- Do not add forms to any factory pack in `Resources/Vocabulary/*.txt`.
- Do not edit an existing test to make it pass. If one fails, leave it red and report it.
- `npm run test:swift` must be green at the end of every task.

## Verified before writing

The three production edits below were applied to a scratch worktree at `81ade62`; the whole suite
passed (1376 tests), and a probe printed:

```
«с вебпаком больше»                    -> «с webpack больше»
«на пастгрессе. Из пастгресса»         -> «на Postgres. Из Postgres»
«Пайтест. Пайторч. Джейкьюери.»        -> «Pytest. PyTorch. jQuery.»
«сделал под инсталл. Под диваном.»     -> «сделал pod install. Под диваном.»
«в рамбуке запишем»                    -> «в ранбуке запишем»
«текст-эдитор, текст эдитор, текстэдитор» -> «TextEditor, TextEditor, TextEditor»
```

Without the `Normalizer` edit the third line read `JQuery.`.

---

### Task 1: Forms enter the glossary

**Files:**
- Modify: `macos/Sources/Macomprendo/Core/Glossary.swift:41-94`
- Modify: `macos/Sources/Macomprendo/Core/GlossaryPack.swift:3-4` (doc comment only)
- Test: `macos/Tests/MacomprendoTests/Core/ReplacementRuleTests.swift` (create)

**Interfaces:** consumes `GlossaryPack.parse(_:name:)`, `GlossaryTerm.cyrillicForms`,
`Glossary.init(packs:manualTerms:)`, `Glossary.key(for:)`, `Glossary.inertTermCountsByPack`,
`Normalizer.normalise(_:with:)` → `NormalisationResult { text, rewrites: [Rewrite] }`, where
`Rewrite` has `range`, `original`, `term`, `packName`. Creates no new symbols.

- [ ] **Step 1: Write the failing tests**

Create `macos/Tests/MacomprendoTests/Core/ReplacementRuleTests.swift`:

```swift
import Testing
@testable import Macomprendo

/// Normalises `text` with one pack named `p` whose file text is `pack`.
private func replaced(_ text: String, _ pack: String) -> String {
    Normalizer.normalise(text, with: Glossary(packs: [GlossaryPack.parse(pack, name: "p")])).text
}

@Suite("Replacement rules — a listed form becomes its term")
struct ReplacementRuleMatchingTests {
    @Test func aListedFormIsRewrittenAndItsEndingDropped() {
        #expect(replaced("Конфиг вебпака переписал, с вебпаком больше не работаю.",
                         "webpack = вебпак, вебпака, вебпаком")
            == "Конфиг webpack переписал, с webpack больше не работаю.")
    }

    @Test func anUnlistedInflectionIsUntouched() {
        #expect(replaced("конфиг вебпака", "webpack = вебпак") == "конфиг вебпака")
    }

    @Test func aFormIsCaseAndSeparatorInsensitive() {
        #expect(replaced("поправил Текст эдитор и текстэдитор",
                         "TextEditor = текст-эдитор")
            == "поправил TextEditor и TextEditor")
    }

    @Test func aMultiWordFormMatchesAcrossWordsButNotAcrossASentence() {
        #expect(replaced("и сделал под инсталл. Под диваном.", "pod install = под инсталл")
            == "и сделал pod install. Под диваном.")
    }

    @Test func aCyrillicTargetKeepsTheEndingItWasListedWith() {
        #expect(replaced("давай в рамбуке запишем", "ранбуке = рамбуке")
            == "давай в ранбуке запишем")
    }

    @Test func yoAndYeKeyAlike() {
        #expect(Glossary.key(for: "нашёл") == Glossary.key(for: "нашел"))
        #expect(replaced("подготовь хёнд-офф", "handoff = хенд-офф") == "подготовь handoff")
    }

    @Test func aTermWithoutFormsStillMatchesOnlyItsOwnSpelling() {
        #expect(replaced("поставил через NVM и вебпак", "nvm") == "поставил через nvm и вебпак")
    }
}

@Suite("Replacement rules — the corpus trap paragraph")
struct ReplacementRuleTrapTests {
    /// Entry 452, verbatim. With these rules only `Джанго` changes, because the author listed it:
    /// a homograph's cost is the author's, and this pins what that cost looks like.
    @Test func wholeFormsLeaveOrdinaryWordsAloneExceptAListedHomograph() {
        let transcript = "Купил на рынке редиску и две редиски отдал соседу. Доехал на метро, в метро "
            + "было душно. Кот спрятался под диваном. Код ревью затянулся. В зоопарке спала панда, "
            + "рядом ползал питон. Реакция на новость была спокойной. Реактор на станции "
            + "остановили. Смотрели фильм про Джанго. Сыграл на гитаре и взял ноту до."
        let pack = "Redis = редис\nReact = реакт\nDjango = джанго\npod install = под инсталл"
        #expect(replaced(transcript, pack) == transcript.replacingOccurrences(
            of: "про Джанго", with: "про Django"))
    }
}

@Suite("Replacement rules — provenance and collisions")
struct ReplacementRuleProvenanceTests {
    @Test func aRewriteFromAFormNamesItsPackAndKeepsTheOriginal() {
        let glossary = Glossary(packs: [GlossaryPack.parse("pytest = пайтест", name: "python")])
        let result = Normalizer.normalise("упал пайтест вчера", with: glossary)
        #expect(result.text == "упал pytest вчера")
        let rewrite = try? #require(result.rewrites.first)
        #expect(rewrite?.original == "пайтест")
        #expect(rewrite?.term == "pytest")
        #expect(rewrite?.packName == "python")
        #expect(rewrite.map { String(result.text[$0.range]) } == "pytest")
    }

    @Test func aFormLosingToAnotherTermIsCountedInert() {
        let glossary = Glossary(packs: [
            GlossaryPack.parse("Redis = редис", name: "a"),
            GlossaryPack.parse("Radish = редис", name: "c"),
        ])
        #expect(glossary.entry(forKey: Glossary.key(for: "редис"))?.canonical == "Redis")
        #expect(glossary.inertTermCountsByPack["a"] == nil)
        #expect(glossary.inertTermCountsByPack["c"] == 1)
    }

    @Test func aFormRedundantWithItsOwnTermOrASiblingIsNotCounted() {
        let glossary = Glossary(packs: [GlossaryPack.parse(
            "TextEditor = text editor, текст-эдитор, текстэдитор", name: "p")])
        #expect(glossary.collisionCount == 0)
        #expect(glossary.termCount == 2)
    }
}
```

`aFormLosingToAnotherTermIsCountedInert`: pack `c`'s term `Radish` does not collide, but its
form `редис` loses to pack `a`'s form of `Redis`, so `c` counts 1 and `a` nothing.
Derive these counts yourself from the rule in the spec before trusting them; if your arithmetic
disagrees, report it rather than adjusting either side.

- [ ] **Step 2: Run and watch it fail**

Run: `swift test --package-path macos --filter ReplacementRule`
Expected: FAIL — forms are not read, so every rewrite test returns its input unchanged, and
`yoAndYeKeyAlike` fails on the key.

- [ ] **Step 3: Implement in `Glossary.swift`**

Replace the `insert` helper and the loops in `init(packs:manualTerms:)` (currently lines 53–70):

```swift
        func insert(_ canonical: String, packName: String?) {
            insert(canonical, spokenAs: canonical, packName: packName)
        }

        /// Adds `spelling` as a key for `canonical`. A form of a term is another spelling of it:
        /// a form that keys the same as its own term, or as a sibling form, is redundant rather
        /// than a lost term.
        func insert(_ canonical: String, spokenAs spelling: String, packName: String?) {
            let key = Self.key(for: spelling)
            guard !key.isEmpty else { return }
            if let existing = entries[key], spelling != canonical, existing.canonical == canonical {
                return
            }
            guard entries[key] == nil else {
                if let packName {
                    packLosses[packName, default: 0] += 1
                } else {
                    manualLosses += 1
                }
                return
            }
            entries[key] = Entry(canonical: canonical, packName: packName)
        }

        for term in manualTerms { insert(term, packName: nil) }
        for pack in packs {
            for term in pack.terms {
                insert(term.canonical, packName: pack.name)
                for form in term.cyrillicForms {
                    insert(term.canonical, spokenAs: form, packName: pack.name)
                }
            }
        }
```

In `key(for:)` (currently line 91), replace `key.append(character)` with:

```swift
            key.append(character == "ё" ? "е" : character)
```

Rewrite the doc comment on `key(for:)` (currently lines 80–86) to:

```swift
    /// A string's normalised key: lowercased, `ё` read as `е`, with every space, hyphen,
    /// underscore, dot and other non-alphanumeric character removed. So `MainMenu.tscn` and
    /// `MainMenu tscn` share a key, and the canonical spelling restores the dot.
    ///
    /// Script-blind and never transliterating: a Cyrillic string keys to Cyrillic characters and
    /// matches a Latin term only when a pack lists it as that term's form.
```

Add to the `init` doc comment (after the sentence ending "cannot take part in a collision at
all."):

```swift
    /// Within a pack, each term's own spelling enters before its forms.
```

In `GlossaryPack.swift`, replace lines 3–4:

```swift
/// One glossary entry: the spelling the term must be pasted in, plus the forms the recogniser
/// writes instead, each rewritten to the term when matched whole. The field keeps its original
/// name although a form may be written in any script.
```

- [ ] **Step 4: Run green**

Run: `swift test --package-path macos --filter "ReplacementRule|Glossary|Normalis|CorrectionReview"`
Expected: the new suites pass (none of them starts a sentence with a term whose canonical
spelling has an interior capital — that is Task 2). Existing suites pass
unchanged — including `keyingIsScriptBlindAndNeverTransliterates`, which holds because keying
itself does not transliterate.

- [ ] **Step 5: Full suite, then commit**

Run: `npm run test:swift` → green.

```bash
git add macos/Sources/Macomprendo/Core/Glossary.swift \
  macos/Sources/Macomprendo/Core/GlossaryPack.swift \
  macos/Tests/MacomprendoTests/Core/ReplacementRuleTests.swift
git commit -m "feat(glossary): rewrite a pack's listed forms to their term"
```

---

### Task 2: The sentence capital gives way to an interior capital

**Files:**
- Modify: `macos/Sources/Macomprendo/Core/Normalizer.swift:98-109`
- Test: `macos/Tests/MacomprendoTests/Core/ReplacementRuleTests.swift` (append)

**Interfaces:** consumes Task 1's behaviour. Changes no signature.

- [ ] **Step 1: Write the failing test** — append to `ReplacementRuleTests.swift`:

```swift
@Suite("Replacement rules — the sentence capital")
struct ReplacementRuleSentenceCapitalTests {
    @Test func aTermWithAnInteriorCapitalKeepsItsOwnSpellingAtASentenceStart() {
        #expect(replaced("Джейкьюери. Всё сломалось", "jQuery = джейкьюери")
            == "jQuery. Всё сломалось")
        #expect(replaced("Всё. IOS упал", "iOS") == "Всё. iOS упал")
    }

    @Test func aLowercaseTermStillTakesTheSentenceCapital() {
        #expect(replaced("Пайтест упал", "pytest = пайтест") == "Pytest упал")
    }
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `swift test --package-path macos --filter ReplacementRuleSentenceCapital`
Expected: FAIL — `JQuery. Всё сломалось` and `Всё. IOS упал`. The second passes.

- [ ] **Step 3: Implement** — in `Normalizer.swift`, replace

```swift
                let replacement = startsSentence && (original.first?.isUppercase ?? false)
                    ? capitalisingFirstLetter(entry.canonical)
                    : entry.canonical
```

with

```swift
                // …unless the canonical spelling carries a capital of its own after the first
                // letter: `jQuery`, `iOS`, `macOS` are brand spellings, and raising their first
                // letter produces `JQuery`, which nobody writes.
                let hasInteriorCapital = entry.canonical.dropFirst().contains(where: \.isUppercase)
                let replacement = startsSentence && (original.first?.isUppercase ?? false)
                    && !hasInteriorCapital
                    ? capitalisingFirstLetter(entry.canonical)
                    : entry.canonical
```

- [ ] **Step 4: Run green, full suite, commit**

Run: `npm run test:swift` → green. Existing `NormalisationSentenceCapitalTests` must pass
unchanged; none of their canonical spellings has an interior capital except `SwiftUI`, whose test
(`interiorCaseIsStillCorrectedAtTheStartOfASentence`) already expects `SwiftUI`.

```bash
git add macos/Sources/Macomprendo/Core/Normalizer.swift \
  macos/Tests/MacomprendoTests/Core/ReplacementRuleTests.swift
git commit -m "fix(glossary): keep a brand capital such as jQuery at a sentence start"
```

---

### Task 3: Documentation the user and agents read

**Files:**
- Modify: `macos/Sources/Macomprendo/Services/GlossaryStore.swift:119-124`
- Test: `macos/Tests/MacomprendoTests/Services/GlossaryStoreTests.swift:121-126` (the expected header)
- Modify: `macos/Sources/Macomprendo/Resources/Vocabulary/README.md:28, 40-42`
- Modify: `CONTEXT.md:54-57`
- Modify: `docs/adr/0013-glossary-reaches-each-backend-differently.md:59-62`
- Modify: `CHANGELOG.md` (`## [Unreleased]` → `### Added`)
- Modify: `docs/SMOKE_TEST.md` (Glossary section, after "An enabled pack corrects a dictated term")

- [ ] **Step 1: Failing test first** — in `GlossaryStoreTests.swift`, change the expected header in
`newPackWritesTheDocumentingHeaderAndNothingElse` to:

```swift
        #expect(text == """
        # pack: mine
        # One term per line, in the spelling you want pasted.
        # `term = форма, форма` rewrites each listed form, matched whole, to the term.
        # List every ending you want caught. A form that is also an ordinary word
        # (`под`, `метро`) is rewritten everywhere — prefer a longer form (`под инсталл`).

        """)
```

This is a deliberate header change, not a test edited to pass. Run
`swift test --package-path macos --filter newPackWritesTheDocumentingHeader` → FAIL.

- [ ] **Step 2: Implement** — in `GlossaryStore.swift`, `newPackHeader` becomes:

```swift
    static let newPackHeader = """
    # pack: %@
    # One term per line, in the spelling you want pasted.
    # `term = форма, форма` rewrites each listed form, matched whole, to the term.
    # List every ending you want caught. A form that is also an ordinary word
    # (`под`, `метро`) is rewritten everywhere — prefer a longer form (`под инсталл`).

    """
```

Run the filter again → PASS.

- [ ] **Step 3: README** — in `Resources/Vocabulary/README.md`, replace line 28
(`TextEditor = текст-эдитор, текстэдитор`) with `pod install = под инсталл`, and replace the
bullet at lines 40–42 with:

```markdown
- **`term = форма, форма` rewrites those forms to the term.** Use it for what the recogniser
  writes by ear: `pytest = пайтест`, `handoff = хенд-офф`. The term may be Cyrillic too, for a
  garbled Russian word: `ранбуке = рамбуке`.
  - **A form matches whole**, ignoring case, spaces, hyphens and `ё`/`е` — `текст-эдитор`
    also catches `Текст эдитор`. It never matches part of a word: `вебпак` does not catch
    `вебпака`. List every ending you want caught: `webpack = вебпак, вебпака, вебпаком`.
  - **The ending is dropped**: `с вебпаком` becomes `с webpack`, as the recogniser itself
    usually writes it.
  - **A form that is also an ordinary word is rewritten everywhere.** `pod = под` turns
    `под диваном` into `pod диваном`. Prefer a longer form: `pod install = под инсталл`.
```

- [ ] **Step 4: CONTEXT.md** — replace the **Replacement rule** definition (lines 55–56) with:

```markdown
A term that also lists other spellings the recogniser writes for it — usually by ear, in
Cyrillic — each rewritten to the canonical spelling when matched whole.
```

- [ ] **Step 5: ADR-0013** — replace lines 59–62 (the paragraph starting
`**3. Cyrillic replacement rules**`) with:

```markdown
**3. Replacement rules**, the `pytest = пайтест` form, last. *Amended 2026-09-28:* forms are
matched **whole**, not by stem. The corpus in
`docs/superpowers/specs/2026-09-28-cyrillic-forms-control-dictation.md` showed a four-character
stem plus inflection rewriting `редиску`, `реакцию` and `реактор` in a single paragraph, and
showed the model itself dropping the ending in 8 of 12 inflected mentions — so every wanted
ending is listed, and a match becomes the bare term.
```

- [ ] **Step 6: CHANGELOG** — under `## [Unreleased]` → `### Added`, directly after the
**Glossary** bullet, add:

```markdown
- **Replacement rules** in glossary packs: a line such as `pytest = пайтест, пайтеста` now
  rewrites each listed form to the term, so a word the recogniser wrote by ear is pasted the way
  you spell it. Forms match whole — list every ending you want caught — and the ending is
  dropped. The target may be Cyrillic too, to fix a garbled word (`ранбуке = рамбуке`). A term
  such as `jQuery` or `iOS` at the start of a sentence now keeps its own spelling instead of
  becoming `JQuery`.
```

- [ ] **Step 7: SMOKE_TEST** — in `docs/SMOKE_TEST.md`, after the bullet
"**An enabled pack corrects a dictated term.**", add:

```markdown
- [ ] **A replacement rule rewrites a listed form.** Create a pack `smoke-forms` holding
      `pytest = пайтест, пайтеста` and `pod install = под инсталл`, enable it, and dictate into
      TextEdit, pausing between words: «Пайтест. Без пайтеста не заметил. Сделал под инсталл, кот
      под диваном.» If the recogniser writes those words in Cyrillic, the pasted text reads
      `Pytest.`, `Без pytest`, `pod install` — and `под диваном` is untouched. If it writes them
      in Latin, normalisation handles them and the check is inconclusive: repeat inside a longer
      Russian sentence. Delete the pack afterwards.
```

- [ ] **Step 8: Gates and commit**

Run: `npm run test:swift` → green. `npm run audit` → green. `swift build --package-path macos`
→ no new warnings.

```bash
git add macos/Sources/Macomprendo/Services/GlossaryStore.swift \
  macos/Tests/MacomprendoTests/Services/GlossaryStoreTests.swift \
  macos/Sources/Macomprendo/Resources/Vocabulary/README.md \
  CONTEXT.md docs/adr/0013-glossary-reaches-each-backend-differently.md
git add -p CHANGELOG.md docs/SMOKE_TEST.md   # only this task's hunks
git commit -m "docs(glossary): document replacement rules in the pack header, README and ADR-0013"
```

The seeded `README.md` in the user's Vocabulary folder is not overwritten by seeding; the updated
text reaches an existing install only through the bundle copy. That is existing behaviour, not
this plan's to change.

---

### Task 4: Acceptance on the real app

- [ ] `npm run install-app:signed`, then run the SMOKE_TEST bullet from Task 3 Step 7.
- [ ] Open the post-dictation review panel after that dictation: the rewritten spans are
      underlined and the caption names `smoke-forms`.

## Report back

State what in the spec or this plan was wrong, ambiguous, or decided by you. Do not be polite
about it — that part matters more than the code.
