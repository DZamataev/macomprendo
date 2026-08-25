import AppKit
import SwiftUI

/// A floating panel that *can* become key (unlike the recording HUD's non-activating panel),
/// so the user can type in the instruction field and edit the text areas.
final class QuickPanelWindow: NSPanel {
    var onEscape: (@MainActor () -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

@MainActor final class FloatingPanelHost<Content: View>: NSObject, QuickPanelHosting, NSWindowDelegate {
    var onEscape: (@MainActor () -> Void)?
    var onFrameChange: (@MainActor (CGRect) -> Void)?

    private let window: QuickPanelWindow

    var isVisible: Bool { window.isVisible }

    init(rootView: Content) {
        window = QuickPanelWindow(
            contentRect: NSRect(origin: .zero, size: QuickPanelController.panelSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        super.init()
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.contentView = NSHostingView(rootView: rootView)
        window.delegate = self
        window.onEscape = { [weak self] in self?.onEscape?() }
    }

    func show(frame: CGRect) {
        window.setFrame(frame, display: true)
        // orderFrontRegardless keeps the source app active; the panel becomes key on first click.
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }

    func windowDidMove(_ notification: Notification) { onFrameChange?(window.frame) }
    func windowDidResize(_ notification: Notification) { onFrameChange?(window.frame) }
}
