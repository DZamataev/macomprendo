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

    struct LocalVoiceGroup: Identifiable, Equatable {
        let language: String
        let displayName: String
        let models: [LocalModel]
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
    private let toaster: any Toasting
    private let modelStates: @MainActor () -> [String: ModelState]

    init(speech: any SpeechSynthesizing,
         holder: any SettingsHolding,
         keychain: any KeychainStoring,
         toaster: any Toasting,
         modelStates: @escaping @MainActor () -> [String: ModelState]) {
        self.speech = speech
        self.holder = holder
        self.keychain = keychain
        self.toaster = toaster
        self.modelStates = modelStates
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
    ///
    /// Preview speaks through whatever source is *active*, and the header selector allows
    /// activating a source that is not ready yet (e.g. Local with no model downloaded).
    /// Mirrors `SpeakController.speak`'s gate: never fall back to another source, since that
    /// would hide that the chosen one is broken.
    func preview() {
        let current = holder.settings.speech
        if case .notReady(let reason, _) = SpeechReadiness.of(source: current.source,
                                                              settings: current,
                                                              modelStates: modelStates()) {
            toaster.toast(reason, duration: 2.5)
            return
        }
        speech.speak(current.previewText, settings: current)
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

    static func localCatalogGroups(_ models: [LocalModel]) -> [LocalVoiceGroup] {
        var grouped: [String: [LocalModel]] = [:]
        for model in models where model.kind == .tts {
            for language in Set((model.languages ?? []).map(baseCode)).sorted() where !language.isEmpty {
                grouped[language, default: []].append(model)
            }
        }
        return grouped.map { language, models in
            LocalVoiceGroup(
                language: language,
                displayName: Locale.current.localizedString(forLanguageCode: language) ?? language,
                models: models)
        }
        .sorted { ($0.displayName, $0.language) < ($1.displayName, $1.language) }
    }

    func downloadedLocalGroups(catalog: [LocalModel]) -> [LocalVoiceGroup] {
        let states = modelStates()
        let downloaded = catalog.filter {
            if case .downloaded = states[$0.id] { return true }
            return false
        }
        return Self.localCatalogGroups(downloaded)
    }

    func localVoice(
        forLanguage language: String,
        catalog: [LocalModel]
    ) -> LocalVoiceSelection? {
        let language = Self.baseCode(language)
        guard let selection = holder.settings.speech.localVoiceByLanguage[language],
              let model = catalog.first(where: { $0.id == selection.modelID }),
              isDownloaded(model.id),
              model.languages?.contains(where: { Self.baseCode($0) == language }) == true
        else { return nil }
        return LocalVoiceSelection(
            modelID: selection.modelID,
            speakerID: Self.clampedSpeaker(selection.speakerID, model: model))
    }

    func setLocalVoice(
        _ modelID: String?,
        forLanguage language: String,
        catalog: [LocalModel]
    ) {
        let language = Self.baseCode(language)
        objectWillChange.send()
        guard let modelID else {
            holder.settings.speech.localVoiceByLanguage.removeValue(forKey: language)
            return
        }
        guard let model = catalog.first(where: { $0.id == modelID }),
              isDownloaded(modelID),
              model.languages?.contains(where: { Self.baseCode($0) == language }) == true
        else { return }
        let old = holder.settings.speech.localVoiceByLanguage[language]
        let speaker = old?.modelID == modelID ? old?.speakerID ?? 0 : 0
        let selection = LocalVoiceSelection(
            modelID: modelID,
            speakerID: Self.clampedSpeaker(speaker, model: model))
        holder.settings.speech.localVoiceByLanguage[language] = selection
        auditionLocal(selection, language: language, catalog: catalog)
    }

    func setLocalSpeaker(
        _ speakerID: Int,
        forLanguage language: String,
        catalog: [LocalModel]
    ) {
        let language = Self.baseCode(language)
        guard let selection = localVoice(forLanguage: language, catalog: catalog),
              let model = catalog.first(where: { $0.id == selection.modelID })
        else { return }
        objectWillChange.send()
        let updated = LocalVoiceSelection(
            modelID: selection.modelID,
            speakerID: Self.clampedSpeaker(speakerID, model: model))
        holder.settings.speech.localVoiceByLanguage[language] = updated
        auditionLocal(updated, language: language, catalog: catalog)
    }

    func setDefaultLocalVoice(_ modelID: String, catalog: [LocalModel]) {
        guard let model = catalog.first(where: { $0.id == modelID }), isDownloaded(modelID) else { return }
        objectWillChange.send()
        holder.settings.speech.localModelID = modelID
        holder.settings.speech.localSpeakerID = Self.clampedSpeaker(
            holder.settings.speech.localSpeakerID,
            model: model)
        auditionLocal(
            LocalVoiceSelection(
                modelID: modelID,
                speakerID: holder.settings.speech.localSpeakerID),
            language: model.languages?.first ?? "en",
            catalog: catalog)
    }

    func setDefaultLocalSpeaker(_ speakerID: Int, catalog: [LocalModel]) {
        guard let modelID = holder.settings.speech.localModelID,
              let model = catalog.first(where: { $0.id == modelID }),
              isDownloaded(modelID)
        else { return }
        objectWillChange.send()
        holder.settings.speech.localSpeakerID = Self.clampedSpeaker(speakerID, model: model)
        auditionLocal(
            LocalVoiceSelection(
                modelID: modelID,
                speakerID: holder.settings.speech.localSpeakerID),
            language: model.languages?.first ?? "en",
            catalog: catalog)
    }

    private func auditionLocal(
        _ selection: LocalVoiceSelection,
        language: String,
        catalog: [LocalModel]
    ) {
        guard holder.settings.speech.auditionOnSelect,
              catalog.contains(where: { $0.id == selection.modelID })
        else { return }
        var settings = holder.settings.speech
        settings.source = .local
        settings.localModelID = selection.modelID
        settings.localSpeakerID = selection.speakerID
        settings.localSegmentationEnabled = false
        let language = Self.baseCode(language)
        speech.speak(
            Self.auditionPhrases[language] ?? "This is how I sound.",
            settings: settings)
    }

    private func isDownloaded(_ modelID: String) -> Bool {
        if case .downloaded = modelStates()[modelID] { return true }
        return false
    }

    private static func clampedSpeaker(_ speakerID: Int, model: LocalModel) -> Int {
        min(max(speakerID, 0), max(0, model.speakerCount - 1))
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

/// The active-source selector and its status sit at the top; the three sub-tabs below are pure
/// navigation. Moving between them changes what is on screen and nothing else — only the
/// selector changes what speaks.
struct SpeechTab: View {
    @ObservedObject var model: SpeechTabModel
    @ObservedObject var source: SpeechSourceModel
    @ObservedObject var models: ModelsViewModel
    @ObservedObject var app: AppModel
    @FocusState private var apiKeyFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal)
                .padding(.vertical, 10)

            Divider()

            Picker("", selection: $source.viewedTab) {
                ForEach(SpeechSource.allCases) { candidate in
                    Text(candidate.displayName).tag(candidate)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top])

            Form {
                switch source.viewedTab {
                case .system: systemSection
                case .local: localSection
                case .endpoint: endpointSection
                }
                footerSection
            }
            .formStyle(.grouped)
        }
        .task {
            await models.refresh()
            source.adopt(models.rows)
        }
        .onChange(of: models.rows) { _, rows in source.adopt(rows) }
    }

    // MARK: - Selector and status

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            Picker("Active speech source", selection: activeSource) {
                ForEach(SpeechSource.allCases) { candidate in
                    Text(source.name(of: candidate)).tag(candidate)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            statusBlock
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var isReady: Bool { source.readiness == .ready }

    /// The only status on this screen, and it describes the selection rather than whichever
    /// sub-tab happens to be open — for the reason the Dictation tab gives: two status blocks
    /// answer "what happens on the hotkey" twice with no way to tell which answer is real.
    private var statusBlock: some View {
        HStack(alignment: .top, spacing: 8) {
            Icon(isReady ? .success : .warning, size: 14)
                .foregroundStyle(isReady ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.statusHeadline)
                    .font(.callout.weight(.semibold))
                Text(source.statusDetail)
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
        if case .notReady(_, let fix) = source.readiness, let fix {
            switch fix {
            case .downloadModel(let id):
                Button("Download") {
                    source.reveal(.local)
                    models.download(id)
                }
            case .selectModel:
                Button("Choose a voice") { source.reveal(.local) }
            case .fillEndpoint:
                Button("Configure") { source.reveal(.endpoint) }
            case .saveKey:
                Button("Add a key") {
                    source.reveal(.endpoint)
                    apiKeyFocused = true
                }
            }
        }
    }

    private var activeSource: Binding<SpeechSource> {
        Binding(get: { source.activeSource }, set: { source.activate($0) })
    }

    // MARK: - System voices

    private var systemSection: some View {
        Section("System voices") {
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

            // The heading is inside the disabled container, not beside it: attached to the
            // rows alone it stayed at full contrast over a greyed-out list.
            VStack(alignment: .leading, spacing: 8) {
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

    // MARK: - Local TTS

    /// Two sibling `Section`s — one for the catalog, one for a selected voice's parameters —
    /// which only compiles as a view body with `@ViewBuilder`.
    @ViewBuilder
    private var localSection: some View {
        Section("Voices") {
            if source.ttsModels.isEmpty {
                Text("No local voices are available in this build yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(SpeechTabModel.localCatalogGroups(source.ttsModels)) { group in
                Text(group.displayName).font(.headline)
                ForEach(group.models) { entry in
                    localVoiceRow(entry)
                }
            }
        }

        if let selected = source.selectedModel {
            Section("Parameters") {
                if selected.speakerCount > 1 {
                    Picker("Speaker", selection: Binding(
                        get: { app.settings.speech.localSpeakerID },
                        set: { model.setDefaultLocalSpeaker($0, catalog: source.ttsModels) })) {
                        ForEach(0..<selected.speakerCount, id: \.self) { id in
                            Text("Speaker \(id)").tag(id)
                        }
                    }
                }
                HStack {
                    Text("Speed")
                    Slider(value: $app.settings.speech.localSpeed, in: 0.5...2.0)
                }
            }
        }

        Section("Mixed-language text") {
            Toggle("Switch voices for mixed-language text",
                   isOn: $app.settings.speech.localSegmentationEnabled)
            Text("Each language run uses its downloaded local voice. Auto prefers the "
                 + "selected default when it supports that language, then another "
                 + "downloaded compatible voice.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if app.settings.speech.localSegmentationEnabled {
                let groups = model.downloadedLocalGroups(catalog: source.ttsModels)
                if groups.isEmpty {
                    Text("Download a local voice to map it to a language.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Voice per language").font(.headline)
                    ForEach(groups) { group in
                        localVoiceMappingRow(group)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func localVoiceMappingRow(_ group: SpeechTabModel.LocalVoiceGroup) -> some View {
        Picker(group.displayName, selection: Binding(
            get: { model.localVoice(forLanguage: group.language, catalog: source.ttsModels)?.modelID },
            set: { model.setLocalVoice(
                $0,
                forLanguage: group.language,
                catalog: source.ttsModels)
            })) {
                Text("Auto").tag(String?.none)
                ForEach(group.models) { entry in
                    Text(entry.displayName).tag(Optional(entry.id))
                }
            }

        if let selection = model.localVoice(forLanguage: group.language, catalog: source.ttsModels),
           let selected = group.models.first(where: { $0.id == selection.modelID }),
           selected.speakerCount > 1 {
            Picker("Speaker for \(group.displayName)", selection: Binding(
                get: { selection.speakerID },
                set: { model.setLocalSpeaker(
                    $0,
                    forLanguage: group.language,
                    catalog: source.ttsModels)
                })) {
                    ForEach(0..<selected.speakerCount, id: \.self) { id in
                        Text("Speaker \(id)").tag(id)
                    }
                }
        }
    }

    @ViewBuilder
    private func localVoiceRow(_ entry: LocalModel) -> some View {
        let state = models.rows.first { $0.id == entry.id }?.state
        let chosen = app.settings.speech.localModelID == entry.id

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.displayName)
                            .fontWeight(chosen ? .semibold : .regular)
                        if chosen { chosenBadge }
                    }
                    Text("\(ModelsViewModel.sizeText(entry.totalSizeBytes)) · "
                         + entry.languagesText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    if !chosen, case .downloaded = state {
                        Button("Use this voice") {
                            model.setDefaultLocalVoice(entry.id, catalog: source.ttsModels)
                        }
                    }
                    localStateView(entry.id, state)
                }
            }
            ModelBriefView(brief: entry.brief)
        }
        .padding(.vertical, 4)
    }

    private var chosenBadge: some View {
        Text("Chosen")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
    }

    @ViewBuilder
    private func localStateView(_ id: String, _ state: ModelState?) -> some View {
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

    // MARK: - Endpoint

    private var endpointSection: some View {
        Section("Endpoint") {
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
                .focused($apiKeyFocused)
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

            Text(SpeechTabModel.endpointPrivacyCaption)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Keeps the last valid URL when the user is mid-edit and the text does not parse.
    private var baseURLSelection: Binding<String> {
        Binding(get: { app.settings.speech.endpointBaseURL.absoluteString },
                set: { newValue in
                    guard let url = URL(string: newValue) else { return }
                    app.settings.speech.endpointBaseURL = url
                })
    }

    // MARK: - Preview

    private var footerSection: some View {
        Section {
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
        } header: {
            Text("Preview")
        } footer: {
            Text("Preview speaks through the active source, so it is what the hotkey will sound like.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
