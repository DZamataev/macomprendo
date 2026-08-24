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
    private let escapeMonitor: any EscapeMonitoring

    private var target: FrontmostApp?
    private var startedAt: Date?
    private var levelTask: Task<Void, Never>?
    private var autoStopTask: Task<Void, Never>?
    private(set) var activeTask: Task<Void, Never>?

    // Guards against ever starting a second `insert()` while one is still running.
    // `insert()` is deliberately non-cooperative with `cancel()` (it must run to
    // completion to guarantee the pasteboard gets restored), so `cancel()` alone
    // cannot stop it — this flag is what stops a *new* dictation cycle from
    // reaching its own `insert()` call while a stale one from a cancelled cycle
    // is still finishing in the background.
    private var isInserting = false

    // The recorder `stop()` that `cancel()` kicks off is deliberately unawaited there
    // (cancel() must return synchronously), but a `start()` from a fast restart must
    // not race it — `AVAudioEngineRecorder.start()` traps/fails if a tap is already
    // installed. `begin()`'s flow awaits this before calling `recorder.start()`.
    private var pendingStopTask: Task<Void, Never>?

    init(recorder: any AudioRecording,
         transcriberProvider: @escaping @Sendable () async throws -> any TranscriptionProvider,
         inserter: any TextInserting,
         tracker: any FrontmostAppTracking,
         permissions: any PermissionsChecking,
         hud: HUDController,
         pasteboard: any PasteboardProtocol,
         settings: @escaping @MainActor () -> Settings,
         escapeMonitor: any EscapeMonitoring) {
        self.recorder = recorder
        self.transcriberProvider = transcriberProvider
        self.inserter = inserter
        self.tracker = tracker
        self.permissions = permissions
        self.hud = hud
        self.pasteboard = pasteboard
        self.settings = settings
        self.escapeMonitor = escapeMonitor
        escapeMonitor.onEscape = { [weak self] in self?.cancel() }

        // One long-lived consumer each: an `AsyncStream` can only be iterated once, so
        // both tasks live as long as the controller and filter/react by state instead.
        // `level` is never finished by the recorder (a capped recording must not be the
        // last one that ever reports a level), so this loop is never expected to end.
        levelTask = Task { [weak self, recorder] in
            for await level in recorder.level {
                guard let self else { return }
                self.onLevel(level)
            }
        }
        // Fires when the recorder auto-stops after hitting its maximum duration — the
        // only signal that a session ended without an explicit `stop()` call. Treat it
        // exactly like a keyUp/second-press stop so transcription proceeds and the HUD
        // leaves `.recording` instead of sitting frozen. `finish()` already no-ops unless
        // `state == .recording`, so this can never double-finish a session that already
        // ended through the normal hotkey path.
        autoStopTask = Task { [weak self, recorder] in
            for await _ in recorder.autoStopped {
                self?.finish()
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
        escapeMonitor.stop()
        if wasRecording {
            let recorder = self.recorder
            pendingStopTask = Task { _ = await recorder.stop() }
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
        // A cancel() just before this begin() may still be stopping the recorder;
        // starting again before that stop lands can fail (or, worse, race) against it.
        await pendingStopTask?.value
        pendingStopTask = nil
        target = tracker.capture()
        do {
            try await recorder.start()
        } catch {
            fail(error)
            return
        }
        startedAt = Date()
        state = .recording
        // Leaving `.idle`: the HUD's cancel hint needs Esc to actually do something.
        // Stopped again wherever the cycle reaches a terminal `.idle`/`.failed` state below.
        escapeMonitor.start()
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
                escapeMonitor.stop()
                hud.toast("Nothing heard")
                return
            }

            state = .inserting
            isInserting = true
            let insertOutcome: Result<Void, Error>
            do {
                try await inserter.insert(text, into: target, method: settings().insertMethod)
                insertOutcome = .success(())
            } catch {
                insertOutcome = .failure(error)
            }
            isInserting = false

            // `insert()` is deliberately non-cooperative with cancellation — it must run
            // to completion so the pasteboard restore isn't skipped — so a `cancel()`
            // mid-insert doesn't stop the paste, it only stops *this task* from acting on
            // the result afterwards. `cancel()` has already set state to `.idle` and shown
            // the "Cancelled" toast synchronously; touching either here would overwrite it
            // with a stale "Inserted"/"Copied to clipboard" outcome the user has already
            // moved past.
            guard !Task.isCancelled else { return }

            switch insertOutcome {
            case .success:
                state = .idle
                target = nil
                escapeMonitor.stop()
                hud.show(.success("Inserted"))
            case .failure(MacomprendoError.insertFailed):
                // `PasteTextInserter` throws `insertFailed` before it ever writes to the
                // pasteboard when it cannot re-activate the target app, but its recovery
                // text promises "the text is on the clipboard" — make that true here so
                // the fallback is a genuine copy, not just a claim.
                copyFallback(text)
            case .failure(let error):
                fail(error)
            }
        } catch is CancellationError {
            cancelledInFlight()
        } catch MacomprendoError.cancelled {
            // `HTTPClient` maps both `CancellationError` and `URLError.cancelled` here, so
            // this can arrive even when `cancel()` was never called (this task itself isn't
            // cancelled) — e.g. a transport-level cancellation the provider originated. Treat
            // it exactly like the cooperative-cancellation path above: whichever one got here
            // first is what matters, not which error type carried it.
            cancelledInFlight()
        } catch {
            fail(error)
        }
    }

    // Every terminal transition stops the monitor. `cancel()` already does this
    // synchronously (and shows the "Cancelled" toast) when it's the one that triggered
    // this cancellation — by the time this runs, `state` is already `.idle` and there's
    // nothing left to do. But a provider can throw a cancellation error on its own
    // (see the `MacomprendoError.cancelled` catch above), in which case `cancel()` never
    // ran: the monitor would otherwise keep swallowing Esc app-wide and the HUD would sit
    // stuck on `.transcribing` forever. Cover that case too, without re-toasting or
    // stopping an already-stopped monitor twice worth caring about (`stop()` is
    // idempotent).
    private func cancelledInFlight() {
        escapeMonitor.stop()
        guard state != .idle else { return }
        state = .idle
        hud.toast("Cancelled")
    }

    private func copyFallback(_ text: String) {
        pasteboard.writeString(text)
        let message = ErrorText.describe(MacomprendoError.insertFailed)
        Log.app.error("Dictation failed: \(message, privacy: .public)")
        state = .failed(message)
        target = nil
        escapeMonitor.stop()
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
        escapeMonitor.stop()
        hud.show(.error(message))
    }
}
