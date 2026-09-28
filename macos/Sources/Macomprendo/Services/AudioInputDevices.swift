import CoreAudio
import Foundation

/// One Core Audio device with at least one input channel.
///
/// `uid` is what gets persisted: it is stable across reboots and reconnections, while `id`
/// (the `AudioDeviceID`) is reassigned every time the device appears.
struct AudioInputDevice: Equatable, Hashable, Sendable, Identifiable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    /// The Mac's own microphone: the preferred place to fall back to from a silent device,
    /// because it cannot be switched off or out of range.
    var isBuiltIn = false
}

/// The system's input devices and its default input, plus a signal whenever either changes
/// — a device plugged in or removed, or the default switched in the Sound menu.
protocol AudioInputDeviceListing: AnyObject, Sendable {
    func inputDevices() -> [AudioInputDevice]
    func defaultInputDevice() -> AudioInputDevice?
    /// A fresh stream per caller. Yields once per change; carries no payload, so a consumer
    /// re-reads the lists it cares about.
    func changes() -> AsyncStream<Void>
}

/// Reads devices through the Core Audio HAL. Thin hardware glue, covered by
/// `docs/SMOKE_TEST.md`.
final class CoreAudioInputDevices: AudioInputDeviceListing, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    private let queue = DispatchQueue(label: "com.dzamataev.macomprendo.audio-devices")
    private var listener: AudioObjectPropertyListenerBlock?

    private static let watched: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDevices,
        kAudioHardwarePropertyDefaultInputDevice
    ]

    init() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.broadcast() }
        listener = block
        for selector in Self.watched {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                &address, queue, block)
        }
    }

    deinit {
        guard let listener else { return }
        for selector in Self.watched {
            var address = Self.address(selector)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                   &address, queue, listener)
        }
    }

    func changes() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            lock.withLock { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                _ = self.lock.withLock { self.continuations.removeValue(forKey: id) }
            }
        }
    }

    private func broadcast() {
        for continuation in lock.withLock({ Array(continuations.values) }) {
            continuation.yield(())
        }
    }

    func inputDevices() -> [AudioInputDevice] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap(Self.inputDevice)
    }

    func defaultInputDevice() -> AudioInputDevice? {
        var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return Self.inputDevice(id)
    }

    /// `nil` for a device with no input channels (speakers, most displays) and for the
    /// private aggregate devices apps create for themselves, which must not be offered.
    private static func inputDevice(_ id: AudioDeviceID) -> AudioInputDevice? {
        guard inputChannelCount(id) > 0,
              let uid = string(id, kAudioDevicePropertyDeviceUID),
              !uid.hasPrefix("CADefaultDeviceAggregate"),
              let name = string(id, kAudioObjectPropertyName) else { return nil }
        return AudioInputDevice(id: id, uid: uid, name: name,
                                isBuiltIn: transportType(id) == kAudioDeviceTransportTypeBuiltIn)
    }

    private static func transportType(_ id: AudioDeviceID) -> UInt32? {
        var address = address(kAudioDevicePropertyTransportType)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}
