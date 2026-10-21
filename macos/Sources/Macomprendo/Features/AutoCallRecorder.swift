import Foundation

/// Polls the audio-process monitor once a second while the setting is on, and drives
/// `CallRecordingController` through its ordinary `toggle()`. It never changes that controller:
/// a recording the user started is not its to stop.
@MainActor
final class AutoCallRecorder {
    private let monitor: any AudioProcessMonitoring
    private let recorder: CallRecordingController
    private let apps: @MainActor () -> [CallApp]
    private let toast: @MainActor (String) -> Void
    private let ownPID: pid_t
    private let now: () -> Date
    private let interval: Duration

    private var policy = AutoCallRecordPolicy()
    private var task: Task<Void, Never>?
    /// The last audio summary logged; the detector logs a change, not every poll.
    private var loggedSummary: String?

    init(monitor: any AudioProcessMonitoring,
         recorder: CallRecordingController,
         apps: @escaping @MainActor () -> [CallApp],
         toast: @escaping @MainActor (String) -> Void,
         ownPID: pid_t = ProcessInfo.processInfo.processIdentifier,
         now: @escaping () -> Date = Date.init,
         interval: Duration = .seconds(1)) {
        self.monitor = monitor
        self.recorder = recorder
        self.apps = apps
        self.toast = toast
        self.ownPID = ownPID
        self.now = now
        self.interval = interval
    }

    var isRunning: Bool { task != nil }

    /// Starts the poll loop; idempotent.
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.interval else { return }
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    /// Cancels the loop and forgets the call in progress. Never stops a recording.
    func stop() {
        task?.cancel()
        task = nil
        policy = AutoCallRecordPolicy()
        loggedSummary = nil
    }

    /// One poll — the loop calls it; tests call it directly.
    func tick() {
        let processes = monitor.snapshot()
        let apps = apps()
        let summary = CallApp.audioSummary(of: processes, apps: apps, excludingPID: ownPID)
        if summary != loggedSummary {
            loggedSummary = summary
            Log.app.notice("Call detector: \(summary, privacy: .public)")
        }
        let call = CallApp.activeCall(in: processes, apps: apps, excludingPID: ownPID)
        switch policy.observe(call, at: now(), recorderBusy: recorder.isRecording) {
        case .start(let app):
            Log.app.notice("Call detector started a recording for \(app.name, privacy: .public)")
            recorder.toggle()
            toast("Recording call — \(app.name)")
        case .stop:
            Log.app.notice("Call detector stopped its recording: the call ended")
            recorder.toggle()
            toast("Call ended — recording stopped")
        case nil:
            break
        }
    }
}
