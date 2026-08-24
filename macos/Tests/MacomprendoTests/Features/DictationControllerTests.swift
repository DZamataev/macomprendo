import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct DictationControllerTests {
    private struct Harness {
        let controller: DictationController
        let recorder: FakeAudioRecorder
        let transcriber: FakeTranscriptionProvider
        let inserter: FakeTextInserter
        let tracker: FakeFrontmostAppTracker
        let permissions: FakePermissions
        let hud: HUDController
        let pasteboard: FakePasteboard
        let settings: SettingsHolder
        let escapeMonitor: FakeEscapeMonitor
    }

    private func makeHarness(mode: DictationMode = .hold,
                             insertMethod: InsertMethod = .auto) -> Harness {
        let recorder = FakeAudioRecorder()
        let transcriber = FakeTranscriptionProvider()
        let inserter = FakeTextInserter()
        let tracker = FakeFrontmostAppTracker()
        let permissions = FakePermissions()
        // A HUD state set via `hud.show`/`hud.toast` schedules an auto-hide `Task` on
        // the same MainActor queue this controller runs on. With a sleep that returns
        // instantly, that queued task drains ahead of a test's `await activeTask?.value`
        // continuation and hides the HUD before the assertion runs. Never resolving
        // within a test's lifetime keeps the asserted state stable; HUDController's own
        // auto-hide timing is covered by HUDControllerTests.
        let hud = HUDController(sleep: { _ in try? await Task.sleep(for: .seconds(3600)) })
        let pasteboard = FakePasteboard()
        let settings = SettingsHolder()
        settings.value.dictationMode = mode
        settings.value.insertMethod = insertMethod
        settings.value.transcriptionLanguage = "en"
        let escapeMonitor = FakeEscapeMonitor()

        let controller = DictationController(
            recorder: recorder,
            transcriberProvider: { transcriber },
            inserter: inserter,
            tracker: tracker,
            permissions: permissions,
            hud: hud,
            pasteboard: pasteboard,
            settings: { settings.value },
            escapeMonitor: escapeMonitor)
        return Harness(controller: controller, recorder: recorder, transcriber: transcriber,
                       inserter: inserter, tracker: tracker, permissions: permissions,
                       hud: hud, pasteboard: pasteboard, settings: settings, escapeMonitor: escapeMonitor)
    }

    // MARK: - Hold mode

    @Test func holdKeyDownStartsRecording() async {
        let h = makeHarness(mode: .hold)
        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value

        #expect(h.controller.state == .recording)
        #expect(h.recorder.startCount == 1)
        #expect(h.hud.state == .recording(level: 0, elapsed: 0))
    }

    @Test func holdKeyUpTranscribesAndInserts() async throws {
        let h = makeHarness(mode: .hold, insertMethod: .paste)
        let app = FrontmostApp(pid: 99, bundleID: "com.apple.Notes", name: "Notes")
        h.tracker.appToCapture = app
        h.recorder.samplesToReturn = [0.1, 0.2, 0.3]
        h.transcriber.result = .success("  hello world  ")

        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value
        h.controller.handle(.keyUp(.dictate))
        await h.controller.activeTask?.value

        #expect(h.recorder.stopCount == 1)
        #expect(h.transcriber.received.count == 1)
        #expect(h.transcriber.received[0].pcm == [0.1, 0.2, 0.3])
        #expect(h.transcriber.received[0].sampleRate == 16_000)
        #expect(h.transcriber.received[0].language == "en")
        #expect(h.inserter.inserted == [.init(text: "hello world", app: app, method: .paste)])
        #expect(h.controller.state == .idle)
        #expect(h.hud.state == .success("Inserted"))
    }

    @Test func holdKeyUpWithoutRecordingDoesNothing() async {
        let h = makeHarness(mode: .hold)
        h.controller.handle(.keyUp(.dictate))
        await h.controller.activeTask?.value
        #expect(h.controller.state == .idle)
        #expect(h.recorder.stopCount == 0)
    }

    @Test func anEmptyTranscriptToastsAndInsertsNothing() async {
        let h = makeHarness(mode: .hold)
        h.transcriber.result = .success("   \n ")

        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value
        h.controller.handle(.keyUp(.dictate))
        await h.controller.activeTask?.value

        #expect(h.inserter.inserted.isEmpty)
        #expect(h.controller.state == .idle)
        #expect(h.hud.state == .toast("Nothing heard"))
    }

    @Test func levelUpdatesReachTheHUDWhileRecording() async {
        let h = makeHarness(mode: .hold)
        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value

        h.recorder.emitLevel(0.6)
        await waitFor("HUD level update") {
            if case .recording(let level, _) = h.hud.state { return level == 0.6 }
            return false
        }
    }

    @Test func levelUpdatesAreIgnoredWhenNotRecording() async {
        let h = makeHarness(mode: .hold)
        h.recorder.emitLevel(0.6)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.hud.state == .hidden)
    }

    // MARK: - Toggle mode

    @Test func toggleStartsOnFirstPressAndStopsOnSecond() async {
        let h = makeHarness(mode: .toggle)
        h.transcriber.result = .success("toggled text")

        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value
        #expect(h.controller.state == .recording)

        h.controller.handle(.keyUp(.dictate))       // ignored in toggle mode
        #expect(h.controller.state == .recording)

        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value
        #expect(h.inserter.inserted.map(\.text) == ["toggled text"])
        #expect(h.controller.state == .idle)
    }

    @Test func toggleThirdPressCancelsAnInFlightTranscription() async {
        let h = makeHarness(mode: .toggle)
        h.transcriber.delay = .seconds(5)

        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value
        h.controller.handle(.keyDown(.dictate))
        #expect(h.controller.state == .transcribing)

        let pending = h.controller.activeTask
        h.controller.handle(.keyDown(.dictate))
        await pending?.value

        #expect(h.controller.state == .idle)
        #expect(h.inserter.inserted.isEmpty)
        #expect(h.hud.state == .toast("Cancelled"))
    }

    @Test func cancelStopsTheRecorder() async {
        let h = makeHarness(mode: .hold)
        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value

        h.controller.cancel()
        #expect(h.controller.state == .idle)
        await waitFor("recorder stopped") { h.recorder.stopCount == 1 }
        #expect(h.inserter.inserted.isEmpty)
    }

    /// `insert()` is non-cooperative with cancellation by design (the paste must run to
    /// completion so the pasteboard restore isn't skipped), but the *controller* must
    /// not act on its result once cancelled: the "Cancelled" toast must win, not a
    /// stale "Inserted".
    @Test func cancelDuringInsertWinsOverTheInsertResult() async {
        let h = makeHarness(mode: .hold)
        h.transcriber.result = .success("won't be shown")
        let gate = AsyncGate()
        h.inserter.gate = gate

        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value
        h.controller.handle(.keyUp(.dictate))
        await waitFor("insert to start") { h.controller.state == .inserting }

        let pending = h.controller.activeTask
        h.controller.cancel()
        #expect(h.controller.state == .idle)
        #expect(h.hud.state == .toast("Cancelled"))

        gate.open()
        await pending?.value

        #expect(h.controller.state == .idle)
        #expect(h.hud.state == .toast("Cancelled"))
        #expect(h.inserter.inserted.map(\.text) == ["won't be shown"])   // the paste still ran
    }

    /// `AVAudioEngineRecorder` finishes its level stream when it auto-stops after
    /// hitting `maxDuration`; the controller must treat that termination exactly like a
    /// keyUp/second-press stop.
    @Test func hittingTheRecordingCapTriggersAnImplicitStop() async {
        let h = makeHarness(mode: .hold)
        h.transcriber.result = .success("capped")

        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value
        #expect(h.controller.state == .recording)

        h.recorder.emitLevel(0.4)
        h.recorder.endLevelStream()

        await waitFor("implicit stop transcribes and inserts") {
            h.inserter.inserted.map(\.text) == ["capped"]
        }
        #expect(h.controller.state == .idle)
        #expect(h.hud.state == .success("Inserted"))
    }

    /// `cancel()` kicks off `recorder.stop()` without awaiting it (it must return
    /// synchronously); a fast restart must still wait for that stop to land before
    /// starting again, rather than racing `recorder.start()` against it.
    @Test func cancelledRecorderStopIsAwaitedBeforeARestart() async {
        let h = makeHarness(mode: .hold)
        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value
        #expect(h.controller.state == .recording)

        let stopGate = AsyncGate()
        h.recorder.stopGate = stopGate
        h.controller.cancel()
        #expect(h.controller.state == .idle)

        h.controller.handle(.keyDown(.dictate))
        try? await Task.sleep(for: .milliseconds(20))
        // Still just the one `start()` from the recording above — the restart is
        // blocked on the pending stop.
        #expect(h.recorder.startCount == 1)

        stopGate.open()
        await h.controller.activeTask?.value
        #expect(h.recorder.startCount == 2)
        #expect(h.controller.state == .recording)
    }

    // MARK: - Esc cancels

    @Test func startingDictationStartsTheEscapeMonitor() async {
        let h = makeHarness(mode: .hold)
        #expect(h.escapeMonitor.startCount == 0)
        #expect(h.escapeMonitor.isRunning == false)

        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value

        #expect(h.controller.state == .recording)
        #expect(h.escapeMonitor.startCount == 1)
        #expect(h.escapeMonitor.isRunning == true)
    }

    @Test func escapeDuringRecordingCancels() async {
        let h = makeHarness(mode: .hold)
        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value
        #expect(h.controller.state == .recording)

        h.escapeMonitor.fireEscape()

        #expect(h.controller.state == .idle)
        #expect(h.hud.state == .toast("Cancelled"))
        #expect(h.escapeMonitor.isRunning == false)
        await waitFor("recorder stopped") { h.recorder.stopCount == 1 }
        #expect(h.inserter.inserted.isEmpty)
    }

    @Test func escapeDuringTranscribingCancels() async {
        let h = makeHarness(mode: .hold)
        h.transcriber.delay = .seconds(5)

        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value
        h.controller.handle(.keyUp(.dictate))
        await waitFor("state transcribing") { h.controller.state == .transcribing }

        let pending = h.controller.activeTask
        h.escapeMonitor.fireEscape()

        #expect(h.controller.state == .idle)
        #expect(h.hud.state == .toast("Cancelled"))
        #expect(h.escapeMonitor.isRunning == false)
        await pending?.value
        #expect(h.inserter.inserted.isEmpty)
    }

    @Test func escapeMonitorIsNotRunningWhenIdle() async {
        let h = makeHarness(mode: .hold)
        #expect(h.escapeMonitor.isRunning == false)

        // A full record → transcribe → insert cycle must leave the monitor stopped again.
        h.transcriber.result = .success("done")
        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value
        h.controller.handle(.keyUp(.dictate))
        await h.controller.activeTask?.value

        #expect(h.controller.state == .idle)
        #expect(h.escapeMonitor.isRunning == false)
    }

    // MARK: - Permissions

    @Test func aDeniedMicrophoneFailsAndOpensSystemSettings() async {
        let h = makeHarness(mode: .hold)
        h.permissions.statuses[.microphone] = .denied
        h.permissions.requestResults[.microphone] = .denied

        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value

        #expect(h.recorder.startCount == 0)
        #expect(h.permissions.openedPanes == [.microphone])
        #expect(h.controller.state
                == .failed(ErrorText.describe(MacomprendoError.permissionDenied(.microphone))))
    }

    @Test func deniedAccessibilityFailsBeforeRecording() async {
        let h = makeHarness(mode: .hold)
        h.permissions.statuses[.accessibility] = .denied
        h.permissions.requestResults[.accessibility] = .denied

        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value

        #expect(h.recorder.startCount == 0)
        #expect(h.permissions.openedPanes == [.accessibility])
        #expect(h.controller.state
                == .failed(ErrorText.describe(MacomprendoError.permissionDenied(.accessibility))))
    }

    @Test func anUndeterminedMicrophonePermissionIsRequestedThenRecordingStarts() async {
        let h = makeHarness(mode: .hold)
        h.permissions.statuses[.microphone] = .undetermined
        h.permissions.requestResults[.microphone] = .granted

        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value

        #expect(h.permissions.requested.contains(.microphone))
        #expect(h.controller.state == .recording)
    }

    // MARK: - Failures

    @Test func aRecorderFailureIsSurfaced() async {
        let h = makeHarness(mode: .hold)
        h.recorder.startError = MacomprendoError.audio("No microphone input is available.")

        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value

        #expect(h.controller.state
                == .failed(ErrorText.describe(MacomprendoError.audio("No microphone input is available."))))
        #expect(h.hud.state
                == .error(ErrorText.describe(MacomprendoError.audio("No microphone input is available."))))
    }

    @Test func aTranscriptionFailureIsSurfaced() async {
        let h = makeHarness(mode: .hold)
        let failure = MacomprendoError.providerUnreachable(endpointName: "Ollama (local)")
        h.transcriber.result = .failure(failure)

        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value
        h.controller.handle(.keyUp(.dictate))
        await h.controller.activeTask?.value

        #expect(h.controller.state == .failed(ErrorText.describe(failure)))
        #expect(h.hud.state == .error(ErrorText.describe(failure)))
        #expect(h.inserter.inserted.isEmpty)
    }

    @Test func anInsertionFailureIsSurfaced() async {
        let h = makeHarness(mode: .hold)
        h.transcriber.result = .success("text")
        h.inserter.error = MacomprendoError.insertFailed

        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value
        h.controller.handle(.keyUp(.dictate))
        await h.controller.activeTask?.value

        #expect(h.controller.state == .failed(ErrorText.describe(MacomprendoError.insertFailed)))
    }

    /// Ruling: `PasteTextInserter` throws `insertFailed` *before* it writes to the
    /// pasteboard when it cannot re-activate the target app, but its recovery text
    /// says "the text is on the clipboard". The controller's fallback must make that
    /// true — copy the dictated text itself — before showing the copy-only toast.
    @Test func anInsertionFailureCopiesTheTextAndShowsAFallbackToast() async {
        let h = makeHarness(mode: .hold, insertMethod: .paste)
        h.transcriber.result = .success("copied text")
        h.inserter.error = MacomprendoError.insertFailed

        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value
        h.controller.handle(.keyUp(.dictate))
        await h.controller.activeTask?.value

        #expect(h.pasteboard.readString() == "copied text")
        #expect(h.hud.state == .toast("Copied to clipboard"))
        #expect(h.controller.state == .failed(ErrorText.describe(MacomprendoError.insertFailed)))
    }

    @Test func aFailedStateCanStartANewRecording() async {
        let h = makeHarness(mode: .hold)
        h.recorder.startError = MacomprendoError.audio("boom")
        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value
        #expect(h.controller.state == .failed(ErrorText.describe(MacomprendoError.audio("boom"))))

        h.recorder.startError = nil
        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value
        #expect(h.controller.state == .recording)
    }

    // MARK: - Routing

    @Test func ignoresEventsForOtherActions() async {
        let h = makeHarness(mode: .hold)
        h.controller.handle(.keyDown(.speak))
        h.controller.handle(.keyDown(.summarize))
        await h.controller.activeTask?.value
        #expect(h.controller.state == .idle)
        #expect(h.recorder.startCount == 0)
    }

    @Test func aProviderThatCannotBeBuiltFailsTheAction() async {
        let recorder = FakeAudioRecorder()
        let hud = HUDController(sleep: { _ in })
        let settings = SettingsHolder()
        let controller = DictationController(
            recorder: recorder,
            transcriberProvider: { throw MacomprendoError.modelMissing("large-v3-turbo") },
            inserter: FakeTextInserter(),
            tracker: FakeFrontmostAppTracker(),
            permissions: FakePermissions(),
            hud: hud,
            pasteboard: FakePasteboard(),
            settings: { settings.value },
            escapeMonitor: FakeEscapeMonitor())

        controller.handle(.keyDown(.dictate))
        await controller.activeTask?.value
        controller.handle(.keyUp(.dictate))
        await controller.activeTask?.value

        #expect(controller.state
                == .failed(ErrorText.describe(MacomprendoError.modelMissing("large-v3-turbo"))))
    }
}
