import Foundation

/// The transcript library: the list of stored transcripts, the one the user has open, and the
/// actions the list offers — reload, select, delete, copy and export.
///
/// Every store failure lands in `error` as `ErrorText.describe(error)`; nothing throws to the
/// view. Transcript text is never logged.
///
/// Only the newest operation may write: `reload`, `select` and `delete` each bump a generation
/// before their first `await`, and a read that started earlier can no longer overwrite
/// `selected`/`headers`/`error` once a newer one has begun. Without it, a slow `select(A)` that
/// finishes after `select(B)` leaves A open, and one that finishes after `delete(A)` resurrects
/// the deleted row.
@MainActor
final class TranscriptLibraryController: ObservableObject {
    /// The reason an `inProgress` row carries when launch maintenance finds it: no job can be
    /// running at launch, so such a row belongs to a job the app did not finish.
    static let abandonedJobReason = "Macomprendo quit before it finished."

    @Published private(set) var headers: [TranscriptHeader] = []
    @Published private(set) var selected: Transcript?
    @Published private(set) var error: String?

    private let store: any TranscriptStoring
    private let pasteboard: any PasteboardProtocol

    /// Bumped by every store-facing operation. A read writes its result only while the
    /// generation it started with is still current.
    private var generation = 0

    init(store: any TranscriptStoring, pasteboard: any PasteboardProtocol) {
        self.store = store
        self.pasteboard = pasteboard
    }

    /// Loads the list, newest first, and re-reads the open transcript so a segment a running
    /// job appended shows up. A selection that no longer exists is dropped.
    func reload() async {
        generation += 1
        let token = generation
        do {
            let headers = try await store.headers()
            guard token == generation else { return }
            self.headers = headers
            if let id = selected?.id {
                let transcript = try await store.transcript(id: id)
                guard token == generation else { return }
                selected = transcript
            }
            error = nil
        } catch {
            guard token == generation else { return }
            self.error = ErrorText.describe(error)
        }
    }

    /// Opens `id`, or clears the selection with `nil`.
    func select(_ id: Int64?) async {
        generation += 1
        let token = generation
        guard let id else {
            selected = nil
            return
        }
        do {
            let transcript = try await store.transcript(id: id)
            guard token == generation else { return }
            selected = transcript
            error = nil
        } catch {
            guard token == generation else { return }
            self.error = ErrorText.describe(error)
        }
    }

    /// Removes `id`. A selection on the deleted transcript is cleared.
    func delete(_ id: Int64) async {
        generation += 1
        let token = generation
        do {
            try await store.delete(id: id)
            guard token == generation else { return }
            headers.removeAll { $0.id == id }
            if selected?.id == id { selected = nil }
            error = nil
        } catch {
            guard token == generation else { return }
            self.error = ErrorText.describe(error)
        }
    }

    /// Puts the open transcript's text on the pasteboard: one segment per line, no timestamps.
    func copySelected() {
        guard let selected else { return }
        pasteboard.writeString(selected.plainText)
    }

    /// The open transcript rendered in `format`, or `nil` when nothing is open.
    func exportText(_ format: TranscriptExportFormat) -> String? {
        guard let selected else { return nil }
        return TranscriptExporter.render(selected, as: format)
    }

    /// Marks every `inProgress` row the app did not finish, then refreshes the list so it shows
    /// the rows as `incomplete`.
    func performLaunchMaintenance() async {
        do {
            try await store.markAbandonedJobs(reason: Self.abandonedJobReason)
        } catch {
            self.error = ErrorText.describe(error)
            return
        }
        await reload()
    }
}
