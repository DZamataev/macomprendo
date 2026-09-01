import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct DictationHistoryControllerTests {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeController(store: FakeDictationHistoryStore = FakeDictationHistoryStore(),
                                pasteboard: FakePasteboard = FakePasteboard(),
                                enabled: Bool = true,
                                pageSize: Int = 2) -> DictationHistoryController {
        DictationHistoryController(store: store, pasteboard: pasteboard,
                                   isEnabled: { enabled }, pageSize: pageSize,
                                   now: { date })
    }

    private func entry(_ id: Int64, text: String = "entry") -> DictationHistoryEntry {
        DictationHistoryEntry(id: id, createdAt: date, kind: .dictation, text: text)
    }

    private func waitForFetches(_ count: Int, in store: FakeDictationHistoryStore) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await store.fetchRequests.count == count { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for \(count) fetch requests")
    }

    @Test func disabledRecordingDoesNotTouchTheStore() async {
        let store = FakeDictationHistoryStore()
        let controller = makeController(store: store, enabled: false)
        #expect(await controller.record(text: "hello", kind: .dictation) == nil)
        #expect(await store.appendRequests.isEmpty)
    }

    @Test func enabledRecordingTrimsAndAppendsOnce() async {
        let store = FakeDictationHistoryStore()
        let controller = makeController(store: store, enabled: true)
        #expect(await controller.record(text: "  hello \n", kind: .dictation) == nil)
        #expect(await store.appendRequests.map(\.text) == ["hello"])
        #expect(await store.appendRequests.map(\.date) == [date])
    }

    @Test func emptyRecordingDoesNotTouchTheStore() async {
        let store = FakeDictationHistoryStore()
        let controller = makeController(store: store)
        #expect(await controller.record(text: " \n\t ", kind: .dictation) == nil)
        #expect(await store.appendRequests.isEmpty)
    }

    @Test func appendFailureIsReturnedAndPersistsAnErrorMessage() async {
        let store = FakeDictationHistoryStore()
        let failure = MacomprendoError.dictationHistory("append failed")
        await store.setAppendError(failure)
        let controller = makeController(store: store)

        #expect(await controller.record(text: "hello", kind: .dictation) == failure)
        #expect(controller.errorMessage == ErrorText.describe(failure))
    }

    @Test func initialLoadReplacesThePreviousPage() async {
        let store = FakeDictationHistoryStore()
        await store.setPages([
            DictationHistoryPage(entries: [entry(2, text: "old")], nextCursor: nil),
            DictationHistoryPage(entries: [entry(4, text: "new")], nextCursor: nil)
        ])
        let controller = makeController(store: store)

        await controller.loadInitial()
        await controller.loadInitial()

        #expect(controller.entries.map(\.id) == [4])
        #expect(await store.fetchRequests.map(\.beforeID) == [nil, nil])
    }

    @Test func nextPageAppendsOnlyNewEntries() async {
        let store = FakeDictationHistoryStore()
        await store.setPages([
            DictationHistoryPage(entries: [entry(3), entry(2)], nextCursor: 2),
            DictationHistoryPage(entries: [entry(2), entry(1)], nextCursor: nil)
        ])
        let controller = makeController(store: store)

        await controller.loadInitial()
        await controller.loadNextPage()

        #expect(controller.entries.map(\.id) == [3, 2, 1])
        #expect(await store.fetchRequests.map(\.beforeID) == [nil, 2])
        #expect(!controller.hasMore)
    }

    @Test func secondPageLoadIsIgnoredWhileTheFirstIsActive() async {
        let store = FakeDictationHistoryStore()
        await store.setPages([
            DictationHistoryPage(entries: [entry(3)], nextCursor: 3),
            DictationHistoryPage(entries: [entry(2)], nextCursor: nil)
        ])
        let controller = makeController(store: store)
        await controller.loadInitial()
        let gate = AsyncGate()
        await store.setFetchGate(gate)

        let loading = Task { await controller.loadNextPage() }
        await waitForFetches(2, in: store)
        await controller.loadNextPage()

        #expect(await store.fetchRequests.count == 2)
        gate.open()
        await loading.value
    }

    @Test func clearEmptiesEntriesAndResetsTheCursor() async {
        let store = FakeDictationHistoryStore()
        await store.setPages([
            DictationHistoryPage(entries: [entry(3)], nextCursor: 3),
            DictationHistoryPage(entries: [entry(5)], nextCursor: nil)
        ])
        let controller = makeController(store: store)
        await controller.loadInitial()

        await controller.clear()
        await controller.loadInitial()

        #expect(await store.clearCallCount == 1)
        #expect(await store.fetchRequests.map(\.beforeID) == [nil, nil])
        #expect(controller.entries.map(\.id) == [5])
    }

    @Test func fetchFailurePersistsAnErrorMessage() async {
        let store = FakeDictationHistoryStore()
        let failure = MacomprendoError.dictationHistory("fetch failed")
        await store.setFetchError(failure)
        let controller = makeController(store: store)

        await controller.loadInitial()

        #expect(controller.entries.isEmpty)
        #expect(controller.errorMessage == ErrorText.describe(failure))
        #expect(!controller.isLoading)
    }

    @Test func clearFailurePersistsAnErrorMessageWithoutThrowing() async {
        let store = FakeDictationHistoryStore()
        let failure = MacomprendoError.dictationHistory("clear failed")
        await store.setClearError(failure)
        let controller = makeController(store: store)

        await controller.clear()

        #expect(controller.errorMessage == ErrorText.describe(failure))
        #expect(!controller.isLoading)
    }

    @Test func clearInvalidatesAnInFlightPageLoad() async {
        let store = FakeDictationHistoryStore()
        await store.setPages([
            DictationHistoryPage(entries: [entry(3)], nextCursor: 3),
            DictationHistoryPage(entries: [entry(2)], nextCursor: nil)
        ])
        let controller = makeController(store: store)
        await controller.loadInitial()
        let gate = AsyncGate()
        await store.setFetchGate(gate)

        let loading = Task { await controller.loadNextPage() }
        await waitForFetches(2, in: store)
        await controller.clear()
        gate.open()
        await loading.value

        #expect(controller.entries.isEmpty)
        #expect(controller.hasMore)
    }

    @Test func cancelThenReloadIgnoresTheStalePage() async {
        let store = FakeDictationHistoryStore()
        await store.setPages([
            DictationHistoryPage(entries: [entry(1, text: "stale")], nextCursor: nil),
            DictationHistoryPage(entries: [entry(2, text: "fresh")], nextCursor: nil)
        ])
        let controller = makeController(store: store)
        let gate = AsyncGate()
        await store.setFetchGate(gate)

        let firstLoad = Task { await controller.loadInitial() }
        await waitForFetches(1, in: store)
        controller.cancelLoading()
        let reloaded = Task { await controller.loadInitial() }
        await waitForFetches(2, in: store)
        gate.open()
        await firstLoad.value
        await reloaded.value

        #expect(controller.entries.map(\.text) == ["fresh"])
        #expect(!controller.isLoading)
    }

    @Test func copyWritesTheCompleteTranscript() {
        let pasteboard = FakePasteboard()
        let controller = makeController(pasteboard: pasteboard)
        controller.copy(DictationHistoryEntry(id: 1, createdAt: .now,
                                              kind: .dictation, text: "full text"))
        #expect(pasteboard.readString() == "full text")
        #expect(controller.copiedEntryID == 1)
    }
}
