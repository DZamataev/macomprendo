import Foundation
import SwiftUI

@MainActor
final class DictationHistoryController: ObservableObject {
    struct AppendResult {
        let entry: DictationHistoryEntry?
        let error: MacomprendoError?
    }

    @Published private(set) var entries: [DictationHistoryEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = true
    @Published private(set) var errorMessage: String?
    @Published private(set) var copiedEntryID: Int64?
    /// The entry whose recording is playing, or `nil` when nothing is.
    @Published private(set) var playingEntryID: Int64?
    /// Bumped whenever the set of files on disk changes — a recording saved or removed, or a
    /// retention pass that deleted some. The Settings screen watches this instead of polling,
    /// so its size readout follows a dictation that lands while it is open.
    @Published private(set) var savedAudioRevision = 0

    private let store: any DictationHistoryStoring
    private let pasteboard: any PasteboardProtocol
    private let isEnabled: @MainActor () -> Bool
    private let encoder: (any DictationAudioEncoding)?
    private let player: (any AudioPlaying)?
    private let shouldSaveRecording: @MainActor () -> Bool
    private let retention: @MainActor () -> HistoryRetention
    private let pageSize: Int
    private let now: @Sendable () -> Date
    private let copyFeedbackSleep: @Sendable (Duration) async -> Void

    private var nextCursor: Int64?
    private var loadGeneration = 0
    private var loadTask: Task<DictationHistoryPage, Error>?
    private var copyGeneration = 0
    /// The recordings whose files were present the last time the directory was read. An entry
    /// referencing a filename outside this set has lost its file, which is normal.
    private var existingAudioFilenames: Set<String> = []

    init(store: any DictationHistoryStoring,
         pasteboard: any PasteboardProtocol,
         isEnabled: @escaping @MainActor () -> Bool,
         encoder: (any DictationAudioEncoding)? = nil,
         player: (any AudioPlaying)? = nil,
         shouldSaveRecording: @escaping @MainActor () -> Bool = { false },
         retention: @escaping @MainActor () -> HistoryRetention = { .unlimited },
         pageSize: Int = 100,
         now: @escaping @Sendable () -> Date = Date.init,
         copyFeedbackSleep: @escaping @Sendable (Duration) async -> Void = { duration in
             try? await Task.sleep(for: duration)
         }) {
        self.store = store
        self.pasteboard = pasteboard
        self.isEnabled = isEnabled
        self.encoder = encoder
        self.player = player
        self.shouldSaveRecording = shouldSaveRecording
        self.retention = retention
        self.pageSize = max(1, pageSize)
        self.now = now
        self.copyFeedbackSleep = copyFeedbackSleep
        player?.onFinished = { [weak self] in self?.playingEntryID = nil }
    }

    func record(text: String, kind: DictationHistoryKind) async -> MacomprendoError? {
        await append(text: text, kind: kind).error
    }

    func append(text: String, kind: DictationHistoryKind) async -> AppendResult {
        guard isEnabled() else { return AppendResult(entry: nil, error: nil) }

        let acceptedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !acceptedText.isEmpty else { return AppendResult(entry: nil, error: nil) }

        do {
            let entry = try await store.append(text: acceptedText, kind: kind, at: now())
            // The window may be open on an already-loaded page. Pages are newest-first, so the
            // new entry belongs at the front; without this the row only appears after the
            // window is closed and reopened.
            entries.insert(entry, at: 0)
            try await applyRetentionThrowing()
            errorMessage = nil
            return AppendResult(entry: entry, error: nil)
        } catch {
            let historyError = mappedHistoryError(from: error)
            errorMessage = ErrorText.describe(historyError)
            return AppendResult(entry: nil, error: historyError)
        }
    }

    func saveRecording(_ pcm: [Float], for entry: DictationHistoryEntry?) async -> MacomprendoError? {
        guard isEnabled(), shouldSaveRecording(), let encoder, let entry else { return nil }
        let filename = "\(entry.id).m4a"
        let url = store.audioDirectoryURL.appendingPathComponent(filename)
        do {
            try Task.checkCancellation()
            await store.beginAudioWrite()
            do {
                try await encoder.encode(pcm, sampleRate: 16_000, to: url)
            } catch {
                await store.endAudioWrite()
                throw error
            }
            await store.endAudioWrite()
            try Task.checkCancellation()
            try await store.attachAudioFile(named: filename, toEntry: entry.id)
            existingAudioFilenames.insert(filename)
            savedAudioRevision += 1
            let withAudio = DictationHistoryEntry(
                id: entry.id, createdAt: entry.createdAt, kind: entry.kind,
                text: entry.text, audioFileName: filename)
            if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                entries[index] = withAudio
            } else {
                // The entry was appended (and this recording captured) while the window was
                // open, so it was never in `entries` to begin with — pages are newest-first.
                entries.insert(withAudio, at: 0)
            }
            return nil
        } catch {
            if error is CancellationError {
                try? await store.removeAudioFiles(named: [filename])
                return nil
            }
            let mapped = error as? MacomprendoError
                ?? MacomprendoError.audioEncoding(error.localizedDescription)
            do {
                try await store.removeAudioFiles(named: [filename])
                errorMessage = ErrorText.describe(mapped)
                return mapped
            } catch {
                let combined = MacomprendoError.audioEncoding(
                    "\(mapped.errorDescription ?? mapped.localizedDescription); "
                    + "the partial recording could not be removed"
                )
                errorMessage = ErrorText.describe(combined)
                return combined
            }
        }
    }

    func applyRetention() async -> MacomprendoError? {
        do {
            try await applyRetentionThrowing()
            return nil
        } catch {
            let historyError = mappedHistoryError(from: error)
            errorMessage = ErrorText.describe(historyError)
            return historyError
        }
    }

    func performLaunchMaintenance() async -> MacomprendoError? {
        guard isEnabled() else { return nil }
        if let error = await applyRetention() { return error }
        do {
            let referenced = try await store.referencedAudioFilenames()
            try await store.purgeUnreferencedAudioFiles(keeping: Set(referenced))
            return nil
        } catch {
            let historyError = mappedHistoryError(from: error)
            errorMessage = ErrorText.describe(historyError)
            return historyError
        }
    }

    private func applyRetentionThrowing() async throws {
        guard let days = retention().days else { return }
        let cutoff = now().addingTimeInterval(-Double(days) * 86_400)
        let filenames = try await store.deleteEntries(olderThan: cutoff)
        try await store.removeAudioFiles(named: filenames)
        guard !filenames.isEmpty else { return }
        for filename in filenames { existingAudioFilenames.remove(filename) }
        entries.removeAll { $0.createdAt < cutoff }
        savedAudioRevision += 1
    }

    func loadInitial() async {
        guard !isLoading else { return }
        let generation = beginLoading()
        await refreshExistingAudioFilenames()
        await loadPage(beforeID: nil, replacingEntries: true, generation: generation)
    }

    func loadNextPage() async {
        guard !isLoading, hasMore, let nextCursor else { return }
        let generation = beginLoading()
        await loadPage(beforeID: nextCursor, replacingEntries: false, generation: generation)
    }

    func clear() async {
        let generation = beginLoading()
        stopPlayback()

        do {
            try await store.clear()
            guard generation == loadGeneration else { return }
            entries = []
            nextCursor = nil
            hasMore = true
            copiedEntryID = nil
            existingAudioFilenames = []
            savedAudioRevision += 1
            errorMessage = nil
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = ErrorText.describe(mappedHistoryError(from: error))
        }

        if generation == loadGeneration { isLoading = false }
    }

    /// Where recordings live, for the settings screen's reveal-in-Finder action.
    var audioDirectoryURL: URL { store.audioDirectoryURL }

    // MARK: - Playback

    /// True only for an entry that references a recording whose file was present the last time
    /// the directory was read. A row whose file has vanished offers no control rather than a
    /// dead button.
    func isPlayable(_ entry: DictationHistoryEntry) -> Bool {
        guard let filename = entry.audioFileName else { return false }
        return existingAudioFilenames.contains(filename)
    }

    /// Starts this entry's recording, or stops it when it is the one already playing. Only one
    /// entry plays at a time: starting a second stops the first.
    func togglePlayback(_ entry: DictationHistoryEntry) async {
        guard let player else { return }
        guard playingEntryID != entry.id else {
            player.stop()
            playingEntryID = nil
            return
        }
        guard let filename = entry.audioFileName else { return }

        do {
            guard let data = try await store.audioFileData(named: filename) else {
                // The file is gone — drop it from the playable set so the row stops offering
                // a control, and say so instead of failing silently.
                existingAudioFilenames.remove(filename)
                player.stop()
                playingEntryID = nil
                errorMessage = ErrorText.describe(
                    MacomprendoError.audioPlayback("the saved recording is no longer on disk"))
                return
            }
            player.stop()
            try player.play(data)
            existingAudioFilenames.insert(filename)
            playingEntryID = entry.id
            errorMessage = nil
        } catch {
            playingEntryID = nil
            let mapped = error as? MacomprendoError
                ?? MacomprendoError.audioPlayback(error.localizedDescription)
            errorMessage = ErrorText.describe(mapped)
        }
    }

    func stopPlayback() {
        player?.stop()
        playingEntryID = nil
    }

    /// The size of the audio directory, or the error that prevented reading it.
    func savedAudioByteCount() async throws -> Int64 {
        try await store.audioDirectoryByteCount()
    }

    /// Removes every recording and keeps every transcript.
    func deleteSavedAudio() async -> MacomprendoError? {
        stopPlayback()
        do {
            let filenames = try await store.deleteAudioReferences()
            try await store.removeAudioFiles(named: filenames)
            existingAudioFilenames = try await store.existingAudioFilenames()
            entries = entries.map(Self.withoutAudio)
            savedAudioRevision += 1
            errorMessage = nil
            return nil
        } catch {
            let historyError = mappedHistoryError(from: error)
            errorMessage = ErrorText.describe(historyError)
            return historyError
        }
    }

    private static func withoutAudio(_ entry: DictationHistoryEntry) -> DictationHistoryEntry {
        DictationHistoryEntry(id: entry.id, createdAt: entry.createdAt, kind: entry.kind,
                              text: entry.text, audioFileName: nil)
    }

    private func refreshExistingAudioFilenames() async {
        existingAudioFilenames = (try? await store.existingAudioFilenames()) ?? []
    }

    func copy(_ entry: DictationHistoryEntry) {
        pasteboard.writeString(entry.text)
        copiedEntryID = entry.id
        copyGeneration += 1
        let generation = copyGeneration

        Task { [weak self] in
            guard let self else { return }
            await self.copyFeedbackSleep(.seconds(1))
            guard !Task.isCancelled,
                  generation == self.copyGeneration
            else { return }
            self.copiedEntryID = nil
        }
    }

    func cancelLoading() {
        loadGeneration += 1
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
    }

    private func beginLoading() -> Int {
        loadGeneration += 1
        loadTask?.cancel()
        loadTask = nil
        isLoading = true
        return loadGeneration
    }

    private func loadPage(beforeID: Int64?, replacingEntries: Bool, generation: Int) async {
        let store = self.store
        let pageSize = self.pageSize
        let loadTask = Task {
            try await store.fetchPage(beforeID: beforeID, limit: pageSize)
        }
        self.loadTask = loadTask

        do {
            let page = try await loadTask.value
            guard generation == loadGeneration else { return }

            if replacingEntries {
                entries = deduplicating(page.entries)
            } else {
                var seenIDs = Set(entries.map(\.id))
                entries.append(contentsOf: page.entries.filter { seenIDs.insert($0.id).inserted })
            }
            nextCursor = page.nextCursor
            hasMore = page.nextCursor != nil
            errorMessage = nil
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = ErrorText.describe(mappedHistoryError(from: error))
        }

        if generation == loadGeneration {
            self.loadTask = nil
            isLoading = false
        }
    }

    private func deduplicating(_ pageEntries: [DictationHistoryEntry]) -> [DictationHistoryEntry] {
        var knownIDs = Set<Int64>()
        return pageEntries.filter { knownIDs.insert($0.id).inserted }
    }

    private func mappedHistoryError(from error: Error) -> MacomprendoError {
        if error is CancellationError { return .cancelled }
        return .dictationHistory("An error occurred while accessing history.")
    }
}
