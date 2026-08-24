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
    #expect(s.presetsSeeded == false)
    #expect(s.quickPanelFrames.isEmpty)
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
        PromptPreset(kind: .refine, name: "Clean up", systemPrompt: "Return only the result.",
                     userTemplate: "Clean up:\n{text}", isFactory: true, sortOrder: 0)
    ]
    s.presetsSeeded = true
    s.defaultRefinePresetID = s.presets[0].id
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
