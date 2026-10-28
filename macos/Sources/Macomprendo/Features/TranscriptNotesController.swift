import Foundation

/// The notes drafts of every transcript being edited, keyed by the notes file's URL — one
/// coordinator, so the menubar panel and the Transcripts window editing the same call share one
/// draft and one save queue (spec §2, "Notes coordinator contract").
///
/// Per URL an entry is unloaded (absent), `clean`, `dirty` or `unreadable`, with that URL's own
/// last save error. `load` re-reads everything but a dirty draft; `edit` is accepted only for a
/// loaded, readable entry and saves after `saveDelay`; a failed save keeps the draft dirty and is
/// retried by the next edit or flush. Writes are synchronous on the main actor — the files are a
/// few kilobytes — so two saves of one file can never interleave. Notes text is never logged.
@MainActor final class TranscriptNotesController: ObservableObject {
    enum EntryState: Equatable {
        case clean
        case dirty
        /// The file exists but cannot be read; the error says why. Nothing writes over it.
        case unreadable(MacomprendoError)
    }

    struct Entry: Equatable {
        var text: String
        var state: EntryState
        /// Why the last save of this file failed; cleared by the next successful one.
        var saveError: String?
    }

    @Published private(set) var entries: [URL: Entry] = [:]

    private let files: any TranscriptSidecarFiling
    private let saveDelay: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var pendingSaves: [URL: Task<Void, Never>] = [:]

    init(files: any TranscriptSidecarFiling,
         saveDelay: Duration = .milliseconds(600),
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.files = files
        self.saveDelay = saveDelay
        self.sleep = sleep
    }

    // MARK: - Reading

    func state(for url: URL) -> EntryState? { entries[key(url)]?.state }

    func text(for url: URL) -> String { entries[key(url)]?.text ?? "" }

    func isEditable(_ url: URL) -> Bool {
        switch entries[key(url)]?.state {
        case .clean, .dirty: true
        case .unreadable, nil: false
        }
    }

    /// The unreadable reason, else the last save failure, for this file only.
    func error(for url: URL) -> String? {
        guard let entry = entries[key(url)] else { return nil }
        if case let .unreadable(error) = entry.state { return ErrorText.describe(error) }
        return entry.saveError
    }

    func fileExists(_ url: URL) -> Bool { files.fileExists(key(url)) }

    func hasNotes(_ url: URL) -> Bool {
        !text(for: url).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Reads the file unless a dirty draft is waiting to be saved: edits made in another editor
    /// show up whenever an editor opens, and unsaved text is never replaced.
    func load(_ url: URL) {
        let url = key(url)
        if entries[url]?.state == .dirty { return }
        do {
            entries[url] = Entry(text: try files.readNotes(at: url), state: .clean)
        } catch let error as MacomprendoError {
            entries[url] = Entry(text: "", state: .unreadable(error))
        } catch {
            entries[url] = Entry(text: "", state: .unreadable(
                .notesUnreadable(error.localizedDescription)))
        }
    }

    /// What an export or Summarize should use right now: the draft when it has unsaved edits,
    /// else the file as it is on disk. Throws `notesUnreadable` rather than answering `""`.
    func currentText(for url: URL) throws -> String {
        let url = key(url)
        if let entry = entries[url], entry.state == .dirty { return entry.text }
        load(url)
        if case let .unreadable(error) = entries[url]?.state { throw error }
        return entries[url]?.text ?? ""
    }

    // MARK: - Writing

    func edit(_ text: String, for url: URL) {
        let url = key(url)
        guard isEditable(url), entries[url]?.text != text else { return }
        entries[url]?.text = text
        entries[url]?.state = .dirty
        scheduleSave(url)
    }

    /// Saves the draft now, if it has unsaved edits. Returns why it could not be saved — the
    /// draft then stays dirty — else `nil`.
    @discardableResult func flush(_ url: URL) -> String? {
        let url = key(url)
        pendingSaves.removeValue(forKey: url)?.cancel()
        save(url)
        return entries[url]?.state == .dirty ? entries[url]?.saveError : nil
    }

    /// Saves every unsaved draft — at quit — and returns the failures by file.
    @discardableResult func flushAll() -> [URL: String] {
        var failures: [URL: String] = [:]
        for url in entries.keys where entries[url]?.state == .dirty {
            if let message = flush(url) { failures[url] = message }
        }
        return failures
    }

    /// Forgets a file whose source went to the Trash: its pending save is cancelled, and a late
    /// edit or flush from an editor still closing cannot recreate it.
    func discard(_ url: URL) {
        let url = key(url)
        pendingSaves.removeValue(forKey: url)?.cancel()
        entries.removeValue(forKey: url)
    }

    /// Awaits every scheduled save. Used by tests.
    func drain() async {
        while let task = pendingSaves.values.first {
            await task.value
        }
    }

    private func scheduleSave(_ url: URL) {
        pendingSaves.removeValue(forKey: url)?.cancel()
        let delay = saveDelay
        let sleep = sleep
        pendingSaves[url] = Task { [weak self] in
            try? await sleep(delay)
            guard !Task.isCancelled, let self else { return }
            self.pendingSaves.removeValue(forKey: url)
            self.save(url)
        }
    }

    /// Writes the current draft — never a captured older value — when it is dirty.
    private func save(_ url: URL) {
        guard let entry = entries[url], entry.state == .dirty else { return }
        do {
            try files.saveNotes(entry.text, at: url)
            entries[url]?.state = .clean
            entries[url]?.saveError = nil
        } catch {
            Log.app.error("Transcript notes could not be saved")
            entries[url]?.saveError = ErrorText.describe(error)
        }
    }

    private func key(_ url: URL) -> URL { files.canonical(url) }
}
