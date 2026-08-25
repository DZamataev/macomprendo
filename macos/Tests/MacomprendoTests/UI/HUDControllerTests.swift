import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct HUDControllerTests {
    private func makeController() -> (HUDController, FakeHUDPresenter, SleepRecorder) {
        let presenter = FakeHUDPresenter()
        let sleeps = SleepRecorder()
        let controller = HUDController(presenter: presenter, sleep: { sleeps.record($0) })
        return (controller, presenter, sleeps)
    }

    @Test func startsHidden() {
        let (controller, presenter, _) = makeController()
        #expect(controller.state == .hidden)
        #expect(presenter.presentCount == 0)
    }

    @Test func recordingStaysVisibleUntilTheNextState() {
        let (controller, presenter, sleeps) = makeController()
        controller.show(.recording(level: 0.4, elapsed: 1.5))
        #expect(controller.state == .recording(level: 0.4, elapsed: 1.5))
        #expect(presenter.presentCount == 1)
        #expect(controller.hideTask == nil)
        #expect(sleeps.durations.isEmpty)
    }

    @Test func transcribingStaysVisible() {
        let (controller, _, _) = makeController()
        controller.show(.transcribing)
        #expect(controller.hideTask == nil)
    }

    @Test func successAutoHidesAfter1_2Seconds() async {
        let (controller, presenter, sleeps) = makeController()
        controller.show(.success("Inserted"))
        #expect(controller.state == .success("Inserted"))
        await controller.hideTask?.value
        #expect(sleeps.durations == [1.2])
        #expect(controller.state == .hidden)
        #expect(presenter.dismissCount == 1)
    }

    @Test func errorAutoHidesAfter4Seconds() async {
        let (controller, _, sleeps) = makeController()
        controller.show(.error("Ollama is not running."))
        await controller.hideTask?.value
        #expect(sleeps.durations == [4])
        #expect(controller.state == .hidden)
    }

    @Test func toastUsesTheGivenDuration() async {
        let (controller, presenter, sleeps) = makeController()
        controller.toast("Nothing heard", duration: 0.8)
        #expect(controller.state == .toast("Nothing heard"))
        #expect(presenter.presentCount == 1)
        await controller.hideTask?.value
        #expect(sleeps.durations == [0.8])
        #expect(controller.state == .hidden)
    }

    @Test func toastDefaultsTo1_2Seconds() async {
        let (controller, _, sleeps) = makeController()
        controller.toast("Copied")
        await controller.hideTask?.value
        #expect(sleeps.durations == [1.2])
    }

    @Test func aNewStateCancelsThePendingAutoHide() async {
        let (controller, _, _) = makeController()
        controller.toast("Nothing heard")
        let pending = controller.hideTask
        controller.show(.transcribing)
        await pending?.value
        #expect(controller.state == .transcribing)
    }

    @Test func hideDismissesThePresenter() {
        let (controller, presenter, _) = makeController()
        controller.show(.transcribing)
        controller.hide()
        #expect(controller.state == .hidden)
        #expect(presenter.dismissCount == 1)
    }

    @Test func showingHiddenDismissesRatherThanPresents() {
        let (controller, presenter, _) = makeController()
        controller.show(.hidden)
        #expect(presenter.presentCount == 0)
        #expect(presenter.dismissCount == 1)
    }

    @Test func speakingNeverAutoHides() {
        #expect(HUDController.autoHideDuration(for: .speaking(hint: "hint")) == nil)
    }

    @Test func speakingStaysVisibleUntilItIsHidden() {
        let hud = HUDController(sleep: { _ in })
        hud.show(.speaking(hint: "Press ⌥S again to stop."))
        #expect(hud.state == .speaking(hint: "Press ⌥S again to stop."))
        #expect(hud.hideTask == nil)
        hud.hide()
        #expect(hud.state == .hidden)
    }
}
