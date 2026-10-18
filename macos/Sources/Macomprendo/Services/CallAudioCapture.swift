import AVFoundation
import Foundation

/// 48 kHz mono Float32 with the host-clock time (seconds) of its first sample.
struct CallAudioChunk: Sendable, Equatable {
    let samples: [Float]
    let time: TimeInterval
}

/// One side of a call, delivering its audio as it arrives. Which thread that is depends on the
/// source — the tap thread for the microphone.
protocol CallAudioCapturing: AnyObject, Sendable {
    /// Starts delivering chunks to `handler` on an audio thread. Throws a `MacomprendoError`.
    ///
    /// `handler` runs inline on that thread and must return quickly. It must never call back
    /// into the capture — `stop()`, `start(_:)` or `setPreferredInputDevice(uid:)` —
    /// synchronously: delivery holds a non-recursive lock, so the call deadlocks the app. Hop to
    /// another queue or actor first (`ScriptedCallCapture` reports a violation as a test issue).
    func start(_ handler: @escaping @Sendable (CallAudioChunk) -> Void) throws
    /// Stops delivery. Idempotent. No chunk is delivered after it returns.
    func stop()
}

/// The microphone side: a capture that follows the chosen input device.
///
/// The handler contract of `CallAudioCapturing.start(_:)` covers `setPreferredInputDevice(uid:)`
/// too: it takes the same lock, so calling it from inside the handler hangs just as surely.
protocol CallMicrophoneCapturing: CallAudioCapturing {
    func setPreferredInputDevice(uid: String?)
    /// Whether `stop()` lets go of the input hardware or only stops the engine.
    func setReleasesInputWhenStopped(_ releases: Bool)
    /// Whether the input stays open between recordings (release switched off). False while a
    /// recording runs: that is recording, not holding.
    var holdsInput: Bool { get }
    /// Lets go of an input kept open between recordings. Does nothing while recording.
    func releaseInput()
}

/// The host clock both call tracks are placed on: `mach_absolute_time` seconds, the same
/// reference `AVAudioTime` uses for tap timestamps.
enum HostClock {
    static func seconds(forHostTime hostTime: UInt64) -> TimeInterval {
        AVAudioTime.seconds(forHostTime: hostTime)
    }

    static func now() -> TimeInterval {
        seconds(forHostTime: mach_absolute_time())
    }
}

/// Captures the microphone for a call: `AVAudioEngine` input in the device's own format,
/// converted to 48 kHz mono, delivered with the host-clock time of its first sample.
///
/// Follows the chosen input device the way `AVAudioEngineRecorder` does — the input node is
/// always bound to a device explicitly, and one that appears, disappears or becomes the system
/// default mid-call moves the capture with it — minus the recorder's silence fallback: both
/// tracks of a call are written to disk as they are, so nothing may be swapped behind the
/// user's back. Voice processing is never enabled: the Me track must hold what the microphone
/// heard.
final class EngineCallMicrophoneCapture: CallMicrophoneCapturing, @unchecked Sendable {
    private let engine: any AudioInputEngine
    private let devices: any AudioInputDeviceListing
    private let clock: @Sendable () -> TimeInterval
    private let resampler = MonoResampler()
    private let lock = NSLock()
    /// Serialises every call into the engine — `start()`, `stop()`, a device picked in Settings
    /// and a device-change restart arrive on different threads. Never acquired while `lock` is
    /// held, so the two cannot deadlock.
    private let engineLock = NSLock()
    private var deviceChangesTask: Task<Void, Never>?
    /// Whether the capture is delivering. Guarded by `lock`, and cleared before `stop()` returns
    /// so no chunk can follow it.
    private var running = false
    private var handler: (@Sendable (CallAudioChunk) -> Void)?
    /// `nil` follows the system default input.
    private var preferredUID: String?
    private var releasesInputWhenStopped = true
    /// The engine has touched the hardware since it was last released.
    private var inputOpen = false
    /// Whether this capture has a tap on the input bus. Tracked here rather than read off
    /// `engine.isRunning`: after a device change the engine stops itself but keeps the tap, and
    /// installing a second one raises an Objective-C exception that crashes the app.
    private var tapInstalled = false

    init(engine: any AudioInputEngine, devices: any AudioInputDeviceListing,
         clock: @escaping @Sendable () -> TimeInterval = HostClock.now) {
        self.engine = engine
        self.devices = devices
        self.clock = clock
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

    /// Applies immediately: a capture in progress moves to the newly chosen device.
    func setPreferredInputDevice(uid: String?) {
        lock.withLock { preferredUID = uid }
        engineLock.withLock { _ = restartOnResolvedDeviceLocked(force: false) }
    }

    func setReleasesInputWhenStopped(_ releases: Bool) {
        lock.withLock { releasesInputWhenStopped = releases }
    }

    var holdsInput: Bool { lock.withLock { inputOpen && !running } }

    func releaseInput() {
        engineLock.withLock {
            guard holdsInput else { return }
            removeTapLocked()
            engine.release()
            lock.withLock { inputOpen = false }
        }
    }

    func start(_ handler: @escaping @Sendable (CallAudioChunk) -> Void) throws {
        let inputFormat: AVAudioFormat = try engineLock.withLock {
            // A second start would swap the tap under a running engine; failing here, like the
            // recorder does, keeps that mistake visible. The check sits inside the serialising
            // lock: two concurrent starts must not both pass it and install a second tap.
            guard !lock.withLock({ running }) else {
                throw MacomprendoError.audio("A call capture is already in progress.")
            }
            guard let device = resolvedDevice() else {
                throw MacomprendoError.audio("No microphone input is available.")
            }
            bindLocked(device)
            let inputFormat = engine.inputFormat
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw MacomprendoError.audio("No microphone input is available.")
            }
            lock.withLock {
                self.handler = handler
                running = true
                inputOpen = true
            }
            do {
                try startEngineLocked(inputFormat)
            } catch {
                // Both, so a failed start does not leave the controller's closure retained.
                lock.withLock {
                    running = false
                    self.handler = nil
                }
                throw MacomprendoError.audio(
                    "Could not start the audio engine: \(error.localizedDescription)")
            }
            return inputFormat
        }
        Log.audio.info("Call microphone capture started at \(inputFormat.sampleRate, privacy: .public) Hz")
    }

    func stop() {
        lock.withLock {
            running = false
            handler = nil
        }
        engineLock.withLock {
            removeTapLocked()
            if lock.withLock({ releasesInputWhenStopped }) {
                engine.release()
                lock.withLock { inputOpen = false }
            } else if engine.isRunning {
                engine.stop()
            }
        }
        Log.audio.info("Call microphone capture stopped")
    }

    // MARK: - The device in use

    /// `resolveInputDevice` against the live device list — no exclusions: this capture has no
    /// silence fallback.
    private func resolvedDevice() -> AudioInputDevice? {
        let preferred = lock.withLock { preferredUID }
        return AVAudioEngineRecorder.resolveInputDevice(preferredUID: preferred,
                                                       devices: devices.inputDevices(),
                                                       systemDefault: devices.defaultInputDevice())
    }

    /// Binds the input node to `device` unless it is already bound to it. Must be called with
    /// `engineLock` held and the engine stopped. A device that refuses is logged and the node
    /// keeps whatever it had; the caller's format check decides whether that is usable.
    private func bindLocked(_ device: AudioInputDevice) {
        if device.id != engine.currentInputDevice {
            do {
                try engine.setInputDevice(device.id)
            } catch {
                Log.audio.error("Could not bind the call recording's input device: \(error.localizedDescription, privacy: .public)")
                return
            }
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

    /// Keeps a capture in progress on the device it should be using. The tap is reinstalled in
    /// the new device's format. If the device will not start, the tap is removed and the capture
    /// stops delivering until the next device change — a hole in a call track is honest, silence
    /// recorded from the wrong device is not. Does nothing between calls: `start()` resolves the
    /// device afresh anyway.
    ///
    /// `force` restarts even when the device is unchanged, for a configuration change that
    /// stopped the engine. Must be called with `engineLock` held.
    @discardableResult
    private func restartOnResolvedDeviceLocked(force: Bool) -> Bool {
        guard lock.withLock({ running }) else { return false }
        let device = resolvedDevice()
        let needsSwitch = device.map { $0.id != engine.currentInputDevice } ?? false
        // A configuration change that arrives with the engine already running again was caused
        // by the capture's own restart; there is nothing left to do.
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
            Log.audio.error("The input device has no input; the call capture is paused")
            return
        }
        do {
            try startEngineLocked(inputFormat)
            Log.audio.info("Input device changed; the call capture continues at \(inputFormat.sampleRate, privacy: .public) Hz")
        } catch {
            engine.stop()
            Log.audio.error("Input device changed and the engine would not restart: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Tap

    /// Installs the tap in `inputFormat` and starts the engine. Must be called with `engineLock`
    /// held; leaves no tap behind if it throws.
    private func startEngineLocked(_ inputFormat: AVAudioFormat) throws {
        removeTapLocked()
        engine.installTap(bufferSize: 4_096, format: inputFormat) { [weak self] buffer in
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

    /// Delivers one captured buffer as a chunk. The handler runs with `lock` held — that is what
    /// makes `stop()` unable to return while a chunk is mid-delivery, at the price stated on
    /// `CallAudioCapturing.start(_:)`: the handler must not call back into the capture.
    private func ingest(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard running, let handler else { return }
            let samples = resampler.convert(buffer)
            guard !samples.isEmpty else { return }
            handler(CallAudioChunk(samples: samples,
                                   time: clock() - Double(buffer.frameLength) / buffer.format.sampleRate))
        }
    }

    /// Removes the tap even when the engine is no longer running: a device change stops the
    /// engine by itself and leaves the tap in place.
    private func removeTapLocked() {
        guard tapInstalled else { return }
        engine.removeTap()
        tapInstalled = false
    }
}
