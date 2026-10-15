import AVFoundation
import CoreAudio
import Foundation

/// The system side of a call: everything the Mac plays, through a global Core Audio process tap
/// (`CATapDescription(stereoGlobalTapButExcludeProcesses:)`, macOS 14.2+) read back through a
/// private aggregate device that contains the tap and no sub-device.
///
/// The tap is created unmuted — the call keeps playing while it is recorded — and this app's own
/// process is excluded. The first tap raises the one-time "System Audio Recording" prompt; if the
/// user declines, the tap delivers silence: the recording continues and the Others track simply
/// stays empty.
///
/// The aggregate is bound to the output device present when it was created, so a change of the
/// system default output tears the tap down and rebuilds it on the new route. A failed rebuild
/// leaves the capture stopped — a hole in the track is honest, audio from the wrong route is not.
final class ProcessTapSystemAudioCapture: CallAudioCapturing, @unchecked Sendable {
    /// The IO proc's queue. A queue of its own, so a lifecycle call on another thread can never
    /// be running while a buffer is being delivered.
    private let ioQueue = DispatchQueue(label: "com.dzamataev.macomprendo.system-audio-tap-io")
    /// Runs the small control blocks: the output-device listener and the rebuild it schedules.
    private let controlQueue = DispatchQueue(
        label: "com.dzamataev.macomprendo.system-audio-tap-control")
    /// Serialises the Core Audio lifecycle — `start()`, `stop()` and a rebuild. Never held while
    /// a chunk is delivered, so it cannot deadlock against a handler.
    private let controlLock = NSLock()
    /// Guards delivery: the running flag and the handler, cleared before `stop()` returns so no
    /// chunk can follow it.
    private let lock = NSLock()
    private var running = false
    private var handler: (@Sendable (CallAudioChunk) -> Void)?
    /// One converter for the life of the capture; a rebuilt tap that comes back in a different
    /// format is absorbed by the resampler rebuilding itself.
    private let resampler = MonoResampler()

    /// Guarded by `controlLock`.
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var listener: AudioObjectPropertyListenerBlock?

    init() {}

    func start(_ handler: @escaping @Sendable (CallAudioChunk) -> Void) throws {
        // A second start would create a tap over a live one; failing here keeps that mistake
        // visible, like the microphone capture does.
        guard lock.withLock({ !running }) else {
            throw MacomprendoError.systemAudioCaptureFailed(
                "A system audio capture is already in progress.")
        }
        try controlLock.withLock {
            // Set before the device starts, so the first buffers are not dropped.
            lock.withLock {
                self.handler = handler
                running = true
            }
            do {
                try setup()
            } catch {
                lock.withLock {
                    running = false
                    self.handler = nil
                }
                throw error
            }
        }
    }

    /// Idempotent. The running flag is cleared before the teardown, so once this returns the IO
    /// proc cannot deliver another chunk even though a late callback may still run.
    func stop() {
        lock.withLock {
            running = false
            handler = nil
        }
        controlLock.withLock { teardown() }
        Log.audio.info("Call system audio capture stopped")
    }

    // MARK: - Core Audio lifecycle

    /// Creates the tap, its aggregate device and the IO proc, starts the device and installs the
    /// output listener. Must be called with `controlLock` held; a throw leaves nothing behind.
    private func setup() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [try ownProcessObject()])
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.name = "Macomprendo call"

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr else {
            throw failure("creating the system audio tap failed", status)
        }
        tapID = newTapID

        let format: AVAudioFormat
        do {
            let uid = try tapUID()
            format = try tapFormat()
            try createAggregate(tapUID: uid)
            try startIOProc(format: format)
        } catch {
            teardown()
            throw error
        }

        installOutputListener()
        Log.audio.info(
            "Call system audio capture started at \(format.sampleRate, privacy: .public) Hz")
    }

    /// Releases everything `setup()` created, in dependency order. Must be called with
    /// `controlLock` held; safe after a partial creation and when already stopped.
    private func teardown() {
        removeOutputListener()
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// This app's Core Audio process object, for the tap's exclusion list — without it the tap
    /// would record Macomprendo's own output too.
    private func ownProcessObject() throws -> AudioObjectID {
        var address = Self.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var processObject = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size,
                                                &processObject)
        guard status == noErr else {
            throw failure("finding this app's audio process failed", status)
        }
        return processObject
    }

    /// The tap's UID, which is what the aggregate's tap list refers to. The HAL returns it
    /// retained; `takeRetainedValue()` owns that reference.
    private func tapUID() throws -> String {
        var address = Self.address(kAudioTapPropertyUID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &value)
        guard status == noErr, let value else {
            throw failure("reading the system audio tap's UID failed", status)
        }
        return value.takeRetainedValue() as String
    }

    private func tapFormat() throws -> AVAudioFormat {
        var address = Self.address(kAudioTapPropertyFormat)
        var streamDescription = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &streamDescription)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw failure("reading the system audio tap's format failed", status)
        }
        return format
    }

    private func createAggregate(tapUID: String) throws {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Macomprendo call",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [] as [[String: Any]],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID,
                 kAudioSubTapDriftCompensationKey: true] as [String: Any]
            ],
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateID)
        guard status == noErr else {
            throw failure("creating the system audio tap's aggregate device failed", status)
        }
        aggregateID = newAggregateID
    }

    private func startIOProc(format: AVAudioFormat) throws {
        var newProcID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateID, ioQueue) {
            [weak self] _, inputData, inputTime, _, _ in
            guard let self,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData,
                                                deallocator: nil) else { return }
            let stamp = inputTime.pointee
            // A device IO proc's input time normally carries a host time; without one the chunk
            // would be stamped at host time 0 and shift the whole track.
            let time = stamp.mFlags.contains(.hostTimeValid)
                ? HostClock.seconds(forHostTime: stamp.mHostTime)
                : HostClock.now()
            ingest(buffer, at: time)
        }
        guard status == noErr, let newProcID else {
            throw failure("creating the system audio tap's IO proc failed", status)
        }
        procID = newProcID
        let startStatus = AudioDeviceStart(aggregateID, newProcID)
        guard startStatus == noErr else {
            throw failure("starting the system audio tap's aggregate device failed", startStatus)
        }
    }

    /// Delivers one captured buffer as a chunk. The handler runs with `lock` held — the same
    /// contract the microphone capture states: `stop()` cannot return mid-delivery, and the
    /// handler must not call back into this capture.
    private func ingest(_ buffer: AVAudioPCMBuffer, at time: TimeInterval) {
        lock.withLock {
            guard running, let handler else { return }
            let samples = resampler.convert(buffer)
            guard !samples.isEmpty else { return }
            handler(CallAudioChunk(samples: samples, time: time))
        }
    }

    // MARK: - Output changes

    /// Watches the system default output, because the tap and its aggregate are bound to the
    /// device that was current when they were created.
    ///
    /// The block the HAL calls only schedules the rebuild: it must not wait for `controlLock`
    /// while `stop()` holds it to remove this listener.
    private func installOutputListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            controlQueue.async { [weak self] in self?.rebuildAfterOutputChange() }
        }
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                         &address, controlQueue, block)
        guard status == noErr else {
            Log.audio.error("The output-device listener could not be installed (OSStatus \(status, privacy: .public)); the call's system audio will not follow an output change")
            return
        }
        listener = block
    }

    private func removeOutputListener() {
        guard let listener else { return }
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                               &address, controlQueue, listener)
        self.listener = nil
    }

    /// Rebuilds the tap and its aggregate on the new default output, keeping the same handler. A
    /// rebuild failure leaves the capture stopped: the timeline pads nothing further and the
    /// level row shows silence.
    private func rebuildAfterOutputChange() {
        controlLock.withLock {
            guard lock.withLock({ running }) else { return }
            teardown()
            do {
                try setup()
                Log.audio.info("The system output changed; the call's system audio capture was rebuilt")
            } catch {
                lock.withLock {
                    running = false
                    handler = nil
                }
                Log.audio.error("The system output changed and the call's system audio capture could not be rebuilt: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private func failure(_ step: String, _ status: OSStatus) -> MacomprendoError {
        Log.audio.error("\(step, privacy: .public) (OSStatus \(status, privacy: .public))")
        return .systemAudioCaptureFailed("\(step) (OSStatus \(status))")
    }
}
