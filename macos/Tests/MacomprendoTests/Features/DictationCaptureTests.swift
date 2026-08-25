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
}
