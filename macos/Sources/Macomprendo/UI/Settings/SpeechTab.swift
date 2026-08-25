import SwiftUI

@MainActor final class SpeechTabModel: ObservableObject {
    struct VoiceGroup: Identifiable, Equatable {
        let language: String        // BCP-47, e.g. "en-US"
        let displayName: String     // "English (United States)"
        let voices: [Voice]
        var id: String { language }
    }

    static let sampleText = "Macomprendo can read your selected text out loud."

    @Published private(set) var groups: [VoiceGroup] = []

    private let speech: any SpeechSynthesizing
    private let holder: any SettingsHolding

    init(speech: any SpeechSynthesizing, holder: any SettingsHolding) {
        self.speech = speech
        self.holder = holder
        reload()
    }

    func reload() {
        groups = Self.group(speech.voices())
    }

    func preview() {
        speech.speak(Self.sampleText, settings: holder.settings.speech)
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

    private var voiceSelection: Binding<String?> {
        Binding(get: { app.settings.speech.voiceID },
                set: { app.settings.speech.voiceID = $0 })
    }
}
