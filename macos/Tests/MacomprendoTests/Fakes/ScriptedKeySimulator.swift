import Foundation
@testable import Macomprendo

/// Records ⌘-key presses and lets a test simulate the side effect of the press.
final class ScriptedKeySimulator: KeySimulating, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [Character] = []
    private var typedStrings: [String] = []

    /// Called on every press — e.g. to write text into a `ScriptedPasteboard`.
    var onPress: (@Sendable (Character) -> Void)?

    var presses: [Character] { lock.withLock { keys } }
    var typed: [String] { lock.withLock { typedStrings } }

    func pressCommand(_ key: Character) async {
        lock.withLock { keys.append(key) }
        onPress?(key)
    }

    func type(_ text: String) async {
        lock.withLock { typedStrings.append(text) }
    }
}
