import AppKit
import SwiftUI

/// Reports a real scroll event over the view it backs. macOS 14 has no SwiftUI API for a user
/// scroll, and `ScrollViewReader.scrollTo` sends no scroll-wheel event, so a local `NSEvent`
/// monitor is the only way to tell the two apart (spec: follow detection).
///
/// The monitor lives only while the view has a window: installed in `viewDidMoveToWindow` and
/// removed when the window goes away and in `dismantleNSView`, so a closed window holds none.
struct ScrollWheelObserver: NSViewRepresentable {
    let onUserScroll: () -> Void

    func makeNSView(context: Context) -> ObserverView {
        ObserverView(onUserScroll: onUserScroll)
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.onUserScroll = onUserScroll
    }

    static func dismantleNSView(_ nsView: ObserverView, coordinator: ()) {
        nsView.removeMonitor()
    }

    /// A zero-drawing view whose only job is the monitor; it spans the scroll view behind it.
    final class ObserverView: NSView {
        var onUserScroll: () -> Void
        private var monitor: Any?

        init(onUserScroll: @escaping () -> Void) {
            self.onUserScroll = onUserScroll
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
            } else {
                installMonitor()
            }
        }

        private func installMonitor() {
            removeMonitor()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                else { return event }
                self.onUserScroll()
                return event
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
