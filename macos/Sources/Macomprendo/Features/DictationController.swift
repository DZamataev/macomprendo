import Foundation
import SwiftUI

enum DictationState: Equatable, Sendable {
    case idle
    case recording
    case transcribing
    case inserting
    case failed(String)
}

/// Hotkey #1: record while the hotkey is held (or between two presses in toggle mode),
/// transcribe, and paste the result into the app that was frontmost when recording began.
@MainActor
final class DictationController: ObservableObject {
    @Published private(set) var state: DictationState = .idle

    private let recorder: any AudioRecording
    private let transcriberProvider: @Sendable () async throws -> any TranscriptionProvider
    private let inserter: any TextInserting
    private let tracker: any FrontmostAppTracking
    private let permissions: any PermissionsChecking
    private let hud: HUDController
    private let pasteboard: any PasteboardProtocol
    private let settings: @MainActor () -> Settings

    private var target: FrontmostApp?
    private var startedAt: Date?
    private var levelTask: Task<Void, Never>?
    private(set) var activeTask: Task<Void, Never>?

    // Guards against ever starting a second `insert()` while one is still running.
    // `insert()` is deliberately non-cooperative with `cancel()` (it must run to
    // completion to guarantee the pasteboard gets restored), so `cancel()` alone
    // cannot stop it — this flag is what stops a *new* dictation cycle from
    // reaching its own `insert()` call while a stale one from a cancelled cycle
    // is still finishing in the background.
    private var isInserting = false

    init(recorder: any AudioRecording,
         transcriberProvider: @escaping @Sendable () async throws -> any TranscriptionProvider,
         inserter: any TextInserting,
         tracker: any FrontmostAppTracking,
         permissions: any PermissionsChecking,
         hud: HUDController,
         pasteboard: any PasteboardProtocol,
         settings: @escaping @MainActor () -> Settings) {
        self.recorder = recorder
        self.transcriberProvider = transcriberProvider
        self.inserter = inserter
        self.tracker = tracker
        self.permissions = permissions
        self.hud = hud
        self.pasteboard = pasteboard
        self.settings = settings

        // One long-lived consumer: an `AsyncStream` can only be iterated once, so the
        // level task lives as long as the controller and filters by state instead.
        levelTask = Task { [weak self, recorder] in
            for await level in recorder.level {
                guard let self else { return }
                self.onLevel(level)
            }
        }
    }

    func handle(_ event: HotkeyEvent) {
        guard event.action == .dictate else { return }
        switch (settings().dictationMode, event) {
        case (.hold, .keyDown):
            switch state {
            case .idle, .failed: begin()
            case .recording: break
            case .transcribing, .inserting: cancel()
            }
        case (.hold, .keyUp):
            if state == .recording { finish() }
        case (.toggle, .keyDown):
            switch state {
            case .idle, .failed: begin()
            case .recording: finish()
            case .transcribing, .inserting: cancel()
            }
        case (.toggle, .keyUp):
            break
        }
    }

    func cancel() {
        let wasRecording = state == .recording
        activeTask?.cancel()
        activeTask = nil
        state = .idle
        startedAt = nil
        target = nil
        if wasRecording {
            let recorder = self.recorder
            Task { _ = await recorder.stop() }
        }
        hud.toast("Cancelled")
    }

    // MARK: - Steps

    private func begin() {
        // Never start a new recording — and so never reach a new `insert()` call —
        // while a previous cycle's insert is still running in the background.
        guard !isInserting else { return }
        activeTask?.cancel()
        activeTask = Task { [weak self] in await self?.startRecording() }
    }

    private func startRecording() async {
        guard await ensurePermission(.microphone), await ensurePermission(.accessibility) else { return }
        target = tracker.capture()
        do {
            try await recorder.start()
        } catch {
            fail(error)
            return
        }
        startedAt = Date()
        state = .recording
        hud.show(.recording(level: 0, elapsed: 0))
    }

    private func finish() {
        guard state == .recording else { return }
        state = .transcribing
        hud.show(.transcribing)
        activeTask = Task { [weak self] in await self?.transcribeAndInsert() }
    }

    private func transcribeAndInsert() async {
        let pcm = await recorder.stop()
        startedAt = nil
        do {
            try Task.checkCancellation()
            let provider = try await transcriberProvider()
            let language = settings().transcriptionLanguage
            let raw = try await provider.transcribe(pcm,
                                                    sampleRate: Int(AVAudioEngineRecorder.targetSampleRate),
                                                    language: language)
            try Task.checkCancellation()

            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                state = .idle
                hud.toast("Nothing heard")
                return
            }

            state = .inserting
            do {
                isInserting = true
                defer { isInserting = false }
                try await inserter.insert(text, into: target, method: settings().insertMethod)
            } catch MacomprendoError.insertFailed {
                // `PasteTextInserter` throws `insertFailed` before it ever writes to the
                // pasteboard when it cannot re-activate the target app, but its recovery
                // text promises "the text is on the clipboard" — make that true here so
                // the fallback is a genuine copy, not just a claim.
                copyFallback(text)
                return
            }

            state = .idle
            target = nil
            hud.show(.success("Inserted"))
        } catch is CancellationError {
            state = .idle
        } catch MacomprendoError.cancelled {
            state = .idle
        } catch {
            fail(error)
        }
    }

    private func copyFallback(_ text: String) {
        pasteboard.writeString(text)
        let message = ErrorText.describe(MacomprendoError.insertFailed)
        Log.app.error("Dictation failed: \(message, privacy: .public)")
        state = .failed(message)
        target = nil
        hud.toast("Copied to clipboard")
    }

    private func ensurePermission(_ kind: PermissionKind) async -> Bool {
        var status = await permissions.status(of: kind)
        if status != .granted {
            status = await permissions.request(kind)
        }
        guard status == .granted else {
            permissions.openSystemSettings(for: kind)
            fail(MacomprendoError.permissionDenied(kind))
            return false
        }
        return true
    }

    private func onLevel(_ level: Float) {
        guard state == .recording else { return }
        let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        hud.show(.recording(level: level, elapsed: elapsed))
    }

    private func fail(_ error: Error) {
        let message = ErrorText.describe(error)
        Log.app.error("Dictation failed: \(message, privacy: .public)")
        state = .failed(message)
        hud.show(.error(message))
    }
}
