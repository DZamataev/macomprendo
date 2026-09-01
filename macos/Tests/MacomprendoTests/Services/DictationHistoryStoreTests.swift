import Foundation
import Testing
@testable import Macomprendo

@Suite struct DictationHistoryStoreTests {
    private func makeStore(maximumEntryCount: Int = 100_000)
        -> (SQLiteDictationHistoryStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("history.sqlite3")
        return (SQLiteDictationHistoryStore(databaseURL: url,
                                            maximumEntryCount: maximumEntryCount), url)
    }

    // Catches using timestamp order, losing data across a reopen, or persisting the wrong kind.
    @Test func appendPersistsAcrossReopenAndFetchesNewestFirst() async throws {
        let (store, url) = makeStore()
        let first = try await store.append(text: "first", kind: .dictation,
                                           at: Date(timeIntervalSince1970: 1))
        let second = try await store.append(text: "second", kind: .dictationAndRefine,
                                            at: Date(timeIntervalSince1970: 2))
        #expect(first.id < second.id)

        let reopened = SQLiteDictationHistoryStore(databaseURL: url)
        let page = try await reopened.fetchPage(beforeID: nil, limit: 20)
        #expect(page.entries.map(\.text) == ["second", "first"])
        #expect(page.entries.map(\.kind) == [.dictationAndRefine, .dictation])
        #expect(page.nextCursor == nil)
    }

    // Catches including the cursor again, which would duplicate rows between pages.
    @Test func pagingUsesAnExclusiveInsertionCursor() async throws {
        let (store, _) = makeStore()
        for value in 1...5 {
            _ = try await store.append(text: "\(value)", kind: .dictation,
                                       at: Date(timeIntervalSince1970: 10))
        }
        let first = try await store.fetchPage(beforeID: nil, limit: 2)
        let second = try await store.fetchPage(beforeID: first.nextCursor, limit: 2)
        let third = try await store.fetchPage(beforeID: second.nextCursor, limit: 2)
        #expect(first.entries.map(\.text) == ["5", "4"])
        #expect(second.entries.map(\.text) == ["3", "2"])
        #expect(third.entries.map(\.text) == ["1"])
        #expect(third.nextCursor == nil)
    }

    // Catches treating zero or negative limits as valid page requests.
    @Test func fetchPageRejectsNonPositiveLimits() async throws {
        let (store, _) = makeStore()

        for limit in [0, -1] {
            do {
                _ = try await store.fetchPage(beforeID: nil, limit: limit)
                Issue.record("expected a dictation history error for limit \(limit)")
            } catch let error as MacomprendoError {
                guard case .dictationHistory = error else {
                    Issue.record("expected a dictation history error, got \(error)")
                    continue
                }
            }
        }
    }

    // Catches failing to create a missing parent directory before opening the database.
    @Test func openingStoreCreatesItsParentDirectory() async throws {
        let parentDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Macomprendo", isDirectory: true)
        let url = parentDirectory.appendingPathComponent("dictation-history.sqlite3")
        let store = SQLiteDictationHistoryStore(databaseURL: url)
        #expect(!FileManager.default.fileExists(atPath: parentDirectory.path))

        _ = try await store.fetchPage(beforeID: nil, limit: 1)

        #expect(FileManager.default.fileExists(atPath: parentDirectory.path))
    }
}
