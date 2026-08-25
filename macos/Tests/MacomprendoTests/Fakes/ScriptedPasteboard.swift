import Foundation
@testable import Macomprendo

/// In-memory `PasteboardProtocol` with a change counter that behaves like NSPasteboard's.
final class ScriptedPasteboard: PasteboardProtocol, @unchecked Sendable {
    static let utf8Type = "public.utf8-plain-text"

    private let lock = NSLock()
    private var items: [[String: Data]] = []
    private var count = 0
    private var restores = 0

    init(initialString: String? = nil) {
        if let initialString { writeString(initialString) }
    }

    var changeCount: Int { lock.withLock { count } }
    var restoreCount: Int { lock.withLock { restores } }

    func readString() -> String? {
        lock.withLock {
            items.last?[Self.utf8Type].flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    func writeString(_ s: String) {
        lock.withLock {
            items = [[Self.utf8Type: Data(s.utf8)]]
            count += 1
        }
    }

    func snapshot() -> PasteboardSnapshot {
        PasteboardSnapshot(items: lock.withLock { items })
    }

    func restore(_ snapshot: PasteboardSnapshot) {
        lock.withLock {
            items = snapshot.items
            count += 1
            restores += 1
        }
    }
}
