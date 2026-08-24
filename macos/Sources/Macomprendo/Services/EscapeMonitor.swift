import AppKit

/// Watches for the Esc key (`keyCode == 53`) so a feature can let the user cancel with the
/// keyboard alone. `DictationController` starts one while recording/transcribing so the HUD's
/// cancel hint is actually backed by something.
protocol EscapeMonitoring: AnyObject {
    var onEscape: (@MainActor () -> Void)? { get set }
    func start()
    func stop()
}

/// `NSEvent.addGlobalMonitorForEvents` only sees key events delivered to *other* apps, so a
/// local monitor is layered on top to also catch Esc while Macomprendo itself is frontmost
/// (e.g. the Settings window). Global monitors require Accessibility permission, which this
/// app already requests for text insertion (see `PermissionsChecking`), so this adds no new
/// prompt.
final class GlobalEscapeMonitor: EscapeMonitoring, @unchecked Sendable {
    private static let escapeKeyCode: UInt16 = 53

    var onEscape: (@MainActor () -> Void)? {
        get { lock.withLock { _onEscape } }
        set { lock.withLock { _onEscape = newValue } }
    }

    private let lock = NSLock()
    private var _onEscape: (@MainActor () -> Void)?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    func start() {
        lock.withLock {
            guard globalMonitor == nil, localMonitor == nil else { return }
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == Self.escapeKeyCode else { return }
                self?.fire()
            }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == Self.escapeKeyCode else { return event }
                self?.fire()
                return nil   // swallow Esc so it doesn't also close a focused window/panel
            }
        }
    }

    func stop() {
        lock.withLock {
            if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
            if let localMonitor { NSEvent.removeMonitor(localMonitor) }
            globalMonitor = nil
            localMonitor = nil
        }
    }

    private func fire() {
        let handler = lock.withLock { _onEscape }
        guard let handler else { return }
        Task { @MainActor in handler() }
    }
}
