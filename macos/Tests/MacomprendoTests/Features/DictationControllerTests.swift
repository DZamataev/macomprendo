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
        let historyStore: FakeDictationHistoryStore
        let history: DictationHistoryController
        let encoder: FakeDictationAudioEncoder
    }

    private func makeHarness(mode: DictationMode = .hold,
                             insertMethod: InsertMethod = .auto,
                             historyEnabled: Bool = true,
                             recordingEnabled: Bool = false,
                             transcript: String? = nil) -> Harness {
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
        settings.value.dictationHistoryEnabled = historyEnabled
        settings.value.saveOriginalRecording = recordingEnabled
        let escapeMonitor = FakeEscapeMonitor()
        let historyStore = FakeDictationHistoryStore()
        let encoder = FakeDictationAudioEncoder()
        let history = DictationHistoryController(store: historyStore,
                                                  pasteboard: pasteboard,
                                                  isEnabled: { settings.value.dictationHistoryEnabled },
                                                  encoder: encoder,
                                                  shouldSaveRecording: {
                                                      settings.value.saveOriginalRecording
                                                  })
        if let transcript { transcriber.result = .success(transcript) }

        let controller = DictationController(
            recorder: recorder,
            transcriberProvider: { transcriber },
            inserter: inserter,
            tracker: tracker,
            permissions: permissions,
            hud: hud,
            pasteboard: pasteboard,
            settings: { settings.value },
            escapeMonitor: escapeMonitor,
            history: history)
        return Harness(controller: controller, recorder: recorder, transcriber: transcriber,
                       inserter: inserter, tracker: tracker, permissions: permissions,
                       hud: hud, pasteboard: pasteboard, settings: settings, escapeMonitor: escapeMonitor,
                       historyStore: historyStore, history: history, encoder: encoder)
    }

    private func recordAndFinish(_ h: Harness) async {
        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value
        h.controller.handle(.keyUp(.dictate))
        await h.controller.activeTask?.value
    }

    // MARK: - Dictation history

    @Test func savedRecordingUsesCapturedSamplesAndAttachesAfterInsertion() async {
        let h = makeHarness(historyEnabled: true, recordingEnabled: true, transcript: "saved")
        let gate = AsyncGate()
        await h.encoder.setGate(gate)
        h.recorder.samplesToReturn = [0.25, -0.5, 0.75]
        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value
        h.controller.handle(.keyUp(.dictate))
        await h.encoder.encodeInvoked.wait()

        #expect(h.inserter.inserted.map(\.text) == ["saved"])
        #expect(await h.encoder.requests.map(\.pcm) == [[0.25, -0.5, 0.75]])
        gate.open()
        await h.controller.activeTask?.value
        #expect(await h.historyStore.attachRequests == [.init(filename: "1.m4a", entryID: 1)])
    }

    @Test func aNewDictationDuringRecordingEncodeStartsInsteadOfBeingCancelled() async {
        // Once the paste has landed, the controller must return to `.idle` immediately —
        // it must not still read as `.inserting` for the whole duration of the recording
        // encode, or a hotkey press in that window is misread as "cancel the in-flight
        // session" instead of "begin a new one".
        let h = makeHarness(historyEnabled: true, recordingEnabled: true, transcript: "saved")
        let gate = AsyncGate()
        await h.encoder.setGate(gate)
        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value
        h.controller.handle(.keyUp(.dictate))
        await h.encoder.encodeInvoked.wait()

        #expect(h.controller.state == .idle)

        h.controller.handle(.keyDown(.dictate))
        await waitFor("new recording to start") { h.controller.state == .recording }

        #expect(h.hud.state != .toast("Cancelled"))

        gate.open()
        await h.controller.activeTask?.value
    }

    @Test func cancellationDuringEncodingAttachesNothing() async {
        let h = makeHarness(historyEnabled: true, recordingEnabled: true, transcript: "inserted")
        let gate = AsyncGate()
        await h.encoder.setGate(gate)
        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value
        h.controller.handle(.keyUp(.dictate))
        await h.encoder.encodeInvoked.wait()

        let pending = h.controller.activeTask
        h.controller.cancel()
        gate.open()
        await pending?.value

        #expect(await h.historyStore.attachRequests.isEmpty)
    }

    @Test func recordingSettingOffSkipsEncoding() async {
        let h = makeHarness(historyEnabled: true, recordingEnabled: false, transcript: "text only")
        await recordAndFinish(h)
        #expect(await h.encoder.requests.isEmpty)
    }

    @Test func encoderFailureKeepsInsertedTranscriptAndShowsTheError() async {
        let h = makeHarness(historyEnabled: true, recordingEnabled: true, transcript: "still inserted")
        await h.encoder.setError(MacomprendoError.audioEncoding("disk full"))
        await recordAndFinish(h)

        #expect(h.inserter.inserted.map(\.text) == ["still inserted"])
        #expect(await h.historyStore.attachRequests.isEmpty)
        guard case .error(let message) = h.hud.state else {
            Issue.record("Expected a user-visible encoding warning")
            return
        }
        #expect(message.contains("Saving the recording failed"))
    }

    /// A regression where the controller bypasses its history commit point would leave
    /// the accepted, trimmed direct dictation absent from history even though it pasted.
    @Test func acceptedTranscriptIsRecordedBeforeInsertion() async {
        let h = makeHarness(historyEnabled: true, transcript: "  recorded text \n")
        let appendGate = AsyncGate()
        await h.historyStore.setAppendGate(appendGate)

        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value
        h.controller.handle(.keyUp(.dictate))
        await waitFor("history append to suspend") { appendGate.waiterCount == 1 }

        #expect(await h.historyStore.appendRequests.map(\.text) == ["recorded text"])
        #expect(await h.historyStore.appendRequests.map(\.kind) == [.dictation])
        #expect(h.inserter.inserted.isEmpty)

        let pending = h.controller.activeTask
        appendGate.open()
        await pending?.value

        #expect(h.inserter.inserted.map(\.text) == ["recorded text"])
    }

    /// A disabled setting must reject the history side effect without changing insertion.
    @Test func disabledHistoryDoesNotRecordAnAcceptedTranscript() async {
        let h = makeHarness(historyEnabled: false, recordingEnabled: true, transcript: "not recorded")
        await recordAndFinish(h)

        #expect(await h.historyStore.appendRequests.isEmpty)
        #expect(await h.encoder.requests.isEmpty)
        #expect(h.inserter.inserted.map(\.text) == ["not recorded"])
    }

    @Test func disablingHistoryBeforeDirectTranscriptAcceptancePreventsPersistence() async {
        let h = makeHarness(historyEnabled: true, transcript: "not persisted")
        let transcriptionGate = AsyncGate()
        h.transcriber.gate = transcriptionGate

        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value
        h.controller.handle(.keyUp(.dictate))
        await waitFor("direct transcription to suspend") { transcriptionGate.waiterCount == 1 }
        h.settings.value.dictationHistoryEnabled = false
        transcriptionGate.open()
        await h.controller.activeTask?.value

        #expect(await h.historyStore.appendRequests.isEmpty)
        #expect(h.inserter.inserted.map(\.text) == ["not persisted"])
    }

    @Test func enablingHistoryBeforeDirectTranscriptAcceptancePermitsPersistence() async {
        let h = makeHarness(historyEnabled: false, transcript: "persisted after enabling")
        let transcriptionGate = AsyncGate()
        h.transcriber.gate = transcriptionGate

        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value
        h.controller.handle(.keyUp(.dictate))
        await waitFor("direct transcription to suspend") { transcriptionGate.waiterCount == 1 }
        h.settings.value.dictationHistoryEnabled = true
        transcriptionGate.open()
        await h.controller.activeTask?.value

        #expect(await h.historyStore.appendRequests.map(\.text) == ["persisted after enabling"])
    }

    /// Blank transcription has no accepted text, so it must not create a history row.
    @Test func blankTranscriptDoesNotRecordHistory() async {
        let h = makeHarness(transcript: " \n ")
        await recordAndFinish(h)

        #expect(await h.historyStore.appendRequests.isEmpty)
        #expect(h.inserter.inserted.isEmpty)
    }

    /// Provider failures happen before acceptance and must not leave history behind.
    @Test func transcriptionFailureDoesNotRecordHistory() async {
        let h = makeHarness()
        h.transcriber.result = .failure(MacomprendoError.providerUnreachable(endpointName: "Ollama (local)"))
        await recordAndFinish(h)

        #expect(await h.historyStore.appendRequests.isEmpty)
        #expect(h.inserter.inserted.isEmpty)
    }

    /// A provider-originated cancellation is not an accepted transcript.
    @Test func providerCancellationDoesNotRecordHistory() async {
        let h = makeHarness()
        h.transcriber.result = .failure(MacomprendoError.cancelled)
        await recordAndFinish(h)

        #expect(await h.historyStore.appendRequests.isEmpty)
        #expect(h.inserter.inserted.isEmpty)
    }

    /// A regression that records before transcription is accepted would leave a history
    /// row after an explicit cancellation while the provider is still transcribing.
    @Test func explicitCancellationBeforeTranscriptAcceptanceDoesNotRecordHistory() async {
        let h = makeHarness()
        h.transcriber.delay = .seconds(5)

        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value
        h.controller.handle(.keyUp(.dictate))
        await waitFor("state transcribing") { h.controller.state == .transcribing }

        let pending = h.controller.activeTask
        h.controller.cancel()
        await pending?.value

        #expect(await h.historyStore.appendRequests.isEmpty)
        #expect(h.inserter.inserted.isEmpty)
    }

    /// Cancelling after the history store has accepted an append but before it completes
    /// must leave that accepted row durable and stop before insertion starts.
    @Test func cancellationAfterHistoryAppendAcceptanceKeepsTheRowButDoesNotInsert() async {
        let h = makeHarness(transcript: "record then cancel")
        let appendGate = AsyncGate()
        await h.historyStore.setAppendGate(appendGate)

        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value
        h.controller.handle(.keyUp(.dictate))
        await waitFor("history append to suspend") { appendGate.waiterCount == 1 }

        let pending = h.controller.activeTask
        h.controller.cancel()
        #expect(await h.historyStore.appendRequests.map(\.text) == ["record then cancel"])
        #expect(h.inserter.inserted.isEmpty)

        appendGate.open()
        await pending?.value

        #expect(h.inserter.inserted.isEmpty)
    }

    /// Insertion can fail after acceptance; the history commit must already be durable.
    @Test func insertionFailureStillRecordsAcceptedTranscript() async {
        let h = makeHarness(transcript: "record despite insert failure")
        h.inserter.error = MacomprendoError.insertFailed
        await recordAndFinish(h)

        #expect(await h.historyStore.appendRequests.map(\.text) == ["record despite insert failure"])
        #expect(h.controller.state == .failed(ErrorText.describe(MacomprendoError.insertFailed)))
    }

    /// A history-store failure is a warning: insertion succeeds and the action remains idle.
    @Test func historyStoreFailureWarnsButStillInserts() async {
        let h = makeHarness(transcript: "insert despite history failure")
        await h.historyStore.setAppendError(MacomprendoError.dictationHistory("disk full"))
        await recordAndFinish(h)

        #expect(await h.historyStore.appendRequests.map(\.text) == ["insert despite history failure"])
        #expect(h.inserter.inserted.map(\.text) == ["insert despite history failure"])
        #expect(h.controller.state == .idle)
        guard case .error(let message) = h.hud.state else {
            Issue.record("Expected a user-visible history warning")
            return
        }
        #expect(message.contains("Dictation history is unavailable"))
    }

    /// A failed history write is non-fatal, but it must not replace the insertion failure
    /// that owns this action's terminal state and HUD while remaining visible in history.
    @Test func simultaneousHistoryAndInsertionFailuresKeepInsertionAsThePrimaryError() async {
        let h = makeHarness(transcript: "both failures")
        let insertionError = MacomprendoError.audio("Insertion service is unavailable.")
        let expectedHistoryError = MacomprendoError.dictationHistory(
            "An error occurred while accessing history.")
        h.inserter.error = insertionError
        await h.historyStore.setAppendError(MacomprendoError.dictationHistory("disk full"))

        await recordAndFinish(h)

        #expect(h.controller.state == .failed(ErrorText.describe(insertionError)))
        #expect(h.hud.state == .error(ErrorText.describe(insertionError)))
        #expect(h.history.errorMessage == ErrorText.describe(expectedHistoryError))
    }

    @Test func enabledTrailingSpaceIsInsertedButNotRecorded() async {
        let h = makeHarness(transcript: "  dictated text  ")
        h.settings.value.appendSpaceAfterDictation = true

        await recordAndFinish(h)

        #expect(await h.historyStore.appendRequests.map(\.text) == ["dictated text"])
        #expect(h.inserter.inserted.map(\.text) == ["dictated text "])
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
        #expect(await h.historyStore.appendRequests.map(\.text) == ["won't be shown"])
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
        h.recorder.triggerAutoStop()

        // Wait on the terminal state, not on `inserted`. `insert()` records its text and
        // only then does the cycle clear `isInserting` and settle `state`, so a wait that
        // stops at `inserted` can resume while the cycle is still finishing.
        await waitFor("implicit stop transcribes and inserts") {
            h.inserter.inserted.map(\.text) == ["capped"] && h.controller.state == .idle
        }
        #expect(h.controller.state == .idle)
        #expect(h.hud.state == .success(DictationController.recordingLimitMessage(seconds: 300)))
    }

    /// Once the cap is a value the user chose, reaching it must be visible: the HUD says the
    /// recording stopped because it reached the limit instead of reporting a plain insertion.
    @Test func hittingTheRecordingCapTellsTheUserWhyItStopped() async {
        let h = makeHarness(mode: .hold)
        h.settings.value.maximumRecordingSeconds = 600
        h.transcriber.result = .success("capped")

        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value
        h.recorder.triggerAutoStop()
        await waitFor("implicit stop transcribes and inserts") {
            h.inserter.inserted.map(\.text) == ["capped"] && h.controller.state == .idle
        }

        #expect(h.hud.state == .success("Stopped at the 10-minute limit"))
    }

    /// A recording the user ended themselves must not claim it hit the limit, including the
    /// one right after a capped recording.
    @Test func aNormalStopAfterACappedOneReportsPlainInsertion() async {
        let h = makeHarness(mode: .hold)
        h.transcriber.result = .success("capped")

        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value
        h.recorder.triggerAutoStop()
        await waitFor("capped cycle finishes") {
            h.inserter.inserted.count == 1 && h.controller.state == .idle
        }

        await recordAndFinish(h)

        #expect(h.hud.state == .success("Inserted"))
    }

    @Test func theRecordingLimitMessageNamesTheConfiguredMinutes() {
        #expect(DictationController.recordingLimitMessage(seconds: 60)
            == "Stopped at the 1-minute limit")
        #expect(DictationController.recordingLimitMessage(seconds: 300)
            == "Stopped at the 5-minute limit")
        #expect(DictationController.recordingLimitMessage(seconds: 90)
            == "Stopped at the 1.5-minute limit")
    }

    /// `AVAudioEngineRecorder`'s `level` stream is created once in `init` and shared by
    /// every recording that instance ever makes; the auto-stop signal must never finish
    /// it, or every recording after the first cap would have a dead meter and a dead
    /// cap-detection signal too.
    @Test func levelUpdatesStillReachTheHUDAfterAnEarlierRecordingHitTheCap() async {
        let h = makeHarness(mode: .hold)
        h.transcriber.result = .success("capped")

        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value
        h.recorder.triggerAutoStop()
        // `state == .idle` is the load-bearing half of this condition. `begin()` refuses to
        // start a new recording while `isInserting` is still set, and it refuses *silently* —
        // no new task is assigned, so the `await activeTask?.value` below would await the
        // previous cycle's task and the state assertion would see `.idle`. Waiting only for
        // `inserted` resumes inside that window whenever the machine is loaded enough to
        // delay the two statements that follow `insert()`.
        await waitFor("implicit stop transcribes and inserts") {
            h.inserter.inserted.map(\.text) == ["capped"] && h.controller.state == .idle
        }

        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value
        #expect(h.controller.state == .recording)

        h.recorder.emitLevel(0.5)
        await waitFor("HUD level update after an earlier cap") {
            if case .recording(let level, _) = h.hud.state { return level == 0.5 }
            return false
        }
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

    /// `startRecording()` has three suspension points (two `ensurePermission` awaits and
    /// `await pendingStopTask?.value`) with no `Task.isCancelled` check after any of them.
    /// Two `begin()`s racing through the mic-permission prompt could both reach
    /// `recorder.start()` — the second `begin()` cancels the first task, but if the first
    /// resumes from its permission await anyway and isn't checked, it starts the recorder
    /// too, hits the real recorder's double-start guard, and fails while the engine is
    /// genuinely recording.
    @Test func aSecondBeginDuringTheFirstsPermissionCheckCancelsTheFirstBeforeItCanStart() async {
        let h = makeHarness(mode: .hold)
        let gate = AsyncGate()
        h.permissions.statusGate = gate

        h.controller.handle(.keyDown(.dictate))   // task 1: suspends inside ensurePermission
        await waitFor("task 1 waiting on the permission check") { gate.waiterCount > 0 }
        let firstTask = h.controller.activeTask

        h.controller.handle(.keyDown(.dictate))   // task 2: cancels task 1, starts fresh
        gate.open()                                // let task 1's status(of:) resume (still granted)

        await firstTask?.value
        await h.controller.activeTask?.value

        #expect(h.controller.state == .recording)
        #expect(h.recorder.startCount == 1)
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

    @Test func startingDictationInToggleModeStartsTheEscapeMonitor() async {
        let h = makeHarness(mode: .toggle)
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

    /// `HTTPClient` maps both `CancellationError` and `URLError.cancelled` to
    /// `MacomprendoError.cancelled`, so a provider can throw it even when `cancel()` was
    /// never called (the controller's task itself isn't cancelled). That path must still
    /// stop the escape monitor and leave the HUD off `.transcribing`, not just the path
    /// that goes through `cancel()`.
    @Test func aProviderThrownCancelledErrorStopsTheMonitorAndHUDWithoutCancelBeingCalled() async {
        let h = makeHarness(mode: .hold)
        h.transcriber.result = .failure(MacomprendoError.cancelled)

        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value
        h.controller.handle(.keyUp(.dictate))
        await h.controller.activeTask?.value

        #expect(h.controller.state == .idle)
        #expect(h.escapeMonitor.isRunning == false)
        #expect(h.hud.state != .transcribing)
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
