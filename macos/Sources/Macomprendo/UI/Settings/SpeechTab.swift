import SwiftUI

@MainActor final class SpeechTabModel: ObservableObject {
    struct VoiceGroup: Identifiable, Equatable {
        /// A base language code ("en", "ru"), never a full BCP-47 tag — `group(_:)` keys it
        /// with `baseCode(_:)` because that is what `LanguageDetecting` returns, so this is the
        /// same key space `voiceByLanguage`, `voice(forLanguage:)` and `setVoice(_:forLanguage:)`
        /// read and write. Writing a full tag ("ru-RU") here would silently stop matching.
        let language: String        // base code, e.g. "en"
        let displayName: String     // "English"
        let voices: [Voice]
        var id: String { language }
    }

    /// A short line per language so a voice can be judged on its own language, not on English.
    /// Anything else is auditioned with the voice's own name, the way System Settings does.
    static let auditionPhrases: [String: String] = [
        "en": "This is how I sound.",
        "ru": "Вот так звучит мой голос.",
        "es": "Así suena mi voz.",
        "de": "So klingt meine Stimme.",
        "fr": "Voici comment sonne ma voix.",
        "pt": "É assim que soa a minha voz.",
        "zh": "这就是我的声音。"
    ]

    static let endpointPrivacyCaption =
        "Selected text is sent to the configured server when this source is active."

    @Published private(set) var groups: [VoiceGroup] = []
    @Published private(set) var endpointVoices: [Voice] = []
    /// Write-only: the stored key is never read back into memory (invariant 5).
    @Published var apiKeyField = ""
    @Published private(set) var keyStatus = ""

    private let speech: any SpeechSynthesizing
    private let holder: any SettingsHolding
    private let keychain: any KeychainStoring

    init(speech: any SpeechSynthesizing,
         holder: any SettingsHolding,
         keychain: any KeychainStoring) {
        self.speech = speech
        self.holder = holder
        self.keychain = keychain
        reload()
    }

    var source: SpeechSource {
        get { holder.settings.speech.source }
        set {
            guard holder.settings.speech.source != newValue else { return }
            objectWillChange.send()
            holder.settings.speech.source = newValue
        }
    }

    func reload() {
        groups = Self.group(speech.voices(for: .system))
        endpointVoices = speech.voices(for: .endpoint)
    }

    /// For the endpoint source this performs a real network call and therefore doubles as the
    /// connection test; failures arrive as a toast through `SpeakController`'s `onError` hook.
    func preview() {
        speech.speak(holder.settings.speech.previewText, settings: holder.settings.speech)
    }

    func hasAPIKey() -> Bool {
        holder.settings.speech.endpointAPIKeyRef != nil
    }

    func saveAPIKey() {
        let account = SpeechSettings.endpointKeychainAccount
        let key = apiKeyField.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            try? keychain.delete(account: account)
            holder.settings.speech.endpointAPIKeyRef = nil
            keyStatus = "Key removed."
        } else {
            try? keychain.set(key, account: account)
            holder.settings.speech.endpointAPIKeyRef = account
            keyStatus = "Key saved to the Keychain."
        }
        apiKeyField = ""
    }

    /// The base code of a BCP-47 tag: "ru-RU" and "zh-Hans-CN" become "ru" and "zh". The voice
    /// map is keyed this way because that is what `LanguageDetecting` returns.
    static func baseCode(_ tag: String) -> String {
        tag.split(separator: "-").first.map { $0.lowercased() } ?? tag.lowercased()
    }

    static func group(_ voices: [Voice]) -> [VoiceGroup] {
        Dictionary(grouping: voices, by: { baseCode($0.language) })
            .map { code, voices in
                VoiceGroup(language: code,
                           displayName: Locale.current.localizedString(forLanguageCode: code) ?? code,
                           voices: voices.sorted { ($0.name, $0.id) < ($1.name, $1.id) })
            }
            .sorted { ($0.displayName, $0.language) < ($1.displayName, $1.language) }
    }

    func voice(forLanguage language: String) -> String? {
        holder.settings.speech.voiceByLanguage[language]
    }

    /// nil clears the mapping, which puts that language back on the automatic pick.
    func setVoice(_ voiceID: String?, forLanguage language: String) {
        objectWillChange.send()
        holder.settings.speech.voiceByLanguage[language] = voiceID
        if let voiceID { audition(voiceID) }
    }

    func setDefaultVoice(_ voiceID: String?) {
        objectWillChange.send()
        holder.settings.speech.voiceID = voiceID
        if let voiceID { audition(voiceID) }
    }

    /// Forces the system source and switches segmentation off, so the phrase is guaranteed to
    /// be heard in the voice that was just picked instead of being re-segmented away from it.
    /// Needs no new protocol method: `SpeechRouter` reads the source from these settings.
    private func audition(_ voiceID: String) {
        guard holder.settings.speech.auditionOnSelect else { return }
        var settings = holder.settings.speech
        settings.source = .system
        settings.voiceID = voiceID
        settings.segmentationEnabled = false
        speech.speak(auditionPhrase(for: voiceID), settings: settings)
    }

    func auditionPhrase(for voiceID: String) -> String {
        guard let voice = speech.voices(for: .system).first(where: { $0.id == voiceID }) else {
            return ""
        }
        return Self.auditionPhrases[Self.baseCode(voice.language)] ?? voice.name
    }
}

struct SpeechTab: View {
    @ObservedObject var model: SpeechTabModel
    @ObservedObject var app: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Speech source", selection: sourceSelection) {
                    ForEach(SpeechSource.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                .pickerStyle(.segmented)

                if app.settings.speech.source == .system {
                    systemSection
                } else {
                    endpointSection
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Preview text").font(.headline)
                    TextField("Preview text", text: $app.settings.speech.previewText, axis: .vertical)
                        .lineLimit(2...4)
                    Toggle("Play a sample when a voice is selected",
                           isOn: $app.settings.speech.auditionOnSelect)
                    HStack {
                        Button("Preview") { model.preview() }
                        Button("Reload voices") { model.reload() }
                        Spacer()
                        Text("Hotkey ⌥S reads the current selection; press it again to stop.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
        }
    }

    private var systemSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Default voice").font(.headline)
            Text("Used for languages you have not mapped, and for everything when voice "
                 + "switching is off.")
                .font(.caption).foregroundStyle(.secondary)
            List(selection: Binding(get: { app.settings.speech.voiceID },
                                    set: { model.setDefaultVoice($0) })) {
                ForEach(model.groups) { group in
                    Section(group.displayName) {
                        ForEach(group.voices) { voice in
                            HStack {
                                Text(voice.name)
                                if voice.quality != "default" {
                                    Text(voice.quality.uppercased())
                                        .font(.caption2)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Color.accentColor.opacity(0.18))
                                        .clipShape(Capsule())
                                }
                                Spacer()
                            }
                            .tag(voice.id)
                        }
                    }
                }
            }
            .frame(minHeight: 200)

            Toggle("Switch voices for mixed-language text",
                   isOn: $app.settings.speech.segmentationEnabled)
            Text("""
                Text is cut into runs of a single script, each run's language is detected, and \
                the run is read by the voice you mapped to that language. Short Latin fragments \
                inside Cyrillic text stay on the Cyrillic voice on purpose, so one foreign word \
                does not flip the voice mid-sentence.
                """)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Voice per language").font(.headline)
            ForEach(model.groups) { group in
                Picker(group.displayName, selection: Binding(
                    get: { model.voice(forLanguage: group.language) },
                    set: { model.setVoice($0, forLanguage: group.language) })) {
                        Text("Auto").tag(String?.none)
                        ForEach(group.voices) { voice in
                            Text(voice.name).tag(Optional(voice.id))
                        }
                    }
            }
            .disabled(!app.settings.speech.segmentationEnabled)

            // Rate, pitch and volume are AVSpeechSynthesizer parameters; the endpoint takes
            // free-form "Style instructions" instead.
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Rate")
                    Slider(value: $app.settings.speech.rate, in: 0...1)
                }
                GridRow {
                    Text("Pitch")
                    Slider(value: $app.settings.speech.pitch, in: 0.5...2.0)
                }
                GridRow {
                    Text("Volume")
                    Slider(value: $app.settings.speech.volume, in: 0...1)
                }
            }
        }
    }

    private var endpointSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                TextField("Base URL", text: baseURLSelection,
                          prompt: Text("https://api.openai.com"))
                TextField("Model", text: $app.settings.speech.endpointModel)

                // Free-form: local servers (openedai-speech, Kokoro-FastAPI) define their own
                // names, so the built-ins are offered as a menu rather than a closed picker.
                HStack {
                    TextField("Voice", text: $app.settings.speech.endpointVoice)
                    Menu("Built-in") {
                        ForEach(model.endpointVoices) { voice in
                            Button(voice.name) { app.settings.speech.endpointVoice = voice.id }
                        }
                    }
                    .fixedSize()
                }

                SecureField("API key", text: $model.apiKeyField)
                    .onSubmit { model.saveAPIKey() }
                HStack {
                    Button("Save key") { model.saveAPIKey() }
                    if !model.keyStatus.isEmpty {
                        Text(model.keyStatus).font(.caption).foregroundStyle(.secondary)
                    } else if model.hasAPIKey() {
                        Text("A key is saved.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("A local server without authentication still needs a non-empty key here.")
                    .font(.caption).foregroundStyle(.secondary)

                TextField("Style instructions", text: $app.settings.speech.endpointInstructions,
                          prompt: Text("e.g. Read this cheerfully"))
            }
            .formStyle(.grouped)

            Text(SpeechTabModel.endpointPrivacyCaption)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sourceSelection: Binding<SpeechSource> {
        Binding(get: { app.settings.speech.source },
                set: { app.settings.speech.source = $0 })
    }

    /// Keeps the last valid URL when the user is mid-edit and the text does not parse.
    private var baseURLSelection: Binding<String> {
        Binding(get: { app.settings.speech.endpointBaseURL.absoluteString },
                set: { newValue in
                    guard let url = URL(string: newValue) else { return }
                    app.settings.speech.endpointBaseURL = url
                })
    }
}
