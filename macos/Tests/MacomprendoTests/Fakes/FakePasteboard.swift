import Foundation
@testable import Macomprendo

/// In-memory stand-in for `SystemPasteboard`. `restoreCalls` lets a test assert that the
/// pasteboard was put back exactly as it was found.
final class FakePasteboard: PasteboardProtocol, @unchecked Sendable {
    private(set) var changeCount: Int = 0
    private var current = PasteboardSnapshot()
    private(set) var restoreCalls: [PasteboardSnapshot] = []

    init(string: String? = nil) {
        if let string { writeString(string) }
    }

    func readString() -> String? {
        guard let data = current.items.first?["public.utf8-plain-text"] else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func writeString(_ s: String) {
        current = PasteboardSnapshot(items: [["public.utf8-plain-text": Data(s.utf8)]])
        changeCount += 1
    }

    func snapshot() -> PasteboardSnapshot { current }

    func restore(_ snapshot: PasteboardSnapshot) {
        restoreCalls.append(snapshot)
        current = snapshot
        changeCount += 1
    }
}
