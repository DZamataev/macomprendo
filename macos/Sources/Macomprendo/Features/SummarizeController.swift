import Foundation

/// Hotkey #4. Selected text in, streamed summary out, Copy or Replace selection.
@MainActor final class SummarizeController: ObservableObject, PromptLanguageSwitching {
    let presetKind = PresetKind.summarize
    var settingsHolder: any SettingsHolding { holder }

    @Published var source: String = ""
    @Published var summary: String = ""
    @Published var isStreaming: Bool = false
    @Published var selectedPresetID: UUID?
    @Published var instruction: String = ""
    @Published var error: String?

    private let llm: @MainActor () throws -> LLMTarget
    private let panel: QuickPanelController
    private let pasteboard: any PasteboardProtocol
    private let inserter: any TextInserting
    private let tracker: any FrontmostAppTracking
    private let toaster: any Toasting
    private let holder: any SettingsHolding

    private var streamTask: Task<Void, Never>?
    private var streamGeneration = 0
    private var target: FrontmostApp?

    init(llm: @escaping @MainActor () throws -> LLMTarget,
         panel: QuickPanelController,
         pasteboard: any PasteboardProtocol,
         inserter: any TextInserting,
         tracker: any FrontmostAppTracking,
         toaster: any Toasting,
         holder: any SettingsHolding) {
        self.llm = llm
        self.panel = panel
        self.pasteboard = pasteboard
        self.inserter = inserter
        self.tracker = tracker
        self.toaster = toaster
        self.holder = holder
    }

    func start(text: String) {
        target = tracker.capture()
        source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        summary = ""
        error = nil
        refreshSelectedPreset()
        panel.present(layout: .summary)
        rerun()
    }

    func rerun() {
        streamTask?.cancel()
        streamGeneration += 1
        let generation = streamGeneration
        isStreaming = true
        summary = ""
        error = nil
        streamTask = Task { [weak self] in await self?.runStream(generation: generation) }
    }

    func stop() {
        streamTask?.cancel()
        isStreaming = false
    }

    /// Awaits the in-flight stream. Used by tests.
    func drain() async {
        _ = await streamTask?.value
    }

    private func runStream(generation: Int) async {
        defer { if generation == streamGeneration { isStreaming = false } }
        guard let preset = activePreset else {
            error = ErrorText.describe(FeatureConfigError.noPreset(.summarize))
            return
        }

        let problems = PromptRenderer.validate(preset)
        guard problems.isEmpty else {
            error = problems.joined(separator: " ")
            return
        }

        let prompt = PromptRenderer.render(
            preset, text: source,
            instruction: instruction,
            language: RefineController.uiLanguageName(),
            chosenLanguage: holder.settings.translationTarget.resolvedName(
                promptLanguage: holder.settings.promptLanguage,
                systemLanguageCode: TranslationTarget.currentSystemLanguageCode))
        do {
            let target = try llm()
            for try await delta in target.provider.chat(prompt.messages, model: target.model,
                                                        options: ChatOptions()) {
                guard generation == streamGeneration else { return }
                summary += delta
            }
        } catch is CancellationError {
        } catch MacomprendoError.cancelled {
        } catch {
            if generation == streamGeneration { self.error = ErrorText.describe(error) }
        }
    }

    func copy() {
        pasteboard.writeString(summary)
        toaster.toast("Copied.", duration: 1.2)
    }

    /// The selection is still selected in the source app, so pasting replaces it.
    func replaceSelection() async {
        guard !summary.isEmpty else {
            toaster.toast("Nothing to insert yet.", duration: 1.5)
            return
        }
        do {
            try await inserter.insert(summary, into: target, method: holder.settings.insertMethod)
            panel.dismiss()
        } catch {
            toaster.toast(ErrorText.describe(error), duration: 2.5)
        }
    }
}
