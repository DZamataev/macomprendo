import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct SpeechTabModelTests {
    @MainActor
    private final class ModelStatesBox {
        var value: [String: ModelState]

        init(_ value: [String: ModelState]) {
            self.value = value
        }
    }

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

    @Test func systemLayoutPutsPreviewSwitchAndParametersBeforeVoiceChoices() {
        #expect(SpeechTabLayout.sections(for: .system) == [
            .preview, .switchVoices, .parameters, .voices, .languageVoices,
        ])
    }

    @Test func localLayoutPutsPreviewSwitchAndParametersBeforeVoiceChoices() {
        #expect(SpeechTabLayout.sections(for: .local) == [
            .preview, .switchVoices, .parameters, .voices, .languageVoices,
        ])
    }

    @Test func endpointLayoutPutsPreviewBeforeEndpointSettings() {
        #expect(SpeechTabLayout.sections(for: .endpoint) == [.preview, .endpoint])
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

    @Test func localCatalogGroupsModelsByEveryDeclaredLanguageInCatalogOrder() {
        let local = ModelCatalog.all(kind: .tts)
        let groups = SpeechTabModel.localCatalogGroups(local)
        let english = groups.first { $0.language == "en" }!
        let chinese = groups.first { $0.language == "zh" }!

        #expect(Set(groups.map(\.language)) == ["en", "ru", "zh"])
        #expect(english.models.map(\.id) == local.filter { $0.languages?.contains("en") == true }.map(\.id))
        #expect(english.models.contains { $0.id == "kokoro-multi-lang-v1_1" })
        #expect(chinese.models.map(\.id) == ["kokoro-multi-lang-v1_1"])
    }

    @Test func localMappingGroupsContainDownloadedModelsOnly() {
        let local = ModelCatalog.all(kind: .tts)
        let russian = local.first { $0.id == "vits-piper-ru_RU-ruslan-medium" }!
        let kokoro = local.first { $0.id == "kokoro-multi-lang-v1_1" }!
        let tab = model(modelStates: {
            [russian.id: .downloaded, kokoro.id: .downloaded]
        })

        let groups = tab.downloadedLocalGroups(catalog: local)

        #expect(groups.flatMap(\.models).allSatisfy { $0.id == russian.id || $0.id == kokoro.id })
        #expect(groups.first { $0.language == "en" }?.models.map(\.id) == [kokoro.id])
        #expect(groups.first { $0.language == "zh" }?.models.map(\.id) == [kokoro.id])
    }

    @Test func deletingAndRedownloadingAMultilingualModelRefreshesEveryGroupAndMapping() {
        let local = ModelCatalog.all(kind: .tts)
        let kokoro = local.first { $0.id == "kokoro-multi-lang-v1_1" }!
        let states = ModelStatesBox([kokoro.id: .downloaded])
        let holder = ScriptedSettingsHolder()
        holder.settings.speech.localVoiceByLanguage["zh"] = LocalVoiceSelection(
            modelID: kokoro.id,
            speakerID: 42)
        let tab = model(holder: holder, modelStates: { states.value })

        #expect(tab.downloadedLocalGroups(catalog: local)
            .flatMap(\.models).count(where: { $0.id == kokoro.id }) == 2)
        #expect(tab.localVoice(forLanguage: "zh", catalog: local)?.speakerID == 42)

        states.value[kokoro.id] = .notDownloaded
        #expect(tab.downloadedLocalGroups(catalog: local)
            .flatMap(\.models).allSatisfy { $0.id != kokoro.id })
        #expect(tab.localVoice(forLanguage: "zh", catalog: local) == nil)

        states.value[kokoro.id] = .downloaded
        #expect(tab.downloadedLocalGroups(catalog: local)
            .flatMap(\.models).count(where: { $0.id == kokoro.id }) == 2)
        #expect(tab.localVoice(forLanguage: "zh", catalog: local)?.speakerID == 42)
    }

    @Test func staleLocalMappingIsPresentedAsAuto() {
        let local = ModelCatalog.all(kind: .tts)
        let kokoro = local.first { $0.id == "kokoro-multi-lang-v1_1" }!
        let holder = ScriptedSettingsHolder()
        holder.settings.speech.localVoiceByLanguage["en"] = LocalVoiceSelection(
            modelID: kokoro.id, speakerID: 7)
        let tab = model(holder: holder, modelStates: { [kokoro.id: .notDownloaded] })

        #expect(tab.localVoice(forLanguage: "en", catalog: local) == nil)
    }

    @Test func localVoiceMutationsPersistAndClampModelPlusSpeaker() {
        let local = ModelCatalog.all(kind: .tts)
        let kokoro = local.first { $0.id == "kokoro-multi-lang-v1_1" }!
        let holder = ScriptedSettingsHolder()
        holder.settings.speech.auditionOnSelect = false
        let tab = model(holder: holder, modelStates: { [kokoro.id: .downloaded] })

        tab.setLocalVoice(kokoro.id, forLanguage: "en", catalog: local)
        tab.setLocalSpeaker(Int.max, forLanguage: "en", catalog: local)

        #expect(holder.settings.speech.localVoiceByLanguage["en"]
                == LocalVoiceSelection(modelID: kokoro.id, speakerID: kokoro.speakerCount - 1))
        tab.setLocalVoice(nil, forLanguage: "en", catalog: local)
        #expect(holder.settings.speech.localVoiceByLanguage["en"] == nil)
    }

    @Test func oneMultilingualModelKeepsIndependentSpeakersPerLanguage() {
        let local = ModelCatalog.all(kind: .tts)
        let kokoro = local.first { $0.id == "kokoro-multi-lang-v1_1" }!
        let holder = ScriptedSettingsHolder()
        holder.settings.speech.auditionOnSelect = false
        let tab = model(holder: holder, modelStates: { [kokoro.id: .downloaded] })

        tab.setLocalVoice(kokoro.id, forLanguage: "en", catalog: local)
        tab.setLocalSpeaker(7, forLanguage: "en", catalog: local)
        tab.setLocalVoice(kokoro.id, forLanguage: "zh", catalog: local)
        tab.setLocalSpeaker(42, forLanguage: "zh", catalog: local)

        #expect(tab.localVoice(forLanguage: "en", catalog: local)?.speakerID == 7)
        #expect(tab.localVoice(forLanguage: "zh", catalog: local)?.speakerID == 42)
    }

    @Test func selectingALocalMappingAuditionsTemporaryLocalSettings() {
        let local = ModelCatalog.all(kind: .tts)
        let russian = local.first { $0.id == "vits-piper-ru_RU-ruslan-medium" }!
        let kokoro = local.first { $0.id == "kokoro-multi-lang-v1_1" }!
        let speech = ScriptedSpeech()
        let holder = ScriptedSettingsHolder()
        holder.settings.speech.source = .endpoint
        holder.settings.speech.localModelID = russian.id
        holder.settings.speech.localSpeakerID = 0
        let tab = model(
            speech: speech,
            holder: holder,
            modelStates: { [russian.id: .downloaded, kokoro.id: .downloaded] })

        tab.setLocalVoice(kokoro.id, forLanguage: "zh", catalog: local)
        tab.setLocalSpeaker(42, forLanguage: "zh", catalog: local)

        let spoken = speech.spoken.last
        #expect(spoken?.text == SpeechTabModel.auditionPhrases["zh"])
        #expect(spoken?.settings.source == .local)
        #expect(spoken?.settings.localModelID == kokoro.id)
        #expect(spoken?.settings.localSpeakerID == 42)
        #expect(spoken?.settings.localSegmentationEnabled == false)
        #expect(holder.settings.speech.source == .endpoint)
        #expect(holder.settings.speech.localModelID == russian.id)
        #expect(holder.settings.speech.localSpeakerID == 0)
    }

    @Test func selectingTheDefaultLocalVoiceAuditionsWithoutActivatingLocal() {
        let local = ModelCatalog.all(kind: .tts)
        let kokoro = local.first { $0.id == "kokoro-multi-lang-v1_1" }!
        let speech = ScriptedSpeech()
        let holder = ScriptedSettingsHolder()
        holder.settings.speech.source = .system
        let tab = model(
            speech: speech,
            holder: holder,
            modelStates: { [kokoro.id: .downloaded] })

        tab.setDefaultLocalVoice(kokoro.id, auditionLanguage: "zh", catalog: local)

        #expect(holder.settings.speech.localModelID == kokoro.id)
        #expect(holder.settings.speech.source == .system)
        #expect(speech.spoken.last?.text == SpeechTabModel.auditionPhrases["zh"])
        #expect(speech.spoken.last?.settings.source == .local)
        #expect(speech.spoken.last?.settings.localModelID == kokoro.id)
        #expect(speech.spoken.last?.settings.localSegmentationEnabled == false)
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
