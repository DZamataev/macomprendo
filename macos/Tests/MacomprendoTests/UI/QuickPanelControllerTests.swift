import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct QuickPanelControllerTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    private func make() -> (QuickPanelController, ScriptedPanelHost, ScriptedSettingsHolder) {
        let holder = ScriptedSettingsHolder()
        let host = ScriptedPanelHost()
        let controller = QuickPanelController(holder: holder)
        controller.attach(host)
        return (controller, host, holder)
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

    @Test func presentingTwiceKeepsOneVisiblePanelAndUpdatesTheLayout() {
        let (controller, host, _) = make()
        controller.present(layout: .refine, screenName: "S1", screenFrame: screen)
        controller.present(layout: .summary, screenName: "S1", screenFrame: screen)
        #expect(controller.layout == .summary)
        #expect(host.shownFrames.count == 2)
        #expect(host.hideCount == 0)
    }
}
