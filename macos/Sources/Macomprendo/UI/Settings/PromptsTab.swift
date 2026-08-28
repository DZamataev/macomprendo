import SwiftUI

@MainActor final class PromptsTabModel: ObservableObject {
    static let sampleText = """
        so um i think we should probably ship the thing on friday, uh, unless the tests \
        are still red — anyway can you tell marta and also book the room
        """

    @Published var kind: PresetKind = .refine {
        didSet { if kind != oldValue { select(presets.first?.id) } }
    }
    /// The working language for this tab. Its writer arrives in Task 6.
    @Published private(set) var language: PromptLanguage = .english
    @Published private(set) var selectedID: UUID?
    @Published var draft: PromptPreset?
    @Published private(set) var problems: [String] = []
    @Published private(set) var testOutput: String = ""
    @Published private(set) var isTesting = false
    @Published private(set) var testError: String?
    @Published private(set) var availableModels: [String] = []
    @Published private(set) var modelsError: String?
    @Published var lastError: String?

    private let holder: any SettingsHolding
    private let llm: @MainActor (PresetKind) throws -> LLMTarget
    private var testTask: Task<Void, Never>?
    private var testGeneration = 0

    init(holder: any SettingsHolding,
         llm: @escaping @MainActor (PresetKind) throws -> LLMTarget) {
        self.holder = holder
        self.llm = llm
        language = PromptLanguage.resolve(languageCode: holder.settings.promptLanguage)
        select(holder.settings.presets(of: kind, language: language.code).first?.id)
    }

    var presets: [PromptPreset] { holder.settings.presets(of: kind, language: language.code) }

    var defaultPresetID: UUID? { holder.settings.defaultPresetID(for: kind, language: language.code) }

    /// The endpoint + model chosen for the current feature.
    var selection: LLMSelection? {
        get {
            switch kind {
            case .refine: holder.settings.refineLLM
            case .summarize: holder.settings.summarizeLLM
            }
        }
        set {
            switch kind {
            case .refine: holder.settings.refineLLM = newValue
            case .summarize: holder.settings.summarizeLLM = newValue
            }
        }
    }

    // MARK: Selection & editing

    func select(_ id: UUID?) {
        selectedID = id
        draft = id.flatMap { holder.settings.preset(id: $0) }
        problems = draft.map { PromptRenderer.validate($0) } ?? []
        lastError = nil
    }

    func save() {
        guard let draft else { return }
        holder.settings.updatePreset(draft)
        problems = PromptRenderer.validate(draft)
    }

    func add() {
        let new = PromptPreset(id: UUID(), kind: kind, language: language.code, name: "New preset",
                               systemPrompt: FactoryPresets.systemPrompt,
                               userTemplate: "{instruction}\n\n{text}",
                               isFactory: false, sortOrder: 0)
        let stored = holder.settings.addPreset(new)
        select(stored.id)
    }

    func duplicate() {
        guard let source = draft else { return }
        var copy = source
        copy.id = UUID()
        copy.language = language.code
        copy.name = source.name + " copy"
        copy.isFactory = false
        let stored = holder.settings.addPreset(copy)
        select(stored.id)
    }

    func delete() {
        guard let id = selectedID else { return }
        do {
            try holder.settings.deletePreset(id: id)
            select(presets.first?.id)
        } catch {
            lastError = ErrorText.describe(error)
        }
    }

    func move(from offsets: IndexSet, to destination: Int) {
        guard let from = offsets.first else { return }
        let ordered = presets
        guard from < ordered.count else { return }
        holder.settings.movePreset(id: ordered[from].id,
                                   to: destination > from ? destination - 1 : destination)
    }

    func makeDefault() {
        guard let id = selectedID else { return }
        holder.settings.setDefaultPreset(id: id, for: kind, language: language.code)
    }

    func restoreFactory() {
        var settings = holder.settings
        FactoryPresets.restoreMissing(into: &settings)
        holder.settings = settings
        select(selectedID ?? presets.first?.id)
    }

    // MARK: Test run

    func runTest() {
        guard let draft else { return }
        testTask?.cancel()
        testGeneration += 1
        let generation = testGeneration
        testOutput = ""
        testError = nil
        isTesting = true
        let prompt = PromptRenderer.render(draft, text: Self.sampleText,
                                           instruction: nil, language: nil)
        let kind = self.kind
        testTask = Task { [weak self] in
            await self?.runTestStream(prompt: prompt, kind: kind, generation: generation)
        }
    }

    private func runTestStream(prompt: RenderedPrompt, kind: PresetKind, generation: Int) async {
        defer { if generation == testGeneration { isTesting = false } }
        do {
            let target = try llm(kind)
            for try await delta in target.provider.chat(prompt.messages, model: target.model,
                                                        options: ChatOptions()) {
                guard generation == testGeneration else { return }
                testOutput += delta
            }
        } catch is CancellationError {
        } catch {
            if generation == testGeneration { testError = ErrorText.describe(error) }
        }
    }

    func stopTest() {
        testTask?.cancel()
        isTesting = false
    }

    /// Awaits the in-flight test stream. Used by tests.
    func drainTest() async {
        _ = await testTask?.value
    }

    func loadModels() async {
        do {
            availableModels = try await llm(kind).provider.listModels()
            modelsError = nil
        } catch {
            availableModels = []
            modelsError = ErrorText.describe(error)
        }
    }
}

struct PromptsTab: View {
    @ObservedObject var model: PromptsTabModel
    @ObservedObject var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Feature", selection: $model.kind) {
                ForEach(PresetKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            endpointRow

            HStack(alignment: .top, spacing: 12) {
                presetList
                editor
            }
        }
        .padding(20)
        .task(id: model.kind) { await model.loadModels() }
    }

    private var endpointRow: some View {
        HStack {
            Picker("Endpoint", selection: endpointBinding) {
                ForEach(app.settings.endpoints) { endpoint in
                    Text(endpoint.name).tag(Optional(endpoint.id))
                }
            }
            .frame(width: 240)

            Picker("Model", selection: modelBinding) {
                ForEach(model.availableModels, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .frame(width: 260)

            Button("Reload") { Task { await model.loadModels() } }

            if let error = model.modelsError {
                Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2)
            }
        }
    }

    private var presetList: some View {
        VStack(spacing: 6) {
            List(selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
                ForEach(model.presets) { preset in
                    HStack {
                        Text(preset.name)
                        if preset.id == model.defaultPresetID {
                            Text("DEFAULT").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .tag(preset.id)
                }
                .onMove { model.move(from: $0, to: $1) }
            }
            .frame(width: 220)
            .frame(minHeight: 260)

            HStack {
                Button("＋") { model.add() }.help("Add a preset")
                Button("⧉") { model.duplicate() }.help("Duplicate")
                Button("－") { model.delete() }.help("Delete")
                Spacer()
                Button("Make default") { model.makeDefault() }
            }
            .font(.caption)

            Button("Restore factory presets") { model.restoreFactory() }
                .font(.caption)

            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private var editor: some View {
        if let draft = Binding($model.draft) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Name", text: draft.name)
                    .onSubmit { model.save() }

                Text("System prompt").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: draft.systemPrompt)
                    .frame(height: 70)
                    .border(.separator)

                Text("User template — must contain {text}; may use {instruction} and {language}")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: draft.userTemplate)
                    .frame(height: 110)
                    .border(.separator)

                if model.problems.isEmpty {
                    Text("Template looks good.").font(.caption).foregroundStyle(.green)
                } else {
                    ForEach(model.problems, id: \.self) { problem in
                        Text(problem).font(.caption).foregroundStyle(.red)
                    }
                }

                HStack {
                    Button("Save") { model.save() }
                    if model.isTesting {
                        Button("Stop") { model.stopTest() }
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Test with sample text") { model.save(); model.runTest() }
                    }
                }

                Text(model.testError ?? model.testOutput)
                    .font(.callout)
                    .foregroundStyle(model.testError == nil ? Color.primary : Color.red)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
                    .textSelection(.enabled)
                    .padding(6)
                    .background(Color.secondary.opacity(0.08))
            }
        } else {
            Text("Select a preset.").foregroundStyle(.secondary)
        }
    }

    private var endpointBinding: Binding<UUID?> {
        Binding(get: { model.selection?.endpointID },
                set: { id in
                    guard let id else { return }
                    model.selection = LLMSelection(endpointID: id,
                                                   model: model.selection?.model ?? "")
                })
    }

    private var modelBinding: Binding<String> {
        Binding(get: { model.selection?.model ?? "" },
                set: { name in
                    guard let endpointID = model.selection?.endpointID
                            ?? app.settings.endpoints.first?.id else { return }
                    model.selection = LLMSelection(endpointID: endpointID, model: name)
                })
    }
}
