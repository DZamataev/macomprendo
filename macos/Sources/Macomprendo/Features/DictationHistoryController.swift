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

    private let store: any DictationHistoryStoring
    private let pasteboard: any PasteboardProtocol
    private let isEnabled: @MainActor () -> Bool
    private let encoder: (any DictationAudioEncoding)?
    private let shouldSaveRecording: @MainActor () -> Bool
    private let retention: @MainActor () -> HistoryRetention
    private let pageSize: Int
    private let now: @Sendable () -> Date
    private let copyFeedbackSleep: @Sendable (Duration) async -> Void

    private var nextCursor: Int64?
    private var loadGeneration = 0
    private var loadTask: Task<DictationHistoryPage, Error>?
    private var copyGeneration = 0

    init(store: any DictationHistoryStoring,
         pasteboard: any PasteboardProtocol,
         isEnabled: @escaping @MainActor () -> Bool,
         encoder: (any DictationAudioEncoding)? = nil,
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
        self.shouldSaveRecording = shouldSaveRecording
        self.retention = retention
        self.pageSize = max(1, pageSize)
        self.now = now
        self.copyFeedbackSleep = copyFeedbackSleep
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
            try await encoder.encode(pcm, sampleRate: 16_000, to: url)
            try Task.checkCancellation()
            try await store.attachAudioFile(named: filename, toEntry: entry.id)
            return nil
        } catch {
            try? await store.removeAudioFiles(named: [filename])
            let mapped = error as? MacomprendoError
                ?? MacomprendoError.audioEncoding(error.localizedDescription)
            errorMessage = ErrorText.describe(mapped)
            return mapped
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
    }

    func loadInitial() async {
        guard !isLoading else { return }
        let generation = beginLoading()
        await loadPage(beforeID: nil, replacingEntries: true, generation: generation)
    }

    func loadNextPage() async {
        guard !isLoading, hasMore, let nextCursor else { return }
        let generation = beginLoading()
        await loadPage(beforeID: nextCursor, replacingEntries: false, generation: generation)
    }

    func clear() async {
        let generation = beginLoading()

        do {
            try await store.clear()
            guard generation == loadGeneration else { return }
            entries = []
            nextCursor = nil
            hasMore = true
            copiedEntryID = nil
            errorMessage = nil
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = ErrorText.describe(mappedHistoryError(from: error))
        }

        if generation == loadGeneration { isLoading = false }
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
