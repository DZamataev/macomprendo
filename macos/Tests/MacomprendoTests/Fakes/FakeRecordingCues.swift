import Foundation
@testable import Macomprendo

/// `RecordingCueing` double: records every call in order.
@MainActor
final class FakeRecordingCues: RecordingCueing {
    private(set) var events: [String] = []

    func playStartSound(_ settings: Settings) async { events.append("startSound") }
    func playStopSound(_ settings: Settings) { events.append("stopSound") }
    func muteOutput() { events.append("mute") }
    func restoreOutput() { events.append("restore") }
}
