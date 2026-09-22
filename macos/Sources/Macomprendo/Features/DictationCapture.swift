import Foundation

/// Microphone → transcript, with the hold/toggle hotkey semantics.
/// Reused by `RefineController` for hotkey #2 (Dictate & Refine).
@MainActor final class DictationCapture {
    enum State: Equatable, Sendable {
        case idle
        case recording
        case transcribing
    }

    private(set) var state: State = .idle
    private(set) var activeMode: DictationMode = .hold

    var onStateChange: (@MainActor (State) -> Void)?
    var onTranscript: (@MainActor (String) -> Void)?
    var onError: (@MainActor (Error) -> Void)?
    var onHistoryError: (@MainActor (MacomprendoError) -> Void)?

    private let recorder: any AudioRecording
    private let transcriberProvider: @Sendable () async throws -> any TranscriptionProvider
    private let permissions: any PermissionsChecking
    private let history: DictationHistoryController
    private let mode: @MainActor () -> DictationMode
    private let language: @MainActor () -> String?
    /// The transcription source in effect, read when the transcript arrives so the row records
    /// the model that actually ran rather than the one selected afterwards.
    private let source: @MainActor () -> TranscriptionSource
    /// The master switch, read when the transcript arrives. While it is off the glossary is
    /// never asked for at all.
    private let isGlossaryEnabled: @MainActor () -> Bool
    /// The glossary in force, read at the same moment, so a pack enabled mid-recording
    /// applies to the transcript that recording produced.
    private let glossary: @MainActor () -> Glossary
    private var task: Task<Void, Never>?
    private var pendingStopTask: Task<Void, Never>?
    private var generation = 0

    init(recorder: any AudioRecording,
         transcriberProvider: @escaping @Sendable () async throws -> any TranscriptionProvider,
         permissions: any PermissionsChecking,
         mode: @escaping @MainActor () -> DictationMode,
         language: @escaping @MainActor () -> String?,
         source: @escaping @MainActor () -> TranscriptionSource,
         history: DictationHistoryController,
         isGlossaryEnabled: @escaping @MainActor () -> Bool = { false },
         glossary: @escaping @MainActor () -> Glossary = { Glossary() }) {
        self.recorder = recorder
        self.transcriberProvider = transcriberProvider
        self.permissions = permissions
        self.history = history
        self.mode = mode
        self.language = language
        self.source = source
        self.isGlossaryEnabled = isGlossaryEnabled
        self.glossary = glossary
    }

    func handle(_ event: HotkeyEvent, mode: DictationMode? = nil) {
        let activeMode = mode ?? self.mode()
        self.activeMode = activeMode
        switch (event, activeMode) {
        case (.keyDown, .hold):
            switch state {
            case .idle: startRecording()
            case .recording: break
            case .transcribing: cancel()
            }
        case (.keyUp, .hold):
            finishRecording()
        case (.keyDown, .toggle):
            switch state {
            case .idle: startRecording()
            case .recording: finishRecording()
            case .transcribing: cancel()
            }
        case (.keyUp, .toggle):
            break
        }
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        let previousStopTask = pendingStopTask
        let recorder = self.recorder
        pendingStopTask = Task {
            _ = await previousStopTask?.value
            _ = await recorder.stop()
        }
        setState(.idle)
    }

    /// Awaits the in-flight capture task. Used by tests and by callers that need to sequence work.
    func drain() async {
        _ = await task?.value
    }

    private func startRecording() {
        guard state == .idle else { return }
        generation += 1
        let generation = generation
        setState(.recording)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let currentStatus = await self.permissions.status(of: .microphone)
                // `cancel()` may have run while the line above was suspended — cooperative
                // cancellation alone doesn't stop this task from resuming and racing on to
                // `recorder.start()` after `cancel()` already kicked off `recorder.stop()`,
                // so every suspension point below must be checked explicitly. Mirrors
                // `DictationController.startRecording()`'s guards.
                guard self.generation == generation, !Task.isCancelled else { return }
                if currentStatus != .granted {
                    let granted = await self.permissions.request(.microphone)
                    guard self.generation == generation, !Task.isCancelled else { return }
                    guard granted == .granted else { throw MacomprendoError.permissionDenied(.microphone) }
                }
                let pendingStopTask = self.pendingStopTask
                await pendingStopTask?.value
                guard self.generation == generation, !Task.isCancelled else { return }
                self.pendingStopTask = nil
                try await self.recorder.start()
                guard self.generation == generation, !Task.isCancelled else { return }
            } catch {
                guard self.generation == generation else { return }
                self.setState(.idle)
                self.onError?(error)
            }
        }
    }

    private func finishRecording() {
        guard state == .recording else { return }
        let generation = generation
        setState(.transcribing)
        let previous = task
        task = Task { [weak self] in
            guard let self else { return }
            _ = await previous?.value              // let start() settle before stopping
            guard self.generation == generation, !Task.isCancelled else { return }
            let samples = await self.recorder.stop()
            do {
                try Task.checkCancellation()
                guard self.generation == generation else { return }
                guard !samples.isEmpty else { throw MacomprendoError.audio("Nothing heard.") }
                // Emptiness and silence are two conditions: these buffers are non-empty and
                // every sample is zero, which a model turns into an invented word rather
                // than into nothing. Stop before the model call.
                guard !AudioMath.isSilent(samples) else { throw MacomprendoError.silentCapture }
                let transcriber = try await self.transcriberProvider()
                guard self.generation == generation else { return }
                let language = self.language()
                let raw = try await transcriber.transcribe(samples, sampleRate: 16_000,
                                                           language: language)
                try Task.checkCancellation()
                guard self.generation == generation else { return }
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw MacomprendoError.audio("Nothing heard.") }
                // The whole result rather than just its text: the rewrites carry the ranges
                // and owning pack a later review panel reads.
                let normalisation = self.isGlossaryEnabled()
                    ? Normalizer.normalise(text, with: self.glossary())
                    : NormalisationResult(text: text, rewrites: [])
                let corrected = normalisation.text
                // `rawText` holds the model's own words only when they differ from what the
                // user gets: the column measures the model against our corrections, and a
                // copy of `text` would claim a correction that never happened.
                let run = TranscriptionRun.from(self.source(), language: language)
                let historyResult = await history.append(
                    text: corrected,
                    rawText: normalisation.rewrites.isEmpty ? nil : text,
                    kind: .dictationAndRefine, run: run)
                try Task.checkCancellation()
                guard self.generation == generation else { return }
                self.setState(.idle)
                if let historyError = historyResult.error {
                    onHistoryError?(historyError)
                }
                self.onTranscript?(corrected)
                let recordingError = await history.saveRecording(samples, for: historyResult.entry)
                guard self.generation == generation, !Task.isCancelled else { return }
                if historyResult.error == nil, let recordingError {
                    onHistoryError?(recordingError)
                }
            } catch {
                guard self.generation == generation else { return }
                self.setState(.idle)
                // `HTTPClient` maps both `CancellationError` and transport-level
                // `URLError.cancelled` to `MacomprendoError.cancelled` — treat that
                // identically to `CancellationError`, matching `DictationController`'s
                // `cancelledInFlight()` handling, so a provider-originated cancellation
                // never surfaces as a user-visible error.
                let isCancellation = error is CancellationError || (error as? MacomprendoError) == .cancelled
                if !isCancellation { self.onError?(error) }
            }
        }
    }

    private func setState(_ new: State) {
        guard state != new else { return }
        state = new
        onStateChange?(new)
    }
}
