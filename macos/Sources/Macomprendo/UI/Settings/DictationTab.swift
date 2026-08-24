import SwiftUI

enum TranscriptionLanguages {
    /// `nil` means "detect automatically".
    static let options: [(code: String?, name: String)] = [
        (nil, "Detect automatically"),
        ("en", "English"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("nl", "Dutch"),
        ("pl", "Polish"),
        ("ru", "Russian"),
        ("uk", "Ukrainian"),
        ("tr", "Turkish"),
        ("zh", "Chinese"),
        ("ja", "Japanese"),
        ("ko", "Korean")
    ]
}

struct DictationTab: View {
    @EnvironmentObject private var model: AppModel

    private enum SourceKind: String, CaseIterable, Identifiable {
        case local, endpoint
        var id: String { rawValue }
    }

    var body: some View {
        Form {
            Section("Transcription source") {
                Picker("Run transcription", selection: sourceKind) {
                    Text("On this Mac (whisper.cpp)").tag(SourceKind.local)
                    Text("Through an endpoint").tag(SourceKind.endpoint)
                }
                .pickerStyle(.radioGroup)

                switch model.settings.transcriptionSource {
                case .local(let modelID):
                    Picker("Model", selection: localModelID) {
                        ForEach(ModelCatalog.all) { candidate in
                            Text(candidate.displayName).tag(candidate.id)
                        }
                    }
                    Text(stateDescription(for: modelID))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Download and delete models in the Models tab.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .endpoint(let id, let modelName):
                    Picker("Endpoint", selection: endpointID) {
                        ForEach(model.settings.endpoints) { endpoint in
                            Text(endpoint.name).tag(endpoint.id)
                        }
                    }
                    TextField("Model", text: endpointModel)
                    Text("Sends WAV audio to \(baseURL(for: id))/v1/audio/transcriptions as \u{201c}\(modelName)\u{201d}.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Language") {
                Picker("Spoken language", selection: language) {
                    ForEach(TranscriptionLanguages.options, id: \.name) { option in
                        Text(option.name).tag(option.code)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task { await model.modelsViewModel.refresh() }
    }

    // MARK: - Bindings

    private var sourceKind: Binding<SourceKind> {
        Binding(
            get: {
                if case .endpoint = model.settings.transcriptionSource { return .endpoint }
                return .local
            },
            set: { kind in
                switch kind {
                case .local:
                    model.settings.transcriptionSource = .local(modelID: ModelCatalog.defaultID)
                case .endpoint:
                    let endpointID = model.settings.endpoints.first?.id ?? Endpoint.ollamaLocalID
                    model.settings.transcriptionSource = .endpoint(id: endpointID, model: "whisper-1")
                }
            })
    }

    private var localModelID: Binding<String> {
        Binding(
            get: {
                if case .local(let modelID) = model.settings.transcriptionSource { return modelID }
                return ModelCatalog.defaultID
            },
            set: { model.settings.transcriptionSource = .local(modelID: $0) })
    }

    private var endpointID: Binding<UUID> {
        Binding(
            get: {
                if case .endpoint(let id, _) = model.settings.transcriptionSource { return id }
                return Endpoint.ollamaLocalID
            },
            set: { newID in
                guard case .endpoint(_, let modelName) = model.settings.transcriptionSource else { return }
                model.settings.transcriptionSource = .endpoint(id: newID, model: modelName)
            })
    }

    private var endpointModel: Binding<String> {
        Binding(
            get: {
                if case .endpoint(_, let modelName) = model.settings.transcriptionSource { return modelName }
                return ""
            },
            set: { newModel in
                guard case .endpoint(let id, _) = model.settings.transcriptionSource else { return }
                model.settings.transcriptionSource = .endpoint(id: id, model: newModel)
            })
    }

    private var language: Binding<String?> {
        Binding(get: { model.settings.transcriptionLanguage },
                set: { model.settings.transcriptionLanguage = $0 })
    }

    // MARK: - Helpers

    private func stateDescription(for modelID: String) -> String {
        guard let row = model.modelsViewModel.rows.first(where: { $0.id == modelID }) else {
            return "Checking\u{2026}"
        }
        switch row.state {
        case .notDownloaded: return "Not downloaded \u{2014} download it in the Models tab."
        case .downloading(let fraction): return "Downloading\u{2026} \(Int(fraction * 100))%"
        case .downloaded: return "Ready."
        case .failed(let message): return message
        }
    }

    private func baseURL(for id: UUID) -> String {
        model.settings.endpoints.first { $0.id == id }?.baseURL.absoluteString ?? "the endpoint"
    }
}
