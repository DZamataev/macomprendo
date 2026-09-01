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
    private var appendError: (any Error)?
    private var fetchError: (any Error)?
    private var clearError: (any Error)?
    private var appendGate: AsyncGate?
    private var fetchGate: AsyncGate?

    func setPages(_ pages: [DictationHistoryPage]) {
        self.pages = pages
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
        return response
    }

    func clear() async throws {
        clearCallCount += 1
        if let clearError { throw clearError }
    }
}
