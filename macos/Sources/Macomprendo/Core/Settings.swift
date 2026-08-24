import Foundation

enum DictationMode: String, Codable, Sendable { case hold, toggle }
enum InsertMethod: String, Codable, Sendable { case auto, paste, typing }

enum TranscriptionSource: Codable, Sendable, Equatable {
    /// A whisper ggml model id from `ModelCatalog`, e.g. "large-v3-turbo".
    case local(modelID: String)
    /// An OpenAI-compatible `/v1/audio/transcriptions` endpoint.
    case endpoint(id: UUID, model: String)
}

struct LLMSelection: Codable, Sendable, Equatable {
    var endpointID: UUID
    var model: String

    init(endpointID: UUID, model: String) {
        self.endpointID = endpointID
        self.model = model
    }
}

struct SpeechSettings: Codable, Sendable, Equatable {
    var voiceID: String?
    var rate: Float
    var pitch: Float
    var volume: Float

    init(voiceID: String? = nil, rate: Float = 0.5, pitch: Float = 1.0, volume: Float = 1.0) {
        self.voiceID = voiceID
        self.rate = rate
        self.pitch = pitch
        self.volume = volume
    }
}

enum SettingsMigrationError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
}

/// The whole persisted document. Stored as JSON in `UserDefaults` under "settings.v1".
struct Settings: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var dictationMode: DictationMode
    var insertMethod: InsertMethod
    var launchAtLogin: Bool
    var transcriptionSource: TranscriptionSource
    /// nil = detect the language automatically.
    var transcriptionLanguage: String?
    var endpoints: [Endpoint]
    var refineLLM: LLMSelection?
    var summarizeLLM: LLMSelection?
    var speech: SpeechSettings
    var presets: [PromptPreset]
    var presetsSeeded: Bool
    var defaultRefinePresetID: UUID?
    var defaultSummarizePresetID: UUID?
    /// Key: screen identifier, value: the remembered Quick Panel frame.
    var quickPanelFrames: [String: CGRect]

    static var `default`: Settings {
        Settings(
            schemaVersion: currentSchemaVersion,
            dictationMode: .hold,
            insertMethod: .auto,
            launchAtLogin: false,
            transcriptionSource: .local(modelID: "large-v3-turbo"),
            transcriptionLanguage: nil,
            endpoints: [Endpoint.ollamaLocal()],
            refineLLM: LLMSelection(endpointID: Endpoint.ollamaLocalID, model: "qwen2.5:1.5b"),
            summarizeLLM: LLMSelection(endpointID: Endpoint.ollamaLocalID, model: "qwen2.5:1.5b"),
            speech: SpeechSettings(),
            presets: [],
            presetsSeeded: false,
            defaultRefinePresetID: nil,
            defaultSummarizePresetID: nil,
            quickPanelFrames: [:]
        )
    }

    /// Decodes persisted JSON. Refuses payloads written by a newer schema; tolerates
    /// payloads written by an older one.
    static func migrate(_ json: Data) throws -> Settings {
        let probe = try JSONDecoder().decode(SchemaProbe.self, from: json)
        let version = probe.schemaVersion ?? currentSchemaVersion
        guard version <= currentSchemaVersion else {
            throw SettingsMigrationError.unsupportedSchemaVersion(version)
        }
        var settings = try JSONDecoder().decode(Settings.self, from: json)
        settings.schemaVersion = currentSchemaVersion
        return settings
    }

    private struct SchemaProbe: Decodable {
        var schemaVersion: Int?
    }
}

extension Settings {
    /// Hand-written so a payload missing newly added keys decodes to the default for
    /// those keys instead of throwing. Declared in an extension so the struct keeps its
    /// memberwise initialiser.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings.default
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? d.schemaVersion
        dictationMode = try c.decodeIfPresent(DictationMode.self, forKey: .dictationMode) ?? d.dictationMode
        insertMethod = try c.decodeIfPresent(InsertMethod.self, forKey: .insertMethod) ?? d.insertMethod
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        transcriptionSource = try c.decodeIfPresent(TranscriptionSource.self, forKey: .transcriptionSource) ?? d.transcriptionSource
        transcriptionLanguage = try c.decodeIfPresent(String.self, forKey: .transcriptionLanguage)
        endpoints = try c.decodeIfPresent([Endpoint].self, forKey: .endpoints) ?? d.endpoints
        refineLLM = try c.decodeIfPresent(LLMSelection.self, forKey: .refineLLM) ?? d.refineLLM
        summarizeLLM = try c.decodeIfPresent(LLMSelection.self, forKey: .summarizeLLM) ?? d.summarizeLLM
        speech = try c.decodeIfPresent(SpeechSettings.self, forKey: .speech) ?? d.speech
        presets = try c.decodeIfPresent([PromptPreset].self, forKey: .presets) ?? d.presets
        presetsSeeded = try c.decodeIfPresent(Bool.self, forKey: .presetsSeeded) ?? d.presetsSeeded
        defaultRefinePresetID = try c.decodeIfPresent(UUID.self, forKey: .defaultRefinePresetID)
        defaultSummarizePresetID = try c.decodeIfPresent(UUID.self, forKey: .defaultSummarizePresetID)
        quickPanelFrames = try c.decodeIfPresent([String: CGRect].self, forKey: .quickPanelFrames) ?? d.quickPanelFrames
    }
}
