import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite("Correction review lifetime")
struct CorrectionReviewControllerTests {
    private func review(_ text: String, terms: [String] = ["MatchHUD"]) -> CorrectionReview {
        CorrectionReview(Normalizer.normalise(text, with: Glossary(manualTerms: terms)))
    }

    private func makeController() -> (CorrectionReviewController, SleepRecorder, Counter) {
        let sleeps = SleepRecorder()
        let hides = Counter()
        let controller = CorrectionReviewController(sleep: { sleeps.record($0) },
                                                    onAutoHide: { hides.increment() })
        return (controller, sleeps, hides)
    }

    @Test func startsWithNothingToShow() {
        let (controller, _, _) = makeController()
        #expect(controller.review == nil)
        #expect(controller.hideTask == nil)
    }

    @Test func staysUpForTwoSeconds() {
        // Long enough to read a line of corrected text, short enough not to linger over the
        // document the text went into. Hovering still holds it open.
        #expect(CorrectionReviewController.autoHideDuration == 2)
    }

    @Test func presentShowsTheReviewAndHidesItAfterTheDuration() async {
        let (controller, sleeps, hides) = makeController()
        let shown = review("открываю Match HUD")

        controller.present(shown)
        #expect(controller.review == shown)
        #expect(controller.hideTask != nil)

        await controller.hideTask?.value
        #expect(sleeps.durations == [CorrectionReviewController.autoHideDuration])
        #expect(controller.review == nil)
        #expect(hides.count == 1)
    }

    @Test func presentWhileVisibleReplacesTheContentAndRestartsTheTimer() async {
        let (controller, sleeps, hides) = makeController()
        let first = review("открываю Match HUD")
        let second = review("снова Match HUD")

        controller.present(first)
        let firstTask = controller.hideTask
        controller.present(second)

        #expect(controller.review == second)
        // A fresh timer, and the superseded one cancelled: were it left running, the first
        // dictation's timer would take the second dictation's text off the screen.
        #expect(firstTask?.isCancelled == true)
        #expect(controller.hideTask != nil)
        #expect(controller.hideTask != firstTask)

        await firstTask?.value
        await controller.hideTask?.value
        #expect(sleeps.durations == [CorrectionReviewController.autoHideDuration,
                                      CorrectionReviewController.autoHideDuration])
        #expect(controller.review == nil)
        // Exactly one, from the live timer: the cancelled one must report nothing.
        #expect(hides.count == 1)
    }

    @Test func thePointerInsidePausesTheTimer() async {
        let (controller, _, hides) = makeController()
        let shown = review("открываю Match HUD")

        controller.present(shown)
        let scheduled = controller.hideTask
        controller.pointerInsideChanged(true)

        #expect(controller.hideTask == nil)
        await scheduled?.value
        #expect(controller.review == shown)
        #expect(hides.count == 0)
    }

    @Test func leavingRestartsTheFullDuration() async {
        let (controller, sleeps, hides) = makeController()
        controller.present(review("открываю Match HUD"))
        controller.pointerInsideChanged(true)
        controller.pointerInsideChanged(false)

        #expect(controller.hideTask != nil)
        await controller.hideTask?.value
        #expect(sleeps.durations.last == CorrectionReviewController.autoHideDuration)
        #expect(controller.review == nil)
        #expect(hides.count == 1)
    }

    @Test func presentingWhileThePointerIsInsideKeepsTheTimerPaused() async {
        // A second dictation lands while the user is reading the first one's panel. Replacing
        // the content must not out-rank the hover pause, or the text is pulled away mid-read.
        let (controller, _, hides) = makeController()
        controller.present(review("открываю Match HUD"))
        controller.pointerInsideChanged(true)

        let second = review("снова Match HUD")
        controller.present(second)

        #expect(controller.review == second)
        #expect(controller.hideTask == nil)

        controller.pointerInsideChanged(false)
        await controller.hideTask?.value
        #expect(controller.review == nil)
        #expect(hides.count == 1)
    }

    @Test func dismissClearsTheReviewWithoutReportingAnAutoHide() async {
        let (controller, _, hides) = makeController()
        controller.present(review("открываю Match HUD"))
        let scheduled = controller.hideTask

        controller.dismiss()
        #expect(controller.review == nil)
        #expect(controller.hideTask == nil)
        // The caller asked for the hide, so the panel is already going away: reporting one
        // back would order it out twice.
        #expect(hides.count == 0)

        await scheduled?.value
        #expect(hides.count == 0)
    }

    @Test func leavingWithNothingOnScreenSchedulesNothing() {
        let (controller, _, _) = makeController()
        controller.pointerInsideChanged(true)
        controller.pointerInsideChanged(false)
        #expect(controller.hideTask == nil)
        #expect(controller.review == nil)
    }
}
