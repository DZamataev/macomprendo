import Foundation
import Testing
@testable import Macomprendo

@Suite struct AVAudioEngineRecorderTests {
    /// Every test hands the recorder fakes for both the engine and the device list, so no
    /// test touches Core Audio.
    private func make(_ engine: FakeAudioInputEngine = FakeAudioInputEngine(),
                      devices: FakeAudioInputDevices = FakeAudioInputDevices()) -> AVAudioEngineRecorder {
        AVAudioEngineRecorder(maxDuration: 5, engine: engine, devices: devices)
    }

    /// Polls until `condition` holds: device-list changes reach the recorder through an
    /// `AsyncStream`, so their effect lands a few hops after `emitChange()` returns.
    private func eventually(_ condition: @escaping () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test func targetSampleRateIs16kHz() {
        #expect(AVAudioEngineRecorder.targetSampleRate == 16_000)
    }

    @Test func aFreshRecorderIsNotRecording() async {
        let recorder: any AudioRecording = make()
        #expect(await recorder.isRecording == false)
    }

    @Test func stoppingWithoutStartingReturnsNoSamples() async {
        let recorder: any AudioRecording = make()
        #expect(await recorder.stop().isEmpty)
    }

    /// The crash: the input device changed mid-recording, the engine stopped itself with the
    /// tap still installed, `stop()` skipped the tap because the engine was no longer
    /// running, and the next `start()` installed a second tap — an uncatchable exception.
    @Test func aDeviceSwitchMidRecordingDoesNotLeaveATapBehind() throws {
        let engine = FakeAudioInputEngine()
        let recorder = make(engine)
        try recorder.start()
        engine.switchInputDevice(to: FakeAudioInputEngine.monoFormat(44_100))
        engine.stop()  // whatever the recovery did, the engine may still end up stopped
        _ = recorder.stop()
        #expect(engine.hasTap == false)

        try recorder.start()
        #expect(engine.doubleTapInstalls == 0)
        _ = recorder.stop()
    }

    @Test func recordingCarriesOnOnTheNewDeviceAfterASwitch() throws {
        let engine = FakeAudioInputEngine(sampleRate: 48_000)
        let recorder = make(engine)
        try recorder.start()
        engine.deliver(level: 0.5, frames: 4_800)

        engine.switchInputDevice(to: FakeAudioInputEngine.monoFormat(16_000))
        #expect(engine.isRunning)
        #expect(engine.doubleTapInstalls == 0)
        #expect(engine.tapFormats.last?.sampleRate == 16_000)
        engine.deliver(level: 0.25, frames: 1_600)

        let samples = recorder.stop()
        #expect(samples.count > 1_600)
        #expect(abs((samples.last ?? 0) - 0.25) < 0.01)
        #expect(engine.hasTap == false)
    }

    @Test func aDeviceSwitchWhileIdleTouchesNothing() {
        let engine = FakeAudioInputEngine()
        _ = make(engine)
        engine.switchInputDevice(to: FakeAudioInputEngine.monoFormat(44_100))
        #expect(engine.isRunning == false)
        #expect(engine.hasTap == false)
    }

    @Test func aNewDeviceThatWillNotStartStillLetsStopReturnWhatWasCaptured() throws {
        let engine = FakeAudioInputEngine(sampleRate: 16_000)
        let recorder = make(engine)
        try recorder.start()
        engine.deliver(level: 0.5, frames: 1_600)
        engine.startError = MacomprendoError.audio("gone")
        engine.switchInputDevice(to: FakeAudioInputEngine.monoFormat(48_000))
        #expect(engine.hasTap == false)
        #expect(recorder.stop().count > 0)
    }

    // MARK: - Choosing the input device

    @Test func withNoPreferenceItRecordsFromTheSystemDefault() throws {
        let engine = FakeAudioInputEngine()
        let devices = FakeAudioInputDevices([.builtIn, .mchose], defaultUID: AudioInputDevice.mchose.uid)
        let recorder = make(engine, devices: devices)
        try recorder.start()
        #expect(engine.currentInputDevice == AudioInputDevice.mchose.id)
        _ = recorder.stop()
    }

    @Test func aPreferredDeviceIsUsedInsteadOfTheSystemDefault() throws {
        let engine = FakeAudioInputEngine()
        engine.deviceFormats[AudioInputDevice.builtIn.id] = FakeAudioInputEngine.monoFormat(44_100)
        let devices = FakeAudioInputDevices([.builtIn, .mchose], defaultUID: AudioInputDevice.mchose.uid)
        let recorder = make(engine, devices: devices)
        recorder.setPreferredInputDevice(uid: AudioInputDevice.builtIn.uid)
        try recorder.start()
        #expect(engine.currentInputDevice == AudioInputDevice.builtIn.id)
        #expect(engine.tapFormats.last?.sampleRate == 44_100)
        _ = recorder.stop()
    }

    /// Handy's behaviour, minus forgetting the choice: an absent preferred device falls back
    /// to the system default, and the preference survives for when it comes back.
    @Test func aDisconnectedPreferredDeviceFallsBackToTheSystemDefault() throws {
        let engine = FakeAudioInputEngine()
        let devices = FakeAudioInputDevices([.builtIn], defaultUID: AudioInputDevice.builtIn.uid)
        let recorder = make(engine, devices: devices)
        recorder.setPreferredInputDevice(uid: AudioInputDevice.mchose.uid)
        try recorder.start()
        #expect(engine.currentInputDevice == AudioInputDevice.builtIn.id)
        _ = recorder.stop()

        devices.devices = [.builtIn, .mchose]
        try recorder.start()
        #expect(engine.currentInputDevice == AudioInputDevice.mchose.id)
        _ = recorder.stop()
    }

    @Test func theDeviceIsNotReselectedWhenItIsAlreadyCurrent() throws {
        let engine = FakeAudioInputEngine()
        let devices = FakeAudioInputDevices([.builtIn], defaultUID: AudioInputDevice.builtIn.uid)
        let recorder = make(engine, devices: devices)
        try recorder.start()
        _ = recorder.stop()
        try recorder.start()
        _ = recorder.stop()
        #expect(engine.selectedDevices == [AudioInputDevice.builtIn.id])
    }

    @Test func losingThePreferredDeviceMidRecordingMovesToTheSystemDefault() throws {
        let engine = FakeAudioInputEngine()
        let devices = FakeAudioInputDevices([.builtIn, .mchose], defaultUID: AudioInputDevice.builtIn.uid)
        let recorder = make(engine, devices: devices)
        recorder.setPreferredInputDevice(uid: AudioInputDevice.mchose.uid)
        try recorder.start()
        engine.deliver(level: 0.5, frames: 4_800)

        devices.devices = [.builtIn]
        engine.loseCurrentDevice()

        #expect(engine.currentInputDevice == AudioInputDevice.builtIn.id)
        #expect(engine.isRunning)
        #expect(engine.doubleTapInstalls == 0)
        engine.deliver(level: 0.25, frames: 4_800)
        #expect(recorder.stop().count > 1_600)
    }

    /// The reported case: a silent headset dongle is the system default, and the user picks
    /// the built-in microphone in the Sound menu while recording.
    @Test func followingTheSystemDefaultSwitchesWhenTheDefaultChangesMidRecording() async throws {
        let engine = FakeAudioInputEngine()
        let devices = FakeAudioInputDevices([.builtIn, .mchose], defaultUID: AudioInputDevice.mchose.uid)
        let recorder = make(engine, devices: devices)
        try recorder.start()
        #expect(engine.currentInputDevice == AudioInputDevice.mchose.id)

        devices.defaultUID = AudioInputDevice.builtIn.uid
        devices.emitChange()

        #expect(await eventually { engine.currentInputDevice == AudioInputDevice.builtIn.id })
        #expect(engine.isRunning)
        #expect(engine.doubleTapInstalls == 0)
        _ = recorder.stop()
        #expect(engine.hasTap == false)
    }

    @Test func aPreferredDeviceIgnoresChangesToTheSystemDefault() async throws {
        let engine = FakeAudioInputEngine()
        let devices = FakeAudioInputDevices([.builtIn, .mchose], defaultUID: AudioInputDevice.builtIn.uid)
        let recorder = make(engine, devices: devices)
        recorder.setPreferredInputDevice(uid: AudioInputDevice.mchose.uid)
        try recorder.start()

        devices.defaultUID = AudioInputDevice.builtIn.uid
        devices.emitChange()
        try await Task.sleep(for: .milliseconds(50))

        #expect(engine.selectedDevices == [AudioInputDevice.mchose.id])
        _ = recorder.stop()
    }

    @Test func choosingADeviceMidRecordingSwitchesToIt() throws {
        let engine = FakeAudioInputEngine()
        let devices = FakeAudioInputDevices([.builtIn, .mchose], defaultUID: AudioInputDevice.mchose.uid)
        let recorder = make(engine, devices: devices)
        try recorder.start()
        recorder.setPreferredInputDevice(uid: AudioInputDevice.builtIn.uid)
        #expect(engine.currentInputDevice == AudioInputDevice.builtIn.id)
        #expect(engine.isRunning)
        #expect(engine.doubleTapInstalls == 0)
        _ = recorder.stop()
    }

    @Test func deviceListChangesWhileIdleTouchNothing() async throws {
        let engine = FakeAudioInputEngine()
        let devices = FakeAudioInputDevices([.builtIn], defaultUID: AudioInputDevice.builtIn.uid)
        _ = make(engine, devices: devices)
        devices.emitChange()
        try await Task.sleep(for: .milliseconds(50))
        #expect(engine.selectedDevices.isEmpty)
        #expect(engine.isRunning == false)
    }

    // MARK: - Falling back from a device that delivers no signal

    /// Feeds `seconds` of a constant level at 16 kHz in 0.1 s buffers.
    private func feed(_ engine: FakeAudioInputEngine, level: Float, seconds: Double) {
        for _ in 0..<Int(seconds * 10) { engine.deliver(level: level, frames: 1_600) }
    }

    private func collectFallbacks(_ recorder: AVAudioEngineRecorder) -> FallbackLog {
        let log = FallbackLog()
        let stream = recorder.inputFallbacks()
        Task { for await fallback in stream { log.append(fallback) } }
        return log
    }

    /// The reported case: a headset dongle is plugged in with the headset off, so the
    /// default input delivers digital silence. The recording moves to a device that works.
    @Test func aSilentDefaultFallsBackToTheBuiltInMicrophone() async throws {
        let engine = FakeAudioInputEngine(sampleRate: 16_000)
        let devices = FakeAudioInputDevices([.mchose, .builtIn], defaultUID: AudioInputDevice.mchose.uid)
        let recorder = make(engine, devices: devices)
        let log = collectFallbacks(recorder)
        try recorder.start()

        feed(engine, level: 0, seconds: 2.5)

        #expect(await eventually { engine.currentInputDevice == AudioInputDevice.builtIn.id })
        #expect(await eventually { log.all == [InputFallback(from: "MCHOSE V9", to: "MacBook Pro Microphone")] })
        #expect(engine.isRunning)
        #expect(engine.doubleTapInstalls == 0)
        _ = recorder.stop()
    }

    @Test func aSilentPreferredDeviceFallsBackToTheSystemDefault() async throws {
        let engine = FakeAudioInputEngine(sampleRate: 16_000)
        let devices = FakeAudioInputDevices([.builtIn, .mchose], defaultUID: AudioInputDevice.builtIn.uid)
        let recorder = make(engine, devices: devices)
        recorder.setPreferredInputDevice(uid: AudioInputDevice.mchose.uid)
        try recorder.start()
        feed(engine, level: 0, seconds: 2.5)
        #expect(await eventually { engine.currentInputDevice == AudioInputDevice.builtIn.id })
        _ = recorder.stop()
    }

    /// A working microphone in a quiet room sits around −66 dBFS between words — under the
    /// silence gate's −60, but far from the digital zeros of a dead device.
    @Test func aQuietButLiveMicrophoneIsKept() async throws {
        let engine = FakeAudioInputEngine(sampleRate: 16_000)
        let devices = FakeAudioInputDevices([.mchose, .builtIn], defaultUID: AudioInputDevice.mchose.uid)
        let recorder = make(engine, devices: devices)
        try recorder.start()
        feed(engine, level: 0.0005, seconds: 4)
        try await Task.sleep(for: .milliseconds(50))
        #expect(engine.selectedDevices == [AudioInputDevice.mchose.id])
        _ = recorder.stop()
    }

    @Test func aShortPauseIsNotMistakenForADeadDevice() async throws {
        let engine = FakeAudioInputEngine(sampleRate: 16_000)
        let devices = FakeAudioInputDevices([.mchose, .builtIn], defaultUID: AudioInputDevice.mchose.uid)
        let recorder = make(engine, devices: devices)
        try recorder.start()
        feed(engine, level: 0, seconds: 1.5)
        feed(engine, level: 0.3, seconds: 0.1)
        feed(engine, level: 0, seconds: 1.5)
        try await Task.sleep(for: .milliseconds(50))
        #expect(engine.selectedDevices == [AudioInputDevice.mchose.id])
        _ = recorder.stop()
    }

    /// A device-list change after the fallback must not resolve straight back to the silent
    /// device the recording just left.
    @Test func aDeviceChangeAfterAFallbackDoesNotReturnToTheSilentDevice() async throws {
        let engine = FakeAudioInputEngine(sampleRate: 16_000)
        let devices = FakeAudioInputDevices([.mchose, .builtIn], defaultUID: AudioInputDevice.mchose.uid)
        let recorder = make(engine, devices: devices)
        try recorder.start()
        feed(engine, level: 0, seconds: 2.5)
        #expect(await eventually { engine.currentInputDevice == AudioInputDevice.builtIn.id })

        devices.emitChange()
        engine.loseCurrentDevice()
        try await Task.sleep(for: .milliseconds(50))
        #expect(engine.currentInputDevice == AudioInputDevice.builtIn.id)
        _ = recorder.stop()
    }

    /// The fallback lasts one recording: the headset may be switched on by the next one.
    @Test func theNextRecordingTriesTheChosenDeviceAgain() async throws {
        let engine = FakeAudioInputEngine(sampleRate: 16_000)
        let devices = FakeAudioInputDevices([.mchose, .builtIn], defaultUID: AudioInputDevice.mchose.uid)
        let recorder = make(engine, devices: devices)
        try recorder.start()
        feed(engine, level: 0, seconds: 2.5)
        #expect(await eventually { engine.currentInputDevice == AudioInputDevice.builtIn.id })
        _ = recorder.stop()

        try recorder.start()
        #expect(engine.currentInputDevice == AudioInputDevice.mchose.id)
        _ = recorder.stop()
    }

    /// With every device silent the recording tries each once and then stays put, rather
    /// than cycling through them for the rest of the recording.
    @Test func whenEveryDeviceIsSilentItTriesEachOnceAndStops() async throws {
        let engine = FakeAudioInputEngine(sampleRate: 16_000)
        let devices = FakeAudioInputDevices([.mchose, .builtIn], defaultUID: AudioInputDevice.mchose.uid)
        let recorder = make(engine, devices: devices)
        let log = collectFallbacks(recorder)
        try recorder.start()
        feed(engine, level: 0, seconds: 2.5)
        #expect(await eventually { engine.currentInputDevice == AudioInputDevice.builtIn.id })
        feed(engine, level: 0, seconds: 5)
        try await Task.sleep(for: .milliseconds(50))
        #expect(engine.selectedDevices == [AudioInputDevice.mchose.id, AudioInputDevice.builtIn.id])
        #expect(log.all.count == 1)
        _ = recorder.stop()
    }

    @Test func withNoOtherDeviceTheRecordingStaysWhereItIs() async throws {
        let engine = FakeAudioInputEngine(sampleRate: 16_000)
        let devices = FakeAudioInputDevices([.mchose], defaultUID: AudioInputDevice.mchose.uid)
        let recorder = make(engine, devices: devices)
        let log = collectFallbacks(recorder)
        try recorder.start()
        feed(engine, level: 0, seconds: 3)
        try await Task.sleep(for: .milliseconds(50))
        #expect(engine.selectedDevices == [AudioInputDevice.mchose.id])
        #expect(engine.isRunning)
        #expect(log.all.isEmpty)
        _ = recorder.stop()
    }
}

final class FallbackLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [InputFallback] = []
    func append(_ item: InputFallback) { lock.withLock { items.append(item) } }
    var all: [InputFallback] { lock.withLock { items } }
}

@Suite struct InputDeviceResolutionTests {
    private let both: [AudioInputDevice] = [.builtIn, .mchose]

    @Test func noPreferencePicksTheDefault() {
        #expect(AVAudioEngineRecorder.resolveInputDevice(
            preferredUID: nil, devices: both, systemDefault: .mchose) == .mchose)
    }

    @Test func aConnectedPreferenceWins() {
        #expect(AVAudioEngineRecorder.resolveInputDevice(
            preferredUID: AudioInputDevice.builtIn.uid, devices: both, systemDefault: .mchose) == .builtIn)
    }

    @Test func aMissingPreferenceFallsBackToTheDefault() {
        #expect(AVAudioEngineRecorder.resolveInputDevice(
            preferredUID: "gone", devices: both, systemDefault: .mchose) == .mchose)
    }

    @Test func anExcludedPreferenceFallsBackToTheDefault() {
        #expect(AVAudioEngineRecorder.resolveInputDevice(
            preferredUID: AudioInputDevice.mchose.uid, devices: both, systemDefault: .builtIn,
            excluding: [AudioInputDevice.mchose.uid]) == .builtIn)
    }

    @Test func anExcludedDefaultFallsBackToTheBuiltInMicrophone() {
        let usb = AudioInputDevice(id: 200, uid: "USB-MIC", name: "USB Mic")
        #expect(AVAudioEngineRecorder.resolveInputDevice(
            preferredUID: nil, devices: [usb, .mchose, .builtIn], systemDefault: .mchose,
            excluding: [AudioInputDevice.mchose.uid]) == .builtIn)
    }

    @Test func withoutABuiltInMicrophoneTheFirstOtherDeviceIsUsed() {
        let usb = AudioInputDevice(id: 200, uid: "USB-MIC", name: "USB Mic")
        #expect(AVAudioEngineRecorder.resolveInputDevice(
            preferredUID: nil, devices: [.mchose, usb], systemDefault: .mchose,
            excluding: [AudioInputDevice.mchose.uid]) == usb)
    }

    @Test func everythingExcludedResolvesToNothing() {
        #expect(AVAudioEngineRecorder.resolveInputDevice(
            preferredUID: nil, devices: both, systemDefault: .mchose,
            excluding: [AudioInputDevice.mchose.uid, AudioInputDevice.builtIn.uid]) == nil)
    }

    @Test func noDevicesAtAllResolvesToNothing() {
        #expect(AVAudioEngineRecorder.resolveInputDevice(
            preferredUID: nil, devices: [], systemDefault: nil) == nil)
    }
}

@Suite struct FakeAudioRecorderTests {
    @Test func recordsStartAndStopAndReturnsScriptedSamples() async throws {
        let recorder = FakeAudioRecorder()
        recorder.samplesToReturn = [0.1, 0.2, 0.3]
        try await recorder.start()
        #expect(recorder.isRecording == true)
        let samples = await recorder.stop()
        #expect(samples == [0.1, 0.2, 0.3])
        #expect(recorder.startCount == 1)
        #expect(recorder.stopCount == 1)
        #expect(recorder.isRecording == false)
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
