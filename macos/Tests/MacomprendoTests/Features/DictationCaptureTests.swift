import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite final class DictationCaptureTests {
    private var transcripts: [String] = []
    private var errors: [Error] = []

    private func history(store: FakeDictationHistoryStore, enabled: Bool = true,
                         preference: Box<Bool>? = nil)
        -> DictationHistoryController {
        DictationHistoryController(store: store, pasteboard: ScriptedPasteboard(),
                                   isEnabled: { preference?.value ?? enabled })
    }

    private func make(mode: DictationMode = .hold,
                      recorder: any AudioRecording = ScriptedRecorder(),
                      transcriber: ScriptedTranscriber = ScriptedTranscriber(),
                      permissions: ScriptedPermissions = ScriptedPermissions(),
                      historyStore: FakeDictationHistoryStore = FakeDictationHistoryStore(),
                      historyEnabled: Bool = true) -> DictationCapture {
        let capture = DictationCapture(
            recorder: recorder,
            transcriberProvider: { transcriber },
            permissions: permissions,
            mode: { mode },
            language: { "en" },
            history: history(store: historyStore, enabled: historyEnabled))
        capture.onTranscript = { [weak self] in self?.transcripts.append($0) }
        capture.onError = { [weak self] in self?.errors.append($0) }
        return capture
    }

    @Test func holdModeRecordsOnKeyDownAndTranscribesOnKeyUp() async {
        let recorder = ScriptedRecorder()
        let capture = make(mode: .hold, recorder: recorder)

        capture.handle(.keyDown(.dictateAndRefine))
        #expect(capture.state == .recording)
        await capture.drain()
        #expect(recorder.startCount == 1)

        capture.handle(.keyUp(.dictateAndRefine))
        await capture.drain()
        #expect(recorder.stopCount == 1)
        #expect(transcripts == ["hello world"])
        #expect(capture.state == .idle)
        #expect(errors.isEmpty)
    }

    @Test func toggleModeStartsAndStopsOnSuccessivePresses() async {
        let recorder = ScriptedRecorder()
        let capture = make(mode: .toggle, recorder: recorder)

        capture.handle(.keyDown(.dictateAndRefine))
        capture.handle(.keyUp(.dictateAndRefine))          // ignored in toggle mode
        await capture.drain()
        #expect(capture.state == .recording)
        #expect(recorder.stopCount == 0)

        capture.handle(.keyDown(.dictateAndRefine))
        await capture.drain()
        #expect(transcripts == ["hello world"])
        #expect(capture.state == .idle)
    }

    @Test func savedRecordingIsEncodedAfterTranscriptDelivery() async {
        let store = FakeDictationHistoryStore()
        let encoder = FakeDictationAudioEncoder()
        let gate = AsyncGate()
        await encoder.setGate(gate)
        let history = DictationHistoryController(
            store: store, pasteboard: ScriptedPasteboard(), isEnabled: { true },
            encoder: encoder, shouldSaveRecording: { true })
        let recorder = ScriptedRecorder()
        recorder.samples = [0.3, -0.4]
        let capture = DictationCapture(
            recorder: recorder, transcriberProvider: { ScriptedTranscriber(text: "hello") },
            permissions: ScriptedPermissions(), mode: { .hold }, language: { "en" },
            history: history)
        capture.onTranscript = { [weak self] in self?.transcripts.append($0) }

        capture.handle(.keyDown(.dictateAndRefine))
        await capture.drain()
        capture.handle(.keyUp(.dictateAndRefine))
        await encoder.encodeInvoked.wait()

        #expect(transcripts == ["hello"])
        #expect(await encoder.requests.map(\.pcm) == [[0.3, -0.4]])
        gate.open()
        await capture.drain()
        #expect(await store.attachRequests == [.init(filename: "1.m4a", entryID: 1)])
    }

    @Test func disabledHistorySavesNeitherRowNorRecording() async {
        let store = FakeDictationHistoryStore()
        let encoder = FakeDictationAudioEncoder()
        let history = DictationHistoryController(
            store: store, pasteboard: ScriptedPasteboard(), isEnabled: { false },
            encoder: encoder, shouldSaveRecording: { true })
        let capture = DictationCapture(
            recorder: ScriptedRecorder(), transcriberProvider: { ScriptedTranscriber() },
            permissions: ScriptedPermissions(), mode: { .hold }, language: { "en" },
            history: history)

        capture.handle(.keyDown(.dictateAndRefine))
        await capture.drain()
        capture.handle(.keyUp(.dictateAndRefine))
        await capture.drain()

        #expect(await store.appendRequests.isEmpty)
        #expect(await encoder.requests.isEmpty)
    }

    /// The capture commit point must durable-write the accepted transcript before handing it
    /// to refinement; removing that write leaves Dictate & Refine absent from history.
    @Test func acceptedTranscriptIsRecordedBeforeItIsDeliveredForRefinement() async {
        let store = FakeDictationHistoryStore()
        let appendGate = AsyncGate()
        await store.setAppendGate(appendGate)
        let capture = DictationCapture(
            recorder: ScriptedRecorder(),
            transcriberProvider: { ScriptedTranscriber(text: "  hello world  ") },
            permissions: ScriptedPermissions(),
            mode: { .hold },
            language: { "en" },
            history: history(store: store))
        capture.onTranscript = { [weak self] in self?.transcripts.append($0) }

        capture.handle(.keyDown(.dictateAndRefine))
        await capture.drain()
        capture.handle(.keyUp(.dictateAndRefine))
        await waitFor("history append to suspend") { appendGate.waiterCount == 1 }

        #expect(await store.appendRequests.map(\.text) == ["hello world"])
        #expect(await store.appendRequests.map(\.kind) == [.dictationAndRefine])
        #expect(transcripts.isEmpty)

        appendGate.open()
        await capture.drain()
        #expect(transcripts == ["hello world"])
    }

    /// History is optional, so a failed durable write must warn once without discarding the
    /// accepted transcript that refinement needs to continue.
    @Test func historyFailureWarnsOnceAndStillDeliversTheTranscript() async {
        let store = FakeDictationHistoryStore()
        await store.setAppendError(MacomprendoError.dictationHistory("disk full"))
        var warnings: [MacomprendoError] = []
        let capture = DictationCapture(
            recorder: ScriptedRecorder(),
            transcriberProvider: { ScriptedTranscriber(text: "hello world") },
            permissions: ScriptedPermissions(),
            mode: { .hold },
            language: { "en" },
            history: history(store: store))
        capture.onTranscript = { [weak self] in self?.transcripts.append($0) }
        capture.onHistoryError = { warnings.append($0) }

        capture.handle(.keyDown(.dictateAndRefine))
        capture.handle(.keyUp(.dictateAndRefine))
        await capture.drain()

        #expect(await store.appendRequests.map(\.text) == ["hello world"])
        #expect(transcripts == ["hello world"])
        #expect(warnings == [.dictationHistory("An error occurred while accessing history.")])
        #expect(errors.isEmpty)
    }

    @Test func disabledHistoryDoesNotRecordAnAcceptedTranscript() async {
        let store = FakeDictationHistoryStore()
        let capture = DictationCapture(
            recorder: ScriptedRecorder(),
            transcriberProvider: { ScriptedTranscriber(text: "hello world") },
            permissions: ScriptedPermissions(),
            mode: { .hold },
            language: { "en" },
            history: history(store: store, enabled: false))

        capture.handle(.keyDown(.dictateAndRefine))
        capture.handle(.keyUp(.dictateAndRefine))
        await capture.drain()

        #expect(await store.appendRequests.isEmpty)
    }

    @Test func disablingHistoryBeforeRefineTranscriptAcceptancePreventsPersistence() async {
        let store = FakeDictationHistoryStore()
        let preference = Box(true)
        let transcriptionGate = AsyncGate()
        let capture = DictationCapture(
            recorder: ScriptedRecorder(),
            transcriberProvider: {
                ScriptedTranscriber(text: "not persisted", gate: transcriptionGate)
            },
            permissions: ScriptedPermissions(),
            mode: { .hold },
            language: { "en" },
            history: history(store: store, preference: preference))

        capture.handle(.keyDown(.dictateAndRefine))
        capture.handle(.keyUp(.dictateAndRefine))
        await waitFor("refine transcription to suspend") { transcriptionGate.waiterCount == 1 }
        preference.value = false
        transcriptionGate.open()
        await capture.drain()

        #expect(await store.appendRequests.isEmpty)
    }

    @Test func enablingHistoryBeforeRefineTranscriptAcceptancePermitsPersistence() async {
        let store = FakeDictationHistoryStore()
        let preference = Box(false)
        let transcriptionGate = AsyncGate()
        let capture = DictationCapture(
            recorder: ScriptedRecorder(),
            transcriberProvider: {
                ScriptedTranscriber(text: "persisted after enabling", gate: transcriptionGate)
            },
            permissions: ScriptedPermissions(),
            mode: { .hold },
            language: { "en" },
            history: history(store: store, preference: preference))

        capture.handle(.keyDown(.dictateAndRefine))
        capture.handle(.keyUp(.dictateAndRefine))
        await waitFor("refine transcription to suspend") { transcriptionGate.waiterCount == 1 }
        preference.value = true
        transcriptionGate.open()
        await capture.drain()

        #expect(await store.appendRequests.map(\.text) == ["persisted after enabling"])
    }

    @Test func blankTranscriptIsReportedAsNothingHeard() async {
        let store = FakeDictationHistoryStore()
        let capture = make(transcriber: ScriptedTranscriber(text: "   "), historyStore: store)
        capture.handle(.keyDown(.dictateAndRefine))
        capture.handle(.keyUp(.dictateAndRefine))
        await capture.drain()
        #expect(transcripts.isEmpty)
        #expect(errors.count == 1)
        #expect(errors.first as? MacomprendoError == MacomprendoError.audio("Nothing heard."))
        #expect(await store.appendRequests.isEmpty)
    }

    @Test func deniedMicrophonePermissionIsReported() async {
        let recorder = ScriptedRecorder()
        let capture = make(recorder: recorder,
                           permissions: ScriptedPermissions(current: .denied, afterRequest: .denied))
        capture.handle(.keyDown(.dictateAndRefine))
        await capture.drain()
        #expect(recorder.startCount == 0)
        #expect(errors.first as? MacomprendoError == MacomprendoError.permissionDenied(.microphone))
        #expect(capture.state == .idle)
    }

    @Test func transcriberFailureIsReportedAndStateReturnsToIdle() async {
        let store = FakeDictationHistoryStore()
        let capture = make(
            transcriber: ScriptedTranscriber(failure: .providerUnreachable(endpointName: "Ollama (local)")),
            historyStore: store)
        capture.handle(.keyDown(.dictateAndRefine))
        capture.handle(.keyUp(.dictateAndRefine))
        await capture.drain()
        #expect(transcripts.isEmpty)
        #expect(errors.first as? MacomprendoError
                == MacomprendoError.providerUnreachable(endpointName: "Ollama (local)"))
        #expect(capture.state == .idle)
        #expect(await store.appendRequests.isEmpty)
    }

    @Test func cancelDuringRecordingProducesNoTranscript() async {
        let recorder = ScriptedRecorder()
        let store = FakeDictationHistoryStore()
        let capture = make(recorder: recorder, historyStore: store)
        capture.handle(.keyDown(.dictateAndRefine))
        await capture.drain()
        capture.cancel()
        await capture.drain()
        #expect(capture.state == .idle)
        #expect(transcripts.isEmpty)
        #expect(errors.isEmpty)
        #expect(await store.appendRequests.isEmpty)
    }

    /// Catches overwriting the asynchronous cancel-stop task with a fast restart, which lets
    /// `recorder.start()` race the still-pending stop and invalidates the new capture generation.
    @Test func cancelledRecorderStopIsAwaitedBeforeAFastRestart() async {
        let recorder = FakeAudioRecorder()
        let capture = make(recorder: recorder)
        capture.handle(.keyDown(.dictateAndRefine))
        await capture.drain()
        #expect(capture.state == .recording)

        let stopGate = AsyncGate()
        recorder.stopGate = stopGate
        capture.cancel()
        await waitFor("cancelled recorder stop to suspend") { stopGate.waiterCount == 1 }

        capture.handle(.keyDown(.dictateAndRefine))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(recorder.startCount == 1)

        stopGate.open()
        await capture.drain()
        #expect(recorder.startCount == 2)
        #expect(recorder.isRecording)
        #expect(capture.state == .recording)
    }

    /// Overwriting stop 1's ownership with stop 2 lets stop 2 finish, starts the final
    /// recording, and then lets the orphaned stop 1 tear that recording down. Chaining every
    /// stop makes the same adversarial release order complete stop 1 before stop 2 instead.
    @Test func repeatedCancelStopsCannotFinishInReverseAndStopTheFinalRecording() async {
        let recorder = FakeAudioRecorder()
        let firstStop = FakeAudioRecorder.StopControl()
        let secondStop = FakeAudioRecorder.StopControl()
        recorder.enqueueStopControl(firstStop)
        recorder.enqueueStopControl(secondStop)
        let capture = make(recorder: recorder)

        capture.handle(.keyDown(.dictateAndRefine))
        await capture.drain()
        #expect(recorder.isRecording)

        capture.cancel()
        await firstStop.invoked.wait()
        capture.handle(.keyDown(.dictateAndRefine))
        capture.cancel()
        capture.handle(.keyDown(.dictateAndRefine))

        // Pre-release stop 2, then cross an acknowledged MainActor scheduling checkpoint.
        // With the ownership bug, stop 2 and the final restart complete before stop 1 is
        // released. With a stop chain, both tasks are suspended behind stop 1 here.
        secondStop.allowCompletion.open()
        let stopCheckpoint = Task { @MainActor in () }
        await stopCheckpoint.value
        let restartCheckpoint = Task { @MainActor in () }
        await restartCheckpoint.value

        firstStop.allowCompletion.open()
        await firstStop.completed.wait()
        await secondStop.completed.wait()
        await capture.drain()

        #expect(recorder.startCount == 2)
        #expect(recorder.stopCount == 2)
        #expect(recorder.isRecording)
        #expect(capture.state == .recording)
    }

    /// A new hold hotkey while the durable append is suspended cancels the superseded
    /// capture. The accepted row remains, but it must neither start another recorder
    /// nor deliver stale refinement work or a stale history warning after the append.
    /// This fails if capture becomes idle before its append finishes, or if the
    /// post-append cancellation guard is removed.
    @Test func newerHoldHotkeyAfterAcceptedHistoryAppendCancelsStaleCapture() async {
        let recorder = ScriptedRecorder()
        let store = FakeDictationHistoryStore()
        let appendGate = AsyncGate()
        await store.setAppendGate(appendGate)
        await store.setAppendError(MacomprendoError.dictationHistory("disk full"))
        var warnings: [MacomprendoError] = []
        let capture = DictationCapture(
            recorder: recorder,
            transcriberProvider: { ScriptedTranscriber(text: "record then supersede") },
            permissions: ScriptedPermissions(),
            mode: { .hold },
            language: { "en" },
            history: history(store: store))
        capture.onTranscript = { [weak self] in self?.transcripts.append($0) }
        capture.onHistoryError = { warnings.append($0) }

        capture.handle(.keyDown(.dictateAndRefine))
        await capture.drain()
        capture.handle(.keyUp(.dictateAndRefine))
        await waitFor("history append to suspend") { appendGate.waiterCount == 1 }

        let staleCompletion = Task { await capture.drain() }
        await Task.yield() // let the drainer snapshot the still-gated append task
        capture.handle(.keyDown(.dictateAndRefine))
        await capture.drain()
        #expect(await store.appendRequests.map(\.text) == ["record then supersede"])
        #expect(recorder.startCount == 1)

        appendGate.open()
        await staleCompletion.value

        #expect(transcripts.isEmpty)
        #expect(warnings.isEmpty)
        #expect(capture.state == .idle)
    }

    /// A cancelled append belongs to the capture generation that accepted it. Once a
    /// newer hold recording has started, resuming that stale append must not reset the
    /// newer recording to idle and make its key-up a no-op.
    @Test func staleAppendCompletionCannotClobberANewerRecording() async {
        let recorder = ScriptedRecorder()
        let store = FakeDictationHistoryStore()
        let appendGate = AsyncGate()
        await store.setAppendGate(appendGate)
        let capture = make(recorder: recorder, historyStore: store)

        capture.handle(.keyDown(.dictateAndRefine))
        await capture.drain()
        capture.handle(.keyUp(.dictateAndRefine))
        await waitFor("first history append to suspend") { appendGate.waiterCount == 1 }

        let staleCompletion = Task { await capture.drain() }
        await Task.yield() // let the drainer snapshot the still-gated append task
        capture.handle(.keyDown(.dictateAndRefine)) // cancel the stale generation
        await capture.drain()
        capture.handle(.keyDown(.dictateAndRefine)) // start a newer generation
        await capture.drain()
        #expect(capture.state == .recording)
        #expect(recorder.startCount == 2)

        appendGate.open()
        await staleCompletion.value

        #expect(capture.state == .recording)
        capture.handle(.keyUp(.dictateAndRefine))
        await capture.drain()

        #expect(capture.state == .idle)
        #expect(transcripts == ["hello world"])
        #expect(await store.appendRequests.map(\.text) == ["hello world", "hello world"])
        #expect(errors.isEmpty)
    }

    // MARK: - Fix-review findings

    /// `HTTPClient` maps transport-level cancellation (`URLError.cancelled`) to
    /// `MacomprendoError.cancelled`, and `DictationController` deliberately treats that
    /// identically to `CancellationError` — a provider-originated cancellation must not
    /// surface as a user-visible error here either.
    @Test func providerOriginatedCancelledErrorIsSwallowedSilently() async {
        let capture = make(transcriber: ScriptedTranscriber(failure: .cancelled))
        capture.handle(.keyDown(.dictateAndRefine))
        capture.handle(.keyUp(.dictateAndRefine))
        await capture.drain()
        #expect(transcripts.isEmpty)
        #expect(errors.isEmpty)
        #expect(capture.state == .idle)
    }

    /// `cancel()` during the permission-check window must stop `startRecording()`'s task
    /// from reaching `recorder.start()` — otherwise the mic starts untracked and the next
    /// `start()` fails with "Recording is already in progress."
    @Test func cancelDuringPermissionCheckPreventsARecorderStart() async {
        let recorder = ScriptedRecorder()
        let permissions = ScriptedPermissions()
        let gate = AsyncGate()
        permissions.statusGate = gate
        let capture = make(recorder: recorder, permissions: permissions)

        capture.handle(.keyDown(.dictateAndRefine))          // suspends inside the permission check
        await waitFor("permission check reached") { gate.waiterCount > 0 }

        capture.cancel()
        gate.open()                                          // let the suspended task resume, now cancelled

        await capture.drain()
        try? await Task.sleep(for: .milliseconds(20))        // let the orphaned first task settle

        #expect(recorder.startCount == 0)
        #expect(capture.state == .idle)
    }
}
