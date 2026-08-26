import SwiftUI

@MainActor final class SpeechTabModel: ObservableObject {
    struct VoiceGroup: Identifiable, Equatable {
        let language: String        // BCP-47, e.g. "en-US"
        let displayName: String     // "English (United States)"
        let voices: [Voice]
        var id: String { language }
    }

    static let sampleText = "Macomprendo can read your selected text out loud."

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
        speech.speak(Self.sampleText, settings: holder.settings.speech)
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

    static func group(_ voices: [Voice]) -> [VoiceGroup] {
        Dictionary(grouping: voices, by: \.language)
            .map { language, voices in
                VoiceGroup(language: language,
                           displayName: Locale.current.localizedString(forIdentifier: language) ?? language,
                           voices: voices.sorted { ($0.name, $0.id) < ($1.name, $1.id) })
            }
            .sorted { ($0.displayName, $0.language) < ($1.displayName, $1.language) }
    }
}

struct SpeechTab: View {
    @ObservedObject var model: SpeechTabModel
    @ObservedObject var app: AppModel

    var body: some View {
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

            HStack {
                Button("Preview") { model.preview() }
                Button("Reload voices") { model.reload() }
                Spacer()
                Text("Hotkey ⌥S reads the current selection; press it again to stop.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    private var systemSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Voice").font(.headline)
            List(selection: voiceSelection) {
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

    private var voiceSelection: Binding<String?> {
        Binding(get: { app.settings.speech.voiceID },
                set: { app.settings.speech.voiceID = $0 })
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
