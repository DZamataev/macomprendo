import Foundation
import SwiftUI

@MainActor
final class DictationHistoryController: ObservableObject {
    @Published private(set) var entries: [DictationHistoryEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = true
    @Published private(set) var errorMessage: String?
    @Published private(set) var copiedEntryID: Int64?

    private let store: any DictationHistoryStoring
    private let pasteboard: any PasteboardProtocol
    private let isEnabled: @MainActor () -> Bool
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
         pageSize: Int = 100,
         now: @escaping @Sendable () -> Date = Date.init,
         copyFeedbackSleep: @escaping @Sendable (Duration) async -> Void = { duration in
             try? await Task.sleep(for: duration)
         }) {
        self.store = store
        self.pasteboard = pasteboard
        self.isEnabled = isEnabled
        self.pageSize = max(1, pageSize)
        self.now = now
        self.copyFeedbackSleep = copyFeedbackSleep
    }

    func record(text: String, kind: DictationHistoryKind) async -> MacomprendoError? {
        guard isEnabled() else { return nil }

        let acceptedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !acceptedText.isEmpty else { return nil }

        do {
            _ = try await store.append(text: acceptedText, kind: kind, at: now())
            errorMessage = nil
            return nil
        } catch {
            let historyError = mappedHistoryError(from: error)
            errorMessage = ErrorText.describe(historyError)
            return historyError
        }
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
