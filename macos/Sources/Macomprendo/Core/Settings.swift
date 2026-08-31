import Foundation

enum DictationMode: String, Codable, Sendable { case hold, toggle }
enum InsertMethod: String, Codable, Sendable { case auto, paste, typing }

/// `Hashable` so the active-model selector can tag its `Picker` rows with the source itself
/// rather than with a stringly-typed stand-in.
enum TranscriptionSource: Codable, Sendable, Equatable, Hashable {
    /// A local transcription model id from `ModelCatalog`, e.g. "large-v3-turbo".
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

/// Which backend reads text aloud.
enum SpeechSource: String, Codable, Sendable, CaseIterable, Identifiable {
    case system
    case endpoint

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "System voices"
        case .endpoint: "Endpoint"
        }
    }
}

struct SpeechSettings: Codable, Sendable, Equatable {
    /// Any OpenAI-compatible `/v1/audio/speech` server: OpenAI itself, a reseller such as
    /// `https://api.proxyapi.ru/openai`, or a local server on `http://localhost:8000`.
    static let defaultEndpointBaseURL = URL(string: "https://api.openai.com")!
    static let defaultEndpointModel = "gpt-4o-mini-tts"
    static let defaultEndpointVoice = "alloy"
    /// Keychain account name for the speech endpoint's key. The key itself never leaves the
    /// Keychain (invariant 5); `endpointAPIKeyRef` only records that one is stored.
    static let endpointKeychainAccount = "speech.endpoint"

    static let defaultPreviewText =
        "Macomprendo can read your selected text out loud. "
        + "Макомпрендо читает выделенный текст вслух."

    var voiceID: String?
    var rate: Float
    var pitch: Float
    var volume: Float
    var source: SpeechSource
    var endpointBaseURL: URL
    var endpointModel: String
    var endpointVoice: String
    var endpointInstructions: String
    var endpointAPIKeyRef: String?
    /// Base language code → voice identifier. An absent key means "pick automatically".
    var voiceByLanguage: [String: String]
    var segmentationEnabled: Bool
    var previewText: String
    var auditionOnSelect: Bool

    init(voiceID: String? = nil,
         rate: Float = 0.5,
         pitch: Float = 1.0,
         volume: Float = 1.0,
         source: SpeechSource = .system,
         endpointBaseURL: URL = SpeechSettings.defaultEndpointBaseURL,
         endpointModel: String = SpeechSettings.defaultEndpointModel,
         endpointVoice: String = SpeechSettings.defaultEndpointVoice,
         endpointInstructions: String = "",
         endpointAPIKeyRef: String? = nil,
         voiceByLanguage: [String: String] = [:],
         segmentationEnabled: Bool = true,
         previewText: String = SpeechSettings.defaultPreviewText,
         auditionOnSelect: Bool = true) {
        self.voiceID = voiceID
        self.rate = rate
        self.pitch = pitch
        self.volume = volume
        self.source = source
        self.endpointBaseURL = endpointBaseURL
        self.endpointModel = endpointModel
        self.endpointVoice = endpointVoice
        self.endpointInstructions = endpointInstructions
        self.endpointAPIKeyRef = endpointAPIKeyRef
        self.voiceByLanguage = voiceByLanguage
        self.segmentationEnabled = segmentationEnabled
        self.previewText = previewText
        self.auditionOnSelect = auditionOnSelect
    }
}

extension SpeechSettings {
    /// Hand-written so a document written before the endpoint source existed decodes to the
    /// defaults for the new keys instead of throwing. Declared in an extension so the struct
    /// keeps its memberwise initialiser — the same pattern `Settings` uses.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SpeechSettings()
        voiceID = try c.decodeIfPresent(String.self, forKey: .voiceID)
        rate = try c.decodeIfPresent(Float.self, forKey: .rate) ?? d.rate
        pitch = try c.decodeIfPresent(Float.self, forKey: .pitch) ?? d.pitch
        volume = try c.decodeIfPresent(Float.self, forKey: .volume) ?? d.volume
        source = try c.decodeIfPresent(SpeechSource.self, forKey: .source) ?? d.source
        endpointBaseURL = try c.decodeIfPresent(URL.self, forKey: .endpointBaseURL) ?? d.endpointBaseURL
        endpointModel = try c.decodeIfPresent(String.self, forKey: .endpointModel) ?? d.endpointModel
        endpointVoice = try c.decodeIfPresent(String.self, forKey: .endpointVoice) ?? d.endpointVoice
        endpointInstructions = try c.decodeIfPresent(String.self, forKey: .endpointInstructions)
            ?? d.endpointInstructions
        endpointAPIKeyRef = try c.decodeIfPresent(String.self, forKey: .endpointAPIKeyRef)
        voiceByLanguage = try c.decodeIfPresent([String: String].self, forKey: .voiceByLanguage)
            ?? d.voiceByLanguage
        segmentationEnabled = try c.decodeIfPresent(Bool.self, forKey: .segmentationEnabled)
            ?? d.segmentationEnabled
        previewText = try c.decodeIfPresent(String.self, forKey: .previewText) ?? d.previewText
        auditionOnSelect = try c.decodeIfPresent(Bool.self, forKey: .auditionOnSelect)
            ?? d.auditionOnSelect
    }
}

enum SettingsMigrationError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
}

/// The whole persisted document. Stored as JSON in `UserDefaults` under "settings.v1".
struct Settings: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 2

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
    /// The working language for Refine & Summarize.
    var promptLanguage: String
    /// What the translating presets translate into, substituted as `{chosen_language}`.
    var translationTarget: TranslationTarget
    /// Languages whose factory presets have already been seeded.
    var seededPromptLanguages: [String]
    /// The factory-set version this document was last topped up to. See
    /// `FactoryPresets.currentVersion`.
    var seededFactoryVersion: Int
    /// Key: `Settings.presetKey(kind, language)`.
    var defaultPresetIDs: [String: UUID]
    /// Key: screen identifier, value: the remembered Quick Panel frame.
    var quickPanelFrames: [String: CGRect]
    /// The endpoint configured for transcription, which is not necessarily the active one:
    /// the endpoint sub-tab configures a server, and the selector activates it. Stored as its
    /// two components rather
    /// than as a `TranscriptionSource?`, because only one of that enum's cases would ever be
    /// valid here and a type that can hold an impossible value invites the bug of writing one.
    var lastTranscriptionEndpointID: UUID?
    var lastTranscriptionEndpointModel: String?
    /// whisper.cpp's thread count. `nil` leaves it to the machine's core count. Only
    /// whisper.cpp reads these two: GigaAM takes no parameters and an endpoint decides
    /// for itself.
    var whisperThreads: Int?
    /// whisper.cpp's `translate` flag: transcribe non-English speech into English.
    var whisperTranslate: Bool

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
            promptLanguage: PromptLanguage.systemDefault.code,
            translationTarget: .systemLanguage,
            seededPromptLanguages: [],
            seededFactoryVersion: 0,
            defaultPresetIDs: [:],
            quickPanelFrames: [:],
            lastTranscriptionEndpointID: nil,
            lastTranscriptionEndpointModel: nil,
            whisperThreads: nil,
            whisperTranslate: false
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
        promptLanguage = try c.decodeIfPresent(String.self, forKey: .promptLanguage) ?? d.promptLanguage
        translationTarget = try c.decodeIfPresent(TranslationTarget.self, forKey: .translationTarget)
            ?? d.translationTarget
        seededPromptLanguages = try c.decodeIfPresent([String].self, forKey: .seededPromptLanguages)
            ?? d.seededPromptLanguages
        seededFactoryVersion = try c.decodeIfPresent(Int.self, forKey: .seededFactoryVersion)
            ?? d.seededFactoryVersion
        defaultPresetIDs = try c.decodeIfPresent([String: UUID].self, forKey: .defaultPresetIDs)
            ?? d.defaultPresetIDs
        quickPanelFrames = try c.decodeIfPresent([String: CGRect].self, forKey: .quickPanelFrames) ?? d.quickPanelFrames
        lastTranscriptionEndpointID = try c.decodeIfPresent(UUID.self, forKey: .lastTranscriptionEndpointID)
        lastTranscriptionEndpointModel = try c.decodeIfPresent(String.self, forKey: .lastTranscriptionEndpointModel)
        whisperThreads = try c.decodeIfPresent(Int.self, forKey: .whisperThreads)
        whisperTranslate = try c.decodeIfPresent(Bool.self, forKey: .whisperTranslate) ?? d.whisperTranslate
    }
}
