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

/// The active-model selector and its status sit at the top; the three sub-tabs below are pure
/// navigation. Moving between them changes what is on screen and nothing else — only the
/// selector changes what transcribes.
struct DictationTab: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var tab: DictationTabModel
    @ObservedObject var models: ModelsViewModel
    @FocusState private var endpointModelFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal)
                .padding(.vertical, 10)

            Divider()

            Picker("", selection: $tab.viewedTab) {
                ForEach(DictationBackendTab.allCases) { candidate in
                    Text(candidate.title).tag(candidate)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top])

            Form {
                switch tab.viewedTab {
                case .whisperCpp, .gigaAM:
                    modelsSection
                    parametersSection
                case .endpoint:
                    endpointSection
                }

                recordingSection
            }
            .formStyle(.grouped)
        }
        .task {
            await models.refresh()
            tab.adopt(models.rows)
        }
        .onChange(of: models.rows) { _, rows in tab.adopt(rows) }
    }

    // MARK: - Selector and status

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Picker("Active model", selection: activeSource) {
                    ForEach(tab.selectableSources) { entry in
                        Text(entry.menuTitle).tag(entry.source)
                    }
                }
                .disabled(!tab.hasReadySource)

                if !tab.selectorCaption.isEmpty {
                    Text(tab.selectorCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            statusBlock
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var isReady: Bool { tab.readiness == .ready }

    /// The only status on this screen, and it describes the selection rather than whatever
    /// sub-tab happens to be open. Two blocks would answer "what runs when I press the
    /// hotkey" twice with no way to tell which answer is real.
    private var statusBlock: some View {
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
                Button("Download") {
                    tab.reveal(.local(modelID: modelID))
                    models.download(modelID)
                }
            case .testEndpoint(let target):
                testButton(source: target.source)
            case .selectModel:
                Button("Name a model") {
                    tab.viewedTab = .endpoint
                    endpointModelFocused = true
                }
            }
        }
    }

    private func testButton(source: TranscriptionSource?) -> some View {
        Button(tab.isProbing ? "Testing…" : "Test") {
            Task {
                await tab.probeEndpoint(source) { try await model.transcriber(for: $0) }
            }
        }
        .disabled(tab.isProbing)
    }

    // MARK: - Models

    private var modelsSection: some View {
        Section("Models") {
            ForEach(tab.rows(for: tab.viewedTab)) { entry in
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
    private func modelRow(_ entry: LocalModel) -> some View {
        let state = models.rows.first { $0.id == entry.id }?.state
        let active = tab.selectedModelID == entry.id

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.displayName)
                            .fontWeight(active ? .semibold : .regular)
                        if active { activeBadge }
                    }
                    Text("\(ModelsViewModel.sizeText(entry.totalSizeBytes)) · "
                         + entry.languagesText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if active {
                        Text(Self.stateCaption(for: state))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    // Offered only for a model that can actually run: a shortcut for the
                    // selector, which lists exactly those. A model still downloading or
                    // missing offers its download control instead.
                    if !active, case .downloaded = state {
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
            // What a tab offers is the model's statement, not the view's: an empty
            // `parameterSummary` means "this tab has real controls". Only the two local tabs
            // reach here — the outer switch sends `.endpoint` to its own section.
            if tab.viewedTab.parameterSummary.isEmpty {
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
                Text(tab.viewedTab.parameterSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var processorCount: Int { ProcessInfo.processInfo.activeProcessorCount }

    // MARK: - Endpoint

    private var endpointSection: some View {
        Section("Endpoint") {
            Picker("Endpoint", selection: endpointID) {
                ForEach(model.settings.endpoints) { endpoint in
                    Text(endpoint.name).tag(endpoint.id)
                }
            }
            TextField("Model", text: endpointModel)
                .focused($endpointModelFocused)

            Text("Sends WAV audio to \(baseURL(for: tab.configuredEndpointID))"
                 + "/v1/audio/transcriptions as \u{201c}\(tab.configuredEndpointModel)\u{201d}. "
                 + "Your dictation is sent to that server. Configuring it here does not switch "
                 + "to it — once its test passes it joins the Active model list above.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .firstTextBaseline) {
                testButton(source: tab.configuredEndpoint)
                Text(tab.probeCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Recording

    /// Outside the sub-tab switch: the cap applies to every backend, so it is not the
    /// business of whichever one happens to be on screen.
    private var recordingSection: some View {
        Section("Recording") {
            Picker("Maximum recording length", selection: maximumRecordingMinutes) {
                ForEach(DictationTab.recordingMinuteChoices, id: \.self) { minutes in
                    Text(DictationTab.recordingLengthLabel(minutes: minutes)).tag(minutes)
                }
            }
            Text(DictationTab.recordingLengthCaption(minutes: minutesChoice))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The offered choice the currently stored length maps to, for the caption below the
    /// picker — same snapping `minutesChoice(forSeconds:)` applies to the picker's selection.
    private var minutesChoice: Int {
        DictationTab.minutesChoice(forSeconds: model.settings.maximumRecordingSeconds)
    }

    /// Whole minutes covering `Settings.recordingSecondsRange`, coarser as they grow.
    nonisolated static let recordingMinuteChoices = [1, 2, 3, 5, 10, 15, 20, 30, 45, 60]

    /// Pure, so the wording is unit-tested.
    nonisolated static func recordingLengthLabel(minutes: Int) -> String {
        minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    /// The caption below the picker. A recording accumulates as `[Float]` in memory —
    /// captured PCM, then again for the WAV encode and again for the AAC encode — so past a
    /// defensible length the limiting resource is memory, not the endpoint's upload cap, and
    /// the caption must name that cost rather than only the 25 MiB upload limit.
    nonisolated static func recordingLengthCaption(minutes: Int) -> String {
        let base = "Endpoint transcription uploads WAV, and OpenAI-compatible endpoints reject "
            + "requests above 25 MiB — about 13 minutes at 16 kHz mono 16-bit. Local "
            + "models have no such limit."
        guard minutes >= 45 else { return base }
        return base + " At \(minutes) minutes the recording, its WAV copy and its AAC copy "
            + "together use several hundred MB of memory while dictating."
    }

    /// The offered choice a stored value maps to. A hand-edited document may hold any number
    /// of seconds in range, and a `Picker` whose selection is missing from its options renders
    /// undefined — so snap to the nearest offered minute rather than showing nothing.
    nonisolated static func minutesChoice(forSeconds seconds: Int) -> Int {
        let minutes = Double(seconds) / 60
        return recordingMinuteChoices.min {
            abs(Double($0) - minutes) < abs(Double($1) - minutes)
        } ?? 5
    }

    // MARK: - Bindings

    private var maximumRecordingMinutes: Binding<Int> {
        Binding(
            get: { DictationTab.minutesChoice(forSeconds: model.settings.maximumRecordingSeconds) },
            set: { model.settings.maximumRecordingSeconds = $0 * 60 })
    }

    private var activeSource: Binding<TranscriptionSource> {
        Binding(get: { tab.activeSource }, set: { tab.activate($0) })
    }

    private var endpointID: Binding<UUID> {
        Binding(
            get: { tab.configuredEndpointID ?? model.settings.endpoints.first?.id ?? Endpoint.ollamaLocalID },
            set: { tab.select(endpointID: $0) })
    }

    private var endpointModel: Binding<String> {
        Binding(get: { tab.configuredEndpointModel }, set: { tab.select(endpointModel: $0) })
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

    private func baseURL(for id: UUID?) -> String {
        guard let id else { return "the endpoint" }
        return model.settings.endpoints.first { $0.id == id }?.baseURL.absoluteString ?? "the endpoint"
    }
}
