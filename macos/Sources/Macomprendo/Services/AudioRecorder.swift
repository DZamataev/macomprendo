// @preconcurrency: AVFAudio's completion-handler based APIs (AVAudioConverter.convert,
// the input tap block) predate Swift concurrency and aren't Sendable-audited, so Swift 6
// strict concurrency treats every capture crossing them as a potential data race even
// though they are, in practice, called synchronously on the calling thread.
@preconcurrency import AVFoundation
import CoreAudio
import Foundation

protocol AudioRecording: AnyObject, Sendable {
    /// RMS level 0…1, roughly ten values per second while recording. Lives as long as the
    /// recorder itself and is never finished — a capped recording must not be the last one
    /// a caller can ever get level updates for.
    var level: AsyncStream<Float> { get }
    /// Fires once whenever the recorder auto-stops after hitting its maximum duration —
    /// the only signal a caller gets that a session ended without an explicit `stop()`
    /// call. Separate from `level` so reaching the cap never has to finish that stream.
    var autoStopped: AsyncStream<Void> { get }
    /// The cap on one recording, in seconds. Applies from the next `start()`; a recording
    /// already running keeps the cap it began with.
    func setMaximumDuration(_ seconds: TimeInterval)
    /// The input device to record from, by Core Audio UID. `nil` follows the system default,
    /// and so does a chosen device that is not connected. Applies at once, including to a
    /// recording in progress.
    func setPreferredInputDevice(uid: String?)
    /// A fresh stream per caller of the fallbacks from a silent input device. Several
    /// controllers share one recorder, and an `AsyncStream` can be iterated only once.
    func inputFallbacks() -> AsyncStream<InputFallback>
    func start() async throws
    /// Returns everything captured since `start()`, as 16 kHz mono Float32 PCM.
    func stop() async -> [Float]
    var isRecording: Bool { get async }
}

/// The recording left an input device that delivered no signal at all and carries on from
/// another one. Names, not ids: this is what the HUD tells the user.
struct InputFallback: Equatable, Sendable {
    let from: String
    let to: String

    /// What the user is told. Here rather than in a view so the Dictate HUD and the
    /// Dictate & Refine toast cannot word it differently.
    var message: String { Self.message(to: to, from: from) }

    static func message(to: String, from: String) -> String {
        "No signal from \(from) — switched to \(to)"
    }
}

/// Fans one sequence of fallbacks out to every subscriber.
final class InputFallbackBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<InputFallback>.Continuation] = [:]

    init() {}

    func subscribe() -> AsyncStream<InputFallback> {
        AsyncStream(bufferingPolicy: .bufferingNewest(4)) { continuation in
            let id = UUID()
            lock.withLock { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                _ = self.lock.withLock { self.continuations.removeValue(forKey: id) }
            }
        }
    }

    func yield(_ fallback: InputFallback) {
        for continuation in lock.withLock({ Array(continuations.values) }) {
            continuation.yield(fallback)
        }
    }
}

/// The input side of `AVAudioEngine` the recorder drives: bus 0 of its input node, the
/// device that node reads from, and the configuration-change signal the engine posts when
/// that device changes under it. A seam so device handling is unit-tested against a fake.
protocol AudioInputEngine: AnyObject {
    /// The hardware format of the current input device.
    var inputFormat: AVAudioFormat { get }
    var isRunning: Bool { get }
    /// The Core Audio device the input node is bound to, if it can be read.
    var currentInputDevice: AudioDeviceID? { get }
    /// Called, on an arbitrary thread, after the engine has stopped itself because its I/O
    /// configuration changed — the device went away or the system default moved. The tap
    /// stays installed.
    var onConfigurationChange: (@Sendable () -> Void)? { get set }
    /// Binds the input node to `device`. Only valid while the engine is stopped.
    func setInputDevice(_ device: AudioDeviceID) throws
    func installTap(bufferSize: AVAudioFrameCount, format: AVAudioFormat,
                    block: @escaping (AVAudioPCMBuffer) -> Void)
    func removeTap()
    func prepare()
    func start() throws
    func stop()
}

/// The real `AVAudioEngine`. Thin hardware glue, covered by `docs/SMOKE_TEST.md`.
final class AVAudioInputEngine: AudioInputEngine, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var observer: NSObjectProtocol?

    var onConfigurationChange: (@Sendable () -> Void)?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.onConfigurationChange?()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    var inputFormat: AVAudioFormat { engine.inputNode.inputFormat(forBus: 0) }
    var isRunning: Bool { engine.isRunning }

    var currentInputDevice: AudioDeviceID? {
        guard let unit = engine.inputNode.audioUnit else { return nil }
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &device, &size)
        return status == noErr ? device : nil
    }

    func setInputDevice(_ device: AudioDeviceID) throws {
        guard let unit = engine.inputNode.audioUnit else {
            throw MacomprendoError.audio("The audio input unit is unavailable.")
        }
        var device = device
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &device,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            throw MacomprendoError.audio("Could not switch to the selected microphone (error \(status)).")
        }
    }

    func installTap(bufferSize: AVAudioFrameCount, format: AVAudioFormat,
                    block: @escaping (AVAudioPCMBuffer) -> Void) {
        engine.inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, _ in
            block(buffer)
        }
    }

    func removeTap() { engine.inputNode.removeTap(onBus: 0) }
    func prepare() { engine.prepare() }
    func start() throws { try engine.start() }
    func stop() { engine.stop() }
}

/// Records from the chosen input device — or the system default when none is chosen or the
/// chosen one is not connected — through `AVAudioEngine`, and converts it to 16 kHz mono
/// Float32, the format whisper.cpp and the OpenAI audio endpoint expect.
///
/// The input node is always bound to a device explicitly rather than left to follow the
/// system default by itself, so the same code path serves both cases, and a device that
/// appears, disappears or becomes the default mid-recording moves the recording with it
/// instead of leaving it stranded on a dead device.
///
/// A device that delivers nothing but digital silence for `deadDeviceSeconds` — a wireless
/// headset's dongle with the headset switched off is the typical case — is abandoned for
/// the rest of the recording in favour of another input, and `inputFallbacks()` says so.
///
/// When the recording reaches `maxDuration` the engine is stopped and no further
/// audio is accumulated; the next `stop()` returns the capped audio.
final class AVAudioEngineRecorder: AudioRecording, @unchecked Sendable {
    static let targetSampleRate: Double = 16_000
    /// How long a device may deliver no signal before the recording leaves it. Shorter than
    /// the HUD's three-second "not hearing anything" warning, so the fallback usually lands
    /// before the warning would have appeared.
    static let deadDeviceSeconds: Double = 2
    /// −100 dBFS: the level below which a buffer counts as no signal at all. A working
    /// microphone in a quiet room sits around −66 dBFS between words, far above this, so
    /// only a device producing digital zeros trips it — never a quiet speaker.
    static let deadSignalThreshold: Float = 0.00001

    let level: AsyncStream<Float>
    let autoStopped: AsyncStream<Void>

    private let levelContinuation: AsyncStream<Float>.Continuation
    private let autoStopContinuation: AsyncStream<Void>.Continuation
    private let engine: any AudioInputEngine
    private let devices: any AudioInputDeviceListing
    private var deviceChangesTask: Task<Void, Never>?
    private let fallbacks = InputFallbackBroadcaster()
    private let lock = NSLock()
    /// Serialises every call into the engine — `start()`, `stop()`, the cap's auto-stop, the
    /// device-change restart and a device picked in Settings arrive on different threads.
    /// Never taken by the tap block and never acquired while `lock` is held, so the two
    /// cannot deadlock.
    private let engineLock = NSLock()
    /// Whether this recorder has a tap on the input bus. Tracked here rather than read off
    /// `engine.isRunning`: after a device change the engine stops itself but keeps the tap,
    /// and installing a second one raises an Objective-C exception that crashes the app.
    private var tapInstalled = false

    private var samples: [Float] = []
    private var maxSamples: Int
    /// The cap the running recording began with. Changing the setting mid-recording must not
    /// retroactively truncate audio already captured.
    private var activeMaxSamples: Int
    private var recording = false
    /// `nil` follows the system default input.
    private var preferredUID: String?
    /// The device the input node was last bound to, for naming it in a fallback.
    private var currentDevice: AudioInputDevice?
    /// Devices this recording found silent. Cleared by `start()`: a headset switched off
    /// during one recording may well be on for the next.
    private var silentDeviceUIDs: Set<String> = []
    /// Consecutive converted samples with no signal on the current device.
    private var deadRunSamples = 0
    /// Set while a fallback is on its way, so the buffers still arriving from the silent
    /// device cannot schedule a second one.
    private var fallbackPending = false
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var resampler = PCMResampler(inputRate: 48_000,
                                         outputRate: AVAudioEngineRecorder.targetSampleRate)

    init(maxDuration: TimeInterval = 300,
         engine: any AudioInputEngine = AVAudioInputEngine(),
         devices: any AudioInputDeviceListing = CoreAudioInputDevices()) {
        self.engine = engine
        self.devices = devices
        maxSamples = Int(maxDuration * AVAudioEngineRecorder.targetSampleRate)
        activeMaxSamples = maxSamples
        var continuation: AsyncStream<Float>.Continuation!
        level = AsyncStream(bufferingPolicy: .bufferingNewest(4)) { continuation = $0 }
        levelContinuation = continuation
        var autoStopContinuation: AsyncStream<Void>.Continuation!
        autoStopped = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { autoStopContinuation = $0 }
        self.autoStopContinuation = autoStopContinuation
        engine.onConfigurationChange = { [weak self] in self?.engineConfigurationChanged() }
        let changes = devices.changes()
        deviceChangesTask = Task.detached { [weak self] in
            for await _ in changes {
                self?.inputDevicesChanged()
            }
        }
    }

    deinit {
        deviceChangesTask?.cancel()
    }

    func inputFallbacks() -> AsyncStream<InputFallback> { fallbacks.subscribe() }

    var isRecording: Bool { lock.withLock { recording } }

    func setMaximumDuration(_ seconds: TimeInterval) {
        lock.withLock {
            maxSamples = max(1, Int(seconds * AVAudioEngineRecorder.targetSampleRate))
        }
    }

    /// Applies immediately: a recording in progress moves to the newly chosen device.
    func setPreferredInputDevice(uid: String?) {
        lock.withLock { preferredUID = uid }
        engineLock.withLock { _ = restartOnResolvedDeviceLocked(force: false) }
    }

    /// The device a recording should use: the preferred one while it is connected, otherwise
    /// the system default. Devices in `excluding` — found silent during this recording — are
    /// skipped; past them come the built-in microphone, then any other input, then nothing.
    /// Pure, so the rule is unit-tested without Core Audio.
    static func resolveInputDevice(preferredUID: String?,
                                   devices: [AudioInputDevice],
                                   systemDefault: AudioInputDevice?,
                                   excluding excluded: Set<String> = []) -> AudioInputDevice? {
        if let preferredUID, !excluded.contains(preferredUID),
           let preferred = devices.first(where: { $0.uid == preferredUID }) {
            return preferred
        }
        if let systemDefault, !excluded.contains(systemDefault.uid) {
            return systemDefault
        }
        let usable = devices.filter { !excluded.contains($0.uid) }
        return usable.first(where: \.isBuiltIn) ?? usable.first
    }

    /// `resolveInputDevice` against the live device list and this recording's exclusions.
    private func resolvedDevice() -> AudioInputDevice? {
        let (preferred, excluded) = lock.withLock { (preferredUID, silentDeviceUIDs) }
        return Self.resolveInputDevice(preferredUID: preferred,
                                       devices: devices.inputDevices(),
                                       systemDefault: devices.defaultInputDevice(),
                                       excluding: excluded)
    }

    func start() throws {
        // Guard against a second start() while already recording: AVAudioEngine's
        // installTap(onBus:) traps if a tap is installed twice on the same bus, so this
        // must be checked before any engine work below.
        guard !isRecording else {
            throw MacomprendoError.audio("Recording is already in progress.")
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Self.targetSampleRate,
                                         channels: 1,
                                         interleaved: false) else {
            throw MacomprendoError.audio("Could not create the 16 kHz recording format.")
        }

        let inputFormat: AVAudioFormat = try engineLock.withLock {
            lock.withLock {
                silentDeviceUIDs = []
                deadRunSamples = 0
                fallbackPending = false
            }
            if let device = resolvedDevice() { bindLocked(device) }
            let inputFormat = engine.inputFormat
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw MacomprendoError.audio("No microphone input is available.")
            }
            lock.withLock {
                samples.removeAll(keepingCapacity: true)
                activeMaxSamples = maxSamples
                recording = true
                targetFormat = target
            }
            do {
                try startEngineLocked(inputFormat)
            } catch {
                lock.withLock { recording = false }
                throw MacomprendoError.audio("Could not start the audio engine: \(error.localizedDescription)")
            }
            return inputFormat
        }
        Log.audio.info("Recording started at \(inputFormat.sampleRate, privacy: .public) Hz")
    }

    /// Binds the input node to `device` unless it is already bound to it. Must be called with
    /// `engineLock` held and the engine stopped. A device that refuses is logged and the node
    /// keeps whatever it had; the caller's format check decides whether that is usable.
    private func bindLocked(_ device: AudioInputDevice) {
        if device.id != engine.currentInputDevice {
            do {
                try engine.setInputDevice(device.id)
            } catch {
                Log.audio.error("Could not bind the input device: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        lock.withLock {
            currentDevice = device
            deadRunSamples = 0
        }
    }

    /// Points the converter at `inputFormat`, installs the tap in that format and starts the
    /// engine. Must be called with `engineLock` held; leaves no tap behind if it throws.
    private func startEngineLocked(_ inputFormat: AVAudioFormat) throws {
        lock.withLock {
            if let targetFormat {
                converter = AVAudioConverter(from: inputFormat, to: targetFormat)
            }
            resampler = PCMResampler(inputRate: inputFormat.sampleRate,
                                     outputRate: Self.targetSampleRate)
        }
        removeTapLocked()
        engine.installTap(bufferSize: 4096, format: inputFormat) { [weak self] buffer in
            self?.ingest(buffer)
        }
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            removeTapLocked()
            throw error
        }
    }

    /// The engine stopped itself because its device changed under it, tap still attached.
    private func engineConfigurationChanged() {
        engineLock.withLock { _ = restartOnResolvedDeviceLocked(force: true) }
    }

    /// A device appeared or went away, or the system default moved.
    private func inputDevicesChanged() {
        engineLock.withLock { _ = restartOnResolvedDeviceLocked(force: false) }
    }

    /// Keeps a recording in progress on the device it should be using. The audio captured so
    /// far is kept and the tap is reinstalled in the new device's format. If the device will
    /// not start, the tap is removed and the recording keeps what it has — the silence gate
    /// then tells the user no sound arrived. Does nothing between recordings: `start()`
    /// resolves the device afresh anyway.
    ///
    /// `force` restarts even when the device is unchanged, for a configuration change that
    /// stopped the engine. Must be called with `engineLock` held.
    @discardableResult
    private func restartOnResolvedDeviceLocked(force: Bool) -> Bool {
        guard isRecording else { return false }
        let device = resolvedDevice()
        let needsSwitch = device.map { $0.id != engine.currentInputDevice } ?? false
        // A configuration change that arrives with the engine already running again was
        // caused by the recorder's own restart; there is nothing left to do.
        guard needsSwitch || (force && !engine.isRunning) else { return false }

        if engine.isRunning { engine.stop() }
        removeTapLocked()
        if needsSwitch, let device { bindLocked(device) }
        restartEngineLocked()
        return needsSwitch
    }

    /// Restarts the stopped engine on whatever device the input node is bound to.
    private func restartEngineLocked() {
        let inputFormat = engine.inputFormat
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            Log.audio.error("The input device has no input; recording paused")
            return
        }
        do {
            try startEngineLocked(inputFormat)
            Log.audio.info("Input device changed; recording continues at \(inputFormat.sampleRate, privacy: .public) Hz")
        } catch {
            engine.stop()
            Log.audio.error("Input device changed and the engine would not restart: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The current device has delivered no signal for `deadDeviceSeconds`. Excludes it for
    /// the rest of this recording and moves to the next device `resolveInputDevice` offers;
    /// with none left the recording stays where it is and the HUD's no-input warning takes
    /// over.
    private func fallBackFromSilentDevice() {
        engineLock.withLock {
            let silent: AudioInputDevice? = lock.withLock {
                fallbackPending = false
                if let currentDevice { silentDeviceUIDs.insert(currentDevice.uid) }
                return currentDevice
            }
            guard restartOnResolvedDeviceLocked(force: false) else { return }
            let replacement = lock.withLock { currentDevice }
            Log.audio.info("No signal from the input device; switched to another one")
            fallbacks.yield(InputFallback(from: silent?.name ?? "the microphone",
                                          to: replacement?.name ?? "another microphone"))
        }
    }

    func stop() -> [Float] {
        let captured: [Float] = lock.withLock {
            recording = false
            let collected = samples
            samples = []
            return collected
        }
        stopEngine()
        Log.audio.info("Recording stopped, \(captured.count, privacy: .public) samples")
        return captured
    }

    // MARK: - Tap

    private func ingest(_ buffer: AVAudioPCMBuffer) {
        var reachedCap = false
        var deviceWentDead = false
        let converted: [Float] = lock.withLock {
            guard recording else { return [] }
            let mono = convertLocked(buffer)
            guard !mono.isEmpty else { return [] }
            if AudioMath.peak(mono) < Self.deadSignalThreshold {
                deadRunSamples += mono.count
                if !fallbackPending,
                   deadRunSamples >= Int(Self.deadDeviceSeconds * Self.targetSampleRate) {
                    fallbackPending = true
                    deviceWentDead = true
                    deadRunSamples = 0
                }
            } else {
                deadRunSamples = 0
            }
            let room = activeMaxSamples - samples.count
            guard room > 0 else {
                recording = false
                reachedCap = true
                return []
            }
            samples.append(contentsOf: mono.prefix(room))
            if samples.count >= activeMaxSamples {
                recording = false
                reachedCap = true
            }
            return mono
        }

        if reachedCap {
            Task.detached { [weak self] in self?.stopEngine() }
        } else if deviceWentDead {
            // Off the tap thread: switching devices stops the engine this buffer came from.
            Task.detached { [weak self] in self?.fallBackFromSilentDevice() }
        }
        if !converted.isEmpty {
            levelContinuation.yield(AudioMath.level(fromRMS: AudioMath.rms(converted)))
        }
        if reachedCap {
            // The engine just auto-stopped with no further `stop()` call coming from the
            // caller — this is the only signal a consumer (like `DictationController`'s
            // auto-stop loop) gets that this recording session is over, so it can
            // transcribe instead of sitting frozen in `.recording`. Deliberately a
            // separate stream from `level`, and never `finish()`ed: `level` is created
            // once in `init` and shared across every recording this instance ever makes,
            // so finishing it here would permanently kill the meter (and this signal)
            // for every later recording, not just this one.
            autoStopContinuation.yield(())
        }
    }

    /// Must be called with `lock` held.
    private func convertLocked(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let converter, let target = targetFormat else {
            return resampler.resample(Self.monoSamples(buffer))
        }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }

        // `AVAudioConverter.convert(to:error:withInputFrom:)` declares its pull block as
        // `@Sendable`, so Swift 6 treats this capture as if it could run concurrently.
        // In practice the block is called synchronously and repeatedly on the calling
        // thread until this function returns — `nonisolated(unsafe)` is safe here.
        nonisolated(unsafe) var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }

    /// Removes the tap even when the engine is no longer running: a device change stops the
    /// engine by itself and leaves the tap in place, and skipping it here is what let the
    /// next `start()` install a second one.
    private func stopEngine() {
        engineLock.withLock {
            removeTapLocked()
            if engine.isRunning { engine.stop() }
        }
    }

    /// Must be called with `engineLock` held.
    private func removeTapLocked() {
        guard tapInstalled else { return }
        engine.removeTap()
        tapInstalled = false
    }

    private static func monoSamples(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData else { return [] }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return [] }
        if channels == 1 {
            return Array(UnsafeBufferPointer(start: data[0], count: frames))
        }
        var mixed = [Float](repeating: 0, count: frames)
        for channel in 0..<channels {
            let pointer = data[channel]
            for frame in 0..<frames { mixed[frame] += pointer[frame] }
        }
        let scale = 1 / Float(channels)
        for frame in 0..<frames { mixed[frame] *= scale }
        return mixed
    }
}
