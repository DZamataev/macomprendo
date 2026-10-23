import Foundation
import KeyboardShortcuts

/// Listens for the Cancel dictation shortcut (Esc by default) so a feature can let the user
/// cancel with the keyboard alone. `DictationController` starts one while recording/transcribing
/// so the HUD's cancel hint is actually backed by something.
protocol EscapeMonitoring: AnyObject {
    var onEscape: (@MainActor () -> Void)? { get set }
    func start()
    func stop()
}

/// Registers the `.cancelDictation` hotkey only between `start()` and `stop()`: a global
/// hotkey swallows its key, and Esc must reach other apps the rest of the time.
final class GlobalEscapeMonitor: EscapeMonitoring, @unchecked Sendable {
    var onEscape: (@MainActor () -> Void)?
    private var isRunning = false

    func start() {
        MainActor.assumeIsolated {
            guard !isRunning else { return }
            isRunning = true
            KeyboardShortcuts.onKeyDown(for: .cancelDictation) { [weak self] in
                guard let handler = self?.onEscape else { return }
                Task { @MainActor in handler() }
            }
        }
    }

    func stop() {
        MainActor.assumeIsolated {
            guard isRunning else { return }
            isRunning = false
            KeyboardShortcuts.removeHandler(for: .cancelDictation)
        }
    }
}
