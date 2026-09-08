import Foundation
import Testing
@testable import Macomprendo

@Test func defaultSettingsSeedTheLocalOllamaEndpoint() {
    let s = Settings.default
    #expect(s.schemaVersion == Settings.currentSchemaVersion)
    #expect(s.endpoints == [Endpoint.ollamaLocal()])
    #expect(s.refineLLM == LLMSelection(endpointID: Endpoint.ollamaLocalID, model: "qwen2.5:1.5b"))
    #expect(s.summarizeLLM == LLMSelection(endpointID: Endpoint.ollamaLocalID, model: "qwen2.5:1.5b"))
    #expect(s.transcriptionSource == .local(modelID: "large-v3-turbo"))
    #expect(s.dictationMode == .hold)
    #expect(s.insertMethod == .auto)
    #expect(s.launchAtLogin == false)
    #expect(s.transcriptionLanguage == nil)
    #expect(s.speech == SpeechSettings())
    #expect(s.presets.isEmpty)
    #expect(s.quickPanelFrames.isEmpty)
}

@Test func dictationHistoryDefaultsOff() {
    #expect(Settings.default.dictationHistoryEnabled == false)
}

@Test func legacySettingsDecodeHistoryAsDisabled() throws {
    var object = try #require(JSONSerialization.jsonObject(
        with: JSONEncoder().encode(Settings.default)) as? [String: Any])
    object.removeValue(forKey: "dictationHistoryEnabled")
    let decoded = try Settings.migrate(JSONSerialization.data(withJSONObject: object))
    #expect(decoded.dictationHistoryEnabled == false)
}

@Test func enabledHistoryRoundTrips() throws {
    var settings = Settings.default
    settings.dictationHistoryEnabled = true
    #expect(try Settings.migrate(JSONEncoder().encode(settings)).dictationHistoryEnabled)
}

@Test func appendSpaceAfterDictationDefaultsOffAndRoundTrips() throws {
    #expect(Settings.default.appendSpaceAfterDictation == false)

    var settings = Settings.default
    settings.appendSpaceAfterDictation = true
    #expect(try Settings.migrate(JSONEncoder().encode(settings)).appendSpaceAfterDictation)
}

@Test func legacySettingsDecodeAppendSpaceAfterDictationAsOff() throws {
    var object = try #require(JSONSerialization.jsonObject(
        with: JSONEncoder().encode(Settings.default)) as? [String: Any])
    object.removeValue(forKey: "appendSpaceAfterDictation")

    let decoded = try Settings.migrate(JSONSerialization.data(withJSONObject: object))
    #expect(decoded.appendSpaceAfterDictation == false)
}
@Test func middleMouseActionDefaultsOffAndRoundTrips() throws {
    #expect(Settings.default.middleMouseAction == nil)

    var settings = Settings.default
    settings.middleMouseAction = .summarize
    #expect(try Settings.migrate(JSONEncoder().encode(settings)).middleMouseAction == .summarize)
}
@Test func legacySettingsDecodeMiddleMouseActionAsDisabled() throws {
    var object = try #require(JSONSerialization.jsonObject(
        with: JSONEncoder().encode(Settings.default)) as? [String: Any])
    object.removeValue(forKey: "middleMouseAction")

    let decoded = try Settings.migrate(JSONSerialization.data(withJSONObject: object))
    #expect(decoded.middleMouseAction == nil)
}

@Test func middleMouseActionChoicesNameTheFiveExistingActions() {
    #expect(MiddleMouseAction.allCases.map(\.displayName) == [
        "Dictate", "Dictate & Refine", "Speak selection", "Summarize selection", "Refine selection",
    ])
}
@Test func legacySettingsDecodeMiddleMouseModeAsHold() throws {
    var object = try #require(JSONSerialization.jsonObject(
        with: JSONEncoder().encode(Settings.default)) as? [String: Any])
    object.removeValue(forKey: "middleMouseMode")

    let decoded = try Settings.migrate(JSONSerialization.data(withJSONObject: object))
    #expect(decoded.middleMouseMode == .hold)
}
@Test func middleMouseModeDefaultsToHoldAndRoundTrips() throws {
    #expect(Settings.default.middleMouseMode == .hold)

    var settings = Settings.default
    settings.middleMouseMode = .toggle
    #expect(try Settings.migrate(JSONEncoder().encode(settings)).middleMouseMode == .toggle)
}
@Test func speechSettingsUseTheDocumentedDefaults() {
    let speech = SpeechSettings()
    #expect(speech.voiceID == nil)
    #expect(speech.rate == 0.5)
    #expect(speech.pitch == 1.0)
    #expect(speech.volume == 1.0)
}

@Test func settingsRoundTripThroughJSON() throws {
    var s = Settings.default
    s.dictationMode = .toggle
    s.insertMethod = .typing
    s.launchAtLogin = true
    s.transcriptionSource = .endpoint(id: Endpoint.ollamaLocalID, model: "whisper-1")
    s.transcriptionLanguage = "de"
    s.presets = [
        PromptPreset(kind: .refine, language: "en", name: "Clean up",
                     systemPrompt: "Return only the result.",
                     userTemplate: "Clean up:\n{text}", isFactory: true, sortOrder: 0)
    ]
    s.seededPromptLanguages = ["en"]
    s.defaultPresetIDs[Settings.presetKey(.refine, "en")] = s.presets[0].id
    s.quickPanelFrames = ["screen-1": CGRect(x: 10, y: 20, width: 680, height: 420)]

    let data = try JSONEncoder().encode(s)
    #expect(try Settings.migrate(data) == s)
}

@Test func migrateFillsInKeysMissingFromAnOlderPayload() throws {
    let json = Data(#"{"schemaVersion":1,"dictationMode":"toggle"}"#.utf8)
    let s = try Settings.migrate(json)
    #expect(s.dictationMode == .toggle)
    #expect(s.insertMethod == .auto)
    #expect(s.endpoints == [Endpoint.ollamaLocal()])
    #expect(s.transcriptionSource == .local(modelID: "large-v3-turbo"))
}

@Test func migrateStampsTheCurrentSchemaVersion() throws {
    let json = Data(#"{"dictationMode":"hold"}"#.utf8)
    #expect(try Settings.migrate(json).schemaVersion == Settings.currentSchemaVersion)
}

@Test func migrateRejectsAFutureSchema() {
    let json = Data(#"{"schemaVersion":99}"#.utf8)
    #expect(throws: SettingsMigrationError.unsupportedSchemaVersion(99)) {
        try Settings.migrate(json)
    }
}

@Test func migrateFillsInLLMSelectionsMissingFromAnOlderPayload() throws {
    let json = Data(#"{"schemaVersion":1,"dictationMode":"toggle"}"#.utf8)
    let s = try Settings.migrate(json)
    #expect(s.refineLLM == Settings.default.refineLLM)
    #expect(s.summarizeLLM == Settings.default.summarizeLLM)
}

@Test func migrateThrowsOnGarbage() {
    #expect(throws: (any Error).self) {
        try Settings.migrate(Data("not json".utf8))
    }
}

@Test func speechSettingsDefaultToTheSystemSource() {
    let speech = Settings.default.speech
    #expect(speech.source == .system)
    #expect(speech.endpointBaseURL.absoluteString == "https://api.openai.com")
    #expect(speech.endpointModel == "gpt-4o-mini-tts")
    #expect(speech.endpointVoice == "alloy")
    #expect(speech.endpointInstructions.isEmpty)
    #expect(speech.endpointAPIKeyRef == nil)
}

@Test func aSpeechPayloadWithoutTheEndpointFieldsDecodesToDefaults() throws {
    let legacy = """
        {"schemaVersion":1,
         "speech":{"voiceID":"com.apple.voice.compact.en-US.Samantha",
                   "rate":0.42,"pitch":1.3,"volume":0.7}}
        """
    let settings = try Settings.migrate(Data(legacy.utf8))
    #expect(settings.speech.voiceID == "com.apple.voice.compact.en-US.Samantha")
    #expect(settings.speech.rate == 0.42)
    #expect(settings.speech.source == .system)
    #expect(settings.speech.endpointBaseURL == SpeechSettings.defaultEndpointBaseURL)
    #expect(settings.speech.endpointModel == SpeechSettings.defaultEndpointModel)
    #expect(settings.speech.endpointVoice == SpeechSettings.defaultEndpointVoice)
    #expect(settings.speech.endpointAPIKeyRef == nil)
}

@Test func endpointSpeechFieldsRoundTripThroughJSON() throws {
    var settings = Settings.default
    settings.speech.source = .endpoint
    settings.speech.endpointBaseURL = URL(string: "https://api.proxyapi.ru/openai")!
    settings.speech.endpointModel = "tts-1-hd"
    settings.speech.endpointVoice = "sage"
    settings.speech.endpointInstructions = "Read slowly and warmly"
    settings.speech.endpointAPIKeyRef = SpeechSettings.endpointKeychainAccount

    let encoded = try JSONEncoder().encode(settings)
    let decoded = try Settings.migrate(encoded)

    #expect(decoded.speech == settings.speech)
    // Only the Keychain account name is persisted, never the key (invariant 5).
    #expect(String(decoding: encoded, as: UTF8.self)
            .contains("\"endpointAPIKeyRef\":\"speech.endpoint\""))
}

@Test func theEndpointKeychainAccountIsStable() {
    #expect(SpeechSettings.endpointKeychainAccount == "speech.endpoint")
    #expect(SpeechSource.allCases.map(\.rawValue) == ["system", "local", "endpoint"])
    #expect(SpeechSource.system.displayName == "System voices")
    #expect(SpeechSource.local.displayName == "Local TTS")
    #expect(SpeechSource.endpoint.displayName == "Endpoint")
}

@Test func aDocumentWrittenBeforeLocalTTSDecodesWithDefaults() throws {
    let json = Data("""
    {"schemaVersion":2,"speech":{"source":"endpoint","endpointModel":"gpt-4o-mini-tts"}}
    """.utf8)
    let settings = try Settings.migrate(json)
    #expect(settings.speech.source == .endpoint)
    #expect(settings.speech.endpointModel == "gpt-4o-mini-tts")
    #expect(settings.speech.localModelID == nil)
    #expect(settings.speech.localSpeakerID == 0)
    #expect(settings.speech.localSpeed == 1.0)
}

@Test func theLocalSourceRoundTripsThroughJSON() throws {
    var settings = Settings.default
    settings.speech.source = .local
    settings.speech.localModelID = "vits-piper-ru_RU-ruslan-medium"
    settings.speech.localSpeakerID = 3
    settings.speech.localSpeed = 1.25

    let encoded = try JSONEncoder().encode(settings)
    let decoded = try Settings.migrate(encoded)

    #expect(decoded.speech.source == .local)
    #expect(decoded.speech.localModelID == "vits-piper-ru_RU-ruslan-medium")
    #expect(decoded.speech.localSpeakerID == 3)
    #expect(decoded.speech.localSpeed == 1.25)
    #expect(decoded.schemaVersion == 2)
}

@Test func localMixedLanguageVoiceSettingsUseIndependentDefaults() {
    let speech = SpeechSettings()

    #expect(speech.localVoiceByLanguage.isEmpty)
    #expect(speech.localSegmentationEnabled == false)
    #expect(speech.segmentationEnabled == true)
}

@Test func localMixedLanguageVoiceSelectionsRoundTripModelAndSpeaker() throws {
    var settings = Settings.default
    settings.speech.localSegmentationEnabled = true
    settings.speech.localVoiceByLanguage = [
        "en": LocalVoiceSelection(modelID: "kokoro", speakerID: 11),
        "zh": LocalVoiceSelection(modelID: "kokoro", speakerID: 42),
    ]

    let decoded = try Settings.migrate(JSONEncoder().encode(settings))

    #expect(decoded.speech.localSegmentationEnabled)
    #expect(decoded.speech.localVoiceByLanguage["en"]?.modelID == "kokoro")
    #expect(decoded.speech.localVoiceByLanguage["en"]?.speakerID == 11)
    #expect(decoded.speech.localVoiceByLanguage["zh"]?.speakerID == 42)
}

@Test func speechPayloadWithoutLocalMixedLanguageKeysDecodesIndependentDefaults() throws {
    let legacy = Data("""
        {"schemaVersion":2,
         "speech":{"segmentationEnabled":false,
                   "voiceByLanguage":{"ru":"ru.milena"}}}
        """.utf8)

    let settings = try Settings.migrate(legacy)

    #expect(settings.speech.segmentationEnabled == false)
    #expect(settings.speech.localSegmentationEnabled == false)
    #expect(settings.speech.localVoiceByLanguage.isEmpty)
}

@Test func addingTheLocalSourceDoesNotMoveTheSchemaVersion() {
    #expect(Settings.currentSchemaVersion == 2)
}

@Suite struct SettingsSchemaV2Tests {
    @Test func defaultsCarryTheNewKeys() {
        let d = Settings.default
        #expect(Settings.currentSchemaVersion == 2)
        #expect(d.promptLanguage == PromptLanguage.systemDefault.code)
        #expect(d.seededPromptLanguages.isEmpty)
        #expect(d.defaultPresetIDs.isEmpty)
        #expect(d.speech.voiceByLanguage.isEmpty)
        #expect(d.speech.segmentationEnabled)
        #expect(d.speech.auditionOnSelect)
        #expect(d.speech.previewText.contains("Macomprendo"))
    }

    @Test func previewTextIsMixedScriptSoItDemonstratesSegmentation() {
        let text = SpeechSettings().previewText
        let scripts = Set(LanguageSegmenter.runs(in: text).map(\.script))
        #expect(scripts.contains(.latin))
        #expect(scripts.contains(.cyrillic))
    }

    @Test func aDocumentWithoutTheNewKeysDecodesToDefaults() throws {
        let json = Data(#"{"schemaVersion":1}"#.utf8)
        let settings = try Settings.migrate(json)
        #expect(settings.schemaVersion == 2)
        #expect(settings.promptLanguage == PromptLanguage.systemDefault.code)
        #expect(settings.seededPromptLanguages.isEmpty)
        #expect(settings.speech.segmentationEnabled)
    }

    @Test func aPresetWithoutALanguageDecodesAsEnglish() throws {
        let json = Data("""
            {"id":"F0000000-0000-0000-0000-000000000001","kind":"refine","name":"Clean up",
             "systemPrompt":"s","userTemplate":"{text}","isFactory":true,"sortOrder":0}
            """.utf8)
        let preset = try JSONDecoder().decode(PromptPreset.self, from: json)
        #expect(preset.language == "en")
    }

    @Test func newKeysSurviveARoundTrip() throws {
        var settings = Settings.default
        settings.promptLanguage = "ru"
        settings.seededPromptLanguages = ["en", "ru"]
        settings.defaultPresetIDs = [Settings.presetKey(.refine, "ru"):
            FactoryPresets.presetID(role: .cleanUp, language: .russian)]
        settings.speech.voiceByLanguage = ["ru": "ru.milena", "en": "en.alex"]
        settings.speech.segmentationEnabled = false
        settings.speech.auditionOnSelect = false
        settings.speech.previewText = "hi"
        let data = try JSONEncoder().encode(settings)
        #expect(try Settings.migrate(data) == settings)
    }

    @Test func aDocumentWithoutTheNewSelectionKeysDecodesToEmptyDefaults() throws {
        let json = Data(#"{"schemaVersion":2,"dictationMode":"hold"}"#.utf8)
        let settings = try JSONDecoder().decode(Settings.self, from: json)

        #expect(settings.lastTranscriptionEndpointID == nil)
        #expect(settings.lastTranscriptionEndpointModel == nil)
    }

    @Test func theSelectionKeysSurviveARoundTrip() throws {
        var settings = Settings.default
        let id = UUID()
        settings.lastTranscriptionEndpointID = id
        settings.lastTranscriptionEndpointModel = "whisper-1"

        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))

        #expect(decoded.lastTranscriptionEndpointID == id)
        #expect(decoded.lastTranscriptionEndpointModel == "whisper-1")
    }

    @Test func addingTheSelectionKeysDoesNotMoveTheSchemaVersion() {
        #expect(Settings.currentSchemaVersion == 2)
    }

    @Test func aDocumentWithoutTheWhisperParameterKeysDecodesToAutomaticAndNoTranslation() throws {
        let json = Data(#"{"schemaVersion":2,"dictationMode":"hold"}"#.utf8)
        let settings = try JSONDecoder().decode(Settings.self, from: json)

        #expect(settings.whisperThreads == nil)
        #expect(settings.whisperTranslate == false)
    }

    @Test func theWhisperParameterKeysSurviveARoundTrip() throws {
        var settings = Settings.default
        settings.whisperThreads = 6
        settings.whisperTranslate = true

        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))

        #expect(decoded.whisperThreads == 6)
        #expect(decoded.whisperTranslate)
    }

    @Test func localModelIdleTimeoutDefaultsToTenMinutesForNewAndLegacySettings() throws {
        #expect(Settings.default.localModelIdleTimeout == .tenMinutes)

        let legacy = Data(#"{"schemaVersion":2,"dictationMode":"hold"}"#.utf8)
        #expect(try Settings.migrate(legacy).localModelIdleTimeout == .tenMinutes)
    }

    @Test func everyLocalModelIdleTimeoutSurvivesARoundTrip() throws {
        for timeout in LocalModelIdleTimeout.allCases {
            var settings = Settings.default
            settings.localModelIdleTimeout = timeout

            let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))

            #expect(decoded.localModelIdleTimeout == timeout)
        }
    }

    @Test func localModelIdleTimeoutChoicesHaveStableUserFacingLabels() {
        #expect(LocalModelIdleTimeout.allCases.map(\.displayName) == [
            "Immediately after transcription",
            "After 5 minutes idle",
            "After 10 minutes idle",
            "After 30 minutes idle",
            "Never",
        ])
    }

    @Test func localModelIdleTimeoutOptionsHaveTheExpectedDurations() {
        #expect(LocalModelIdleTimeout.immediately.duration == .zero)
        #expect(LocalModelIdleTimeout.fiveMinutes.duration == .seconds(300))
        #expect(LocalModelIdleTimeout.tenMinutes.duration == .seconds(600))
        #expect(LocalModelIdleTimeout.thirtyMinutes.duration == .seconds(1_800))
        #expect(LocalModelIdleTimeout.never.duration == nil)
    }
}
