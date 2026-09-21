import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct GlossarySectionModelTests {
    private func makeModel(
        store: FakeGlossaryStore = FakeGlossaryStore(),
        revealer: FakeFileRevealer = FakeFileRevealer(),
        holder: ScriptedSettingsHolder = ScriptedSettingsHolder(),
        changed: Counter = Counter()
    ) -> GlossarySectionModel {
        GlossarySectionModel(holder: holder,
                             store: store,
                             revealer: revealer,
                             glossaryChanged: { await changed.increment() })
    }

    /// Counts the rebuild requests the section sends upstream.
    actor Counter {
        private(set) var count = 0
        func increment() { count += 1 }
    }

    // MARK: - The first-run offer

    @Test func turningTheSwitchOnTheFirstTimeOffersTheRecommendedPacksAndWritesNothingYet() async {
        let store = FakeGlossaryStore()
        let holder = ScriptedSettingsHolder()
        let model = makeModel(store: store, holder: holder)

        model.setGlossaryEnabled(true)

        #expect(holder.settings.glossaryEnabled)
        #expect(model.isRecommendedOfferPresented)
        #expect(model.recommendedPackNames == FactoryGlossaryPacks.names)
        #expect(await store.mutations.isEmpty)
        #expect(holder.settings.glossaryRecommendedPacksOffered == false)
    }

    @Test func acceptingTheOfferEnablesEveryRecommendedPack() async {
        let store = FakeGlossaryStore()
        let holder = ScriptedSettingsHolder()
        let model = makeModel(store: store, holder: holder)

        model.setGlossaryEnabled(true)
        await model.acceptRecommendedPacks()

        #expect(await store.mutations == FactoryGlossaryPacks.names.map { .setEnabled(true, $0) })
        #expect(await store.state.enabled == FactoryGlossaryPacks.names)
        #expect(model.isRecommendedOfferPresented == false)
        #expect(holder.settings.glossaryRecommendedPacksOffered)
    }

    @Test func decliningTheOfferLeavesTheConfigEmpty() async {
        let store = FakeGlossaryStore()
        let holder = ScriptedSettingsHolder()
        let model = makeModel(store: store, holder: holder)

        model.setGlossaryEnabled(true)
        model.declineRecommendedPacks()

        #expect(await store.mutations.isEmpty)
        #expect(await store.state.enabled.isEmpty)
        #expect(model.isRecommendedOfferPresented == false)
    }

    @Test func theOfferIsNeverMadeTwiceAfterDeclining() async {
        let holder = ScriptedSettingsHolder()
        let model = makeModel(holder: holder)

        model.setGlossaryEnabled(true)
        model.declineRecommendedPacks()
        model.setGlossaryEnabled(false)
        model.setGlossaryEnabled(true)

        #expect(model.isRecommendedOfferPresented == false)
    }

    @Test func theOfferIsNeverMadeTwiceAfterAccepting() async {
        let holder = ScriptedSettingsHolder()
        let model = makeModel(holder: holder)

        model.setGlossaryEnabled(true)
        await model.acceptRecommendedPacks()
        model.setGlossaryEnabled(false)
        model.setGlossaryEnabled(true)

        #expect(model.isRecommendedOfferPresented == false)
    }

    @Test func turningTheSwitchOffNeverOffersAnything() {
        let holder = ScriptedSettingsHolder()
        let model = makeModel(holder: holder)

        model.setGlossaryEnabled(false)

        #expect(model.isRecommendedOfferPresented == false)
        #expect(holder.settings.glossaryEnabled == false)
    }

    // MARK: - What the list shows

    @Test func aRowCarriesItsTermCountAndSkippedLines() async {
        let store = FakeGlossaryStore()
        await store.setPack("# comment\njq\nnvm\n= broken\n", named: "typescript", isFactory: true)
        let model = makeModel(store: store)

        await model.refresh()

        let row = model.rows.first { $0.name == "typescript" }
        #expect(row?.termCount == 2)
        #expect(row?.skippedLineCount == 1)
        #expect(row?.isFactory == true)
        #expect(row?.isEnabled == false)
    }

    @Test func aFactoryRowOffersResetAndAUserRowOffersDelete() async {
        let store = FakeGlossaryStore()
        await store.setPack("jq\n", named: "typescript", isFactory: true)
        await store.setPack("MatchHUD\n", named: "mine", isFactory: false)
        let model = makeModel(store: store)

        await model.refresh()

        let factory = model.rows.first { $0.name == "typescript" }
        let user = model.rows.first { $0.name == "mine" }
        #expect(factory?.canReset == true)
        #expect(factory?.canDelete == false)
        #expect(user?.canReset == false)
        #expect(user?.canDelete == true)
    }

    @Test func aRowCountsTheTermsAnotherSourceHasTakenOver() async {
        let store = FakeGlossaryStore()
        await store.setPack("react-native\n", named: "winner")
        await store.setPack("React Native\nMatchHUD\n", named: "loser")
        await store.setEnabledNames(["winner", "loser"])
        let model = makeModel(store: store)

        await model.refresh()

        #expect(model.rows.first { $0.name == "winner" }?.inertTermCount == 0)
        #expect(model.rows.first { $0.name == "loser" }?.inertTermCount == 1)
        #expect(model.collisionCount == 1)
    }

    @Test func aDisabledPackCountsNoInertTerms() async {
        let store = FakeGlossaryStore()
        await store.setPack("react-native\n", named: "winner")
        await store.setPack("React Native\n", named: "loser")
        await store.setEnabledNames(["winner"])
        let model = makeModel(store: store)

        await model.refresh()

        #expect(model.rows.first { $0.name == "loser" }?.inertTermCount == 0)
        #expect(model.collisionCount == 0)
    }

    @Test func theManualListTakesPartInTheCollisionCount() async {
        let store = FakeGlossaryStore()
        await store.setPack("React Native\n", named: "loser")
        await store.setEnabledNames(["loser"])
        let holder = ScriptedSettingsHolder()
        holder.settings.glossaryManualTerms = ["react-native"]
        let model = makeModel(store: store, holder: holder)

        await model.refresh()

        #expect(model.rows.first { $0.name == "loser" }?.inertTermCount == 1)
    }

    @Test func aPackNamedTwiceInTheConfigDoesNotWarnAboutItself() async {
        let store = FakeGlossaryStore()
        await store.setPack("react-native\nMatchHUD\n", named: "tools")
        await store.setEnabledNames(["tools", "tools"])
        let model = makeModel(store: store)

        await model.refresh()

        #expect(model.rows.first { $0.name == "tools" }?.inertTermCount == 0)
        #expect(model.collisionCount == 0)
    }

    @Test func anUnreadableConfigIsSurfacedAsAMessage() async {
        let store = FakeGlossaryStore()
        await store.setMessage("packs.json could not be read.")
        let model = makeModel(store: store)

        await model.refresh()

        #expect(model.message == "packs.json could not be read.")
    }

    // MARK: - Editing

    @Test func togglingAPackWritesTheConfigAndNothingElse() async {
        let store = FakeGlossaryStore()
        await store.setPack("jq\n", named: "typescript", isFactory: true)
        let changed = Counter()
        let model = makeModel(store: store, changed: changed)
        await model.refresh()

        await model.setEnabled(true, forPackNamed: "typescript")

        #expect(await store.mutations == [.setEnabled(true, "typescript")])
        #expect(await store.state.packs.first?.pack.serialise() == "jq\n")
        #expect(model.rows.first?.isEnabled == true)
        #expect(await changed.count == 1)
    }

    @Test func openingAPackShowsItsTextAndSavingWritesItBackVerbatim() async {
        let store = FakeGlossaryStore()
        let text = "# pack: mine\n\n  jq\nMatchHUD\n"
        await store.setPack(text, named: "mine")
        let changed = Counter()
        let model = makeModel(store: store, changed: changed)
        await model.refresh()

        model.edit(packNamed: "mine")
        #expect(model.editedPackName == "mine")
        #expect(model.editedText == text)

        await model.saveEdits()

        #expect(await store.mutations == [.write("mine")])
        #expect(await store.state.packs.first?.pack.serialise() == text)
        #expect(model.editedPackName == nil)
        #expect(await changed.count == 1)
    }

    @Test func closingTheEditorWithoutSavingWritesNothing() async {
        let store = FakeGlossaryStore()
        await store.setPack("jq\n", named: "mine")
        let model = makeModel(store: store)
        await model.refresh()

        model.edit(packNamed: "mine")
        model.editedText = "jq\nnvm\n"
        model.cancelEdits()

        #expect(await store.mutations.isEmpty)
        #expect(model.editedPackName == nil)
    }

    @Test func creatingAPackAddsItToTheList() async {
        let store = FakeGlossaryStore()
        let model = makeModel(store: store)
        await model.refresh()

        await model.createPack(named: "mine")

        #expect(await store.mutations == [.create("mine")])
        #expect(model.rows.map(\.name) == ["mine"])
        #expect(model.errorMessage == nil)
    }

    @Test func aRefusedPackNameIsReportedAndChangesNothing() async {
        let store = FakeGlossaryStore()
        let model = makeModel(store: store)
        await model.refresh()

        await model.createPack(named: "bad/name")

        #expect(await store.mutations.isEmpty)
        #expect(model.rows.isEmpty)
        #expect(model.errorMessage != nil)
    }

    @Test func aSucceedingActionClearsAnEarlierError() async {
        let store = FakeGlossaryStore()
        let model = makeModel(store: store)

        await model.createPack(named: "")
        #expect(model.errorMessage != nil)

        await model.createPack(named: "mine")
        #expect(model.errorMessage == nil)
    }

    @Test func duplicatingCopiesThePackUnderTheNewName() async {
        let store = FakeGlossaryStore()
        await store.setPack("jq\n", named: "typescript", isFactory: true)
        let model = makeModel(store: store)
        await model.refresh()

        await model.duplicatePack(named: "typescript", as: "mine")

        #expect(await store.mutations == [.duplicate("typescript", "mine")])
        #expect(model.rows.first { $0.name == "mine" }?.isFactory == false)
    }

    @Test func deletingRemovesAUserPack() async {
        let store = FakeGlossaryStore()
        await store.setPack("jq\n", named: "mine")
        let changed = Counter()
        let model = makeModel(store: store, changed: changed)
        await model.refresh()

        await model.deletePack(named: "mine")

        #expect(await store.mutations == [.delete("mine")])
        #expect(model.rows.isEmpty)
        #expect(await changed.count == 1)
    }

    @Test func resettingRestoresAFactoryPack() async {
        let store = FakeGlossaryStore()
        await store.setPack("jq\n", named: "typescript", isFactory: true)
        let changed = Counter()
        let model = makeModel(store: store, changed: changed)
        await model.refresh()

        await model.resetPack(named: "typescript")

        #expect(await store.mutations == [.reset("typescript")])
        #expect(await changed.count == 1)
    }

    @Test func aFailedActionIsReportedAndLeavesTheListReadable() async {
        let store = FakeGlossaryStore()
        await store.setPack("jq\n", named: "mine")
        let model = makeModel(store: store)
        await model.refresh()
        await store.setNextError(MacomprendoError.glossary("the folder is read-only"))

        await model.deletePack(named: "mine")

        #expect(model.errorMessage != nil)
        #expect(model.rows.map(\.name) == ["mine"])
    }

    @Test func aRowWithNoProblemSaysNothingExtra() async {
        let store = FakeGlossaryStore()
        await store.setPack("jq\n", named: "mine")
        let model = makeModel(store: store)

        await model.refresh()

        #expect(model.rows.first?.detailText == "1 term")
        #expect(model.rows.first?.warningText == nil)
    }

    @Test func aRowNamesBothCountsThatMakeAPackDoNothing() {
        let row = GlossaryPackRow(name: "p", termCount: 12, skippedLineCount: 2,
                                  inertTermCount: 3, isFactory: false, isEnabled: true)

        #expect(row.detailText == "12 terms")
        let warning = row.warningText
        #expect(warning?.contains("2 lines") == true)
        #expect(warning?.contains("3 terms") == true)
    }

    @Test func oneOfEachCountIsSingular() {
        let row = GlossaryPackRow(name: "p", termCount: 1, skippedLineCount: 1,
                                  inertTermCount: 1, isFactory: false, isEnabled: true)

        #expect(row.detailText == "1 term")
        #expect(row.warningText?.contains("1 line") == true)
        #expect(row.warningText?.contains("1 term is") == true)
    }

    @Test func revealAsksTheRevealerForTheVocabularyDirectory() {
        let store = FakeGlossaryStore()
        let revealer = FakeFileRevealer()
        let model = makeModel(store: store, revealer: revealer)

        model.reveal()

        #expect(revealer.revealed == [store.directoryURL])
    }

    // MARK: - The manual list

    @Test func manualTermsAreOneTermPerLine() {
        #expect(GlossarySectionModel.manualTerms(from: " jq \n\nMatchHUD\n")
            == ["jq", "MatchHUD"])
        #expect(GlossarySectionModel.manualTermsText(["jq", "MatchHUD"]) == "jq\nMatchHUD")
    }

    @Test func theManualFieldOpensOnTheStoredList() {
        let holder = ScriptedSettingsHolder()
        holder.settings.glossaryManualTerms = ["jq", "MatchHUD"]

        let model = makeModel(holder: holder)

        #expect(model.manualTermsText == "jq\nMatchHUD")
    }

    // The field is edited as text, so what the user typed stays on screen — a half-typed
    // blank line must not be deleted under the cursor — while settings hold the parsed list.
    @Test func editingTheManualListWritesItToSettingsAndLeavesTheTextAlone() {
        let holder = ScriptedSettingsHolder()
        let model = makeModel(holder: holder)

        model.manualTermsText = "jq\n\n  MatchHUD  \n"

        #expect(holder.settings.glossaryManualTerms == ["jq", "MatchHUD"])
        #expect(model.manualTermsText == "jq\n\n  MatchHUD  \n")
    }

    // Trailing whitespace and blank lines are not terms, so typing them must not rewrite the
    // stored list — `AppModel` rebuilds the glossary on every change to it.
    @Test func typingOnlyWhitespaceLeavesTheStoredListAlone() {
        let holder = ScriptedSettingsHolder()
        holder.settings.glossaryManualTerms = ["jq"]
        let model = makeModel(holder: holder)

        model.manualTermsText = "jq\n\n   "

        #expect(holder.settings.glossaryManualTerms == ["jq"])
    }
}
