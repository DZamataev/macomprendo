import AppKit
import Foundation
import SwiftUI

/// Shows the post-dictation review panel. Shaped like `HUDPresenting`: the controller decides
/// *whether* and *what*, the presenter owns only the window, so every decision above it is
/// unit-tested against a fake and only the `NSPanel` is smoke-tested (invariant 3).
///
/// A `CorrectionReview` carries transcript content, so an implementation must never log it at
/// default level.
@MainActor
protocol CorrectionReviewPresenting: AnyObject {
    /// Shows `review`, replacing whatever is on screen. Never stacks: a new dictation's
    /// corrections supersede the previous one's.
    func present(_ review: CorrectionReview)
    /// Hides the panel, if one is showing.
    func dismiss()
}

/// Puts `CorrectionReviewView` in a `FloatingPanel` on the screen the mouse is on.
///
/// `FloatingPanel` is reused rather than replaced for the reason this whole feature exists:
/// insertion simulates ⌘V into the frontmost application, so a panel that could become key
/// would redirect the paste into itself. Its `.borderless, .nonactivatingPanel` mask and
/// `canBecomeKey == false` are that guarantee — never add `.titled`.
///
/// `ignoresMouse: false` is the one difference from the recording HUD: hovering a marked span
/// is how the original spelling is read, and a panel that ignores the mouse cannot be hovered.
/// That is also why placement matters — it follows the HUD's, which is already chosen to stay
/// clear of the text caret.
///
/// Nothing but ordering and placement lives here; the lifetime rules are in
/// `CorrectionReviewController`, where they are unit-tested.
@MainActor
final class CorrectionReviewWindowPresenter: CorrectionReviewPresenting {
    private let controller = CorrectionReviewController()
    private var panel: FloatingPanel?

    init() {
        // The timer is the only thing that takes the panel down on its own, so ordering out
        // is wired to it rather than polled from the view.
        controller.onAutoHide = { [weak self] in self?.orderOut() }
    }

    func present(_ review: CorrectionReview) {
        let panel = panel ?? makePanel()
        self.panel = panel
        controller.present(review)
        position(panel)
        panel.orderFrontRegardless()
    }

    func dismiss() {
        controller.dismiss()
        orderOut()
    }

    private func orderOut() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: CorrectionReviewLayout.size),
            ignoresMouse: false)
        panel.contentView = NSHostingView(rootView: CorrectionReviewView(controller: controller))
        return panel
    }

    private func position(_ panel: FloatingPanel) {
        guard let screen = HUDLayout.screenUnderMouse(mouseLocation: NSEvent.mouseLocation,
                                                      screens: NSScreen.screens) else { return }
        let origin = CorrectionReviewLayout.origin(panelSize: CorrectionReviewLayout.size,
                                                   screenFrame: screen.frame,
                                                   visibleFrame: screen.visibleFrame)
        panel.setFrameOrigin(NSPoint(x: origin.x, y: origin.y))
    }
}
