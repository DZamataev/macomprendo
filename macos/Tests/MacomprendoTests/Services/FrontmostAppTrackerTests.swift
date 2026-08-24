import Foundation
import Testing
@testable import Macomprendo

@Suite struct ActivationPollerTests {
    @Test func returnsImmediatelyWhenAlreadyActive() async {
        let sleeps = SleepRecorder()
        let result = await ActivationPoller.wait(
            timeout: 0.5,
            interval: 0.025,
            isActive: { true },
            sleep: { sleeps.record($0) })
        #expect(result == true)
        #expect(sleeps.durations.isEmpty)
    }

    @Test func pollsUntilTheAppBecomesActive() async {
        let sleeps = SleepRecorder()
        let attempts = Counter()
        let result = await ActivationPoller.wait(
            timeout: 0.5,
            interval: 0.025,
            isActive: { attempts.increment() >= 3 },
            sleep: { sleeps.record($0) })
        #expect(result == true)
        #expect(sleeps.durations == [0.025, 0.025])
    }

    @Test func givesUpAfterTheTimeout() async {
        let sleeps = SleepRecorder()
        let result = await ActivationPoller.wait(
            timeout: 0.1,
            interval: 0.025,
            isActive: { false },
            sleep: { sleeps.record($0) })
        #expect(result == false)
        #expect(sleeps.durations.count == 4)   // 0.1 / 0.025
    }
}

@Suite struct FakeFrontmostAppTrackerTests {
    @Test func capturesAndActivatesTheScriptedApp() async {
        let tracker = FakeFrontmostAppTracker()
        let app = FrontmostApp(pid: 42, bundleID: "com.apple.TextEdit", name: "TextEdit")
        tracker.appToCapture = app
        #expect(tracker.capture() == app)
        #expect(await tracker.activate(app) == true)
        #expect(tracker.activated == [app])

        tracker.activateResult = false
        #expect(await tracker.activate(app) == false)
    }
}
