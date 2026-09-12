import Foundation
@testable import Macomprendo

actor FakeDictationHistoryStore: DictationHistoryStoring {
    struct AppendRequest: Sendable, Equatable {
        let text: String
        let kind: DictationHistoryKind
        let date: Date
    }

    struct FetchRequest: Sendable, Equatable {
        let beforeID: Int64?
        let limit: Int
    }

    struct AttachRequest: Sendable, Equatable {
        let filename: String
        let entryID: Int64
    }

    nonisolated let audioDirectoryURL: URL

    init(audioDirectoryURL: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("FakeDictationAudio", isDirectory: true)) {
        self.audioDirectoryURL = audioDirectoryURL
    }

    private(set) var appendRequests: [AppendRequest] = []
    private(set) var fetchRequests: [FetchRequest] = []
    private(set) var attachRequests: [AttachRequest] = []
    private(set) var deleteOlderThanRequests: [Date] = []
    private(set) var deleteAudioReferencesCallCount = 0
    private(set) var referencedAudioFilenamesCallCount = 0
    private(set) var cancelledFetchCount = 0
    private(set) var clearCallCount = 0

    private var pages: [DictationHistoryPage] = []
    private var expiredAudioFilenames: [String] = []
    private var storedAudioFilenames: [String] = []
    private var appendError: (any Error)?
    private var fetchError: (any Error)?
    private var clearError: (any Error)?
    private var attachError: (any Error)?
    private var retentionError: (any Error)?
    private var appendGate: AsyncGate?
    private var fetchGate: AsyncGate?

    func setPages(_ pages: [DictationHistoryPage]) {
        self.pages = pages
    }

    func setExpiredAudioFilenames(_ filenames: [String]) {
        expiredAudioFilenames = filenames
    }

    func setStoredAudioFilenames(_ filenames: [String]) {
        storedAudioFilenames = filenames
    }

    func setAppendError(_ error: (any Error)?) {
        appendError = error
    }

    func setFetchError(_ error: (any Error)?) {
        fetchError = error
    }

    func setClearError(_ error: (any Error)?) {
        clearError = error
    }

    func setAttachError(_ error: (any Error)?) {
        attachError = error
    }

    func setRetentionError(_ error: (any Error)?) {
        retentionError = error
    }

    /// Suspends an append only after its request has been accepted, so callers can
    /// deterministically exercise cancellation and ordering at the durable commit point.
    func setAppendGate(_ gate: AsyncGate?) {
        appendGate = gate
    }

    func setFetchGate(_ gate: AsyncGate?) {
        fetchGate = gate
    }

    func append(text: String, kind: DictationHistoryKind, at date: Date) async throws
        -> DictationHistoryEntry {
        appendRequests.append(AppendRequest(text: text, kind: kind, date: date))
        if let appendGate { await appendGate.wait() }
        if let appendError { throw appendError }
        return DictationHistoryEntry(id: Int64(appendRequests.count), createdAt: date,
                                     kind: kind, text: text)
    }

    func fetchPage(beforeID: Int64?, limit: Int) async throws -> DictationHistoryPage {
        fetchRequests.append(FetchRequest(beforeID: beforeID, limit: limit))
        if let fetchError { throw fetchError }
        let response: DictationHistoryPage
        if pages.isEmpty {
            response = DictationHistoryPage(entries: [], nextCursor: nil)
        } else {
            response = pages.removeFirst()
        }
        if let fetchGate { await fetchGate.wait() }
        if Task.isCancelled {
            cancelledFetchCount += 1
            throw CancellationError()
        }
        return response
    }

    func clear() async throws {
        clearCallCount += 1
        if let clearError { throw clearError }
        storedAudioFilenames = []
    }

    func attachAudioFile(named filename: String, toEntry id: Int64) async throws {
        attachRequests.append(AttachRequest(filename: filename, entryID: id))
        if let attachError { throw attachError }
        storedAudioFilenames.append(filename)
    }

    @discardableResult
    func deleteEntries(olderThan cutoff: Date) async throws -> [String] {
        deleteOlderThanRequests.append(cutoff)
        if let retentionError { throw retentionError }
        let expired = expiredAudioFilenames
        expiredAudioFilenames = []
        storedAudioFilenames.removeAll { expired.contains($0) }
        return expired
    }

    @discardableResult
    func deleteAudioReferences() async throws -> [String] {
        deleteAudioReferencesCallCount += 1
        if let retentionError { throw retentionError }
        let removed = storedAudioFilenames
        storedAudioFilenames = []
        return removed
    }

    func referencedAudioFilenames() async throws -> [String] {
        referencedAudioFilenamesCallCount += 1
        if let retentionError { throw retentionError }
        return storedAudioFilenames
    }

    func removeAudioFiles(named filenames: [String]) async throws {
        if let retentionError { throw retentionError }
        for filename in filenames {
            let url = audioDirectoryURL.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    func purgeUnreferencedAudioFiles(keeping referencedFilenames: Set<String>) async throws {
        if let retentionError { throw retentionError }
        guard FileManager.default.fileExists(atPath: audioDirectoryURL.path) else { return }
        for url in try FileManager.default.contentsOfDirectory(at: audioDirectoryURL,
                                                               includingPropertiesForKeys: nil)
            where !referencedFilenames.contains(url.lastPathComponent) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
