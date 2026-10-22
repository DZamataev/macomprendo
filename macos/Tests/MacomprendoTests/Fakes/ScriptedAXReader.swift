import Foundation
@testable import Macomprendo

struct ScriptedAXReader: AXReading {
    var text: String?
    var acceptsText = false
    func focusedSelectedText() -> String? { text }
    func focusedElementAcceptsText() -> Bool { acceptsText }
}

/// Returns a different response on each call — one instance per `AXSelectedTextService`,
/// so this is what lets a test tell "the first read" from "the second, superseding read"
/// apart without racing a fake `⌘C`.
final class CountingAXReader: AXReading, @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private let responses: [String?]

    init(responses: [String?]) { self.responses = responses }

    func focusedElementAcceptsText() -> Bool { false }

    func focusedSelectedText() -> String? {
        lock.withLock {
            defer { callCount += 1 }
            return callCount < responses.count ? responses[callCount] : responses.last ?? nil
        }
    }
}
