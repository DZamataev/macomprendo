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
        let reviewPresenter: FakeCorrectionReviewPresenter
        /// How many times the controller asked for the glossary. Zero proves the master
        /// switch is read before anything is built or matched.
        let glossaryRequests: Box<Int>
        /// The controller's clock, so elapsed-time behaviour is asserted without sleeping.
        let clock: Box<Date>
        /// The controller's sleep. Nothing it is asked to wait for ends until a test releases it.
        let sleeper: GatedSleeper
    }

    private func makeHarness(mode: DictationMode = .hold,
                             insertMethod: InsertMethod = .auto,
                             historyEnabled: Bool = true,
                             recordingEnabled: Bool = false,
                             transcript: String? = nil,
                             glossaryEnabled: Bool = false,
                             glossary: Glossary = Glossary(),
                             hudPresenter: (any HUDPresenting)? = nil) -> Harness {
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
        let hud = HUDController(presenter: hudPresenter,
                                sleep: { _ in try? await Task.sleep(for: .seconds(3600)) })
        let pasteboard = FakePasteboard()
        let settings = SettingsHolder()
        settings.value.dictationMode = mode
        settings.value.insertMethod = insertMethod
        settings.value.transcriptionLanguage = "en"
        settings.value.dictationHistoryEnabled = historyEnabled
        settings.value.saveOriginalRecording = recordingEnabled
        settings.value.glossaryEnabled = glossaryEnabled
        let glossaryRequests = Box(0)
        let clock = Box(Date(timeIntervalSince1970: 1_000))
        let escapeMonitor = FakeEscapeMonitor()
        let historyStore = FakeDictationHistoryStore()
        let encoder = FakeDictationAudioEncoder()
        let history = DictationHistoryController(store: historyStore,
                                                  pasteboard: pasteboard,
                                                  isEnabled: { settings.value.dictationHistoryEnabled },
                                                  encoder: encoder,
                                                  shouldSaveRecording: {
                                                      settings.value.saveOriginalRecording
                                                  },
                                                  recordingFormat: {
                                                      settings.value.savedRecordingFormat
                                                  })
        if let transcript { transcriber.result = .success(transcript) }
        let reviewPresenter = FakeCorrectionReviewPresenter()
        let sleeper = GatedSleeper()

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
            history: history,
            reviewPresenter: reviewPresenter,
            glossary: {
                glossaryRequests.value += 1
                return glossary
            },
            now: { clock.value },
            sleep: { await sleeper.sleep($0) })
        return Harness(controller: controller, recorder: recorder, transcriber: transcriber,
                       inserter: inserter, tracker: tracker, permissions: permissions,
                       hud: hud, pasteboard: pasteboard, settings: settings, escapeMonitor: escapeMonitor,
                       historyStore: historyStore, history: history, encoder: encoder,
                       reviewPresenter: reviewPresenter,
                       glossaryRequests: glossaryRequests, clock: clock, sleeper: sleeper)
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

    // MARK: - What the row records about the run

    // Catches a row that names no model, or names the wrong one: two months from now the
    // corpus cannot answer "what transcribed this" from anything else.
    @Test func aDictationRecordsTheModelEngineLanguageAndVersion() async {
        let h = makeHarness(historyEnabled: true, transcript: "dictated")
        h.settings.value.transcriptionSource = .local(modelID: "large-v3-turbo")
        h.settings.value.transcriptionLanguage = "ru"

        await recordAndFinish(h)

        let run = await h.historyStore.appendRequests.first?.run
        #expect(run?.modelID == "large-v3-turbo")
        #expect(run?.engine == LocalEngine.whisperCpp.rawValue)
        #expect(run?.language == "ru")
        #expect(run?.appVersion == TranscriptionRun.currentAppVersion)
        // Nothing normalises text yet, so the raw transcript is not a second copy of it.
        #expect(await h.historyStore.appendRequests.first?.rawText == nil)
    }

    @Test func anEndpointDictationRecordsTheEndpointEngineAndItsModel() async {
        let h = makeHarness(historyEnabled: true, transcript: "dictated")
        h.settings.value.transcriptionSource = .endpoint(id: UUID(), model: "whisper-1")
        h.settings.value.transcriptionLanguage = nil

        await recordAndFinish(h)

        let run = await h.historyStore.appendRequests.first?.run
        #expect(run?.engine == "endpoint")
        #expect(run?.modelID == "whisper-1")
        #expect(run?.language == nil)
    }

    // `shortDictationInsertsOK` short-circuits to the literal "OK" without running a model.
    // No model produced that text and there is no audio worth keeping, so it writes no row.
    @Test func shortDictationWritesNoHistoryRow() async {
        let h = makeHarness(historyEnabled: true, recordingEnabled: true, transcript: "never used")
        h.settings.value.shortDictationInsertsOK = true
        h.recorder.samplesToReturn = [0.1, 0.2]

        await recordAndFinish(h)

        #expect(h.inserter.inserted.map(\.text) == ["OK"])
        #expect(await h.historyStore.appendRequests.isEmpty)
        #expect(await h.encoder.requests.isEmpty)
        #expect(h.hud.state == .hidden)
        #expect(h.history.errorMessage == nil)
    }

    // The short tap's "OK" lands in the user's document, which is its own confirmation. The
    // cycle ends with the HUD dismissed — not "Inserted", and not left on "Transcribing".
    @Test func shortDictationEndsWithTheHUDDismissedRatherThanASuccessMessage() async {
        let presenter = FakeHUDPresenter()
        let h = makeHarness(historyEnabled: false, transcript: "never used", hudPresenter: presenter)
        h.settings.value.shortDictationInsertsOK = true
        h.recorder.samplesToReturn = [0.1, 0.2]

        await recordAndFinish(h)

        #expect(h.inserter.inserted.map(\.text) == ["OK"])
        #expect(h.controller.state == .idle)
        #expect(h.hud.state == .hidden)
        #expect(presenter.dismissCount == 1)
    }

    // The same short buffer with the feature off goes to the model: that is a real
    // transcription, however short, and keeps its row and its model attribution.
    @Test func aShortSpokenDictationWithTheShortTapFeatureOffStillWritesItsRow() async {
        let h = makeHarness(historyEnabled: true, transcript: "да")
        h.settings.value.shortDictationInsertsOK = false
        h.recorder.samplesToReturn = [0.1, 0.2]

        await recordAndFinish(h)

        #expect(h.transcriber.received.count == 1)
        #expect(h.inserter.inserted.map(\.text) == ["да"])
        let requests = await h.historyStore.appendRequests
        #expect(requests.map(\.text) == ["да"])
        #expect(requests.first?.run != nil)
    }

    // A pack may list `ok` as a term. The short tap's "OK" is then rewritten, but no model
    // produced it and there is no correction of a model to explain: no review is shown.
    @Test func shortDictationPresentsNoReviewEvenWhenTheGlossaryContainsOK() async {
        let h = makeHarness(historyEnabled: true, transcript: "never used",
                            glossaryEnabled: true, glossary: Self.glossary("ok"))
        h.settings.value.shortDictationInsertsOK = true
        h.recorder.samplesToReturn = [0.1, 0.2]

        await recordAndFinish(h)

        #expect(h.transcriber.received.isEmpty)
        #expect(h.inserter.inserted.count == 1)
        #expect(h.reviewPresenter.presented.isEmpty)
        #expect(await h.historyStore.appendRequests.isEmpty)
    }

    // Control for the test above: the same pack does fire a review when a model produced
    // the "OK", so the absence above is not the glossary failing to match.
    @Test func aTranscribedOKMatchingTheGlossaryStillPresentsAReview() async {
        let h = makeHarness(transcript: "OK", glossaryEnabled: true, glossary: Self.glossary("ok"))
        h.settings.value.shortDictationInsertsOK = false
        h.recorder.samplesToReturn = [0.1, 0.2]

        await recordAndFinish(h)

        #expect(h.transcriber.received.count == 1)
        #expect(h.reviewPresenter.presented.count == 1)
    }

    // A dictation too short to hold audio has nothing to save, and saying so reads as a
    // failure the user has to act on. It inserted "OK" and lost nothing — the HUD must show
    // the success, not "Saving the recording failed: there was nothing to encode".
    @Test func aShortDictationWithNothingToSaveShowsNoError() async {
        let h = makeHarness(historyEnabled: true, recordingEnabled: true, transcript: "never used")
        h.settings.value.shortDictationInsertsOK = true
        h.recorder.samplesToReturn = []

        await recordAndFinish(h)

        #expect(h.inserter.inserted.map(\.text) == ["OK"])
        #expect(h.hud.state == .hidden)
        #expect(await h.encoder.requests.isEmpty)
        #expect(h.history.errorMessage == nil)
    }

    // MARK: - The recording format

    @Test func theRecordingIsEncodedInTheFormatCurrentlyInSettings() async {
        let h = makeHarness(historyEnabled: true, recordingEnabled: true, transcript: "saved")
        h.settings.value.savedRecordingFormat = .lossless

        await recordAndFinish(h)

        #expect(await h.encoder.requests.map(\.format) == [.lossless])
    }

    @Test func theDefaultRecordingFormatIsCompressed() async {
        let h = makeHarness(historyEnabled: true, recordingEnabled: true, transcript: "saved")

        await recordAndFinish(h)

        #expect(await h.encoder.requests.map(\.format) == [.aac])
    }

    // MARK: - The glossary

    private static func glossary(_ terms: String...) -> Glossary {
        Glossary(packs: [GlossaryPack.parse(terms.joined(separator: "\n"), name: "test")])
    }

    @Test func glossaryOffInsertsAndRecordsTheModelsTextAndNeverAsksForTheGlossary() async {
        let h = makeHarness(historyEnabled: true,
                            transcript: "Открыл Xcode build",
                            glossaryEnabled: false,
                            glossary: Self.glossary("xcodebuild"))

        await recordAndFinish(h)

        #expect(h.inserter.inserted.map(\.text) == ["Открыл Xcode build"])
        let request = await h.historyStore.appendRequests.first
        #expect(request?.text == "Открыл Xcode build")
        #expect(request?.rawText == nil)
        #expect(h.glossaryRequests.value == 0)
    }

    @Test func glossaryOnWithAHitInsertsTheCorrectionAndRecordsTheModelsOwnText() async {
        let h = makeHarness(historyEnabled: true,
                            transcript: "Открыл Xcode build",
                            glossaryEnabled: true,
                            glossary: Self.glossary("xcodebuild"))

        await recordAndFinish(h)

        #expect(h.inserter.inserted.map(\.text) == ["Открыл xcodebuild"])
        let request = await h.historyStore.appendRequests.first
        #expect(request?.text == "Открыл xcodebuild")
        #expect(request?.rawText == "Открыл Xcode build")
    }

    // The column exists so a corpus can measure the model rather than our corrections:
    // a duplicate of `text` destroys exactly that distinction.
    @Test func glossaryOnWithoutAHitRecordsNoRawText() async {
        let h = makeHarness(historyEnabled: true,
                            transcript: "Открыл терминал",
                            glossaryEnabled: true,
                            glossary: Self.glossary("xcodebuild"))

        await recordAndFinish(h)

        #expect(h.inserter.inserted.map(\.text) == ["Открыл терминал"])
        let request = await h.historyStore.appendRequests.first
        #expect(request?.text == "Открыл терминал")
        #expect(request?.rawText == nil)
    }

    // MARK: - The correction review

    @Test func noRewritesPresentsNothing() async {
        let h = makeHarness(transcript: "Открыл терминал",
                            glossaryEnabled: true,
                            glossary: Self.glossary("xcodebuild"))

        await recordAndFinish(h)

        #expect(h.inserter.inserted.map(\.text) == ["Открыл терминал"])
        #expect(h.reviewPresenter.presented.isEmpty)
    }

    @Test func glossaryOffPresentsNothing() async {
        let h = makeHarness(transcript: "Открыл Xcode build",
                            glossaryEnabled: false,
                            glossary: Self.glossary("xcodebuild"))

        await recordAndFinish(h)

        #expect(h.inserter.inserted.map(\.text) == ["Открыл Xcode build"])
        #expect(h.reviewPresenter.presented.isEmpty)
    }

    @Test func oneRewritePresentsItWithItsOriginal() async {
        let h = makeHarness(transcript: "Открыл Xcode build",
                            glossaryEnabled: true,
                            glossary: Self.glossary("xcodebuild"))

        await recordAndFinish(h)

        #expect(h.reviewPresenter.presented.count == 1)
        guard let review = h.reviewPresenter.presented.first else { return }
        #expect(review.text == "Открыл xcodebuild")
        #expect(review.rewrites.map(\.original) == ["Xcode build"])
        #expect(review.rewrites.map(\.term) == ["xcodebuild"])
        // The range must index the presented text, not the transcript: the view underlines
        // with it, and a range computed against the model's words points at the wrong span.
        #expect(review.rewrites.map { String(review.text[$0.range]) } == ["xcodebuild"])
    }

    @Test func severalRewritesArePresentedInDocumentOrder() async {
        let h = makeHarness(transcript: "Открыл Xcode build и TS Config JSON",
                            glossaryEnabled: true,
                            glossary: Self.glossary("xcodebuild", "tsconfig.json"))

        await recordAndFinish(h)

        #expect(h.reviewPresenter.presented.count == 1)
        guard let review = h.reviewPresenter.presented.first else { return }
        #expect(review.text == "Открыл xcodebuild и tsconfig.json")
        #expect(review.rewrites.map(\.original) == ["Xcode build", "TS Config JSON"])
        #expect(review.rewrites.map { String(review.text[$0.range]) }
            == ["xcodebuild", "tsconfig.json"])
        // Document order is the order of the ranges, not merely the order the matcher
        // happened to append them in.
        let starts = review.rewrites.map(\.range.lowerBound)
        #expect(starts == starts.sorted())
    }

    /// Presentation follows insertion. A panel describing text that never reached the user's
    /// document is worse than no panel: it claims a correction was delivered when it was not.
    @Test func aFailedInsertPresentsNothing() async {
        let h = makeHarness(transcript: "Открыл Xcode build",
                            glossaryEnabled: true,
                            glossary: Self.glossary("xcodebuild"))
        h.inserter.error = MacomprendoError.insertFailed

        await recordAndFinish(h)

        #expect(h.inserter.inserted.isEmpty)
        #expect(h.reviewPresenter.presented.isEmpty)
    }

    /// Any other insertion failure is equally not an insertion.
    @Test func anInsertThatFailsWithoutTheClipboardFallbackPresentsNothing() async {
        let h = makeHarness(transcript: "Открыл Xcode build",
                            glossaryEnabled: true,
                            glossary: Self.glossary("xcodebuild"))
        h.inserter.error = MacomprendoError.permissionDenied(.accessibility)

        await recordAndFinish(h)

        #expect(h.reviewPresenter.presented.isEmpty)
    }

    @Test func aSecondDictationReplacesRatherThanStacks() async {
        let h = makeHarness(transcript: "Открыл Xcode build",
                            glossaryEnabled: true,
                            glossary: Self.glossary("xcodebuild", "tsconfig.json"))

        await recordAndFinish(h)
        h.transcriber.result = .success("Правил TS Config JSON")
        await recordAndFinish(h)

        #expect(h.reviewPresenter.presented.count == 2)
        // The second review carries only the second dictation's rewrite: a panel that
        // accumulated would describe text the user has already moved past.
        #expect(h.reviewPresenter.presented.map(\.text)
            == ["Открыл xcodebuild", "Правил tsconfig.json"])
        #expect(h.reviewPresenter.presented.map { $0.rewrites.map(\.original) }
            == [["Xcode build"], ["TS Config JSON"]])
    }

    /// A review describes the dictation that produced it. The moment the next recording
    /// starts, whatever is still on screen describes text the user has moved past.
    @Test func aNewDictationTakesTheEarlierReviewDown() async {
        let h = makeHarness(transcript: "Открыл Xcode build",
                            glossaryEnabled: true,
                            glossary: Self.glossary("xcodebuild"))

        await recordAndFinish(h)
        #expect(h.reviewPresenter.presented.count == 1)
        #expect(h.reviewPresenter.dismissCount == 0)

        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value

        #expect(h.reviewPresenter.dismissCount == 1)
    }

    /// The same boundary, on a cycle that never reaches a review of its own: the stale panel
    /// must not outlive the dictation it belonged to just because the next one failed.
    @Test func aDictationThatFailsStillTakesTheEarlierReviewDown() async {
        let h = makeHarness(transcript: "Открыл Xcode build",
                            glossaryEnabled: true,
                            glossary: Self.glossary("xcodebuild"))

        await recordAndFinish(h)
        #expect(h.reviewPresenter.presented.count == 1)

        h.transcriber.result = .failure(MacomprendoError.providerUnreachable(endpointName: "Test"))
        await recordAndFinish(h)

        #expect(h.reviewPresenter.dismissCount == 1)
        #expect(h.reviewPresenter.presented.count == 1)
    }

    /// The trailing space is an insertion detail, not part of what was corrected, so the
    /// review shows the corrected text the ranges were computed against.
    @Test func theReviewShowsTheCorrectedTextWithoutTheAppendedSpace() async {
        let h = makeHarness(transcript: "Открыл Xcode build",
                            glossaryEnabled: true,
                            glossary: Self.glossary("xcodebuild"))
        h.settings.value.appendSpaceAfterDictation = true

        await recordAndFinish(h)

        #expect(h.inserter.inserted.map(\.text) == ["Открыл xcodebuild "])
        #expect(h.reviewPresenter.presented.map(\.text) == ["Открыл xcodebuild"])
    }

    // MARK: - The silence gate

    /// Longer than `shortDictationMaximumSamples` (half a second at 16 kHz).
    private static func zeros(seconds: Double) -> [Float] {
        Array(repeating: 0, count: Int(16_000 * seconds))
    }

    @Test func anAllZeroRecordingNeverReachesTheModel() async {
        let h = makeHarness(historyEnabled: true, recordingEnabled: true, transcript: "you")
        h.recorder.samplesToReturn = Self.zeros(seconds: 2)

        await recordAndFinish(h)

        #expect(h.transcriber.received.isEmpty)
        #expect(h.inserter.inserted.isEmpty)
        #expect(await h.historyStore.appendRequests.isEmpty)
        #expect(await h.encoder.requests.isEmpty)
        guard case .error(let message) = h.hud.state else {
            Issue.record("Expected the silent-capture error, got \(h.hud.state)")
            return
        }
        #expect(message.contains("No sound was captured"))
        #expect(message.contains("input device"))
    }

    /// The boundary is inclusive upward: a borderline-quiet real recording is kept.
    @Test func aRecordingAtTheSilenceThresholdStillReachesTheModel() async {
        let h = makeHarness(transcript: "barely audible")
        var samples = Self.zeros(seconds: 2)
        samples[100] = AudioMath.silenceThreshold

        h.recorder.samplesToReturn = samples
        await recordAndFinish(h)

        #expect(h.transcriber.received.count == 1)
        #expect(h.inserter.inserted.map(\.text) == ["barely audible"])
    }

    @Test func aNormalRecordingIsUnaffectedByTheGate() async {
        let h = makeHarness(transcript: "hello world")
        h.recorder.samplesToReturn = [0.1, -0.4, 0.9, 0.2]

        await recordAndFinish(h)

        #expect(h.transcriber.received.count == 1)
        #expect(h.inserter.inserted.map(\.text) == ["hello world"])
    }

    /// Sixteen of the twenty-five measured silent files took the short-dictation path and
    /// behaved correctly: the gate sits after it, so a deliberate short tap still works.
    @Test func aShortSilentTapStillInsertsOK() async {
        let h = makeHarness(historyEnabled: true, transcript: "never used")
        h.settings.value.shortDictationInsertsOK = true
        h.recorder.samplesToReturn = Array(repeating: 0, count: 100)

        await recordAndFinish(h)

        #expect(h.transcriber.received.isEmpty)
        #expect(h.inserter.inserted.map(\.text) == ["OK"])
        #expect(await h.historyStore.appendRequests.isEmpty)
    }

    /// With the short-tap feature off, a buffer shorter than the cutoff is still silence.
    @Test func aShortSilentRecordingIsGatedWhenTheShortTapFeatureIsOff() async {
        let h = makeHarness(transcript: "you")
        h.settings.value.shortDictationInsertsOK = false
        h.recorder.samplesToReturn = Array(repeating: 0, count: 100)

        await recordAndFinish(h)

        #expect(h.transcriber.received.isEmpty)
        #expect(h.inserter.inserted.isEmpty)
    }

    /// The measured failure: 4.2 s of digital silence — the length of history row 308 —
    /// went to the model, which returned `you`, and it was pasted into a document.
    @Test func fourPointTwoSecondsOfZerosProducesNoModelCall() async {
        let h = makeHarness(historyEnabled: true, recordingEnabled: true, transcript: "you")
        h.recorder.samplesToReturn = Self.zeros(seconds: 4.2)

        await recordAndFinish(h)

        #expect(h.transcriber.received.isEmpty)
        #expect(h.inserter.inserted.isEmpty)
        #expect(await h.historyStore.appendRequests.isEmpty)
    }

    // MARK: - The live no-input warning

    /// Emits one level and waits for the HUD to act on it, so the levels a test scripts are
    /// consumed one at a time: the recorder's stream is buffered, and two levels yielded
    /// back to back can both be read after a later clock change.
    private func emit(_ level: Float, elapsed: TimeInterval, into h: Harness) async {
        h.recorder.emitLevel(level)
        await waitFor("the HUD to consume level \(level) at \(elapsed)s") {
            switch h.hud.state {
            case .recording(let shown, let shownElapsed):
                return shown == level && shownElapsed == elapsed
            case .recordingNoInput(let shownElapsed):
                return shownElapsed == elapsed
            default:
                return false
            }
        }
    }

    private func advance(_ seconds: TimeInterval, _ h: Harness) {
        h.clock.value = h.clock.value.addingTimeInterval(seconds)
    }

    @Test func threeSecondsOfZeroLevelWarnsWhileRecordingContinues() async {
        let h = makeHarness(mode: .hold)
        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value

        advance(1, h)
        await emit(0, elapsed: 1, into: h)
        advance(3, h)
        await emit(0, elapsed: 4, into: h)

        #expect(h.hud.state == .recordingNoInput(elapsed: 4))
        #expect(h.controller.state == .recording)
        #expect(h.recorder.stopCount == 0)
    }

    @Test func aNonZeroLevelBeforeThreeSecondsDoesNotWarn() async {
        let h = makeHarness(mode: .hold)
        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value

        advance(1, h)
        await emit(0, elapsed: 1, into: h)
        advance(2, h)
        await emit(0, elapsed: 3, into: h)

        // Two seconds of silence, one short of the warning.
        #expect(h.hud.state == .recording(level: 0, elapsed: 3))
    }

    @Test func aNonZeroLevelClearsTheWarning() async {
        let h = makeHarness(mode: .hold)
        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value

        advance(1, h)
        await emit(0, elapsed: 1, into: h)
        advance(3, h)
        await emit(0, elapsed: 4, into: h)
        #expect(h.hud.state == .recordingNoInput(elapsed: 4))

        advance(1, h)
        await emit(0.7, elapsed: 5, into: h)
        #expect(h.hud.state == .recording(level: 0.7, elapsed: 5))

        // And the silent run restarts from here rather than resuming the old one.
        advance(2, h)
        await emit(0, elapsed: 7, into: h)
        #expect(h.hud.state == .recording(level: 0, elapsed: 7))
        #expect(h.controller.state == .recording)
    }

    /// A new recording must not inherit the previous one's silent stretch.
    @Test func theWarningStateDoesNotCarryIntoTheNextRecording() async {
        let h = makeHarness(mode: .hold, transcript: "spoken")
        h.recorder.samplesToReturn = [0.5, -0.5]
        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value
        advance(1, h)
        await emit(0, elapsed: 1, into: h)
        advance(3, h)
        await emit(0, elapsed: 4, into: h)
        #expect(h.hud.state == .recordingNoInput(elapsed: 4))
        h.controller.handle(.keyUp(.dictate))
        await h.controller.activeTask?.value

        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value
        advance(2, h)
        await emit(0, elapsed: 2, into: h)

        #expect(h.hud.state == .recording(level: 0, elapsed: 2))
    }

    // MARK: - The short-tap window

    /// Gives queued MainActor work — a level from the recorder's stream, a released sleep —
    /// the chance to run, where there is no visible state change to wait on.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(20))
    }

    /// Waits until the controller has asked to wait out `count` short-tap windows, so a test
    /// never releases a window that has not been requested yet.
    private func windowsRequested(_ count: Int, _ h: Harness) async {
        await waitFor("\(count) short-tap window(s) to be requested") {
            h.sleeper.requests.count >= count
        }
    }

    private func makeShortTapHarness(transcript: String? = nil,
                                     presenter: FakeHUDPresenter) -> Harness {
        let h = makeHarness(mode: .hold, historyEnabled: false, transcript: transcript,
                            hudPresenter: presenter)
        h.settings.value.shortDictationInsertsOK = true
        return h
    }

    /// The window is the short-tap threshold itself — 8 000 samples at 16 kHz — read as
    /// time. Stated in seconds here, independently of how the controller derives it, so a
    /// delay of zero, or one that drifts from the threshold, fails.
    @Test func theRecordingHUDWaitsHalfASecondWhenTheShortTapFeatureIsOn() async {
        let presenter = FakeHUDPresenter()
        let h = makeShortTapHarness(presenter: presenter)

        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value
        await windowsRequested(1, h)

        #expect(h.controller.state == .recording)
        #expect(h.sleeper.requests == [0.5])
        #expect(DictationController.shortTapWindow
            == Double(DictationController.shortDictationMaximumSamples)
                / AVAudioEngineRecorder.targetSampleRate)
        #expect(h.hud.state == .hidden)
        #expect(presenter.presentCount == 0)
    }

    @Test func aTapReleasedInsideTheWindowShowsNoHUDAtAll() async {
        let presenter = FakeHUDPresenter()
        let h = makeShortTapHarness(transcript: "never used", presenter: presenter)
        h.recorder.samplesToReturn = [0.1, 0.2]

        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value
        await windowsRequested(1, h)
        h.recorder.emitLevel(0.6)
        await settle()
        h.controller.handle(.keyUp(.dictate))
        await h.controller.activeTask?.value
        // The window ending after the release must not bring the HUD up either.
        h.sleeper.release(0)
        await settle()

        #expect(h.inserter.inserted.map(\.text) == ["OK"])
        #expect(h.hud.state == .hidden)
        #expect(presenter.presentCount == 0)
    }

    @Test func aPressHeldPastTheWindowShowsTheHUDOnceWithItsRealElapsedTime() async {
        let presenter = FakeHUDPresenter()
        let h = makeShortTapHarness(presenter: presenter)

        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value
        await windowsRequested(1, h)
        advance(0.25, h)
        h.recorder.emitLevel(0.6)
        await settle()
        #expect(h.hud.state == .hidden)

        advance(0.5, h)
        h.sleeper.release(0)
        await waitFor("the HUD to appear after the window") { h.hud.state != .hidden }

        #expect(h.hud.state == .recording(level: 0.6, elapsed: 0.75))
        #expect(presenter.presentCount == 1)
        #expect(h.controller.state == .recording)

        // And from here the meter behaves as it always has.
        advance(0.25, h)
        await emit(0.3, elapsed: 1.0, into: h)
    }

    @Test func withTheShortTapFeatureOffTheHUDAppearsImmediately() async {
        let presenter = FakeHUDPresenter()
        let h = makeHarness(mode: .hold, hudPresenter: presenter)
        h.settings.value.shortDictationInsertsOK = false

        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value

        #expect(h.hud.state == .recording(level: 0, elapsed: 0))
        #expect(presenter.presentCount == 1)
        #expect(h.sleeper.requests.isEmpty)
    }

    @Test func aPendingHUDDoesNotFireAfterItsCycleWasCancelled() async {
        let presenter = FakeHUDPresenter()
        let h = makeShortTapHarness(presenter: presenter)

        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value
        await windowsRequested(1, h)
        h.controller.cancel()
        #expect(h.hud.state == .toast("Cancelled"))

        h.sleeper.release(0)
        await settle()

        #expect(h.hud.state == .toast("Cancelled"))
        #expect(h.controller.state == .idle)
    }

    /// A new press starts a new window. The previous press's window ending must not reveal
    /// the HUD over the new recording before its own window is over.
    @Test func aPendingHUDDoesNotFireOverTheNextRecording() async {
        let presenter = FakeHUDPresenter()
        let h = makeShortTapHarness(presenter: presenter)

        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value
        await windowsRequested(1, h)
        h.controller.cancel()
        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value
        await windowsRequested(2, h)
        #expect(h.controller.state == .recording)
        #expect(h.sleeper.requests.count == 2)

        h.sleeper.release(0)
        await settle()
        #expect(h.hud.state == .toast("Cancelled"))

        h.sleeper.release(1)
        await waitFor("the second recording's HUD") {
            if case .recording = h.hud.state { return true }
            return false
        }
    }

    /// Released inside the window, but the buffer turns out long enough to transcribe: the
    /// model runs, and the user must see that it is working.
    @Test func aReleaseInsideTheWindowThatStillTranscribesShowsTranscribing() async {
        let presenter = FakeHUDPresenter()
        let h = makeShortTapHarness(transcript: "spoken", presenter: presenter)
        h.recorder.samplesToReturn = Array(repeating: 0.3, count: 16_000)
        let gate = AsyncGate()
        h.transcriber.gate = gate

        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value
        await windowsRequested(1, h)
        h.controller.handle(.keyUp(.dictate))
        await waitFor("the transcribing HUD") { h.hud.state == .transcribing }

        gate.open()
        await h.controller.activeTask?.value
        #expect(h.inserter.inserted.map(\.text) == ["spoken"])
        #expect(h.hud.state == .success("Inserted"))
    }

    /// The warning counts from the first silent level, which arrives before the HUD does.
    /// Counting from the reveal instead would hold it back by the length of the window.
    @Test func theNoInputWarningCountsFromTheRecordingNotFromTheHUD() async {
        let presenter = FakeHUDPresenter()
        let h = makeShortTapHarness(presenter: presenter)

        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value
        await windowsRequested(1, h)
        advance(0.125, h)
        h.recorder.emitLevel(0)
        await settle()
        #expect(h.hud.state == .hidden)

        advance(0.5, h)
        h.sleeper.release(0)
        await waitFor("the HUD to appear after the window") { h.hud.state != .hidden }
        #expect(h.hud.state == .recording(level: 0, elapsed: 0.625))

        advance(2.5, h)
        await emit(0, elapsed: 3.125, into: h)
        #expect(h.hud.state == .recordingNoInput(elapsed: 3.125))
    }

    @Test func theCapStillEndsARecordingHeldPastTheWindow() async {
        let presenter = FakeHUDPresenter()
        let h = makeShortTapHarness(transcript: "capped", presenter: presenter)
        h.recorder.samplesToReturn = Array(repeating: 0.3, count: 16_000)

        h.controller.handle(.keyDown(.dictate))
        await h.controller.activeTask?.value
        await windowsRequested(1, h)
        h.sleeper.release(0)
        await waitFor("the HUD to appear after the window") { h.hud.state != .hidden }
        h.recorder.triggerAutoStop()
        await waitFor("the capped recording to insert") {
            h.inserter.inserted.map(\.text) == ["capped"] && h.controller.state == .idle
        }

        #expect(h.hud.state == .success(DictationController.recordingLimitMessage(seconds: 300)))
    }
}
