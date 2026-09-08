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
                       keychain: InMemoryKeychainStore = InMemoryKeychainStore(),
                       toaster: ScriptedToaster = ScriptedToaster(),
                       modelStates: @escaping @MainActor () -> [String: ModelState] = { [:] })
        -> SpeechTabModel {
        SpeechTabModel(speech: speech, holder: holder, keychain: keychain,
                       toaster: toaster, modelStates: modelStates)
    }

    private let catalog = [
        Voice(id: "en.alex", name: "Alex", language: "en-US", quality: "default"),
        Voice(id: "en.daniel", name: "Daniel", language: "en-GB", quality: "enhanced"),
        Voice(id: "ru.milena", name: "Milena", language: "ru-RU", quality: "default"),
        Voice(id: "uk.lesya", name: "Lesya", language: "uk-UA", quality: "premium")
    ]

    private func make(voices: [Voice])
        -> (SpeechTabModel, ScriptedSpeech, ScriptedSettingsHolder) {
        let speech = ScriptedSpeech()
        speech.available = voices
        speech.availableBySource[.system] = voices
        let holder = ScriptedSettingsHolder()
        return (SpeechTabModel(speech: speech, holder: holder, keychain: InMemoryKeychainStore(),
                               toaster: ScriptedToaster(), modelStates: { [:] }),
                speech, holder)
    }

    // MARK: existing behaviour

    @Test func voicesAreGroupedByLanguageAndSortedByName() {
        let groups = SpeechTabModel.group(voices)
        #expect(groups.map(\.language) == ["en", "fr"])
        #expect(groups[0].voices.map(\.name) == ["Alex", "Ava"])
        #expect(groups[0].displayName.contains("English"))
        #expect(groups[1].voices.map(\.name) == ["Amélie"])
    }

    @Test func regionalVariantsShareOneLanguageGroup() {
        let groups = SpeechTabModel.group(catalog)
        #expect(groups.map(\.language).sorted() == ["en", "ru", "uk"])
        let english = groups.first { $0.language == "en" }!
        #expect(english.voices.map(\.id) == ["en.alex", "en.daniel"])
    }

    @Test func baseCodeStripsRegionAndScript() {
        #expect(SpeechTabModel.baseCode("ru-RU") == "ru")
        #expect(SpeechTabModel.baseCode("zh-Hans-CN") == "zh")
        #expect(SpeechTabModel.baseCode("EN") == "en")
    }

    @Test func mappingAVoiceToALanguagePersistsAndClearingRemovesTheKey() {
        let (model, _, holder) = make(voices: catalog)
        model.setVoice("ru.milena", forLanguage: "ru")
        #expect(holder.settings.speech.voiceByLanguage == ["ru": "ru.milena"])
        model.setVoice(nil, forLanguage: "ru")
        #expect(holder.settings.speech.voiceByLanguage.isEmpty)
    }

    @Test func selectingAVoiceAuditionsItWithSegmentationOff() {
        let (model, speech, holder) = make(voices: catalog)
        holder.settings.speech.auditionOnSelect = true
        holder.settings.speech.source = .endpoint
        model.setVoice("ru.milena", forLanguage: "ru")
        #expect(speech.spoken.count == 1)
        let spoken = speech.spoken[0]
        #expect(spoken.text == "Вот так звучит мой голос.")
        #expect(spoken.settings.voiceID == "ru.milena")
        #expect(spoken.settings.source == .system)
        #expect(spoken.settings.segmentationEnabled == false)
    }

    @Test func auditionIsSilentWhenTheToggleIsOff() {
        let (model, speech, holder) = make(voices: catalog)
        holder.settings.speech.auditionOnSelect = false
        model.setDefaultVoice("en.alex")
        #expect(holder.settings.speech.voiceID == "en.alex")
        #expect(speech.spoken.isEmpty)
    }

    /// Nothing in the type system ties the phrase table to `PromptLanguage`, so an eighth
    /// language would otherwise ship auditioning in the voice's own name with no one noticing.
    @Test func everyPromptLanguageHasAnAuditionPhrase() {
        #expect(Set(SpeechTabModel.auditionPhrases.keys)
                == Set(PromptLanguage.allCases.map(\.code)))
    }

    @Test func anUnknownLanguageIsAuditionedWithTheVoicesOwnName() {
        let (model, _, _) = make(voices: catalog)
        #expect(model.auditionPhrase(for: "uk.lesya") == "Lesya")
        #expect(model.auditionPhrase(for: "en.alex") == "This is how I sound.")
    }

    @Test func previewSpeaksTheEditablePreviewText() {
        let (model, speech, holder) = make(voices: catalog)
        holder.settings.speech.previewText = "проверка check"
        model.preview()
        #expect(speech.spoken.map(\.text) == ["проверка check"])
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
        #expect(speech.spoken[0].text == SpeechSettings.defaultPreviewText)
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

    // MARK: readiness gate

    /// The header selector allows activating a Local source before a model is downloaded.
    /// Preview must not silently fall back to System in that case (contradicting both the
    /// no-fallback decision and the UI text saying Preview speaks through the active source).
    @Test func previewThroughAnUnreadyLocalSourceToastsAndSpeaksNothing() {
        let speech = ScriptedSpeech()
        let holder = ScriptedSettingsHolder()
        holder.settings.speech.source = .local
        holder.settings.speech.localModelID = "piper-ru"
        let toaster = ScriptedToaster()
        let tab = model(speech: speech, holder: holder, toaster: toaster,
                        modelStates: { ["piper-ru": .notDownloaded] })

        tab.preview()

        #expect(speech.spoken.isEmpty)
        #expect(toaster.messages == ["This voice has not been downloaded yet."])
    }

    @Test func previewThroughAReadyLocalSourceUsesTheSpeechRouterBoundary() {
        let speech = ScriptedSpeech()
        let holder = ScriptedSettingsHolder()
        holder.settings.speech.source = .local
        holder.settings.speech.localModelID = "piper-ru"
        let toaster = ScriptedToaster()
        let tab = model(speech: speech, holder: holder, toaster: toaster,
                        modelStates: { ["piper-ru": .downloaded] })

        tab.preview()

        #expect(speech.spoken.map(\.text) == [SpeechSettings.defaultPreviewText])
        #expect(toaster.messages.isEmpty)
    }

    @Test func previewThroughAReadySystemSourceStillSpeaksCurrentSettings() {
        let speech = ScriptedSpeech()
        let holder = ScriptedSettingsHolder()
        holder.settings.speech = SpeechSettings(voiceID: "v.en1", rate: 0.7, pitch: 1.2, volume: 0.8)
        let toaster = ScriptedToaster()
        let tab = model(speech: speech, holder: holder, toaster: toaster)

        tab.preview()

        #expect(speech.spoken.count == 1)
        #expect(speech.spoken[0].text == SpeechSettings.defaultPreviewText)
        #expect(speech.spoken[0].settings.voiceID == "v.en1")
        #expect(speech.spoken[0].settings.rate == 0.7)
        #expect(toaster.messages.isEmpty)
    }

    @Test func previewThroughAMisconfiguredEndpointToastsAndSpeaksNothing() {
        let speech = ScriptedSpeech()
        let holder = ScriptedSettingsHolder()
        holder.settings.speech.source = .endpoint
        holder.settings.speech.endpointModel = ""     // required field left blank
        let toaster = ScriptedToaster()
        let tab = model(speech: speech, holder: holder, toaster: toaster)

        tab.preview()

        #expect(speech.spoken.isEmpty)
        #expect(toaster.messages == ["The server, model and voice must all be filled in."])
    }

    @Test func previewThroughAConfiguredEndpointStillSpeaks() {
        let speech = ScriptedSpeech()
        let holder = ScriptedSettingsHolder()
        holder.settings.speech.source = .endpoint
        holder.settings.speech.endpointAPIKeyRef = SpeechSettings.endpointKeychainAccount
        let toaster = ScriptedToaster()
        let tab = model(speech: speech, holder: holder, toaster: toaster)

        tab.preview()

        #expect(speech.spoken.map(\.text) == [SpeechSettings.defaultPreviewText])
        #expect(toaster.messages.isEmpty)
    }
}
