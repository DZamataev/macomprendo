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

    private(set) var appendRequests: [AppendRequest] = []
    private(set) var fetchRequests: [FetchRequest] = []
    private(set) var clearCallCount = 0

    private var pages: [DictationHistoryPage] = []
    private var appendError: MacomprendoError?
    private var fetchError: MacomprendoError?
    private var clearError: MacomprendoError?
    private var fetchGate: AsyncGate?

    func setPages(_ pages: [DictationHistoryPage]) {
        self.pages = pages
    }

    func setAppendError(_ error: MacomprendoError?) {
        appendError = error
    }

    func setFetchError(_ error: MacomprendoError?) {
        fetchError = error
    }

    func setClearError(_ error: MacomprendoError?) {
        clearError = error
    }

    func setFetchGate(_ gate: AsyncGate?) {
        fetchGate = gate
    }

    func append(text: String, kind: DictationHistoryKind, at date: Date) async throws
        -> DictationHistoryEntry {
        appendRequests.append(AppendRequest(text: text, kind: kind, date: date))
        if let appendError { throw appendError }
        return DictationHistoryEntry(id: Int64(appendRequests.count), createdAt: date,
                                     kind: kind, text: text)
    }

    func fetchPage(beforeID: Int64?, limit: Int) async throws -> DictationHistoryPage {
        fetchRequests.append(FetchRequest(beforeID: beforeID, limit: limit))
        if let fetchError { throw fetchError }
        if let fetchGate { await fetchGate.wait() }
        guard !pages.isEmpty else {
            return DictationHistoryPage(entries: [], nextCursor: nil)
        }
        return pages.removeFirst()
    }

    func clear() async throws {
        clearCallCount += 1
        if let clearError { throw clearError }
    }
}
