import AppKit
import Foundation
import Testing
@testable import Macomprendo

/// The panel's window configuration, which is the constraint the whole feature turns on.
///
/// `NSPanel` *behaviour* — ordering, hovering, what happens over a full-screen app — is
/// smoke-tested (invariant 3). Its configuration is not behaviour: it is four flags read off
/// an object, and getting one of them wrong redirects the user's paste into this panel. They
/// are asserted here so a later edit cannot quietly flip one.
@MainActor
@Suite("Correction review panel configuration")
struct CorrectionReviewPanelTests {
    @Test func theReviewPanelCanNeverBecomeKeyOrMain() {
        // Insertion simulates ⌘V into the frontmost app. A panel that takes focus receives
        // that paste itself, and the user's text never arrives.
        let panel = CorrectionReviewWindowPresenter.makePanel(contentView: nil)

        #expect(panel.canBecomeKey == false)
        #expect(panel.canBecomeMain == false)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.styleMask.contains(.titled) == false)
    }

    @Test func theReviewPanelTakesMouseEventsUnlikeTheRecordingHUD() {
        // Hovering a marked span is how the original spelling is read; a panel that ignores
        // the mouse can never be hovered.
        #expect(CorrectionReviewWindowPresenter.makePanel(contentView: nil).ignoresMouseEvents == false)
    }

    @Test func theRecordingHUDStillIgnoresTheMouse() {
        // The difference is deliberate and belongs to this panel alone: the HUD sits over the
        // app the user is typing in and must not intercept clicks.
        #expect(FloatingPanel(contentRect: NSRect(origin: .zero, size: HUDLayout.size))
            .ignoresMouseEvents)
    }

    @Test func theReviewPanelIsSizedAndFloatedForTheText() {
        let panel = CorrectionReviewWindowPresenter.makePanel(contentView: nil)

        #expect(panel.frame.size == CorrectionReviewLayout.size)
        #expect(panel.level == .floating)
        // Visible over a full-screen app rather than hidden behind it.
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
    }
}
