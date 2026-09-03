import Foundation
import Testing
@testable import Macomprendo

@Suite @MainActor struct SpeechSourceModelTests {

    private func model(_ settings: Settings = .default,
                       catalog: [LocalModel] = []) -> SpeechSourceModel {
        SpeechSourceModel(holder: ScriptedSettingsHolder(settings), catalog: catalog)
    }

    // MARK: - Navigation is not selection

    @Test func theTabShownOnOpenIsTheActiveSource() {
        var settings = Settings.default
        settings.speech.source = .endpoint
        #expect(model(settings).viewedTab == .endpoint)

        settings.speech.source = .local
        #expect(model(settings).viewedTab == .local)
    }

    @Test func movingBetweenTabsChangesNothingButWhatIsOnScreen() {
        var settings = Settings.default
        settings.speech.source = .system
        let tab = model(settings)
        let before = tab.holder.settings

        tab.viewedTab = .local
        tab.viewedTab = .endpoint
        tab.viewedTab = .system

        #expect(tab.holder.settings == before)
        #expect(tab.holder.settings.speech.source == .system)
    }

    @Test func onlyTheSelectorChangesWhatSpeaks() {
        let tab = model()
        tab.viewedTab = .endpoint
        #expect(tab.activeSource == .system)

        tab.activate(.endpoint)
        #expect(tab.activeSource == .endpoint)
        #expect(tab.holder.settings.speech.source == .endpoint)
    }

    @Test func revealingASourceIsNavigationOnly() {
        let tab = model()
        tab.reveal(.local)
        #expect(tab.viewedTab == .local)
        #expect(tab.activeSource == .system)
    }

    // MARK: - Choosing a local voice

    @Test func choosingALocalModelRecordsItWithoutActivatingTheSource() {
        // Same separation as the endpoint sub-tab in Dictation: configuring is not activating.
        let tab = model(.default, catalog: [Self.piper])
        tab.select(modelID: "piper-ru")
        #expect(tab.holder.settings.speech.localModelID == "piper-ru")
        #expect(tab.activeSource == .system)
    }

    @Test func anUnknownModelIDIsIgnored() {
        let tab = model(.default, catalog: [Self.piper])
        tab.select(modelID: "not-in-the-catalog")
        #expect(tab.holder.settings.speech.localModelID == nil)
    }

    @Test func theCatalogListsTTSEntriesOnly() {
        let tab = SpeechSourceModel(holder: ScriptedSettingsHolder())
        // Vacuous until Plan 2 lands the TTS entries; it exists to fail then.
        #expect(tab.ttsModels.allSatisfy { $0.kind == .tts })
    }

    // MARK: - Status

    @Test func theStatusDescribesTheSelectedSourceNotTheViewedTab() {
        var settings = Settings.default
        settings.speech.source = .system
        let tab = model(settings, catalog: [Self.piper])

        tab.viewedTab = .local          // looking at a source that is not ready
        #expect(tab.readiness == .ready)
        #expect(tab.statusHeadline == "Ready to use")
        #expect(tab.statusDetail.contains("System voices"))
    }

    @Test func aNotReadySourceExplainsItselfInTheStatus() {
        var settings = Settings.default
        settings.speech.source = .local
        settings.speech.localModelID = "piper-ru"
        let tab = model(settings, catalog: [Self.piper])
        tab.modelStates = ["piper-ru": .notDownloaded]

        #expect(tab.statusHeadline == "Not ready")
        #expect(tab.statusDetail.contains("has not been downloaded"))
        #expect(tab.statusDetail.contains("Local TTS"))
    }

    @Test func adoptingRowsTracksADownloadInProgress() {
        var settings = Settings.default
        settings.speech.source = .local
        settings.speech.localModelID = "piper-ru"
        let tab = model(settings, catalog: [Self.piper])

        tab.adopt([ModelsViewModel.Row(model: Self.piper, state: .downloading(fraction: 0.5))])

        #expect(tab.readiness == .notReady(reason: "Downloading… 50%", fix: nil))
    }

    // MARK: - Fixtures

    private static let piper = LocalModel(
        id: "piper-ru",
        displayName: "Piper — Ruslan (Russian)",
        engine: .whisperCpp,      // replaced by .sherpaVits in Plan 2; kind is what matters here
        languages: ["ru"],
        files: [],
        brief: ModelBrief(summary: "", strengths: [], limitations: [], benchmarks: [],
                          sourceURL: URL(string: "https://example.com")!),
        speakerCount: 1,
        archiveSentinel: nil)
}
