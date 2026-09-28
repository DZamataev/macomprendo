import CoreAudio
import Foundation
@testable import Macomprendo

/// A scripted set of input devices. `emitChange()` stands in for Core Audio announcing a
/// device being plugged in, unplugged, or made the system default.
final class FakeAudioInputDevices: AudioInputDeviceListing, @unchecked Sendable {
    private let lock = NSLock()
    private var _devices: [AudioInputDevice]
    private var _defaultUID: String?
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    init(_ devices: [AudioInputDevice] = [], defaultUID: String? = nil) {
        _devices = devices
        _defaultUID = defaultUID ?? devices.first?.uid
    }

    var devices: [AudioInputDevice] {
        get { lock.withLock { _devices } }
        set { lock.withLock { _devices = newValue } }
    }

    var defaultUID: String? {
        get { lock.withLock { _defaultUID } }
        set { lock.withLock { _defaultUID = newValue } }
    }

    func inputDevices() -> [AudioInputDevice] { devices }

    func defaultInputDevice() -> AudioInputDevice? {
        lock.withLock { _devices.first { $0.uid == _defaultUID } }
    }

    func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.continuations.removeValue(forKey: id) }
            }
        }
    }

    func emitChange() {
        for continuation in lock.withLock({ Array(continuations.values) }) {
            continuation.yield(())
        }
    }
}

extension AudioInputDevice {
    static let builtIn = AudioInputDevice(id: 121, uid: "BuiltInMicrophoneDevice",
                                          name: "MacBook Pro Microphone", isBuiltIn: true)
    static let mchose = AudioInputDevice(id: 163, uid: "MCHOSE-USB-0001", name: "MCHOSE V9")
}
