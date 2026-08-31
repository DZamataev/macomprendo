import AppKit
import SwiftUI

enum HUDLayout {
    static let size = CGSize(width: 260, height: 108)
    static let topInset: CGFloat = 24

    /// Top-centre of the given screen.
    static func origin(panelSize: CGSize,
                       screenFrame: CGRect,
                       visibleFrame: CGRect,
                       topInset: CGFloat = HUDLayout.topInset) -> CGPoint {
        CGPoint(x: screenFrame.midX - panelSize.width / 2,
                y: visibleFrame.maxY - panelSize.height - topInset)
    }

    static func screenUnderMouse(mouseLocation: NSPoint, screens: [NSScreen]) -> NSScreen? {
        screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? screens.first
    }
}

/// Shows the HUD in a floating panel on the screen the mouse is on.
@MainActor
final class HUDWindowPresenter: HUDPresenting {
    private var panel: FloatingPanel?

    func present(_ controller: HUDController) {
        let panel = panel ?? makePanel(for: controller)
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
    }

    func dismiss() {
        panel?.orderOut(nil)
    }

    private func makePanel(for controller: HUDController) -> FloatingPanel {
        let panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: HUDLayout.size))
        panel.contentView = NSHostingView(rootView: HUDView(controller: controller))
        return panel
    }

    private func position(_ panel: FloatingPanel) {
        guard let screen = HUDLayout.screenUnderMouse(mouseLocation: NSEvent.mouseLocation,
                                                      screens: NSScreen.screens) else { return }
        let origin = HUDLayout.origin(panelSize: HUDLayout.size,
                                      screenFrame: screen.frame,
                                      visibleFrame: screen.visibleFrame)
        panel.setFrameOrigin(NSPoint(x: origin.x, y: origin.y))
    }
}
