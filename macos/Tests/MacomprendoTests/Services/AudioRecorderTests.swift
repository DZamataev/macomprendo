import Foundation
import Testing
@testable import Macomprendo

@Suite struct AVAudioEngineRecorderTests {
    @Test func targetSampleRateIs16kHz() {
        #expect(AVAudioEngineRecorder.targetSampleRate == 16_000)
    }

    @Test func aFreshRecorderIsNotRecording() async {
        let recorder: any AudioRecording = AVAudioEngineRecorder(maxDuration: 5)
        #expect(await recorder.isRecording == false)
    }

    @Test func stoppingWithoutStartingReturnsNoSamples() async {
        let recorder: any AudioRecording = AVAudioEngineRecorder(maxDuration: 5)
        #expect(await recorder.stop().isEmpty)
    }
}

@Suite struct FakeAudioRecorderTests {
    @Test func recordsStartAndStopAndReturnsScriptedSamples() async throws {
        let recorder = FakeAudioRecorder()
        recorder.samplesToReturn = [0.1, 0.2, 0.3]
        try await recorder.start()
        #expect(await recorder.isRecording == true)
        let samples = await recorder.stop()
        #expect(samples == [0.1, 0.2, 0.3])
        #expect(recorder.startCount == 1)
        #expect(recorder.stopCount == 1)
        #expect(await recorder.isRecording == false)
    }

    @Test func startThrowsTheScriptedError() async {
        let recorder = FakeAudioRecorder()
        recorder.startError = MacomprendoError.audio("no device")
        await #expect(throws: MacomprendoError.audio("no device")) {
            try await recorder.start()
        }
    }

    @Test func emitLevelReachesTheLevelStream() async {
        let recorder = FakeAudioRecorder()
        var iterator = recorder.level.makeAsyncIterator()
        recorder.emitLevel(0.75)
        #expect(await iterator.next() == 0.75)
    }
}
