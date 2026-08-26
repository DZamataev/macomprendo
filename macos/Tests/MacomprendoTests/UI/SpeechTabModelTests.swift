import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct SpeechTabModelTests {
    private let voices = [
        Voice(id: "v.fr", name: "Amélie", language: "fr-FR", quality: "premium"),
        Voice(id: "v.en2", name: "Alex", language: "en-US", quality: "default"),
        Voice(id: "v.en1", name: "Ava", language: "en-US", quality: "enhanced"),
    ]

    private let endpointCatalog = [
        Voice(id: "alloy", name: "alloy", language: "endpoint", quality: "premium"),
        Voice(id: "sage", name: "sage", language: "endpoint", quality: "premium"),
    ]

    private func model(speech: ScriptedSpeech = ScriptedSpeech(),
                       holder: ScriptedSettingsHolder = ScriptedSettingsHolder(),
                       keychain: InMemoryKeychainStore = InMemoryKeychainStore())
        -> SpeechTabModel {
        SpeechTabModel(speech: speech, holder: holder, keychain: keychain)
    }

    // MARK: existing behaviour

    @Test func voicesAreGroupedByLanguageAndSortedByName() {
        let groups = SpeechTabModel.group(voices)
        #expect(groups.map(\.language) == ["en-US", "fr-FR"])
        #expect(groups[0].voices.map(\.name) == ["Alex", "Ava"])
        #expect(groups[0].displayName.contains("English"))
        #expect(groups[1].voices.map(\.name) == ["Amélie"])
    }

    @Test func groupingAnEmptyListYieldsNoGroups() {
        #expect(SpeechTabModel.group([]).isEmpty)
    }

    @Test func reloadPublishesTheServiceVoices() {
        let speech = ScriptedSpeech()
        speech.availableBySource = [.system: voices, .endpoint: endpointCatalog]
        let tab = model(speech: speech)
        #expect(tab.groups.count == 2)

        speech.availableBySource[.system] = [voices[0]]
        tab.reload()
        #expect(tab.groups.count == 1)
    }

    @Test func previewSpeaksTheSampleWithTheCurrentSettings() {
        let speech = ScriptedSpeech()
        let holder = ScriptedSettingsHolder()
        holder.settings.speech = SpeechSettings(voiceID: "v.en1", rate: 0.7, pitch: 1.2, volume: 0.8)
        let tab = model(speech: speech, holder: holder)

        tab.preview()

        #expect(speech.spoken.count == 1)
        #expect(speech.spoken[0].text == SpeechTabModel.sampleText)
        #expect(speech.spoken[0].settings.voiceID == "v.en1")
        #expect(speech.spoken[0].settings.rate == 0.7)
    }

    // MARK: the endpoint source

    @Test func theSourceBindingWritesThroughToSettings() {
        let holder = ScriptedSettingsHolder()
        let tab = model(holder: holder)
        #expect(tab.source == .system)

        tab.source = .endpoint

        #expect(holder.settings.speech.source == .endpoint)
        #expect(tab.source == .endpoint)
    }

    @Test func endpointVoicesComeFromTheEndpointSource() {
        let speech = ScriptedSpeech()
        speech.availableBySource = [.system: voices, .endpoint: endpointCatalog]
        let tab = model(speech: speech)
        #expect(tab.endpointVoices.map(\.id) == ["alloy", "sage"])
        #expect(tab.groups.flatMap { $0.voices.map(\.id) }.sorted() == ["v.en1", "v.en2", "v.fr"])
    }

    @Test func savingAnAPIKeyStoresItInTheKeychainAndRecordsTheReference() throws {
        let holder = ScriptedSettingsHolder()
        let keychain = InMemoryKeychainStore()
        let tab = model(holder: holder, keychain: keychain)

        tab.apiKeyField = "  sk-SECRET  "
        tab.saveAPIKey()

        #expect(try keychain.get(account: SpeechSettings.endpointKeychainAccount) == "sk-SECRET")
        #expect(holder.settings.speech.endpointAPIKeyRef == SpeechSettings.endpointKeychainAccount)
        #expect(tab.hasAPIKey())
    }

    @Test func savingAnEmptyKeyDeletesItAndClearsTheReference() throws {
        let holder = ScriptedSettingsHolder()
        let keychain = InMemoryKeychainStore()
        try keychain.set("sk-OLD", account: SpeechSettings.endpointKeychainAccount)
        holder.settings.speech.endpointAPIKeyRef = SpeechSettings.endpointKeychainAccount
        let tab = model(holder: holder, keychain: keychain)

        tab.apiKeyField = "   "
        tab.saveAPIKey()

        #expect(try keychain.get(account: SpeechSettings.endpointKeychainAccount) == nil)
        #expect(holder.settings.speech.endpointAPIKeyRef == nil)
        #expect(!tab.hasAPIKey())
    }

    @Test func theAPIKeyFieldIsClearedAfterSaving() {
        let tab = model()
        tab.apiKeyField = "sk-SECRET"
        tab.saveAPIKey()

        #expect(tab.apiKeyField.isEmpty)
        #expect(!tab.keyStatus.isEmpty)
        #expect(!tab.keyStatus.contains("sk-"))
    }

    @Test func thePrivacyCaptionNamesTheConfiguredServer() {
        #expect(SpeechTabModel.endpointPrivacyCaption
                == "Selected text is sent to the configured server when this source is active.")
    }
}
