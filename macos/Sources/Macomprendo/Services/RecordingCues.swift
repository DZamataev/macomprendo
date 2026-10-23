import AppKit
import CoreAudio

/// The optional cues around a dictation recording: a sound at its start and end, and the
/// system output muted while it runs.
@MainActor
protocol RecordingCueing: AnyObject {
    /// Returns once the sound has finished, so it is neither recorded nor cut by the mute.
    func playStartSound(_ settings: Settings) async
    func playStopSound(_ settings: Settings)
    func muteOutput()
    /// Unmutes only what `muteOutput()` muted, so calling it on every stop path is safe.
    func restoreOutput()
}

@MainActor
final class SystemRecordingCues: RecordingCueing {
    private var mutedDevice: AudioObjectID?

    func playStartSound(_ settings: Settings) async {
        guard let sound = Self.play("Tink", settings) else { return }
        try? await Task.sleep(for: .seconds(sound.duration))
    }

    func playStopSound(_ settings: Settings) {
        Self.play("Pop", settings)
    }

    @discardableResult
    private static func play(_ name: String, _ settings: Settings) -> NSSound? {
        guard let sound = NSSound(named: name) else { return nil }
        sound.volume = Float(settings.recordingSoundsVolume)
        sound.playbackDeviceIdentifier = settings.recordingSoundsOutputUID
        if sound.play() { return sound }
        // The chosen device is gone: play on the system default rather than not at all.
        sound.playbackDeviceIdentifier = nil
        return sound.play() ? sound : nil
    }

    func muteOutput() {
        guard mutedDevice == nil, let device = Self.defaultOutputDevice() else { return }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = Self.muteAddress
        // Already muted by the user: leave it, so the restore cannot unmute it.
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr,
              muted == 0 else { return }
        guard Self.setMute(device, 1) else {
            Log.audio.error("The output device cannot be muted; recording continues unmuted")
            return
        }
        mutedDevice = device
    }

    func restoreOutput() {
        guard let device = mutedDevice else { return }
        mutedDevice = nil
        if !Self.setMute(device, 0) {
            Log.audio.error("The output device could not be unmuted after recording")
        }
    }

    private static let muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    private static func setMute(_ device: AudioObjectID, _ value: UInt32) -> Bool {
        var value = value
        var address = muteAddress
        return AudioObjectSetPropertyData(device, &address, 0, nil,
                                          UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    private static func defaultOutputDevice() -> AudioObjectID? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }
}
