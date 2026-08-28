import Foundation

enum RefineSource: Equatable, Sendable {
    case dictation
    case selection(String)
}

enum RefineSide: Equatable, Sendable {
    case original
    case refined
}

/// Hotkeys #2 (Dictate & Refine) and #5 (Refine selection).
@MainActor final class RefineController: ObservableObject {
    @Published var original: String = ""
    @Published var refined: String = ""
    @Published var isStreaming: Bool = false
    @Published var selectedPresetID: UUID?
    @Published var instruction: String = ""
    @Published var error: String?
    @Published private(set) var isCapturing: Bool = false

    private let capture: DictationCapture
    private let llm: @MainActor () throws -> LLMTarget
    private let panel: QuickPanelController
    private let pasteboard: any PasteboardProtocol
    private let inserter: any TextInserting
    private let tracker: any FrontmostAppTracking
    private let toaster: any Toasting
    private let holder: any SettingsHolding

    private var streamTask: Task<Void, Never>?
    /// Bumped on every re-run so a cancelled stream cannot clobber the new one's state.
    private var streamGeneration = 0
    /// The app that was frontmost when the hotkey fired; Insert pastes back into it.
    private var target: FrontmostApp?

    init(capture: DictationCapture,
         llm: @escaping @MainActor () throws -> LLMTarget,
         panel: QuickPanelController,
         pasteboard: any PasteboardProtocol,
         inserter: any TextInserting,
         tracker: any FrontmostAppTracking,
         toaster: any Toasting,
         holder: any SettingsHolding) {
        self.capture = capture
        self.llm = llm
        self.panel = panel
        self.pasteboard = pasteboard
        self.inserter = inserter
        self.tracker = tracker
        self.toaster = toaster
        self.holder = holder

        capture.onTranscript = { [weak self] text in self?.beginRefine(with: text) }
        capture.onError = { [weak self] error in
            self?.toaster.toast(ErrorText.describe(error), duration: 2.5)
        }
        capture.onStateChange = { [weak self] state in
            guard let self else { return }
            self.isCapturing = state != .idle
            // Drive the toaster — it *is* the HUD (`Toasting.show(_:)/hide()`) — through
            // capture, since `DictationCapture` has no HUD dependency of its own.
            // `HUDState.recording` renders "Release to transcribe · Esc cancels", but Esc
            // is not wired to `DictationCapture`, so showing that hint here would be a
            // false promise: show nothing while recording, only "Transcribing…" once
            // recording stops, matching docs/SMOKE_TEST.md's Dictate & Refine row.
            switch state {
            case .recording: break
            case .transcribing: self.toaster.show(.transcribing)
            case .idle: self.toaster.hide()
            }
        }
    }

    /// The working language for the whole Refine & Summarize feature. Writing it moves the
    /// selection to the new language's default preset and reruns, so one click reprocesses the
    /// same text with the other language's prompt set.
    var promptLanguage: String {
        get { holder.settings.promptLanguage }
        set {
            guard holder.settings.promptLanguage != newValue else { return }
            objectWillChange.send()
            holder.settings.promptLanguage = newValue
            selectedPresetID = holder.settings.defaultPreset(for: .refine, language: newValue)?.id
            rerun()
        }
    }

    // MARK: Starting

    /// Hold/toggle routing for hotkey #2.
    func handle(_ event: HotkeyEvent) {
        if case .keyDown = event { target = tracker.capture() }
        capture.handle(event)
    }

    func start(source: RefineSource) {
        switch source {
        case .dictation:
            target = tracker.capture()
            capture.handle(.keyDown(.dictateAndRefine))
        case .selection(let text):
            target = tracker.capture()
            beginRefine(with: text)
        }
    }

    private func beginRefine(with text: String) {
        original = text.trimmingCharacters(in: .whitespacesAndNewlines)
        refined = ""
        error = nil
        if selectedPresetID == nil {
            selectedPresetID = holder.settings.defaultPreset(for: .refine, language: holder.settings.promptLanguage)?.id
        }
        panel.present(layout: .refine)
        rerun()
    }

    // MARK: Streaming

    func rerun() {
        streamTask?.cancel()
        streamGeneration += 1
        let generation = streamGeneration
        isStreaming = true
        refined = ""
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

    /// Awaits the in-flight microphone capture. Used by tests.
    func drainCapture() async {
        await capture.drain()
    }

    private func runStream(generation: Int) async {
        defer { if generation == streamGeneration { isStreaming = false } }
        let current = holder.settings

        let chosen: PromptPreset?
        if let id = selectedPresetID, let found = current.preset(id: id), found.kind == .refine {
            chosen = found
        } else {
            chosen = current.defaultPreset(for: .refine, language: current.promptLanguage)
        }
        guard let preset = chosen else {
            error = ErrorText.describe(FeatureConfigError.noPreset(.refine))
            return
        }

        let problems = PromptRenderer.validate(preset)
        guard problems.isEmpty else {
            error = problems.joined(separator: " ")
            return
        }

        let prompt = PromptRenderer.render(preset, text: original,
                                           instruction: instruction,
                                           language: Self.uiLanguageName())
        do {
            let target = try llm()
            for try await delta in target.provider.chat(prompt.messages, model: target.model,
                                                        options: ChatOptions()) {
                guard generation == streamGeneration else { return }
                refined += delta
            }
        } catch is CancellationError {
            // The user pressed Stop or started a re-run: keep whatever streamed so far.
        } catch MacomprendoError.cancelled {
        } catch {
            if generation == streamGeneration { self.error = ErrorText.describe(error) }
        }
    }

    /// Target language for the Translate preset: the app's UI language unless the user types
    /// something else into the instruction field.
    static func uiLanguageName() -> String {
        let locale = Locale.current
        guard let code = locale.language.languageCode?.identifier,
              let name = locale.localizedString(forLanguageCode: code)
        else { return PromptRenderer.defaultLanguage }
        return name
    }

    // MARK: Actions

    func copy(_ side: RefineSide) {
        pasteboard.writeString(text(for: side))
        toaster.toast("Copied.", duration: 1.2)
    }

    func insert(_ side: RefineSide) async {
        let value = text(for: side)
        guard !value.isEmpty else {
            toaster.toast("Nothing to insert yet.", duration: 1.5)
            return
        }
        do {
            try await inserter.insert(value, into: target, method: holder.settings.insertMethod)
            panel.dismiss()
        } catch {
            toaster.toast(ErrorText.describe(error), duration: 2.5)
        }
    }

    private func text(for side: RefineSide) -> String {
        switch side {
        case .original: original
        case .refined: refined
        }
    }
}
