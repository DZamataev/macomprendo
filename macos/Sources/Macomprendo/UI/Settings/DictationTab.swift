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

/// One sub-tab per transcription backend. The sub-tab *is* the selection: opening GigaAM makes
/// GigaAM the engine dictation runs. That is deliberate, and the status block right under the
/// tabs says so in words rather than leaving it to be discovered by pressing the hotkey.
struct DictationTab: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var tab: DictationTabModel
    @ObservedObject var models: ModelsViewModel
    @FocusState private var endpointModelFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: tabBinding) {
                ForEach(DictationBackendTab.allCases) { candidate in
                    Text(tab.tabTitle(for: candidate)).tag(candidate)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top])

            // Pinned above the scrolling form rather than filed at the bottom of it: on a tab
            // listing nine models with their briefs, a status block below the fold would be
            // exactly the "you can only find this out by dictating" failure it exists to avoid.
            statusBanner
                .padding(.horizontal)
                .padding(.vertical, 10)

            Divider()

            Form {
                switch tab.activeTab {
                case .whisperCpp, .gigaAM:
                    modelsSection
                    parametersSection
                case .endpoint:
                    endpointSection
                }
            }
            .formStyle(.grouped)
        }
        .task {
            await models.refresh()
            tab.adopt(models.rows)
        }
        .onChange(of: models.rows) { _, rows in tab.adopt(rows) }
    }

    // MARK: - Status

    private var isReady: Bool { tab.readiness == .ready }

    private var statusBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Icon(isReady ? .success : .warning, size: 14)
                .foregroundStyle(isReady ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.statusHeadline)
                    .font(.callout.weight(.semibold))
                Text(tab.statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            fixButton
        }
    }

    @ViewBuilder
    private var fixButton: some View {
        if case .notReady(_, let fix) = tab.readiness, let fix {
            switch fix {
            case .download(let modelID):
                Button("Download") { models.download(modelID) }
            case .testEndpoint:
                testButton
            case .selectModel:
                Button("Name a model") { endpointModelFocused = true }
            }
        }
    }

    private var testButton: some View {
        Button(tab.isProbing ? "Testing…" : "Test") {
            let provider = model.transcriberProvider
            Task { await tab.probeEndpoint { try await provider() } }
        }
        .disabled(tab.isProbing)
    }

    // MARK: - Models

    private var modelsSection: some View {
        Section("Models") {
            ForEach(tab.rows(for: tab.activeTab)) { entry in
                modelRow(entry)
            }

            HStack(alignment: .firstTextBaseline) {
                Text("Stored in ~/Library/Application Support/Macomprendo/models. "
                     + "Disk usage: \(models.diskUsageText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Refresh") { Task { await models.refresh() } }
            }
        }
    }

    @ViewBuilder
    private func modelRow(_ entry: LocalASRModel) -> some View {
        let state = models.rows.first { $0.id == entry.id }?.state
        let selected = tab.selectedModelID == entry.id

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.displayName)
                            .fontWeight(selected ? .semibold : .regular)
                        if selected { activeBadge }
                    }
                    Text("\(ModelsViewModel.sizeText(entry.totalSizeBytes)) · "
                         + DictationTabModel.languagesText(entry.languages))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if selected {
                        Text(Self.stateCaption(for: state))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    if !selected {
                        Button("Use this model") { tab.select(modelID: entry.id) }
                    }
                    modelStateView(entry.id, state)
                }
            }
            ModelBriefView(brief: entry.brief)
        }
        .padding(.vertical, 4)
    }

    private var activeBadge: some View {
        Text("Active")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
    }

    @ViewBuilder
    private func modelStateView(_ id: String, _ state: ModelState?) -> some View {
        switch state {
        case .none:
            EmptyView()
        case .notDownloaded:
            Button("Download") { models.download(id) }
        case .downloading(let fraction):
            HStack(spacing: 8) {
                ProgressView(value: fraction).frame(width: 90)
                Button("Cancel") { models.cancelDownload(id) }
            }
        case .downloaded:
            HStack(spacing: 8) {
                Label { Text("Downloaded") } icon: { Icon(.success, size: 14) }
                    .foregroundStyle(.green)
                Button("Delete", role: .destructive) { Task { await models.delete(id) } }
            }
        case .failed(let message):
            HStack(spacing: 8) {
                Label { Text(message) } icon: { Icon(.warning, size: 14) }
                    .foregroundStyle(.red)
                    .lineLimit(2)
                Button("Retry") { models.download(id) }
            }
        }
    }

    // MARK: - Parameters

    @ViewBuilder
    private var parametersSection: some View {
        Section("Parameters") {
            if tab.activeTab == .whisperCpp {
                Picker("Spoken language", selection: language) {
                    ForEach(TranscriptionLanguages.options, id: \.name) { option in
                        Text(option.name).tag(option.code)
                    }
                }
                Picker("Threads", selection: threads) {
                    ForEach(DictationTabModel.threadChoices(processorCount: processorCount), id: \.self) { choice in
                        Text(DictationTabModel.threadLabel(choice, processorCount: processorCount))
                            .tag(choice)
                    }
                }
                Toggle("Translate into English", isOn: translate)
                Text("whisper.cpp can translate while it transcribes: speech in any language "
                     + "comes back as English text. Leave this off to keep the spoken language.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(tab.activeTab.parameterSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var processorCount: Int { ProcessInfo.processInfo.activeProcessorCount }

    // MARK: - Endpoint

    @ViewBuilder
    private var endpointSection: some View {
        Section("Endpoint") {
            Picker("Endpoint", selection: endpointID) {
                ForEach(model.settings.endpoints) { endpoint in
                    Text(endpoint.name).tag(endpoint.id)
                }
            }
            TextField("Model", text: endpointModel)
                .focused($endpointModelFocused)

            if case .endpoint(let id, let modelName) = model.settings.transcriptionSource {
                Text("Sends WAV audio to \(baseURL(for: id))/v1/audio/transcriptions "
                     + "as \u{201c}\(modelName)\u{201d}. Your dictation is sent to that server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline) {
                testButton
                Text(tab.probeCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Bindings

    private var tabBinding: Binding<DictationBackendTab> {
        Binding(get: { tab.activeTab }, set: { tab.select(tab: $0) })
    }

    private var endpointID: Binding<UUID> {
        Binding(
            get: {
                if case .endpoint(let id, _) = model.settings.transcriptionSource { return id }
                return Endpoint.ollamaLocalID
            },
            set: { tab.select(endpointID: $0) })
    }

    private var endpointModel: Binding<String> {
        Binding(
            get: {
                if case .endpoint(_, let modelName) = model.settings.transcriptionSource { return modelName }
                return ""
            },
            set: { tab.select(endpointModel: $0) })
    }

    private var language: Binding<String?> {
        Binding(get: { model.settings.transcriptionLanguage },
                set: { model.settings.transcriptionLanguage = $0 })
    }

    private var threads: Binding<Int?> {
        Binding(get: { model.settings.whisperThreads },
                set: { model.settings.whisperThreads = $0 })
    }

    private var translate: Binding<Bool> {
        Binding(get: { model.settings.whisperTranslate },
                set: { model.settings.whisperTranslate = $0 })
    }

    // MARK: - Helpers

    /// Pure, so the wording is unit-tested. `nil` means the row has not been read yet.
    /// `ModelState` is the top-level enum from `ModelManager`, the same one `ModelsViewModel.Row`
    /// stores.
    static func stateCaption(for state: ModelState?) -> String {
        switch state {
        case .none: "Checking…"
        case .notDownloaded: "Not downloaded — use the Download button on this row."
        case .downloading(let fraction): "Downloading… \(Int(fraction * 100))%"
        case .downloaded: "Ready."
        case .failed(let message): message
        }
    }

    private func baseURL(for id: UUID) -> String {
        model.settings.endpoints.first { $0.id == id }?.baseURL.absoluteString ?? "the endpoint"
    }
}
