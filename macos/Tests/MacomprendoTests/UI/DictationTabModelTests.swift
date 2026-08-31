import Foundation
import Testing
@testable import Macomprendo

@Suite @MainActor struct DictationTabModelTests {

    private func tabModel(_ settings: Settings = .default) -> DictationTabModel {
        DictationTabModel(holder: ScriptedSettingsHolder(settings), catalog: ModelCatalog.all)
    }

    @Test func theActiveTabFollowsTheConfiguredSource() {
        var settings = Settings.default
        settings.transcriptionSource = .local(modelID: "gigaam-v3-e2e-ctc")
        #expect(tabModel(settings).activeTab == .gigaAM)

        settings.transcriptionSource = .local(modelID: "base")
        #expect(tabModel(settings).activeTab == .whisperCpp)

        settings.transcriptionSource = .endpoint(id: UUID(), model: "whisper-1")
        #expect(tabModel(settings).activeTab == .endpoint)
    }

    @Test func selectingATabMakesItsRememberedModelTheConfiguredSource() {
        var settings = Settings.default
        settings.transcriptionSource = .local(modelID: "base")
        settings.lastModelByEngine = ["gigaAM": "gigaam-v3-e2e-rnnt"]
        let tab = tabModel(settings)

        tab.select(tab: .gigaAM)

        #expect(tab.holder.settings.transcriptionSource == .local(modelID: "gigaam-v3-e2e-rnnt"))
    }

    @Test func selectingATabWithNoRememberedModelFallsBackToItsFirstEntry() {
        var settings = Settings.default
        settings.transcriptionSource = .local(modelID: "base")
        let tab = tabModel(settings)

        tab.select(tab: .gigaAM)

        #expect(tab.holder.settings.transcriptionSource == .local(modelID: "gigaam-v3-e2e-ctc"))
    }

    @Test func selectingAModelRecordsItAsThatEnginesRememberedChoice() {
        let tab = tabModel()

        tab.select(modelID: "gigaam-multilingual-large-ctc")

        #expect(tab.holder.settings.transcriptionSource == .local(modelID: "gigaam-multilingual-large-ctc"))
        #expect(tab.holder.settings.lastModelByEngine["gigaAM"] == "gigaam-multilingual-large-ctc")
    }

    @Test func returningToATabRestoresWhatWasChosenThereRatherThanTheDefault() {
        let tab = tabModel()
        tab.select(tab: .gigaAM)
        tab.select(modelID: "gigaam-multilingual-ctc")
        tab.select(tab: .whisperCpp)

        tab.select(tab: .gigaAM)

        #expect(tab.holder.settings.transcriptionSource == .local(modelID: "gigaam-multilingual-ctc"))
    }

    @Test func selectingTheAlreadyActiveTabChangesNothing() {
        var settings = Settings.default
        settings.transcriptionSource = .local(modelID: "small")
        let tab = tabModel(settings)

        tab.select(tab: .whisperCpp)

        #expect(tab.holder.settings.transcriptionSource == .local(modelID: "small"))
    }

    @Test func eachTabListsOnlyItsOwnEnginesModels() {
        let tab = tabModel()
        #expect(tab.rows(for: .gigaAM).allSatisfy { $0.engine == .gigaAM })
        #expect(tab.rows(for: .gigaAM).count == 4)
        #expect(tab.rows(for: .whisperCpp).count == 9)
        #expect(tab.rows(for: .endpoint).isEmpty)
    }

    @Test func aReadyTabSaysThisIsTheActiveDictationModel() {
        let tab = tabModel()
        tab.select(tab: .gigaAM)
        tab.select(modelID: "gigaam-v3-e2e-ctc")
        tab.modelStates["gigaam-v3-e2e-ctc"] = .downloaded

        #expect(tab.readiness == .ready)
        #expect(tab.statusHeadline == "Ready to use")
        #expect(tab.statusDetail.contains("GigaAM v3 e2e CTC (Russian)"))
        #expect(tab.statusDetail.lowercased().contains("dictation"))
    }

    @Test func anUnreadyTabExplainsWhatIsWrongAndThatDictationWillFail() {
        let tab = tabModel()
        tab.select(tab: .gigaAM)
        tab.select(modelID: "gigaam-v3-e2e-ctc")
        tab.modelStates["gigaam-v3-e2e-ctc"] = .notDownloaded

        #expect(tab.statusHeadline == "Not ready")
        #expect(tab.statusDetail.contains("has not been downloaded"))
        #expect(tab.statusDetail.lowercased().contains("will fail"))
    }

    @Test func anEndpointSourceIsNamedByItsModel() {
        var settings = Settings.default
        settings.transcriptionSource = .endpoint(id: UUID(), model: "whisper-1")
        #expect(tabModel(settings).activeSourceName == "OpenAI endpoint · whisper-1")
    }

    @Test func gigaAMReportsThatItHasNoParametersToConfigure() {
        #expect(DictationBackendTab.gigaAM.parameterSummary.lowercased().contains("no settings"))
        #expect(DictationBackendTab.whisperCpp.parameterSummary.isEmpty)
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

    @Test func onlyTheActiveTabCanShowAsReady() {
        let tab = tabModel()
        tab.select(tab: .gigaAM)
        tab.select(modelID: "gigaam-v3-e2e-ctc")
        tab.modelStates["gigaam-v3-e2e-ctc"] = .downloaded

        #expect(tab.indicator(for: .gigaAM) == .ready)
        // whisper models may well be on disk, but they are not what dictation will run, so
        // their tab is neither ready nor broken.
        tab.modelStates["base"] = .downloaded
        #expect(tab.indicator(for: .whisperCpp) == .inactive)
        #expect(tab.indicator(for: .endpoint) == .inactive)
    }

    @Test func theSubTabTitleCarriesItsOwnReadinessMarker() {
        // In the title string, not beside it: a segmented control always renders its own
        // title, whereas an icon next to it may be dropped by the style.
        let tab = tabModel()
        tab.select(tab: .gigaAM)
        tab.select(modelID: "gigaam-v3-e2e-ctc")
        tab.modelStates["gigaam-v3-e2e-ctc"] = .downloaded
        #expect(tab.tabTitle(for: .gigaAM) == "GigaAM ✅")

        tab.modelStates["gigaam-v3-e2e-ctc"] = .notDownloaded
        #expect(tab.tabTitle(for: .gigaAM) == "GigaAM ❌")

        // An unconfigured backend is neither ready nor broken, so it carries no marker at all.
        #expect(tab.tabTitle(for: .whisperCpp) == "whisper.cpp")
        #expect(tab.tabTitle(for: .endpoint) == "OpenAI endpoint")
    }

    @Test func theActiveTabSaysSoEvenWhenItCannotRun() {
        let tab = tabModel()
        tab.select(tab: .gigaAM)
        tab.modelStates["gigaam-v3-e2e-ctc"] = .notDownloaded

        #expect(tab.indicator(for: .gigaAM) == .notReady)
    }

    @Test func theSelectedModelIDIsNilOnTheEndpointTab() {
        var settings = Settings.default
        settings.transcriptionSource = .endpoint(id: UUID(), model: "whisper-1")
        #expect(tabModel(settings).selectedModelID == nil)
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

    // MARK: - The endpoint tab

    @Test func choosingAnEndpointRemembersItForNextTime() {
        var settings = Settings.default
        let first = UUID(), second = UUID()
        settings.transcriptionSource = .endpoint(id: first, model: "whisper-1")
        let tab = tabModel(settings)

        tab.select(endpointID: second)

        #expect(tab.holder.settings.transcriptionSource == .endpoint(id: second, model: "whisper-1"))
        #expect(tab.holder.settings.lastTranscriptionEndpointID == second)
    }

    @Test func namingAnEndpointModelRemembersItForNextTime() {
        var settings = Settings.default
        let id = UUID()
        settings.transcriptionSource = .endpoint(id: id, model: "whisper-1")
        let tab = tabModel(settings)

        tab.select(endpointModel: "gpt-4o-transcribe")

        #expect(tab.holder.settings.transcriptionSource == .endpoint(id: id, model: "gpt-4o-transcribe"))
        #expect(tab.holder.settings.lastTranscriptionEndpointModel == "gpt-4o-transcribe")
    }

    @Test func returningToTheEndpointTabRestoresTheEndpointAndModelLastUsed() {
        var settings = Settings.default
        let chosen = UUID()
        settings.transcriptionSource = .endpoint(id: UUID(), model: "whisper-1")
        let tab = tabModel(settings)
        tab.select(endpointID: chosen)
        tab.select(endpointModel: "gpt-4o-transcribe")

        tab.select(tab: .whisperCpp)
        tab.select(tab: .endpoint)

        #expect(tab.holder.settings.transcriptionSource == .endpoint(id: chosen, model: "gpt-4o-transcribe"))
    }

    @Test func changingTheEndpointDropsAProbeThatProvedADifferentServer() {
        var settings = Settings.default
        settings.transcriptionSource = .endpoint(id: UUID(), model: "whisper-1")
        let tab = tabModel(settings)
        tab.endpointProbe = .succeeded

        tab.select(endpointID: UUID())

        #expect(tab.endpointProbe == nil)
        #expect(tab.statusHeadline == "Not ready")
    }

    @Test func changingTheEndpointModelDropsAProbeThatProvedADifferentModel() {
        var settings = Settings.default
        settings.transcriptionSource = .endpoint(id: UUID(), model: "whisper-1")
        let tab = tabModel(settings)
        tab.endpointProbe = .succeeded

        tab.select(endpointModel: "gpt-4o-transcribe")

        #expect(tab.endpointProbe == nil)
    }

    // MARK: - The endpoint probe

    @Test func theTestButtonSaysWhetherThisEndpointHasEverAnswered() {
        let tab = tabModel()
        #expect(tab.probeCaption.contains("test clip"))

        tab.endpointProbe = .succeeded
        #expect(tab.probeCaption == "This endpoint transcribed a one-second test clip.")

        tab.endpointProbe = .failed("Could not reach the server.")
        // The reason is shown once, in the status block, not twice.
        #expect(!tab.probeCaption.contains("Could not reach the server."))
        #expect(tab.probeCaption.lowercased().contains("failed"))
    }

    @Test func aSuccessfulProbeMarksTheEndpointReady() async {
        var settings = Settings.default
        settings.transcriptionSource = .endpoint(id: UUID(), model: "whisper-1")
        let tab = tabModel(settings)
        let http = StubHTTPClient()
        http.stub("POST", path: "/v1/audio/transcriptions", body: Data(#"{"text":"hi"}"#.utf8))
        let transcriber = OpenAICompatibleTranscriber(
            endpoint: Endpoint(id: UUID(), name: "Example", kind: .openAICompatible,
                               baseURL: URL(string: "https://api.example.com")!, apiKeyRef: nil),
            apiKey: nil, model: "whisper-1", http: http)

        await tab.probeEndpoint { transcriber }

        #expect(tab.endpointProbe == .succeeded)
        #expect(tab.readiness == .ready)
        #expect(!tab.isProbing)
    }

    @Test func aFailedProbeIsRememberedWithItsReason() async {
        var settings = Settings.default
        settings.transcriptionSource = .endpoint(id: UUID(), model: "whisper-1")
        let tab = tabModel(settings)

        await tab.probeEndpoint { throw MacomprendoError.providerUnreachable(endpointName: "Example") }

        guard case .failed(let message) = tab.endpointProbe else {
            Issue.record("expected a failed probe, got \(String(describing: tab.endpointProbe))")
            return
        }
        #expect(message.contains("Example"))
        #expect(tab.statusHeadline == "Not ready")
    }

    @Test func probingSomethingThatIsNotAnEndpointSaysSoRatherThanClaimingSuccess() async {
        let tab = tabModel()

        await tab.probeEndpoint { ScriptedTranscriber(text: "hi") }

        guard case .failed(let message) = tab.endpointProbe else {
            Issue.record("expected a failed probe, got \(String(describing: tab.endpointProbe))")
            return
        }
        #expect(message.lowercased().contains("endpoint"))
    }
}
