import AppKit

/// Everything on the pasteboard: one dictionary per item, type identifier -> raw data.
/// Snapshotting all types (not just the string) is what lets Macomprendo put an image
/// or rich text back exactly as it found it.
struct PasteboardSnapshot: Sendable, Equatable {
    var items: [[String: Data]]

    init(items: [[String: Data]] = []) { self.items = items }
}

/// `Sendable` because Plan 3's `PasteTextInserter` and Plan 4's `AXSelectedTextService`
/// are `Sendable` structs that hold one of these.
protocol PasteboardProtocol: AnyObject, Sendable {
    var changeCount: Int { get }
    func readString() -> String?
    func writeString(_ s: String)
    func snapshot() -> PasteboardSnapshot
    func restore(_ snapshot: PasteboardSnapshot)
}

final class SystemPasteboard: PasteboardProtocol, @unchecked Sendable {
    private let pasteboard: NSPasteboard

    init(_ pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    var changeCount: Int { pasteboard.changeCount }

    func readString() -> String? { pasteboard.string(forType: .string) }

    func writeString(_ s: String) {
        pasteboard.clearContents()
        pasteboard.setString(s, forType: .string)
    }

    func snapshot() -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item -> [String: Data] in
            var dict: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { dict[type.rawValue] = data }
            }
            return dict
        }
        return PasteboardSnapshot(items: items)
    }

    func restore(_ snapshot: PasteboardSnapshot) {
        pasteboard.clearContents()
        let items = snapshot.items.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in dict {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items)
    }
}
