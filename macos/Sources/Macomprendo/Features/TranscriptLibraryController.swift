import Foundation

/// The transcript library: the list of stored transcripts, the one the user has open, and the
/// actions the list offers — reload, select, delete, copy and export.
///
/// Every store failure lands in `error` as `ErrorText.describe(error)`; nothing throws to the
/// view. Transcript text is never logged.
///
/// Writes are scoped to what an operation touched rather than to "the newest operation", so
/// unrelated operations never cancel each other's legitimate writes. Two tokens track this:
/// `listToken` guards the list (`headers`), `selectionToken` guards the open transcript
/// (`selected`). A `reload` bumps only `listToken`, so it cannot invalidate a concurrent
/// `select`; a `select` bumps only `selectionToken`. A completed `delete` applies its effects
/// unconditionally — the deletion is the truth — then bumps both, so a read that started before
/// it cannot re-add the row or re-open it. Without the split, a slow `select(A)` finishing after
/// `select(B)` leaves A open, and a reload started during a delete drops the delete's pruning.
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

    /// Guards the list: bumped when `reload()` starts and when a `delete()` completes. A
    /// `reload()` writes `headers` only while the value it started with is still current, so a
    /// list read that started before a completed delete cannot re-add the deleted row.
    private var listToken = 0

    /// Guards the open transcript: bumped when `select()` starts and when a `delete()` completes.
    /// A `select()` and a `reload()`'s refresh of `selected` write only while the value they
    /// started with is still current. `reload()` does not bump it, so a reload never invalidates
    /// a concurrent select.
    private var selectionToken = 0

    init(store: any TranscriptStoring, pasteboard: any PasteboardProtocol) {
        self.store = store
        self.pasteboard = pasteboard
    }

    /// Loads the list, newest first, and re-reads the open transcript so a segment a running
    /// job appended shows up. A selection that no longer exists is dropped.
    func reload() async {
        listToken += 1
        let list = listToken
        let selection = selectionToken
        do {
            let headers = try await store.headers()
            guard list == listToken else { return }
            self.headers = headers
            if let id = selected?.id {
                let transcript = try await store.transcript(id: id)
                guard selection == selectionToken else { return }
                selected = transcript
            }
            error = nil
        } catch {
            guard list == listToken else { return }
            self.error = ErrorText.describe(error)
        }
    }

    /// Opens `id`, or clears the selection with `nil`.
    func select(_ id: Int64?) async {
        selectionToken += 1
        let token = selectionToken
        guard let id else {
            selected = nil
            return
        }
        do {
            let transcript = try await store.transcript(id: id)
            guard token == selectionToken else { return }
            selected = transcript
            error = nil
        } catch {
            guard token == selectionToken else { return }
            self.error = ErrorText.describe(error)
        }
    }

    /// Removes `id`. A selection on the deleted transcript is cleared.
    func delete(_ id: Int64) async {
        do {
            try await store.delete(id: id)
        } catch {
            // A failed delete always reports: a newer read cannot be trusted to have done the
            // deleting, so it does not suppress the failure.
            self.error = ErrorText.describe(error)
            return
        }
        // The deletion is the truth: apply its effects unconditionally, so an operation that
        // started while it was in flight cannot drop the pruning or the clearing.
        headers.removeAll { $0.id == id }
        if selected?.id == id { selected = nil }
        error = nil
        // Any read that started before this deletion can no longer re-add the row or re-open it.
        listToken += 1
        selectionToken += 1
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
