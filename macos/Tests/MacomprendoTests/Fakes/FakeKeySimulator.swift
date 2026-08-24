import Foundation
@testable import Macomprendo

final class FakeKeySimulator: KeySimulating, @unchecked Sendable {
    private let lock = NSLock()
    private var _pressed: [Character] = []
    private var _typed: [String] = []
    private var _onPressCommand: (@Sendable (Character) -> Void)?

    var pressed: [Character] { lock.withLock { _pressed } }
    var typed: [String] { lock.withLock { _typed } }

    /// Runs on every `pressCommand` — used to simulate the user copying something mid-paste.
    var onPressCommand: (@Sendable (Character) -> Void)? {
        get { lock.withLock { _onPressCommand } }
        set { lock.withLock { _onPressCommand = newValue } }
    }

    func pressCommand(_ key: Character) async {
        let hook = lock.withLock { () -> (@Sendable (Character) -> Void)? in
            _pressed.append(key)
            return _onPressCommand
        }
        hook?(key)
    }

    func type(_ text: String) async {
        lock.withLock { _typed.append(text) }
    }
}
