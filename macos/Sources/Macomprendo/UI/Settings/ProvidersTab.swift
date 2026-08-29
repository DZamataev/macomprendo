import SwiftUI

struct ProvidersTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ProvidersTabContent(viewModel: model.providersViewModel)
    }
}

private struct ProvidersTabContent: View {
    @ObservedObject var viewModel: ProvidersViewModel
    @State private var selection: UUID?
    @State private var pullModelName = "qwen2.5:1.5b"

    var body: some View {
        HSplitView {
            list
            detail
                .frame(minWidth: 320, maxWidth: .infinity)
        }
        .padding()
    }

    private var list: some View {
        VStack(spacing: 8) {
            List(viewModel.endpoints, selection: $selection) { endpoint in
                VStack(alignment: .leading, spacing: 2) {
                    Text(endpoint.name)
                    Text(endpoint.baseURL.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(endpoint.id)
            }
            HStack {
                Button { viewModel.add() } label: { Icon(.add, size: 12) }
                Button {
                    if let selection { viewModel.remove(selection) }
                    selection = nil
                } label: {
                    Icon(.remove, size: 12)
                }
                .disabled(selection == nil)
                Spacer()
            }
        }
        // Bounded on both ends: an HSplitView hands a greedy pane everything the other does
        // not claim, and with only a minimum here the list took the whole width and squeezed
        // the editor down to a column a few characters wide.
        .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
    }

    /// The editor needs a floor of its own, or the split gives it whatever is left — which is
    /// nothing once the list has taken its share.
    @ViewBuilder
    private var detail: some View {
        if let endpoint = viewModel.endpoints.first(where: { $0.id == selection }) {
            EndpointEditor(endpoint: endpoint, viewModel: viewModel, pullModelName: $pullModelName)
        } else {
            Text("Select an endpoint.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct EndpointEditor: View {
    let endpoint: Endpoint
    @ObservedObject var viewModel: ProvidersViewModel
    @Binding var pullModelName: String
    @State private var apiKey = ""

    var body: some View {
        Form {
            Section {
                TextField("Name", text: Binding(
                    get: { endpoint.name },
                    set: { newValue in
                        var updated = endpoint
                        updated.name = newValue
                        viewModel.update(updated)
                    }))

                Picker("Kind", selection: Binding(
                    get: { endpoint.kind },
                    set: { newValue in
                        var updated = endpoint
                        updated.kind = newValue
                        viewModel.update(updated)
                    })) {
                    Text("Ollama").tag(EndpointKind.ollama)
                    Text("OpenAI-compatible").tag(EndpointKind.openAICompatible)
                }

                TextField("Base URL", text: Binding(
                    get: { endpoint.baseURL.absoluteString },
                    set: { newValue in
                        guard let url = URL(string: newValue) else { return }
                        var updated = endpoint
                        updated.baseURL = url
                        viewModel.update(updated)
                    }))

                SecureField("API key", text: $apiKey)
                    .onSubmit { viewModel.setAPIKey(apiKey, for: endpoint) }
                Text("Keys are stored in the login Keychain, never in settings or logs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Save key") { viewModel.setAPIKey(apiKey, for: endpoint) }
            }

            Section {
                Button("Test connection") { viewModel.testConnection(endpoint) }
                if let result = viewModel.testResults[endpoint.id] {
                    Text(result).font(.callout)
                }
            }

            if endpoint.kind == .ollama {
                Section("Ollama") {
                    TextField("Model to pull", text: $pullModelName)
                    Button("Pull \(pullModelName)") {
                        viewModel.pull(model: pullModelName, from: endpoint)
                    }
                    if let status = viewModel.pullStatus {
                        if let progress = viewModel.pullProgress {
                            ProgressView(value: progress) { Text(status) }
                        } else {
                            Text(status).font(.callout)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { apiKey = viewModel.apiKey(for: endpoint) }
        .onChange(of: endpoint.id) { _, _ in apiKey = viewModel.apiKey(for: endpoint) }
    }
}
