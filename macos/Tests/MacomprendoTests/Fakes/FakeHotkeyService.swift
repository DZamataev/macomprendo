import Foundation
@testable import Macomprendo

final class FakeHotkeyService: HotkeyServicing, @unchecked Sendable {
    let events: AsyncStream<HotkeyEvent>
    private let continuation: AsyncStream<HotkeyEvent>.Continuation
    private let lock = NSLock()
    private var _enabled: [HotkeyAction: Bool] = [:]

    init() {
        var continuation: AsyncStream<HotkeyEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.continuation = continuation
    }

    var enabled: [HotkeyAction: Bool] { lock.withLock { _enabled } }

    func send(_ event: HotkeyEvent) {
        continuation.yield(event)
    }

    func setEnabled(_ action: HotkeyAction, _ enabled: Bool) {
        lock.withLock { _enabled[action] = enabled }
    }
}
