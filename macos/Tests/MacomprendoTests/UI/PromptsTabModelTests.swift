import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct PromptsTabModelTests {
    private func make(deltas: [String] = ["tested"], failure: MacomprendoError? = nil)
        -> (PromptsTabModel, ScriptedSettingsHolder, LLMCallRecorder) {
        let holder = ScriptedSettingsHolder.seeded()
        let recorder = LLMCallRecorder()
        let provider = ScriptedLLMProvider(deltas: deltas, failure: failure, recorder: recorder)
        let model = PromptsTabModel(holder: holder,
                                    llm: { _ in LLMTarget(provider: provider, model: "m") })
        return (model, holder, recorder)
    }

    @Test func startsOnRefineWithTheFirstPresetSelected() {
        let (model, _, _) = make()
        #expect(model.kind == .refine)
        #expect(model.presets.count == 7)
        #expect(model.selectedID == FactoryPresets.ID.cleanUp)
        #expect(model.draft?.name == "Clean up")
        #expect(model.problems.isEmpty)
    }

    @Test func switchingKindSelectsThatKindsFirstPreset() {
        let (model, _, _) = make()
        model.kind = .summarize
        #expect(model.presets.count == 4)
        #expect(model.selectedID == FactoryPresets.ID.brief)
    }

    @Test func editingTheDraftAndSavingWritesThrough() {
        let (model, holder, _) = make()
        model.draft?.name = "Tidy up"
        model.save()
        #expect(holder.settings.preset(id: FactoryPresets.ID.cleanUp)?.name == "Tidy up")
    }

    @Test func validationProblemsAreRepublishedOnSave() {
        let (model, _, _) = make()
        model.draft?.userTemplate = "no placeholder here"
        model.save()
        #expect(model.problems.contains("The user template must contain {text}."))
    }

    @Test func addCreatesACustomPresetOfTheCurrentKindAndSelectsIt() {
        let (model, holder, _) = make()
        model.add()
        #expect(holder.settings.presets(of: .refine, language: "en").count == 8)
        #expect(model.draft?.isFactory == false)
        #expect(model.draft?.id == model.selectedID)
        #expect(model.presets.last?.id == model.selectedID)
    }

    @Test func duplicateCopiesTheSelectionAsANonFactoryPreset() {
        let (model, holder, _) = make()
        model.duplicate()
        #expect(holder.settings.presets(of: .refine, language: "en").count == 8)
        #expect(model.draft?.name == "Clean up copy")
        #expect(model.draft?.isFactory == false)
        #expect(model.draft?.userTemplate == FactoryPresets.refine()[0].userTemplate)
    }

    @Test func deleteRemovesTheSelectionAndSelectsAnother() {
        let (model, holder, _) = make()
        model.delete()
        #expect(holder.settings.preset(id: FactoryPresets.ID.cleanUp) == nil)
        #expect(model.selectedID == FactoryPresets.ID.formal)
        #expect(model.lastError == nil)
    }

    @Test func deletingTheLastPresetOfAKindPublishesAnError() {
        let (model, holder, _) = make()
        while holder.settings.presets(of: .refine, language: "en").count > 1 { model.delete() }
        model.delete()
        #expect(holder.settings.presets(of: .refine, language: "en").count == 1)
        #expect(model.lastError?.contains("At least one") == true)
    }

    @Test func moveReordersWithinTheKind() {
        let (model, _, _) = make()
        model.move(from: IndexSet(integer: 6), to: 0)     // Translate to the top
        #expect(model.presets.first?.id == FactoryPresets.ID.translate)
    }

    @Test func makeDefaultUpdatesSettings() {
        let (model, holder, _) = make()
        model.select(FactoryPresets.ID.formal)
        model.makeDefault()
        #expect(holder.settings.defaultPresetID(for: .refine, language: "en") == FactoryPresets.ID.formal)
    }

    @Test func restoreFactoryReaddsDeletedFactoryPresets() {
        let (model, holder, _) = make()
        model.delete()                                   // removes Clean up
        model.restoreFactory()
        #expect(holder.settings.preset(id: FactoryPresets.ID.cleanUp) != nil)
        #expect(holder.settings.presets(of: .refine, language: "en").count == 7)
    }

    @Test func testWithSampleTextStreamsIntoTheOutputBox() async {
        let (model, _, recorder) = make(deltas: ["Ti", "dy"])
        model.runTest()
        await model.drainTest()
        #expect(model.testOutput == "Tidy")
        #expect(!model.isTesting)
        #expect(model.testError == nil)
        #expect(recorder.calls.last?.messages.last?.content.contains(PromptsTabModel.sampleText) == true)
    }

    @Test func aFailingTestShowsTheProviderError() async {
        let (model, _, _) = make(deltas: [], failure: .providerUnreachable(endpointName: "Ollama (local)"))
        model.runTest()
        await model.drainTest()
        #expect(model.testError != nil)
        #expect(!model.isTesting)
    }

    @Test func aSecondRunTestSupersedesTheFirst() async {
        let holder = ScriptedSettingsHolder.seeded()
        // The first run never completes within the test window, but its cancellation is
        // near-instant — that's exactly when its unguarded `defer` would fire.
        let first = ScriptedLLMProvider(deltas: ["first"], delayPerDelta: .seconds(5))
        // The second run streams for a while, so we can observe state mid-stream.
        let second = ScriptedLLMProvider(deltas: ["a", "b"], delayPerDelta: .milliseconds(60))
        var callCount = 0
        let model = PromptsTabModel(holder: holder, llm: { _ in
            callCount += 1
            return callCount == 1
                ? LLMTarget(provider: first, model: "first")
                : LLMTarget(provider: second, model: "second")
        })

        model.runTest()      // starts the slow first run
        model.runTest()      // supersedes it with the second run

        // Give the cancelled first run's task time to unwind (cancellation is near-instant)
        // while the second run is still mid-stream (its first delta lands after 60ms).
        try? await Task.sleep(for: .milliseconds(20))
        #expect(model.isTesting)             // the second run must still read as in-flight
        #expect(model.testOutput.isEmpty)    // neither run has appended anything yet

        await model.drainTest()

        #expect(model.testOutput == "ab")
        #expect(!model.isTesting)
        #expect(model.testError == nil)
    }

    @Test func loadModelsPublishesTheProviderList() async {
        let (model, _, _) = make()
        await model.loadModels()
        #expect(model.availableModels == ["scripted-model"])
        #expect(model.modelsError == nil)
    }

    @Test func selectionReadsAndWritesThePerFeatureLLMChoice() {
        let (model, holder, _) = make()
        let endpointID = holder.settings.endpoints[0].id
        model.selection = LLMSelection(endpointID: endpointID, model: "llama3.2")
        #expect(holder.settings.refineLLM == LLMSelection(endpointID: endpointID, model: "llama3.2"))
        model.kind = .summarize
        model.selection = LLMSelection(endpointID: endpointID, model: "qwen2.5:1.5b")
        #expect(holder.settings.summarizeLLM?.model == "qwen2.5:1.5b")
        #expect(holder.settings.refineLLM?.model == "llama3.2")
    }
}
