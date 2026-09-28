@preconcurrency import AVFoundation
import CoreAudio
import Foundation
@testable import Macomprendo

/// Stands in for `AVAudioEngine`'s input side and reproduces the behaviours of the real
/// engine that the recorder has to survive:
///
/// - installing a second tap on the input bus is a hard failure (the real engine raises an
///   Objective-C exception, `nullptr == Tap()`, and the app crashes) — counted here in
///   `doubleTapInstalls` so a test can assert it never happens;
/// - when the system input device changes, the engine stops *itself* but keeps the tap
///   installed, then posts a configuration change — `switchInputDevice(to:)`;
/// - pointing the input node at a device changes the input format to that device's.
final class FakeAudioInputEngine: AudioInputEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var _inputFormat: AVAudioFormat
    private var _isRunning = false
    private var _doubleTapInstalls = 0
    private var _tapFormats: [AVAudioFormat] = []
    private var _selectedDevices: [AudioDeviceID] = []
    private var _currentInputDevice: AudioDeviceID?
    private var tap: ((AVAudioPCMBuffer) -> Void)?

    var startError: Error?
    var onConfigurationChange: (@Sendable () -> Void)?
    /// The hardware format each device reports once selected.
    var deviceFormats: [AudioDeviceID: AVAudioFormat] = [:]

    var inputFormat: AVAudioFormat { lock.withLock { _inputFormat } }
    var isRunning: Bool { lock.withLock { _isRunning } }
    var doubleTapInstalls: Int { lock.withLock { _doubleTapInstalls } }
    var tapFormats: [AVAudioFormat] { lock.withLock { _tapFormats } }
    /// Every device the recorder pointed the input node at, in call order.
    var selectedDevices: [AudioDeviceID] { lock.withLock { _selectedDevices } }
    var currentInputDevice: AudioDeviceID? { lock.withLock { _currentInputDevice } }
    var hasTap: Bool { lock.withLock { tap != nil } }

    init(sampleRate: Double = 48_000) {
        _inputFormat = Self.monoFormat(sampleRate)
    }

    static func monoFormat(_ sampleRate: Double) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                      channels: 1, interleaved: false)!
    }

    func setInputDevice(_ device: AudioDeviceID) throws {
        lock.withLock {
            _selectedDevices.append(device)
            _currentInputDevice = device
            if let format = deviceFormats[device] { _inputFormat = format }
        }
    }

    func installTap(bufferSize: AVAudioFrameCount, format: AVAudioFormat,
                    block: @escaping (AVAudioPCMBuffer) -> Void) {
        lock.withLock {
            if tap != nil { _doubleTapInstalls += 1 }
            tap = block
            _tapFormats.append(format)
        }
    }

    func removeTap() { lock.withLock { tap = nil } }

    func prepare() {}

    func start() throws {
        if let startError { throw startError }
        lock.withLock { _isRunning = true }
    }

    func stop() { lock.withLock { _isRunning = false } }

    /// What macOS does when the user picks another input device mid-recording.
    func switchInputDevice(to format: AVAudioFormat) {
        lock.withLock {
            _isRunning = false
            _inputFormat = format
        }
        onConfigurationChange?()
    }

    /// What macOS does when the device the engine is on disappears: the engine stops and
    /// posts a configuration change.
    func loseCurrentDevice() {
        lock.withLock { _isRunning = false }
        onConfigurationChange?()
    }

    /// Feeds one buffer of a constant level through the tap, in the current input format.
    func deliver(level: Float, frames: Int) {
        let tap: ((AVAudioPCMBuffer) -> Void)? = lock.withLock { _isRunning ? self.tap : nil }
        let format = inputFormat
        guard let tap else { return }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for frame in 0..<frames { buffer.floatChannelData![0][frame] = level }
        tap(buffer)
    }
}
