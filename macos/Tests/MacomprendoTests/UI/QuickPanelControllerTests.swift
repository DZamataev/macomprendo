import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct QuickPanelControllerTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    /// Counts the dismissal hook the composition root uses to stop panel-initiated playback.
    @MainActor final class DismissCounter {
        var count = 0
    }

    private func make() -> (QuickPanelController, ScriptedPanelHost, ScriptedSettingsHolder) {
        let (controller, host, holder, _) = makeCounting()
        return (controller, host, holder)
    }

    private func makeCounting()
        -> (QuickPanelController, ScriptedPanelHost, ScriptedSettingsHolder, DismissCounter) {
        let holder = ScriptedSettingsHolder()
        let host = ScriptedPanelHost()
        let counter = DismissCounter()
        let controller = QuickPanelController(holder: holder,
                                              onDismiss: { counter.count += 1 })
        controller.attach(host)
        return (controller, host, holder, counter)
    }

    @Test func screenKeyIsStableAndDoesNotUseSwiftHashing() {
        let a = QuickPanelController.screenKey(name: "Built-in Retina Display", frame: screen)
        let b = QuickPanelController.screenKey(name: "Built-in Retina Display", frame: screen)
        #expect(a == b)
        #expect(a == "Built-in Retina Display#0,0,1440x900")
        #expect(a != QuickPanelController.screenKey(name: "Studio Display", frame: screen))
    }

    @Test func defaultFrameIsTopCentreAndSixEightyByFourTwenty() {
        let frame = QuickPanelController.defaultFrame(inScreenFrame: screen)
        #expect(frame.width == 680)
        #expect(frame.height == 420)
        #expect(frame.midX == screen.midX)
        #expect(frame.maxY == screen.maxY - 80)
    }

    @Test func presentShowsTheHostWithTheDefaultFrame() {
        let (controller, host, _) = make()
        controller.present(layout: .summary, screenName: "S1", screenFrame: screen)
        #expect(controller.isVisible)
        #expect(controller.layout == .summary)
        #expect(host.shownFrames == [QuickPanelController.defaultFrame(inScreenFrame: screen)])
    }

    @Test func aRememberedFrameIsReusedForTheSameScreen() {
        let (controller, host, holder) = make()
        let remembered = CGRect(x: 10, y: 20, width: 700, height: 500)
        holder.settings.quickPanelFrames[
            QuickPanelController.screenKey(name: "S1", frame: screen)] = remembered
        controller.present(layout: .refine, screenName: "S1", screenFrame: screen)
        #expect(host.shownFrames == [remembered])
    }

    @Test func draggingThePanelPersistsTheFramePerScreen() {
        let (controller, host, holder) = make()
        controller.present(layout: .refine, screenName: "S1", screenFrame: screen)
        let moved = CGRect(x: 100, y: 200, width: 680, height: 420)
        host.dragTo(moved)
        let key = QuickPanelController.screenKey(name: "S1", frame: screen)
        #expect(holder.settings.quickPanelFrames[key] == moved)
    }

    @Test func escapeDismissesThePanel() {
        let (controller, host, _) = make()
        controller.present(layout: .refine, screenName: "S1", screenFrame: screen)
        host.pressEscape()
        #expect(!controller.isVisible)
        #expect(host.hideCount == 1)
    }

    // Controller ruling (F4): the screen-free overload is what RefineController and
    // SummarizeController call — it must resolve a real screen itself (via
    // `HUDLayout.screenUnderMouse`) rather than defaulting to `NSScreen.main`, which on
    // this `LSUIElement` app is always the menu-bar screen. The exact screen picked isn't
    // asserted here (headless test hosts may have zero or many screens); this only
    // guards that Features/ code no longer has to supply one and the panel still opens.
    @Test func presentWithoutAnExplicitScreenStillOpensThePanel() {
        let (controller, host, _) = make()
        controller.present(layout: .refine)
        #expect(controller.isVisible)
        #expect(controller.layout == .refine)
        #expect(host.shownFrames.count == 1)
    }

    /// The hook `TextFeatures.live` uses to stop a read the panel started. Esc, Insert and
    /// Replace selection all dismiss through the same call, so one hook covers all three.
    @Test func dismissingCallsTheDismissHookBeforeHidingTheWindow() {
        let (controller, host, _, counter) = makeCounting()
        controller.present(layout: .refine, screenName: "S1", screenFrame: screen)
        host.pressEscape()
        #expect(counter.count == 1)
        #expect(host.hideCount == 1)

        controller.dismiss()
        #expect(counter.count == 2)
    }

    @Test func presentingTwiceKeepsOneVisiblePanelAndUpdatesTheLayout() {
        let (controller, host, _) = make()
        controller.present(layout: .refine, screenName: "S1", screenFrame: screen)
        controller.present(layout: .summary, screenName: "S1", screenFrame: screen)
        #expect(controller.layout == .summary)
        #expect(host.shownFrames.count == 2)
        #expect(host.hideCount == 0)
    }
}
