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

    @Test func aFormSpelledExactlyLikeItsOwnTermIsNotCounted() {
        let glossary = Glossary(packs: [GlossaryPack.parse("redis = redis, редис", name: "p")])
        #expect(glossary.collisionCount == 0)
        #expect(glossary.termCount == 2)
    }

    @Test func aTermRepeatedInALaterPackIsStillCounted() {
        let glossary = Glossary(packs: [GlossaryPack.parse("Redis", name: "a"),
                                        GlossaryPack.parse("Redis", name: "b")])
        #expect(glossary.inertTermCountsByPack["b"] == 1)
    }

    @Test func aFormRedundantWithItsOwnTermOrASiblingIsNotCounted() {
        let glossary = Glossary(packs: [GlossaryPack.parse(
            "TextEditor = text editor, текст-эдитор, текстэдитор", name: "p")])
        #expect(glossary.collisionCount == 0)
        #expect(glossary.termCount == 2)
    }
}

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

@Suite("Replacement rules — the manual list")
struct ReplacementRuleManualListTests {
    @Test func aManualLineWithFormsRewritesThemToItsTerm() {
        let glossary = Glossary(manualTerms: ["LOOKY = луки, луки-приложение", "nvm"])
        #expect(Normalizer.normalise("открой луки и NVM", with: glossary).text
                == "открой LOOKY и nvm")
    }

    @Test func aManualFormOutranksTheSameFormInAPack() {
        let glossary = Glossary(packs: [GlossaryPack.parse("Lukey = луки", name: "p")],
                                manualTerms: ["LOOKY = луки"])
        #expect(Normalizer.normalise("открой луки", with: glossary).text == "открой LOOKY")
        #expect(glossary.inertTermCountsByPack["p"] == 1)
    }

    @Test func aManualRewriteReportsNoPack() {
        let result = Normalizer.normalise("открой луки",
                                          with: Glossary(manualTerms: ["LOOKY = луки"]))
        #expect(result.rewrites.map(\.packName) == [nil])
        #expect(result.rewrites.map(\.original) == ["луки"])
    }
}
