import Foundation
import Testing
@testable import Macomprendo

@Suite @MainActor struct DictationTabModelTests {

    private func tabModel(_ settings: Settings = .default) -> DictationTabModel {
        DictationTabModel(holder: ScriptedSettingsHolder(settings), catalog: ModelCatalog.all)
    }

    private func endpointSettings(id: UUID = UUID(), model: String = "whisper-1") -> Settings {
        var settings = Settings.default
        settings.transcriptionSource = .endpoint(id: id, model: model)
        return settings
    }

    // MARK: - Navigation

    @Test func theSubTabShownOnOpenIsTheOneTheActiveModelBelongsTo() {
        var settings = Settings.default
        settings.transcriptionSource = .local(modelID: "gigaam-v3-e2e-ctc")
        #expect(tabModel(settings).viewedTab == .gigaAM)

        settings.transcriptionSource = .local(modelID: "base")
        #expect(tabModel(settings).viewedTab == .whisperCpp)

        #expect(tabModel(endpointSettings()).viewedTab == .endpoint)
    }

    @Test func movingBetweenSubTabsChangesNothingButWhatIsOnScreen() {
        var settings = Settings.default
        settings.transcriptionSource = .local(modelID: "large-v3-turbo")
        let tab = tabModel(settings)
        let before = tab.holder.settings

        tab.viewedTab = .gigaAM
        tab.viewedTab = .endpoint
        tab.viewedTab = .whisperCpp

        // The whole point of the redesign: navigation writes nothing at all, so the round trip
        // that used to downgrade Large v3 Turbo to Tiny cannot happen.
        #expect(tab.holder.settings == before)
        #expect(tab.holder.settings.transcriptionSource == .local(modelID: "large-v3-turbo"))
    }

    @Test func eachTabListsOnlyItsOwnEnginesModels() {
        let tab = tabModel()
        #expect(tab.rows(for: .gigaAM).allSatisfy { $0.engine == .gigaAM })
        #expect(tab.rows(for: .gigaAM).count == 4)
        #expect(tab.rows(for: .whisperCpp).count == 9)
        #expect(tab.rows(for: .endpoint).isEmpty)
    }

    // MARK: - The active-model selector

    @Test func activatingAModelMakesItTheConfiguredSource() {
        let tab = tabModel()

        tab.activate(.local(modelID: "gigaam-multilingual-large-ctc"))

        #expect(tab.holder.settings.transcriptionSource == .local(modelID: "gigaam-multilingual-large-ctc"))
    }

    @Test func theRowShortcutIsTheSelectorAndNotASecondSourceOfTruth() {
        let tab = tabModel()

        tab.select(modelID: "gigaam-multilingual-ctc")

        #expect(tab.holder.settings.transcriptionSource == .local(modelID: "gigaam-multilingual-ctc"))
        #expect(tab.activeSource == .local(modelID: "gigaam-multilingual-ctc"))
    }

    @Test func theSelectorListsEveryDownloadedModelAndNothingElse() {
        let tab = tabModel()
        tab.modelStates = ["base": .downloaded,
                           "large-v3-turbo": .downloaded,
                           "gigaam-v3-e2e-ctc": .downloaded,
                           "small": .downloading(fraction: 0.5),
                           "medium": .failed("checksum mismatch")]

        let listed = tab.selectableSources.map(\.source)

        #expect(listed.contains(.local(modelID: "base")))
        #expect(listed.contains(.local(modelID: "gigaam-v3-e2e-ctc")))
        #expect(!listed.contains(.local(modelID: "small")))
        #expect(!listed.contains(.local(modelID: "medium")))
        #expect(!listed.contains(.local(modelID: "tiny")))
        #expect(tab.selectableSources.allSatisfy { $0.isReady })
    }

    @Test func theSelectorKeepsTheActiveSourceEvenWhenItIsNoLongerReady() {
        // Its files were deleted after it was chosen. Dropping it out of view would leave a
        // Picker whose selection is not among its options, and hide the user's own setting.
        let tab = tabModel()
        tab.modelStates = ["base": .downloaded, "large-v3-turbo": .notDownloaded]

        let active = tab.selectableSources.first { $0.source == .local(modelID: "large-v3-turbo") }

        #expect(active != nil)
        #expect(active?.isReady == false)
        #expect(active?.menuTitle == "Large v3 Turbo — not ready")
        #expect(tab.selectableSources.first { $0.source == .local(modelID: "base") }?.menuTitle
                == "Base (multilingual)")
    }

    @Test func theSelectorIsDisabledAndSaysSoWhenNothingIsReady() {
        let tab = tabModel()
        tab.modelStates = ["large-v3-turbo": .notDownloaded]

        #expect(!tab.hasReadySource)
        #expect(tab.selectorCaption == "No model is ready — download one below.")

        tab.modelStates["base"] = .downloaded
        #expect(tab.hasReadySource)
        #expect(tab.selectorCaption.isEmpty)
    }

    @Test func theSelectorOffersAProbedEndpoint() {
        let id = UUID()
        let tab = tabModel(endpointSettings(id: id))
        tab.endpointProbe = .succeeded(id: id, model: "whisper-1")

        let entry = tab.selectableSources.first { $0.source == .endpoint(id: id, model: "whisper-1") }

        #expect(entry?.isReady == true)
        #expect(entry?.menuTitle == "OpenAI endpoint · whisper-1")
    }

    @Test func theSelectorDoesNotCallAnEndpointReadyOnAProbeOfAnotherServer() {
        let id = UUID()
        let tab = tabModel(endpointSettings(id: id))
        tab.endpointProbe = .succeeded(id: UUID(), model: "whisper-1")

        #expect(tab.selectableSources.first { $0.source == .endpoint(id: id, model: "whisper-1") }?
                .isReady == false)

        tab.endpointProbe = .succeeded(id: id, model: "gpt-4o-transcribe")
        #expect(tab.selectableSources.first { $0.source == .endpoint(id: id, model: "whisper-1") }?
                .isReady == false)
    }

    @Test func aConfiguredButInactiveEndpointJoinsTheListOnceItHasBeenProbed() {
        var settings = Settings.default
        let id = UUID()
        settings.lastTranscriptionEndpointID = id
        settings.lastTranscriptionEndpointModel = "whisper-1"
        let tab = tabModel(settings)
        tab.modelStates = ["large-v3-turbo": .downloaded]

        #expect(!tab.selectableSources.contains { $0.source == .endpoint(id: id, model: "whisper-1") })

        tab.endpointProbe = .succeeded(id: id, model: "whisper-1")
        #expect(tab.selectableSources.contains { $0.source == .endpoint(id: id, model: "whisper-1") })
    }

    // MARK: - The status block

    @Test func aReadySelectionSaysThisIsTheActiveDictationModel() {
        let tab = tabModel()
        tab.activate(.local(modelID: "gigaam-v3-e2e-ctc"))
        tab.modelStates["gigaam-v3-e2e-ctc"] = .downloaded

        #expect(tab.readiness == .ready)
        #expect(tab.statusHeadline == "Ready to use")
        #expect(tab.statusDetail.contains("GigaAM v3 e2e CTC (Russian)"))
        #expect(tab.statusDetail.lowercased().contains("dictation"))
    }

    @Test func anUnreadySelectionExplainsWhatIsWrongAndThatDictationWillFail() {
        let tab = tabModel()
        tab.activate(.local(modelID: "gigaam-v3-e2e-ctc"))
        tab.modelStates["gigaam-v3-e2e-ctc"] = .notDownloaded

        #expect(tab.statusHeadline == "Not ready")
        #expect(tab.statusDetail.contains("has not been downloaded"))
        #expect(tab.statusDetail.lowercased().contains("will fail"))
    }

    @Test func theStatusBlockDescribesTheSelectionRatherThanTheTabBeingViewed() {
        let tab = tabModel()
        tab.activate(.local(modelID: "base"))
        tab.modelStates["base"] = .downloaded

        tab.viewedTab = .gigaAM

        #expect(tab.statusHeadline == "Ready to use")
        #expect(tab.statusDetail.contains("Base (multilingual)"))
    }

    @Test func anEndpointSourceIsNamedByItsModel() {
        #expect(tabModel(endpointSettings()).activeSourceName == "OpenAI endpoint · whisper-1")
    }

    @Test func gigaAMReportsThatItHasNoParametersToConfigure() {
        #expect(DictationBackendTab.gigaAM.parameterSummary.lowercased().contains("no settings"))
        #expect(DictationBackendTab.whisperCpp.parameterSummary.isEmpty)
    }

    // MARK: - Configuring the endpoint without activating it

    @Test func choosingAnEndpointRecordsItWithoutMakingItTheSource() {
        let tab = tabModel()      // active source is a local model
        let id = UUID()

        tab.select(endpointID: id)
        tab.select(endpointModel: "gpt-4o-transcribe")

        #expect(tab.holder.settings.lastTranscriptionEndpointID == id)
        #expect(tab.holder.settings.lastTranscriptionEndpointModel == "gpt-4o-transcribe")
        #expect(tab.holder.settings.transcriptionSource == .local(modelID: "large-v3-turbo"))
    }

    @Test func editingTheAlreadyActiveEndpointKeepsTheSourceInStep() {
        // Editing the endpoint that is *already* transcribing is not an activation, and
        // leaving the source pointing at the old model name would be a lie.
        let id = UUID()
        let tab = tabModel(endpointSettings(id: id))

        tab.select(endpointModel: "gpt-4o-transcribe")

        #expect(tab.holder.settings.transcriptionSource == .endpoint(id: id, model: "gpt-4o-transcribe"))
        #expect(tab.holder.settings.lastTranscriptionEndpointModel == "gpt-4o-transcribe")
    }

    @Test func changingTheEndpointDropsAProbeThatProvedADifferentServer() {
        let id = UUID()
        let tab = tabModel(endpointSettings(id: id))
        tab.endpointProbe = .succeeded(id: id, model: "whisper-1")

        tab.select(endpointID: UUID())

        #expect(tab.endpointProbe == nil)
        #expect(tab.statusHeadline == "Not ready")
    }

    @Test func changingTheEndpointModelDropsAProbeThatProvedADifferentModel() {
        let id = UUID()
        let tab = tabModel(endpointSettings(id: id))
        tab.endpointProbe = .succeeded(id: id, model: "whisper-1")

        tab.select(endpointModel: "gpt-4o-transcribe")

        #expect(tab.endpointProbe == nil)
    }

    // MARK: - The endpoint probe

    @Test func theTestButtonSaysWhetherThisEndpointHasEverAnswered() {
        let id = UUID()
        let tab = tabModel(endpointSettings(id: id))
        #expect(tab.probeCaption.contains("test clip"))

        tab.endpointProbe = .succeeded(id: id, model: "whisper-1")
        #expect(tab.probeCaption == "This endpoint transcribed a one-second test clip.")

        tab.endpointProbe = .failed("Could not reach the server.")
        // The reason is shown once, in the status block, not twice.
        #expect(!tab.probeCaption.contains("Could not reach the server."))
        #expect(tab.probeCaption.lowercased().contains("failed"))
    }

    @Test func theProbeTestsTheConfiguredEndpointEvenWhileALocalModelIsActive() async {
        // The whole point of configuring without activating: the Test button has to reach the
        // endpoint being set up, not whatever is transcribing at the moment.
        var settings = Settings.default          // active source is a local model
        let id = UUID()
        settings.lastTranscriptionEndpointID = id
        settings.lastTranscriptionEndpointModel = "whisper-1"
        let tab = tabModel(settings)
        let http = StubHTTPClient()
        http.stub("POST", path: "/v1/audio/transcriptions", body: Data(#"{"text":"hi"}"#.utf8))
        var asked: TranscriptionSource?

        await tab.probeEndpoint { source in
            asked = source
            return OpenAICompatibleTranscriber(
                endpoint: Endpoint(id: id, name: "Example", kind: .openAICompatible,
                                   baseURL: URL(string: "https://api.example.com")!, apiKeyRef: nil),
                apiKey: nil, model: "whisper-1", http: http)
        }

        #expect(asked == .endpoint(id: id, model: "whisper-1"))
        #expect(tab.endpointProbe == .succeeded(id: id, model: "whisper-1"))
        // Proving the endpoint works does not switch to it.
        #expect(tab.holder.settings.transcriptionSource == .local(modelID: "large-v3-turbo"))
        #expect(tab.selectableSources.contains { $0.source == .endpoint(id: id, model: "whisper-1") })
    }

    @Test func probingWithNoEndpointConfiguredSaysSoRatherThanReachingForTheActiveSource() async {
        var settings = Settings.default
        settings.endpoints = []
        let tab = tabModel(settings)
        var asked = false

        await tab.probeEndpoint { _ in asked = true; return ScriptedTranscriber(text: "hi") }

        #expect(!asked)
        guard case .failed(let message) = tab.endpointProbe else {
            Issue.record("expected a failed probe, got \(String(describing: tab.endpointProbe))")
            return
        }
        #expect(message.lowercased().contains("endpoint"))
    }

    @Test func aSuccessfulProbeRecordsWhichServerAndModelItProved() async {
        let id = UUID()
        let tab = tabModel(endpointSettings(id: id))
        let http = StubHTTPClient()
        http.stub("POST", path: "/v1/audio/transcriptions", body: Data(#"{"text":"hi"}"#.utf8))
        let transcriber = OpenAICompatibleTranscriber(
            endpoint: Endpoint(id: UUID(), name: "Example", kind: .openAICompatible,
                               baseURL: URL(string: "https://api.example.com")!, apiKeyRef: nil),
            apiKey: nil, model: "whisper-1", http: http)

        await tab.probeEndpoint { _ in transcriber }

        #expect(tab.endpointProbe == .succeeded(id: id, model: "whisper-1"))
        #expect(tab.readiness == .ready)
        #expect(!tab.isProbing)
    }

    @Test func aFailedProbeIsRememberedWithItsReason() async {
        let tab = tabModel(endpointSettings())

        await tab.probeEndpoint { _ in throw MacomprendoError.providerUnreachable(endpointName: "Example") }

        guard case .failed(let message) = tab.endpointProbe else {
            Issue.record("expected a failed probe, got \(String(describing: tab.endpointProbe))")
            return
        }
        #expect(message.contains("Example"))
        #expect(tab.statusHeadline == "Not ready")
    }

    @Test func probingSomethingThatIsNotAnEndpointSaysSoRatherThanClaimingSuccess() async {
        let tab = tabModel(endpointSettings())

        await tab.probeEndpoint { _ in ScriptedTranscriber(text: "hi") }

        guard case .failed(let message) = tab.endpointProbe else {
            Issue.record("expected a failed probe, got \(String(describing: tab.endpointProbe))")
            return
        }
        #expect(message.lowercased().contains("endpoint"))
    }

    // MARK: - What the view renders

    @Test func aModelWithNoPublishedLanguageListIsCalledMultilingualRatherThanBlank() {
        #expect(DictationTabModel.languagesText(nil) == "90+ languages")
        #expect(DictationTabModel.languagesText([]) == "90+ languages")
    }

    @Test func aPublishedLanguageListIsNamedInWords() {
        #expect(DictationTabModel.languagesText(["ru"]) == "Russian")
        #expect(DictationTabModel.languagesText(["ru", "en"]) == "Russian, English")
        // An unknown code is shown as itself rather than dropped.
        #expect(DictationTabModel.languagesText(["zzz"]).contains("zzz"))
    }

    @Test func theSelectedModelIDIsNilOnAnEndpointSource() {
        #expect(tabModel(endpointSettings()).selectedModelID == nil)
        #expect(tabModel().selectedModelID == "large-v3-turbo")
    }

    @Test func theThreadPickerOffersAutomaticPlusEveryCore() {
        #expect(DictationTabModel.threadChoices(processorCount: 4) == [nil, 1, 2, 3, 4])
        // A machine that reports nothing still gets a usable single-thread choice.
        #expect(DictationTabModel.threadChoices(processorCount: 0) == [nil, 1])
    }

    @Test func theAutomaticThreadChoiceNamesWhatItResolvesTo() {
        #expect(DictationTabModel.threadLabel(nil, processorCount: 10) == "Automatic (8)")
        #expect(DictationTabModel.threadLabel(3, processorCount: 10) == "3")
    }

    @Test func benchmarkNumbersAreShownToOneDecimal() {
        #expect(DictationTabModel.benchmarkValue(7.1) == "7.1")
        #expect(DictationTabModel.benchmarkValue(5) == "5.0")
        #expect(DictationTabModel.benchmarkValue(105.4) == "105.4")
    }

    @Test func publishedComparisonsAreListedInAStableOrder() {
        #expect(DictationTabModel.comparisonText([:]) == "")
        #expect(DictationTabModel.comparisonText(["Whisper large-v3": 9.1]) == "Whisper large-v3 9.1")
        // Dictionary order is not stable, so the rendering sorts by name.
        #expect(DictationTabModel.comparisonText(["Whisper large-v3": 9.1, "Another model": 4.0])
                == "Another model 4.0 · Whisper large-v3 9.1")
    }

    // MARK: - Live download progress

    @Test func readinessFollowsTheLiveDownloadRowsRatherThanAStaleSnapshot() async {
        let tab = tabModel()
        let manager = StubModelManager()
        manager.states = ["large-v3-turbo": .notDownloaded]
        let models = ModelsViewModel(models: manager, catalog: ModelCatalog.all)
        await models.refresh()

        tab.adopt(models.rows)
        #expect(tab.readiness == .notReady(reason: "This model has not been downloaded yet.",
                                           fix: .download(modelID: "large-v3-turbo")))

        manager.states["large-v3-turbo"] = .downloaded
        await models.refresh()
        tab.adopt(models.rows)

        #expect(tab.readiness == .ready)
    }
}
