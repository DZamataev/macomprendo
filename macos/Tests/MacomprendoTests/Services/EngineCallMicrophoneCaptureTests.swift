import AVFoundation
import Foundation
import Testing
@testable import Macomprendo

@Suite struct EngineCallMicrophoneCaptureTests {
    /// Every test hands the capture fakes for both the engine and the device list, so no test
    /// touches Core Audio, and an injected fixed clock, so a chunk's stamp is exact.
    private func make(_ engine: FakeAudioInputEngine = FakeAudioInputEngine(),
                      devices: FakeAudioInputDevices = FakeAudioInputDevices(),
                      clock: @escaping @Sendable () -> TimeInterval = { 100 })
        -> EngineCallMicrophoneCapture {
        EngineCallMicrophoneCapture(engine: engine, devices: devices, clock: clock)
    }

    /// Polls until `condition` holds: device-list changes reach the capture through an
    /// `AsyncStream`, so their effect lands a few hops after `emitChange()` returns.
    private func eventually(_ condition: @escaping () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func builtInDevices() -> FakeAudioInputDevices {
        FakeAudioInputDevices([.builtIn], defaultUID: AudioInputDevice.builtIn.uid)
    }

    private func stereoBuffer(left: Float, right: Float, frames: AVAudioFrameCount,
                              rate: Double = 44_100) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        buffer.floatChannelData?[0].update(repeating: left, count: Int(frames))
        buffer.floatChannelData?[1].update(repeating: right, count: Int(frames))
        return buffer
    }

    private func meanMagnitude(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return samples.reduce(0) { $0 + abs($1) } / Float(samples.count)
    }

    @Test func startBindsTheResolvedDeviceAndInstallsATap() throws {
        let engine = FakeAudioInputEngine()
        engine.deviceFormats[AudioInputDevice.builtIn.id] = FakeAudioInputEngine.monoFormat(44_100)
        let devices = FakeAudioInputDevices([.builtIn, .mchose], defaultUID: AudioInputDevice.mchose.uid)
        let capture = make(engine, devices: devices)
        capture.setPreferredInputDevice(uid: AudioInputDevice.builtIn.uid)

        try capture.start { _ in }

        #expect(engine.currentInputDevice == AudioInputDevice.builtIn.id)
        #expect(engine.hasTap)
        #expect(engine.tapFormats.last?.sampleRate == 44_100)
        #expect(engine.isRunning)
        #expect(engine.doubleTapInstalls == 0)
        capture.stop()
    }

    @Test func aStereoBufferArrivesResampledAndStampedOnTheHostClock() throws {
        let engine = FakeAudioInputEngine()
        let log = ChunkLog()
        let capture = make(engine, devices: builtInDevices())
        try capture.start { log.append($0) }

        engine.deliver(stereoBuffer(left: 0.5, right: 0.5, frames: 44_100))

        let chunk = try #require(log.all.first)
        #expect(abs(chunk.samples.count - 48_000) <= 64, "got \(chunk.samples.count) samples")
        #expect(chunk.time == 100 - Double(44_100) / 44_100, "stamp was \(chunk.time)")
        #expect(meanMagnitude(chunk.samples) > 0.3)
        capture.stop()
    }

    @Test func aConfigurationChangeRestartsTheStoppedEngineAndChunksKeepFlowing() throws {
        let engine = FakeAudioInputEngine(sampleRate: 44_100)
        let log = ChunkLog()
        let capture = make(engine, devices: builtInDevices())
        try capture.start { log.append($0) }
        engine.deliver(level: 0.5, frames: 4_410)
        #expect(log.all.count == 1)

        engine.loseCurrentDevice()

        #expect(engine.isRunning)
        #expect(engine.hasTap)
        #expect(engine.doubleTapInstalls == 0)
        engine.deliver(level: 0.5, frames: 4_410)
        #expect(log.all.count == 2)
        capture.stop()
    }

    @Test func aPreferredDeviceJoiningTheListSwitchesTheRunningCaptureToIt() async throws {
        let engine = FakeAudioInputEngine()
        let devices = builtInDevices()
        let capture = make(engine, devices: devices)
        capture.setPreferredInputDevice(uid: AudioInputDevice.mchose.uid)  // not connected yet
        try capture.start { _ in }
        #expect(engine.currentInputDevice == AudioInputDevice.builtIn.id)

        devices.devices = [.builtIn, .mchose]
        devices.emitChange()

        #expect(await eventually { engine.currentInputDevice == AudioInputDevice.mchose.id })
        #expect(engine.isRunning)
        #expect(engine.doubleTapInstalls == 0)
        capture.stop()
    }

    @Test func choosingAnotherDeviceMidRecordingMovesTheCaptureToIt() throws {
        let engine = FakeAudioInputEngine()
        let devices = FakeAudioInputDevices([.builtIn, .mchose], defaultUID: AudioInputDevice.mchose.uid)
        let capture = make(engine, devices: devices)
        try capture.start { _ in }
        #expect(engine.currentInputDevice == AudioInputDevice.mchose.id)

        capture.setPreferredInputDevice(uid: AudioInputDevice.builtIn.uid)

        #expect(engine.currentInputDevice == AudioInputDevice.builtIn.id)
        #expect(engine.isRunning)
        #expect(engine.doubleTapInstalls == 0)
        capture.stop()
    }

    @Test func stopRemovesTheTapAndNoChunkIsDeliveredAfterItReturns() throws {
        let engine = FakeAudioInputEngine()
        let log = ChunkLog()
        let capture = make(engine, devices: builtInDevices())
        try capture.start { log.append($0) }
        engine.deliver(level: 0.5, frames: 4_800)
        #expect(log.all.count == 1)

        // A buffer already in flight when `stop()` removed the tap: the block is gone from the
        // engine, but the audio thread may still be inside a copy of it.
        let inFlight = try #require(engine.installedTap)
        capture.stop()
        capture.stop()  // idempotent

        #expect(engine.hasTap == false)
        #expect(engine.isRunning == false)
        engine.deliver(level: 0.5, frames: 4_800)
        let late = AVAudioPCMBuffer(pcmFormat: FakeAudioInputEngine.monoFormat(48_000),
                                    frameCapacity: 4_800)!
        late.frameLength = 4_800
        inFlight(late)
        #expect(log.all.count == 1)
    }

    @Test func startWithNoInputDeviceAtAllThrows() {
        let engine = FakeAudioInputEngine()
        let capture = make(engine, devices: FakeAudioInputDevices([]))

        #expect(throws: MacomprendoError.audio("No microphone input is available.")) {
            try capture.start { _ in }
        }

        #expect(engine.hasTap == false)
        #expect(engine.isRunning == false)
    }

    @Test func whenTheEngineWillNotStartNoTapIsLeftBehind() throws {
        let engine = FakeAudioInputEngine()
        let capture = make(engine, devices: builtInDevices())
        engine.startError = MacomprendoError.audio("gone")

        #expect(throws: MacomprendoError.self) { try capture.start { _ in } }
        #expect(engine.hasTap == false)

        engine.startError = nil
        try capture.start { _ in }
        #expect(engine.doubleTapInstalls == 0)
        capture.stop()
    }

    @Test func aStartThatThrowsDoesNotRetainTheHandler() throws {
        let engine = FakeAudioInputEngine()
        let capture = make(engine, devices: builtInDevices())
        engine.startError = MacomprendoError.audio("gone")

        // The token's only other reference is the scope below: if the capture kept the handler
        // after the throw, it would outlive that scope.
        weak var weakToken: HandlerRetentionToken?
        do {
            let token = HandlerRetentionToken()
            weakToken = token
            #expect(throws: MacomprendoError.self) {
                try capture.start { _ in _ = token }
            }
        }

        #expect(weakToken == nil)
        #expect(engine.hasTap == false)
    }

    @Test func aStoppedCaptureStartsAgainWithTheNewHandler() throws {
        let engine = FakeAudioInputEngine()
        let first = ChunkLog()
        let second = ChunkLog()
        let capture = make(engine, devices: builtInDevices())
        try capture.start { first.append($0) }
        capture.stop()

        try capture.start { second.append($0) }
        engine.deliver(level: 0.5, frames: 4_800)

        #expect(first.all.isEmpty)
        #expect(second.all.count == 1)
        capture.stop()
    }

    @Test func aSecondStartWhileRunningThrows() throws {
        let engine = FakeAudioInputEngine()
        let capture = make(engine, devices: builtInDevices())
        try capture.start { _ in }

        #expect(throws: MacomprendoError.self) { try capture.start { _ in } }
        #expect(engine.doubleTapInstalls == 0)
        capture.stop()
    }
}

@Suite struct HostClockTests {
    @Test func nowIsAPositiveGrowingTime() {
        let before = HostClock.now()
        #expect(before > 0)
        #expect(HostClock.now() >= before)
    }

    @Test func secondsMatchesAVAudioTime() {
        let hostTime = mach_absolute_time()
        #expect(HostClock.seconds(forHostTime: hostTime) == AVAudioTime.seconds(forHostTime: hostTime))
    }
}

@Suite struct ScriptedCallCaptureTests {
    @Test func startStoresTheHandlerAndEmitReachesIt() throws {
        let capture = ScriptedCallCapture()
        let log = ChunkLog()
        try capture.start { log.append($0) }
        #expect(capture.isRunning)

        capture.emit(CallAudioChunk(samples: [0.1, 0.2], time: 12.5))

        #expect(log.all == [CallAudioChunk(samples: [0.1, 0.2], time: 12.5)])
        capture.stop()
        #expect(capture.isRunning == false)
        #expect(capture.startCount == 1)
        #expect(capture.stopCount == 1)
    }

    /// Lenient on purpose: a controller test may need to prove what it does with audio that
    /// arrives after the recording stopped.
    @Test func emitAfterStopStillReachesTheHandler() throws {
        let capture = ScriptedCallCapture()
        let log = ChunkLog()
        try capture.start { log.append($0) }
        capture.stop()

        capture.emit(CallAudioChunk(samples: [0.3], time: 2))

        #expect(log.all.count == 1)
    }

    @Test func startThrowsTheScriptedError() {
        let capture = ScriptedCallCapture()
        capture.startError = MacomprendoError.audio("no device")

        #expect(throws: MacomprendoError.audio("no device")) {
            try capture.start { _ in }
        }

        #expect(capture.isRunning == false)
    }

    @Test func aSecondStartWhileRunningThrows() throws {
        let capture = ScriptedCallCapture()
        try capture.start { _ in }

        #expect(throws: MacomprendoError.self) { try capture.start { _ in } }
        capture.stop()
    }

    @Test func setPreferredInputDeviceRecordsTheChoice() {
        let capture = ScriptedCallCapture()
        capture.setPreferredInputDevice(uid: AudioInputDevice.builtIn.uid)
        capture.setPreferredInputDevice(uid: nil)
        #expect(capture.preferredInputDeviceUIDs == [AudioInputDevice.builtIn.uid, nil])
    }

    /// The real capture holds its state lock across the handler call, so a handler that calls
    /// back into it deadlocks. The fake must report that rather than let a controller ship a
    /// design that hangs the app.
    @Test func aHandlerThatCallsStopSynchronouslyRecordsAnIssue() throws {
        let capture = ScriptedCallCapture()
        try capture.start { _ in
            withKnownIssue("handler re-entered the capture synchronously") {
                capture.stop()
            }
        }

        capture.emit(CallAudioChunk(samples: [0.1], time: 1))

        #expect(capture.isRunning == false)
        #expect(capture.stopCount == 1)
    }

    @Test func aHandlerThatSwitchesDeviceSynchronouslyRecordsAnIssue() throws {
        let capture = ScriptedCallCapture()
        try capture.start { _ in
            withKnownIssue("handler re-entered the capture synchronously") {
                capture.setPreferredInputDevice(uid: nil)
            }
        }

        capture.emit(CallAudioChunk(samples: [0.1], time: 1))

        #expect(capture.preferredInputDeviceUIDs == [nil])
    }
}

/// A token a test can watch through a weak reference, to prove a handler closure was released.
private final class HandlerRetentionToken: @unchecked Sendable {}

/// Collects the chunks a capture delivers, from whichever thread it delivers them on.
final class ChunkLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [CallAudioChunk] = []

    func append(_ chunk: CallAudioChunk) { lock.withLock { items.append(chunk) } }
    var all: [CallAudioChunk] { lock.withLock { items } }
}
