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
    private var task: Task<Void, Never>?
    private var pendingStopTask: Task<Void, Never>?
    private var generation = 0

    init(recorder: any AudioRecording,
         transcriberProvider: @escaping @Sendable () async throws -> any TranscriptionProvider,
         permissions: any PermissionsChecking,
         mode: @escaping @MainActor () -> DictationMode,
         language: @escaping @MainActor () -> String?,
         history: DictationHistoryController) {
        self.recorder = recorder
        self.transcriberProvider = transcriberProvider
        self.permissions = permissions
        self.history = history
        self.mode = mode
        self.language = language
    }

    func handle(_ event: HotkeyEvent) {
        switch (event, mode()) {
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
        let recorder = self.recorder
        pendingStopTask = Task { _ = await recorder.stop() }
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
                let transcriber = try await self.transcriberProvider()
                guard self.generation == generation else { return }
                let raw = try await transcriber.transcribe(samples, sampleRate: 16_000,
                                                           language: self.language())
                try Task.checkCancellation()
                guard self.generation == generation else { return }
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw MacomprendoError.audio("Nothing heard.") }
                let historyError = await history.record(text: text, kind: .dictationAndRefine)
                try Task.checkCancellation()
                guard self.generation == generation else { return }
                self.setState(.idle)
                if let historyError {
                    onHistoryError?(historyError)
                }
                self.onTranscript?(text)
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
