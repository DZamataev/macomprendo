import Foundation
import Testing
@testable import Macomprendo

/// Builds a pack from term lines, the way a pack file would be read from disk.
private func glossaryPack(_ name: String, _ terms: String...) -> GlossaryPack {
    GlossaryPack.parse(terms.joined(separator: "\n"), name: name)
}

// MARK: - Step 1: keying

@Suite("Glossary keying")
struct GlossaryKeyTests {
    @Test func keyIgnoresCaseAndSeparators() {
        #expect(Glossary.key(for: "Xcode build") == Glossary.key(for: "xcodebuild"))
        #expect(Glossary.key(for: "XcodeBuild") == Glossary.key(for: "xcode-build"))
        #expect(Glossary.key(for: "auto-till-dry") == Glossary.key(for: "Auto-Till-Dry"))
        #expect(Glossary.key(for: "safe_area_view") == Glossary.key(for: "Safe Area View"))
    }

    @Test func keyDropsDotsSoASplitFileNameSharesItsKey() {
        #expect(Glossary.key(for: "MainMenu.tscn") == Glossary.key(for: "MainMenu tscn"))
        #expect(Glossary.key(for: "MainMenu.tscn") == "mainmenutscn")
    }

    @Test func keyKeepsDigits() {
        #expect(Glossary.key(for: "large-v3-turbo") == Glossary.key(for: "Large V3 Turbo"))
        #expect(Glossary.key(for: "large-v3-turbo") == "largev3turbo")
    }

    @Test func keyingIsScriptBlindAndNeverTransliterates() {
        // The 9 % this spec deliberately does not address: a Cyrillic rendering of a Latin
        // term must not be keyed onto it.
        #expect(Glossary.key(for: "метро") != Glossary.key(for: "Metro"))
        #expect(Glossary.key(for: "текст-эдитор") != Glossary.key(for: "TextEditor"))
        #expect(Glossary.key(for: "текст-эдитор") == "текстэдитор")
    }

    @Test func aStringOfOnlySeparatorsHasAnEmptyKey() {
        #expect(Glossary.key(for: " -- ... ") == "")
    }
}

// MARK: - Step 1: collisions

@Suite("Glossary collisions")
struct GlossaryCollisionTests {
    @Test func aTermIsFoundByItsKeyAndNamesItsPack() {
        let glossary = Glossary(packs: [glossaryPack("typescript", "xcodebuild")])
        let entry = glossary.entry(forKey: Glossary.key(for: "Xcode build"))
        #expect(entry?.canonical == "xcodebuild")
        #expect(entry?.packName == "typescript")
        #expect(glossary.collisionCount == 0)
    }

    @Test func aManualTermHasNoPackName() {
        let glossary = Glossary(manualTerms: ["MatchHUD"])
        #expect(glossary.entry(forKey: Glossary.key(for: "match hud"))?.packName == nil)
        #expect(glossary.entry(forKey: Glossary.key(for: "match hud"))?.canonical == "MatchHUD")
    }

    @Test func theManualListWinsOverEveryPack() {
        let glossary = Glossary(
            packs: [glossaryPack("react-native", "react-native")],
            manualTerms: ["React Native"]
        )
        let entry = glossary.entry(forKey: Glossary.key(for: "react native"))
        #expect(entry?.canonical == "React Native")
        #expect(entry?.packName == nil)
        #expect(glossary.collisionCount == 1)
    }

    @Test func anEarlierPackWinsOverALaterOne() {
        // Pack order is `packs.json` order; there is no alphabetical fallback, because a pack
        // absent from `packs.json` is disabled and contributes no terms at all.
        let glossary = Glossary(packs: [
            glossaryPack("react-native", "react-native"),
            glossaryPack("typescript", "React Native"),
        ])
        #expect(glossary.entry(forKey: Glossary.key(for: "reactnative"))?.canonical == "react-native")
        #expect(glossary.entry(forKey: Glossary.key(for: "reactnative"))?.packName == "react-native")
        #expect(glossary.collisionCount == 1)
    }

    @Test func everyLoserIsCountedNotJustTheFirst() {
        let glossary = Glossary(packs: [
            glossaryPack("a", "react-native"),
            glossaryPack("b", "React Native"),
            glossaryPack("c", "ReactNative"),
        ])
        #expect(glossary.collisionCount == 2)
        #expect(glossary.termCount == 1)
    }

    @Test func twoSpellingsOfOneKeyInsideOnePackAlsoCollide() {
        // `GlossaryPack` only de-duplicates identical canonical spellings, so a single pack can
        // still carry two terms that share a key.
        let glossary = Glossary(packs: [glossaryPack("p", "react-native", "React Native")])
        #expect(glossary.entry(forKey: Glossary.key(for: "reactnative"))?.canonical == "react-native")
        #expect(glossary.collisionCount == 1)
    }

    @Test func distinctKeysNeverCollide() {
        let glossary = Glossary(
            packs: [glossaryPack("p", "jq", "nvm", "SafeAreaView")],
            manualTerms: ["MatchHUD"]
        )
        #expect(glossary.termCount == 4)
        #expect(glossary.collisionCount == 0)
    }

    @Test func aTermWithNoKeyableCharactersIsDroppedWithoutCountingAsACollision() {
        let glossary = Glossary(packs: [glossaryPack("p", "---", "jq")], manualTerms: [""])
        #expect(glossary.termCount == 1)
        #expect(glossary.collisionCount == 0)
    }

    @Test func anEmptyGlossaryHasNoTerms() {
        #expect(Glossary().termCount == 0)
        #expect(Glossary().collisionCount == 0)
    }
}

// MARK: - Step 2: matching

/// Normalises with a single unnamed pack holding `terms`.
private func normalised(_ text: String, terms: String...) -> String {
    Normalizer.normalise(text, with: Glossary(packs: [glossaryPack("p", terms.joined(separator: "\n"))])).text
}

@Suite("Normalisation — casing")
struct NormalisationCasingTests {
    @Test func casingIsCorrectedToTheCanonicalSpelling() {
        #expect(normalised("поставил через NVM сегодня", terms: "nvm") == "поставил через nvm сегодня")
    }

    @Test func casingIsCorrectedAcrossHyphens() {
        #expect(normalised("режим Auto-Till-Dry работает", terms: "auto-till-dry")
            == "режим auto-till-dry работает")
    }

    @Test func interiorCasingIsCorrected() {
        #expect(normalised("это называется AutoLoad а сцена", terms: "Autoload")
            == "это называется Autoload а сцена")
    }

    @Test func aTermAlreadyInItsCanonicalSpellingIsNotAChange() {
        let result = Normalizer.normalise(
            "собрал через xcodebuild вчера",
            with: Glossary(packs: [glossaryPack("p", "xcodebuild")])
        )
        #expect(result.text == "собрал через xcodebuild вчера")
        #expect(result.rewrites.isEmpty)
    }
}

@Suite("Normalisation — splitting")
struct NormalisationSplittingTests {
    @Test func aTermSplitInTwoIsJoined() {
        #expect(normalised("и собрал через Xcode build вчера", terms: "xcodebuild")
            == "и собрал через xcodebuild вчера")
    }

    @Test func aTermSplitInThreeIsJoined() {
        #expect(normalised("ведёт себя внутри Safe Area View там", terms: "SafeAreaView")
            == "ведёт себя внутри SafeAreaView там")
    }

    @Test func aMultiWordTermKeepsItsInteriorSpace() {
        #expect(normalised("запустил Xcode gen generate потом", terms: "xcodegen generate")
            == "запустил xcodegen generate потом")
    }

    @Test func aDotIsRestoredFromTheCanonicalSpelling() {
        #expect(normalised("сцена лежит в MainMenu TSCN потом", terms: "MainMenu.tscn")
            == "сцена лежит в MainMenu.tscn потом")
    }

    @Test func aFourWordTermIsTheLongestWindowMatched() {
        #expect(normalised("модель Large V3 Turbo быстрая", terms: "large-v3-turbo")
            == "модель large-v3-turbo быстрая")
        // Five words never key together: `a b c d e` cannot match a single term.
        #expect(normalised("тут a b c d e тут", terms: "abcde") == "тут a b c d e тут")
    }
}

@Suite("Normalisation — window selection")
struct NormalisationWindowTests {
    @Test func theLongestWindowWinsAtAGivenPosition() {
        // Both windows match at the same start; the three-word one must win.
        #expect(normalised("запустил Xcode gen generate потом", terms: "Xcodegen", "xcodegen generate")
            == "запустил xcodegen generate потом")
    }

    @Test func matchingResumesAfterTheWindowItConsumed() {
        #expect(normalised("тут Safe Area View и NVM тут", terms: "SafeAreaView", "nvm")
            == "тут SafeAreaView и nvm тут")
    }

    @Test func twoRewritesInARowBothHappen() {
        #expect(normalised("тут NVM YARN тут", terms: "nvm", "yarn") == "тут nvm yarn тут")
    }
}

@Suite("Normalisation — punctuation")
struct NormalisationPunctuationTests {
    @Test func trailingPunctuationIsDetachedAndReattached() {
        #expect(normalised("собрал через Xcode build, потом ушёл", terms: "xcodebuild")
            == "собрал через xcodebuild, потом ушёл")
    }

    @Test func surroundingBracketsAreDetachedAndReattached() {
        #expect(normalised("в коде (SwiftUi) написано", terms: "SwiftUI") == "в коде (SwiftUI) написано")
    }

    @Test func aTrailingSentenceDotSurvivesTheRewrite() {
        #expect(normalised("собрал через Xcode build. Ушёл", terms: "xcodebuild")
            == "собрал через xcodebuild. Ушёл")
    }
}

@Suite("Normalisation — what it must not touch")
struct NormalisationRestraintTests {
    @Test func anEmptyGlossaryIsTheIdentityFunction() {
        let text = "Сначала я через GQ вытащил поле. Потом Xcode build упал!"
        let result = Normalizer.normalise(text, with: Glossary())
        #expect(result.text == text)
        #expect(result.rewrites.isEmpty)
    }

    @Test func aTermThatIsNotInTheGlossaryIsUntouched() {
        #expect(normalised("проверил через ADB Devices тут", terms: "nvm")
            == "проверил через ADB Devices тут")
    }

    @Test func aSubstitutionIsNotAMatchBecauseItsKeyDiffers() {
        // The two failures normalisation is REQUIRED to leave alone: exact key equality only,
        // no edit distance, no phonetic matching, no threshold.
        #expect(normalised("я через GQ вытащил и линтанул через RAV тут", terms: "jq", "ruff")
            == "я через GQ вытащил и линтанул через RAV тут")
    }

    @Test func aCyrillicWindowNeverMatchesALatinTerm() {
        #expect(normalised("отработает метро потом", terms: "Metro") == "отработает метро потом")
        #expect(normalised("поправил текст-эдитор в настройках", terms: "TextEditor")
            == "поправил текст-эдитор в настройках")
        #expect(normalised("проверил что код ген отработал", terms: "Codegen")
            == "проверил что код ген отработал")
    }

    @Test func whitespaceAndLineStructureAreOtherwisePreserved() {
        #expect(normalised("  через   Xcode build\tтут\n\nи всё  ", terms: "xcodebuild")
            == "  через   xcodebuild\tтут\n\nи всё  ")
    }

    @Test func anEmptyTranscriptIsAnEmptyResult() {
        let result = Normalizer.normalise("", with: Glossary(packs: [glossaryPack("p", "jq")]))
        #expect(result.text == "")
        #expect(result.rewrites.isEmpty)
    }
}

// MARK: - Step 3: the sentence boundary

/// Every test here pairs the case that must stay untouched with a control that must be
/// rewritten, so it cannot pass against a normaliser that simply does nothing.
@Suite("Normalisation — a window never crosses a sentence boundary")
struct NormalisationSentenceBoundaryTests {
    @Test func aFullStopStopsAWindow() {
        #expect(normalised("Закрыл Xcode. Build упал", terms: "xcodebuild") == "Закрыл Xcode. Build упал")
        #expect(normalised("Закрыл Xcode build упал", terms: "xcodebuild") == "Закрыл xcodebuild упал")
    }

    @Test(arguments: ["!", "?", "…", ":", ";"])
    func everyBoundaryPunctuationStopsAWindow(mark: String) {
        #expect(normalised("Закрыл Xcode\(mark) Build упал", terms: "xcodebuild")
            == "Закрыл Xcode\(mark) Build упал")
    }

    @Test func aNewlineStopsAWindow() {
        #expect(normalised("Закрыл Xcode\nbuild упал", terms: "xcodebuild") == "Закрыл Xcode\nbuild упал")
        #expect(normalised("Закрыл Xcode build упал", terms: "xcodebuild") == "Закрыл xcodebuild упал")
    }

    @Test(arguments: ["(", ")", "[", "]", "{", "}", "«", "»", "\"", "„", "“", "”"])
    func aBracketOrQuotationMarkStopsAWindow(mark: String) {
        #expect(normalised("тут Xcode\(mark) build тут", terms: "xcodebuild") == "тут Xcode\(mark) build тут")
        #expect(normalised("тут Xcode\(mark)build тут", terms: "xcodebuild") == "тут Xcode\(mark)build тут")
    }

    @Test func aBoundaryLeadingTheSecondWordAlsoStopsTheWindow() {
        #expect(normalised("тут Xcode (build) тут", terms: "xcodebuild") == "тут Xcode (build) тут")
    }

    @Test func aBoundaryInsideAThreeWordWindowStopsIt() {
        #expect(normalised("внутри Safe Area. View там", terms: "SafeAreaView")
            == "внутри Safe Area. View там")
        #expect(normalised("внутри Safe. Area View там", terms: "SafeAreaView")
            == "внутри Safe. Area View там")
    }

    @Test func aDotInsideOneWordIsNotABoundaryBecauseItIsNotASentenceEnd() {
        // This is the whole reason the key drops dots: `MainMenu.tscn` is one word.
        #expect(normalised("сцена лежит в MainMenu.tscn потом", terms: "MainMenu.tscn")
            == "сцена лежит в MainMenu.tscn потом")
        #expect(normalised("сцена лежит в mainmenu.TSCN потом", terms: "MainMenu.tscn")
            == "сцена лежит в MainMenu.tscn потом")
    }

    @Test func aSingleWordStillMatchesInsideBrackets() {
        // A bracket stops a *window*; it must not stop a one-word term from being recognised.
        #expect(normalised("в коде (swiftui) написано", terms: "SwiftUI") == "в коде (SwiftUI) написано")
    }

    @Test func punctuationDetachedFromAWindowIsNeverSwallowed() {
        // A dash beside a window is stripped before keying and left where it was, so it can
        // neither join the key nor be eaten by the replacement.
        #expect(normalised("тут — Xcode build тут", terms: "xcodebuild") == "тут — xcodebuild тут")
        #expect(normalised("тут «Xcode build» тут", terms: "xcodebuild") == "тут «xcodebuild» тут")
    }
}

// MARK: - Step 3: the sentence capital

@Suite("Normalisation — a sentence's first word keeps its capital")
struct NormalisationSentenceCapitalTests {
    @Test func aSentenceCapitalSurvivesWhenCaseIsTheOnlyDifference() {
        #expect(normalised("Swift хорош", terms: "swift") == "Swift хорош")
        #expect(normalised("Это Swift хорош", terms: "swift") == "Это swift хорош")
    }

    @Test func theRuleAppliesAfterEverySentenceEndNotJustAtTheStartOfTheText() {
        #expect(normalised("Всё упало. Swift хорош", terms: "swift") == "Всё упало. Swift хорош")
        #expect(normalised("Всё упало! Swift хорош", terms: "swift") == "Всё упало! Swift хорош")
        #expect(normalised("Всё упало\nSwift хорош", terms: "swift") == "Всё упало\nSwift хорош")
    }

    @Test func aSentenceCapitalDoesNotSurviveAnyOtherDifference() {
        // The split is fixed and the sentence capital survives it.
        #expect(normalised("Xcode build упал", terms: "xcodebuild") == "Xcodebuild упал")
        #expect(normalised("Auto-Till-Dry сломался", terms: "auto-till-dry") == "Auto-till-dry сломался")
    }

    @Test func anAllCapsAcronymAtASentenceStartKeepsACapitalItDidNotAskFor() {
        // A consequence of the two rules meeting, which the spec does not call out: `NVM` is
        // not a first-letter-case-only difference from `nvm`, so it IS corrected — and because
        // it opens a sentence, the correction keeps its capital. The user who wrote `nvm` in a
        // pack gets `Nvm` here and `nvm` everywhere else. Pinned deliberately: the alternative
        // is to let a rewrite lowercase a sentence's first letter, which rule 2 forbids.
        #expect(normalised("NVM сломался", terms: "nvm") == "Nvm сломался")
        #expect(normalised("Поставил через NVM сегодня", terms: "nvm") == "Поставил через nvm сегодня")
    }

    @Test func interiorCaseIsStillCorrectedAtTheStartOfASentence() {
        #expect(normalised("SwiftUi хорош", terms: "SwiftUI") == "SwiftUI хорош")
    }

    @Test func aTermWhoseCanonicalSpellingStartsWithACapitalIsUnaffectedByTheRule() {
        #expect(normalised("swiftui хорош", terms: "SwiftUI") == "SwiftUI хорош")
    }

    @Test func theRuleDoesNotApplyMidSentence() {
        #expect(normalised("это Swift хорош", terms: "swift") == "это swift хорош")
    }

    @Test func aColonOrABracketDoesNotStartASentence() {
        // `:` `;` and brackets stop a *window* but do not begin a sentence, so no capital is
        // owed to them.
        #expect(normalised("Сказал: Swift хорош", terms: "swift") == "Сказал: swift хорош")
        #expect(normalised("Сказал (Swift) хорош", terms: "swift") == "Сказал (swift) хорош")
    }

    @Test func everyWindowAtASentenceStartIsProtectedInTurn() {
        // `Git rebase` differs from `git rebase` only in the sentence capital, so it is left
        // alone — and the shorter window `Git` is protected by the same rule rather than being
        // rewritten to `git` once the longer one declines.
        #expect(normalised("Git rebase на main", terms: "git rebase", "git") == "Git rebase на main")
        #expect(normalised("Сделал Git rebase на main", terms: "git rebase", "git")
            == "Сделал git rebase на main")
    }

    @Test func aLeadingQuoteDoesNotHideTheSentenceStart() {
        #expect(normalised("«Swift хорош»", terms: "swift") == "«Swift хорош»")
    }
}

// MARK: - Step 4: provenance

@Suite("Normalisation — ranges and provenance")
struct NormalisationProvenanceTests {
    @Test func nothingChangedMeansNoRewrites() {
        let result = Normalizer.normalise("ничего тут нет", with: Glossary(packs: [glossaryPack("p", "jq")]))
        #expect(result.rewrites.isEmpty)
    }

    @Test func aRewriteCarriesItsOriginalAndItsTerm() {
        let result = Normalizer.normalise(
            "собрал через Xcode build вчера",
            with: Glossary(packs: [glossaryPack("typescript", "xcodebuild")])
        )
        #expect(result.rewrites.count == 1)
        #expect(result.rewrites.first?.original == "Xcode build")
        #expect(result.rewrites.first?.term == "xcodebuild")
    }

    @Test func aRangeIndexesTheFinalStringNotTheInput() {
        // `Safe Area View` → `SafeAreaView` shortens the text, so a range taken against the
        // input and returned unadjusted would underline the wrong words.
        let result = Normalizer.normalise(
            "внутри Safe Area View и NVM тут",
            with: Glossary(packs: [glossaryPack("p", "SafeAreaView", "nvm")])
        )
        #expect(result.text == "внутри SafeAreaView и nvm тут")
        #expect(result.rewrites.count == 2)
        for rewrite in result.rewrites {
            #expect(String(result.text[rewrite.range]) == rewrite.term)
        }
    }

    @Test func aRangeIsCorrectWhenTheRewriteLengthensTheText() {
        let result = Normalizer.normalise(
            "сцена лежит в MainMenu TSCN потом",
            with: Glossary(packs: [glossaryPack("p", "MainMenu.tscn")])
        )
        #expect(result.text == "сцена лежит в MainMenu.tscn потом")
        #expect(result.rewrites.first.map { String(result.text[$0.range]) } == "MainMenu.tscn")
    }

    @Test func rangesCoverExactlyTheRewrittenSpansAndExcludePunctuation() {
        let result = Normalizer.normalise(
            "в коде (swiftui), потом",
            with: Glossary(packs: [glossaryPack("p", "SwiftUI")])
        )
        #expect(result.text == "в коде (SwiftUI), потом")
        #expect(result.rewrites.first.map { String(result.text[$0.range]) } == "SwiftUI")
        #expect(result.rewrites.first?.original == "swiftui")
    }

    @Test func rewritesAreReportedInTheOrderTheyAppear() {
        let result = Normalizer.normalise(
            "тут NVM потом YARN потом PNPM",
            with: Glossary(packs: [glossaryPack("p", "nvm", "yarn", "pnpm")])
        )
        #expect(result.rewrites.map(\.term) == ["nvm", "yarn", "pnpm"])
        #expect(result.rewrites.map { result.text.distance(from: result.text.startIndex, to: $0.range.lowerBound) }
            == [4, 14, 25])
    }

    @Test func eachRewriteNamesThePackThatOwnsItsTerm() {
        let result = Normalizer.normalise(
            "через NVM и Safe Area View",
            with: Glossary(packs: [
                glossaryPack("typescript", "nvm"),
                glossaryPack("react-native", "SafeAreaView"),
            ])
        )
        #expect(result.rewrites.map(\.packName) == ["typescript", "react-native"])
    }

    @Test func aManualTermReportsNoPack() {
        let result = Normalizer.normalise(
            "это Match Hud тут",
            with: Glossary(packs: [glossaryPack("p", "nvm")], manualTerms: ["MatchHUD"])
        )
        #expect(result.rewrites.map(\.term) == ["MatchHUD"])
        #expect(result.rewrites.first?.packName == nil)
    }

    @Test func aTermWinningAKeyCollisionReportsThePackThatWon() {
        let result = Normalizer.normalise(
            "в react native проекте",
            with: Glossary(packs: [
                glossaryPack("react-native", "react-native"),
                glossaryPack("typescript", "React Native"),
            ])
        )
        #expect(result.text == "в react-native проекте")
        #expect(result.rewrites.first?.packName == "react-native")
    }

    @Test func aSentenceCapitalLeftAloneIsNotReportedAsARewrite() {
        let result = Normalizer.normalise("Swift хорош", with: Glossary(packs: [glossaryPack("p", "swift")]))
        #expect(result.text == "Swift хорош")
        #expect(result.rewrites.isEmpty)
    }
}

// MARK: - Step 6: the control-dictation regression pin

/// The five transcripts of `docs/superpowers/specs/2026-09-14-glossary-control-dictation.md`
/// (`ggml-large-v3-turbo`, Russian pinned, history ids 264–268), fed through the normaliser with
/// a pack holding the terms that dictation broke.
///
/// **This pins behaviour; it does not measure effectiveness.** The rules were derived from this
/// text and the terms were then taken from it, so the ratio it produces measures how well a rule
/// fits the data that produced it. The honest number requires the second control dictation the
/// spec calls for. What the test is worth is the other half: the failures normalisation must
/// **not** touch — `GQ`, `RAV`, `Rancor Lite`, `Match Hut`, `под install`, `метро`, `код ген` —
/// are asserted to survive unchanged.
@Suite("Normalisation — control-dictation regression pin")
struct ControlDictationRegressionPinTests {
    /// The six factory packs, read out of the bundle — the text that actually ships, so this
    /// pin fails when a shipped pack drifts away from the behaviour it records.
    ///
    /// Task 3 built this glossary by hand from the dictation's failure table; Task 4 repointed
    /// it. The hand-built list is gone deliberately: left in place it would have kept passing
    /// while the packs changed underneath it.
    static let factoryPacks: [GlossaryPack] = FactoryGlossaryPacks.names.compactMap {
        FactoryGlossaryPacks.pack($0)
    }

    /// The dictation's project-specific terms, which cannot be factory terms: they name the
    /// speaker's own projects, modules and models. The spec's factory set is per-stack plus
    /// "one per active project the user chooses to add" — this stands in for that pack.
    ///
    /// `TextEditor` and `MainMenu.tscn` are here for the same reason: the first is a SwiftUI
    /// type with no factory pack to live in, the second is a scene file name, and the `godot`
    /// pack says scene names belong in a pack of your own.
    static let personalPack = GlossaryPack.parse("""
    TextEditor
    MainMenu.tscn
    auto-till-dry
    look-box
    rn-core-lite
    Footmen Frenzy
    MatchHUD
    SherpaOnnx
    large-v3-turbo
    """, name: "personal")

    static var glossary: Glossary { Glossary(packs: factoryPacks + [personalPack]) }

    private func pin(_ transcript: String, _ expected: String) {
        #expect(Normalizer.normalise(transcript, with: Self.glossary).text == expected)
    }

    @Test func transcript264ShortCommandsAndAbbreviations() {
        pin(
            "Сначала я через GQ вытащил поле из ответа, потом проверил устройство через ADB Devices, "
                + "а на симуляторе через IDB. Переключил ноду через NVM, поставил зависимости через "
                + "YARN, а в другом проекте через PNPM. Прогнал TSC, потом OXLint, а форматирование "
                + "сделал через OXFMT. Теперь поставил все через UV и лентонул через RAV. Посмотрел "
                + "pull request через GH, поискал по коду через RG.",
            // `GQ` and `RAV` are substitutions: their keys differ, so exact matching leaves them
            // wrong, which is the behaviour being pinned.
            "Сначала я через GQ вытащил поле из ответа, потом проверил устройство через adb devices, "
                + "а на симуляторе через idb. Переключил ноду через nvm, поставил зависимости через "
                + "yarn, а в другом проекте через pnpm. Прогнал tsc, потом oxlint, а форматирование "
                + "сделал через oxfmt. Теперь поставил все через uv и лентонул через RAV. Посмотрел "
                + "pull request через gh, поискал по коду через rg."
        )
    }

    @Test func transcript265ToolsAndTwoWordCommands() {
        pin(
            "Сделал git rebase на main, потом git stash, потом force push. Запустил npm run build, "
                + "дождался пока отработает метро. И собрал через Xcode build. В React Native проекте "
                + "сначала под install, потом yarn IOS. Проверил, что Watchman не завис. Запустил "
                + "Xcode gen generate, потому что поменял project yaml.",
            // `метро` and `под install` are Cyrillic renderings of Latin terms — the 9 % this
            // spec does not address and must not fake. `project yaml` is a substitution.
            "Сделал git rebase на main, потом git stash, потом force push. Запустил npm run build, "
                + "дождался пока отработает метро. И собрал через xcodebuild. В React Native проекте "
                + "сначала под install, потом yarn ios. Проверил, что watchman не завис. Запустил "
                + "xcodegen generate, потому что поменял project yaml."
        )
    }

    @Test func transcript266CompoundNamesWrittenAsOneWord() {
        pin(
            "Поправил текст-эдитор в настройках, потом посмотрел, как ведет себя scrollview внутри "
                + "Safe Area View. В Swift коде это SwiftUI, а раньше был UIKit. Подключил "
                + "TurboModules и проверил, что код ген отработал. В Godot это называется AutoLoad, "
                + "а сцена лежит в MainMenu TSCN.",
            "Поправил текст-эдитор в настройках, потом посмотрел, как ведет себя ScrollView внутри "
                + "SafeAreaView. В Swift коде это SwiftUI, а раньше был UIKit. Подключил "
                + "TurboModules и проверил, что код ген отработал. В Godot это называется Autoload, "
                + "а сцена лежит в MainMenu.tscn."
        )
    }

    @Test func transcript267OwnTerms() {
        pin(
            "В нашем проекте есть режим Auto-Till-Dry, и он не то же самое, что Lookbox. Модуль "
                + "называется Rancor Lite. В Footman Frenzy это Match Hut. У Macomprenda билд "
                + "называется Sherpa ONX, а модель Large V3 Turbo.",
            // `Rancor Lite`, `Footman Frenzy` and `Match Hut` are substitutions. `Sherpa ONX` is
            // filed as a split in the dictation, but its letters differ from `SherpaOnnx`, so
            // exact key equality cannot reach it either.
            "В нашем проекте есть режим auto-till-dry, и он не то же самое, что look-box. Модуль "
                + "называется Rancor Lite. В Footman Frenzy это Match Hut. У Macomprenda билд "
                + "называется Sherpa ONX, а модель large-v3-turbo."
        )
    }

    @Test func transcript268RussianSpeechInflectingTheTerms() {
        pin(
            "Открыл настройки в текст-эдитере, поправил в текст-эдитере еще раз, потом закрыл "
                + "текст-эдитер, работал с нады, зашел в наду, вышел из нады, пересобрал через "
                + "xcode build, потому что в xcode build поменялись флаги.",
            "Открыл настройки в текст-эдитере, поправил в текст-эдитере еще раз, потом закрыл "
                + "текст-эдитер, работал с нады, зашел в наду, вышел из нады, пересобрал через "
                + "xcodebuild, потому что в xcodebuild поменялись флаги."
        )
    }

    @Test func theCorpusRewriteCountIsPinnedAndItsProvenanceIsComplete() {
        let transcripts = [
            "Сначала я через GQ вытащил поле из ответа, потом проверил устройство через ADB Devices, "
                + "а на симуляторе через IDB. Переключил ноду через NVM, поставил зависимости через "
                + "YARN, а в другом проекте через PNPM. Прогнал TSC, потом OXLint, а форматирование "
                + "сделал через OXFMT. Теперь поставил все через UV и лентонул через RAV. Посмотрел "
                + "pull request через GH, поискал по коду через RG.",
            "Сделал git rebase на main, потом git stash, потом force push. Запустил npm run build, "
                + "дождался пока отработает метро. И собрал через Xcode build. В React Native проекте "
                + "сначала под install, потом yarn IOS. Проверил, что Watchman не завис. Запустил "
                + "Xcode gen generate, потому что поменял project yaml.",
            "Поправил текст-эдитор в настройках, потом посмотрел, как ведет себя scrollview внутри "
                + "Safe Area View. В Swift коде это SwiftUI, а раньше был UIKit. Подключил "
                + "TurboModules и проверил, что код ген отработал. В Godot это называется AutoLoad, "
                + "а сцена лежит в MainMenu TSCN.",
            "В нашем проекте есть режим Auto-Till-Dry, и он не то же самое, что Lookbox. Модуль "
                + "называется Rancor Lite. В Footman Frenzy это Match Hut. У Macomprenda билд "
                + "называется Sherpa ONX, а модель Large V3 Turbo.",
            "Открыл настройки в текст-эдитере, поправил в текст-эдитере еще раз, потом закрыл "
                + "текст-эдитер, работал с нады, зашел в наду, вышел из нады, пересобрал через "
                + "xcode build, потому что в xcode build поменялись флаги.",
        ]
        let results = transcripts.map { Normalizer.normalise($0, with: Self.glossary) }
        let rewrites = results.flatMap(\.rewrites)

        // 24 rewritten spans: the spec's figure, which counts text occurrences — `xcodebuild`
        // appears twice in transcript 268 while the dictation's table lists it once.
        #expect(rewrites.count == 24)
        #expect(results.map(\.rewrites.count) == [11, 4, 4, 3, 2])
        // Every rewrite names the pack it came from, and every one of those packs is real.
        let sources = Set(Self.factoryPacks.map(\.name) + [Self.personalPack.name])
        #expect(rewrites.allSatisfy { $0.packName.map(sources.contains) == true })
        // The provenance is specific, not merely non-nil: a term moved between factory packs
        // must show up here rather than pass silently.
        let packByTerm = Dictionary(
            rewrites.map { ($0.term, $0.packName) }, uniquingKeysWith: { first, _ in first }
        )
        #expect(packByTerm["nvm"] == "typescript")
        #expect(packByTerm["xcodebuild"] == "react-native")
        #expect(packByTerm["uv"] == "python")
        #expect(packByTerm["Autoload"] == "godot")
        #expect(packByTerm["auto-till-dry"] == "personal")
        // Every range indexes the final string it belongs to.
        for result in results {
            for rewrite in result.rewrites {
                #expect(String(result.text[rewrite.range]) == rewrite.term)
            }
        }
        // Nothing normalisation must not touch was touched.
        for forbidden in ["GQ", "RAV", "Rancor Lite", "Footman Frenzy", "Match Hut", "Sherpa ONX",
                          "метро", "под install", "код ген", "текст-эдитор", "project yaml"] {
            #expect(rewrites.allSatisfy { $0.original != forbidden })
        }
    }
}

@Suite("Normalisation — the sentence capital, read as protection rather than as a veto")
struct NormalisationSentenceCapitalDirectionTests {
    @Test func aLowercaseWordAtASentenceStartIsStillRaisedToItsCanonicalCapital() {
        // The spec's rule reads "the only difference is the case of its first letter, leave it
        // alone", which taken literally would also leave `swift` alone against a pack holding
        // `Swift`. That direction has nothing to protect: the canonical spelling and the
        // sentence's capital want the same letter, and leaving it would paste a sentence
        // starting in lowercase. The rule protects a capital; it does not forbid gaining one.
        #expect(normalised("swift хорош", terms: "Swift") == "Swift хорош")
        #expect(normalised("это swift хорош", terms: "Swift") == "это Swift хорош")
    }

    @Test func aCapitalIsStillNeverLostAtASentenceStart() {
        #expect(normalised("Swift хорош", terms: "swift") == "Swift хорош")
    }
}
