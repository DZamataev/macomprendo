import Foundation

protocol TextInserting: Sendable {
    /// Inserts `text` into `app` (or the current frontmost app when nil).
    /// Throws `MacomprendoError.insertFailed` when the target app cannot be brought forward.
    func insert(_ text: String, into app: FrontmostApp?, method: InsertMethod) async throws
}

/// Default inserter: activate the remembered app, put the text on the pasteboard, press ⌘V,
/// then put the user's own clipboard back — unless they copied something while we pasted.
///
/// `@unchecked Sendable`: the pasteboard and key simulator are only touched inside `insert(_:into:method:)`,
/// which the controllers call one at a time from the main actor.
struct PasteTextInserter: TextInserting, @unchecked Sendable {
    private let pasteboard: any PasteboardProtocol
    private let tracker: any FrontmostAppTracking
    private let keySimulator: any KeySimulating
    private let restoreDelay: TimeInterval

    init(pasteboard: any PasteboardProtocol,
         tracker: any FrontmostAppTracking,
         keySimulator: any KeySimulating,
         restoreDelay: TimeInterval = 0.3) {
        self.pasteboard = pasteboard
        self.tracker = tracker
        self.keySimulator = keySimulator
        self.restoreDelay = restoreDelay
    }

    func insert(_ text: String, into app: FrontmostApp?, method: InsertMethod) async throws {
        if let app {
            guard await tracker.activate(app) else {
                Log.ui.error("Could not activate \(app.name, privacy: .public) for insertion")
                throw MacomprendoError.insertFailed
            }
        }
        switch method {
        case .typing:
            await keySimulator.type(text)
        case .paste, .auto:
            await paste(text)
        }
    }

    private func paste(_ text: String) async {
        let snapshot = pasteboard.snapshot()
        pasteboard.writeString(text)
        let ourChangeCount = pasteboard.changeCount
        await keySimulator.pressCommand("v")
        if restoreDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(restoreDelay * 1_000_000_000))
        }
        guard pasteboard.changeCount == ourChangeCount else {
            Log.ui.info("Pasteboard changed during paste; leaving the user's clipboard alone")
            return
        }
        pasteboard.restore(snapshot)
    }
}
