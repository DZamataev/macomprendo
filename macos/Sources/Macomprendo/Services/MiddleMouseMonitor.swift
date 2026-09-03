import AppKit

/// The press and release phases of a physical middle mouse button input.
enum MiddleMouseEvent: Sendable, Equatable {
    case down
    case up
}

/// OS-facing middle-button monitoring. The implementation listens globally and locally so an
/// enabled action works whether another app or Macomprendo currently has focus.
protocol MiddleMouseMonitoring: AnyObject {
    var events: AsyncStream<MiddleMouseEvent> { get }
    func setEnabled(_ enabled: Bool)
}

/// Emits middle-button events while enabled. The monitor observes rather than consumes the
/// mouse event, matching the non-invasive behaviour of the existing global keyboard shortcuts.
final class NSEventMiddleMouseMonitor: MiddleMouseMonitoring, @unchecked Sendable {
    let events: AsyncStream<MiddleMouseEvent>
    private let continuation: AsyncStream<MiddleMouseEvent>.Continuation
    private let lock = NSLock()
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init() {
        var streamContinuation: AsyncStream<MiddleMouseEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(32)) { streamContinuation = $0 }
        continuation = streamContinuation
    }

    func setEnabled(_ enabled: Bool) {
        lock.withLock {
            if enabled {
                guard globalMonitor == nil, localMonitor == nil else { return }
                globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.otherMouseDown, .otherMouseUp]) {
                    [weak self] event in
                    self?.receive(event)
                }
                localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .otherMouseUp]) {
                    [weak self] event in
                    self?.receive(event)
                    return event
                }
            } else {
                if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
                if let localMonitor { NSEvent.removeMonitor(localMonitor) }
                globalMonitor = nil
                localMonitor = nil
            }
        }
    }

    private func receive(_ event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        switch event.type {
        case .otherMouseDown: continuation.yield(.down)
        case .otherMouseUp: continuation.yield(.up)
        default: break
        }
    }
}
