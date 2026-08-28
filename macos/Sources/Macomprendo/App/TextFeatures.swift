import AppKit
import Foundation

/// Owns hotkeys #2–#5 and the Quick Panel. `AppModel` forwards every non-dictation
/// `HotkeyEvent` here.
@MainActor final class TextFeatures {
    let quickPanel: QuickPanelController
    let refine: RefineController
    let summarize: SummarizeController
    let speak: SpeakController

    private let selectedText: any SelectedTextReading
    private let toaster: any Toasting
    private var task: Task<Void, Never>?

    init(quickPanel: QuickPanelController,
         refine: RefineController,
         summarize: SummarizeController,
         speak: SpeakController,
         selectedText: any SelectedTextReading,
         toaster: any Toasting) {
        self.quickPanel = quickPanel
        self.refine = refine
        self.summarize = summarize
        self.speak = speak
        self.selectedText = selectedText
        self.toaster = toaster
    }

    func handle(_ event: HotkeyEvent) {
        switch event {
        case .keyDown(.dictateAndRefine), .keyUp(.dictateAndRefine):
            refine.handle(event)

        case .keyDown(.refineSelection):
            withSelection { [weak self] text in self?.refine.start(source: .selection(text)) }

        case .keyDown(.summarize):
            withSelection { [weak self] text in self?.summarize.start(text: text) }

        case .keyDown(.speak):
            task?.cancel()
            task = Task { [weak self] in
                guard let self else { return }
                // `toggle` only evaluates the closure when it is about to start speaking, so a
                // second press stops without simulating ⌘C.
                await self.speak.toggle(text: { try await self.selectedText.read() })
            }

        case .keyDown(.dictate), .keyUp(.dictate),
             .keyUp(.speak), .keyUp(.summarize), .keyUp(.refineSelection):
            break
        }
    }

    /// Awaits the in-flight selection read / speech toggle. Used by tests.
    func drain() async {
        _ = await task?.value
    }

    private func withSelection(_ body: @escaping @MainActor (String) -> Void) {
        // Two selection hotkeys within `copyTimeout` of each other would otherwise run two
        // concurrent `readViaCopy` cycles: the second snapshots an already-dirtied
        // pasteboard, and the restore order can replace the user's clipboard with the
        // selection. Cancel any in-flight read before starting a new one — invariant 7,
        // one in-flight task per controller.
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                body(try await self.selectedText.read())
            } catch {
                self.toaster.toast(ErrorText.describe(error), duration: 2.5)
            }
        }
    }
}

extension AppModel {
    /// The provider + model configured for one feature in Settings ▸ Refine & Summarize.
    func llmTarget(for kind: PresetKind) throws -> LLMTarget {
        let selection: LLMSelection?
        switch kind {
        case .refine: selection = settings.refineLLM
        case .summarize: selection = settings.summarizeLLM
        }
        guard let selection, !selection.model.isEmpty,
              let endpoint = settings.endpoints.first(where: { $0.id == selection.endpointID })
        else { throw FeatureConfigError.llmNotConfigured(kind) }
        return LLMTarget(provider: try env.factory.llm(for: endpoint), model: selection.model)
    }
}

extension TextFeatures {
    /// Builds the real object graph, including the floating panel window when the environment
    /// supplies a host factory (it is nil in `AppEnvironment.fake()`, so tests build no windows).
    static func live(model: AppModel,
                     env: AppEnvironment,
                     hud: HUDController,
                     transcriberProvider: @escaping @Sendable () async throws -> any TranscriptionProvider)
        -> TextFeatures {

        let quickPanel = QuickPanelController(holder: model)

        let capture = DictationCapture(
            recorder: env.recorder,
            transcriberProvider: transcriberProvider,
            permissions: env.permissions,
            mode: { model.settings.dictationMode },
            language: { model.settings.transcriptionLanguage })

        let refine = RefineController(
            capture: capture,
            llm: { try model.llmTarget(for: .refine) },
            panel: quickPanel,
            pasteboard: env.pasteboard,
            inserter: env.inserter,
            tracker: env.tracker,
            toaster: hud,
            holder: model)

        let summarize = SummarizeController(
            llm: { try model.llmTarget(for: .summarize) },
            panel: quickPanel,
            pasteboard: env.pasteboard,
            inserter: env.inserter,
            tracker: env.tracker,
            toaster: hud,
            holder: model)

        let speak = SpeakController(speech: env.speech, toaster: hud, settings: { model.settings })

        let selectedText = AXSelectedTextService(ax: env.ax,
                                                 pasteboard: env.pasteboard,
                                                 keySimulator: env.keySimulator)

        let features = TextFeatures(quickPanel: quickPanel, refine: refine, summarize: summarize,
                                    speak: speak, selectedText: selectedText, toaster: hud)

        // The panel's content needs the controllers, so the window is built last and attached.
        if let makeHost = env.quickPanelHost {
            quickPanel.attach(makeHost(QuickPanelView(panel: quickPanel, refine: refine,
                                                      summarize: summarize, speak: speak, app: model)))
        }
        return features
    }
}
