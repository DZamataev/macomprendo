import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite final class DictationCaptureTests {
    private var transcripts: [String] = []
    private var errors: [Error] = []

    private func make(mode: DictationMode = .hold,
                      recorder: ScriptedRecorder = ScriptedRecorder(),
                      transcriber: ScriptedTranscriber = ScriptedTranscriber(),
                      permissions: ScriptedPermissions = ScriptedPermissions()) -> DictationCapture {
        let capture = DictationCapture(
            recorder: recorder,
            transcriberProvider: { transcriber },
            permissions: permissions,
            mode: { mode },
            language: { "en" })
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

    @Test func blankTranscriptIsReportedAsNothingHeard() async {
        let capture = make(transcriber: ScriptedTranscriber(text: "   "))
        capture.handle(.keyDown(.dictateAndRefine))
        capture.handle(.keyUp(.dictateAndRefine))
        await capture.drain()
        #expect(transcripts.isEmpty)
        #expect(errors.count == 1)
        #expect(errors.first as? MacomprendoError == MacomprendoError.audio("Nothing heard."))
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
        let capture = make(transcriber: ScriptedTranscriber(failure: .providerUnreachable(endpointName: "Ollama (local)")))
        capture.handle(.keyDown(.dictateAndRefine))
        capture.handle(.keyUp(.dictateAndRefine))
        await capture.drain()
        #expect(transcripts.isEmpty)
        #expect(errors.first as? MacomprendoError
                == MacomprendoError.providerUnreachable(endpointName: "Ollama (local)"))
        #expect(capture.state == .idle)
    }

    @Test func cancelDuringRecordingProducesNoTranscript() async {
        let recorder = ScriptedRecorder()
        let capture = make(recorder: recorder)
        capture.handle(.keyDown(.dictateAndRefine))
        await capture.drain()
        capture.cancel()
        await capture.drain()
        #expect(capture.state == .idle)
        #expect(transcripts.isEmpty)
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
