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
        // makeKeyAndOrderFront, not orderFrontRegardless: the panel must become key
        // immediately so Esc (NSPanel.cancelOperation, wired to onEscape above) closes it
        // without the user clicking into it first — cancelOperation only fires for the
        // key window. Because the style mask carries .nonactivatingPanel, this makes the
        // panel key WITHOUT activating the app or stealing focus from the source app the
        // way a normal window's makeKeyAndOrderFront would.
        // NOTE: `ScriptedPanelHost` (the test fake) doesn't model key-window state at
        // all — `host.pressEscape()` fires unconditionally, more permissively than the
        // real NSPanel, which only calls `cancelOperation` while key. Keep that gap in
        // mind when trusting a green FloatingPanelHost-adjacent test alone; this file's
        // behavior is covered by docs/SMOKE_TEST.md, not a unit test.
        window.makeKeyAndOrderFront(nil)
    }

    func hide() {
        window.orderOut(nil)
    }

    func windowDidMove(_ notification: Notification) { onFrameChange?(window.frame) }
    func windowDidResize(_ notification: Notification) { onFrameChange?(window.frame) }
}
