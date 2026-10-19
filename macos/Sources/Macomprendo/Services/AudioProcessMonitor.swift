import CoreAudio
import Foundation

/// Which processes are using audio right now. Read-only and permission-free; polling it costs
/// a few property reads per process once a second.
protocol AudioProcessMonitoring: Sendable {
    /// Every process Core Audio reports, read now. Empty when the list cannot be read.
    func snapshot() -> [AudioProcessActivity]
}

/// Reads Core Audio's process-object list. Polling rather than the per-process input listener,
/// which one open-source report says never fires on macOS 26.
final class CoreAudioProcessMonitor: AudioProcessMonitoring {
    func snapshot() -> [AudioProcessActivity] {
        Self.processObjects().compactMap { object in
            var pid: pid_t = 0
            guard Self.read(object, kAudioProcessPropertyPID, into: &pid) == noErr else {
                return nil
            }
            var input: UInt32 = 0
            guard Self.read(object, kAudioProcessPropertyIsRunningInput, into: &input) == noErr
            else { return nil }
            var output: UInt32 = 0
            guard Self.read(object, kAudioProcessPropertyIsRunningOutput, into: &output) == noErr
            else { return nil }
            return AudioProcessActivity(pid: pid, bundleID: Self.bundleID(of: object),
                                        isRunningInput: input != 0,
                                        isRunningOutput: output != 0)
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func read(_ object: AudioObjectID,
                             _ selector: AudioObjectPropertySelector,
                             into value: inout pid_t) -> OSStatus {
        var address = address(selector)
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
    }

    private static func read(_ object: AudioObjectID,
                             _ selector: AudioObjectPropertySelector,
                             into value: inout UInt32) -> OSStatus {
        var address = address(selector)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
    }

    private static func processObjects() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else {
            return []
        }
        var ids = [AudioObjectID](repeating: 0,
                                  count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    /// The property is a retained `CFString`; an empty one (a helper with no bundle) is `nil`.
    private static func bundleID(of object: AudioObjectID) -> String? {
        var address = address(kAudioProcessPropertyBundleID)
        var bundle: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &bundle) == noErr,
              let bundle else { return nil }
        let value = bundle.takeRetainedValue() as String
        return value.isEmpty ? nil : value
    }
}
