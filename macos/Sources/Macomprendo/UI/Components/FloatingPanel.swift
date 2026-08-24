import AppKit

/// Borderless, non-activating panel used for the recording HUD (and, in Plan 4, the Quick Panel).
/// It never becomes key, so the app the user is typing in keeps focus.
final class FloatingPanel: NSPanel {
    init(contentRect: NSRect, ignoresMouse: Bool = true) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        ignoresMouseEvents = ignoresMouse
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
