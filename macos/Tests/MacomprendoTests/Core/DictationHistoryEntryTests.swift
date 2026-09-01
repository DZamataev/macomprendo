import Foundation
import Testing
@testable import Macomprendo

@Test func historyEntryCarriesStableIdentityAndKind() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let entry = DictationHistoryEntry(id: 42, createdAt: date,
                                      kind: .dictationAndRefine, text: "hello")
    #expect(entry.id == 42)
    #expect(entry.createdAt == date)
    #expect(entry.kind == .dictationAndRefine)
    #expect(entry.text == "hello")
}

@Test func historyEntryEqualityIncludesAllStoredValues() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let entry = DictationHistoryEntry(id: 42, createdAt: date,
                                      kind: .dictationAndRefine, text: "hello")
    #expect(entry == DictationHistoryEntry(id: 42, createdAt: date,
                                           kind: .dictationAndRefine, text: "hello"))
    #expect(entry != DictationHistoryEntry(id: 43, createdAt: date,
                                           kind: .dictationAndRefine, text: "hello"))
    #expect(entry != DictationHistoryEntry(id: 42, createdAt: date,
                                           kind: .dictation, text: "hello"))
    #expect(entry != DictationHistoryEntry(id: 42, createdAt: date,
                                           kind: .dictationAndRefine, text: "goodbye"))
}

@Test func historyPageCarriesTheNextCursor() {
    let page = DictationHistoryPage(entries: [], nextCursor: 41)
    #expect(page.nextCursor == 41)
}
